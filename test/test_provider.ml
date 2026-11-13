(* The provider contract's machinery, tested apart from any adapter.

   Port of the parts of tests/providers/ that are not about one backend: the
   constraint report and its sentence, the snippet and text caps, and the
   failure rows provider-contract.md's Failures table fixes. The rows are driven
   over real adapters by test_provider_contract.ml; what stays here is the
   wording, the bucket rules, and the unit the caps count in. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module A = Alcotest
open Test_support

let query ?(text = "q") ?(max_results = 5) ?(include_domains = [])
    ?(exclude_domains = []) ?country ?language ?recency ?safe_search () :
    Model.search_query =
  {
    Model.query = text;
    max_results;
    include_domains;
    exclude_domains;
    country;
    language;
    recency;
    safe_search;
  }

(* An adapter that honours everything, as a call site writes it. *)
let honoured q =
  Provider.ignored_constraints q ~domains:true ~dates:true ~geo:true
    ~language:(Some true) ~safety:true

(* The constraint report. *)

let no_constraints_draws_no_notice () =
  check_opt_string "an unconstrained query" None (honoured (query ()))

let each_bucket_names_its_token () =
  let cases =
    [
      ("a domain filter", query ~include_domains:[ "go.dev" ] (), "domain");
      ("an excluded domain", query ~exclude_domains:[ "spam.example" ] (), "domain");
      ("a recency", query ~recency:Model.Week (), "dates");
      ("a country", query ~country:"de" (), "country");
      ("a language", query ~language:"de" (), "language");
      ("safe-search on", query ~safe_search:true (), "safe-search");
      ("safe-search off", query ~safe_search:false (), "safe-search");
    ]
  in
  List.iter
    (fun (what, q, token) ->
      (* The bucket is refused, and the sentence names only that bucket. *)
      (* [~language:(Some false)]: this probe refuses every bucket, so each case
         has to name exactly one drop. *)
      match
        Provider.ignored_constraints q ~domains:false ~dates:false ~geo:false
          ~language:(Some false) ~safety:false
      with
      | None -> A.failf "%s drew no notice" what
      | Some sentence ->
          check_string what
            (Printf.sprintf "cannot filter by %s; that constraint was ignored" token)
            sentence)
    cases

let the_geo_bucket_stays_joined_when_language_is_not_answered () =
  (* [~language:None] is Python's default: an adapter with no geo surface at all
     reports both halves as one token. *)
  let q = query ~country:"de" ~language:"de" () in
  check_string "the joined bucket" "cannot filter by country/language; that constraint was ignored"
    (Option.value
       ~default:""
       (Provider.ignored_constraints q ~domains:true ~dates:true ~geo:false ~language:None
          ~safety:true))

let a_split_bucket_names_only_what_dropped () =
  (* The shape both keyless adapters call with: language rides the wire, the
     country does not, so the joined token would claim a drop that did not
     happen. *)
  let q = query ~country:"de" ~language:"de" () in
  check_string "the split bucket" "cannot filter by country; that constraint was ignored"
    (Option.value
       ~default:""
       (Provider.ignored_constraints q ~domains:true ~dates:true ~geo:false
          ~language:(Some true) ~safety:true))

let every_dropped_bucket_is_named_in_order () =
  let q =
    query ~include_domains:[ "go.dev" ] ~exclude_domains:[ "spam.example" ] ~recency:Model.Day
      ~country:"de" ~language:"de" ~safe_search:true ()
  in
  check_string "all five buckets"
    "cannot filter by domain or dates or country or language or safe-search; that \
     constraint was ignored"
    (Option.value
       ~default:""
       (Provider.ignored_constraints q ~domains:false ~dates:false ~geo:false
          ~language:(Some false) ~safety:false))

let a_constraint_that_is_not_asked_for_draws_no_notice () =
  (* The buckets fire on what the caller asked for, not on what the adapter
     cannot do: an incapable adapter with nothing asked files nothing. *)
  check_opt_string "nothing asked" None
    (Provider.ignored_constraints (query ()) ~domains:false ~dates:false ~geo:false
       ~language:None ~safety:false)

(* Folding domain filters into the query, for the backends where the operators
   are the interface. *)

let site_operators () =
  check_string "no filters" "wal mode" (Provider.site_filtered_query (query ~text:"wal mode" ()));
  check_string "one include" "wal mode site:sqlite.org"
    (Provider.site_filtered_query (query ~text:"wal mode" ~include_domains:[ "sqlite.org" ] ()));
  check_string "two includes are grouped" "wal mode (site:sqlite.org OR site:python.org)"
    (Provider.site_filtered_query
       (query ~text:"wal mode" ~include_domains:[ "sqlite.org"; "python.org" ] ()));
  check_string "excludes carry the minus" "wal mode -site:spam.example"
    (Provider.site_filtered_query
       (query ~text:"wal mode" ~exclude_domains:[ "spam.example" ] ()));
  check_string "both, includes first" "q site:a.com -site:b.com"
    (Provider.site_filtered_query (query ~include_domains:[ "a.com" ] ~exclude_domains:[ "b.com" ] ()))

(* The caps. *)

let a_short_snippet_is_returned_whole () =
  let snippet, uncapped = Provider.truncate_snippet (Some "short enough.") 500 in
  check_opt_string "whole" (Some "short enough.") snippet;
  check_opt_int "measured" (Some 13) uncapped

let a_missing_snippet_stays_missing () =
  let snippet, uncapped = Provider.truncate_snippet None 500 in
  check_opt_string "no snippet" None snippet;
  (* Not a string upstream is not a length either: the cap measured nothing. *)
  check_opt_int "no measurement" None uncapped

let whitespace_is_normalised_before_the_cap () =
  let snippet, uncapped = Provider.truncate_snippet (Some "  a \n b\tc  ") 500 in
  check_opt_string "collapsed" (Some "a b c") snippet;
  check_opt_int "the length the cap received" (Some 5) uncapped

let unicode_whitespace_is_normalised_before_the_cap () =
  (* Python's [str.split()] splits on the Unicode spaces, not ASCII only, so an
     ideographic or no-break space is a word boundary here too (F1.5). *)
  let snippet, uncapped =
    Provider.truncate_snippet (Some "\xe3\x80\x80a\xc2\xa0b\xe3\x80\x80") 500
  in
  check_opt_string "unicode blanks collapse" (Some "a b") snippet;
  check_opt_int "measured after collapsing" (Some 3) uncapped

let a_sentence_boundary_beats_mid_word () =
  let snippet, uncapped = Provider.truncate_snippet (Some "alpha beta. gamma delta") 12 in
  check_opt_string "cut at the sentence" (Some "alpha beta.") snippet;
  check_opt_int "measured whole" (Some 23) uncapped

let a_boundary_too_early_is_not_used () =
  (* A period in the first quarter of the window saves nothing; the plain cut
     carries more text. *)
  let snippet, uncapped = Provider.truncate_snippet (Some "One. and then more words") 20 in
  check_opt_string "plain cut" (Some "One. and then more w…") snippet;
  check_opt_int "measured whole" (Some 24) uncapped

let the_cap_counts_characters_not_bytes () =
  (* Python's [len] and slicing count codepoints. A byte-wise cap would cut a
     multibyte token in half — the snippet has to stay valid UTF-8 for the
     caller's tokenizer — and the length figure has to mean the same thing on
     both sides of the port. Nine characters here is seventeen bytes. *)
  let snippet, uncapped = Provider.truncate_snippet (Some "éééé éééé") 5 in
  check_opt_string "cut after five characters" (Some "éééé…") snippet;
  check_int "the clipped snippet is eleven bytes" 11 (String.length (Option.get snippet));
  check_int "the source is seventeen bytes" 17 (String.length "éééé éééé");
  check_opt_int "measured in characters" (Some 9) uncapped

(* Differential, driven over the corpus the P4 review diffed against
   [src/seekwright/providers/base.py]. These eight pairs are the ones where the
   byte length and the codepoint length fall on opposite sides of the cap, so a
   byte-wise guard clips or ellipsises what Python returns whole — and reports
   the cut where Python reports none. Rows are (text, limit, snippet, uncapped
   length, cut); every value is the oracle's own answer. *)
let the_crossing_pairs_match_the_oracle () =
  let thirty_e = String.concat "" (List.init 30 (fun _ -> "é")) in
  let cases =
    [
      ("héllo. x", 8, "héllo. x", 8);
      ("éabcd", 5, "éabcd", 5);
      ("naïve café. next sentence here", 30, "naïve café. next sentence here", 30);
      ("日本語のテキストです。次", 12, "日本語のテキストです。次", 12);
      ("日本語のテキストです。次", 20, "日本語のテキストです。次", 12);
      ("日本語のテキストです。次", 30, "日本語のテキストです。次", 12);
      ("emoji 😀 test", 12, "emoji 😀 test", 12);
      (thirty_e, 30, thirty_e, 30);
    ]
  in
  (* The fixtures have to be the ones the cap cannot settle: bytes past the cap,
     codepoints not. Otherwise the guard under test is never reached. *)
  check_int "the Japanese snippet is 36 bytes" 36 (String.length "日本語のテキストです。次");
  check_int "the thirty-é snippet is 60 bytes" 60 (String.length thirty_e);
  List.iter
    (fun (text, limit, expected, uncapped) ->
      let what = Printf.sprintf "%S at %d" text limit in
      check_bool "the byte length passes the cap" true (String.length text > limit);
      let snippet, measured = Provider.truncate_snippet (Some text) limit in
      check_opt_string (what ^ " snippet") (Some expected) snippet;
      check_opt_int (what ^ " measured") (Some uncapped) measured;
      let text_out, cut, text_measured = Provider.truncate_text (Some text) limit in
      check_opt_string (what ^ " text") (Some expected) text_out;
      check_bool (what ^ " not cut") false cut;
      check_opt_int (what ^ " text measured") (Some uncapped) text_measured)
    cases

(* The ASCII half of the same differential: the boundary preference, the plain
   cut, the rstrip before the ellipsis, and the [limit / 2] threshold all have to
   land where Python's [str] slicing does. *)
let ascii_caps_match_the_oracle () =
  let cases =
    [
      ("hello", 5, "hello", 5, false);
      ("hello", 3, "hel…", 5, true);
      ("hello", 0, "…", 5, true);
      ("hello world", 8, "hello wo…", 11, true);
      ("a. b. c. d. e.", 5, "a. b.", 14, true);
      ("a. b. c. d. e.", 8, "a. b. c.", 14, true);
      ("a. b. c. d. e.", 12, "a. b. c. d.", 14, true);
      ("One. and then more words", 20, "One. and then more w…", 24, true);
      ("alpha beta. gamma delta", 12, "alpha beta.", 23, true);
      ("aaaaaaaaaa. bbbbbbbbbb", 12, "aaaaaaaaaa.", 22, true);
      ("no period at all", 5, "no pe…", 16, true);
      ("tab\there and  spaces", 8, "tab here…", 19, true);
      ("ends with period.", 20, "ends with period.", 17, false);
    ]
  in
  List.iter
    (fun (text, limit, expected, uncapped, expected_cut) ->
      let what = Printf.sprintf "%S at %d" text limit in
      let snippet, measured = Provider.truncate_snippet (Some text) limit in
      check_opt_string (what ^ " snippet") (Some expected) snippet;
      check_opt_int (what ^ " measured") (Some uncapped) measured;
      let text_out, cut, text_measured = Provider.truncate_text (Some text) limit in
      check_opt_string (what ^ " text") (Some expected) text_out;
      check_bool (what ^ " cut") expected_cut cut;
      check_opt_int (what ^ " text measured") (Some uncapped) text_measured)
    cases

let text_reports_whether_it_was_cut () =
  let text, cut, uncapped = Provider.truncate_text (Some "short") 500 in
  check_opt_string "whole" (Some "short") text;
  check_bool "not cut" false cut;
  check_opt_int "measured" (Some 5) uncapped;
  let text, cut, uncapped = Provider.truncate_text (Some "alpha beta. gamma delta") 12 in
  check_opt_string "cut" (Some "alpha beta.") text;
  check_bool "reported" true cut;
  check_opt_int "measured" (Some 23) uncapped

let empty_text_is_absent_not_empty () =
  let text, cut, uncapped = Provider.truncate_text (Some "   \n  ") 500 in
  check_opt_string "absent" None text;
  check_bool "nothing was cut" false cut;
  check_opt_int "nothing measured" None uncapped

(* The failure vocabulary. *)

let the_quota_row_is_never_retryable () =
  let e = Provider.quota_exhausted ~provider:"freeserp" () in
  check_string "the default wording" "quota exhausted" e.message;
  check_string "named by its provider" "freeserp: quota exhausted" (Provider.render_error e);
  check_bool "not retryable" false e.retryable;
  check_bool "a quota failure" true (e.kind = Provider.Quota);
  check_string "a backend words its own quota failure" "out of credits or rate limited"
    (Provider.quota_exhausted ~provider:"anysearch" ~message:"out of credits or rate limited" ()).message

let the_auth_row_is_not_retryable () =
  let e = Provider.auth_error ~provider:"freeserp" in
  check_string "the contracted sentence" "authentication rejected (check API key)" e.message;
  check_bool "not retryable" false e.retryable;
  check_bool "an ordinary failure" true (e.kind = Provider.Failure)

let the_status_row_carries_only_the_code () =
  check_string "500" "HTTP 500" (Provider.http_status_error ~provider:"freeserp" 500).message;
  check_string "418" "HTTP 418" (Provider.http_status_error ~provider:"freeserp" 418).message

let the_grant_answered_its_two_transport_rows () =
  let row kind =
    Provider.transport_error ~provider:"freeserp"
      (Caps.Error.make kind ~message:"connect 203.0.113.9:443 refused q=secret-query")
  in
  check_string "the bound row" "request timed out" (row Caps.Error.Timeout).message;
  List.iter
    (fun kind ->
      let e = row kind in
      check_string "the network row" "network error" e.message;
      (* The redaction rule, at the point where an OCaml adapter could break it:
         the authority's own account of the failure — address, query, anything —
         never rides along. *)
      check_bool "nothing from the grant is echoed" false
        (contains ~haystack:(Provider.render_error e) ~needle:"203.0.113.9"
        || contains ~haystack:(Provider.render_error e) ~needle:"secret-query"))
    [ Caps.Error.Denied; Invalid; Unavailable; Failed ]

let a_body_that_is_not_an_object_is_the_same_failure () =
  List.iter
    (fun (what, body) ->
      match Provider.decode_json_object ~provider:"freeserp" body with
      | Ok json -> A.failf "%s decoded as %s" what (Yojson.Safe.to_string json)
      | Error e -> check_string what "malformed JSON response" e.message)
    [
      ("not JSON at all", "<html>nope</html>");
      ("empty", "");
      ("an array", "[]");
      ("null", "null");
      ("a number", "42");
      ("a bare string", "\"a bare string\"");
    ];
  match Provider.decode_json_object ~provider:"freeserp" "{\"results\": []}" with
  | Ok _ -> ()
  | Error e -> A.failf "a real object was refused: %s" e.message

(* The payload readers, which is where "a field of the wrong type counts as
   absent" lives once instead of in every adapter. *)

let json_readers_drop_the_wrong_shape () =
  let record =
    Yojson.Safe.from_string
      {|{"title":"t","url":"https://x","score":1.5,"flag":true,"nested":{"a":1},"list":[1],"count":7,"empty":""}|}
  in
  check_opt_string "a string field" (Some "t") (Provider.Json.string_field "title" record);
  check_opt_string "a missing field" None (Provider.Json.string_field "absent" record);
  check_opt_string "an object is not a string" None (Provider.Json.string_field "nested" record);
  check_opt_string "an empty string is still a string" (Some "") (Provider.Json.string_field "empty" record);
  check_opt_number "a float" (Some 1.5) (Provider.Json.number_field "score" record);
  check_opt_number "an int" (Some 7.) (Provider.Json.number_field "count" record);
  (* [true] is not a number: Python's [isinstance(value, bool)] arm. *)
  check_opt_number "a bool is not a number" None (Provider.Json.number_field "flag" record);
  check_opt_number "a string is not a number" None (Provider.Json.number_field "title" record);
  check_bool "a missing key reads as null, so readers chain" true
    (Provider.Json.field "absent" record = `Null);
  check_bool "present and true" true (Provider.Json.is_true_field "flag" record);
  check_bool "absent is not true" false (Provider.Json.is_true_field "absent" record);
  let flags = Yojson.Safe.from_string {|{"engine_fallback":false,"one":1,"no":0,"yes":true}|} in
  check_bool "false is not true" false (Provider.Json.is_true_field "engine_fallback" flags);
  (* [1] is not [true], the way Python's [is True] reads. *)
  check_bool "one is not true" false (Provider.Json.is_true_field "one" flags);
  check_bool "zero is not true" false (Provider.Json.is_true_field "no" flags);
  check_bool "a non-object has no fields" false
    (Provider.Json.is_true_field "engine_fallback" (`String "site profiles"));
  check_bool "a list is a list" true
    (match Provider.Json.field "list" record with `List [ `Int 1 ] -> true | _ -> false)

let project_url_is_the_one_the_providers_send () =
  check_string "the oracle's PROJECT_URL" "https://github.com/leoschwarz/seekwright"
    Provider.project_url

(* The redaction rule, checked as a property of the source rather than of one
   run: the failure constructors take a constant string, and the values that
   could leak are only reachable through an accessor this tree never calls. *)

(* A value an adapter may put in a failure message, and one it may never name. *)
let forbidden =
  [
    (* The grant's message may name the peer address: the redaction rule is that
       an adapter never reads it. *)
    "Error.message";
    (* A URL names this deployment and its query; it belongs in a log field, not
       in a failure message. *)
    "Uri.to_string";
    (* stdout is the protocol channel, and a provider module is not a CLI. *)
    "print_";
    "prerr";
  ]

let adapter_sources =
  "../lib/provider.ml" :: "../lib/provider.mli"
  :: (Array.to_list (Sys.readdir "../lib/providers")
      |> List.filter (fun name ->
           Filename.check_suffix name ".ml" || Filename.check_suffix name ".mli")
      |> List.map (Filename.concat "../lib/providers"))

let an_adapter_never_reaches_for_the_values_that_leak () =
  List.iter
    (fun path ->
      let text = read_file path in
      List.iter
        (fun needle ->
          if contains ~haystack:text ~needle:needle then
            A.failf "%s mentions %S, which the redaction rule refuses" path needle)
        forbidden)
    adapter_sources;
  (* The guard above proves nothing if it read nothing: the contract module,
     both adapters and the MCP client have to be there. The client is scanned
     because it builds provider errors, so it owes the same redaction rule. *)
  check_int "adapter sources in the sandbox" 4
    (List.length (List.filter (fun path -> Filename.check_suffix path ".ml") adapter_sources))

let () =
  A.(
    run "seekwright/provider"
      [
        ( "the constraint report",
            [
              test_case "an unconstrained query draws no notice" `Quick no_constraints_draws_no_notice;
              test_case "each bucket names its own token" `Quick each_bucket_names_its_token;
              test_case "the geo bucket stays joined when language is not answered" `Quick
                the_geo_bucket_stays_joined_when_language_is_not_answered;
              test_case "a split bucket names only what dropped" `Quick
                a_split_bucket_names_only_what_dropped;
              test_case "every dropped bucket is named in order" `Quick
                every_dropped_bucket_is_named_in_order;
              test_case "a constraint that is not asked for draws no notice" `Quick
                a_constraint_that_is_not_asked_for_draws_no_notice;
            ] );
        ("folding domain filters into the query", [ test_case "the site: operators" `Quick site_operators ]);
        ( "the caps",
            [
              test_case "a short snippet is returned whole" `Quick a_short_snippet_is_returned_whole;
              test_case "a missing snippet stays missing" `Quick a_missing_snippet_stays_missing;
              test_case "whitespace is normalised before the cap" `Quick
                whitespace_is_normalised_before_the_cap;
              test_case "unicode whitespace is normalised before the cap" `Quick
                unicode_whitespace_is_normalised_before_the_cap;
              test_case "a sentence boundary beats mid-word" `Quick a_sentence_boundary_beats_mid_word;
              test_case "a boundary too early is not used" `Quick a_boundary_too_early_is_not_used;
              test_case "the cap counts characters, not bytes" `Quick the_cap_counts_characters_not_bytes;
              test_case "the crossing pairs match the oracle" `Quick
                the_crossing_pairs_match_the_oracle;
              test_case "ASCII pairs match the oracle" `Quick ascii_caps_match_the_oracle;
              test_case "inline text reports whether it was cut" `Quick text_reports_whether_it_was_cut;
              test_case "empty text is absent, not empty" `Quick empty_text_is_absent_not_empty;
            ] );
        ( "the failure rows",
            [
              test_case "the quota row is never retryable" `Quick the_quota_row_is_never_retryable;
              test_case "the auth row is not retryable" `Quick the_auth_row_is_not_retryable;
              test_case "the status row carries only the code" `Quick
                the_status_row_carries_only_the_code;
              test_case "the grant answers its two transport rows" `Quick
                the_grant_answered_its_two_transport_rows;
              test_case "a body that is not an object is the same failure" `Quick
                a_body_that_is_not_an_object_is_the_same_failure;
            ] );
        ( "reading an upstream payload",
            [
              test_case "a field of the wrong shape is absent" `Quick json_readers_drop_the_wrong_shape;
              test_case "the project URL is the one the oracle prints" `Quick
                project_url_is_the_one_the_providers_send;
            ] );
        ( "the seam",
            [
              test_case "no adapter reads the values the redaction rule bans" `Quick
                an_adapter_never_reaches_for_the_values_that_leak;
            ] );
      ])
