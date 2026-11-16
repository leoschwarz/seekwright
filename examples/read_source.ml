(** A gated [read_source] tool demonstrating filesystem grants.

    The operator names the directory root at startup; file reads outside that
    subtree are refused by the grant before any filesystem access.

    Run in stdio mode:
    {v
    mkdir -p /tmp/src/notes && echo 'the answer is 42' > /tmp/src/notes/answer.md
    ./_build/default/examples/read_source.exe /tmp/src
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}
    {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_source","arguments":{"path":"notes/answer.md"}}}
    {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_source","arguments":{"path":"../../etc/passwd"}}}
    v}

    Run in HTTP mode:
    {v
    ./_build/default/examples/read_source.exe /tmp/src --http 8765
    curl -sS -X POST http://127.0.0.1:8765/ \
      -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_source","arguments":{"path":"notes/answer.md"}}}'
    v} *)

module Authority = Mcp_caps.Authority
module Error = Mcp_caps.Error
module Policy = Mcp_caps.Policy
module Registry = Mcp_caps.Registry
module Server = Mcp_caps.Server
module Tool = Mcp_caps.Tool

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

let ping =
  Tool.make
    ~description:"Say pong."
    ~input_schema:(Mcp_kit.Schema.object_ ~properties:[] ~required:[] ())
    ~decode:(fun _json -> Ok ())
    ~run:(fun () () -> Ok (Tool.Output.text "pong"))
    "ping"

let note line =
  prerr_endline ("read-source: " ^ line)

let max_request_body = 1_048_576
let loopback = "127.0.0.1"

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
  let root, transport = cli () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match build ~sw env root with
  | Error (Server.Duplicate_tool name) -> note ("duplicate tool: " ^ name)
  | Error (Server.Invalid_declaration message) -> note message
  | Ok server -> (
      match transport with
      | Transport_stdio ->
        Mcp_kit_stdio.run_channels server stdin stdout
      | Transport_http port -> serve_http ~sw env server port)
