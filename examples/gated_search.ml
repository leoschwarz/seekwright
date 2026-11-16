(** A gated [search_web] and [fetch_url] server demonstrating network grants.

    The operator names allowed endpoints at startup. [search_web] reaches the configured endpoint,
    while [fetch_url] validates caller-supplied URLs against the grant.

    Run target in one shell:
    {v python3 -m http.server 8099 --bind 127.0.0.1 v}

    Run server in another:
    {v
    ./_build/default/examples/gated_search.exe http://127.0.0.1:8099
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}
    {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_web","arguments":{"query":"the answer"}}}
    {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fetch_url","arguments":{"url":"http://127.0.0.1:8099/"}}}
    {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fetch_url","arguments":{"url":"http://localhost:8099/"}}}
    {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"fetch_url","arguments":{"url":"http://169.254.169.254/latest/meta-data/"}}}
    v} *)

module Authority = Mcp_caps.Authority
module Budget = Mcp_caps.Budget
module Error = Mcp_caps.Error
module Event = Mcp_caps.Event
module Policy = Mcp_caps.Policy
module Registry = Mcp_caps.Registry
module Server = Mcp_caps.Server
module Tool = Mcp_caps.Tool

let () = Mirage_crypto_rng_unix.use_default ()

let note line = prerr_endline ("gated-search: " ^ line)

let audit event = note (Event.render event)

let request_headers = [ ("accept", "application/json") ]

type target = { endpoint : Policy.endpoint; base : Uri.t }

let search_uri target query = Uri.add_query_param' (Uri.with_path target.base "/search") ("q", query)

let search_web target =
  Tool.make
    ~description:
      "Search the web through the one endpoint this server was started with. The answer is \
       whatever that endpoint returns."
    ~input_schema:
      (Mcp_kit.Schema.object_
         ~properties:[ ("query", Mcp_kit.Schema.string ()) ]
         ~required:[ "query" ] ())
    ~decode:(Mcp_kit.Tool.Arg.string "query")
    ~run:(fun grant query ->
      match
        Authority.Net.request grant
          {
            Authority.Net.meth = `GET;
            uri = search_uri target query;
            headers = request_headers;
            body = None;
          }
      with
      | Ok response -> Ok (Tool.Output.text response.body)
      | Error error -> Error error)
    "search_web"

let fetch_url =
  Tool.make
    ~description:
      "Read a URL through this server's network grant. Only the endpoints the operator listed are \
       reachable."
    ~input_schema:
      (Mcp_kit.Schema.object_
         ~properties:[ ("url", Mcp_kit.Schema.string ()) ]
         ~required:[ "url" ] ())
    ~decode:(Mcp_kit.Tool.Arg.string "url")
    ~run:(fun grant url ->
      match
        Authority.Net.request grant
          {
            Authority.Net.meth = `GET;
            uri = Uri.of_string url;
            headers = request_headers;
            body = None;
          }
      with
      | Ok response -> Ok (Tool.Output.text (Printf.sprintf "%d\n%s" response.status response.body))
      | Error error -> Error error)
    "fetch_url"

let max_response_bytes = 65_536
let operation_timeout_seconds = 10.
let loopback = "127.0.0.1"

type transport = Transport_stdio | Transport_http of int

let usage () =
  note "usage: gated_search <endpoint> [--http [<port>]] [--max-calls <n>]";
  note "  endpoint: [scheme://]host[:port], e.g. http://127.0.0.1:8099 or https://api.example.com";
  exit 2

let port_of = function
  | None -> Transport_http 8765
  | Some text -> (
      match int_of_string_opt text with
      | Some port when port > 0 && port < 65_536 -> Transport_http port
      | _ ->
          note (Printf.sprintf "--http: %S is not a port number" text);
          exit 2)

let target_of text =
  let with_scheme =
    if String.contains text '/' || String.starts_with ~prefix:"." text then text
    else "https://" ^ text
  in
  let uri = Uri.of_string with_scheme in
  match (Uri.scheme uri, Uri.host uri) with
  | Some (("http" | "https") as scheme), Some host ->
      let scheme = if scheme = "https" then `Https else `Http in
      Ok { endpoint = { Policy.scheme; host; port = Uri.port uri }; base = uri }
  | scheme, _ ->
      note
        (Printf.sprintf "%S is not an http(s) endpoint with a host (scheme: %s)" text
           (Option.value ~default:"none" scheme));
      Error ()

let cli () =
  match Array.to_list Sys.argv with
  | [] | [ _ ] -> usage ()
  | _ :: endpoint_text :: rest -> (
      let transport = ref Transport_stdio and max_calls = ref None in
      let scan = function
        | [] -> ()
        | [ "--http" ] -> transport := port_of None
        | [ "--http"; text ] -> transport := port_of (Some text)
        | [ "--max-calls"; text ] -> (
            match int_of_string_opt text with
            | Some n when n > 0 -> max_calls := Some n
            | _ ->
                note (Printf.sprintf "--max-calls: %S is not a positive count" text);
                exit 2)
        | _ -> usage ()
      in
      scan rest;
      match target_of endpoint_text with
      | Error () -> exit 2
      | Ok target -> (target, !transport, !max_calls))

let build ~sw env target max_calls =
  let ( let* ) = Result.bind in
  let ( >>= ) = Result.bind in
  let invalid message = Error (Server.Invalid_declaration message) in
  let* confinement =
    match Policy.with_endpoints ~sw ~net:env#net ~max_response_bytes [ target.endpoint ] with
    | Ok confinement -> Ok confinement
    | Error error -> invalid (Error.render error)
  in
  let clock = Eio.Stdenv.mono_clock env in
  let grant =
    Authority.with_log ~sink:audit
      (Authority.with_operation_timeout
         (Eio.Time.Timeout.seconds clock operation_timeout_seconds)
         (Authority.Net.of_confinement ~mono_clock:clock confinement))
  in
  let grant =
    match max_calls with
    | None -> grant
    | Some calls -> Authority.with_operation_budget (Budget.make calls) grant
  in
  let* registry =
    Registry.add Registry.empty (search_web target) ~grant
    >>= (fun registry -> Registry.add registry fetch_url ~grant)
    |> Result.map_error (fun (Registry.Duplicate_tool name) -> Server.Duplicate_tool name)
  in
  List.iter (fun entry -> note ("serves " ^ Registry.entry_name entry)) (Registry.entries registry);
  note
    (Printf.sprintf "one endpoint allowed: %s://%s%s, at most %d response bytes%s"
       (match target.endpoint.Policy.scheme with `Http -> "http" | `Https -> "https")
       target.endpoint.Policy.host
       (match target.endpoint.Policy.port with Some port -> ":" ^ string_of_int port | None -> "")
       max_response_bytes
       (match max_calls with
       | Some calls -> ", at most " ^ string_of_int calls ^ " calls per process"
       | None -> ""));
  Server.of_registry ~name:"gated-search" ~version:"0.1.0" registry

let serve_http ~sw env server port =
  let handler = Mcp_kit_cohttp_eio.handler ~max_body_size:1_048_576 server in
  let socket = Eio.Net.listen ~backlog:128 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
  note (Printf.sprintf "streamable HTTP on http://%s:%d/ (POST JSON-RPC to /)" loopback port);
  Cohttp_eio.Server.run
    ~on_error:(function
      | Mcp_kit_cohttp_eio.Rejected_origin -> note "origin rejected"
      | exn -> note ("connection: " ^ Printexc.to_string exn))
    socket handler

let () =
  let target, transport, max_calls = cli () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match build ~sw env target max_calls with
  | Error (Server.Duplicate_tool name) -> note ("duplicate tool: " ^ name)
  | Error (Server.Invalid_declaration message) -> note message
  | Ok server -> (
      match transport with
      | Transport_stdio -> Mcp_kit_stdio.run_channels server stdin stdout
      | Transport_http port -> serve_http ~sw env server port)
