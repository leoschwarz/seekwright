(** A gated [read_source] tool: the audit surface, in one file.

    This is the shape [bin/main.ml] will have for seekwright (the layout plan
    calls it "the audit surface: one Registry.add line per tool, grant named").
    Every tool is registered where its power is named, and the only power here
    is one filesystem subtree:

    {v Registry.add registry read_source ~grant v}

    [grant] came from [Authority.Fs.of_confinement] two lines above, and the
    only way to a confinement decision is the [Policy.with_root] above that, so
    a reader who wants to know what [read_source] may touch has one line to look
    at (plans/capability-gated-mcp-server.md §1, §4).

    {2 The Eio contract, in code}

    The grant's subtree handle belongs to the loop that opened it, and
    [Authority.Fs] operations are Eio direct style, so the transport loop runs
    inside [Eio_main.run], under the same [Eio.Switch.t] that owns the grant
    (§7). That is what gives mcp-kit's synchronous handler a fiber to do I/O
    in — the "Running the operations" section of [Authority] explains why the
    adapter does not call [Eio_main.run] itself.

    The stdin read here is a blocking channel read, so it sits in a fiber of the
    loop and parks the loop while it waits. For a single stdio client that is
    the whole process, and the mcp-kit adapter owns the framing. The HTTP
    transport obeys the same contract: the listener, the grant and the loop all
    sit under one [Eio.Switch.t], and [Mcp_kit_cohttp_eio.handler] gives each
    request its own fiber, which is what a concurrent server needs and what a
    blocking stdio read does not get.

    {2 Trying it — stdio}

    {v
    mkdir -p /tmp/src/notes && echo 'the answer is 42' > /tmp/src/notes/answer.md
    ./_build/default/examples/read_source.exe /tmp/src
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}
    {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_source","arguments":{"path":"notes/answer.md"}}}
    {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_source","arguments":{"path":"../../etc/passwd"}}}
    |e}

    The last call answers [isError] with [invalid: …]; [escape] (a symlink to
    ["/etc/passwd"] under the root) answers [denied: …].

    {2 Trying it — Streamable HTTP}

    {v
    ./_build/default/examples/read_source.exe /tmp/src --http 8765
    curl -sS -X POST http://127.0.0.1:8765/ \
      -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_source","arguments":{"path":"notes/answer.md"}}}'
    v}

    The bodies are the same ones as above, which is the point: [build] below is
    the only server construction either transport sees, so the tool surface,
    the grant, and the refusal sentences are shared and only the framing differs
    (§7, and test/test_http_transport.ml which asserts that equality).

    What differs is what the adapters do around it. The stdio adapter opens one
    [Mcp_kit.Server.session] per connection and enforces the legacy
    initialize/initialized lifecycle through it; the Cohttp-Eio adapter
    dispatches every POST statelessly against the shared server value, so a
    legacy body needs no handshake and a modern one needs the routing headers
    ([MCP-Protocol-Version], [Mcp-Method], [Mcp-Name]) it validates itself:

    {v
    curl -sS -X POST http://127.0.0.1:8765/ \
      -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
      -H 'mcp-protocol-version: 2026-07-28' -H 'mcp-method: tools/call' -H 'mcp-name: read_source' \
      -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_source","arguments":{"path":"notes/answer.md"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
    v}

    Request bodies are capped by [max_request_body] below, request routing
    headers and Origin are checked by the mcp-kit adapter, and the inbound
    listener is loopback-only: inbound TLS and any wider Host policy belong to
    the gateway, not to this example (§7). *)

module Authority = Mcp_caps.Authority
module Error = Mcp_caps.Error
module Policy = Mcp_caps.Policy
module Registry = Mcp_caps.Registry
module Server = Mcp_caps.Server
module Tool = Mcp_caps.Tool

(* A tool that needs a power says so in its ['caps]: [run] is handed the grant,
   and every read it does goes through that value. *)
let read_source =
  Tool.make
    ~description:"Read a file from the source root this server was started with."
    ~input_schema:
      (Mcp_kit.Schema.object_
         ~properties:[("path", Mcp_kit.Schema.string ())]
         ~required:["path"]
         ())
    ~decode:(Mcp_kit.Tool.Arg.string "path")
    ~run:(fun grant path ->
      match Authority.Fs.read_file grant path with
      | Ok content -> Ok (Tool.Output.text content)
      | Error error -> Error error)
    "read_source"

(* The same shape with no power at all: [~grant:()] is what makes the powered
   tool stand out when the registrations are read in order. *)
let ping =
  Tool.make
    ~description:"Say pong."
    ~input_schema:(Mcp_kit.Schema.object_ ~properties:[] ~required:[] ())
    ~decode:(fun _json -> Ok ())
    ~run:(fun () () -> Ok (Tool.Output.text "pong"))
    "ping"

let note line =
  (* stdout is the JSON-RPC channel, so everything about startup goes to
     stderr, and a failure exits nonzero (§7). *)
  prerr_endline ("read-source: " ^ line)

(* The body bound is the mcp-kit adapter's, not ours (§7); it is named here so
   that pinning it is a decision in this file rather than an upstream default
   this example happens to inherit. A JSON-RPC [tools/call] for this server is
   a path, so 1 MiB is already far above anything a client has a reason to
   send. *)
let max_request_body = 1_048_576

let loopback = "127.0.0.1"

(* [read_source <root>] is stdio; [--http [<port>]] asks for Streamable HTTP on
   loopback instead. Both serve the same [build] below. *)
type transport = Transport_stdio | Transport_http of int

let usage () =
  note "usage: read_source <source-root-directory> [--http [<port>]]";
  exit 2

let port_of = function
  | None -> Transport_http 8765
  | Some text -> (
      match int_of_string_opt text with
      | Some port when port > 0 && port < 65_536 -> Transport_http port
      | _ ->
          note (Printf.sprintf "--http: %S is not a port number" text);
          exit 2)

let cli () =
  match Array.to_list Sys.argv with
  | [] | [ _ ] -> usage ()
  | _ :: root :: rest ->
      let transport =
        match rest with
        | [] -> Transport_stdio
        | [ "--http" ] -> port_of None
        | [ "--http"; text ] -> port_of (Some text)
        | [ flag ] when String.starts_with ~prefix:"--http=" flag ->
            let prefix = String.length "--http=" in
            port_of (Some (String.sub flag prefix (String.length flag - prefix)))
        | _ -> usage ()
      in
      (root, transport)

let build ~sw env root =
  let ( let* ) = Result.bind in
  let ( >>= ) = Result.bind in
  let invalid message = Error (Server.Invalid_declaration message) in
  let* confinement =
    match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) root with
    | Ok confinement -> Ok confinement
    | Error error -> invalid (Error.render error)
  in
  let grant = Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement in
  let* registry =
    Registry.add Registry.empty ping ~grant:()
    >>= (fun registry -> Registry.add registry read_source ~grant)
    |> Result.map_error (fun (Registry.Duplicate_tool name) -> Server.Duplicate_tool name)
  in
  List.iter
    (fun entry -> note ("serves " ^ Registry.entry_name entry))
    (Registry.entries registry);
  note ("read_source is confined to " ^ root);
  Server.of_registry ~name:"read-source" ~version:"0.1.0" registry

let serve_http ~sw env server port =
  let handler = Mcp_kit_cohttp_eio.handler ~max_body_size:max_request_body server in
  (* The listening socket is registered on the switch that owns the grant, so a
     request cannot outlive the subtree its tool reads through (§7). *)
  let socket =
    Eio.Net.listen ~backlog:128 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  note (Printf.sprintf "streamable HTTP on http://%s:%d/ (POST JSON-RPC to /)" loopback port);
  (* [on_error] is the adapter's channel for per-connection failures. The
     rejected-Origin case is expected traffic, and it is reported as a named
     event rather than as an exception dump (§7). *)
  Cohttp_eio.Server.run
    ~on_error:(function
      | Mcp_kit_cohttp_eio.Rejected_origin -> note "origin rejected"
      | exn -> note ("connection: " ^ Printexc.to_string exn))
    socket handler

let () =
  let root, transport = cli () in
  Eio_main.run @@ fun env ->
  (* The switch that owns the grant has to outlive the transport loop, so the
     loop runs inside it rather than after it. *)
  Eio.Switch.run @@ fun sw ->
  match build ~sw env root with
  | Error (Server.Duplicate_tool name) -> note ("duplicate tool: " ^ name)
  | Error (Server.Invalid_declaration message) -> note message
  | Ok server -> (
      match transport with
      | Transport_stdio ->
        (* The mcp-kit stdio adapter owns the framing; this call sits inside the
           loop that owns the grant, which is what the handler needs in order to
           read a file. *)
        Mcp_kit_stdio.run_channels server stdin stdout
      | Transport_http port -> serve_http ~sw env server port)
