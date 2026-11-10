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
    the whole process, and the mcp-kit adapter owns the framing; an HTTP
    transport (M2) meets the same contract by running its loop under this switch.

    {2 Trying it}

    {v
    mkdir -p /tmp/src/notes && echo 'the answer is 42' > /tmp/src/notes/answer.md
    ./_build/default/examples/read_source.exe /tmp/src
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}
    {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_source","arguments":{"path":"notes/answer.md"}}}
    {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_source","arguments":{"path":"../../etc/passwd"}}}
    |e}

    The last call answers [isError] with [denied: …]. *)

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

let root_from_argv () =
  match Array.to_list Sys.argv with
  | [ _; root ] -> root
  | _ ->
      note "usage: read_source <source-root-directory>";
      exit 2

let build ~sw env root =
  let ( let* ) = Result.bind in
  let ( >>= ) = Result.bind in
  let invalid message = Error (Server.Invalid_declaration message) in
  let* confinement =
    match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) root with
    | Ok confinement -> Ok confinement
    | Error error -> invalid (Error.render error)
  in
  let grant = Authority.Fs.of_confinement confinement in
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

let () =
  let root = root_from_argv () in
  Eio_main.run @@ fun env ->
  (* The switch that owns the grant has to outlive the transport loop, so the
     loop runs inside it rather than after it. *)
  Eio.Switch.run @@ fun sw ->
  match build ~sw env root with
  | Error (Server.Duplicate_tool name) -> note ("duplicate tool: " ^ name)
  | Error (Server.Invalid_declaration message) -> note message
  | Ok server ->
      (* The mcp-kit stdio adapter owns the framing; this call sits inside the
         loop that owns the grant, which is what the handler needs in order to
         read a file. *)
      Mcp_kit_stdio.run_channels server stdin stdout
