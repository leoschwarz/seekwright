(* The table half of the fetch path: which bodies are tables, and the
   rendering [path] addresses.

   Port of tests/fetch/test_tabledoc.py. Nothing here reaches the network and
   no extractor is involved. What is pinned is that [render_table] writes
   [Jsondoc]'s own line grammar — one line per row or cell, each starting at
   the root and labelled with the path that addresses it — because that shared
   grammar is the whole reason [fetch]'s [path], [structure] and [offset]
   answer a CSV with no new machinery, and a rendering that drifted from it
   would be silently misread as a JSON shape. The two cuts are pinned here too:
   a rendering is bounded by [Jsondoc]'s budget, and a record stream that stops
   parsing stops printing rather than failing the fetch. *)

module J = Seekwright_fetch.Jsondoc
module T = Seekwright_fetch.Tabledoc
module A = Alcotest

let table_body =
  "id,price,city,qty,note\n1,12.50,London,3,four\n2,7.00,Leeds,11,short\n3,3.99,Bristol,2,x\n4,120.00,Perth,1,long note here\n5,0.50,Cork,7,\n"

let lines t = String.split_on_char '\n' t

let render ?(delimiter = ",") text =
  (* These fixtures are tables by construction; a [None] here is a broken
     fixture. *)
  match T.render_table text ~delimiter with
  | Some rendered -> rendered
  | None -> A.fail "fixture did not render"

let table () = render table_body

let find_at hay needle =
  let n = String.length hay and m = String.length needle in
  let rec go i = if i + m > n then None else if String.sub hay i m = needle then Some i else go (i + 1) in
  go 0

let contains_substring hay needle = find_at hay needle <> None

let assert_in needle ls =
  if not (List.mem needle ls) then
    A.failf "no line %S among %d lines" needle (List.length ls) ()

(* [TestRecognising] *)
let test_the_types_that_name_a_table_by_themselves () =
  A.check A.bool "text/csv" true (T.is_table_media "text/csv");
  A.check A.bool "application/csv" true (T.is_table_media "application/csv");
  A.check A.bool "text/tab-separated-values" true (T.is_table_media "text/tab-separated-values");
  A.check A.bool "text/plain" false (T.is_table_media "text/plain")

let test_a_spreadsheet_type_is_not_claimed () =
  (* [vnd.ms-excel] is as often a binary workbook as a CSV export, and a guess
     is not a read. *)
  A.check A.bool "vnd.ms-excel" false (T.is_table_media "application/vnd.ms-excel")

(* [TestRendering] *)
let test_the_whole_small_table_renders () =
  let ls = lines (table ()) in
  A.check (A.list A.string) "head"
    [ "$  object(1)"; "$.rows  array(5)"; "$.rows[0]  object(5)"; "$.rows[0].id  \"1\"" ]
    (List.filteri (fun i _ -> i < 4) ls);
  assert_in "$.rows[0].price  \"12.50\"" ls;
  assert_in "$.rows[4]  object(5)" ls

let test_every_cell_is_a_quoted_string_whatever_it_holds () =
  (* A CSV has no types, so [007] and [1.50] come back as the exact text the
     file wrote. *)
  let ls = lines (render "id,price,code,empty\n1,1.50,007,\n") in
  assert_in "$.rows[0].price  \"1.50\"" ls;
  assert_in "$.rows[0].code  \"007\"" ls;
  assert_in "$.rows[0].empty  \"\"" ls

let test_a_cell_holding_a_newline_stays_on_one_line () =
  (* The line grammar is one node per line, so the leaf is JSON-escaped, not
     wrapped. *)
  let ls = lines (render "a,b\n\"x\ny\",2\n") in
  assert_in "$.rows[0].a  \"x\\ny\"" ls;
  A.check A.int "line count" 5 (List.length ls)

let test_a_column_name_that_cannot_be_written_bare_is_quoted_and_reads_back () =
  (* The path is a caller's argument, so a header cell with a newline has to
     round-trip. *)
  let rendered = render "\"a\nb\",c\n1,2\n" in
  let path = "$.rows[0][\"a\\nb\"]" in
  assert_in (path ^ "  \"1\"") (lines rendered);
  J.parse_path path |> ignore

(* [TestHeaderRules] *)
let test_an_empty_header_cell_gets_a_positional_name () =
  assert_in "$.rows[0].column2  \"2\""
    (lines (render "id,,note\n1,2,3\n"))

let test_a_long_header_cell_is_cut_to_the_cap () =
  (* The name labels every cell under it and is a printed path, so it cannot
     be unbounded. *)
  let rendered = render (String.make 200 'z' ^ ",b\n1,2\n") in
  let label = "$.rows[0]." ^ String.make T.max_column_name_chars 'z' in
  assert_in (label ^ "  \"1\"") (lines rendered);
  A.check A.bool "the cap holds" false
    (contains_substring rendered (String.make (T.max_column_name_chars + 1) 'z'))

let test_a_bom_is_not_part_of_the_first_column_name () =
  let ls = lines (render "\xef\xbb\xbfid,name\n1,Ada\n") in
  assert_in "$.rows[0].id  \"1\"" ls;
  assert_in "$.rows[0].name  \"Ada\"" ls

let test_a_blank_line_between_records_does_not_consume_a_row_index () =
  let ls = lines (render "a,b\n1,x\n\n2,y\n") in
  assert_in "$.rows[1]  object(2)" ls;
  assert_in "$.rows[1].a  \"2\"" ls;
  A.check A.bool "no third row index" false (contains_substring (String.concat "\n" ls) "$.rows[2]")

let test_two_columns_with_one_name_print_twice_and_both_are_addressable () =
  (* The file's defect is reported, not renamed away: [path] answers both
     cells. *)
  let spans, _ = J.select_paths (render "id,id\n1,2\n") "$.rows[0].id" ~max_chars:6000 in
  A.check (A.list A.string) "both cells"
    [ "$.rows[0].id  \"1\"\n$.rows[0].id  \"2\"" ]
    (List.map snd spans)

(* [TestSharedGrammar] *)
let test_every_line_is_a_path_the_grammar_reads () =
  List.iter
    (fun line ->
      let path =
        match find_at line "  " with
        | Some i -> String.sub line 0 i
        | None -> line
      in
      J.parse_path path |> ignore)
    (lines (table ()))

let test_the_shape_names_the_columns_and_withholds_the_values () =
  match J.render_schema (table ()) with
  | None -> A.fail "schema refused a rendering"
  | Some schema ->
      let ls = lines schema in
      assert_in "$.rows[*]  object(5)" ls;
      List.iter
        (fun column -> assert_in (Printf.sprintf "$.rows[*].%s  string" column) ls)
        [ "id"; "price"; "city"; "qty"; "note" ];
      if contains_substring schema "12.50" then A.fail "a value rode through"

let test_one_column_of_every_row_is_one_wildcard_step () =
  let spans, dropped = J.select_paths (table ()) "$.rows[*].price" ~max_chars:6000 in
  A.check (A.list A.string) "one cell per row"
    [ "$.rows[0].price  \"12.50\"";
      "$.rows[1].price  \"7.00\"";
      "$.rows[2].price  \"3.99\"";
      "$.rows[3].price  \"120.00\"";
      "$.rows[4].price  \"0.50\"" ]
    (List.map snd spans);
  A.check A.int "nothing dropped" 0 dropped

let test_a_slice_of_rows_is_two_whole_row_blocks () =
  let rendered = table () in
  let spans, dropped = J.select_paths rendered "$.rows[1:3]" ~max_chars:6000 in
  A.check A.int "nothing dropped" 0 dropped;
  A.check A.bool "adjacent rows are one span" true (List.length spans = 1);
  let offset, block = List.nth spans 0 in
  let ls = lines block in
  A.check A.int "twelve lines" 12 (List.length ls);
  A.check A.string "first row" "$.rows[1]  object(5)" (List.nth ls 0);
  A.check A.string "second row" "$.rows[2]  object(5)" (List.nth ls 6);
  A.check A.string "last cell" "$.rows[2].note  \"x\"" (List.nth ls (List.length ls - 1));
  A.check A.string "offset indexes the rendering"
    block (String.sub rendered offset (String.length block))

let test_a_column_name_holding_a_colon_stays_a_name_through_the_grammar () =
  (* [Price: USD] is one header cell, and a slice bound is never quoted. The
     only header character that ever broke the round trip, and it broke all
     three readers at once: the path, the shape view, and a [path] read of an
     unrelated column, since the selector re-reads every printed line. *)
  let rendered = render "id,Price: USD\n1,12.50\n" in
  let line =
    List.find
      (fun l -> String.starts_with ~prefix:"$.rows[0][\"Price" l)
      (lines rendered)
  in
  let path =
    match find_at line "  " with
    | Some i -> String.sub line 0 i
    | None -> line
  in
  J.parse_path path |> ignore;
  match J.render_schema rendered with
  | None -> A.fail "schema refused"
  | Some schema ->
      assert_in "$.rows[*][\"Price: USD\"]  string" (lines schema);
  let spans, dropped = J.select_paths rendered "$.rows[*][\"Price: USD\"]" ~max_chars:600 in
  A.check A.int "nothing dropped" 0 dropped;
  A.check (A.list A.string) "the column answers"
    [ "$.rows[0][\"Price: USD\"]  \"12.50\"" ]
    (List.map snd spans)

(* [TestDelimiters] *)
let test_a_tab_type_declares_its_delimiter_whatever_the_body_looks_like () =
  (* The type states the delimiter, so a body full of commas does not out-vote
     it. *)
  A.check A.string "tab declared" "\t"
    (T.table_delimiter "text/tab-separated-values" "a,b,c\n1,2,3\n")

let test_a_european_export_served_as_csv_is_read_on_semicolons () =
  A.check A.string "semicolon" ";" (T.table_delimiter "text/csv" "a;b;c\n1;2;3\n")

let test_a_comma_inside_a_quoted_value_does_not_move_the_delimiter () =
  (* Counting commas would be fooled here; parsing the head four ways is not. *)
  A.check A.string "comma" "," (T.table_delimiter "text/csv" "a,b\n\"x,y,z\",2\n")

let test_a_pipe_separated_body_is_sniffed () =
  A.check A.string "pipe" "|" (T.table_delimiter "text/csv" "a|b|c\n1|2|3\n")

let test_a_separator_inside_a_quoted_cell_does_not_outvote_the_delimiter () =
  (* An address cell of [1 Main St; London; UK] is one cell, not four
     columns. *)
  let body = "id,address\n1,\"1 Main St; London; UK\"\n2,\"2 Oak Ave; Leeds; UK\"\n" in
  A.check A.string "comma wins" "," (T.table_delimiter "text/csv" body);
  A.check A.string "the cell is one column"
    "$.rows[0].address  \"1 Main St; London; UK\""
    (List.nth (lines (render body)) 4)

let test_prose_with_no_delimiter_stays_on_commas_and_renders_one_column () =
  let text = "some prose here\nand more of it\n" in
  A.check A.string "commas" "," (T.table_delimiter "text/csv" text);
  A.check A.string "one column"
    "$.rows[0][\"some prose here\"]  \"and more of it\""
    (List.nth (lines (render text)) 3)

(* [TestCuts] *)
let test_a_table_wider_than_its_budget_ends_with_the_line_naming_the_cut () =
  let body =
    "id,price,city,qty,note\n"
    ^ String.concat "" (List.init 3000 (fun n -> Printf.sprintf "%d,12.50,London,3,four\n" n))
  in
  let rendered = render body in
  let budget = max J.min_render_chars (J.max_render_ratio * String.length body) in
  let last = List.nth (lines rendered) (List.length (lines rendered) - 1) in
  match find_at last "]" with
  | None -> A.fail "cut line has no row index"
  | Some i ->
      let printed = int_of_string (String.sub last 7 (i - 7)) in
      A.check A.bool "some rows printed" true (printed > 0 && printed < 3000);
      A.check A.string "the cut line"
        (Printf.sprintf
           "$.rows[%d]  not rendered: the table expands past the budget of %d \
            characters, %d times the file's own %d; %d rows are printed above and no \
            further row of the file is addressable in this page -- fetch with `offset` \
            to page through what is here, or raise fetch.max_download_bytes, the budget \
            being a ratio of it"
           printed budget J.max_render_ratio (String.length body) printed)
        last;
      assert_in (Printf.sprintf "$.rows  array(%d)" printed) (lines rendered);
      A.check A.bool "within a small multiple" true (String.length rendered < 5 * String.length body);
      let spans, _ = J.select_paths rendered (Printf.sprintf "$.rows[%d]" (printed + 5)) ~max_chars:600 in
      A.check A.int "the row count printed is a bound, not the file's length" 0
        (List.length spans)

let test_the_rows_above_a_parse_stop_are_kept_and_counted () =
  (* The record-stream rule: whole rows survive where the reader gave up. *)
  let body = "id,name\n1,Ada\n" ^ String.make 200_000 'x' ^ "\n" in
  let rendered = render body in
  assert_in "$.rows[0].name  \"Ada\"" (lines rendered);
  A.check A.string "the stop line"
    (Printf.sprintf
       "$.rows[1]  not rendered: this file stopped parsing at this row (field larger \
        than field limit (%d)); the rows above it are complete"
       T.field_limit)
    (List.nth (lines rendered) (List.length (lines rendered) - 1))

let test_a_parse_stop_before_any_row_leaves_the_body_as_the_answer () =
  (* Columns and no row say nothing about the file, so the bytes ride on. *)
  A.check (A.option A.string) "no rendering" None
    (T.render_table ("a\n" ^ String.make 200_000 'x' ^ "\n") ~delimiter:",")

(* [TestNothingToRender] *)
let test_an_empty_body_renders_as_nothing () =
  A.check (A.option A.string) "empty" None (T.render_table "" ~delimiter:",");
  A.check (A.option A.string) "blank lines" None (T.render_table "\n\n" ~delimiter:",")

let test_a_header_only_file_is_a_table_with_no_rows () =
  A.check A.string "header only" "$  object(1)\n$.rows  array(0)" (render "a,b\n")

let () =
  Alcotest.run "tabledoc"
    [
      ( "recognising",
        [ Alcotest.test_case "the types that name a table by themselves" `Quick
            test_the_types_that_name_a_table_by_themselves;
          Alcotest.test_case "a spreadsheet type is not claimed" `Quick
            test_a_spreadsheet_type_is_not_claimed ] );
      ( "rendering",
        [ Alcotest.test_case "the whole small table renders" `Quick
            test_the_whole_small_table_renders;
          Alcotest.test_case "every cell is a quoted string whatever it holds" `Quick
            test_every_cell_is_a_quoted_string_whatever_it_holds;
          Alcotest.test_case "a cell holding a newline stays on one line" `Quick
            test_a_cell_holding_a_newline_stays_on_one_line ] );
      ( "header rules",
        [ Alcotest.test_case "a column name that cannot be written bare is quoted" `Quick
            test_a_column_name_that_cannot_be_written_bare_is_quoted_and_reads_back;
          Alcotest.test_case "an empty header cell gets a positional name" `Quick
            test_an_empty_header_cell_gets_a_positional_name;
          Alcotest.test_case "a long header cell is cut to the cap" `Quick
            test_a_long_header_cell_is_cut_to_the_cap;
          Alcotest.test_case "a bom is not part of the first column name" `Quick
            test_a_bom_is_not_part_of_the_first_column_name;
          Alcotest.test_case "a blank line between records does not consume a row index" `Quick
            test_a_blank_line_between_records_does_not_consume_a_row_index;
          Alcotest.test_case "two columns with one name print twice" `Quick
            test_two_columns_with_one_name_print_twice_and_both_are_addressable ] );
      ( "shared grammar",
        [ Alcotest.test_case "every line is a path the grammar reads" `Quick
            test_every_line_is_a_path_the_grammar_reads;
          Alcotest.test_case "the shape names the columns and withholds the values" `Quick
            test_the_shape_names_the_columns_and_withholds_the_values;
          Alcotest.test_case "one column of every row is one wildcard step" `Quick
            test_one_column_of_every_row_is_one_wildcard_step;
          Alcotest.test_case "a slice of rows is two whole row blocks" `Quick
            test_a_slice_of_rows_is_two_whole_row_blocks;
          Alcotest.test_case "a column name holding a colon stays a name" `Quick
            test_a_column_name_holding_a_colon_stays_a_name_through_the_grammar ] );
      ( "delimiters",
        [ Alcotest.test_case "a tab type declares its delimiter" `Quick
            test_a_tab_type_declares_its_delimiter_whatever_the_body_looks_like;
          Alcotest.test_case "a european export served as csv is read on semicolons" `Quick
            test_a_european_export_served_as_csv_is_read_on_semicolons;
          Alcotest.test_case "a comma inside a quoted value does not move the delimiter" `Quick
            test_a_comma_inside_a_quoted_value_does_not_move_the_delimiter;
          Alcotest.test_case "a pipe separated body is sniffed" `Quick
            test_a_pipe_separated_body_is_sniffed;
          Alcotest.test_case "a separator inside a quoted cell does not outvote" `Quick
            test_a_separator_inside_a_quoted_cell_does_not_outvote_the_delimiter;
          Alcotest.test_case "prose with no delimiter stays on commas" `Quick
            test_prose_with_no_delimiter_stays_on_commas_and_renders_one_column ] );
      ( "cuts",
        [ Alcotest.test_case "a table wider than its budget ends with the cut line" `Quick
            test_a_table_wider_than_its_budget_ends_with_the_line_naming_the_cut;
          Alcotest.test_case "the rows above a parse stop are kept and counted" `Quick
            test_the_rows_above_a_parse_stop_are_kept_and_counted;
          Alcotest.test_case "a parse stop before any row leaves the body" `Quick
            test_a_parse_stop_before_any_row_leaves_the_body_as_the_answer ] );
      ( "nothing to render",
        [ Alcotest.test_case "an empty body renders as nothing" `Quick
            test_an_empty_body_renders_as_nothing;
          Alcotest.test_case "a header only file is a table with no rows" `Quick
            test_a_header_only_file_is_a_table_with_no_rows ] );
    ]
