(** A gated [search_web]: the network grant, in one file.

    The filesystem example ([read_source.ml]) shows one subtree; this shows the
    other power the layer offers, and the shape seekwright's [search] tool will
    have: the operator names the endpoints, the grant is built once at startup,
    and every request the tool makes is one bounded HTTP exchange through that
    value (plans/capability-gated-mcp-server.md §4, §5).

    {v Authority.Net.of_confinement ~mono_clock confinement v}

    with [confinement] from [Policy.with_endpoints ~sw ~net ~max_response_bytes
    entries] two lines above. That is the whole audit answer to "what may
    [search_web] reach": one line, one list, named at startup (§1).

    {2 Two tools, one grant, and the refusal that proves the grant is real}

    [search_web] only ever asks the operator's endpoint, so it cannot show what
    the policy refuses. [fetch_url] is registered with the {e same} grant and
    takes its URL from the {e caller}: the tool has no idea what it is allowed to
    reach, and the grant decides. That is the pair worth running by hand — one
    call served, one refused with [denied:], and the refusal sent no DNS query
    and no packet (§5).

    {2 The bounds around it}

    - [with_operation_timeout] is the bound one request gets: DNS, connect, TLS,
      headers and body together. It is per operation, so four calls from one
      client get four bounds, not one shared deadline (§6).
    - [--max-calls N] puts a [Budget] counter in the grant. That is honest here
      only because this process {e is} the scope: the counter caps the calls one
      server instance serves and dies with it. A real deployment must not read
      that as a per-request budget — a counter in a server-lifetime grant is a
      server-lifetime budget, which is why §6 puts the per-request counter with
      the code that wants the ceiling (a plan, a request) rather than in the
      grant.
    - [with_log ~sink] sends one bounded, content-free [Event.t] per operation to
      {b stderr}: stdout is the JSON-RPC channel, so a log line on it corrupts the
      protocol (§6, §7). The line carries the operation name, its outcome, and a
      byte count — never the URL query, the response body, or a header.
    - The response body is capped by [max_response_bytes] at construction, and a
      caller may lower it per request with [~max_response_bytes], never raise it.

    {2 Trying it}

    Start a target for the grant to allow, then the server, in a second shell:

    {v
    python3 -m http.server 8099 --bind 127.0.0.1
    ./_build/default/examples/gated_search.exe 127.0.0.1:8099
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}
    {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_web","arguments":{"query":"the answer"}}}
    {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fetch_url","arguments":{"url":"http://127.0.0.1:8099/"}}}
    {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fetch_url","arguments":{"url":"http://localhost:8099/"}}}
    {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"fetch_url","arguments":{"url":"http://169.254.169.254/latest/meta-data/"}}}
    v}

    The [fetch_url] calls answer in turn: served, [denied: …] because [localhost]
    is not the name the allowlist lists, and [denied: …] again. The last one is
    the case worth reading closely: an unlisted host is refused {b before} any
    resolver query, so the metadata address was never dialed, and the audit line
    on stderr says [net.request failed denied] with no address in it.

    With [--http [<port>]] the same server answers Streamable HTTP on loopback;
    [read_source.ml]'s docstring explains what the two transports do differently
    around one shared [build] (§7). *)

module Authority = Mcp_caps.Authority
module Budget = Mcp_caps.Budget
module Error = Mcp_caps.Error
module Event = Mcp_caps.Event
module Policy = Mcp_caps.Policy
module Registry = Mcp_caps.Registry
module Server = Mcp_caps.Server
module Tool = Mcp_caps.Tool

(* TLS needs a process-global random generator, and [Policy_net] refuses to build
   an https-capable grant without one rather than handing back a grant whose
   https path throws later (§5). An application that has its own entropy source
   installs it here instead. *)
let () = Mirage_crypto_rng_unix.use_default ()

let note line = prerr_endline ("gated-search: " ^ line)

(* The audit sink. [Event.render] is one bounded line, and [Event] cannot carry a
   body, a header, or a query string (§6). *)
let audit event = note (Event.render event)

(* One request's headers. [accept] is the caller's business; [Host],
   [Content-Length], [Transfer-Encoding], [Connection] and [Upgrade] are the
   authority's and a tool that tries to set them is refused with [Invalid],
   because those are the headers that decide where a request is served and where
   it ends. *)
let request_headers = [ ("accept", "application/json") ]

(* The operator's endpoint, in the two forms the code needs: the policy entry the
   grant is built from, and the URI [search_web] addresses. *)
type target = { endpoint : Policy.endpoint; base : Uri.t }

let search_uri target query =
  Uri.add_query_param' (Uri.with_path target.base "/search") ("q", query)

let search_web target =
  Tool.make
    ~description:
      "Search the web through the one endpoint this server was started with. The answer is \
       whatever that endpoint returns."
    ~input_schema:
      (Mcp_kit.Schema.object_
         ~properties:[ ("query", Mcp_kit.Schema.string ()) ]
         ~required:[ "query" ]
         ())
    ~decode:(Mcp_kit.Tool.Arg.string "query")
    ~run:(fun grant query ->
      match
        Authority.Net.request grant
          { Authority.Net.meth = `GET;
            uri = search_uri target query;
            headers = request_headers;
            body = None;
          }
      with
      | Ok response -> Ok (Tool.Output.text response.body)
      | Error error -> Error error)
    "search_web"

(* The same grant, with the destination in the caller's hands. Everything that
   makes the grant a gate — the name check before any lookup, the vetted address,
   the byte ceiling — applies here too, and this is the tool that shows it. *)
let fetch_url =
  Tool.make
    ~description:
      "Read a URL through this server's network grant. Only the endpoints the operator listed \
       are reachable."
    ~input_schema:
      (Mcp_kit.Schema.object_
         ~properties:[ ("url", Mcp_kit.Schema.string ()) ]
         ~required:[ "url" ]
         ())
    ~decode:(Mcp_kit.Tool.Arg.string "url")
    ~run:(fun grant url ->
      match
        Authority.Net.request grant
          { Authority.Net.meth = `GET;
            uri = Uri.of_string url;
            headers = request_headers;
            body = None;
          }
      with
      | Ok response ->
          Ok
            (Tool.Output.text
               (Printf.sprintf "%d\n%s" response.status response.body))
      | Error error -> Error error)
    "fetch_url"

(* The response ceiling this example builds its grant with. A search provider's
   JSON lives well inside it; an uncapped body would let the peer decide how much
   memory and context one call costs (§5). *)
let max_response_bytes = 65_536

(* The one operation bound a request gets, in seconds: DNS, connect, TLS, headers
   and body together. Named rather than inherited from the library default so a
   reader of this file sees the number the example runs with. *)
let operation_timeout_seconds = 10.

let loopback = "127.0.0.1"

type transport = Transport_stdio | Transport_http of int

let usage () =
  note "usage: gated_search <endpoint> [--http [<port>]] [--max-calls <n>]";
  note "  endpoint: [scheme://]host[:port], e.g. 127.0.0.1:8099 or https://api.example.com";
  exit 2

let port_of = function
  | None -> Transport_http 8765
  | Some text -> (
      match int_of_string_opt text with
      | Some port when port > 0 && port < 65_536 -> Transport_http port
      | _ ->
          note (Printf.sprintf "--http: %S is not a port number" text);
          exit 2)

(* [host:port] or [scheme://host[:port]]. The default scheme is https, because
   that is what a real provider is addressed with; a loopback target has to say
   [http://] explicitly, which is also the shape that makes "this one is
   cleartext, on purpose" visible in the command line. *)
let target_of text =
  let with_scheme =
    if String.contains text '/' || String.starts_with ~prefix:"." text then text
    else "https://" ^ text
  in
  let uri = Uri.of_string with_scheme in
  match (Uri.scheme uri, Uri.host uri) with
  | (Some ("http" | "https" as scheme), Some host) ->
      let scheme = if scheme = "https" then `Https else `Http in
      Ok { endpoint = { Policy.scheme; host; port = Uri.port uri }; base = uri }
  | (scheme, _) ->
      note
        (Printf.sprintf "%S is not an http(s) endpoint with a host (scheme: %s)" text
           (Option.value ~default:"none" scheme));
      Error ()

let cli () =
  match Array.to_list Sys.argv with
  | [] | [ _ ] -> usage ()
  | _ :: endpoint_text :: rest ->
      let transport = ref Transport_stdio and max_calls = ref None in
      let scan = function
        | [] -> ()
        | [ "--http" ] -> transport := port_of None
        | [ "--http"; text ] -> transport := port_of (Some text)
        | [ "--max-calls"; text ] ->
            (match int_of_string_opt text with
            | Some n when n > 0 -> max_calls := Some n
            | _ ->
                note (Printf.sprintf "--max-calls: %S is not a positive count" text);
                exit 2)
        | _ -> usage ()
      in
      scan rest;
      match target_of endpoint_text with
      | Error () -> exit 2
      | Ok target -> (target, !transport, !max_calls)

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
       (match target.endpoint.Policy.port with
       | Some port -> ":" ^ string_of_int port
       | None -> "")
       max_response_bytes
       (match max_calls with
       | Some calls -> ", at most " ^ string_of_int calls ^ " calls per process"
       | None -> ""));
  Server.of_registry ~name:"gated-search" ~version:"0.1.0" registry

let serve_http ~sw env server port =
  let handler = Mcp_kit_cohttp_eio.handler ~max_body_size:1_048_576 server in
  let socket =
    Eio.Net.listen ~backlog:128 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  note (Printf.sprintf "streamable HTTP on http://%s:%d/ (POST JSON-RPC to /)" loopback port);
  Cohttp_eio.Server.run
    ~on_error:(function
      | Mcp_kit_cohttp_eio.Rejected_origin -> note "origin rejected"
      | exn -> note ("connection: " ^ Printexc.to_string exn))
    socket handler

let () =
  let target, transport, max_calls = cli () in
  Eio_main.run @@ fun env ->
  (* The switch that owns the grant has to outlive the transport loop, exactly as
     in [read_source.ml]: a request must not outlive the authority it dials
     through (§1, §7). *)
  Eio.Switch.run @@ fun sw ->
  match build ~sw env target max_calls with
  | Error (Server.Duplicate_tool name) -> note ("duplicate tool: " ^ name)
  | Error (Server.Invalid_declaration message) -> note message
  | Ok server -> (
      match transport with
      | Transport_stdio -> Mcp_kit_stdio.run_channels server stdin stdout
      | Transport_http port -> serve_http ~sw env server port)
