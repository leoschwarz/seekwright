let check_message what input expected =
  Alcotest.(check string) what expected (Mcp_caps.Error.sanitize input)

let one_line _ =
  check_message "newlines collapse" "first\nsecond\rthird\tfourth" "first second third fourth";
  check_message "edges trim" "   padded\n" "padded";
  let error = Mcp_caps.Error.make Mcp_caps.Error.Failed ~message:"provider said:\nSECRET" in
  Alcotest.(check string) "one line" "provider said: SECRET" (Mcp_caps.Error.message error)

(* A real validator, so the truncation test can fail: checking the last byte of
   the result cannot, because [sanitize] always ends it with "...". *)
let is_valid_utf8 text =
  let length = String.length text in
  let rec continuation index stop accumulated =
    if index > stop then Some accumulated
    else
      let byte = Char.code text.[index] in
      if byte land 0xC0 <> 0x80 then None
      else continuation (index + 1) stop ((accumulated lsl 6) lor (byte land 0x3F))
  in
  let rec go index =
    if index >= length then true
    else
      let byte = Char.code text.[index] in
      if byte < 0x80 then go (index + 1)
      else
        let needed, minimum =
          if byte land 0xE0 = 0xC0 then (1, 0x80)
          else if byte land 0xF0 = 0xE0 then (2, 0x800)
          else if byte land 0xF8 = 0xF0 then (3, 0x10000)
          else (-1, 0)
        in
        if needed < 0 || index + needed >= length then false
        else
          match continuation (index + 1) (index + needed) (byte land (0x7F lsr (needed + 1))) with
          | None -> false
          | Some codepoint ->
              codepoint >= minimum
              && codepoint <= 0x10FFFF
              && not (codepoint >= 0xD800 && codepoint <= 0xDFFF)
              && go (index + needed + 1)
  in
  go 0

(* [sanitize] appends the ellipsis only when it cut, so the prefix under test is
   the result without exactly those three bytes. *)
let truncated_prefix sanitized =
  let length = String.length sanitized in
  if length >= 3 && String.sub sanitized (length - 3) 3 = "..." then
    String.sub sanitized 0 (length - 3)
  else sanitized

let bounded _ =
  let long = String.make (Mcp_caps.Error.max_message_bytes + 900) 'a' in
  let sanitized = Mcp_caps.Error.sanitize long in
  Alcotest.(check bool)
    "cut, not kept"
    true
    (String.length sanitized > Mcp_caps.Error.max_message_bytes
    && String.length sanitized <= Mcp_caps.Error.max_message_bytes + 3
    && is_valid_utf8 (truncated_prefix sanitized))

let utf8_cut_is_never_mid_sequence _ =
  (* A cut through a multi-byte character would put an invalid string into JSON.
     Each input is over the cap, so [sanitize] has to choose a cut inside
     multibyte text: 300 × "é" cuts in a 2-byte character, "あ" in a 3-byte one,
     and "abé" changes the alignment. *)
  let is_lead char = (Char.code char land 0xC0) = 0xC0 in
  let repeat text count = String.concat "" (List.init count (fun _ -> text)) in
  List.iter
    (fun text ->
      let sanitized = Mcp_caps.Error.sanitize text in
      let prefix = truncated_prefix sanitized in
      Alcotest.(check bool) "the cut happened" true (String.length prefix < String.length text);
      Alcotest.(check bool) "the prefix is valid UTF-8" true (is_valid_utf8 prefix);
      Alcotest.(check bool)
        "the byte before the ellipsis is not a lead byte"
        false
        (is_lead prefix.[String.length prefix - 1]);
      Alcotest.(check bool)
        "stays within the cap"
        true
        (String.length sanitized <= Mcp_caps.Error.max_message_bytes + 3))
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
