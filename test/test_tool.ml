module Tool = Mcp_caps.Tool

(* A tool that only needs the unit grant: it is the shape every no-capability
   tool takes, and the shape the echo examples register. *)
let echo_tool =
  Tool.make
    ~title:"Echo"
    ~description:"Echo the message."
    ~input_schema:(`Assoc [("type", `String "object")])
    ~decode:(fun json ->
      match json with
      | `Assoc [("message", `String message)] -> Ok message
      | _ -> Error "message must be a string")
    ~run:(fun () message -> Ok (Tool.Output.text message))
    "echo"

let output_carries_text_and_structure _ =
  let output =
    Tool.Output.text ~structured_content:(`Assoc [("echoed", `String "hi")]) "hi"
  in
  Alcotest.(check string) "text" "hi" (Tool.Output.text_of output);
  match Tool.Output.structured_content output with
  | Some (`Assoc [("echoed", `String "hi")]) -> ()
  | Some other ->
      Alcotest.failf "wrong structured content: %s" (Yojson.Safe.to_string other)
  | None -> Alcotest.fail "structured content was dropped"

let metadata_survives_make _ =
  Alcotest.(check string) "name" "echo" (Tool.name echo_tool);
  Alcotest.(check (option string)) "title" (Some "Echo") (Tool.title echo_tool);
  Alcotest.(check (option string)) "description" (Some "Echo the message.")
    (Tool.description echo_tool);
  match Tool.output_schema echo_tool with
  | None -> ()
  | Some schema ->
      Alcotest.failf "expected no output schema, got %s" (Yojson.Safe.to_string schema)

let decode_then_run _ =
  (match Tool.decode echo_tool (`Assoc [("message", `String "hi")]) with
  | Ok message -> Alcotest.(check string) "decoded" "hi" message
  | Error message -> Alcotest.failf "decode failed: %s" message);
  (match Tool.decode echo_tool (`Assoc [("message", `Int 1)]) with
  | Ok _ -> Alcotest.fail "an int should not decode as a string"
  | Error _ -> ());
  match
    Tool.run echo_tool () "hi"
  with
  | Ok output -> Alcotest.(check string) "ran" "hi" (Tool.Output.text_of output)
  | Error error -> Alcotest.failf "run failed: %s" (Mcp_caps.Error.render error)

let () =
  Alcotest.run "mcp-caps/tool"
    [
      ( "tool",
        [
          Alcotest.test_case "output keeps both views" `Quick
            output_carries_text_and_structure;
          Alcotest.test_case "make keeps metadata" `Quick metadata_survives_make;
          Alcotest.test_case "decode is explicit" `Quick decode_then_run;
        ] );
    ]
