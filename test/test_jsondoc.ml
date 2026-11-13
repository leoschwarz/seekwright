(* The JSON half of the fetch path: the rendering a model reads, and the
   grammar that addresses it.

   Port of tests/fetch/test_jsondoc.py. Nothing here reaches the network. What
   is pinned is the pair of contracts the rest of the tree stands on: that
   every line [render_json] writes is readable by [parse_path], because a
   caller copies a path out of a page and gets that value back by asking for
   it; and that [select_paths] spends [fetch.max_match_chars] the way
   [select_passages] does, so one config key bounds both selectors with one
   meaning.

   One Python case is not ported: the tracemalloc probe that measures the
   walk's peak allocation. OCaml has no tracemalloc, the walk is the same
   one-frame-per-level shape the Python walk moved to, and a memory figure a
   different runtime produces is not the fact the Python suite pinned. *)

module J = Seekwright_fetch.Jsondoc
module A = Alcotest
open Test_support

let doc =
  "\n{\n  \"total_count\": 1615,\n  \"items\": [\n    {\"id\": 1, \"name\": \"first\", \"tags\": [\"a\", \"b\"], \"meta\": {\"score\": 1.5}},\n    {\"id\": 2, \"name\": \"second\", \"tags\": [], \"meta\": {}}\n  ],\n  \"next\": null\n}\n"

let lines t = String.split_on_char '\n' t

let render body =
  (* These fixtures are documents by construction; a [None] here is a broken
     fixture. *)
  match J.render_json body with
  | Some text -> text
  | None -> A.fail "fixture did not render"

let rendered () = render doc

(* The offset of a needle the fixture is known to carry; a missing one is a
   broken fixture, and the failure names the needle. *)
let require_offset text needle =
  (* The fixtures are ASCII, so the byte index is the codepoint index. *)
  match find_sub ~haystack:text ~needle:needle () with
  | Some i -> i
  | None -> A.failf "needle %S not found" needle ()

let assert_in needle ls =
  if not (List.mem needle ls) then
    A.failf "no line %S among %d lines" needle (List.length ls) ()

let step_eq a b =
  match (a, b) with
  | J.Key x, J.Key y -> x = y
  | J.Position x, J.Position y -> x = y
  | J.Every, J.Every -> true
  | J.Bounds (a1, b1), J.Bounds (a2, b2) -> a1 = a2 && b1 = b2
  | _ -> false

let steps_eq a b = List.length a = List.length b && List.for_all2 step_eq a b

let show_step s =
  match s with
  | J.Key k -> Printf.sprintf "key %S" k
  | J.Position i -> Printf.sprintf "position %d" i
  | J.Every -> "every"
  | J.Bounds (a, b) ->
      Printf.sprintf "bounds %s:%s"
        (match a with Some x -> string_of_int x | None -> "")
        (match b with Some x -> string_of_int x | None -> "")

let check_steps exp got =
  if not (steps_eq exp got) then
    A.failf "steps differ: expected %s, got %s"
      (String.concat ", " (List.map show_step exp))
      (String.concat ", " (List.map show_step got))
      ()

let assert_path_syntax ?(match_ = None) f =
  match f () with
  | exception J.Path_syntax msg -> (
      match match_ with
      | Some needle when not (contains ~haystack:msg ~needle:needle) ->
          A.failf "message %S lacks %S" msg needle ()
      | _ -> ())
  | _ -> A.fail "expected Path_syntax"

let json_dumps_items n =
  (* json.dumps({"items": [{"n": 1}] * n}) *)
  "{\"items\": ["
  ^ String.concat ", " (List.init n (fun _ -> "{\"n\": 1}"))
  ^ "]}"

(* [TestRecognising] *)
let test_the_bare_types_are_json () =
  A.check A.bool "application/json is json" true (J.is_json_media "application/json");
  A.check A.bool "text/json is json" true (J.is_json_media "text/json");
  A.check A.bool "text/plain is not json" false (J.is_json_media "text/plain")

let test_the_structured_syntax_suffix_is_json_whatever_it_is_about () =
  (* RFC 6839: the suffix states the syntax, so no registry of prefixes is
     consulted. *)
  A.check A.bool "geo+json" true (J.is_json_media "application/geo+json");
  A.check A.bool "vnd.api+json" true (J.is_json_media "application/vnd.api+json");
  A.check A.bool "vnd.api+xml" false (J.is_json_media "application/vnd.api+xml")

let test_only_a_document_shape_sniffs_as_json () =
  (* A bare value is not a document, and guessing one from unlabelled bytes
     turns a CSV into one. *)
  A.check A.bool "whitespace then array" true (J.sniffs_json "   [1, 2]");
  A.check A.bool "object" true (J.sniffs_json "{\"a\": 1}");
  A.check A.bool "csv of numbers" false (J.sniffs_json "1,2,3");
  A.check A.bool "html" false (J.sniffs_json "<html><body>")

(* [TestRendering] *)
let test_a_container_names_itself_before_its_members () =
  let ls = lines (rendered ()) in
  A.check A.string "root header" "$  object(3)" (List.nth ls 0);
  assert_in "$.items  array(2)" ls;
  assert_in "$.items[0]  object(4)" ls

let test_a_leaf_is_compact_json_at_its_own_path () =
  let ls = lines (rendered ()) in
  assert_in "$.items[0].name  \"first\"" ls;
  assert_in "$.total_count  1615" ls;
  assert_in "$.next  null" ls

let test_kinds_survive_the_rendering () =
  (* A number, a string, a boolean and a null have to stay tellable apart, or
     the map lies. *)
  let ls =
    lines (render "{\"a\": 1, \"b\": \"1\", \"c\": true, \"d\": \"true\", \"e\": null}")
  in
  A.check (A.list A.string) "kinds"
    [ "$.a  1"; "$.b  \"1\""; "$.c  true"; "$.d  \"true\""; "$.e  null" ]
    (List.tl ls)

let test_float_and_out_of_range_integers_are_leaves_too () =
  (* Every scalar Yojson can hand the walk is named by the [leaf] type: a float
     keeps Python's [repr], and an integer past the machine word arrives as
     [Intlit] and is printed verbatim. *)
  let ls = lines (render "{\"f\": 1.5, \"big\": 123456789012345678901234567890}") in
  A.check (A.list A.string) "leaf kinds"
    [ "$  object(2)"; "$.f  1.5"; "$.big  123456789012345678901234567890" ] ls

(* F8: the renderer and the media-type phrase stay total. [dump_leaf]'s domain
   is the [leaf] type, so it needs no unreachable arm; [describe_types] walks
   its list rather than taking [List.hd]/[List.tl]. The compiler proves the
   first at the call site, and this reads the sources so a partial accessor
   cannot return unnoticed. *)
let test_no_unreachable_arm_or_partial_list_accessor () =
  let forbidden = [ "assert false"; "List.hd"; "List.tl" ] in
  List.iter
    (fun (name, path) ->
      let source = read_file path in
      List.iter
        (fun needle -> excludes (Printf.sprintf "%s has no %S" name needle) needle source)
        forbidden)
    [ ("jsondoc.ml", "../lib/fetch/jsondoc.ml");
      ("tabledoc.ml", "../lib/fetch/tabledoc.ml");
      ("extractor.ml", "../lib/fetch/extractor.ml") ]

let test_document_order_is_kept () =
  let ls = lines (render "{\"z\": 1, \"a\": 2}") in
  A.check (A.list A.string) "document order" [ "$.z  1"; "$.a  2" ] (List.tl ls)

let test_a_duplicate_key_keeps_its_first_place_and_its_last_value () =
  (* Python's object semantics, which the whole fetch path inherits: a repeated
     member is not a second line and not a dropped one — the key holds the place
     it first took and the value it last had, exactly as [json.loads] leaves it.
     The earlier fold in this module rebuilt the accumulator on every duplicate
     and could get the two halves apart; this pins both together. *)
  let ls = lines (render "{\"a\": 1, \"b\": 2, \"a\": 3}") in
  A.check A.string "the header counts members, not mentions" "$  object(2)" (List.nth ls 0);
  A.check (A.list A.string) "first place, last value" [ "$.a  3"; "$.b  2" ] (List.tl ls)

let test_a_key_repeated_tens_of_thousands_of_times_is_one_pass () =
  (* [max_download_bytes] caps a body's bytes, not its member count, so
     [{"k":1,}] repeated is a legal document at tens of thousands of members.
     A dedupe that scans and rebuilds its accumulator per member makes the parse
     quadratic before the rendering budget is even consulted — the Python suite
     measures that shape with [tracemalloc]; [Gc]'s word counters are this
     runtime's equivalent, and the ceiling below is many times the one-pass
     figure and far under what the quadratic fold allocated at the same size. *)
  let words_allocated () =
    (* [Gc.counters] is (minor_words, promoted_words, major_words) since the
       process started, and the total allocated is minor + major - promoted. *)
    let minor, promoted, major = Gc.counters () in
    minor +. major -. promoted
  in
  let n = 20_000 in
  let body = "{" ^ String.concat "," (List.init n (fun _ -> "\"k\": 1")) ^ "}" in
  let before = words_allocated () in
  (match J.render_json body with
  | Some text ->
      (* Every mention collapses: one line for the key, holding the last value. *)
      let ls = lines text in
      A.check A.string "one header" "$  object(1)" (List.nth ls 0);
      A.check (A.list A.string) "one member" [ "$.k  1" ] (List.tl ls)
  | None -> A.fail "the repeated-key body refused to render");
  let words = words_allocated () -. before in
  A.(check bool)
    (Printf.sprintf "the parse allocated %.0f words, not quadratically" words)
    true (words < 50_000_000.)

let test_an_empty_container_is_still_a_line () =
  let ls = lines (rendered ()) in
  assert_in "$.items[1].meta  object(0)" ls;
  assert_in "$.items[1].tags  array(0)" ls

let test_a_key_that_cannot_be_written_bare_is_quoted () =
  (* The path is a caller's argument, so it has to be re-readable, not pretty. *)
  let text = render "{\"a.b\": {\"c d\": [1]}, \"\": 5}" in
  assert_in "$[\"a.b\"][\"c d\"][0]  1" (lines text);
  assert_in "$[\"\"]  5" (lines text)

let test_text_is_not_ascii_escaped () =
  assert_in "$.name  \"Grün\"" (lines (render "{\"name\": \"Grün\"}"))

let test_a_body_that_is_not_one_document_renders_as_nothing () =
  (* HTML under a JSON type, a trailing comma and a JSON Lines stream are
     fetch outcomes, not exceptions. *)
  A.check (A.option A.string) "html" None (J.render_json "<html>not json</html>");
  A.check (A.option A.string) "trailing comma" None (J.render_json "{\"a\": 1,}");
  A.check (A.option A.string) "two documents" None (J.render_json "{\"a\": 1}\n{\"b\": 2}");
  A.check (A.option A.string) "empty" None (J.render_json "")

let test_deep_nesting_is_cut_at_the_depth_cap () =
  (* A body of nested brackets is not a document, and it must not cost more
     than itself. *)
  let body = String.make 5000 '[' ^ String.make 5000 ']' in
  match J.render_json body with
  | None -> A.fail "deep nesting did not render"
  | Some text ->
      if not (contains ~haystack:text ~needle:"not expanded: nested past depth") then
        A.fail "no depth cut line";
      A.check A.bool "size" true (String.length text < 4 * 5000)

let test_a_wide_document_inside_the_depth_cap_is_cut_by_size () =
  (* Depth bounds nesting only; the shape under the cap is bounded by its own
     budget. 99 levels is *inside* the cap, and 200k leaves under it each print
     a path label. *)
  let body =
    String.make 99 '['
    ^ String.concat "," (List.init 200_000 (fun _ -> "1"))
    ^ String.make 99 ']'
  in
  match J.render_json body with
  | None -> A.fail "wide document did not render"
  | Some text ->
      if not (contains ~haystack:text ~needle:"not rendered: the document expands past the budget of")
      then A.fail "no budget cut line";
      A.check A.bool "within a small multiple of the body" true
        (String.length text < 5 * String.length body)

let test_a_document_people_publish_is_never_cut () =
  (* The budget is there for a hostile shape, not for a large API response. *)
  let item i = Printf.sprintf "{\"name\": \"repository %d\", \"score\": 1.5}" i in
  let body = "{\"items\": [" ^ String.concat ", " (List.init 3000 item) ^ "]}" in
  match J.render_json body with
  | None -> A.fail "api response did not render"
  | Some text ->
      if contains ~haystack:text ~needle:"not rendered" then A.fail "response was cut";
      A.check A.int "line count" (3000 * 3 + 2) (List.length (lines text))

let test_every_rendered_path_reads_back_through_the_grammar () =
  (* The rendering and the grammar are one contract: a path off a page is a
     path a caller can send. *)
  List.iter
    (fun line ->
      let path =
        match find_sub ~haystack:line ~needle:"  " () with
        | Some i -> String.sub line 0 i
        | None -> line
      in
      J.parse_path path |> ignore)
    (lines (rendered ()))

(* [TestGrammar] *)
let test_the_shapes_the_grammar_reads () =
  check_steps [ J.Key "a"; J.Key "b" ] (J.parse_path "$.a.b");
  check_steps [ J.Key "a b"; J.Position 0 ] (J.parse_path "$[\"a b\"][0]");
  check_steps [ J.Key "items"; J.Every; J.Key "name" ] (J.parse_path "$.items[*].name");
  check_steps [ J.Key "items"; J.Bounds (Some 1, Some 4) ] (J.parse_path "$.items[1:4]");
  check_steps [ Bounds (Some 2, None) ] (J.parse_path "$[2:]")

let test_the_root_is_optional () =
  check_steps (J.parse_path "$.items[0]") (J.parse_path "items[0]");
  A.check A.int "root alone" 0 (List.length (J.parse_path "$"))

let test_a_bracketed_key_is_read_in_either_quoting () =
  (* The renderer writes JSON quoting; a caller typing a path writes
     JSONPath's. *)
  check_steps (J.parse_path "$[\"items\"]") (J.parse_path "$['items']");
  check_steps [ J.Key "items" ] (J.parse_path "$[\"items\"]");
  check_steps [ J.Key "a b" ] (J.parse_path "$['a b']")

let test_a_quoted_key_holding_a_colon_is_a_name_not_a_slice () =
  (* The renderer writes this spelling for a key like [Price: USD]. Read in
     the other order — bounds before quotes — the colon turns the name into a
     slice with an unparseable bound, and one such line makes the whole
     rendering unreadable to [structure] and to every other [path]. *)
  check_steps [ J.Key "a: b" ] (J.parse_path "$[\"a: b\"]");
  let text = render "{\"a: b\": 1}" in
  let line = List.nth (lines text) 1 in
  A.check A.string "quoted key line" "$[\"a: b\"]  1" line;
  let path =
    match find_sub ~haystack:line ~needle:"  " () with
    | Some i -> String.sub line 0 i
    | None -> line
  in
  check_steps [ J.Key "a: b" ] (J.parse_path path)

let test_a_blank_path_is_refused_rather_than_read_as_the_root () =
  (* [path=" "] returning the whole document is a typo turning into another
     request. *)
  assert_path_syntax ~match_:(Some "names nothing") (fun () -> J.parse_path " ");
  assert_path_syntax ~match_:(Some "names nothing") (fun () -> J.parse_path "")

let test_a_path_refusal_keeps_printable_non_ascii_readable () =
  (* The oracle's refusal messages use [repr], which leaves a printable
     non-ASCII token readable. The ASCII-only escape stays for the path
     rendering itself, not for what a refusal quotes back (F1.5). *)
  assert_path_syntax
    ~match_:(Some "cannot read the bracketed step ['caf\xc3\xa9']")
    (fun () -> J.parse_path "$.items[caf\xc3\xa9]")

let test_a_sloppy_dot_before_a_bracket_is_tolerated () =
  check_steps (J.parse_path "$[\"a b\"]") (J.parse_path "$[\"a b\"]")

let bad_paths =
  [ "$.items[";
    "$.items[]";
    "$.items[-1]";
    "$.a[1:x]";
    "$.a[0:-1]";
    "$..name";
    "$.items[?(@.id)]";
    "$.a]b" ]

let test_a_path_this_grammar_cannot_honour_is_refused_by_name () =
  List.iter (fun bad -> assert_path_syntax (fun () -> J.parse_path bad)) bad_paths

let test_a_filter_says_so_rather_than_matching_nothing () =
  (* Silence would read as "no such field"; the caller wrote something
     unsupported. *)
  assert_path_syntax ~match_:(Some "bracketed step") (fun () -> J.parse_path "$.items[?(@.id)]")

let test_negative_indices_are_refused_with_the_alternative () =
  assert_path_syntax ~match_:(Some "[0:5]") (fun () -> J.parse_path "$.items[-1]")

(* [TestSelecting] *)
let test_a_leaf_is_one_span () =
  let text = rendered () in
  let needle = "$.items[0].name  \"first\"" in
  let spans, dropped = J.select_paths text "$.items[0].name" ~max_chars:6000 in
  A.check (A.list (A.pair A.int A.string)) "one span"
    [ (require_offset text needle, needle) ] spans;
  A.check A.int "nothing dropped" 0 dropped

let test_a_container_is_its_whole_subtree () =
  let spans, _ = J.select_paths (rendered ()) "$.items[1]" ~max_chars:6000 in
  A.check A.int "one span" 1 (List.length spans);
  let text = snd (List.nth spans 0) in
  A.check A.bool "starts at the row object" true
    (String.starts_with ~prefix:"$.items[1]  object(4)" text);
  if not (contains ~haystack:text ~needle:"$.items[1].name") then
    A.fail "subtree lost its member";
  if contains ~haystack:text ~needle:"$.total_count" then
    A.fail "took more than the subtree"

let test_a_wildcard_selects_one_line_per_element () =
  let spans, _ = J.select_paths (rendered ()) "$.items[*].name" ~max_chars:6000 in
  A.check (A.list A.string) "one line per element"
    [ "$.items[0].name  \"first\""; "$.items[1].name  \"second\"" ]
    (List.map snd spans)

let test_a_slice_selects_a_range_of_an_array () =
  let spans, _ = J.select_paths (rendered ()) "$.items[0:1]" ~max_chars:6000 in
  A.check A.bool "starts at the first row" true
    (String.starts_with ~prefix:"$.items[0]  object(4)" (snd (List.nth spans 0)));
  A.check A.bool "slice ends before the second" false
    (contains ~haystack:(snd (List.nth spans 0)) ~needle:"$.items[1]")

let test_an_index_segment_is_a_step_not_a_character_prefix () =
  let spans, _ = J.select_paths (render "{\"a\": {\"b\": 1}}") "$[0]" ~max_chars:600 in
  A.check A.int "no span" 0 (List.length spans)

let test_offsets_index_the_full_rendering () =
  let text = rendered () in
  let spans, _ = J.select_paths text "$.items[*].tags" ~max_chars:6000 in
  List.iter
    (fun (offset, span) ->
      A.check A.string "offset indexes the rendering"
        span (String.sub text offset (String.length span)))
    spans

let test_a_path_that_matches_nothing_reports_nothing () =
  let spans, dropped = J.select_paths (rendered ()) "$.nope" ~max_chars:6000 in
  A.check A.int "no spans" 0 (List.length spans);
  A.check A.int "nothing dropped" 0 dropped

let test_the_whole_document_is_the_root () =
  let spans, dropped = J.select_paths (rendered ()) "$" ~max_chars:6000 in
  A.check A.bool "starts at the root" true
    (String.starts_with ~prefix:"$  object(3)" (snd (List.nth spans 0)));
  A.check A.int "nothing dropped" 0 dropped

let test_the_budget_cuts_a_subtree_at_a_line_boundary_and_counts_the_rest () =
  let spans, dropped = J.select_paths (rendered ()) "$.items" ~max_chars:60 in
  if spans = [] then A.fail "the head of the subtree is an answer";
  List.iter
    (fun (_, t) -> A.check A.bool "span within budget" true (String.length t <= 60))
    spans;
  A.check A.bool "the rest is counted" true (dropped > 0)

let test_the_budget_stops_at_the_first_span_that_does_not_fit () =
  (* [select_passages] stops rather than letting a smaller span queue-jump;
     both spend one key. *)
  let small = render "{\"items\": [{\"n\": 1}, {\"n\": 2}, {\"n\": 3}]}" in
  let spans, dropped = J.select_paths small "$.items[*].n" ~max_chars:20 in
  A.check (A.list A.string) "stops at the first" [ "$.items[0].n  1" ] (List.map snd spans);
  A.check A.int "the rest counted" 2 dropped

let test_a_value_line_bigger_than_the_budget_is_counted_not_returned () =
  let text = render ("{\"a\": \"" ^ String.make 300 'x' ^ "\"}") in
  let spans, dropped = J.select_paths text "$.a" ~max_chars:100 in
  A.check A.int "no span" 0 (List.length spans);
  A.check A.int "counted" 1 dropped

let test_a_page_that_was_never_rendered_has_no_paths_to_match () =
  (* Raw text reaching the caller is not a document with no match; the engine
     says which. *)
  let spans, dropped = J.select_paths "{\"a\": 1}" "$.a" ~max_chars:600 in
  A.check A.int "no spans" 0 (List.length spans);
  A.check A.int "nothing dropped" 0 dropped

let test_a_document_media_type_is_told_from_a_stream () =
  (* The fetcher cuts a body at [max_download_bytes], and only a cut document
     is unreadable. *)
  A.check A.bool "application/json" true (J.is_json_document_media "application/json");
  A.check A.bool "vnd.api+json" true (J.is_json_document_media "application/vnd.api+json");
  A.check A.bool "x-ndjson is not a document" false
    (J.is_json_document_media "application/x-ndjson");
  A.check A.bool "x-ndjson is json" true (J.is_json_media "application/x-ndjson")

(* [TestShaping] *)
let test_the_shape_round_trips_through_the_grammar () =
  match J.render_schema (rendered ()) with
  | None -> A.fail "schema refused a rendering"
  | Some schema ->
      List.iter
        (fun line ->
          let path =
            match find_sub ~haystack:line ~needle:"  " () with
            | Some i -> String.sub line 0 i
            | None -> line
          in
          J.parse_path path |> ignore)
        (lines schema)

let test_leaves_read_as_types_not_values () =
  let body = render "{\"s\": \"secret\", \"n\": 42, \"b\": true, \"x\": null, \"f\": -1.5}" in
  match J.render_schema body with
  | None -> A.fail "schema refused"
  | Some text ->
      if contains ~haystack:text ~needle:"secret" then A.fail "a leaf value rode through";
      assert_in "$.s  string" (lines text);
      assert_in "$.n  number" (lines text);
      assert_in "$.b  bool" (lines text);
      assert_in "$.x  null" (lines text);
      assert_in "$.f  number" (lines text)

let test_a_value_that_is_its_own_type_word_is_still_withheld () =
  (* A leaf reading [null] prints [null] — the type, the same string the value
     spells. The first-byte rule is what makes that so, and what keeps the
     rule cheap; a value that happens to spell its own type is the one place
     the withholding is not a shortening. *)
  A.check A.string "null leaf"
    "$  object(1)\n$.x  null"
    (match J.render_schema (render "{\"x\": null}") with
     | Some s -> s
     | None -> A.fail "schema refused")

let test_a_uniform_array_collapses_to_one_star_subtree () =
  let body = render "{\"items\": [{\"id\": 1, \"name\": \"a\"}, {\"id\": 2, \"name\": \"b\"}]}" in
  match J.render_schema body with
  | None -> A.fail "schema refused"
  | Some schema ->
      assert_in "$.items  array(2)" (lines schema);
      assert_in "$.items[*].id  number" (lines schema);
      assert_in "$.items[*].name  string" (lines schema);
      (* A uniform array is one subtree, not two members. *)
      if contains ~haystack:schema ~needle:"[0]" then A.fail "collapse did not happen"

let test_heterogeneous_members_print_one_line_each () =
  let body = render "{\"mixed\": [1, \"two\", null]}" in
  match J.render_schema body with
  | None -> A.fail "schema refused"
  | Some schema ->
      assert_in "$.mixed[0]  number" (lines schema);
      assert_in "$.mixed[1]  string" (lines schema);
      assert_in "$.mixed[2]  null" (lines schema)

let test_uniformity_is_checked_recursively () =
  (* Same keys, same types, different values — the record case — collapse. *)
  let body =
    render "{\"rows\": [{\"a\": 1, \"b\": {\"c\": \"x\"}}, {\"a\": 2, \"b\": {\"c\": \"y\"}}]}"
  in
  match J.render_schema body with
  | None -> A.fail "schema refused"
  | Some schema ->
      assert_in "$.rows[*]  object(2)" (lines schema);
      assert_in "$.rows[*].b.c  string" (lines schema);
  (* One of the members evolves a member the other does not have and the
     collapse is refused, because [[*]] would name a member some lack. *)
  let body = render "{\"rows\": [{\"a\": 1}, {\"a\": 2, \"b\": 3}]}" in
  match J.render_schema body with
  | None -> A.fail "schema refused"
  | Some schema ->
      if contains ~haystack:(replace_all ~haystack:schema ~needle:"$  object" ~with_:"") ~needle:"$.rows[*]" then
        A.fail "collapse happened";
      assert_in "$.rows[0].a  number" (lines schema);
      assert_in "$.rows[1].b  number" (lines schema)

let test_sizes_survive_the_collapse_so_a_slice_is_addressable () =
  let body = render (json_dumps_items 200) in
  match J.render_schema body with
  | None -> A.fail "schema refused"
  | Some schema -> assert_in "$.items  array(200)" (lines schema)

let test_empty_containers_report_their_zero () =
  A.check A.string "empty containers"
    "$  object(2)\n$.a  array(0)\n$.b  object(0)"
    (match J.render_schema (render "{\"a\": [], \"b\": {}}") with
     | Some s -> s
     | None -> A.fail "schema refused")

let test_annotations_ride_through_verbatim () =
  let text = rendered () ^ "\n$.items[1]  array(0) not expanded: nested past depth 100" in
  match J.render_schema text with
  | None -> A.fail "schema refused"
  | Some schema ->
      if not (contains ~haystack:schema ~needle:"not expanded: nested past depth 100") then
        A.fail "annotation lost"

let test_not_a_rendering_is_refused_wholesale () =
  A.check (A.option A.string) "plain text" None (J.render_schema "plain text page");
  A.check (A.option A.string) "raw json" None (J.render_schema "{\"a\": 1}");
  A.check (A.option A.string) "trailing prose" None
    (J.render_schema (rendered () ^ "\ntrailing prose"));
  A.check (A.option A.string) "unclassifiable" None (J.render_schema "$  ??\n")

let test_a_member_line_before_the_root_is_refused () =
  (* Spot-checking a rendering's tail is not reading its document. *)
  A.check (A.option A.string) "member first" None (J.render_schema "$.a  number")

let test_the_schema_is_small_where_the_rendering_is_big () =
  (* The case the view exists for: the rendering cut by its own budget. A
     5000-record array renders past its budget, so uniformity would fail on
     the budget-cut annotation at the last described member — the renders' cut
     says nothing about shapes, so it is set aside and the run collapses. *)
  let rendered_text = render (json_dumps_items 5000) in
  match J.render_schema rendered_text with
  | None -> A.fail "schema refused"
  | Some schema ->
      A.check A.bool "schema is small" true (String.length schema < 500);
      if
        not (contains ~haystack:schema ~needle:"not rendered: the document expands past the budget")
      then A.fail "the cut line does not ride";
      let path =
        match find_sub ~haystack:schema ~needle:"  " () with
        | Some i -> String.sub schema 0 i
        | None -> schema
      in
      J.parse_path path |> ignore

let () =
  Alcotest.run "jsondoc"
    [
      ( "recognising",
        [ Alcotest.test_case "the bare types are json" `Quick test_the_bare_types_are_json;
          Alcotest.test_case "the structured syntax suffix is json" `Quick
            test_the_structured_syntax_suffix_is_json_whatever_it_is_about;
          Alcotest.test_case "only a document shape sniffs as json" `Quick
            test_only_a_document_shape_sniffs_as_json ] );
      ( "rendering",
        [ Alcotest.test_case "a container names itself before its members" `Quick
            test_a_container_names_itself_before_its_members;
          Alcotest.test_case "a leaf is compact json at its own path" `Quick
            test_a_leaf_is_compact_json_at_its_own_path;
          Alcotest.test_case "kinds survive the rendering" `Quick
            test_kinds_survive_the_rendering;
          Alcotest.test_case "float and out-of-range integer leaves render" `Quick
            test_float_and_out_of_range_integers_are_leaves_too;
          Alcotest.test_case "no unreachable arm or partial list accessor" `Quick
            test_no_unreachable_arm_or_partial_list_accessor;
          Alcotest.test_case "document order is kept" `Quick test_document_order_is_kept;
          Alcotest.test_case "a duplicate key keeps its first place and its last value" `Quick
            test_a_duplicate_key_keeps_its_first_place_and_its_last_value;
          Alcotest.test_case "a key repeated tens of thousands of times is one pass" `Quick
            test_a_key_repeated_tens_of_thousands_of_times_is_one_pass;
          Alcotest.test_case "an empty container is still a line" `Quick
            test_an_empty_container_is_still_a_line;
          Alcotest.test_case "a key that cannot be written bare is quoted" `Quick
            test_a_key_that_cannot_be_written_bare_is_quoted;
          Alcotest.test_case "text is not ascii escaped" `Quick test_text_is_not_ascii_escaped;
          Alcotest.test_case "a body that is not one document renders as nothing" `Quick
            test_a_body_that_is_not_one_document_renders_as_nothing;
          Alcotest.test_case "deep nesting is cut at the depth cap" `Quick
            test_deep_nesting_is_cut_at_the_depth_cap;
          Alcotest.test_case "a wide document inside the depth cap is cut by size" `Quick
            test_a_wide_document_inside_the_depth_cap_is_cut_by_size;
          Alcotest.test_case "a document people publish is never cut" `Quick
            test_a_document_people_publish_is_never_cut;
          Alcotest.test_case "every rendered path reads back through the grammar" `Quick
            test_every_rendered_path_reads_back_through_the_grammar ] );
      ( "grammar",
        [ Alcotest.test_case "the shapes the grammar reads" `Quick
            test_the_shapes_the_grammar_reads;
          Alcotest.test_case "the root is optional" `Quick test_the_root_is_optional;
          Alcotest.test_case "a bracketed key is read in either quoting" `Quick
            test_a_bracketed_key_is_read_in_either_quoting;
          Alcotest.test_case "a quoted key holding a colon is a name not a slice" `Quick
            test_a_quoted_key_holding_a_colon_is_a_name_not_a_slice;
          Alcotest.test_case "a blank path is refused" `Quick
            test_a_blank_path_is_refused_rather_than_read_as_the_root;
          Alcotest.test_case "a path refusal keeps non-ascii readable" `Quick
            test_a_path_refusal_keeps_printable_non_ascii_readable;
          Alcotest.test_case "a sloppy dot before a bracket is tolerated" `Quick
            test_a_sloppy_dot_before_a_bracket_is_tolerated;
          Alcotest.test_case "a path this grammar cannot honour is refused by name" `Quick
            test_a_path_this_grammar_cannot_honour_is_refused_by_name;
          Alcotest.test_case "a filter says so rather than matching nothing" `Quick
            test_a_filter_says_so_rather_than_matching_nothing;
          Alcotest.test_case "negative indices are refused with the alternative" `Quick
            test_negative_indices_are_refused_with_the_alternative ] );
      ( "selecting",
        [ Alcotest.test_case "a leaf is one span" `Quick test_a_leaf_is_one_span;
          Alcotest.test_case "a container is its whole subtree" `Quick
            test_a_container_is_its_whole_subtree;
          Alcotest.test_case "a wildcard selects one line per element" `Quick
            test_a_wildcard_selects_one_line_per_element;
          Alcotest.test_case "a slice selects a range of an array" `Quick
            test_a_slice_selects_a_range_of_an_array;
          Alcotest.test_case "an index segment is a step not a character prefix" `Quick
            test_an_index_segment_is_a_step_not_a_character_prefix;
          Alcotest.test_case "offsets index the full rendering" `Quick
            test_offsets_index_the_full_rendering;
          Alcotest.test_case "a path that matches nothing reports nothing" `Quick
            test_a_path_that_matches_nothing_reports_nothing;
          Alcotest.test_case "the whole document is the root" `Quick
            test_the_whole_document_is_the_root;
          Alcotest.test_case "the budget cuts a subtree at a line boundary" `Quick
            test_the_budget_cuts_a_subtree_at_a_line_boundary_and_counts_the_rest;
          Alcotest.test_case "the budget stops at the first span that does not fit" `Quick
            test_the_budget_stops_at_the_first_span_that_does_not_fit;
          Alcotest.test_case "a value line bigger than the budget is counted not returned" `Quick
            test_a_value_line_bigger_than_the_budget_is_counted_not_returned;
          Alcotest.test_case "a page that was never rendered has no paths to match" `Quick
            test_a_page_that_was_never_rendered_has_no_paths_to_match;
          Alcotest.test_case "a document media type is told from a stream" `Quick
            test_a_document_media_type_is_told_from_a_stream ] );
      ( "shaping",
        [ Alcotest.test_case "the shape round trips through the grammar" `Quick
            test_the_shape_round_trips_through_the_grammar;
          Alcotest.test_case "leaves read as types not values" `Quick
            test_leaves_read_as_types_not_values;
          Alcotest.test_case "a value that is its own type word is still withheld" `Quick
            test_a_value_that_is_its_own_type_word_is_still_withheld;
          Alcotest.test_case "a uniform array collapses to one star subtree" `Quick
            test_a_uniform_array_collapses_to_one_star_subtree;
          Alcotest.test_case "heterogeneous members print one line each" `Quick
            test_heterogeneous_members_print_one_line_each;
          Alcotest.test_case "uniformity is checked recursively" `Quick
            test_uniformity_is_checked_recursively;
          Alcotest.test_case "sizes survive the collapse so a slice is addressable" `Quick
            test_sizes_survive_the_collapse_so_a_slice_is_addressable;
          Alcotest.test_case "empty containers report their zero" `Quick
            test_empty_containers_report_their_zero;
          Alcotest.test_case "annotations ride through verbatim" `Quick
            test_annotations_ride_through_verbatim;
          Alcotest.test_case "not a rendering is refused wholesale" `Quick
            test_not_a_rendering_is_refused_wholesale;
          Alcotest.test_case "a member line before the root is refused" `Quick
            test_a_member_line_before_the_root_is_refused;
          Alcotest.test_case "the schema is small where the rendering is big" `Quick
            test_the_schema_is_small_where_the_rendering_is_big ] );
    ]
