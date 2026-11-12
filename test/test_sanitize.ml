(* Port of tests/test_sanitize.py: the rule, its two passes, the boundary.

   The Python oracle defines the expected strings; the cases here are the same
   ones, written against alcotest. *)

module S = Seekwright.Sanitize
module M = Seekwright.Model
open Test_support

let z = S.zwsp

let check_sanitize msg input expected count =
  let out, n = S.sanitize_text input in
  Alcotest.(check int) (msg ^ ": count") count n;
  Alcotest.(check string) (msg ^ ": text") expected out

let drop_zwsp text = replace_all ~haystack:text ~needle:z ~with_:""

let member name = function
  | `Assoc kvs -> List.assoc_opt name kvs
  | _ -> None

let member_exn name json =
  match member name json with
  | Some value -> value
  | None -> Alcotest.fail (Printf.sprintf "missing member %S" name)

let string_member name json =
  match member_exn name json with
  | `String s -> s
  | _ -> Alcotest.fail (Printf.sprintf "member %S is not a string" name)

let mk_result ?snippet ?text ?text_truncated ?published_date ?score ~title ~url ()
    : M.result =
  { M.title; url; snippet; text; text_truncated; published_date; score }

let mk_search_response ?answer ?retrieved_at ?notice ~query ~provider ~results ()
    : M.search_response =
  { M.query; provider; results; answer; retrieved_at; notice }

let mk_fetch_response ?title ?text ?content_type ?status_code ?retrieved_at
    ?(truncated = false) ?total_chars ?offset ?matches ?image ?notice ~url
    ~requested_url () : M.fetch_response =
  {
    M.url;
    requested_url;
    title;
    text;
    content_type;
    status_code;
    retrieved_at;
    truncated;
    total_chars;
    offset;
    matches;
    image;
    notice;
  }

let mk_answer_response ?retrieved_at ?truncated ?notice ~query ~answer ~sources
    ~model ~depth ~searches ~fetched () : M.answer_response =
  {
    M.query;
    answer;
    sources;
    model;
    depth;
    searches;
    fetched;
    retrieved_at;
    truncated;
    notice;
  }

let test_incident_string () =
  check_sanitize "incident"
    "Encountered text corresponding to disallowed special token '<|endoftext|>'."
    (Printf.sprintf
       "Encountered text corresponding to disallowed special token '<%s|endoftext|>'."
       z)
    1

let test_escape_is_idempotent () =
  let once, n = S.sanitize_text "<|im_start|>user<|im_end|>" in
  Alcotest.(check int) "first pass count" 2 n;
  let twice, n2 = S.sanitize_text once in
  Alcotest.(check int) "second pass count" 0 n2;
  Alcotest.(check string) "second pass text" once twice

let test_angle_shapes () =
  Alcotest.(check int) "fullwidth shape" 1
    (snd (S.sanitize_text "<｜end▁of▁sentence｜>"));
  Alcotest.(check int) "chatml shape" 2
    (snd (S.sanitize_text "<|im_start|>system<|im_end|>"))

let test_literal_markers () =
  Alcotest.(check int) "llama markers" 3
    (snd (S.sanitize_text "[INST] hi <<SYS>> x [/INST]"));
  Alcotest.(check int) "gemma markers" 2
    (snd (S.sanitize_text "<start_of_turn>model<end_of_turn>"))

let test_false_positive_canon_untouched () =
  List.iter
    (fun text ->
      let out, n = S.sanitize_text text in
      Alcotest.(check int) (Printf.sprintf "%S: count" text) 0 n;
      Alcotest.(check string) (Printf.sprintf "%S: text" text) text out)
    [
      "<s>strike</s>";
      "<think>x</think>";
      "0 < |x| < 1";
      "a < b && c > d";
      "<|endoftext is unterminated";
      "";
    ]

let test_count_counts_every_literal () =
  let source = "<|a|> and [INST] and <start_of_turn>" in
  let out, n = S.sanitize_text source in
  Alcotest.(check int) "count" 3 n;
  Alcotest.(check string) "reversible" source (drop_zwsp out)

let test_text_without_delimiters_is_returned_unscanned () =
  let text = "nothing structural here" in
  let out, n = S.sanitize_text text in
  Alcotest.(check int) "count" 0 n;
  Alcotest.(check string) "text" text out;
  Alcotest.(check bool) "same object" true (out == text)

(* The {1,64} content ceiling is counted in codepoints; [▁] is three bytes in
   UTF-8, so a byte-counting scan would answer the 64 case as a non-match. *)
let test_the_sixty_four_ceiling () =
  let ascii n = "<|" ^ String.concat "" (List.init n (fun _ -> "a")) ^ "|>" in
  Alcotest.(check int) "64 ascii codepoints" 1 (snd (S.sanitize_text (ascii 64)));
  Alcotest.(check int) "65 ascii codepoints" 0
    (snd (S.sanitize_text (ascii 65)));
  let wide n = "<｜" ^ String.concat "" (List.init n (fun _ -> "▁")) ^ "｜>" in
  Alcotest.(check int) "64 wide codepoints" 1 (snd (S.sanitize_text (wide 64)));
  Alcotest.(check int) "65 wide codepoints" 0 (snd (S.sanitize_text (wide 65)))

let test_a_search_response_walks_results_and_answer () =
  let response =
    mk_search_response ~query:"how do I quote <|endoftext|>" ~provider:"fakeserp"
      ~results:
        [
          mk_result ~title:"a title with <start_of_turn>"
            ~url:"https://e.com/tokens" ~snippet:"[INST] a snippet" ();
          mk_result ~title:"plain" ~url:"https://e.com/plain"
            ~text:"text with <|im_end|>" ();
        ]
      ~answer:"an answer quoting <<SYS>>" ()
  in
  let escaped, n = M.sanitize_search_response response in
  Alcotest.(check int) "count" 4 n;
  Alcotest.(check string) "first title"
    (Printf.sprintf "a title with <%sstart_of_turn>" z)
    (List.nth escaped.results 0).title;
  Alcotest.(check (option string)) "first snippet"
    (Some (Printf.sprintf "[%sINST] a snippet" z))
    (List.nth escaped.results 0).snippet;
  Alcotest.(check (option string)) "second text"
    (Some (Printf.sprintf "text with <%s|im_end|>" z))
    (List.nth escaped.results 1).text;
  Alcotest.(check (option string)) "answer"
    (Some (Printf.sprintf "an answer quoting <%s<SYS>>" z))
    escaped.answer

let test_the_callers_own_strings_are_not_escaped () =
  let response =
    mk_search_response ~query:"how do I quote <|endoftext|>" ~provider:"fakeserp"
      ~results:
        [
          mk_result ~title:"t" ~url:"https://e.com/?q=<|endoftext|>"
            ~text:"body" ();
        ]
      ()
  in
  let escaped, n = M.sanitize_search_response response in
  Alcotest.(check int) "count" 0 n;
  Alcotest.(check string) "query kept" "how do I quote <|endoftext|>" escaped.query;
  Alcotest.(check string) "url kept" "https://e.com/?q=<|endoftext|>"
    (List.nth escaped.results 0).url

let test_fetch_and_answer_shapes_recurse_into_their_lists () =
  let fetch =
    mk_fetch_response ~url:"https://e.com" ~requested_url:"https://e.com"
      ~title:"a title with <end_of_turn>"
      ~matches:
        [
          { M.offset = 0; text = "[INST] a passage" };
          { M.offset = 10; text = "a plain passage" };
        ]
      ()
  in
  let fetch, fetch_count = M.sanitize_fetch_response fetch in
  Alcotest.(check int) "fetch count" 2 fetch_count;
  Alcotest.(check (option string)) "fetch title"
    (Some (Printf.sprintf "a title with <%send_of_turn>" z))
    fetch.title;
  let matches =
    match fetch.matches with Some ms -> ms | None -> Alcotest.fail "matches gone"
  in
  Alcotest.(check string) "first match" (Printf.sprintf "[%sINST] a passage" z)
    (List.nth matches 0).text;
  Alcotest.(check string) "second match" "a plain passage"
    (List.nth matches 1).text;
  let answer =
    mk_answer_response ~query:"q" ~answer:"prose with <|eom|>"
      ~sources:
        [
          {
            M.source_title = "a source with <<SYS>>";
            source_url = "https://e.com";
            source_provider = "p";
          };
          {
            M.source_title = "plain";
            source_url = "https://e.com/2";
            source_provider = "p";
          };
        ]
      ~model:"m" ~depth:M.Brief ~searches:1 ~fetched:0 ()
  in
  let answer, answer_count = M.sanitize_answer_response answer in
  Alcotest.(check int) "answer count" 2 answer_count;
  Alcotest.(check string) "answer prose"
    (Printf.sprintf "prose with <%s|eom|>" z)
    answer.answer;
  Alcotest.(check string) "first source"
    (Printf.sprintf "a source with <%s<SYS>>" z)
    (List.nth answer.sources 0).source_title

let test_a_clean_response_counts_zero () =
  let response =
    mk_search_response ~query:"q" ~provider:"fakeserp"
      ~results:[ mk_result ~title:"t" ~url:"https://e.com" ~snippet:"s" () ]
      ()
  in
  let _, n = M.sanitize_search_response response in
  Alcotest.(check int) "count" 0 n

let test_a_response_bypassing_the_engines_escapes_on_dump () =
  let response =
    mk_search_response ~query:"q" ~provider:"p"
      ~results:
        [
          mk_result ~title:"t" ~url:"https://e.com"
            ~text:"x <|endoftext|> y [INST] z" ();
        ]
      ~answer:"an <|im_end|>" ()
  in
  let json = M.search_response_to_yojson response in
  let result = List.hd (match member_exn "results" json with `List l -> l | _ -> []) in
  Alcotest.(check string) "result text"
    (Printf.sprintf "x <%s|endoftext|> y [%sINST] z" z z)
    (string_member "text" result);
  Alcotest.(check string) "answer"
    (Printf.sprintf "an <%s|im_end|>" z)
    (string_member "answer" json)

let test_a_leaf_model_escapes_its_own_fields () =
  let json = M.fetch_match_to_yojson { M.offset = 0; text = "[INST] x" } in
  Alcotest.(check string) "leaf text" (Printf.sprintf "[%sINST] x" z)
    (string_member "text" json)

let test_a_cached_response_reread_escapes_once () =
  let response =
    mk_search_response ~query:"q" ~provider:"p"
      ~results:
        [
          mk_result ~title:"t" ~url:"https://e.com"
            ~text:"raw <|im_start|> raw" ();
        ]
      ()
  in
  let first = M.search_response_to_yojson response in
  let reread =
    match M.search_response_of_yojson first with
    | Ok value -> value
    | Error e -> Alcotest.fail ("decode failed: " ^ e)
  in
  let second = M.search_response_to_yojson reread in
  Alcotest.(check bool) "byte-identical" true (Yojson.Safe.equal first second)

(* The incident payload pinned verbatim in tests/test_sanitize.py; the MD5
   assertion makes a transcription slip fail instead of weakening the case. *)
let golden_incident_text =
  {|## Bug Description

When the RAG text splitter is configured to `token`, fetching web pages that contain the literal string `<|endoftext|>` (e.g. in scraped documentation, code examples, or dataset pages) causes an unhandled exception and the request silently fails with no response.

## Steps to Reproduce

1. Go to **Admin Panel → Documents → Text Splitter** and set it to `token`
2. Start a chat with a model that has web search enabled
3. Ask a question that causes Open WebUI to fetch a page containing the literal text `<|endoftext|>` (common on ML/AI documentation and dataset pages)
4. Observe the error — no response is returned

## Error Message

```
Encountered text corresponding to disallowed special token '<|endoftext|>'.
If you want this text to be encoded as a special token, pass it to `allowed_special`,
e.g. `allowed_special={'<|endoftext|>', ...}`.
If you want this text to be encoded as normal text, disable the check for this token by
passing `disallowed_special=(enc.special_tokens_set - {'<|endoftext|>'})`.
To disable this check for all special tokens, pass `disallowed_special=()`.
```

## Root Cause

In `backend/open_webui/routers/retrieval.py`, `TokenTextSplitter` (from LangChain) is instantiated without `allowed_special`, so tiktoken uses its default strict mode and raises a `ValueError` when it encounters any special token literal in the content being chunked.

The length function on line 1585 already correctly passes `disallowed_special=()`, but the `TokenTextSplitter` on line 1687 does not:

```python
# Line 1584-1585 — CORRECT, already safe:
encoding = tiktoken.get_encoding(str(config.TIKTOKEN_ENCODING_NAME))
return lambda text: len(encoding.encode(text, disallowed_special=()))

# Line 1687-1692 — BUG, missing allowed_special:
text_splitter = TokenTextSplitter(
    encoding_name=str(config.TIKTOKEN_ENCODING_NAME),
    chunk_size=config.CHUNK_SIZE,
    chunk_overlap=config.CHUNK_OVERLAP,
    add_start_index=True,
    # ← no allowed_special here, tiktoken will crash on <|endoftext|> etc.
)
```

## Proposed Fix

Pass `allowed_special="all"` to `TokenTextSplitter` so special token literals in web content are treated as plain text, consistent with how the length function is already handled:

```python
text_splitter = TokenTextSplitter(
    encoding_name=str(config.TIKTOKEN_ENCODING_NAME),
    chunk_size=config.CHUNK_SIZE,
    chunk_overlap=config.CHUNK_OVERLAP,
    add_start_index=True,
    allowed_special="all",
)
```

## Workaround

Set the RAG Text Splitter back to the default (`character`) in **Admin Panel → Documents**. This avoids `TokenTextSplitter` entirely and the crash does not occur.

## Environment

- **Branch:** `dev`
- **File:** `backend/open_webui/routers/retrieval.py`
- **Affected setting:** RAG Text Splitter = `token`
- **Trigger:** Any web fetch returning a page with `<|endoftext|>` in its content|}

let test_the_golden_payload_is_the_incident_payload () =
  Alcotest.(check string) "md5" "45d195493c1ad03dff65e4a54bac7cfc"
    (Digest.to_hex (Digest.string golden_incident_text))

let test_the_payload_escapes_completely () =
  let out, n = S.sanitize_text golden_incident_text in
  Alcotest.(check int) "count" 7 n;
  Alcotest.(check bool) "literal gone" false
    (count_occurrences ~haystack:out ~needle:"<|endoftext|>" > 0);
  Alcotest.(check bool) "rejected line rewritten" true
    (count_occurrences ~haystack:out
       ~needle:(Printf.sprintf "disallowed special token '<%s|endoftext|>'." z)
    > 0)

let test_the_payload_travels_the_boundary_and_back () =
  let response =
    mk_search_response ~query:"tiktoken special tokens" ~provider:"freeserp"
      ~results:
        [
          mk_result ~title:"open-webui #27094"
            ~url:"https://github.com/open-webui/open-webui/issues/27094"
            ~text:golden_incident_text ();
        ]
      ()
  in
  let json = M.search_response_to_yojson response in
  let result = List.hd (match member_exn "results" json with `List l -> l | _ -> []) in
  let served = string_member "text" result in
  Alcotest.(check bool) "literal gone" false
    (count_occurrences ~haystack:served ~needle:"<|endoftext|>" > 0);
  Alcotest.(check int) "seven escapes" 7 (count_occurrences ~haystack:served ~needle:z);
  let reread =
    match M.search_response_of_yojson json with
    | Ok value -> value
    | Error e -> Alcotest.fail ("decode failed: " ^ e)
  in
  Alcotest.(check bool) "cache reread unchanged" true
    (Yojson.Safe.equal json (M.search_response_to_yojson reread));
  Alcotest.(check string) "reversible" golden_incident_text (drop_zwsp served)

let () =
  Alcotest.run "sanitize"
    [
      ( "SanitizeText",
        [
          Alcotest.test_case "the incident string" `Quick test_incident_string;
          Alcotest.test_case "the escape is idempotent" `Quick
            test_escape_is_idempotent;
          Alcotest.test_case "the angle shapes" `Quick test_angle_shapes;
          Alcotest.test_case "the literal markers" `Quick test_literal_markers;
          Alcotest.test_case "the false-positive canon is untouched" `Quick
            test_false_positive_canon_untouched;
          Alcotest.test_case "the count counts every literal" `Quick
            test_count_counts_every_literal;
          Alcotest.test_case "text without delimiters is returned unscanned"
            `Quick test_text_without_delimiters_is_returned_unscanned;
          Alcotest.test_case "the sixty-four-codepoint ceiling" `Quick
            test_the_sixty_four_ceiling;
        ] );
      ( "SanitizeModel",
        [
          Alcotest.test_case "a search response walks results and answer" `Quick
            test_a_search_response_walks_results_and_answer;
          Alcotest.test_case "the caller's own strings are not escaped" `Quick
            test_the_callers_own_strings_are_not_escaped;
          Alcotest.test_case "fetch and answer shapes recurse into their lists"
            `Quick test_fetch_and_answer_shapes_recurse_into_their_lists;
          Alcotest.test_case "a clean response counts zero" `Quick
            test_a_clean_response_counts_zero;
        ] );
      ( "SerializationBoundary",
        [
          Alcotest.test_case "a response bypassing the engines escapes on dump"
            `Quick test_a_response_bypassing_the_engines_escapes_on_dump;
          Alcotest.test_case "a leaf model escapes its own fields" `Quick
            test_a_leaf_model_escapes_its_own_fields;
          Alcotest.test_case "a cached response reread escapes once" `Quick
            test_a_cached_response_reread_escapes_once;
        ] );
      ( "GoldenIncidentPayload",
        [
          Alcotest.test_case "the payload is pinned verbatim" `Quick
            test_the_golden_payload_is_the_incident_payload;
          Alcotest.test_case "the payload escapes completely" `Quick
            test_the_payload_escapes_completely;
          Alcotest.test_case "the payload travels the boundary and back" `Quick
            test_the_payload_travels_the_boundary_and_back;
        ] );
    ]
