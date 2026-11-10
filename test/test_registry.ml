module Registry = Mcp_caps.Registry

let ( >>= ) = Result.bind

let input_schema = `Assoc [("type", `String "object")]

(* The grant is an ordinary string here so a test can see which grant a call
   actually ran under; a real tool's grant is an abstract Authority value. *)
let make_tool ~name ~prefix =
  Mcp_caps.Tool.make ~input_schema
    ~decode:(fun json ->
      match json with
      | `Assoc [("message", `String message)] -> Ok message
      | `Assoc [("undecodable", `String _)] -> Error "undecodable input"
      | _ -> Error "message must be a string")
    ~run:(fun grant message ->
      Ok (Mcp_caps.Tool.Output.text (prefix ^ grant ^ ":" ^ message)))
    name

let only_tool registry =
  match Registry.entries registry with
  | [ entry ] -> entry
  | entries -> Alcotest.failf "expected one entry, got %d" (List.length entries)

let call registry name json =
  match Registry.find registry name with
  | None -> Alcotest.failf "%s is not registered" name
  | Some entry -> (
      match Registry.entry_call entry json with
      | Ok output -> Mcp_caps.Tool.Output.text_of output
      | Error error -> Alcotest.failf "%s failed: %s" name (Mcp_caps.Error.render error))

let message text = `Assoc [("message", `String text)]

let empty_registry _ =
  Alcotest.(check int) "no entries" 0 (List.length (Registry.entries Registry.empty))

let add_packs_the_grant _ =
  match Registry.add Registry.empty (make_tool ~name:"echo" ~prefix:"") ~grant:"grant-a" with
  | Error _ -> Alcotest.fail "first add should succeed"
  | Ok registry ->
      Alcotest.(check int) "one entry" 1 (List.length (Registry.entries registry));
      Alcotest.(check string) "named" "echo" (Registry.entry_name (only_tool registry));
      Alcotest.(check string) "ran under its own grant" "grant-a:hi"
        (call registry "echo" (message "hi"))

let duplicate_names_are_refused _ =
  match
    Registry.add Registry.empty (make_tool ~name:"echo" ~prefix:"") ~grant:"grant-a"
    >>= fun registry ->
    Registry.add registry (make_tool ~name:"echo" ~prefix:"") ~grant:"grant-b"
  with
  | Ok _ -> Alcotest.fail "a duplicate name should not register"
  | Error (Registry.Duplicate_tool name) -> Alcotest.(check string) "names" "echo" name

(* Two tools, same input shape, different grants: this is the closure packing
   Server relies on, and the case where a shared authority value would show up. *)
let grants_do_not_leak_between_tools _ =
  match
    Registry.add Registry.empty (make_tool ~name:"left" ~prefix:"left ") ~grant:"L"
    >>= fun registry ->
    Registry.add registry (make_tool ~name:"right" ~prefix:"right ") ~grant:"R"
  with
  | Error _ -> Alcotest.fail "both adds should succeed"
  | Ok registry ->
      (* interleaved, so an entry reading a mutable grant would be caught *)
      Alcotest.(check string) "left first" "left L:one" (call registry "left" (message "one"));
      Alcotest.(check string) "right first" "right R:one"
        (call registry "right" (message "one"));
      Alcotest.(check string) "left second" "left L:two" (call registry "left" (message "two"));
      Alcotest.(check string) "right second" "right R:two"
        (call registry "right" (message "two"))

(* The input schema has already passed by the time decode runs, so a decoder
   refusal is a tool result, never a transport failure. *)
let decoder_failure_is_an_invalid_error _ =
  match
    Registry.add Registry.empty (make_tool ~name:"echo" ~prefix:"") ~grant:"grant-a"
  with
  | Error _ -> Alcotest.fail "add should succeed"
  | Ok registry -> (
      match
        Registry.entry_call (only_tool registry) (`Assoc [("undecodable", `String "x")])
      with
      | Ok _ -> Alcotest.fail "the decoder should have refused"
      | Error error ->
          Alcotest.(check bool) "kind is Invalid" true
            (Mcp_caps.Error.kind error = Mcp_caps.Error.Invalid))

let () =
  Alcotest.run "mcp-caps/registry"
    [
      ( "registry",
        [
          Alcotest.test_case "empty is empty" `Quick empty_registry;
          Alcotest.test_case "add closes the grant over run" `Quick add_packs_the_grant;
          Alcotest.test_case "a duplicate name is refused" `Quick duplicate_names_are_refused;
          Alcotest.test_case "grants do not leak between tools" `Quick
            grants_do_not_leak_between_tools;
          Alcotest.test_case "a decoder refusal is Error.Invalid" `Quick
            decoder_failure_is_an_invalid_error;
        ] );
    ]
