(** MCP echo server on top of [mcp-kit].

    Run it and speak the protocol on stdin/stdout:

    {e|
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}
    {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"}}}
    |e} *)

let echo =
  let input_schema =
    Mcp_kit.Schema.object_
      ~properties:[("message", Mcp_kit.Schema.string ())]
      ~required:["message"]
      ()
  in
  Mcp_kit.Tool.make
    ~description:"Echo the message back."
    ~input_schema
    "echo"
    (fun args ->
      Result.map
        (fun message ->
          {
            Mcp_kit.Tool.content = [ Mcp_kit.Tool.Text message ];
            is_error = false;
            structured_content = None;
          })
        (Mcp_kit.Tool.Arg.string "message" args))

let () =
  match Mcp_kit.Server.add_tool (Mcp_kit.Server.create ~name:"echo" ~version:"0.1.0" ()) echo with
  | Error (Mcp_kit.Server.Duplicate_tool name) ->
      prerr_endline ("echo: duplicate tool: " ^ name);
      exit 1
  | Error _ ->
      prerr_endline "echo: could not register the tool";
      exit 1
  | Ok server ->
      Mcp_kit_stdio.run_channels server stdin stdout
