(* P8: the server module — the three tools through the capability registry, the
   HTTP custom routes behind the Host allowlist, and the frozen-surface data
   [ocaml-tools/surface.ml] prints. The app is built directly from stub
   providers (the [Provider.S] packaged modules, as in [test_engine.ml]); no
   transport and no network is involved. *)

module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Registry = Mcp_caps.Registry
module CapsServer = Mcp_caps.Server
module Server = Seekwright.Server
module Usage = Seekwright.Usage
module Agent = Seekwright.Agent
module A = Alcotest

let check_string = A.(check string)
let check_int = A.(check int)
let check_bool = A.(check bool)

let contains text needle =
  let n = String.length text and m = String.length needle in
  let rec from i =
    if i + m > n then false
    else if String.sub text i m = needle then true
    else from (i + 1)
  in
  from 0

(* {1 Fixtures} *)

let clock () = 1.0
let now () = 1_700_000_000.0
let no_log _level _event _fields = ()

type stub = {
  name : string;
  mutable behavior : Model.search_query -> (Provider.outcome, Provider.error) result;
}

let stub ?(name = "serper") ?fail () =
  let s = { name; behavior = fun _ -> assert false } in
  s.behavior <-
    (fun q ->
      match fail with
      | Some failure -> Error failure
      | None ->
        Ok
          {
            Provider.provider = s.name;
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
          });
  s

let provider (s : stub) : Provider.t =
  (module struct
    let name = s.name
    let cost_per_1k = 1.0
    let cost_for n = float_of_int n /. 1000.
    let search q = s.behavior q
    let aclose () = ()
  end : Provider.S)

let config ?(dashboard = false) providers =
  match
    Config.resolve
      ~providers:
        (List.map (fun name -> (name, { Config.default_provider_config with Config.enabled = true })) providers)
      ~dashboard:
        { Config.default_dashboard_config with Config.enabled = dashboard }
      ()
  with
  | Ok config -> config
  | Error message -> A.failf "the fixture config was refused: %s" message

let usage () =
  match Usage.create ~now () with Ok u -> u | Error message -> A.failf "%s" message

let fetch_engine config =
  let fetcher =
    {
      Engine.Fetch.name = "http";
      cost_per_1k = None;
      fetch =
        (fun ~url ~offset:_ ~max_chars:_ ->
          Ok
            {
              Engine.Fetch.url;
              title = Some "A page";
              text = "page text";
              content_type = Some "text/html";
              status_code = 200;
              truncated = false;
              total_chars = 9;
              path_addressable = false;
              image = None;
            });
      aclose = (fun () -> ());
    }
  in
  let readers =
    {
      Engine.Fetch.Readers.parse_path = (fun _ -> Ok ());
      render_schema = (fun _ -> None);
      select_paths = (fun ~text:_ ~path:_ ~max_chars:_ -> ([], 0));
      select_passages = (fun ~text:_ ~query:_ ~max_chars:_ -> ([], 0));
    }
  in
  match Engine.Fetch.create config fetcher ~readers ~clock ~now () with
  | Ok engine -> engine
  | Error message -> A.failf "the fixture fetch engine was refused: %s" message

let make_app ?(stubs = [ stub () ]) ?(fetch = true) ?(agent = false) ?(dashboard = false) providers
    : Server.app =
  let config = config ~dashboard providers in
  let search =
    Engine.Search.create config (List.map (fun s -> (s.name, provider s)) stubs) ~clock ~now ()
  in
  let usage = usage () in
  let fetch_engine = if fetch then Some (fetch_engine config) else None in
  let agent_engine =
    if agent then
      let net =
        {
          Provider.Net.request =
            (fun _request ->
              Error (Mcp_caps.Error.make Mcp_caps.Error.Unavailable ~message:"no model configured"));
        }
      in
      Some (Agent.create config ~net search ~usage ~log:no_log ~clock ~now ())
    else None
  in
  {
    Server.config;
    search;
    usage;
    fetch = fetch_engine;
    agent = agent_engine;
    started_at = 40.0;
    mono_now = (fun () -> 42.5);
    allowed_hosts = [];
    health = None;
  }

let default_app () = make_app [ "serper" ]

(* {1 JSON helpers} *)

let field key = function
  | `Assoc fields -> ( match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

let dispatch server line =
  match Mcp_kit.Server.dispatch_string server line with
  | Some response -> Yojson.Safe.from_string response
  | None -> `Null

let result_of response = field "result" response
let is_error response = match field "isError" (result_of response) with `Bool b -> b | _ -> false

let text_of response =
  match field "content" (result_of response) with
  | `List [ block ] -> ( match field "text" block with `String t -> t | _ -> "")
  | _ -> ""

let mcp app =
  match Server.mcp_server app with
  | Error (CapsServer.Duplicate_tool name) -> A.failf "duplicate tool: %s" name
  | Error (CapsServer.Invalid_declaration message) -> A.failf "invalid declaration: %s" message
  | Ok server -> server

(* {1 The registry and the tools} *)

let registry_lists_the_three_tools _ =
  let app = default_app () in
  match Server.registry app with
  | Error (Registry.Duplicate_tool name) -> A.failf "duplicate: %s" name
  | Ok registry ->
      let names = List.map Registry.entry_name (Registry.entries registry) in
      A.(check (list string)) "registration order" [ "search"; "fetch"; "answer" ] names

let tools_list_advertises_the_freeze _ =
  let server = mcp (default_app ()) in
  let listed = dispatch server {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}|} in
  let tools =
    match field "tools" (result_of listed) with `List tools -> tools | _ -> []
  in
  let names =
    List.map (fun tool -> match field "name" tool with `String n -> n | _ -> "") tools
  in
  A.(check (list string)) "the three tools" [ "search"; "fetch"; "answer" ] names;
  let by_name name = List.find (fun tool -> field "name" tool = `String name) tools in
  let required tool =
    match field "required" (field "inputSchema" tool) with
    | `List items -> List.map (fun i -> match i with `String s -> s | _ -> "") items
    | _ -> []
  in
  A.(check (list string)) "search requires query" [ "query" ] (required (by_name "search"));
  A.(check (list string)) "fetch requires url" [ "url" ] (required (by_name "fetch"));
  A.(check (list string)) "answer requires query" [ "query" ] (required (by_name "answer"))

let the_surface_data_matches_the_freeze _ =
  let sorted = List.sort compare in
  A.(check (list (pair string (list string))))
    "tools and params"
    [
      ( "answer",
        [
          "query"; "extra_queries"; "depth"; "provider"; "include_domains"; "exclude_domains";
          "recency"; "language"; "safe_search";
        ] );
      ("fetch", [ "url"; "offset"; "query"; "path"; "provider"; "structure" ]);
      ( "search",
        [
          "query"; "provider"; "mode"; "max_results"; "include_domains"; "exclude_domains";
          "recency"; "language"; "safe_search";
        ] );
    ]
    Server.tools_surface;
  let route (m, p, model_name, keys) = (m ^ " " ^ p, model_name, keys) in
  A.(check (list (triple string string (list string))))
    "rest routes"
    [
      ( "POST /api/v1/answer",
        "AnswerRequest",
        sorted
          [
            "query"; "extra_queries"; "depth"; "provider"; "include_domains"; "exclude_domains";
            "recency"; "language"; "safe_search";
          ] );
      ( "POST /api/v1/fetch",
        "FetchRequest",
        sorted [ "url"; "offset"; "query"; "path"; "provider"; "structure" ] );
      ( "POST /api/v1/search",
        "SearchRequest",
        sorted
          [
            "query"; "provider"; "mode"; "max_results"; "include_domains"; "exclude_domains";
            "recency"; "language"; "safe_search";
          ] );
    ]
    (List.map route Server.rest_routes);
  A.(check (list (pair string string)))
    "operational routes"
    [
      ("GET", "/dashboard");
      ("GET", "/dashboard/data");
      ("GET", "/dashboard/metrics");
      ("GET", "/healthz");
    ]
    Server.operational_routes;
  A.(check (list string)) "client verbs" [ "answer"; "fetch"; "search" ] Server.cli_verbs;
  A.(check (list string))
    "server flags"
    [
      "--check"; "--live"; "--metrics"; "--json"; "--http"; "--host"; "--port"; "--allowed-host";
      "--log-level"; "--log-format";
    ]
    Server.server_flags

let a_search_call_answers_over_the_registry _ =
  let server = mcp (default_app ()) in
  let called =
    dispatch server
      {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"ocaml effects","max_results":2}}}|}
  in
  check_bool "not an error" false (is_error called);
  let text = text_of called in
  check_bool "the answer names the provider that served" true (contains text "serper");
  check_bool "the answer carries the hit" true (contains text "Result for ocaml effects")

let a_refused_search_is_a_tool_result _ =
  let server = mcp (default_app ()) in
  let called =
    dispatch server
      {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"anything here","provider":"no-such-provider"}}}|}
  in
  check_bool "isError is set" true (is_error called);
  check_bool "no JSON-RPC error" false (field "error" called <> `Null)

let a_failed_search_is_a_tool_result _ =
  let s = stub ~fail:(Provider.provider_error ~provider:"serper" "HTTP 500") () in
  let server = mcp (make_app ~stubs:[ s ] [ "serper" ]) in
  let called =
    dispatch server
      {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"anything here"}}}|}
  in
  check_bool "isError is set" true (is_error called)

let fetch_disabled_refuses_cleanly _ =
  let server = mcp (make_app ~fetch:false [ "serper" ]) in
  let called =
    dispatch server
      {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fetch","arguments":{"url":"https://example.com/"}}}|}
  in
  check_bool "isError is set" true (is_error called);
  check_bool "the sentence is the shared one" true
    (contains (text_of called) Server.fetch_disabled)

let agent_disabled_refuses_cleanly _ =
  let server = mcp (default_app ()) in
  let called =
    dispatch server
      {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"answer","arguments":{"query":"what is eio?"}}}|}
  in
  check_bool "isError is set" true (is_error called);
  check_bool "the sentence is the shared one" true
    (contains (text_of called) Server.agent_disabled)

(* {1 The Host allowlist} *)

let the_host_allowlist_matches_python _ =
  let entries = Server.host_allowlist [ "search.internal:9000"; "wild.example:*" ] in
  check_bool "loopback name" true (Server.is_host_allowed entries "localhost");
  check_bool "loopback name with a port" true (Server.is_host_allowed entries "localhost:8000");
  check_bool "loopback ip with a port" true (Server.is_host_allowed entries "127.0.0.1:8000");
  check_bool "ipv6 loopback with a port" true (Server.is_host_allowed entries "[::1]:8000");
  check_bool "an operator host with its port" true (Server.is_host_allowed entries "search.internal:9000");
  check_bool "a wildcard entry matches any port" true (Server.is_host_allowed entries "wild.example:1234");
  check_bool "a foreign name is refused" false (Server.is_host_allowed entries "evil.example.com");
  check_bool "the wrong port on an exact entry is refused" false
    (Server.is_host_allowed entries "search.internal:9001")

(* {1 The custom routes} *)

let healthz_is_secret_free_and_exempt _ =
  let app = default_app () in
  let ok = Server.handle_custom app ~meth:"GET" ~path:"/healthz" ~host:None ~origin:None ~body:"" in
  check_int "status" 200 ok.Server.status;
  let body = Yojson.Safe.from_string ok.Server.body in
  check_string "status field" "ok" (match field "status" body with `String s -> s | _ -> "");
  check_bool "names the enabled providers" true
    (match field "providers" body with `List [ `String "serper" ] -> true | _ -> false);
  check_string "the default provider" "serper"
    (match field "default_provider" body with `String s -> s | _ -> "");
  check_int "uptime is whole seconds" 2
    (match field "uptime_s" body with `Int n -> n | _ -> -1);
  check_bool "no key or secret field is present" false
    (contains ok.Server.body "api_key" || contains ok.Server.body "key");
  (* A configured name this build has no adapter for is not a provider it has:
     /healthz reports the dispatchable set, and the startup warning names the
     rest. *)
  let undeployable = make_app [ "serper"; "exa:free" ] in
  let body =
    Yojson.Safe.from_string
      (Server.handle_custom undeployable ~meth:"GET" ~path:"/healthz" ~host:None
         ~origin:None ~body:"")
        .Server.body
  in
  check_bool "an unbuilt configured name is not advertised" true
    (match field "providers" body with `List [ `String "serper" ] -> true | _ -> false);
  (* A kubelet probes with the pod IP in Host; /healthz must still answer. *)
  let probed =
    Server.handle_custom app ~meth:"GET" ~path:"/healthz" ~host:(Some "10.0.0.5") ~origin:None ~body:""
  in
  check_int "the probe is not refused" 200 probed.Server.status

let guarded_routes_refuse_a_foreign_host _ =
  let app = default_app () in
  let denied =
    Server.handle_custom app ~meth:"POST" ~path:"/api/v1/search" ~host:(Some "evil.example.com")
      ~origin:None ~body:{|{"query":"ocaml effects"}|}
  in
  check_int "421" 421 denied.Server.status;
  check_string "the plain-text body" "Invalid Host header" denied.Server.body;
  let no_host =
    Server.handle_custom app ~meth:"POST" ~path:"/api/v1/search" ~host:None ~origin:None
      ~body:{|{"query":"ocaml effects"}|}
  in
  check_int "a missing Host is refused too" 421 no_host.Server.status;
  let denied_dash =
    Server.handle_custom app ~meth:"GET" ~path:"/dashboard" ~host:(Some "evil.example.com") ~origin:None
      ~body:""
  in
  check_int "the dashboard is guarded too" 421 denied_dash.Server.status;
  let mcp_is_guarded_at_the_same_layer =
    Server.handle_custom app ~meth:"POST" ~path:"/mcp" ~host:(Some "evil.example.com") ~origin:None ~body:""
  in
  check_int "any non-healthz path is guarded" 421 mcp_is_guarded_at_the_same_layer.Server.status

let origins_are_checked_against_the_allowlist _ =
  let app = default_app () in
  let call origin =
    Server.handle_custom app ~meth:"POST" ~path:"/api/v1/search" ~host:(Some "localhost")
      ~origin ~body:{|{"query":"ocaml effects"}|}
  in
  check_int "a foreign origin is 403" 403 (call (Some "https://evil.example.com")).Server.status;
  check_int "a loopback origin is fine" 200 (call (Some "http://localhost")).Server.status;
  check_int "no origin header is fine" 200 (call None).Server.status

let an_oversized_body_is_413 _ =
  let app = default_app () in
  let big = String.make (Server.max_body_size + 1) 'a' in
  let refused =
    Server.handle_custom app ~meth:"POST" ~path:"/api/v1/search" ~host:(Some "localhost") ~origin:None
      ~body:big
  in
  check_int "413" 413 refused.Server.status

let api_search_round_trip _ =
  let app = default_app () in
  let ok =
    Server.handle_custom app ~meth:"POST" ~path:"/api/v1/search" ~host:(Some "127.0.0.1:8000")
      ~origin:None ~body:{|{"query":"ocaml effects","max_results":2}|}
  in
  check_int "200" 200 ok.Server.status;
  let body = Yojson.Safe.from_string ok.Server.body in
  check_string "the provider that served" "serper"
    (match field "provider" body with `String s -> s | _ -> "");
  check_int "the hit count" 1
    (match field "results" body with `List l -> List.length l | _ -> -1);
  check_bool "the hit is there" true
    (contains ok.Server.body "Result for ocaml effects")

let api_search_status_table _ =
  let app = default_app () in
  let call body =
    Server.handle_custom app ~meth:"POST" ~path:"/api/v1/search" ~host:(Some "localhost")
      ~origin:None ~body
  in
  let bad_json = call "not json" in
  check_int "invalid JSON is 400" 400 bad_json.Server.status;
  check_bool "the error key is there" true
    (match Yojson.Safe.from_string bad_json.Server.body |> field "error" with
    | `String _ -> true
    | _ -> false);
  let not_object = call "[1,2]" in
  check_int "a non-object body is 400" 400 not_object.Server.status;
  check_string "Python's sentence" "Body must be a JSON object."
    (match Yojson.Safe.from_string not_object.Server.body |> field "error" with
    | `String s -> s
    | _ -> "");
  let short_query = call {|{"query":"x"}|} in
  check_int "a refused body is 400" 400 short_query.Server.status;
  let refused = call {|{"query":"ok query","provider":"no-such-provider"}|} in
  check_int "an unserved provider is 400" 400 refused.Server.status;
  let s = stub ~fail:(Provider.provider_error ~provider:"serper" "HTTP 500") () in
  let failing = make_app ~stubs:[ s ] [ "serper" ] in
  let failed =
    Server.handle_custom failing ~meth:"POST" ~path:"/api/v1/search" ~host:(Some "localhost")
      ~origin:None ~body:{|{"query":"ok query"}|}
  in
  check_int "an upstream failure is 502" 502 failed.Server.status

let api_fetch_and_answer_statuses _ =
  let app = default_app () in
  let call path body =
    Server.handle_custom app ~meth:"POST" ~path ~host:(Some "localhost") ~origin:None ~body
  in
  let fetched = call "/api/v1/fetch" {|{"url":"https://example.com/page"}|} in
  check_int "fetch 200" 200 fetched.Server.status;
  check_string "the page text" "page text"
    (match Yojson.Safe.from_string fetched.Server.body |> field "text" with
    | `String s -> s
    | _ -> "");
  let disabled = make_app ~fetch:false [ "serper" ] in
  let off =
    Server.handle_custom disabled ~meth:"POST" ~path:"/api/v1/fetch" ~host:(Some "localhost")
      ~origin:None ~body:{|{"url":"https://example.com/page"}|}
  in
  check_int "fetch off is 404" 404 off.Server.status;
  check_string "the shared sentence" Server.fetch_disabled
    (match Yojson.Safe.from_string off.Server.body |> field "error" with `String s -> s | _ -> "");
  let answered = call "/api/v1/answer" {|{"query":"what is eio?"}|} in
  check_int "answer off is 404" 404 answered.Server.status;
  check_string "the shared sentence" Server.agent_disabled
    (match Yojson.Safe.from_string answered.Server.body |> field "error" with
    | `String s -> s
    | _ -> "");
  (* With agent mode on, an unserved pin is a 400 before any model call. *)
  let with_agent = make_app ~agent:true [ "serper" ] in
  let pinned =
    Server.handle_custom with_agent ~meth:"POST" ~path:"/api/v1/answer" ~host:(Some "localhost")
      ~origin:None ~body:{|{"query":"what is eio?","provider":"no-such-provider"}|}
  in
  check_int "a refused pin is 400" 400 pinned.Server.status

let dashboard_routes _ =
  let off = default_app () in
  let get app path =
    Server.handle_custom app ~meth:"GET" ~path ~host:(Some "localhost") ~origin:None ~body:""
  in
  check_int "a disabled dashboard 404s" 404 (get off "/dashboard").Server.status;
  let enabled = make_app ~dashboard:true [ "serper" ] in
  let page = get enabled "/dashboard" in
  check_int "the page" 200 page.Server.status;
  check_string "html content type" "text/html; charset=utf-8"
    (List.assoc "content-type" page.Server.headers);
  check_bool "it is the embedded document" true (String.length page.Server.body > 1000);
  let data = get enabled "/dashboard/data" in
  check_int "data" 200 data.Server.status;
  check_bool "the snapshot carries endpoints" true
    (match field "endpoints" (Yojson.Safe.from_string data.Server.body) with
    | `Assoc _ | `List _ -> true
    | _ -> false);
  let metrics = get enabled "/dashboard/metrics" in
  check_int "metrics" 200 metrics.Server.status;
  let wrong_method =
    Server.handle_custom enabled ~meth:"POST" ~path:"/dashboard" ~host:(Some "localhost") ~origin:None
      ~body:""
  in
  check_int "wrong method is 405" 405 wrong_method.Server.status;
  check_int "unknown path is 404" 404 (get enabled "/nope").Server.status

(* {1 The flag table and the wire helpers} *)

let read path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let slice_between text start_marker end_marker =
  let at marker =
    let n = String.length text and m = String.length marker in
    let rec from i =
      if i + m > n then A.failf "the source is missing %s" marker
      else if String.sub text i m = marker then i
      else from (i + 1)
    in
    from 0
  in
  let start = at start_marker and stop = at end_marker in
  String.sub text start (stop - start)

(* [Server.server_flag_table] is the one vocabulary the manifest and the CLI
   both read. The source half is the derivation: the scanner must dispatch on
   [flag_spec] and its keys, never on a flag spelling — a renamed row moves the
   accepted name, the error sentence and the manifest together. *)
let test_the_flag_table_is_the_scanners_only_vocabulary () =
  A.(check (list string) "the manifest is the table's names"
       (List.map (fun (flag : Server.server_flag) -> flag.name)
          Server.server_flag_table)
       Server.server_flags);
  let names = List.map (fun (flag : Server.server_flag) -> flag.name)
      Server.server_flag_table
  in
  let keys = List.map (fun (flag : Server.server_flag) -> flag.key)
      Server.server_flag_table
  in
  A.(check int "no duplicate spelling" (List.length names)
       (List.length (List.sort_uniq String.compare names)));
  A.(check int "no duplicate key" (List.length keys)
       (List.length (List.sort_uniq String.compare keys)));
  A.(check (list string) "the ten keys the record has"
       [ "check"; "live"; "metrics"; "json"; "http"; "host"; "port";
         "allowed_host"; "log_level"; "log_format" ]
       keys);
  List.iter
    (fun (flag : Server.server_flag) ->
      match flag.arity with
      | Server.Boolean ->
          A.(check bool (flag.name ^ " is not repeatable") false flag.repeats)
      | Server.Value ->
          A.(check bool (flag.name ^ " repeats only for allowed-host") true
               (flag.repeats = (flag.key = "allowed_host"))))
    Server.server_flag_table;
  let scanner =
    slice_between (read "../bin/main.ml") "let parse_server_flags"
      "(* {1 The check} *)"
  in
  A.(check bool "the scanner reads the table" true
       (contains scanner "Server.flag_spec"));
  A.(check bool "the scanner reads the row's arity" true
       (contains scanner "spec.Server.arity"));
  List.iter
    (fun name ->
      A.(check bool (name ^ " is not string-matched in the scanner") false
           (contains scanner ("\"" ^ name ^ "\""))))
    names

(* The transport below [serve_http]'s routing writes its own framing, so this
   string is the whole response: the length has to be the body's, not a literal
   copied beside it. *)
let test_http_text_response_frames_its_body () =
  let body = "Invalid Host header" in
  let response = Server.http_text_response 421 body in
  check_string "exact bytes"
    ("HTTP/1.1 421 Misdirected Request\r\ncontent-type: text/plain\r\n\
      content-length: 19\r\nconnection: close\r\n\r\n" ^ body)
    response;
  List.iter
    (fun status ->
      let body = "refused" in
      let response = Server.http_text_response status body in
      let expected =
        Printf.sprintf "content-length: %d" (String.length body)
      in
      A.(check bool (Printf.sprintf "%d's length is the body's" status) true
           (contains response expected)))
    [ 400; 403; 413; 421; 500 ]

(* The replayed request head arrives as lines. [Host] is read from the same
   header type the transport uses, so a case variant and surrounding whitespace
   behave; a line without a colon is not a header. *)
let test_header_lines_fold_into_the_header_type () =
  let headers =
    Server.headers_of_lines
      [
        "Host: Example.COM";
        "not a header";
        "X-Trace:  abc ";
        ": nameless";
        "Accept: */*";
      ]
  in
  A.(check (option string) "Host is read case-insensitively" (Some "Example.COM")
       (Http.Header.get headers "host"));
  A.(check (option string) "a value is trimmed" (Some "abc")
       (Http.Header.get headers "x-trace"));
  A.(check (option string) "a second header survives" (Some "*/*")
       (Http.Header.get headers "accept"))

let () =
  A.run "seekwright/p8-server"
    [
      ( "registry",
        [
          A.test_case "the registry lists the three tools" `Quick registry_lists_the_three_tools;
          A.test_case "tools/list advertises the freeze" `Quick tools_list_advertises_the_freeze;
          A.test_case "the surface data matches the freeze" `Quick the_surface_data_matches_the_freeze;
          A.test_case "a search call answers over the registry" `Quick a_search_call_answers_over_the_registry;
          A.test_case "a refused search is a tool result" `Quick a_refused_search_is_a_tool_result;
          A.test_case "a failed search is a tool result" `Quick a_failed_search_is_a_tool_result;
          A.test_case "fetch disabled refuses cleanly" `Quick fetch_disabled_refuses_cleanly;
          A.test_case "agent disabled refuses cleanly" `Quick agent_disabled_refuses_cleanly;
        ] );
      ( "host guard",
        [
          A.test_case "the allowlist matches Python's matcher" `Quick the_host_allowlist_matches_python;
          A.test_case "guarded routes refuse a foreign host" `Quick guarded_routes_refuse_a_foreign_host;
          A.test_case "origins are checked too" `Quick origins_are_checked_against_the_allowlist;
          A.test_case "an oversized body is 413" `Quick an_oversized_body_is_413;
        ] );
      ( "custom routes",
        [
          A.test_case "healthz is secret-free and exempt" `Quick healthz_is_secret_free_and_exempt;
          A.test_case "api search round trip" `Quick api_search_round_trip;
          A.test_case "the api search status table" `Quick api_search_status_table;
          A.test_case "fetch and answer statuses" `Quick api_fetch_and_answer_statuses;
          A.test_case "the dashboard routes" `Quick dashboard_routes;
        ] );
      ( "flags and framing",
        [
          A.test_case "the flag table is the scanner's vocabulary" `Quick
            test_the_flag_table_is_the_scanners_only_vocabulary;
          A.test_case "a text response frames its own body" `Quick
            test_http_text_response_frames_its_body;
          A.test_case "header lines fold into the header type" `Quick
            test_header_lines_fold_into_the_header_type;
        ] );
    ]
