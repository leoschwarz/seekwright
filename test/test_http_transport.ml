(* M2: the same registry-backed server over Streamable HTTP.

   What this suite pins is that the HTTP transport adds framing and nothing else
   to the capability surface, and that the bounds a reviewer would expect to
   find implemented here are the mcp-kit adapter's, not ours
   (plans/capability-gated-mcp-server.md §7):

   - one transcript of legacy JSON-RPC bodies — [initialize], the initialized
     notification, [tools/list], three [tools/call]s and the no-capability
     [ping] — gets the same JSON answer through a stdio session as over a
     loopback HTTP POST, so what [Mcp_caps.Server.of_registry] produces is
     transport-neutral;
   - the request body ceiling comes from [Mcp_kit_cohttp_eio.handler
     ~max_body_size]: this file chooses the number, and the 413 with an empty
     body (and the fact that the oversized body is never parsed) is the
     library's;
   - modern Streamable HTTP routing headers ([MCP-Protocol-Version],
     [Mcp-Method], [Mcp-Name]), the [Content-Type]/[Accept] requirement, the
     Origin allowlist and the method gate are the adapter's too: a wrong
     [Mcp-Method] is a 400 carrying the adapter's own JSON-RPC code -32020, an
     unlisted [Origin] is a 403 with [Rejected_origin] reported to
     [Cohttp_eio.Server.run]'s [on_error], and a GET never reaches dispatch.

   The last two are also where the M2 spike lives — can a grant vary per client?
   Not through mcp-kit: [handler] closes over one [Mcp_kit.Server.t] and its
   callback ignores the connection it is given. [two_listeners_do_not_share_a_grant]
   is the shape that works with no application transport code at all — one
   listener per policy — and [one_listener_can_route_connections_to_different_grants]
   is the shape that works with eight lines of accept loop, because
   [Cohttp_eio.Server.callback] is public and is the per-connection driver
   [Cohttp_eio.Server.run] wraps. What neither can do is decide *from the
   request*: at accept time the only fact about the caller is its address.
   [concurrent_clients_do_not_mix_answers] is the shape that must not vary: two
   clients on one listener share its confinement, and their answers stay
   separate.

   [stdio_enforces_the_legacy_lifecycle_and_http_does_not] is the other half of
   the finding: [Mcp_kit_stdio.run_channels] opens one [Mcp_kit.Server.session]
   and gates the transcript behind [initialize], while the Cohttp-Eio adapter
   dispatches every POST statelessly against the server value. There is no
   session value on the HTTP path, so there is nothing per-connection to hang a
   per-client grant on.

   {2 The two transcripts, recorded 2026-11-10}

   The same seven bodies, in the same order, run against
   [examples/read_source.exe /tmp/opencode/src] — once over stdio, once over
   [--http 8765] with curl. Every JSON body below came back byte-identical from
   both transports; what differs is only the framing.

   {v
   body                                     stdio session            streamable HTTP
   id:1 initialize                          serverInfo read-source   200, 191 B, same body
   notifications/initialized                (no line)                204, 0 B
   id:2 tools/list                          ping + read_source       200, 400 B, same body
   id:3 read notes/answer.md                "the answer is 42\n"     200, 131 B, same body
   id:4 read escape -> /etc/passwd          denied: … isError        200, 223 B, same body
   id:5 read ../../etc/passwd               invalid: … isError       200, 255 B, same body
   id:6 ping                                "pong"                   200, 117 B, same body
   v}

   Three calls the stdio transcript cannot make, all answered by the adapter's
   own code rather than by anything in this tree: a 2026-07-28 [tools/call] with
   [mcp-protocol-version], [mcp-method] and [mcp-name] set answers the file
   (200, and its result carries [_meta.io.modelcontextprotocol/serverInfo]); the
   same body with [mcp-method: tools/list] is [400 {"error":{"code":-32020,
   "message":"header mismatch: Mcp-Method"}}]; and a POST carrying
   [origin: http://evil.example] is [403] with an empty body, with
   [Rejected_origin] reaching [Cohttp_eio.Server.run]'s [on_error] — the
   example logs it as [read-source: origin rejected] on stderr, beside the
   startup notes, never on the protocol channel. *)

module Authority = Mcp_caps.Authority
module Error = Mcp_caps.Error
module Policy = Mcp_caps.Policy
module Registry = Mcp_caps.Registry
module Server = Mcp_caps.Server
module Tool = Mcp_caps.Tool

let path_schema =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc [ ("path", `Assoc [ ("type", `String "string") ]) ]);
      ("required", `List [ `String "path" ]);
    ]

let empty_schema =
  `Assoc [ ("type", `String "object"); ("properties", `Assoc []); ("required", `List []) ]

(* The same two declarations test_grant_wiring.ml uses, so a difference between
   the two suites can only come from the transport. *)
let read_source =
  Tool.make
    ~description:"Read a file under the root this server was given."
    ~input_schema:path_schema
    ~decode:(fun json ->
      match json with
      | `Assoc [("path", `String path)] -> Ok path
      | _ -> Error "path must be a string")
    ~run:(fun grant path ->
      match Authority.Fs.read_file grant path with
      | Ok content -> Ok (Tool.Output.text content)
      | Error error -> Error error)
    "read_source"

let ping =
  Tool.make
    ~description:"Say pong."
    ~input_schema:empty_schema
    ~decode:(fun _json -> Ok ())
    ~run:(fun () () -> Ok (Tool.Output.text "pong"))
    "ping"

let root_a = Filename.temp_dir "mcp-caps-http-a" ""
let root_b = Filename.temp_dir "mcp-caps-http-b" ""

let write dir name contents =
  let channel = open_out (Filename.concat dir name) in
  output_string channel contents;
  close_out channel

let () =
  write root_a "answer.md" "from A\n";
  (* The two shapes a real transport has to refuse: a symlink out of the root,
     and a lexical walk. *)
  Unix.symlink "/etc/passwd" (Filename.concat root_a "escape");
  write root_b "answer.md" "from B\n"

let starts_with prefix text =
  String.length text >= String.length prefix
  && String.sub text 0 (String.length prefix) = prefix

let contains text needle =
  let n = String.length text and m = String.length needle in
  let rec from i =
    if i + m > n then false
    else if starts_with needle (String.sub text i m) then true
    else from (i + 1)
  in
  from 0

(* {2 A server value, and a listener around it}

   Grant, registry, server, listener and client all live under one
   [Eio.Switch.t] — the §7 contract, the same one examples/read_source.ml runs.
   A listener is stopped with the [stop] promise rather than by cancelling its
   fiber: [Eio.Switch.run] waits for every fiber it registered, so a listener
   that is never asked to return would hang the test rather than fail it. *)

type listener = {
  port : int;
  rejected : int Atomic.t;
  faults : exn list Atomic.t;
  stop : unit Eio.Promise.u;
  stopped : unit Eio.Promise.t;
}

let build_server ~sw env ~root =
  match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) root with
  | Error error -> Alcotest.failf "with_root %s: %s" root (Error.render error)
  | Ok confinement ->
      let grant = Authority.Fs.of_confinement confinement in
      let ( >>= ) = Result.bind in
      match
        Registry.add Registry.empty ping ~grant:()
        >>= (fun registry -> Registry.add registry read_source ~grant)
      with
      | Error (Registry.Duplicate_tool name) -> Alcotest.failf "duplicate: %s" name
      | Ok registry -> (
          match Server.of_registry ~name:"http-test" ~version:"0" registry with
          | Ok server -> server
          | Error (Server.Duplicate_tool name) -> Alcotest.failf "duplicate: %s" name
          | Error (Server.Invalid_declaration message) ->
              Alcotest.failf "invalid declaration: %s" message)

let run_listener ~env ~sw ?(max_body_size = 4096) ?(allowed_origins = []) server =
  (* [rejected] counts the Origin rejections the adapter reports to [on_error];
     [faults] collects every other connection fault, because a fault the test
     did not ask for is a failure and not a log line. *)
  let rejected = Atomic.make 0 in
  let faults = Atomic.make [] in
  let on_error = function
    | Mcp_kit_cohttp_eio.Rejected_origin -> Atomic.incr rejected
    | exn -> Atomic.set faults (exn :: Atomic.get faults)
  in
  let handler = Mcp_kit_cohttp_eio.handler ~max_body_size ~allowed_origins server in
  let socket =
    Eio.Net.listen ~backlog:128 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  match Eio.Net.listening_addr socket with
  | `Tcp (_, port) ->
      let stop, fill = Eio.Promise.create () in
      let stopped, fill_stopped = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect
          ~finally:(fun () -> Eio.Promise.resolve fill_stopped ())
          (fun () -> Cohttp_eio.Server.run ~stop ~on_error socket handler));
      { port; rejected; faults; stop = fill; stopped }
  | `Unix path -> Alcotest.failf "unexpected unix socket: %s" path

let stop_listener listener =
  Eio.Promise.resolve listener.stop ();
  Eio.Promise.await listener.stopped

(* Both counts are checked after the listener has drained: the adapter writes
   the 403 before it raises [Rejected_origin], so the client can see the
   response while the server's fiber is still on its way to [on_error]. *)
let check_listener ?(rejections = 0) listener =
  Alcotest.(check int) "Origin rejections the adapter reported" rejections
    (Atomic.get listener.rejected);
  match Atomic.get listener.faults with
  | [] -> ()
  | exns ->
      Alcotest.failf "unexpected connection faults: %s"
        (String.concat "; " (List.map Printexc.to_string exns))

let json_headers extra =
  Http.Header.of_list (("content-type", "application/json") :: extra)

let read_response response body =
  ( Http.Status.to_int (Http.Response.status response),
    Eio.Buf_read.(take_all (of_flow ~max_size:1_000_000 body)) )

let post ~sw client ~headers ?(body = "") uri =
  Cohttp_eio.Client.post client ~sw ~headers ~body:(Cohttp_eio.Body.of_string body) uri

let get ~sw client ~headers uri = Cohttp_eio.Client.get client ~sw ~headers uri

(* What a case is handed: the server value it is calling, and a client that is
   already pointed at the listener serving it. *)
type serving = {
  server : Mcp_kit.Server.t;
  client : Cohttp_eio.Client.t;
  uri : Uri.t;
}

(* Serves [root]'s grant set on loopback, runs [f] against it, then stops the
   listener and fails on any fault the adapter reported that the case did not
   ask for. [rejections] is the number of Origin rejections the case wants. *)
let with_server ~root ?max_body_size ?allowed_origins ?(rejections = 0) f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let server = build_server ~sw env ~root in
  let listener = run_listener ~env ~sw ?max_body_size ?allowed_origins server in
  let client = Cohttp_eio.Client.make ~https:None env#net in
  Fun.protect
    ~finally:(fun () -> stop_listener listener)
    (fun () ->
      f {
        server;
        client;
        uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/" listener.port);
      });
  check_listener ~rejections listener

(* {2 The transcript, and its parity with stdio}

   The same seven bodies, in the same order, through both transports; they are
   the calls in the transcripts recorded in examples/read_source.ml and in the
   M2 commit message. *)

let initialize =
  {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"m2","version":"0"}}}|}

let initialized = {|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}|}

let tools_list = {|{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}|}

let call name arguments =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":%S,"arguments":%s}}|}
    name arguments

(* A 2026-07-28 request: the same body on either transport, plus the three
   routing headers the HTTP adapter insists on (its check, not ours). *)
let modern_body method_ name arguments =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":9,"method":%S,"params":{"name":%S,"arguments":%s,"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}|}
    method_ name arguments

let modern_headers method_ name =
  json_headers
    [
      ("accept", "application/json, text/event-stream");
      ("mcp-protocol-version", "2026-07-28");
      ("mcp-method", method_);
      ("mcp-name", name);
    ]

let transcript =
  [
    ("initialize", initialize);
    ("initialized notification", initialized);
    ("tools/list", tools_list);
    ("read in root", call "read_source" {|{"path":"answer.md"}|});
    ("read via a symlink out of root", call "read_source" {|{"path":"escape"}|});
    ("read by walking out of root", call "read_source" {|{"path":"../../etc/passwd"}|});
    ("ping", call "ping" {||});
  ]

(* stdio: one session per connection, the legacy lifecycle enforced through it. *)
let over_stdio server =
  let session = Mcp_kit.Server.create_session server in
  List.map
    (fun (label, body) ->
      match Mcp_kit_stdio.serve_session_line_frames session body with
      | [] -> (label, None)
      | [ response ] -> (label, Some (Yojson.Safe.from_string response))
      | frames -> (label, Some (`List (List.map Yojson.Safe.from_string frames))))
    transcript

(* HTTP: stateless per POST, and a notification is answered 204 with an empty
   body — the one place the transports differ, and it is framing. *)
let over_http ~client ~uri =
  List.map
    (fun (label, body) ->
      Eio.Switch.run (fun sw ->
        let response, body = post ~sw client ~headers:(json_headers []) ~body uri in
        let status, text = read_response response body in
        if status <> 200 && status <> 204 then
          Alcotest.failf "%s: HTTP %d %S" label status text;
        (label, if text = "" then None else Some (Yojson.Safe.from_string text))))
    transcript

let show = function
  | None -> "<no body>"
  | Some json -> Yojson.Safe.to_string json

let same_transcript_stdio_and_http () =
  (* One server value, two transports: every answer is the same JSON, because
     nothing between [Registry.add] and the adapter knows which transport
     carried the call. *)
  with_server ~root:root_a (fun s ->
    let stdio = over_stdio s.server in
    let http = over_http ~client:s.client ~uri:s.uri in
    List.iter2
      (fun (label, stdio) (label', http) ->
        Alcotest.(check string) "same transcript entry" label label';
        match (stdio, http) with
        | Some stdio, Some http ->
            Alcotest.(check string)
              (label ^ " answers the same way")
              (Yojson.Safe.to_string stdio) (Yojson.Safe.to_string http)
        | None, None -> ()
        | _ ->
            Alcotest.failf "%s: stdio %s but HTTP %s" label (show stdio) (show http))
      stdio http)

let a_modern_call_answers_the_same_way_over_both_transports () =
  (* The 2026-07-28 request model needs no handshake on either transport, so the
     same body goes over stdio bare and over HTTP with the routing headers the
     adapter insists on. The answers are the same JSON, [_meta] server info
     included: what the headers buy is admission, not a different server. *)
  with_server ~root:root_a (fun s ->
    let body = modern_body "tools/call" "read_source" {|{"path":"answer.md"}|} in
    let stdio =
      match
        Mcp_kit_stdio.serve_session_line_frames (Mcp_kit.Server.create_session s.server) body
      with
      | [ response ] -> Yojson.Safe.from_string response
      | frames -> Alcotest.failf "stdio answered with %d frames" (List.length frames)
    in
    Eio.Switch.run (fun sw ->
      let response, http_body =
        post ~sw s.client ~headers:(modern_headers "tools/call" "read_source") ~body s.uri
      in
      let status, text = read_response response http_body in
      Alcotest.(check int) "200" 200 status;
      Alcotest.(check string)
        "the modern answer is the same JSON over both transports"
        (Yojson.Safe.to_string stdio) text))

let stdio_enforces_the_legacy_lifecycle_and_http_does_not () =
  (* A [tools/list] that arrives before [initialize]: the stdio session refuses
     it, the HTTP path has no session to refuse it with and answers the tool
     list. What the per-connection-authority question turns on is exactly this —
     the HTTP adapter never builds a session value. *)
  with_server ~root:root_a (fun s ->
    (match Mcp_kit_stdio.serve_session_line_frames (Mcp_kit.Server.create_session s.server) tools_list with
    | [ response ] ->
        Alcotest.(check bool) "stdio gates the call behind initialize: " true
          (contains response "server not initialized")
    | frames ->
        Alcotest.failf "stdio answered the un-initialized call with %d frames"
          (List.length frames));
    Eio.Switch.run (fun sw ->
      let response, body = post ~sw s.client ~headers:(json_headers []) ~body:tools_list s.uri in
      let status, text = read_response response body in
      Alcotest.(check int) "HTTP answers it" 200 status;
      Alcotest.(check bool) "and lists the registered tools: " true (contains text "read_source")))

(* {2 The bounds belong to the adapter} *)

let a_body_over_the_pinned_bound_is_refused_by_the_adapter () =
  (* [max_body_size] is the only thing this file supplies: the 413 with an empty
     body, and that the oversized body is never parsed, is mcp-kit's. *)
  let oversized = call "read_source" (Printf.sprintf {|{"path":%S}|} (String.make 400 'x')) in
  with_server ~root:root_a ~max_body_size:256 (fun s ->
    Eio.Switch.run (fun sw ->
      let response, body =
        post ~sw s.client ~headers:(json_headers []) ~body:oversized s.uri
      in
      let status, text = read_response response body in
      Alcotest.(check int) "413 from the adapter" 413 status;
      Alcotest.(check string) "no JSON body comes back" "" text))

let a_body_under_the_same_bound_still_works () =
  with_server ~root:root_a ~max_body_size:256 (fun s ->
    Eio.Switch.run (fun sw ->
      let response, body =
        post ~sw s.client ~headers:(json_headers [])
          ~body:(call "read_source" {|{"path":"answer.md"}|})
          s.uri
      in
      let status, text = read_response response body in
      Alcotest.(check int) "200" 200 status;
      Alcotest.(check bool) "answered from the grant: " true (contains text "from A")))

let a_modern_request_with_correct_headers_is_answered () =
  (* The adapter's modern path is what serves this server: routing headers
     validated by the library, the tool answered by our registry. *)
  with_server ~root:root_a (fun s ->
    Eio.Switch.run (fun sw ->
      let response, body =
        post ~sw s.client ~headers:(modern_headers "tools/call" "read_source")
          ~body:(modern_body "tools/call" "read_source" {|{"path":"answer.md"}|})
          s.uri
      in
      let status, text = read_response response body in
      Alcotest.(check int) "200" 200 status;
      Alcotest.(check bool) "answered from the grant: " true (contains text "from A")))

let a_modern_request_with_a_wrong_mcp_method_is_refused () =
  with_server ~root:root_a (fun s ->
    Eio.Switch.run (fun sw ->
      let response, body =
        post ~sw s.client ~headers:(modern_headers "tools/list" "read_source")
          ~body:(modern_body "tools/call" "read_source" {|{"path":"answer.md"}|})
          s.uri
      in
      let status, text = read_response response body in
      Alcotest.(check int) "400 from the adapter" 400 status;
      Alcotest.(check bool) "the adapter's own -32020: " true (contains text "-32020");
      Alcotest.(check bool) ("and no page content: " ^ text) false (contains text "from A")))

let an_unlisted_origin_and_a_get_are_refused () =
  (* Origin checking is the adapter's, and its default allowlist is empty; the
     rejection reaches [on_error] as [Rejected_origin], which the mli tells an
     application to expect rather than log as a fault. A GET never reaches the
     JSON-RPC dispatch either. And [allowed_origins] is an argument to
     [handler], so it belongs to a listener: the same request on a listener that
     lists that Origin is a 405, not a 403. *)
  with_server ~root:root_a ~rejections:1 (fun s ->
    Eio.Switch.run (fun sw ->
      let response, body =
        get ~sw s.client ~headers:(json_headers [("origin", "http://not-allowed.example")]) s.uri
      in
      let status, _ = read_response response body in
      Alcotest.(check int) "403 for an unlisted Origin" 403 status);
    Eio.Switch.run (fun sw ->
      let response, body = get ~sw s.client ~headers:(json_headers []) s.uri in
      let status, _ = read_response response body in
      Alcotest.(check int) "405 for GET" 405 status));
  with_server ~root:root_a ~allowed_origins:["http://not-allowed.example"] (fun s ->
    Eio.Switch.run (fun sw ->
      let response, body =
        get ~sw s.client ~headers:(json_headers [("origin", "http://not-allowed.example")]) s.uri
      in
      let status, _ = read_response response body in
      Alcotest.(check int) "the same request is a 405 once that Origin is listed" 405 status))

(* {2 Grants, per listener} *)

let two_listeners_do_not_share_a_grant () =
  (* The spike answer in test form: the grant set is a property of the server
     value the handler was built with, so what varies a grant today is the
     listener, not the client. Two listeners, two roots, one process. *)
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let listener_a = run_listener ~env ~sw (build_server ~sw env ~root:root_a) in
  let listener_b = run_listener ~env ~sw (build_server ~sw env ~root:root_b) in
  let client = Cohttp_eio.Client.make ~https:None env#net in
  Fun.protect
    ~finally:(fun () ->
      stop_listener listener_a;
      stop_listener listener_b)
    (fun () ->
      let read listener =
        Eio.Switch.run (fun sw ->
          let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/" listener.port) in
          let response, body =
            post ~sw client ~headers:(json_headers [])
              ~body:(call "read_source" {|{"path":"answer.md"}|})
              uri
          in
          let _, text = read_response response body in
          text)
      in
      let text_a = read listener_a in
      let text_b = read listener_b in
      Alcotest.(check bool) "listener A answers its own root" true (contains text_a "from A");
      Alcotest.(check bool) "listener A does not reach B" false (contains text_a "from B");
      Alcotest.(check bool) "listener B answers its own root" true (contains text_b "from B");
      Alcotest.(check bool) "listener B does not reach A" false (contains text_b "from A"));
  check_listener listener_a;
  check_listener listener_b

let one_listener_can_route_connections_to_different_grants () =
  (* The sharp half of the M2 spike. [Mcp_kit_cohttp_eio.handler] closes over one
     server value and its callback ignores the connection, so mcp-kit itself
     cannot vary a grant per client. But [Cohttp_eio.Server.callback] is public:
     it is the per-connection driver [Cohttp_eio.Server.run] calls, and an
     application that accepts connections itself — eight lines of
     [Eio.Net.run_server], which is what [Server.run] wraps — chooses which
     handler value owns that connection. One listening socket, two grants, chosen
     per connection.

     The choice here is by connection order, because that is all an accept-time
     decision can see: the peer address, and nothing about the caller. That is
     the limit worth recording, not the mechanism. *)
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let handlers =
    List.map
      (fun root ->
        Mcp_kit_cohttp_eio.handler ~max_body_size:4096 (build_server ~sw env ~root))
      [root_a; root_b]
  in
  let socket =
    Eio.Net.listen ~backlog:128 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> Alcotest.failf "unexpected unix socket: %s" path
  in
  let next = Atomic.make 0 in
  let stop, fill = Eio.Promise.create () in
  let stopped, fill_stopped = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Promise.resolve fill_stopped ())
      (fun () ->
        Eio.Net.run_server socket ~stop ~on_error:ignore (fun flow peer ->
          Eio.Switch.run (fun conn_sw ->
            let input = Eio.Buf_read.of_flow ~max_size:max_int flow in
            Eio.Buf_write.with_flow flow (fun output ->
              let chosen = Atomic.fetch_and_add next 0 in
              Atomic.set next (chosen + 1);
              Cohttp_eio.Server.callback (List.nth handlers (chosen mod 2)) (conn_sw, peer) input output)))));
  let client = Cohttp_eio.Client.make ~https:None env#net in
  let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/" port) in
  Fun.protect
    ~finally:(fun () ->
      Eio.Promise.resolve fill ();
      Eio.Promise.await stopped)
    (fun () ->
      (* One request per connection, run in order: the cohttp-eio client opens a
         fresh socket per call and closes it with its switch, so connection order
         is request order here. *)
      let read () =
        Eio.Switch.run (fun sw ->
          let response, body =
            post ~sw client ~headers:(json_headers [])
              ~body:(call "read_source" {|{"path":"answer.md"}|})
              uri
          in
          let _, text = read_response response body in
          text)
      in
      let first = read () in
      let second = read () in
      Alcotest.(check bool) "the first connection gets the first grant" true
        (contains first "from A");
      Alcotest.(check bool) "the second connection gets the second grant" true
        (contains second "from B");
      Alcotest.(check bool) "and neither reaches the other's file" false
        (contains first "from B" || contains second "from A"))

let concurrent_clients_do_not_mix_answers () =
  (* Two clients, one listener, one grant: interleaved calls — one a read, one a
     refusal — come back as their own answers. That is the concurrency half of
     §8 for a server-lifetime grant. *)
  with_server ~root:root_a (fun s ->
    let first = Atomic.make "" and second = Atomic.make "" in
    Eio.Fiber.all
      [
        (fun () ->
          Eio.Switch.run (fun sw ->
            let response, body =
              post ~sw s.client ~headers:(json_headers [])
                ~body:(call "read_source" {|{"path":"answer.md"}|})
                s.uri
            in
            let _, text = read_response response body in
            Atomic.set first text));
        (fun () ->
          Eio.Switch.run (fun sw ->
            let response, body =
              post ~sw s.client ~headers:(json_headers [])
                ~body:(call "read_source" {|{"path":"../../etc/passwd"}|})
                s.uri
            in
            let _, text = read_response response body in
            Atomic.set second text));
      ];
    let first = Atomic.get first and second = Atomic.get second in
    Alcotest.(check bool) "the read still answers its own file" true (contains first "from A");
    Alcotest.(check bool) "the walk is still refused" true (contains second "isError");
    Alcotest.(check bool) ("and the refusal carries no root path: " ^ second) false
      (contains second root_a))

let () =
  Alcotest.run "mcp-caps/http"
    [
      ( "parity",
        [
          Alcotest.test_case "the same transcript answers the same way over stdio and HTTP"
            `Quick same_transcript_stdio_and_http;
          Alcotest.test_case "a modern call answers the same way over both transports" `Quick
            a_modern_call_answers_the_same_way_over_both_transports;
          Alcotest.test_case "stdio enforces the legacy lifecycle and HTTP does not" `Quick
            stdio_enforces_the_legacy_lifecycle_and_http_does_not;
        ] );
      ( "bounds the adapter owns",
        [
          Alcotest.test_case "a body over the pinned bound is refused by the adapter" `Quick
            a_body_over_the_pinned_bound_is_refused_by_the_adapter;
          Alcotest.test_case "a body under the same bound still works" `Quick
            a_body_under_the_same_bound_still_works;
          Alcotest.test_case "a modern request with correct headers is answered" `Quick
            a_modern_request_with_correct_headers_is_answered;
          Alcotest.test_case "a modern request with a wrong Mcp-Method is refused" `Quick
            a_modern_request_with_a_wrong_mcp_method_is_refused;
          Alcotest.test_case "an unlisted Origin and a GET are refused" `Quick
            an_unlisted_origin_and_a_get_are_refused;
        ] );
      ( "grants per listener",
        [
          Alcotest.test_case "two listeners do not share a grant" `Quick
            two_listeners_do_not_share_a_grant;
          Alcotest.test_case "one listener can route connections to different grants" `Quick
            one_listener_can_route_connections_to_different_grants;
          Alcotest.test_case "concurrent clients do not mix answers" `Quick
            concurrent_clients_do_not_mix_answers;
        ] );
    ]
