(* A tool says which power it needs, and the registry cannot be built by handing
   it someone else's: [read_source]'s capability is [Authority.Fs.t], and a
   [Net] grant — a real one's type, from a caller that holds network access — is
   a type error rather than a runtime hole
   (plans/capability-gated-mcp-server.md §3, §4).

   The two kinds are deliberately distinct types rather than two values of one
   grant type: [Authority] keeps the phantom kind in the grant, which is what
   makes a network grant unable to answer [Authority.Fs.read_file] at all.

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

let registry (net_grant : Mcp_caps.Authority.Net.t) =
  Mcp_caps.Registry.add Mcp_caps.Registry.empty read_source ~grant:net_grant
