(* FreeSerp: response parsing, request shape, cost and failures.

   Port of tests/providers/test_freeserp.py. The fixture is the live
   [index=web] payload that suite pins, trimmed to two results (probed
   2026-10-14). The request-shape cases drive the adapter through a fake
   {!Seekwright.Provider.Net.t} — the same position [httpx.MockTransport] holds
   in Python, and possible here for the same reason: the client is injected.

   The wiring cases from that suite ([test_built_with_no_key_in_the_environment],
   the [KNOWN_PROVIDERS] membership checks) belong to the config and factory
   suites, P3 and P5: an adapter never decides whether it is enabled. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Freeserp = Seekwright_providers.Freeserp
module A = Alcotest

let check_string what expected got = A.(check string) what expected got
let check_bool what expected got = A.(check bool) what expected got
let check_int what expected got = A.(check int) what expected got
let check_opt what expected got = A.(check (option string)) what expected got
let check_opt_int what expected got = A.(check (option int)) what expected got

(* Alcotest's float testable takes the absolute error, not a labelled option. *)
let number = A.float 1e-9
let check_number what expected got = A.(check number) what expected got
let check_opt_number what expected got = A.(check (option number)) what expected got

let contains text needle =
  let n = String.length text and m = String.length needle in
  let rec from i =
    if i + m > n then false else String.sub text i m = needle || from (i + 1)
  in
  from 0

(* UTF-8 codepoints, so a cap assertion says the same thing the Python [len]
   said: the cap counts characters, and an ellipsis is one of them. *)
let chars s =
  let n = ref 0 and i = ref 0 in
  while !i < String.length s do
    let c = Char.code s.[!i] in
    i := !i + (if c < 0x80 then 1 else if c < 0xe0 then 2 else if c < 0xf0 then 3 else 4);
    incr n
  done;
  !n

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

(* The clock [recency] is measured against, pinned so the date the adapter
   sends is a fact this suite asserts rather than one it recomputes: 2023-11-14
   UTC, which is what the Python suite would have seen at that instant. *)
let now () = 1_700_000_000.

(* {1 The fixture}

   The live payload, trimmed to two results: the fields the mapping reads, the
   ones it must ignore ([total], [related_apis]), and the [site]/[source]
   sub-objects it never touches. *)
let sample =
  {|{
  "ok": true,
  "index": "web",
  "query": "python asyncio tutorial",
  "total": 30,
  "total_note": "FreeSerp Global returns the top 100 candidates (after de-duplication); there is no exhaustive hit count",
  "count": 2,
  "from": 0,
  "size": 2,
  "sort": "relevance",
  "ranking": "bm25_trust",
  "filters": {},
  "took_ms": 4,
  "engine_ms": 1,
  "cached": false,
  "results": [
    {
      "url": "https://www.testmuai.com/blog/python-asyncio/",
      "domain": "testmuai.com",
      "title": "Python Asyncio Tutorial: A Complete Guide",
      "snippet": "In this Python asyncio tutorial, we will explore the basics of asynchronous programming and how the event loop schedules coroutines.",
      "language": "en",
      "published_at": "2024-10-04",
      "crawled_at": "2026-07-12",
      "score": 949.36,
      "site": null,
      "source": {
        "index": "FreeSerp Global",
        "captured_at": "2026-07-12T05:28:08Z",
        "digest": "sha1:TPKDS6VQNUOUWHKQOSCZMWK3NRK7BBDR"
      }
    },
    {
      "url": "https://realpython.com/async-io-python/",
      "domain": "realpython.com",
      "title": "Async IO in Python: A Complete Walkthrough",
      "snippet": "A complete walkthrough of async IO in Python.",
      "language": "en",
      "published_at": null,
      "crawled_at": "2026-06-30",
      "score": 812.5,
      "site": {"dr": 78, "category": null},
      "source": {"index": "FreeSerp Global"}
    }
  ],
  "related_apis": {
    "note": "Companion APIs from the same team - use these to act on what you find here.",
    "news_search": {"endpoint": "https://freenewsapi.ai/v1/search"}
  }
}|}

let sample_json =
  match Yojson.Safe.from_string sample with
  | `Assoc _ as json -> json
  | _ -> A.failf "the fixture is not an object"

(* {1 The seam}

   A {!Seekwright.Provider.Net.t} that records what was dialed and answers with
   a canned response — the analogue of the Python suite's
   [httpx.MockTransport]. Every request-shape case is
   [let provider, sent = dial () in …; let request = sent ()]. *)
let dial ?(status = 200) ?(body = sample) ?(snippet_chars = 500)
    ?(cost_per_1k = 0.) () =
  let sent = ref None in
  let net =
    {
      Provider.Net.request =
        (fun request ->
          sent := Some request;
          Ok { Caps.Authority.Net.status; headers = []; body });
    }
  in
  let provider = Freeserp.make ~cost_per_1k ~snippet_chars ~now ~net () in
  (provider, fun () -> Option.get !sent)

(* A Net that answers with a transport failure instead of a response: the
   grant refusing the endpoint, the name not resolving, the bound expiring. *)
let refusal kind ~message =
  let net =
    {
      Provider.Net.request =
        (fun _ -> Error (Caps.Error.make kind ~message));
    }
  in
  Freeserp.make ~now ~net ()

(* [Policy_net] declares [body] and [headers] on both its request and its
   response record, so a caller has to say which record it means. *)
let params (request : Caps.Authority.Net.request) = Uri.query request.uri
let param (request : Caps.Authority.Net.request) name = Uri.get_query_param request.uri name

let has_param request name =
  List.exists (fun (key, _) -> key = name) (params request)

(* {1 The mapping's inputs} *)

let record fields =
  `Assoc (("title", `String "t") :: ("url", `String "https://example.com/a") :: fields)

let payload items = `Assoc [ ("results", `List items) ]

let parse ?(snippet_chars = 500) ?(limit = 10) data =
  Freeserp.parse ~snippet_chars data ~limit

let hits_json hits =
  Yojson.Safe.to_string
    (`List (List.map (fun (h : Provider.hit) -> Model.result_to_yojson h.result) hits))

(* The adapter, driven: [search_of ()] answers with the fixture and hands back
   both the outcome and the request that was dialed. *)
let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500)
    ?(cost_per_1k = 0.) ?(query = query ()) () =
  let provider, sent = dial ~status ~body ~snippet_chars ~cost_per_1k () in
  match Provider.search provider query with
  | Ok outcome -> (outcome, sent ())
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

let engine_fallback_refusal body query =
  let provider, _ = dial ~body () in
  match Provider.search provider query with
  | Ok outcome ->
      A.failf "the substituted index was accepted: %d results"
        (List.length outcome.results)
  | Error failure -> failure

(* {1 Parsing} *)

let the_fixture_yields_both_records () =
  let hits = parse sample_json in
  check_int "two results" 2 (List.length hits);
  let first = List.hd hits in
  check_string "the title" "Python Asyncio Tutorial: A Complete Guide" first.result.title;
  check_string "the url" "https://www.testmuai.com/blog/python-asyncio/" first.result.url;
  check_string "the second url" "https://realpython.com/async-io-python/"
    (List.nth hits 1).result.url

let the_limit_is_honoured () =
  check_int "one of two" 1 (List.length (parse ~limit:1 sample_json))

let a_serp_record_fills_snippet_and_never_text () =
  (* A SERP backend: the record's [snippet] is the only text there is, and a
     [text] beside it would ship the same prose twice. *)
  List.iter
    (fun (h : Provider.hit) ->
      check_bool "snippet is filled" true (h.result.snippet <> None);
      check_opt "text is never filled" None h.result.text)
    (parse sample_json)

let the_snippet_cap_clips_and_measures () =
  let hits = parse ~snippet_chars:40 sample_json in
  let snippet = Option.get (List.hd hits).result.snippet in
  check_int "cut at the cap plus the ellipsis" 41 (chars snippet);
  check_string "the cut is a plain one" "In this Python asyncio tutorial, we will…" snippet;
  (* The length the cap received, which is what makes [max_snippet_chars]
     measurable from traffic: 132 characters upstream, 41 shipped. *)
  check_opt_int "the pre-cap length" (Some 132) (List.hd hits).uncapped_chars

let uncapped_chars_reach_the_boundary_not_the_wire () =
  (* Python hangs this on [Result._uncapped_chars], private so it cannot reach
     the wire. Here it rides beside the result, and the wire model has no field
     for it — so the JSON the engine serialises must not name it either. *)
  let hits = parse sample_json in
  check_opt_int "recorded" (Some 132) (List.hd hits).uncapped_chars;
  check_bool "absent from the wire model" false
    (contains (Yojson.Safe.to_string (Model.result_to_yojson (List.hd hits).result))
       "uncapped")

let published_at_is_the_date () =
  check_opt "the declared date" (Some "2024-10-04")
    (List.hd (parse sample_json)).result.published_date

let crawled_at_stands_in_when_published_at_is_missing () =
  (* Their docs say the declared date is missing for many pages, and the crawl
     date is the honest stand-in. *)
  check_opt "the crawl date" (Some "2026-06-30")
    (List.nth (parse sample_json) 1).result.published_date

let a_falsy_published_at_falls_through_to_crawled_at () =
  List.iter
    (fun (what, value) ->
      let hits =
        parse
          (payload
             [
               record
                 [
                   ("published_at", value); ("crawled_at", `String "2026-01-02");
                 ];
             ])
      in
      check_opt what (Some "2026-01-02") (List.hd hits).result.published_date)
    [ ("null", `Null); ("empty", `String ""); ("zero", `Int 0) ]

let no_date_is_invented_when_neither_is_present () =
  check_opt "no date" None (List.hd (parse (payload [ record [] ]))).result.published_date

let the_score_passes_through_as_is () =
  (* Their BM25 x trust number, not a normalised relevance: nothing downstream
     compares scores across providers, so there is nothing to rescale. *)
  let hits = parse sample_json in
  check_opt_number "the first" (Some 949.36) (List.hd hits).result.score;
  check_opt_number "the second" (Some 812.5) (List.nth hits 1).result.score

let a_non_numeric_score_is_dropped () =
  List.iter
    (fun (what, value) ->
      check_opt_number what None
        (List.hd (parse (payload [ record [ ("score", value) ] ]))).result.score)
    [
      ("a numeric string", `String "949.36");
      ("an object", `Assoc [ ("value", `Int 1) ]);
      ("a list", `List [ `Int 1 ]);
      (* [true] is not the number a [score] claims to be. *)
      ("a bool", `Bool true);
      ("null", `Null);
    ]

let records_without_a_url_or_title_are_dropped () =
  let drop items = List.length (parse (`Assoc [ ("results", `List items) ])) in
  check_int "no url" 0 (drop [ `Assoc [ ("title", `String "t") ] ]);
  check_int "no title" 0 (drop [ `Assoc [ ("url", `String "https://example.com") ] ]);
  (* Present but empty is the same drop: an empty title is no title. *)
  check_int "an empty url" 0 (drop [ `Assoc [ ("url", `String ""); ("title", `String "t") ] ]);
  check_int "an empty title" 0
    (drop [ `Assoc [ ("url", `String "https://e.com"); ("title", `String "") ] ])

let a_record_that_is_not_an_object_is_skipped () =
  let hits =
    parse
      (payload [ `String "nonsense"; record [] ])
  in
  check_int "the string is dropped, the object survives" 1 (List.length hits)

let missing_results_is_empty_not_an_error () =
  check_int "results is null" 0 (List.length (parse (`Assoc [ ("results", `Null) ])));
  check_int "results is absent" 0 (List.length (parse (`Assoc [])));
  check_int "results is not a list" 0
    (List.length (parse (`Assoc [ ("results", `Assoc [ ("0", `String "x") ]) ])))

let the_cross_promotion_block_is_ignored () =
  (* [related_apis] advertises the operator's other services. It is a promotion,
     not a result source: the mapping reads [results[]] and nothing else, so a
     body with the block and one without parse identically. *)
  check_bool "the fixture carries it" true (contains sample "related_apis");
  let without =
    `Assoc
      (List.filter (fun (key, _) -> key <> "related_apis")
         (Option.get (Provider.Json.members sample_json)))
  in
  check_string "identical parses" (hits_json (parse sample_json)) (hits_json (parse without))

(* {1 The substituted index}

   [engine_fallback: true] is a refusal, not a caveat: when their web engine
   does not answer, [index=web] is served site profiles rather than search
   results, and the wire shape has no field that could carry the substitution. *)

let a_healthy_fixture_does_not_carry_the_key () =
  check_bool "absent, which is the healthy shape" true
    (Provider.Json.field "engine_fallback" sample_json = `Null)

let the_substituted_index_fails_the_search () =
  let body =
    Yojson.Safe.to_string
      (`Assoc
         (Option.get (Provider.Json.members sample_json) @ [
            ("index", `String "sites");
            ("engine_fallback", `Bool true);
            ("engine_error", `String "engine_unavailable");
            ("requested_index", `String "web");
          ]))
  in
  let failure = engine_fallback_refusal body (query ()) in
  check_string "the contracted sentence" "upstream index unavailable" failure.message;
  (* Transient, like the 5xx row: neither auth nor quota, and the walk may try
     the fallback again later. *)
  check_bool "retryable" true failure.retryable;
  check_bool "not a quota failure" true (failure.kind = Provider.Failure)

let the_upstream_error_text_is_not_interpolated () =
  let body =
    Yojson.Safe.to_string
      (`Assoc
         (Option.get (Provider.Json.members sample_json)
         @ [
             ("engine_fallback", `Bool true);
             ("engine_error", `String "engine_unavailable: https://internal.example/?k=secret");
           ]))
  in
  let failure = engine_fallback_refusal body (query ()) in
  check_string "the sentence is the adapter's own" "upstream index unavailable" failure.message;
  check_bool "nothing from the body rides along" false
    (contains (Provider.render_error failure) "internal.example")

let a_false_or_absent_key_maps_normally () =
  let with_false =
    Yojson.Safe.to_string
      (`Assoc
         (Option.get (Provider.Json.members sample_json)
         @ [ ("engine_fallback", `Bool false) ]))
  in
  List.iter
    (fun body ->
      let outcome, _ = search_of ~body () in
      check_int "two results" 2 (List.length outcome.results))
    [ with_false; sample ]

(* {1 The request} *)

let get_to_the_web_index_self_identifying () =
  let _, request = search_of ~query:(query ~text:"wal mode" ~max_results:3 ()) () in
  check_bool "the method" true (request.meth = `GET);
  check_string "the path" "/api.php" (Uri.path request.uri);
  check_string "the host" "freeserp.ai" (Option.get (Uri.host request.uri));
  check_string "the scheme" "https" (Option.get (Uri.scheme request.uri));
  check_opt "the web index, not the sites default" (Some "web") (param request "index");
  check_opt "the query" (Some "wal mode") (param request "q");
  check_opt "the size follows max_results" (Some "3") (param request "size");
  (* The operator asks callers to say who they are; nothing validates it, which
     is why neither value is config. *)
  check_opt "the agent" (Some Freeserp.agent) (param request "agent");
  check_opt "the website" (Some Provider.project_url) (param request "website")

let size_is_clamped_to_the_endpoint_ceiling () =
  (* The tool schema caps [max_results] at 20, but the adapter is callable
     directly, so the clamp lives here rather than being assumed. *)
  let _, request = search_of ~query:(query ~max_results:500 ()) () in
  check_opt "the endpoint's ceiling" (Some (string_of_int Freeserp.max_size))
    (param request "size")

let a_language_reaches_lang_lowercased () =
  (* [lang] is an ISO 639-1 code; the schema already guarantees the two-letter
     form, and this backend has no country parameter at all. *)
  let _, request = search_of ~query:(query ~language:"DE" ()) () in
  check_opt "lowercased, not split" (Some "de") (param request "lang")

let no_lang_is_sent_when_none_was_asked_for () =
  let _, request = search_of () in
  check_bool "no lang parameter" false (has_param request "lang")

let recency_reaches_published_from () =
  List.iter
    (fun (period, expected) ->
      let _, request = search_of ~query:(query ~recency:period ()) () in
      check_string
        (Printf.sprintf "%s reaches published_from" expected)
        expected
        (param request "published_from" |> Option.value ~default:"");
      (* Open-ended, like Linkup's [fromDate]: no upper bound is sent. *)
      check_bool "no published_to" false (has_param request "published_to"))
    [
      (Model.Day, "2023-11-13");
      (Model.Week, "2023-11-07");
      (Model.Month, "2023-10-15");
      (Model.Year, "2022-11-14");
    ]

let the_unhonourable_constraints_are_reported_never_guessed () =
  (* Domains, country and safe-search have no parameter here, so they are named;
     [recency] and [language] reach their own fields and are not. *)
  let outcome, request =
    search_of
      ~query:
        (query ~text:"wal mode" ~include_domains:[ "sqlite.org" ]
           ~exclude_domains:[ "spam.example" ] ~country:"de" ~language:"de"
           ~safe_search:true ())
      ()
  in
  check_string "the notice names exactly what dropped"
    "cannot filter by domain or country or safe-search; that constraint was ignored"
    (Option.get outcome.notice);
  check_opt "the language did ride the wire" (Some "de") (param request "lang");
  List.iter
    (fun name ->
      check_bool (Printf.sprintf "no %s parameter" name) false (has_param request name))
    [
      "site"; "include_domains"; "exclude_domains"; "country"; "gl"; "safe_search";
      "safety"; "safe"; "published_to"; "total";
    ];
  (* No [site:] operator either: a backend with a native filter field never
     folds the domain into the query, and this one has no field either. *)
  check_opt "the query is sent as asked" (Some "wal mode") (param request "q")

let safe_search_is_noticed_for_both_values () =
  (* Both values are drops: FreeSerp has no safety parameter at all. [None] is
     not a drop, which is [a_honoured_constraint_draws_no_notice]. *)
  List.iter
    (fun value ->
      let outcome, _ = search_of ~query:(query ~safe_search:value ()) () in
      check_string "the safe-search sentence"
        "cannot filter by safe-search; that constraint was ignored"
        (Option.get outcome.notice))
    [ true; false ]

let the_candidate_pool_size_is_not_a_hit_count () =
  (* [total] is the size of a top-100 pool, not a hit count — the response says
     so itself in [total_note] — and neither [ProviderResult] nor
     [SearchResponse] carries a count field, so there is nothing to map it onto.
     It is not a number on the result, and not a dropped constraint either. *)
  let outcome, _ = search_of () in
  check_int "the two records the fixture counts" 2 (List.length outcome.results);
  check_bool "not the pool size" true (List.length outcome.results <> 30);
  check_opt "no notice" None outcome.notice

let a_honoured_constraint_draws_no_notice () =
  let outcome, _ = search_of ~query:(query ~language:"de" ~recency:Model.Month ()) () in
  check_opt "nothing dropped" None outcome.notice

let the_result_reports_its_flat_zero_cost () =
  let outcome, _ = search_of ~query:(query ~max_results:5 ()) () in
  check_string "named by the adapter that served it" "freeserp" outcome.provider;
  check_opt_number "flat zero" (Some 0.) outcome.cost_usd;
  check_opt "no answer from a SERP adapter" None outcome.answer

(* {1 The failures this adapter owns}

   The six rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is this adapter's quota statuses,
   its own wording, and the leak regression that proves the redaction rule for
   the place its credentials would ride. *)

let payment_and_rate_limit_are_quota () =
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:{|{"results": []}|} () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_bool "the quota kind" true (failure.kind = Provider.Quota);
          check_bool "a spent quota is not transient" false failure.retryable)
    [ 402; 429 ]

let rejected_authentication_is_the_auth_row () =
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:{|{"results": []}|} () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string "the contracted sentence" "authentication rejected (check API key)"
            failure.message;
          check_bool "not retryable" false failure.retryable)
    [ 401; 403 ]

let the_status_row_carries_only_the_code () =
  (* 502 is the documented upstream failure and the transient one of the pair. *)
  let provider, _ = dial ~status:502 ~body:"<!doctype html>an upstream error page</html>" () in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "HTTP 502 was accepted"
  | Error failure ->
      check_string "the code is the whole payload" "HTTP 502" failure.message;
      check_bool "the body is not quoted" false
        (contains (Provider.render_error failure) "error page")

let a_network_failure_does_not_echo_the_request () =
  (* The message must not carry the underlying failure: httpx errors echo the
     request, and the request here names this deployment and its query. *)
  let provider =
    refusal Caps.Error.Denied
      ~message:"connection refused to /api.php?agent=seekwright&website=secret-marker"
  in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "a refused grant was accepted"
  | Error failure ->
      check_string "the network row" "network error" failure.message;
      check_bool "nothing about the request rides along" false
        (contains (Provider.render_error failure) "secret-marker")

let the_grants_bound_is_the_timeout_row () =
  let provider = refusal Caps.Error.Timeout ~message:"operation bound of 10s exceeded" in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "a timed-out grant was accepted"
  | Error failure ->
      check_string "the timeout row" "request timed out" failure.message;
      check_bool "transient, so the walk may retry" true failure.retryable

let a_body_that_is_not_json_is_malformed () =
  List.iter
    (fun (what, body) ->
      let provider, _ = dial ~body () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "%s was accepted as a response" what
      | Error failure -> check_string what "malformed JSON response" failure.message)
    [ ("an HTML page", "<html>nope</html>"); ("an empty body", ""); ("an array", "[]") ]

(* {1 Cost} *)

let it_cannot_bill () =
  let provider, _ = dial () in
  check_number "the reporting figure" 0. (Provider.cost_per_1k provider);
  check_number "flat, whatever the caller asks for" 0. (Provider.cost_for provider 1);
  check_number "the same at the schema ceiling" 0. (Provider.cost_for provider 20)

let an_operator_corrected_cost_reaches_the_adapter () =
  (* Reporting only, but an operator may want a figure they recognise. The
     Python row's [default_cost] in [factory._PROVIDERS] is the figure that
     takes effect there, so the two move together (P5). *)
  let provider, _ = dial ~cost_per_1k:0.25 () in
  check_number "the corrected figure" 0.25 (Provider.cost_per_1k provider);
  check_number "and its per-query reading" 0.00025 (Provider.cost_for provider 5)

let the_endpoint_is_the_one_the_grant_allows () =
  (* The URL the adapter dials and the entry the factory must allowlist are one
     fact: the adapter sends [https] to [freeserp.ai] on the default port, which
     is what the policy row says. *)
  check_string "the endpoint" "https://freeserp.ai/api.php" (Uri.to_string Freeserp.endpoint);
  check_string "the policy host" "freeserp.ai" Freeserp.policy_endpoint.Caps.Policy.host;
  check_bool "https" true (Freeserp.policy_endpoint.Caps.Policy.scheme = `Https);
  check_bool "the default port" true (Freeserp.policy_endpoint.Caps.Policy.port = None);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.uri = Some Freeserp.policy_endpoint.Caps.Policy.host)

let () =
  A.
    (run "seekwright/freeserp"
       [
         ( "parsing",
             [
               test_case "the live fixture yields both records" `Quick the_fixture_yields_both_records;
               test_case "the limit is honoured" `Quick the_limit_is_honoured;
               test_case "a SERP record fills snippet and never text" `Quick
                 a_serp_record_fills_snippet_and_never_text;
               test_case "the snippet cap clips and measures" `Quick the_snippet_cap_clips_and_measures;
               test_case "the cap measurement stops at the boundary" `Quick
                 uncapped_chars_reach_the_boundary_not_the_wire;
               test_case "published_at is the date" `Quick published_at_is_the_date;
               test_case "crawled_at stands in when published_at is missing" `Quick
                 crawled_at_stands_in_when_published_at_is_missing;
               test_case "a falsy published_at falls through to crawled_at" `Quick
                 a_falsy_published_at_falls_through_to_crawled_at;
               test_case "no date is invented when neither is present" `Quick
                 no_date_is_invented_when_neither_is_present;
               test_case "the score passes through as-is" `Quick the_score_passes_through_as_is;
               test_case "a non-numeric score is dropped" `Quick a_non_numeric_score_is_dropped;
               test_case "records without a url or title are dropped" `Quick
                 records_without_a_url_or_title_are_dropped;
               test_case "a record that is not an object is skipped" `Quick
                 a_record_that_is_not_an_object_is_skipped;
               test_case "missing results is empty, not an error" `Quick
                 missing_results_is_empty_not_an_error;
               test_case "the cross-promotion block is ignored" `Quick
                 the_cross_promotion_block_is_ignored;
             ] );
         ( "the substituted index",
             [
               test_case "a healthy fixture does not carry the key" `Quick
                 a_healthy_fixture_does_not_carry_the_key;
               test_case "the substituted index fails the search" `Quick
                 the_substituted_index_fails_the_search;
               test_case "the upstream error text is not interpolated" `Quick
                 the_upstream_error_text_is_not_interpolated;
               test_case "a false or absent key maps normally" `Quick a_false_or_absent_key_maps_normally;
             ] );
         ( "the request",
             [
               test_case "GET to the web index, self-identifying" `Quick
                 get_to_the_web_index_self_identifying;
               test_case "size is clamped to the endpoint ceiling" `Quick
                 size_is_clamped_to_the_endpoint_ceiling;
               test_case "a language reaches lang lowercased" `Quick a_language_reaches_lang_lowercased;
               test_case "no lang is sent when none was asked for" `Quick
                 no_lang_is_sent_when_none_was_asked_for;
               test_case "recency reaches published_from, and only that" `Quick
                 recency_reaches_published_from;
               test_case "the unhonourable constraints are reported, never guessed" `Quick
                 the_unhonourable_constraints_are_reported_never_guessed;
               test_case "safe-search is noticed for both values" `Quick
                 safe_search_is_noticed_for_both_values;
               test_case "the candidate pool size is not a hit count" `Quick
                 the_candidate_pool_size_is_not_a_hit_count;
               test_case "a honoured constraint draws no notice" `Quick
                 a_honoured_constraint_draws_no_notice;
               test_case "the result reports its flat zero cost" `Quick
                 the_result_reports_its_flat_zero_cost;
             ] );
         ( "the failures this adapter owns",
             [
               test_case "payment and rate limit are quota" `Quick payment_and_rate_limit_are_quota;
               test_case "rejected authentication is the auth row" `Quick
                 rejected_authentication_is_the_auth_row;
               test_case "the status row carries only the code" `Quick
                 the_status_row_carries_only_the_code;
               test_case "a network failure does not echo the request" `Quick
                 a_network_failure_does_not_echo_the_request;
               test_case "the grant's bound is the timeout row" `Quick
                 the_grants_bound_is_the_timeout_row;
               test_case "a body that is not JSON is malformed" `Quick
                 a_body_that_is_not_json_is_malformed;
             ] );
         ( "cost and endpoint",
             [
               test_case "it cannot bill" `Quick it_cannot_bill;
               test_case "an operator-corrected cost reaches the adapter" `Quick
                 an_operator_corrected_cost_reaches_the_adapter;
               test_case "the endpoint is the one the grant allows" `Quick
                 the_endpoint_is_the_one_the_grant_allows;
             ] );
       ])
