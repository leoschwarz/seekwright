(* The narrow MCP client behind Exa and Parallel, driven against a real
   loopback fixture through a [Policy.with_endpoints] grant — the same fixture
   shape test_fetch_http.ml uses, for the same reason: the grant's own policy is
   pinned elsewhere, and what is pinned here is what the client adds on top.

   Port of the session cases of tests/providers/test_exa_tiers.py and the
   upstream-error cases of test_exa_mcp.py, plus the framing and lifecycle cases
   the port's streams needed. Every HTTP exchange is a discrete POST, so the
   fixture records what the client actually sent: the session header, the
   negotiated protocol version, the request ids, and whether a failure was
   retried. No provider endpoint is reached, and no case can bill anything.

   The failure cases are also leak cases: the fixture echoes a probe key in the
   bodies and headers it answers with, and every expectation renders the
   failure it got, so a body or a header reaching a provider error fails the
   case that produced it. *)

module Caps = Mcp_caps
module Provider = Seekwright.Provider
module Mcp = Seekwright_providers.Mcp_client
module Policy = Caps.Policy
module Authority = Caps.Authority
module Error = Caps.Error
module A = Alcotest
open Test_support

(* Never dialled, only echoed: it is the string a leak would carry. *)
let probe_key = "contract-probe-key-4c1f"

(* What the fixture negotiates, deliberately not the version the client asks
   for: a call that carries this value is one that read the handshake's answer. *)
let negotiated_version = "2099-01-01"

(* The fixture's slow route and the budget measured against it. *)
let slow_seconds = 1.0
let tight_budget_seconds = 0.2

(* {1 The fixture's record} *)

type recorded = {
  http_method : string;
  path : string;
  headers : (string * string) list;
  body : string;
  rpc_method : string option;
  rpc_id : int option;
}

type state = {
  mutable requests : recorded list;  (** Newest first. *)
  mutable deletes : recorded list;  (** Newest first. *)
  mutable session_count : int;
  mutable current_session : string option;
  mutable dead_once_fired : bool;
}

let fresh_state () =
  {
    requests = [];
    deletes = [];
    session_count = 0;
    current_session = None;
    dead_once_fired = false;
  }

let header_value headers name =
  let wanted = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) -> if String.lowercase_ascii key = wanted then Some value else None)
    headers

let member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let string_member key json =
  match member key json with Some (`String value) -> Some value | _ -> None

let int_member key json =
  match member key json with Some (`Int value) -> Some value | _ -> None

let json_of_body body =
  try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None

(* {1 The fixture's answers} *)

let respond ?(headers = []) ~status ~content_type body =
  Cohttp_eio.Server.respond_string
    ~headers:(Http.Header.of_list (("content-type", content_type) :: headers))
    ~status:(Http.Status.of_int status) ~body ()

let json ?headers ~status body = respond ?headers ~status ~content_type:"application/json" body
let sse ?headers ~status body = respond ?headers ~status ~content_type:"text/event-stream" body

let acknowledged () =
  Cohttp_eio.Server.respond_string ~status:(Http.Status.of_int 202) ~body:"" ()

let sse_frame json = "data: " ^ Yojson.Safe.to_string json ^ "\n\n"

let rpc_result ~id result =
  `Assoc [ ("jsonrpc", `String "2.0"); ("id", `Int id); ("result", result) ]

let rpc_error ~id ~code message =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", `Int id);
      ("error", `Assoc [ ("code", `Int code); ("message", `String message) ]);
    ]

let text_content ?(is_error = false) text =
  `Assoc
    [
      ("content", `List [ `Assoc [ ("type", `String "text"); ("text", `String text) ] ]);
      ("isError", `Bool is_error);
    ]

let initialize_result =
  `Assoc
    [
      ("protocolVersion", `String negotiated_version);
      ("capabilities", `Assoc []);
      ("serverInfo", `Assoc [ ("name", `String "fixture"); ("version", `String "0.0.0") ]);
    ]

let answer_json value = json ~status:200 (Yojson.Safe.to_string value)

let issue_session state =
  state.session_count <- state.session_count + 1;
  let id = Printf.sprintf "session-%d" state.session_count in
  state.current_session <- Some id;
  id

(* Every stateful route refuses a call whose session is not the one it issued,
   which is how the fixture notices a client that forgot the header instead of
   silently serving it. *)
let session_is_current state headers =
  match state.current_session with
  | None -> true
  | Some id -> header_value headers "mcp-session-id" = Some id

let is_sse path =
  List.mem path [ "/sse"; "/sse-progress"; "/oversized" ]

(* The one route table. [rpc_method] is [None] for a body that is not a
   JSON-RPC message, which is itself a case. *)
let handle ~state ~clock ~path ~http_method ~headers ~body_json =
  let rpc_method = Option.bind body_json (fun json -> string_member "method" json) in
  let rpc_id = Option.bind body_json (fun json -> int_member "id" json) in
  match http_method with
  | "DELETE" ->
      (* The specification's session termination; a server free to decline. *)
      Cohttp_eio.Server.respond_string ~status:(Http.Status.of_int 405) ~body:"" ()
  | _ -> (
      match (rpc_method, rpc_id) with
      | Some "initialize", Some id -> (
          match path with
          | "/handshake-500" -> json ~status:500 {|{"error":"no handshake today"}|}
          | "/handshake-garbage" -> json ~status:200 "<html>not a json-rpc message</html>"
          | "/handshake-rpc-error" -> answer_json (rpc_error ~id ~code:(-32_600) "bad initialize")
          | "/stall-init" ->
              Eio.Time.sleep clock slow_seconds;
              answer_json (rpc_result ~id initialize_result)
          | _ ->
              let headers =
                if path = "/json-stateless" then begin
                  state.current_session <- None;
                  []
                end
                else [ ("mcp-session-id", issue_session state) ]
              in
              let reply = rpc_result ~id initialize_result in
              if is_sse path then sse ~headers ~status:200 (sse_frame reply)
              else json ~headers ~status:200 (Yojson.Safe.to_string reply))
      | Some "notifications/initialized", None -> acknowledged ()
      | Some "tools/call", Some id -> (
          let ready =
            match path with
            | "/dead-once" | "/dead-twice" -> true
            | _ -> session_is_current state headers
          in
          if not ready then json ~status:404 {|{"error":"unknown session"}|}
          else
            let reply result = answer_json (rpc_result ~id result) in
            match path with
            | "/json" -> reply (text_content "parallel answer")
            | "/json-stateless" -> reply (text_content "stateless answer")
            | "/sse" -> sse ~status:200 (sse_frame (rpc_result ~id (text_content "streamed answer")))
            | "/sse-progress" ->
                let progress =
                  `Assoc
                    [
                      ("jsonrpc", `String "2.0");
                      ("method", `String "notifications/progress");
                      ("params", `Assoc []);
                    ]
                in
                sse ~status:200
                  (sse_frame progress ^ sse_frame (rpc_result ~id (text_content "after progress")))
            | "/iserror-quota" ->
                reply
                  (text_content ~is_error:true
                     "web_search_exa error (429): rate limit exceeded for this key")
            | "/iserror-key" ->
                reply
                  (text_content ~is_error:true
                     ("web_search_exa error (401): Invalid API key " ^ probe_key))
            | "/iserror-generic" ->
                reply (text_content ~is_error:true "the tool failed while reading something")
            | "/malformed" -> json ~status:200 "not a json document"
            | "/oversized" ->
                sse ~status:200 (sse_frame (rpc_result ~id (text_content (String.make 4096 'x'))))
            | "/oversized-json" ->
                reply (text_content (String.make 4096 'y'))
            | "/status-401" ->
                json ~status:401 (Printf.sprintf {|{"message":"invalid API key: %s"}|} probe_key)
            | "/dead-once" ->
                if state.dead_once_fired then reply (text_content "reconnected")
                else begin
                  state.dead_once_fired <- true;
                  state.current_session <- None;
                  json ~status:404 {|{"error":"session expired"}|}
                end
            | "/dead-twice" -> json ~status:404 {|{"error":"session expired"}|}
            | "/stall-tool" ->
                Eio.Time.sleep clock slow_seconds;
                reply (text_content "late")
            | "/close" -> reply (text_content "closed route")
            | "/concurrent" ->
                let text =
                  Option.bind body_json (fun json ->
                      Provider.Json.field "params" json |> Provider.Json.field "arguments"
                      |> Provider.Json.string_field "q")
                  |> Option.value ~default:""
                in
                reply (text_content text)
            | _ -> json ~status:404 {|{"error":"no such route"}|})
      | _ -> json ~status:400 {|{"error":"not a json-rpc message"}|})

let fixture ~state ~clock _env request body =
  let resource = Http.Request.resource request in
  let path =
    match String.index_opt resource '?' with
    | Some i -> String.sub resource 0 i
    | None -> resource
  in
  let headers = Http.Header.to_list (Http.Request.headers request) in
  let http_method = Http.Method.to_string (Http.Request.meth request) in
  let body =
    try Eio.Buf_read.(take_all (of_flow ~max_size:1_000_000 body)) with End_of_file -> ""
  in
  let body_json = json_of_body body in
  let recorded =
    {
      http_method;
      path;
      headers;
      body;
      rpc_method = Option.bind body_json (fun json -> string_member "method" json);
      rpc_id = Option.bind body_json (fun json -> int_member "id" json);
    }
  in
  if http_method = "DELETE" then state.deletes <- recorded :: state.deletes
  else state.requests <- recorded :: state.requests;
  handle ~state ~clock ~path ~http_method ~headers ~body_json

(* {1 Reading back what the client sent} *)

let rpc_requests state meth =
  List.filter (fun recorded -> recorded.rpc_method = Some meth) state.requests
  |> List.rev

let count_rpc state meth = List.length (rpc_requests state meth)

let only_rpc label state meth =
  match rpc_requests state meth with
  | [ one ] -> one
  | many -> A.failf "%s: expected one %s request, saw %d" label meth (List.length many)

(* {1 The harness} *)

let with_client ?auth ?max_frame_bytes ?max_events ?timeout ?(provider = "exa") ~path f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~backlog:16 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> Alcotest.failf "unix socket fixture: %s" path
  in
  let state = fresh_state () in
  let clock = Eio.Stdenv.clock env in
  let server = Cohttp_eio.Server.make ~callback:(fixture ~state ~clock) () in
  let stop, fill_stop = Eio.Promise.create () in
  let stopped, fill_stopped = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Fun.protect
        ~finally:(fun () -> Eio.Promise.resolve fill_stopped ())
        (fun () -> Cohttp_eio.Server.run ~stop ~on_error:(fun _exn -> ()) socket server));
  Fun.protect
    ~finally:(fun () ->
      Eio.Promise.resolve fill_stop ();
      Eio.Promise.await stopped)
    (fun () ->
      let endpoint : Policy.endpoint =
        { Policy.scheme = `Http; host = "127.0.0.1"; port = Some port }
      in
      match Policy.with_endpoints ~sw ~net:env#net ~max_response_bytes:1_000_000 [ endpoint ] with
      | Error error -> Alcotest.failf "with_endpoints: %s" (Error.render error)
      | Ok decision ->
          let grant =
            Authority.Net.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) decision
          in
          let grant =
            match timeout with
            | None -> grant
            | Some seconds ->
                Authority.with_operation_timeout
                  (Eio.Time.Timeout.seconds (Eio.Stdenv.mono_clock env) seconds)
                  grant
          in
          let client =
            Mcp.create ?auth ?max_frame_bytes ?max_events ~provider
              ~net:(Provider.Net.of_grant grant)
              ~uri:(Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path))
              ()
          in
          Fun.protect ~finally:(fun () -> Mcp.aclose client) (fun () -> f client state))

(* {1 Expectations} *)

let kind_testable =
  let show = function Provider.Failure -> "failure" | Provider.Quota -> "quota" in
  A.testable (fun fmt kind -> Format.pp_print_string fmt (show kind)) ( = )

let ok_text label = function
  | Ok tool -> tool.Mcp.text
  | Error error -> A.failf "%s: expected a result, got %s" label (Provider.render_error error)

let expect_failure ?(kind = Provider.Failure) ?message ?(retryable = true) ?(forbidden = [])
    ?(provider = "exa") label result =
  match result with
  | Ok _ -> A.failf "%s: expected an error, got a result" label
  | Error (error : Provider.error) ->
      A.check kind_testable (label ^ ": kind") kind error.kind;
      A.check A.string (label ^ ": provider") provider error.provider;
      A.check A.bool (label ^ ": retryable") retryable error.retryable;
      (match message with
      | Some expected -> A.check A.string (label ^ ": message") expected error.message
      | None -> ());
      let rendered = Provider.render_error error in
      List.iter
        (fun needle ->
          if contains ~haystack:rendered ~needle then
            A.failf "%s: the failure leaked %S: %S" label needle rendered)
        forbidden;
      ignore error

(* {1 Framing: a JSON body, an SSE body, and the frames a call may skip} *)

let test_a_json_answer_is_read () =
  with_client ~path:"/json" (fun client state ->
      let text =
        ok_text "call"
          (Mcp.call_tool client ~name:"web_search" ~arguments:(`Assoc [ ("q", `String "wal") ]))
      in
      A.check A.string "text" "parallel answer" text;
      let handshake = only_rpc "handshake" state "initialize" in
      A.check (A.option A.string) "initialize names the protocol" (Some "2025-06-18")
        (Option.bind (json_of_body handshake.body) (fun json ->
             string_member "protocolVersion" (Provider.Json.field "params" json)));
      let notification = only_rpc "notification" state "notifications/initialized" in
      A.check (A.option A.int) "the notification has no id" None notification.rpc_id;
      A.check (A.option A.string) "the notification carries the session" (Some "session-1")
        (header_value notification.headers "mcp-session-id");
      let call = only_rpc "call" state "tools/call" in
      A.check (A.option A.string) "the call carries the session" (Some "session-1")
        (header_value call.headers "mcp-session-id");
      A.check (A.option A.string) "the call carries the negotiated version"
        (Some negotiated_version)
        (header_value call.headers "mcp-protocol-version");
      A.check (A.option A.string) "the call asks for both framings" (Some "application/json, text/event-stream")
        (header_value call.headers "accept");
      A.check A.int "one handshake" 1 (count_rpc state "initialize"))

let test_an_sse_answer_is_read () =
  with_client ~path:"/sse" (fun client _state ->
      let text =
        ok_text "call" (Mcp.call_tool client ~name:"web_search_exa" ~arguments:(`Assoc []))
      in
      A.check A.string "text" "streamed answer" text)

let test_frames_without_the_calls_id_are_skipped () =
  with_client ~path:"/sse-progress" (fun client _state ->
      let text =
        ok_text "call" (Mcp.call_tool client ~name:"web_search_exa" ~arguments:(`Assoc []))
      in
      A.check A.string "text" "after progress" text)

let test_a_stateless_endpoint_is_accepted () =
  with_client ~path:"/json-stateless" (fun client state ->
      let text =
        ok_text "call" (Mcp.call_tool client ~name:"web_search" ~arguments:(`Assoc []))
      in
      A.check A.string "text" "stateless answer" text;
      let call = only_rpc "call" state "tools/call" in
      A.check (A.option A.string) "no session header" None
        (header_value call.headers "mcp-session-id"))

(* {1 The handshake} *)

let test_a_refused_handshake_is_reported_and_not_stored () =
  with_client ~path:"/handshake-500" (fun client state ->
      expect_failure ~message:"MCP handshake failed" "refused" (Mcp.connect client);
      (* A failed handshake stores no session, so the next attempt handshakes
         again rather than believing it is connected. *)
      expect_failure ~message:"MCP handshake failed" "refused again" (Mcp.connect client);
      A.check A.int "two handshakes" 2 (count_rpc state "initialize");
      A.check A.int "no tool calls" 0 (count_rpc state "tools/call"))

let test_a_garbage_handshake_body_is_a_handshake_failure () =
  with_client ~path:"/handshake-garbage" (fun client state ->
      expect_failure ~message:"MCP handshake failed" "garbage" (Mcp.connect client);
      A.check A.int "nothing further was sent" 0 (count_rpc state "tools/call"))

let test_a_handshake_answer_with_an_rpc_error_is_a_handshake_failure () =
  with_client ~path:"/handshake-rpc-error" (fun client _state ->
      expect_failure ~message:"MCP handshake failed" "rpc error" (Mcp.connect client))

let test_a_handshake_timeout_names_its_own_sentence () =
  with_client ~path:"/stall-init" ~timeout:tight_budget_seconds (fun client _state ->
      expect_failure ~message:"MCP handshake timed out" "handshake timeout" (Mcp.connect client))

(* {1 Tool results} *)

let test_a_quota_shaped_tool_error_is_the_quota_row () =
  with_client ~path:"/iserror-quota" (fun client state ->
      expect_failure ~kind:Provider.Quota ~message:"rate limited" ~retryable:false "quota"
        (Mcp.call_tool client ~name:"web_search_exa" ~arguments:(`Assoc []));
      A.check A.int "a valid tool error is not retried" 1 (count_rpc state "tools/call"))

let test_an_exa_invalid_key_is_a_tool_error_without_the_upstream_text () =
  with_client ~path:"/iserror-key" (fun client state ->
      expect_failure ~message:"upstream MCP tool reported an error"
        ~forbidden:[ probe_key; "Invalid API key"; "401" ] "invalid key"
        (Mcp.call_tool client ~name:"web_search_exa" ~arguments:(`Assoc []));
      A.check A.int "a valid tool error is not retried" 1 (count_rpc state "tools/call"))

let test_any_other_tool_error_is_one_fixed_sentence () =
  with_client ~path:"/iserror-generic" (fun client state ->
      expect_failure ~message:"upstream MCP tool reported an error"
        ~forbidden:[ "reading something" ] "generic"
        (Mcp.call_tool client ~name:"web_search" ~arguments:(`Assoc []));
      A.check A.int "a valid tool error is not retried" 1 (count_rpc state "tools/call"))

let test_an_authentication_status_is_the_auth_row () =
  with_client ~path:"/status-401" (fun client state ->
      expect_failure ~message:"authentication rejected (check API key)" ~retryable:false
        ~forbidden:[ probe_key ] "auth"
        (Mcp.call_tool client ~name:"web_search_exa" ~arguments:(`Assoc []));
      A.check A.int "a status failure is not retried" 1 (count_rpc state "tools/call"))

(* {1 Bounds} *)

let test_a_body_that_is_not_json_is_malformed () =
  with_client ~path:"/malformed" (fun client _state ->
      expect_failure ~message:"malformed MCP response" "malformed"
        (Mcp.call_tool client ~name:"web_search" ~arguments:(`Assoc [])))

let test_an_sse_frame_over_the_bound_is_refused () =
  with_client ~path:"/oversized" ~max_frame_bytes:1024 (fun client _state ->
      expect_failure ~message:"MCP response exceeded its frame bound" "oversized sse"
        (Mcp.call_tool client ~name:"web_search_exa" ~arguments:(`Assoc [])))

let test_a_json_body_over_the_bound_is_refused () =
  with_client ~path:"/oversized-json" ~max_frame_bytes:1024 (fun client _state ->
      expect_failure ~message:"MCP response exceeded its frame bound" "oversized json"
        (Mcp.call_tool client ~name:"web_search" ~arguments:(`Assoc [])))

(* {1 Session lifecycle} *)

let test_concurrent_calls_get_distinct_ids () =
  with_client ~path:"/concurrent" (fun client state ->
      (match Mcp.connect client with
      | Ok () -> ()
      | Error error -> A.failf "connect: %s" (Provider.render_error error));
      let answer question =
        ok_text question
          (Mcp.call_tool client ~name:"web_search"
             ~arguments:(`Assoc [ ("q", `String question) ]))
      in
      let left = ref "" and right = ref "" in
      Eio.Fiber.both
        (fun () -> left := answer "alpha")
        (fun () -> right := answer "beta");
      A.check A.string "the first call's answer" "alpha" !left;
      A.check A.string "the second call's answer" "beta" !right;
      let ids =
        rpc_requests state "tools/call" |> List.filter_map (fun recorded -> recorded.rpc_id)
      in
      A.check A.int "two calls" 2 (List.length ids);
      A.check A.int "distinct ids" 2 (List.length (List.sort_uniq Stdlib.compare ids));
      A.check A.int "one handshake for both" 1 (count_rpc state "initialize"))

let test_a_dead_session_is_reconnected_exactly_once () =
  with_client ~path:"/dead-once" (fun client state ->
      let text =
        ok_text "reconnect"
          (Mcp.call_tool client ~name:"web_search_exa" ~arguments:(`Assoc []))
      in
      A.check A.string "the retried call answered" "reconnected" text;
      A.check A.int "two handshakes" 2 (count_rpc state "initialize");
      let calls = rpc_requests state "tools/call" in
      A.check A.int "two call attempts" 2 (List.length calls);
      A.check (A.option A.string) "the first attempt used the old session" (Some "session-1")
        (header_value (List.nth calls 0).headers "mcp-session-id");
      A.check (A.option A.string) "the retry used the new one" (Some "session-2")
        (header_value (List.nth calls 1).headers "mcp-session-id"))

let test_a_second_dead_session_is_unavailable () =
  with_client ~path:"/dead-twice" (fun client state ->
      expect_failure ~message:"MCP session unavailable" "dead twice"
        (Mcp.call_tool client ~name:"web_search_exa" ~arguments:(`Assoc []));
      A.check A.int "two handshakes" 2 (count_rpc state "initialize");
      A.check A.int "two call attempts" 2 (count_rpc state "tools/call"))

let test_a_tool_timeout_is_not_retried () =
  with_client ~path:"/stall-tool" ~timeout:tight_budget_seconds (fun client state ->
      expect_failure ~message:"request timed out" "tool timeout"
        (Mcp.call_tool client ~name:"web_search_exa" ~arguments:(`Assoc []));
      A.check A.int "one handshake" 1 (count_rpc state "initialize");
      A.check A.int "the timeout is not retried" 1 (count_rpc state "tools/call"))

let test_close_marks_the_client_and_terminates_the_session () =
  with_client ~path:"/close" (fun client state ->
      let _ =
        ok_text "call" (Mcp.call_tool client ~name:"web_search" ~arguments:(`Assoc []))
      in
      Mcp.aclose client;
      A.check A.int "one delete" 1 (List.length state.deletes);
      let delete = List.hd state.deletes in
      A.check A.string "the delete method" "DELETE" delete.http_method;
      A.check A.string "the delete reaches the endpoint" "/close" delete.path;
      A.check (A.option A.string) "the delete names the session" (Some "session-1")
        (header_value delete.headers "mcp-session-id");
      expect_failure ~message:"MCP client is closed" "closed"
        (Mcp.call_tool client ~name:"web_search" ~arguments:(`Assoc []));
      (* Closing twice is a no-op, and a closed client handshakes no more. *)
      Mcp.aclose client;
      A.check A.int "still one delete" 1 (List.length state.deletes);
      A.check A.int "no extra handshake" 1 (count_rpc state "initialize"))

let () =
  A.run "mcp_client"
    [
      ( "framing",
        [
          A.test_case "a JSON answer is read" `Quick test_a_json_answer_is_read;
          A.test_case "an SSE answer is read" `Quick test_an_sse_answer_is_read;
          A.test_case "frames without the call's id are skipped" `Quick
            test_frames_without_the_calls_id_are_skipped;
          A.test_case "a stateless endpoint is accepted" `Quick
            test_a_stateless_endpoint_is_accepted;
        ] );
      ( "handshake",
        [
          A.test_case "a refused handshake is reported and not stored" `Quick
            test_a_refused_handshake_is_reported_and_not_stored;
          A.test_case "a garbage body is a handshake failure" `Quick
            test_a_garbage_handshake_body_is_a_handshake_failure;
          A.test_case "an rpc error is a handshake failure" `Quick
            test_a_handshake_answer_with_an_rpc_error_is_a_handshake_failure;
          A.test_case "a handshake timeout names its own sentence" `Quick
            test_a_handshake_timeout_names_its_own_sentence;
        ] );
      ( "tool results",
        [
          A.test_case "a quota-shaped tool error is the quota row" `Quick
            test_a_quota_shaped_tool_error_is_the_quota_row;
          A.test_case "an Exa invalid key is a tool error without its text" `Quick
            test_an_exa_invalid_key_is_a_tool_error_without_the_upstream_text;
          A.test_case "any other tool error is one fixed sentence" `Quick
            test_any_other_tool_error_is_one_fixed_sentence;
          A.test_case "an authentication status is the auth row" `Quick
            test_an_authentication_status_is_the_auth_row;
        ] );
      ( "bounds",
        [
          A.test_case "a body that is not json is malformed" `Quick
            test_a_body_that_is_not_json_is_malformed;
          A.test_case "an SSE frame over the bound is refused" `Quick
            test_an_sse_frame_over_the_bound_is_refused;
          A.test_case "a JSON body over the bound is refused" `Quick
            test_a_json_body_over_the_bound_is_refused;
        ] );
      ( "session lifecycle",
        [
          A.test_case "concurrent calls get distinct ids" `Quick
            test_concurrent_calls_get_distinct_ids;
          A.test_case "a dead session is reconnected exactly once" `Quick
            test_a_dead_session_is_reconnected_exactly_once;
          A.test_case "a second dead session is unavailable" `Quick
            test_a_second_dead_session_is_unavailable;
          A.test_case "a tool timeout is not retried" `Quick
            test_a_tool_timeout_is_not_retried;
          A.test_case "close marks the client and terminates the session" `Quick
            test_close_marks_the_client_and_terminates_the_session;
        ] );
    ]
