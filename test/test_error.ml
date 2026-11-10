let check_message what input expected =
  Alcotest.(check string) what expected (Mcp_caps.Error.sanitize input)

let one_line _ =
  check_message "newlines collapse" "first\nsecond\rthird\tfourth" "first second third fourth";
  check_message "edges trim" "   padded\n" "padded";
  let error = Mcp_caps.Error.make Mcp_caps.Error.Failed ~message:"provider said:\nSECRET" in
  Alcotest.(check string) "one line" "provider said: SECRET" (Mcp_caps.Error.message error)

let bounded _ =
  let long = String.make (Mcp_caps.Error.max_message_bytes + 900) 'a' in
  let sanitized = Mcp_caps.Error.sanitize long in
  Alcotest.(check bool)
    "cut, not kept"
    true
    (String.length sanitized > Mcp_caps.Error.max_message_bytes
    && String.length sanitized <= Mcp_caps.Error.max_message_bytes + 3)

let utf8_cut_is_never_mid_sequence _ =
  (* A cut through a multi-byte character would put an invalid string into JSON. *)
  let is_continuation char = (Char.code char land 0xC0) = 0x80 in
  let repeat text count = String.concat "" (List.init count (fun _ -> text)) in
  List.iter
    (fun text ->
      let sanitized = Mcp_caps.Error.sanitize text in
      let last = sanitized.[String.length sanitized - 1] in
      Alcotest.(check bool) "no split character" false (is_continuation last))
    [ repeat "é" 300; repeat "あ" 300; repeat "abé" 600 ]

let idempotent _ =
  List.iter
    (fun text ->
      let once = Mcp_caps.Error.sanitize text in
      Alcotest.(check string) "sanitize twice" once (Mcp_caps.Error.sanitize once))
    [ "a\nb"; String.make (Mcp_caps.Error.max_message_bytes * 2) 'x'; ""; "  ok  " ]

let kinds_are_stable _ =
  let cases =
    [
      (Mcp_caps.Error.Denied, "denied");
      (Invalid, "invalid");
      (Unavailable, "unavailable");
      (Timeout, "timeout");
      (Failed, "failed");
    ]
  in
  List.iter
    (fun (kind, name) ->
      let error = Mcp_caps.Error.make kind ~message:"x" in
      Alcotest.(check string) name name (Mcp_caps.Error.kind_to_string (Mcp_caps.Error.kind error));
      Alcotest.(check string) "render" (name ^ ": x") (Mcp_caps.Error.render error))
    cases

let () =
  Alcotest.run "mcp-caps/error"
    [
      ( "error",
        [
          Alcotest.test_case "a message is one line" `Quick one_line;
          Alcotest.test_case "a message is bounded" `Quick bounded;
          Alcotest.test_case "a cut cannot split a character" `Quick
            utf8_cut_is_never_mid_sequence;
          Alcotest.test_case "sanitize is idempotent" `Quick idempotent;
          Alcotest.test_case "kinds are stable" `Quick kinds_are_stable;
        ] );
    ]
