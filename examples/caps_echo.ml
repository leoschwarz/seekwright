(** Echo tool registered through [mcp-caps].

    Run it and speak the protocol on stdin/stdout:

    {e|
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}
    {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"}}}
    |e} *)

let echo =
  Mcp_caps.Tool.make
    ~description:"Echo the message back."
    ~input_schema:
      (Mcp_kit.Schema.object_
         ~properties:[("message", Mcp_kit.Schema.string ())]
         ~required:["message"]
         ())
    ~output_schema:
      (Mcp_kit.Schema.object_
         ~properties:[("echoed", Mcp_kit.Schema.string ())]
         ~required:["echoed"]
         ())
    ~decode:(Mcp_kit.Tool.Arg.string "message")
    ~run:(fun () message ->
      Ok
        (Mcp_caps.Tool.Output.text
           ~structured_content:(`Assoc [("echoed", `String message)])
           message))
    "echo"

let fail message =
  prerr_endline ("caps-echo: " ^ message);
  exit 1

let () =
  match Mcp_caps.Registry.add Mcp_caps.Registry.empty echo ~grant:() with
  | Error (Mcp_caps.Registry.Duplicate_tool name) -> fail ("duplicate tool: " ^ name)
  | Ok registry -> (
      match Mcp_caps.Server.of_registry ~name:"caps-echo" ~version:"0.1.0" registry with
      | Error (Mcp_caps.Server.Duplicate_tool name) -> fail ("duplicate tool: " ^ name)
      | Error (Mcp_caps.Server.Invalid_declaration message) -> fail message
      | Ok server ->
          Mcp_kit_stdio.run_channels server stdin stdout)
