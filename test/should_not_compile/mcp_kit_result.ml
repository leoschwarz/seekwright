(* The core's output type is its own. [mcp-caps] keeps mcp-kit behind
   [Server.ml] (§2), so a tool cannot be written that hands mcp-kit's own
   result shape to the registry: doing so would let the transport's types set
   what a tool may return, which is the seam the layer exists to hold
   (plans/capability-gated-mcp-server.md §8).

   Expected: [Mcp_kit.Tool.result] is not a [Tool.Output.t]. *)

let echo =
  Mcp_caps.Tool.make
    ~input_schema:(`Assoc [ ("type", `String "object") ])
    ~decode:(fun _json -> Ok ())
    ~run:(fun () () -> Ok (Mcp_kit.Tool.text "pong"))
    "echo"
