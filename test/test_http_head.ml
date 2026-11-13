(* F2.1: the request-head and response-head ceilings.

   Two layers are exercised. The pure cases drive [Http_head] directly, so the
   boundary is asserted in bytes rather than in elapsed time: a head of exactly
   {!Http_head.request_head_limit} bytes is accepted, the byte that would make
   it one more is refused, and the count is cumulative — a thousand short
   headers are refused exactly as one long one is. The wire cases run one real
   loopback connection through {!Server.serve_connection}, which is where the
   ceiling, the replay and the refusal statuses meet; the timeout case injects
   a monotonic clock whose [sleep_until] returns at once, so no case here waits
   on wall-clock time to decide an outcome. *)

module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Http_head = Seekwright.Http_head
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Server = Seekwright.Server
module Usage = Seekwright.Usage
module A = Alcotest
open Test_support

(* {1 Fixtures}

   The app shape is [test_p8_server.ml]'s: a stub [Provider.S], a search engine
   built from it, and the MCP server over the registry. Nothing is dialled and
   no config file is read. *)

let clock () = 1.0
let now () = 1_700_000_000.0

type stub = {
  name : string;
  behavior : Model.search_query -> (Provider.outcome, Provider.error) result;
}

let stub ?(name = "serper") () =
  let behavior (q : Model.search_query) =
    Ok
      {
        Provider.provider = name;
        results =
          [
            {
              Provider.result =
                {
                  Model.title = "Result for " ^ q.Model.query;
                  url = "https://example.com/" ^ q.Model.query;
                  snippet = Some "a snippet";
                  text = None;
                  text_truncated = None;
                  published_date = None;
                  score = None;
                };
              uncapped_chars = None;
            };
          ];
        answer = None;
        cost_usd = Some 0.001;
        notice = None;
      }
  in
  { name; behavior }

let provider (s : stub) : Provider.t =
  (module struct
    let name = s.name
    let cost_per_1k = 1.0
    let cost_for n = float_of_int n /. 1000.
    let search q = s.behavior q
    let aclose () = ()
  end : Provider.S)

let config () =
  match
    Config.resolve
      ~providers:
        [ ( "serper",
            { Config.default_provider_config with Config.enabled = true } ) ]
      ()
  with
  | Ok config -> config
  | Error message -> A.failf "the fixture config was refused: %s" message

let app () : Server.app =
  let config = config () in
  let search =
    Engine.Search.create config
      (List.map (fun s -> (s.name, provider s)) [ stub () ])
      ~clock ~now ()
  in
  let usage =
    match Usage.create ~now () with
    | Ok usage -> usage
    | Error message -> A.failf "the fixture recorder was refused: %s" message
  in
  {
    Server.config;
    search;
    usage;
    fetch = None;
    agent = None;
    started_at = 40.0;
    mono_now = (fun () -> 42.5);
    allowed_hosts = [];
    health = None;
  }

let mcp app =
  match Server.mcp_server app with
  | Ok server -> server
  | Error _ -> A.fail "the fixture registry was refused"

(* {1 Head construction} *)

let base_head = "GET /healthz HTTP/1.1\r\nHost: localhost\r\n"
let head_term = "\r\n"

(* A head of exactly [size] wire bytes: the fixed request line and Host header,
   one padding header that carries the difference, and the blank line. *)
let head_of_size size =
  let fixed = String.length base_head + String.length head_term in
  if size < fixed + 9 then invalid_arg "head_of_size: smaller than the fixed part";
  let value = String.make (size - fixed - 9) 'a' in
  base_head ^ "X-Pad: " ^ value ^ "\r\n" ^ head_term

let many_headers count =
  let buffer = Buffer.create 1024 in
  Buffer.add_string buffer base_head;
  for n = 1 to count do
    Buffer.add_string buffer
      (Printf.sprintf "X-Header-%04d: %s\r\n" n (String.make 20 'v'))
  done;
  Buffer.add_string buffer head_term;
  Buffer.contents buffer

let healthz_request = "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n"

(* {1 Reading a head from a string} *)

let read_head ?(limit = Http_head.request_head_limit) text =
  let source = Eio.Flow.string_source text in
  let reader = Http_head.request_reader ~limit source in
  Http_head.read_request_head ~limit reader

let expect_too_large = function
  | Error Http_head.Request_head_too_large -> ()
  | Error Http_head.Malformed_request_head ->
      A.fail "a head over the ceiling was reported as malformed"
  | Error Http_head.Client_closed -> A.fail "a complete head was reported as a closed connection"
  | Ok (_head, raw) ->
      A.failf "a head of %d bytes was accepted" (String.length raw)

(* {1 The request ceiling} *)

let a_request_line_at_the_cap_is_accepted () =
  let text = head_of_size Http_head.request_head_limit in
  match read_head text with
  | Error error ->
      A.failf "the at-cap head was refused: %s"
        (match error with
        | Http_head.Client_closed -> "closed"
        | Http_head.Request_head_too_large -> "too large"
        | Http_head.Malformed_request_head -> "malformed")
  | Ok (head, raw) ->
      A.(check int) "the head keeps every byte" Http_head.request_head_limit
        (String.length raw);
      A.(check string) "the request line" "GET /healthz HTTP/1.1"
        head.Http_head.request_line;
      A.(check (list string)) "the header lines" [ "Host: localhost"; "X-Pad: " ^ String.make (Http_head.request_head_limit - 51) 'a' ]
        head.Http_head.header_lines

let a_request_line_over_the_cap_is_refused () =
  expect_too_large (read_head (head_of_size (Http_head.request_head_limit + 1)))

let many_small_headers_are_counted_together () =
  (* The ceiling is on the head, not on one line: 500 short headers fit, and a
     head built the same way but longer does not. *)
  (match read_head (many_headers 300) with
  | Ok (head, _) ->
      A.(check int) "every header line is parsed" 301
        (List.length head.Http_head.header_lines)
  | Error _ -> A.fail "300 short headers were refused");
  expect_too_large (read_head (many_headers 600))

let one_huge_header_is_refused () =
  let text =
    base_head ^ "X-Huge: " ^ String.make (Http_head.request_head_limit + 1) 'a'
    ^ "\r\n" ^ head_term
  in
  expect_too_large (read_head text)

let the_raw_bytes_survive_parsing () =
  let crlf = "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n" in
  let lf = "GET /healthz HTTP/1.1\nHost: localhost\n\n" in
  let raw_of text =
    match read_head text with
    | Ok (_, raw) -> raw
    | Error _ -> A.failf "a valid head was refused: %S" text
  in
  A.(check string) "CRLF is replayed byte for byte" crlf (raw_of crlf);
  A.(check string) "a bare-LF head is not rewritten into CRLF" lf (raw_of lf);
  match read_head lf with
  | Ok (head, _) ->
      A.(check (list string)) "bare-LF lines lose only their terminator"
        [ "Host: localhost" ] head.Http_head.header_lines
  | Error _ -> A.fail "a bare-LF head was refused"

(* {1 The response ceiling} *)

let response_head_at_and_over_the_cap () =
  let headers = [ ("content-type", "text/plain") ] in
  let rendered =
    match Http_head.response_head ~status:200 ~headers ~body_length:5 () with
    | Ok head -> head
    | Error Http_head.Response_head_too_large ->
        A.fail "an ordinary head was refused"
  in
  let size = String.length rendered in
  (match Http_head.response_head ~limit:size ~status:200 ~headers ~body_length:5 () with
  | Ok head -> A.(check int) "exactly at the cap is accepted" size (String.length head)
  | Error _ -> A.fail "a head of exactly the cap was refused");
  match
    Http_head.response_head ~limit:(size - 1) ~status:200 ~headers
      ~body_length:5 ()
  with
  | Error Http_head.Response_head_too_large -> ()
  | Ok _ -> A.fail "a head one byte over the cap was accepted"

let an_ordinary_response_head_is_under_the_default_cap () =
  match
    Http_head.response_head ~status:200
      ~headers:[ ("content-type", "text/plain") ]
      ~body_length:(String.length "Request Header Fields Too Large") ()
  with
  | Ok head ->
      A.(check bool) "under the named cap" true
        (String.length head <= Http_head.response_head_limit)
  | Error _ -> A.fail "an ordinary head was refused by the default cap"

(* {1 The wire} *)

(* The fake monotonic clock: [sleep_until] advances the reading and returns, so
   the timeout decides the 408 case with no wall-clock wait. It is the same
   [Eio.Time.Pi] seam [test_health.ml] uses for the cooldown. *)
module Fake_clock = struct
  type t = { mutable now : Mtime.t }
  type time = Mtime.t

  let now t = t.now
  let sleep_until t target = if Mtime.compare t.now target < 0 then t.now <- target
end

let fake_clock () =
  let state = { Fake_clock.now = Mtime.of_uint64_ns 0L } in
  Eio.Resource.T (state, Eio.Time.Pi.clock (module Fake_clock))

(* One listener per case: [Eio.Net.run_server] accepts, and each accepted
   connection is handed to the one driver under test — nothing else wraps it. *)
let with_connection ~app ~clock f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen ~sw ~backlog:4 net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> A.failf "unexpected unix socket: %s" path
  in
  let server = mcp app in
  let clock = clock env in
  let stop, resolve_stop = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Net.run_server ~stop ~on_error:(fun _ -> ()) socket
        (fun flow peer ->
          Server.serve_connection ~clock ~log:(fun _ _ _ -> ()) ~app ~server
            ~flow ~peer ()));
  Fun.protect
    ~finally:(fun () -> Eio.Promise.resolve resolve_stop ())
    (fun () -> f sw env port)

let connect ~sw env port =
  Eio.Net.connect ~sw (Eio.Stdenv.net env)
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))

let send flow text = Eio.Flow.copy_string text flow

let read_all flow =
  let reader = Eio.Buf_read.of_flow flow ~max_size:1_000_000 in
  Eio.Buf_read.take_all reader

(* One request on its own connection, half-closed after the request so the
   keep-alive loop sees EOF and the answer is complete. *)
let one_shot ~sw env port text =
  let flow = connect ~sw env port in
  send flow text;
  Eio.Flow.shutdown flow `Send;
  read_all flow

let status_of response = match String.index_opt response '\r' with
  | Some at -> String.sub response 0 at
  | None -> response

let read_response reader =
  let status_line = Eio.Buf_read.line reader in
  let rec header_lines acc =
    let line = Eio.Buf_read.line reader in
    if line = "" || line = "\r" then List.rev acc
    else header_lines (line :: acc)
  in
  let headers = header_lines [] in
  let content_length =
    List.fold_left
      (fun found line ->
        match String.index_opt line ':' with
        | None -> found
        | Some at ->
            let name =
              String.lowercase_ascii (String.trim (String.sub line 0 at))
            in
            if name <> "content-length" then found
            else
              Some
                (int_of_string
                   (String.trim
                      (String.sub line (at + 1)
                         (String.length line - at - 1))))
      )
      None headers
  in
  let length = Option.value content_length ~default:0 in
  let body = if length = 0 then "" else Eio.Buf_read.take length reader in
  (status_line, headers, body)

let head_too_large () = head_of_size (Http_head.request_head_limit + 1)

let an_ordinary_request_survives_a_refusal () =
  (* The at-cap head is served, the over-cap one is refused, and the next
     connection is served as if nothing happened: the ceiling costs one
     connection, not the listener. *)
  with_connection ~app:(app ())
    ~clock:(fun env -> Eio.Stdenv.mono_clock env)
  @@ fun sw env port ->
  let at_cap = one_shot ~sw env port (head_of_size Http_head.request_head_limit) in
  A.(check string) "the at-cap head is served"
    "HTTP/1.1 200 OK" (status_of at_cap);
  let refused = one_shot ~sw env port (head_too_large ()) in
  A.(check string) "the over-cap head is refused"
    "HTTP/1.1 431 Request Header Fields Too Large" (status_of refused);
  A.(check bool) "the refusal says the connection closes" true
    (contains ~haystack:refused ~needle:"connection: close");
  let ordinary = one_shot ~sw env port healthz_request in
  A.(check string) "the next request is served"
    "HTTP/1.1 200 OK" (status_of ordinary);
  A.(check bool) "with the health body" true
    (contains ~haystack:ordinary ~needle:"\"status\"")

let a_trickled_head_and_a_chunked_body_are_read () =
  (* Neither the head nor the body arrives in one write. The head reader has to
     stop exactly at its blank line without swallowing body bytes, and the
     chunked body has to reach the MCP handler intact. *)
  with_connection ~app:(app ())
    ~clock:(fun env -> Eio.Stdenv.mono_clock env)
  @@ fun sw env port ->
  let flow = connect ~sw env port in
  let body = {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}|} in
  let chunk text =
    Printf.sprintf "%x\r\n%s\r\n" (String.length text) text
  in
  send flow "POST /mcp HTTP/1.1\r\nHost: local";
  Eio.Fiber.yield ();
  send flow "host\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n\r\n";
  Eio.Fiber.yield ();
  send flow (chunk (String.sub body 0 20));
  Eio.Fiber.yield ();
  send flow (chunk (String.sub body 20 (String.length body - 20)));
  Eio.Fiber.yield ();
  send flow "0\r\n\r\n";
  Eio.Flow.shutdown flow `Send;
  let response = read_all flow in
  A.(check string) "the chunked request is answered"
    "HTTP/1.1 200 OK" (status_of response);
  A.(check bool) "the tool list is in the body" true
    (contains ~haystack:response ~needle:"search")

let an_unterminated_head_meets_the_injected_timeout () =
  (* The client connects and never sends a head. The fake clock's
     [sleep_until] returns immediately, so the timeout fires at once and the
     refusal is read without any wall-clock wait. *)
  let events = ref [] in
  let log _level event fields = events := (event, fields) :: !events in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~sw ~backlog:4 (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> A.failf "unexpected unix socket: %s" path
  in
  let app = app () in
  let server = mcp app in
  let stop, resolve_stop = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Net.run_server ~stop ~on_error:(fun _ -> ()) socket
        (fun flow peer ->
          Server.serve_connection ~clock:(fake_clock ()) ~log ~app ~server
            ~flow ~peer ()));
  Fun.protect
    ~finally:(fun () -> Eio.Promise.resolve resolve_stop ())
    (fun () ->
      let flow = connect ~sw env port in
      let response = read_all flow in
      A.(check string) "408" "HTTP/1.1 408 Request Timeout" (status_of response));
  A.(check bool) "the timeout is logged as a head rejection" true
    (List.exists
       (fun (event, fields) ->
         event = "http.head_rejected"
         && List.assoc_opt "kind" fields = Some (`String "timeout"))
       !events)

let an_over_cap_head_on_a_keep_alive_connection_is_refused () =
  (* The first request is served over keep-alive; the second head arrives on
     the same connection and is read by the transport from the same bounded
     reader, so its single over-wide line trips the ceiling rather than growing
     the buffer. The refusal replaces the answer to the second request. *)
  with_connection ~app:(app ())
    ~clock:(fun env -> Eio.Stdenv.mono_clock env)
  @@ fun sw env port ->
  let flow = connect ~sw env port in
  let reader = Eio.Buf_read.of_flow flow ~max_size:1_000_000 in
  send flow healthz_request;
  let status, _, body = read_response reader in
  A.(check string) "the first request answers" "HTTP/1.1 200 OK" status;
  A.(check bool) "with the health body" true
    (contains ~haystack:body ~needle:"\"status\"");
  (* One line, not many: the transport reads a later head through the same
     bounded reader, so a line past the ceiling trips the buffer rather than
     growing it. *)
  send flow ("GET /healthz HTTP/1.1\r\nX-Huge: " ^ String.make 65_536 'a' ^ "\r\n\r\n");
  let status, _, _ = read_response reader in
  A.(check string) "the second head is refused"
    "HTTP/1.1 431 Request Header Fields Too Large" status;
  (* The refusal drains the peer's remaining input before closing; closing the
     client is what lets that drain see EOF instead of the head timeout. *)
  Eio.Flow.close flow

let () =
  A.run "http-head"
    [
      ( "the request ceiling",
        [
          A.test_case "a request line at the cap is accepted" `Quick
            a_request_line_at_the_cap_is_accepted;
          A.test_case "a request line over the cap is refused" `Quick
            a_request_line_over_the_cap_is_refused;
          A.test_case "many headers are counted together" `Quick
            many_small_headers_are_counted_together;
          A.test_case "one huge header is refused" `Quick
            one_huge_header_is_refused;
          A.test_case "the raw bytes survive parsing" `Quick
            the_raw_bytes_survive_parsing;
        ] );
      ( "the response ceiling",
        [
          A.test_case "at the cap is accepted, over it is refused" `Quick
            response_head_at_and_over_the_cap;
          A.test_case "an ordinary head is under the default cap" `Quick
            an_ordinary_response_head_is_under_the_default_cap;
        ] );
      ( "the wire",
        [
          A.test_case "an ordinary request survives a refusal" `Quick
            an_ordinary_request_survives_a_refusal;
          A.test_case "a trickled head and a chunked body are read" `Quick
            a_trickled_head_and_a_chunked_body_are_read;
          A.test_case "an unterminated head meets the injected timeout" `Quick
            an_unterminated_head_meets_the_injected_timeout;
          A.test_case "an over-cap keep-alive head is refused" `Quick
            an_over_cap_head_on_a_keep_alive_connection_is_refused;
        ] );
    ]
