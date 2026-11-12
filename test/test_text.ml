(* The one codepoint walk and the one [repr] pass, pinned directly.

   Style review H1 and H2: the port had six copies of the walk in three
   spellings, and they disagreed on two things that show up only on hostile
   input — what a bad lead byte costs, and what a truncated trailing sequence
   does to a slice. H1's payload is the one that actually raised: a log-field
   builder on a refusal path called [take] with three bytes of a four-byte
   sequence, and [String.sub] answered [Invalid_argument] out of a module whose
   failures are values.

   The cases here are the walk's own contract, so the pin survives whoever calls
   it: [test_engine.ml] and [test_sanitize.ml] pin the call sites, this suite
   pins the walk. *)

module U = Seekwright_text.Utf8
module R = Seekwright_text.Repr
module A = Alcotest

(* {2 The step} *)

let test_a_truncated_trailing_sequence_is_cut_not_raised () =
  (* The H1 repro: a two-byte prefix of a three-byte sequence, asked for more
     codepoints than it holds. Before the fix this raised [Invalid_argument]. *)
  A.(check string) "the whole payload comes back" "a\xe2\x80" (U.take 2 "a\xe2\x80");
  A.(check int) "two codepoints" 2 (U.count "a\xe2\x80");
  A.(check string) "a wider ask is the same cut" "a\xe2\x80" (U.take 9 "a\xe2\x80");
  (* And the boundary that sits exactly on the truncated sequence. *)
  A.(check string) "one codepoint" "a" (U.take 1 "a\xe2\x80")

let test_the_step_returns_an_index () =
  (* [next_index] is what a scan advances by. A copy that returns a {b width}
     here pins its own loop: [i] stops moving, [count] never terminates, and no
     test that only checks a length can see it. *)
  A.(check int) "ascii" 1 (U.next_index "ab" 0);
  A.(check int) "into a three-byte sequence" 4 (U.next_index "a\xe2\x82\xac" 1);
  A.(check int) "a truncated sequence stops at the end" 3 (U.next_index "a\xe2\x80" 1);
  A.(check int) "the last ascii byte stops at the end" 2 (U.next_index "ab" 1)

let test_a_bad_lead_byte_advances_one () =
  (* The H2 disagreement: a five-byte lead is not UTF-8, and the range form said
     four while the mask form said one. One is the answer the sanitize pass
     needs — it walks a [<|…|>] literal a codepoint at a time looking for the
     closing bar, and a step of four jumps the bar. *)
  List.iter
    (fun byte ->
      let s = Bytes.make 1 (Char.chr byte) |> Bytes.to_string in
      A.(check int) (Printf.sprintf "lead 0x%02x costs one" byte) 1 (U.lead_width s 0);
      A.(check int) (Printf.sprintf "and steps one at 0x%02x" byte) 1 (U.next_index s 0))
    [ 0xf8; 0xfe; 0xff ];
  (* A continuation byte on its own is a character too, never a skip. *)
  A.(check int) "a continuation byte" 1 (U.lead_width "\x80x" 0);
  (* The constraint the sanitizer carries, stated where the walk lives: a scan
     starting at a five-byte lead reaches the bar, and the token gets escaped. *)
  A.(check int) "the scan stops on the bar" 1 (U.next_index "\xf8|>" 0);
  A.(check int) "so a bad lead is still counted" 3 (U.count "\xf8|>")

let test_counting_is_codepoints_not_bytes () =
  A.(check int) "empty" 0 (U.count "");
  A.(check int) "ascii" 4 (U.count "abcd");
  A.(check int) "two-byte" 1 (U.count "\xc3\xa9");
  A.(check int) "three-byte" 1 (U.count "\xe2\x82\xac");
  A.(check int) "four-byte" 1 (U.count "\xf0\x9f\x98\x80");
  let mixed = "caf\xc3\xa9 \xe2\x82\xac \xf0\x9f\x98\x80" in
  A.(check int) "mixed" 8 (U.count mixed);
  A.(check bool) "which is not the byte count" true (U.count mixed <> String.length mixed);
  (* A cut never lands mid-sequence, which is the whole point of counting first:
     five codepoints of this string is [café] and the blank after it. *)
  A.(check string) "take 5" "caf\xc3\xa9 " (U.take 5 mixed)

let test_slices_and_codepoints_agree_with_the_walk () =
  let s = "a\xe2\x82\xac\xf0\x9f\x98\x80" in
  let cps = U.codepoints s in
  A.(check int) "three codepoints" 3 (List.length cps);
  A.(check (list int)) "indexes" [ 0; 1; 4 ] (List.map (fun cp -> cp.U.idx) cps);
  A.(check (list int)) "widths" [ 1; 3; 4 ] (List.map (fun cp -> cp.U.width) cps);
  let slices = U.slices s in
  A.(check int) "one entry per codepoint" 3 (Array.length slices);
  A.(check string) "and they re-join" s (String.concat "" (Array.to_list slices));
  (* The truncated case again: the last width is the bytes present, not the
     sequence's nominal width. *)
  A.(check (list int)) "a truncated last width is clamped" [ 1; 2 ]
    (List.map (fun cp -> cp.U.width) (U.codepoints "a\xe2\x80"))

(* {2 Codepoint arrays} *)

let test_the_array_round_trips () =
  List.iter
    (fun s ->
      A.(check string) ("round trip " ^ String.escaped s) s (U.to_string (U.of_string s)))
    [ ""; "plain"; "caf\xc3\xa9"; "\xe2\x82\xac euro"; "\xf0\x9f\x98\x80 emoji" ];
  (* The lenient half of the contract: a byte sequence the encoder would not
     emit is still {i one} entry, and re-encoding writes the well-formed
     sequence for whatever value the decode landed on — byte identity across a
     malformed input is not the promise, {i never raising} and {i one entry per
     bad lead} are. *)
  A.(check int) "a truncated sequence is still one entry" 2
    (Array.length (U.of_string "a\xe2\x80"));
  A.(check int) "the truncated entry holds the bytes present" 1
    (List.length (List.filter (fun cp -> cp.U.width = 2) (U.codepoints "a\xe2\x80")));
  A.(check bool) "and the walk stops at the end without raising" true
    (U.next_index "a\xe2\x80" 1 = 3)

let test_encode_writes_the_sequence () =
  A.(check string) "ascii" "a" (U.encode 0x61);
  A.(check string) "two bytes" "\xc3\xa9" (U.encode 0xe9);
  A.(check string) "three bytes" "\xe2\x82\xac" (U.encode 0x20ac);
  A.(check string) "four bytes" "\xf0\x9f\x98\x80" (U.encode 0x1f600);
  A.(check bool) "and decodes back" true
    (List.for_all
       (fun cp -> U.of_string (U.encode cp) = [| cp |])
       [ 0x41; 0xa0; 0x2028; 0x1f600 ])

(* {2 Whitespace — two sets, one module} *)

let test_the_two_whitespace_sets_are_two_decisions () =
  (* [is_python_space] is [str.isspace()], which is what [splitlines] breaks on
     and what the fetch path strips and runs on. *)
  List.iter
    (fun cp ->
      A.(check bool) (Printf.sprintf "python space U+%04X" cp) true (U.is_python_space cp))
    [ 0x09; 0x0a; 0x0b; 0x0c; 0x0d; 0x20; 0x1c; 0x1d; 0x1e; 0x1f; 0x85; 0xa0; 0x1680; 0x2000; 0x2028; 0x2029; 0x202f; 0x205f; 0x3000 ];
  A.(check bool) "a letter is not" false (U.is_python_space (Char.code 'a'));
  A.(check bool) "and NUL is not" false (U.is_python_space 0x00);
  (* [is_ascii_space] is the search path's narrower set, deliberately: Python's
     [split] also splits on the Unicode spaces, and this does not. Both live here
     so the next reader sees two decisions rather than one rule typed twice. *)
  List.iter
    (fun ch -> A.(check bool) "ascii space" true (U.is_ascii_space ch))
    [ ' '; '\t'; '\n'; '\r'; '\011'; '\012' ];
  List.iter
    (fun ch -> A.(check bool) "not an ascii space" false (U.is_ascii_space ch))
    [ Char.unsafe_chr 0x1c; Char.unsafe_chr 0x85; Char.unsafe_chr 0xa0 ]

let test_splitlines_breaks_where_python_does () =
  let lines s = List.map U.to_string (U.splitlines (U.of_string s)) in
  A.(check (list string)) "one line" [ "a b" ] (lines "a b");
  A.(check (list string)) "two lines" [ "a"; "b" ] (lines "a\nb");
  A.(check (list string)) "a trailing break ends an empty last line"
    [ "a"; "" ] (lines "a\n");
  A.(check (list string)) "the separators break" [ "a"; "b"; "c" ] (lines "a\x1cb\x1ec");
  A.(check (list string)) "NEL breaks" [ "a"; "b" ] (lines "a\x85b");
  A.(check (list string)) "the Unicode line and paragraph separators break"
    [ "a"; "b"; "c" ] (lines ("a\xe2\x80\xa8b\xe2\x80\xa9c"));
  (* The one place this walk is {i not} Python's, pinned so the difference is a
     recorded fact rather than a surprise: [CR] is not in the port's boundary set,
     so a [CRLF] breaks at the [LF] and carries the [CR] into the line before it.
     Python's {e splitlines} breaks on the [CR] itself. The fetch path's CSV
     reader depends on the carriage return surviving the split — it refuses a bare
     one with [csv]'s own wording, which it could not see otherwise — so the
     difference is the walk's open question, not something to change under it. *)
  A.(check (list string)) "CRLF carries the CR" [ "a\r"; "b" ] (lines "a\r\nb");
  A.(check bool) "CR is not a boundary here" false (U.is_line_boundary 0x0d);
  A.(check bool) "a tab is not either" false (U.is_line_boundary (Char.code '\t'))

let test_ascii_lower_folds_only_ascii () =
  let cps = U.ascii_lower (U.of_string "AbZ9 \xc3\x89") in
  A.(check string) "ascii folds" "abz9 \xc3\x89" (U.to_string cps)

(* {2 The two [repr]s} *)

let test_the_log_repr_quotes_the_way_python_does () =
  A.(check string) "plain" "'plain'" (R.py_repr "plain");
  A.(check string) "empty" "''" (R.py_repr "");
  (* The rule that makes a log line safe: a newline in a scraped title is
     named, so it cannot close one record and open a fabricated one. *)
  A.(check string) "newline, tab, carriage return" "'a\\nb\\tc\\rd'"
    (R.py_repr "a\nb\tc\rd");
  A.(check string) "backslash" "'a\\\\b'" (R.py_repr "a\\b");
  (* Single quotes unless the text holds one and no double quote. *)
  A.(check string) "an apostrophe picks double quotes" "\"it's\"" (R.py_repr "it's");
  A.(check string) "a double quote stays inside single quotes" "'say \"hi\"'"
    (R.py_repr "say \"hi\"");
  A.(check string) "both quotes keeps singles and escapes the apostrophe"
    "'it\\'s \"ok\"'" (R.py_repr "it's \"ok\"");
  (* Control bytes and DEL are [\\xNN]; a non-ASCII printable is left alone,
     because a log reader keeps UTF-8 and rewriting it would hide the page. *)
  A.(check string) "control bytes" "'\\x01\\x7f'" (R.py_repr "\x01\x7f");
  A.(check string) "non-ascii passes through" "'caf\xc3\xa9'" (R.py_repr "caf\xc3\xa9");
  (* Idempotence is not the contract, but re-escaping a repr must not lose the
     text's own quoting — and a repr never contains a raw newline. *)
  let once = R.py_repr "a\nb" in
  A.(check bool) "no raw newline survives" true (not (String.contains once '\n'))

let test_the_ascii_repr_is_the_one_a_refusal_quotes_with () =
  (* The quote is fixed, so a token that holds one comes back escaped rather than
     re-quoted, and every byte above ASCII is written out. *)
  A.(check string) "the quote stays single" "'it\\'s'" (R.py_repr_ascii "it's");
  A.(check string) "non-ascii arrives as its bytes" "'caf\\xc3\\xa9'"
    (R.py_repr_ascii "caf\xc3\xa9");
  A.(check string) "the same escapes as the log pass" "'a\\nb'" (R.py_repr_ascii "a\nb");
  A.(check string) "del escapes" "'\\x7f'" (R.py_repr_ascii "\x7f")

(* {2 The library boundary} *)

let test_the_fetch_path_walk_is_this_walk () =
  (* [lib/fetch/utf8.ml] is a re-export, so a fetch-path call site and an engine
     call site cannot drift into two walks again. This is a compile-time fact:
     the two [t]s are one type, and it fails the build if the re-export is
     dropped. *)
  let pin : Seekwright_fetch.Utf8.t -> Seekwright_text.Utf8.t = Fun.id in
  let page = "caf\xc3\xa9 \xe2\x82\xac" in
  A.(check int) "and it counts the same" (Seekwright_fetch.Utf8.count page)
    (U.count page);
  ignore pin

let () =
  A.run "text"
    [
      ( "the step",
          [
            A.test_case "a truncated trailing sequence is cut, not raised" `Quick
              test_a_truncated_trailing_sequence_is_cut_not_raised;
            A.test_case "the step returns an index" `Quick test_the_step_returns_an_index;
            A.test_case "a bad lead byte advances one" `Quick test_a_bad_lead_byte_advances_one;
            A.test_case "counting is codepoints, not bytes" `Quick
              test_counting_is_codepoints_not_bytes;
            A.test_case "slices and codepoints agree with the walk" `Quick
              test_slices_and_codepoints_agree_with_the_walk;
          ] );
      ( "codepoint arrays",
          [
            A.test_case "the array round trips" `Quick test_the_array_round_trips;
            A.test_case "encode writes the sequence" `Quick test_encode_writes_the_sequence;
          ] );
      ( "blanks and lines",
          [
            A.test_case "the two whitespace sets are two decisions" `Quick
              test_the_two_whitespace_sets_are_two_decisions;
            A.test_case "splitlines breaks where python does" `Quick
              test_splitlines_breaks_where_python_does;
            A.test_case "ascii lower folds only ascii" `Quick test_ascii_lower_folds_only_ascii;
          ] );
      ( "repr",
          [
            A.test_case "the log repr quotes the way python does" `Quick
              test_the_log_repr_quotes_the_way_python_does;
            A.test_case "the ascii repr is the one a refusal quotes with" `Quick
              test_the_ascii_repr_is_the_one_a_refusal_quotes_with;
          ] );
      ( "one owner",
          [ A.test_case "the fetch path walks this walk" `Quick test_the_fetch_path_walk_is_this_walk ];
      );
    ]
