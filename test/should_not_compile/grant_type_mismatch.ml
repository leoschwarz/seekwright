(* A tool says which power it needs, and the registry cannot be built by giving
   it a different one: [read_source]'s capability is [Authority.Fs.t], so the
   [~grant:()] a no-I/O tool passes is a type error rather than a runtime hole
   (plans/capability-gated-mcp-server.md §3, §4).

   Expected: the grant argument's type conflicts with the tool's. *)

let read_source =
  Mcp_caps.Tool.make
    ~input_schema:(`Assoc [ ("type", `String "object") ])
    ~decode:(fun json -> Ok json)
    ~run:(fun grant _json ->
      match Mcp_caps.Authority.Fs.read_file grant "notes/answer.md" with
      | Ok content -> Ok (Mcp_caps.Tool.Output.text content)
      | Error error -> Error error)
    "read_source"

let registry = Mcp_caps.Registry.add Mcp_caps.Registry.empty read_source ~grant:()
