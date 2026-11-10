(* A tool that needs a power cannot be registered without naming it.
   [Registry.add] takes [~grant] as a required label, so the omission is a type
   error on the one line an auditor reads — which is the whole point of the
   registry being the only place a tool and a grant meet
   (plans/capability-gated-mcp-server.md §1, §4).

   Expected: the application of [add] is reported as still waiting for [grant:]. *)

let ping =
  Mcp_caps.Tool.make
    ~input_schema:(`Assoc [ ("type", `String "object") ])
    ~decode:(fun _json -> Ok ())
    ~run:(fun () () -> Ok (Mcp_caps.Tool.Output.text "pong"))
    "ping"

let registry : (Mcp_caps.Registry.t, Mcp_caps.Registry.add_error) result =
  Mcp_caps.Registry.add Mcp_caps.Registry.empty ping
