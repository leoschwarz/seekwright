module Registry = Mcp_caps.Registry
module Server = Mcp_caps.Server
module Tool = Mcp_caps.Tool

let contains text needle =
  let n = String.length text and m = String.length needle in
  let rec from i =
    if i + m > n then false
    else if String.sub text i m = needle then true
    else from (i + 1)
  in
  from 0

let object_schema ~properties ~required =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("required", `List (List.map (fun name -> `String name) required));
    ]

let string_schema = `Assoc [("type", `String "string")]

let echo ?output_schema () =
  Tool.make
    ~input_schema:(object_schema ~properties:[("message", string_schema)] ~required:["message"])
    ?output_schema
    ~decode:(fun json ->
      match json with
      | `Assoc [("message", `String message)] -> Ok message
      | _ -> Error "message must be a string")
    ~run:(fun () message ->
      Ok
        (Tool.Output.text
           ~structured_content:(`Assoc [("echoed", `String message)])
           message))
    "echo"

let build registry =
  match Server.of_registry ~name:"test" ~version:"0" registry with
  | Ok server -> server
  | Error (Server.Duplicate_tool name) -> Alcotest.failf "unexpected duplicate: %s" name
  | Error (Server.Invalid_declaration message) ->
      Alcotest.failf "unexpected invalid declaration: %s" message

let registered tool =
  match Registry.add Registry.empty tool ~grant:() with
  | Ok registry -> registry
  | Error (Registry.Duplicate_tool name) -> Alcotest.failf "duplicate in a fresh registry: %s" name

let dispatch server line =
  match Mcp_kit.Server.dispatch_string server line with
  | Some response -> Yojson.Safe.from_string response
  | None -> `Null

let field json name =
  match json with
  | `Assoc fields -> ( match List.assoc_opt name fields with Some value -> value | None -> `Null)
  | _ -> `Null

let has json name = field json name <> `Null

let text_of response =
  match field (field response "result") "content" with
  | `List [ block ] -> ( match field block "text" with `String text -> text | _ -> "")
  | _ -> ""

(* M0's exit criterion, checked against the layer's own server: a legacy
   lifecycle, then a call, over the same server value. *)
let legacy_lifecycle_answers _ =
  let server = build (registered (echo ())) in
  let initialize =
    dispatch server
      {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}|}
  in
  Alcotest.(check bool) "initialize has a result" true (has initialize "result");
  Alcotest.(check bool) "initialized is a notification" true
    (dispatch server {|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}|} = `Null);
  let listed = dispatch server {|{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}|} in
  Alcotest.(check bool) "tools/list advertises echo" true
    (contains (Yojson.Safe.to_string listed) "\"echo\"");
  let called =
    dispatch server
      {|{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"}}}|}
  in
  Alcotest.(check string) "the tool answered" "hello" (text_of called);
  Alcotest.(check bool) "structured content is there" true
    (has (field (field called "result") "structuredContent") "echoed")

(* The same server answers a 2026-07-28 request that carries no handshake. *)
let modern_call_answers _ =
  let server = build (registered (echo ())) in
  let response =
    dispatch server
      {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"modern"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}|}
  in
  Alcotest.(check string) "the tool answered" "modern" (text_of response)

(* A tool-originated failure is an MCP result with isError, never a JSON-RPC
   error: the caller still gets a result it can read. *)
let a_tool_failure_is_not_a_transport_failure _ =
  let tool =
    Tool.make
      ~input_schema:(object_schema ~properties:[] ~required:[])
      ~decode:(fun _json -> Ok ())
      ~run:(fun () () -> Error (Mcp_caps.Error.make Mcp_caps.Error.Denied ~message:"no"))
      "denier"
  in
  let server = build (registered tool) in
  let response =
    dispatch server
      {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"denier","arguments":{}}}|}
  in
  Alcotest.(check bool) "no JSON-RPC error" false (has response "error");
  Alcotest.(check bool) "isError is set" true
    (field (field response "result") "isError" = `Bool true);
  Alcotest.(check string) "only the sanitized message crosses" "denied: no" (text_of response)

(* Declaration problems are startup failures, and they are reported rather than
   quietly dropping the entry. *)
let bad_declarations_fail_construction _ =
  let refusal tool =
    match Server.of_registry ~name:"test" ~version:"0" (registered tool) with
    | Ok _ -> Alcotest.fail "construction should have refused"
    | Error (Server.Duplicate_tool name) ->
        Alcotest.failf "expected Invalid_declaration, got Duplicate_tool %s" name
    | Error (Server.Invalid_declaration message) -> message
  in
  let tool ~name =
    Tool.make ~input_schema:(object_schema ~properties:[] ~required:[])
      ~decode:(fun _ -> Ok ())
      ~run:(fun () () -> Ok (Tool.Output.text ""))
      name
  in
  let non_object_schema =
    refusal
      (Tool.make ~input_schema:(`Assoc [("type", `String "string")])
         ~decode:(fun _ -> Ok ())
         ~run:(fun () () -> Ok (Tool.Output.text ""))
         "bad")
  in
  Alcotest.(check bool) "the refusal names the tool" true (contains non_object_schema "bad:");
  Alcotest.(check bool) "and says what is wrong" true
    (contains non_object_schema "describe an object");
  Alcotest.(check bool) "an empty name is refused" true
    (contains (refusal (tool ~name:"")) "usable");
  Alcotest.(check bool) "a name with a space is refused" true
    (contains (refusal (tool ~name:"not a name")) "usable")

(* An advertised output schema the handler does not satisfy is a server contract
   failure, which mcp-kit owns: it becomes a JSON-RPC error, not a denial. *)
let an_output_schema_mismatch_is_a_contract_failure _ =
  let tool = echo ~output_schema:(object_schema ~properties:[("missing", string_schema)] ~required:["missing"]) () in
  let server = build (registered tool) in
  let response =
    dispatch server
      {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"}}}|}
  in
  Alcotest.(check bool) "reported as a JSON-RPC error" true (has response "error");
  Alcotest.(check bool) "not passed off as a tool result" false (has response "result")

let () =
  Alcotest.run "mcp-caps/server"
    [
      ( "server",
        [
          Alcotest.test_case "a legacy lifecycle answers" `Quick legacy_lifecycle_answers;
          Alcotest.test_case "a modern call answers" `Quick modern_call_answers;
          Alcotest.test_case "a tool failure is not a transport failure" `Quick
            a_tool_failure_is_not_a_transport_failure;
          Alcotest.test_case "bad declarations fail construction" `Quick
            bad_declarations_fail_construction;
          Alcotest.test_case "an output schema mismatch is a contract failure" `Quick
            an_output_schema_mismatch_is_a_contract_failure;
        ] );
    ]
