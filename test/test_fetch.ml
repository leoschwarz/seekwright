(* The fetch stack's pure half: URL validation, the response window, image
   sniffing, the extractor plumbing, passage selection, and the stdlib backend.

   Port of tests/fetch/test_fetcher.py (TestWindowText), test_fetch_guardrails.py
   (TestSchemeAndShape, TestImages' signature table) and test_extractors.py (the
   stdlib-backend and shared-plumbing classes). The networked half of the
   fetcher — redirects, the cap, the type gate over a real grant — lives in
   test_fetch_http.ml. *)

module F = Seekwright_fetch.Fetcher
module E = Seekwright_fetch.Extractor
module J = Seekwright_fetch.Jsondoc
module T = Seekwright_fetch.Tabledoc
module S = Seekwright_fetch_stdlib.Stdlib
module A = Alcotest

let contains_substring hay needle =
  let n = String.length hay and m = String.length needle in
  let rec go i =
    if i + m > n then false
    else String.sub hay i m = needle || go (i + 1)
  in
  m = 0 || go 0

let paged ?(paragraph = "paragraph of body text") count =
  String.concat "\n\n" (List.init count (fun i -> Printf.sprintf "%s %d" paragraph i))

(* {1 Windowing — TestWindowText} *)

let test_a_short_text_is_returned_whole () =
  let text = paged 3 in
  A.check (A.pair A.string A.bool) "whole" (text, false)
    (F.window_text text ~offset:0 ~max_chars:40_000)

let test_a_long_text_is_cut_at_a_paragraph_break () =
  let text = paged 40 in
  let window, more = F.window_text text ~offset:0 ~max_chars:200 in
  A.check A.bool "more remains" true more;
  A.check A.bool "marker appended" true (String.ends_with ~suffix:"\n\n[...]" window);
  let core = String.sub window 0 (String.length window - String.length "\n\n[...]") in
  A.check A.bool "prefix of the text" true (String.starts_with ~prefix:core text);
  A.check A.bool "cut landed on a paragraph boundary" true
    (match core with "" -> false | c -> c.[String.length c - 1] >= '0' && c.[String.length c - 1] <= '9')

let test_the_marker_is_not_counted_in_the_offsets () =
  let text = paged 40 in
  let window, _ = F.window_text text ~offset:0 ~max_chars:200 in
  let core = String.sub window 0 (String.length window - String.length "\n\n[...]") in
  let rest = String.sub text (String.length core) (String.length text - String.length core) in
  A.check A.string "the cut is the paragraph break it found" ("\n\n" ^ String.sub rest 2 (String.length rest - 2)) rest

let test_an_offset_slices_mid_document () =
  let text = paged 40 in
  let window, more = F.window_text text ~offset:500 ~max_chars:100 in
  let core = String.sub window 0 (String.length window - String.length "\n\n[...]") in
  A.check A.bool "not empty" true (core <> "");
  A.check A.bool "starts at the offset" true
    (String.starts_with ~prefix:core (String.sub text 500 (String.length text - 500)));
  A.check A.bool "more remains" true more

let test_a_window_that_reaches_the_end_is_not_flagged () =
  let text = paged 40 in
  let tail, more = F.window_text text ~offset:(String.length text - 50) ~max_chars:100 in
  (* The fixtures are ASCII, so byte length is the codepoint length. *)
  A.check A.string "the tail" (String.sub text (String.length text - 50) 50) tail;
  A.check A.bool "not flagged" false more

let test_an_offset_past_the_end_returns_empty_but_still_flags () =
  let text = paged 40 in
  A.check (A.pair A.string A.bool) "empty but flagged" ("", true)
    (F.window_text text ~offset:(String.length text + 10) ~max_chars:100)

let test_an_uncapped_window_is_the_whole_text () =
  let text = paged 40 in
  A.check (A.pair A.string A.bool) "whole" (text, false)
    (F.window_text text ~offset:0 ~max_chars:F.uncapped)

(* {1 URL validation — TestSchemeAndShape} *)

let blocked_schemes =
  [
    "file:///etc/passwd";
    "data:text/html,<b>hi";
    "javascript:alert(1)";
    "ftp://example.com/x";
    "gopher://example.com/";
  ]

let assert_url_blocked ?needle f =
  match f () with
  | exception F.Url_blocked msg -> (
      match needle with
      | Some needle when not (contains_substring msg needle) ->
          A.failf "message %S lacks %S" msg needle ()
      | _ -> ())
  | _ -> A.fail "expected Url_blocked"

let test_non_http_schemes_are_refused () =
  List.iter
    (fun url -> assert_url_blocked ~needle:"not fetchable" (fun () -> F.validate_url url))
    blocked_schemes

let test_credentials_are_refused_not_stripped () =
  assert_url_blocked ~needle:"credentials" (fun () ->
    F.validate_url "http://user:secret@example.com/")

let test_missing_host_is_refused () =
  assert_url_blocked ~needle:"no host" (fun () -> F.validate_url "http:///path-only")

let test_ordinary_url_passes_and_keeps_its_query () =
  A.check A.string "unchanged" "https://e.com/a?b=1" (F.validate_url "https://e.com/a?b=1")

let test_fragment_is_dropped () =
  A.check A.string "fragment gone" "https://e.com/a" (F.validate_url "https://e.com/a#frag")

let test_an_unsendable_port_is_refused () =
  List.iter
    (fun url -> assert_url_blocked ~needle:"port" (fun () -> F.validate_url url))
    [
      "https://example.com:99999/";
      "https://example.com:70000/";
      "https://example.com:notaport/";
      "https://example.com:0/";
    ]

let test_an_ordinary_port_passes () =
  A.check A.string "port kept" "https://e.com:8443/a" (F.validate_url "https://e.com:8443/a")

let test_the_scheme_is_lowercased_and_an_empty_path_becomes_root () =
  A.check A.string "normalised" "https://e.com/" (F.validate_url "HTTPS://e.com")

(* {1 Image sniffing} *)

let test_the_signature_table_names_exactly_the_admitted_types () =
  A.check (A.list A.string) "the four admitted types" F.image_types
    [ "image/png"; "image/jpeg"; "image/gif"; "image/webp" ]

let test_each_signature_sniffs_as_its_type () =
  A.check (A.option A.string) "png" (Some "image/png")
    (F.sniff_image_type "\x89PNG\r\n\x1a\nrest");
  A.check (A.option A.string) "jpeg" (Some "image/jpeg") (F.sniff_image_type "\xff\xd8\xff\xe0");
  A.check (A.option A.string) "gif87a" (Some "image/gif") (F.sniff_image_type "GIF87a......");
  A.check (A.option A.string) "gif89a" (Some "image/gif") (F.sniff_image_type "GIF89a......");
  A.check (A.option A.string) "webp" (Some "image/webp")
    (F.sniff_image_type "RIFF\x00\x00\x00\x00WEBPVP8 ");
  A.check (A.option A.string) "not an image" None (F.sniff_image_type "<html>nope")

let test_resolved_cap () =
  A.check A.int "default" 40 (F.resolved_cap 40 None);
  A.check A.int "override" 7 (F.resolved_cap 40 (Some 7))

(* {1 Media-type plumbing} *)

let test_media_type_strips_parameters () =
  A.check A.string "params stripped" "text/html" (E.media_type (Some "TEXT/HTML; charset=utf-8"));
  A.check A.string "none" "" (E.media_type None)

let test_charset_is_parsed () =
  A.check (A.option A.string) "quoted" (Some "utf-8")
    (E.charset_of (Some "text/html; charset=\"utf-8\""));
  A.check (A.option A.string) "absent" None (E.charset_of (Some "text/html"))

let test_is_supported_reads_the_json_suffix () =
  A.check A.bool "geo+json" true
    (E.is_supported [ "application/json" ] "application/geo+json");
  A.check A.bool "xml suffix is not json" false
    (E.is_supported [ "application/json" ] "application/atom+xml")

let test_describe_types_renders_the_families_in_order () =
  A.check A.string "full set" "HTML, plain text, JSON, CSV and PDF"
    (E.describe_types E.supported_types);
  A.check A.string "stdlib set" "HTML, plain text, JSON and CSV"
    (E.describe_types S.supported_types);
  A.check A.string "single family" "HTML" (E.describe_types [ "text/html" ]);
  A.check A.string "unknown type appended" "HTML and application/x-thing"
    (E.describe_types [ "application/x-thing"; "text/html" ]);
  A.check A.string "empty" "nothing" (E.describe_types [])

let test_sniffs_html () =
  A.check A.bool "doctype" true (E.sniffs_html "  <!DOCTYPE html><html>");
  A.check A.bool "html tag" true (E.sniffs_html "<html><body>");
  A.check A.bool "not html" false (E.sniffs_html "just text")

(* {1 Decoding} *)

let test_declared_charset_is_preferred () =
  let body = "caf\xe9" (* latin-1 *) in
  A.check A.string "latin-1 decoded" "café" (E.decode body (Some "text/html; charset=iso-8859-1"))

let test_undecodable_bytes_do_not_raise () =
  let body = "ok \xff\xfe bad" in
  let decoded = E.decode body (Some "text/plain") in
  A.check A.bool "survives" true (String.starts_with ~prefix:"ok " decoded)

let test_a_declared_charset_no_codec_names_falls_back () =
  A.check A.string "utf-8 fallback" "café"
    (E.decode "caf\xc3\xa9" (Some "text/html; charset=not-a-codec"))

let test_windows_1252_specials_decode () =
  A.check A.string "euro" "€" (E.decode "\x80" (Some "text/plain; charset=windows-1252"))

(* {1 Normalise} *)

let test_normalise_collapses_and_measures_in_codepoints () =
  let r = E.normalise "  a \t b\n\n\n\nc  " (Some "") in
  A.check A.string "collapsed" "a b\n\nc" r.E.text;
  A.check (A.option A.string) "empty title is None" None r.E.title;
  A.check A.int "codepoints" 6 r.E.total_chars

(* {1 Passage selection — TestSelectPassages} *)

let chunked_para head = head ^ " " ^ String.concat "" (List.init 200 (fun _ -> "filler "))

let test_prefers_chunks_hitting_more_terms () =
  let no_term = chunked_para "Sourdough starters need flour and water." in
  let one_term = chunked_para "Volatility spiked after the announcement." in
  let two_terms = chunked_para "Bitcoin volatility spiked after the announcement." in
  let text = no_term ^ "\n\n" ^ one_term ^ "\n\n" ^ two_terms in
  let spans, dropped = E.select_passages text "bitcoin volatility" ~max_chars:6000 in
  A.check A.int "dropped" 0 dropped;
  A.check A.int "one span" 1 (List.length spans);
  let offset, body = List.hd spans in
  A.check A.int "offset" (String.length no_term + 2) offset;
  A.check A.string "the span is the text at its offset"
    (String.sub text offset (String.length text - offset)) body

let test_budget_stops_selection_and_counts_dropped () =
  let a = chunked_para "Bitcoin volatility spiked after the announcement." in
  let gap = chunked_para "Sourdough starters need flour and patience." in
  let b = chunked_para "Bitcoin miners resumed operations." in
  let c = chunked_para "Bitcoin exchanges raised their fees." in
  let text = String.concat "\n\n" [ a; gap; b; c ] in
  let spans, dropped = E.select_passages text "bitcoin" ~max_chars:3000 in
  A.check A.int "dropped" 1 dropped;
  A.check A.int "two spans" 2 (List.length spans);
  A.check A.bool "within budget" true
    (List.fold_left (fun acc (_, body) -> acc + String.length body) 0 spans <= 3000)

let test_adjacent_selected_chunks_merge_into_one_span () =
  let a = chunked_para "Bitcoin volatility spiked." in
  let b = chunked_para "Volatility spread to the altcoins." in
  let text = a ^ "\n\n" ^ b in
  let spans, dropped = E.select_passages text "volatility" ~max_chars:6000 in
  A.check A.int "dropped" 0 dropped;
  A.check (A.list (A.pair A.int A.string)) "one span" [ (0, text) ] spans

let test_no_match_returns_nothing_and_no_drops () =
  let text = chunked_para "Sourdough starters need flour and patience." in
  A.check A.int "no spans" 0 (List.length (fst (E.select_passages text "bitcoin mining rig" ~max_chars:6000)));
  A.check A.int "no drops" 0 (snd (E.select_passages text "bitcoin mining rig" ~max_chars:6000))

let test_short_query_tokens_are_ignored () =
  let text = chunked_para "Sourdough starters need flour and patience." in
  let spans, dropped = E.select_passages text "a of" ~max_chars:6000 in
  A.check A.int "no spans" 0 (List.length spans);
  A.check A.int "no drops" 0 dropped

(* {1 The stdlib backend} *)

let article ?(body = String.concat "" (List.init 10 (fun _ -> "This is the real content of the page. "))) () =
  "<!DOCTYPE html>\n<html><head><title>The Title</title></head>\n<body>\n  <nav>Home About Contact Login</nav>\n  <script>var tracking = 1;</script>\n  <style>body { color: red }</style>\n  <article>\n    <h1>A Heading</h1>\n    <p>"
  ^ body
  ^ "</p>\n    <p>A second paragraph with an &amp; entity in it.</p>\n  </article>\n  <footer>Copyright 2026 Some Company</footer>\n</body></html>"

let test_it_names_itself_and_claims_no_pdf () =
  A.check A.string "name" "stdlib" S.name;
  A.check A.bool "no pdf" false
    (E.is_supported S.supported_types "application/pdf");
  A.check A.string "phrase" "HTML, plain text, JSON and CSV"
    (E.describe_types S.supported_types)

let test_the_article_survives_and_its_chrome_does_not () =
  let r = S.extract (article ()) (Some "text/html") in
  A.check A.bool "content kept" true (contains_substring r.E.text "real content of the page");
  A.check A.bool "nav dropped" false (contains_substring r.E.text "Home About Contact");
  A.check A.bool "footer dropped" false (contains_substring r.E.text "Copyright 2026");
  A.check A.bool "script dropped" false (contains_substring r.E.text "var tracking");
  A.check A.bool "style dropped" false (contains_substring r.E.text "color: red");
  A.check A.bool "entity unescaped" false (contains_substring r.E.text "&amp;");
  A.check A.bool "ampersand present" true (contains_substring r.E.text "&");
  A.check (A.option A.string) "title" (Some "The Title") r.E.title

let test_a_list_reads_as_items () =
  let body = "<html><body><ul><li>One</li><li>Two</li></ul></body></html>" in
  A.check A.string "items" "- One\n- Two" (S.extract body (Some "text/html")).E.text

let test_an_empty_list_item_earns_no_bullet () =
  let body = "<html><body><ul><li><span></span></li><li>Real item</li></ul></body></html>" in
  A.check A.string "no bullet" "- Real item" (S.extract body (Some "text/html")).E.text

let test_a_table_keeps_its_cells_apart () =
  let body = "<html><body><table><tr><td>one</td><td>two</td></tr></table></body></html>" in
  A.check A.string "cells apart" "one two" (S.extract body (Some "text/html")).E.text

let test_a_row_begins_at_its_first_cell () =
  let body =
    "<html><body><table><tr><th>H1</th><th>H2</th></tr><tr><td>a</td><td>b</td></tr></table></body></html>"
  in
  A.check A.string "row break" "H1 H2\n\na b" (S.extract body (Some "text/html")).E.text

let test_an_icon_sprite_does_not_rename_the_page () =
  let body =
    "<html><head><title>Real Page Title</title></head><body>"
    ^ "<svg><symbol id='a'><title>Icon A</title><svg><path/></svg></symbol>"
    ^ "<symbol id='b'><title>Icon B</title></svg><p>body text</p></body></html>"
  in
  let r = S.extract body (Some "text/html") in
  A.check (A.option A.string) "title" (Some "Real Page Title") r.E.title;
  A.check A.bool "icon A dropped" false (contains_substring r.E.text "Icon A");
  A.check A.bool "icon B dropped" false (contains_substring r.E.text "Icon B")

let test_a_title_inside_a_graphic_is_never_the_page_name () =
  let body =
    "<html><body><svg><g><svg><title>Icon A</title></svg><title>Icon B</title></svg><p>body</p></body></html>"
  in
  A.check (A.option A.string) "no title" None (S.extract body (Some "text/html")).E.title

let test_both_ways_of_writing_a_break_mean_one_line () =
  let body = "<html><body><p>one<br/>two<br>three</p></body></html>" in
  A.check A.string "one line each" "one\ntwo\nthree" (S.extract body (Some "text/html")).E.text

let test_the_text_inside_a_form_goes_with_the_form () =
  let body = "<html><body><form><p>inside form text</p></form><p>outside</p></body></html>" in
  A.check A.string "outside only" "outside" (S.extract body (Some "text/html")).E.text

let test_a_block_left_open_does_not_swallow_the_rest_of_the_page () =
  let body = "<html><body><nav><div>Menu</nav><p>The article body.</p></body></html>" in
  let r = S.extract body (Some "text/html") in
  A.check A.bool "article kept" true (contains_substring r.E.text "The article body.");
  A.check A.bool "menu dropped" false (contains_substring r.E.text "Menu")

let test_missing_content_type_is_sniffed () =
  let r = S.extract (article ()) None in
  A.check A.bool "sniffed as html" true (contains_substring r.E.text "real content")

let test_javascript_shell_yields_empty_text_not_an_error () =
  let shell = "<!DOCTYPE html><html><body><div id='root'></div></body></html>" in
  A.check A.string "empty" "" (S.extract shell (Some "text/html")).E.text

let test_a_pdf_is_a_refusal_naming_the_type () =
  match S.extract "%PDF-1.4\n" (Some "application/pdf") with
  | exception E.Extraction_failed msg ->
      A.check A.bool "names the type" true (contains_substring msg "application/pdf")
  | _ -> A.fail "expected Extraction_failed"

let test_untagged_markup_is_read_as_text_not_as_a_failure () =
  let body = "<html><body><p>An unclosed paragraph<p>And another" in
  let r = S.extract body (Some "text/html") in
  A.check A.bool "first" true (contains_substring r.E.text "An unclosed paragraph");
  A.check A.bool "second" true (contains_substring r.E.text "And another")

let test_plain_text_passes_through () =
  A.check A.string "plain" "hello world" (S.extract "hello world" (Some "text/plain")).E.text

let test_plain_text_whitespace_runs_are_collapsed () =
  A.check A.string "collapsed" "a b c" (S.extract "a   b\t\tc" (Some "text/plain")).E.text

let test_unextractable_types_raise () =
  List.iter
    (fun ctype ->
      match S.extract "body" (Some ctype) with
      | exception E.Extraction_failed _ -> ()
      | _ -> A.failf "expected Extraction_failed for %s" ctype)
    [ "application/pdf"; "image/png"; "application/octet-stream" ]

let test_a_json_body_becomes_structure_a_path_can_address () =
  let r = S.extract "{\"title\": \"A page\", \"lines\": [\"one\", \"two\"]}" (Some "application/json") in
  A.check A.bool "addressable" true r.E.path_addressable;
  A.check A.bool "path printed" true (contains_substring r.E.text "$.lines[0]")

let test_a_body_that_is_not_one_json_document_comes_back_as_its_text () =
  let body = "{\"a\": 1}\n{\"a\": 2}\n" in
  let r = S.extract body (Some "application/jsonl") in
  A.check A.bool "not addressable" false r.E.path_addressable;
  A.check A.string "the bytes are the answer" body r.E.text

let test_a_csv_document_arrives_as_row_paths () =
  let r = S.extract "id,name\n1,Ada\n" (Some "text/csv") in
  A.check A.bool "addressable" true r.E.path_addressable;
  A.check A.bool "row path" true (contains_substring r.E.text "$.rows[0].name")

let () =
  Alcotest.run "fetch"
    [
      ( "windowing",
        [
          A.test_case "a short text is returned whole" `Quick test_a_short_text_is_returned_whole;
          A.test_case "a long text is cut at a paragraph break" `Quick
            test_a_long_text_is_cut_at_a_paragraph_break;
          A.test_case "the marker is not counted in the offsets" `Quick
            test_the_marker_is_not_counted_in_the_offsets;
          A.test_case "an offset slices mid document" `Quick test_an_offset_slices_mid_document;
          A.test_case "a window reaching the end is not flagged" `Quick
            test_a_window_that_reaches_the_end_is_not_flagged;
          A.test_case "an offset past the end flags" `Quick
            test_an_offset_past_the_end_returns_empty_but_still_flags;
          A.test_case "an uncapped window is the whole text" `Quick
            test_an_uncapped_window_is_the_whole_text;
        ] );
      ( "url validation",
        [
          A.test_case "non-http schemes are refused" `Quick test_non_http_schemes_are_refused;
          A.test_case "credentials are refused" `Quick test_credentials_are_refused_not_stripped;
          A.test_case "missing host is refused" `Quick test_missing_host_is_refused;
          A.test_case "ordinary url keeps its query" `Quick
            test_ordinary_url_passes_and_keeps_its_query;
          A.test_case "fragment is dropped" `Quick test_fragment_is_dropped;
          A.test_case "unsendable ports are refused" `Quick test_an_unsendable_port_is_refused;
          A.test_case "an ordinary port passes" `Quick test_an_ordinary_port_passes;
          A.test_case "scheme lowercased, empty path is root" `Quick
            test_the_scheme_is_lowercased_and_an_empty_path_becomes_root;
        ] );
      ( "images",
        [
          A.test_case "the signature table names the admitted types" `Quick
            test_the_signature_table_names_exactly_the_admitted_types;
          A.test_case "each signature sniffs as its type" `Quick test_each_signature_sniffs_as_its_type;
          A.test_case "resolved cap" `Quick test_resolved_cap;
        ] );
      ( "plumbing",
        [
          A.test_case "media type strips parameters" `Quick test_media_type_strips_parameters;
          A.test_case "charset is parsed" `Quick test_charset_is_parsed;
          A.test_case "the json suffix is supported" `Quick test_is_supported_reads_the_json_suffix;
          A.test_case "describe_types renders families in order" `Quick
            test_describe_types_renders_the_families_in_order;
          A.test_case "sniffs html" `Quick test_sniffs_html;
          A.test_case "decode prefers the declared charset" `Quick test_declared_charset_is_preferred;
          A.test_case "undecodable bytes do not raise" `Quick test_undecodable_bytes_do_not_raise;
          A.test_case "unknown codec falls back" `Quick
            test_a_declared_charset_no_codec_names_falls_back;
          A.test_case "windows-1252 specials decode" `Quick test_windows_1252_specials_decode;
          A.test_case "normalise collapses and measures" `Quick
            test_normalise_collapses_and_measures_in_codepoints;
        ] );
      ( "passage selection",
        [
          A.test_case "prefers chunks hitting more terms" `Quick
            test_prefers_chunks_hitting_more_terms;
          A.test_case "budget stops selection and counts dropped" `Quick
            test_budget_stops_selection_and_counts_dropped;
          A.test_case "adjacent chunks merge" `Quick test_adjacent_selected_chunks_merge_into_one_span;
          A.test_case "no match returns nothing" `Quick test_no_match_returns_nothing_and_no_drops;
          A.test_case "short query tokens are ignored" `Quick test_short_query_tokens_are_ignored;
        ] );
      ( "stdlib backend",
        [
          A.test_case "names itself and claims no pdf" `Quick test_it_names_itself_and_claims_no_pdf;
          A.test_case "article survives, chrome does not" `Quick
            test_the_article_survives_and_its_chrome_does_not;
          A.test_case "a list reads as items" `Quick test_a_list_reads_as_items;
          A.test_case "an empty list item earns no bullet" `Quick
            test_an_empty_list_item_earns_no_bullet;
          A.test_case "a table keeps its cells apart" `Quick test_a_table_keeps_its_cells_apart;
          A.test_case "a row begins at its first cell" `Quick test_a_row_begins_at_its_first_cell;
          A.test_case "an icon sprite does not rename the page" `Quick
            test_an_icon_sprite_does_not_rename_the_page;
          A.test_case "a title inside a graphic is never the page name" `Quick
            test_a_title_inside_a_graphic_is_never_the_page_name;
          A.test_case "both break spellings mean one line" `Quick
            test_both_ways_of_writing_a_break_mean_one_line;
          A.test_case "form text goes with the form" `Quick
            test_the_text_inside_a_form_goes_with_the_form;
          A.test_case "a block left open does not swallow the page" `Quick
            test_a_block_left_open_does_not_swallow_the_rest_of_the_page;
          A.test_case "missing content type is sniffed" `Quick test_missing_content_type_is_sniffed;
          A.test_case "a js shell yields empty text" `Quick
            test_javascript_shell_yields_empty_text_not_an_error;
          A.test_case "a pdf is a refusal naming the type" `Quick
            test_a_pdf_is_a_refusal_naming_the_type;
          A.test_case "untagged markup is text" `Quick
            test_untagged_markup_is_read_as_text_not_as_a_failure;
          A.test_case "plain text passes through" `Quick test_plain_text_passes_through;
          A.test_case "plain text whitespace collapses" `Quick
            test_plain_text_whitespace_runs_are_collapsed;
          A.test_case "unextractable types raise" `Quick test_unextractable_types_raise;
          A.test_case "json becomes addressable structure" `Quick
            test_a_json_body_becomes_structure_a_path_can_address;
          A.test_case "a non-document json body is its text" `Quick
            test_a_body_that_is_not_one_json_document_comes_back_as_its_text;
          A.test_case "csv arrives as row paths" `Quick test_a_csv_document_arrives_as_row_paths;
        ] );
    ]
