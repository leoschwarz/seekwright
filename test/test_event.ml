let renders_operation_and_outcome _ =
  let open Mcp_caps.Event in
  Alcotest.(check string)
    "ok"
    "caps.read_file ok"
    (render (make ~operation:"read_file" Ok));
  Alcotest.(check string)
    "denied"
    "caps.request failed:denied bytes=12"
    (render (with_bytes 12 (make ~operation:"request" (Failed Mcp_caps.Error.Denied))))

let notes_are_bounded_and_content_free _ =
  let open Mcp_caps.Event in
  let event =
    List.fold_left
      (fun acc index -> add_note "k" (Printf.sprintf "value %d\nsecond line" index) acc)
      (make ~operation:"read_file" Ok)
      (List.init (max_notes + 4) Fun.id)
  in
  Alcotest.(check int) "notes capped" max_notes (List.length (notes event));
  Alcotest.(check bool)
    "no second line"
    false
    (String.contains (render event) '\n')

let operation_and_keys_cannot_break_the_line _ =
  let open Mcp_caps.Event in
  let event =
    add_note "key\nwith newline" "value" (make ~operation:"read_\nfile" Ok)
  in
  Alcotest.(check string) "operation sanitized" "read_ file" (operation event);
  Alcotest.(check bool)
    "no second line"
    false
    (String.contains (render event) '\n')

let () =
  Alcotest.run "mcp-caps/event"
    [
      ( "event",
        [
          Alcotest.test_case "rendered one line" `Quick renders_operation_and_outcome;
          Alcotest.test_case "notes stay bounded" `Quick notes_are_bounded_and_content_free;
          Alcotest.test_case "operation and keys stay one line" `Quick
            operation_and_keys_cannot_break_the_line;
        ] );
    ]
