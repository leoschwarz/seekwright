(* SearXNG: response parsing, the paging walk, request shape and cost.

   Port of tests/providers/test_searxng.py. The fixture is the documented
   JSON-API payload (see docs/reference/providers.md), and the request-shape
   cases drive the adapter through a fake {!Seekwright.Provider.Net.t} — the
   position [httpx.MockTransport] holds in Python, and possible here for the
   same reason: the client is injected. Paging needs more than one canned
   answer, so [dial_pages] hands the grant a handler that reads the [pageno]
   parameter the adapter sent.

   The wiring cases from that suite ([test_built_when_a_url_is_configured],
   [test_enabled_without_a_url_is_a_config_error]) belong to the registry and
   config suites: an adapter never decides whether it is enabled, and the
   instance URL reaches it as the [endpoint] argument the row resolves. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Searxng = Seekwright_providers.Searxng
module A = Alcotest
open Test_support

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

(* The instance under test: a private host on a port, so the [search_uri] case
   pins the path join against a URL an operator would actually write. *)
let instance = Uri.of_string "http://searx.internal:8080"

(* {1 The fixture}

   The JSON-API payload: [results[]] with the fields the mapping reads, and the
   [infoboxes] and [unresponsive_engines] blocks it never touches. *)
let sample =
  {|{
  "query": "wal mode",
  "results": [
    {
      "title": "Write-Ahead Logging",
      "url": "https://www.sqlite.org/wal.html",
      "content": "The default method by which SQLite implements atomic commit is a rollback journal.",
      "engines": ["google", "bing"],
      "score": 12.5,
      "publishedDate": "2024-11-03T00:00:00Z"
    },
    {
      "title": "SQLite WAL mode explained",
      "url": "https://example.com/wal-explained",
      "content": "WAL allows readers and one writer to proceed concurrently.",
      "engines": ["startpage"],
      "score": 8
    }
  ],
  "infoboxes": [],
  "unresponsive_engines": []
}|}

let sample_json =
  match Yojson.Safe.from_string sample with
  | `Assoc _ as json -> json
  | _ -> A.failf "the fixture is not an object"

(* [n] minimal well-formed results, distinct so slicing is observable. *)
let n_results n =
  `Assoc
    [
      ( "results"
      , `List
          (List.init n (fun i ->
               `Assoc
                 [
                   ("title", `String (Printf.sprintf "hit %d" i));
                   ("url", `String (Printf.sprintf "https://example.com/%d" i));
                   ("content", `String (Printf.sprintf "content %d" i));
                 ])) );
    ]

(* {1 The seam}

   A {!Seekwright.Provider.Net.t} that records every request it was handed —
   paging is observable through the [pageno] the adapter sent — and answers
   with what the case's handler decides. *)
let dial_pages ?(snippet_chars = 500) ?cost_per_1k ?(instance = instance) ~handler () =
  let sent = ref [] in
  let net =
    {
      Provider.Net.request =
        (fun request ->
          sent := request :: !sent;
          Ok (handler request));
    }
  in
  let provider =
    Searxng.make ?cost_per_1k ~snippet_chars ~endpoint:instance ~net ()
  in
  (provider, fun () -> List.rev !sent)

let answering ?(status = 200) ?(body = sample) () =
  { Caps.Authority.Net.status; headers = []; body }

let dial ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k () =
  dial_pages ~snippet_chars ?cost_per_1k ~handler:(fun _ -> answering ~status ~body ()) ()

let refusal kind ~message =
  let net =
    {
      Provider.Net.request =
        (fun _ -> Error (Caps.Error.make kind ~message));
    }
  in
  Searxng.make ~endpoint:instance ~net ()

let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k
    ?(query = query ()) () =
  let provider, sent = dial ~status ~body ~snippet_chars ?cost_per_1k () in
  match Provider.search provider query with
  | Ok outcome -> (outcome, List.hd (sent ()))
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

let search_pages_of ?(handler = fun _ -> answering ()) ?(query = query ()) () =
  let provider, sent = dial_pages ~handler () in
  match Provider.search provider query with
  | Ok outcome -> (outcome, sent ())
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

let params (request : Caps.Authority.Net.request) = Uri.query request.uri

let param (request : Caps.Authority.Net.request) name =
  Uri.get_query_param request.uri name

let has_param request name =
  List.exists (fun (key, _) -> key = name) (params request)

(* {1 Parsing} *)

let parse ?(snippet_chars = 500) ?(limit = 10) data = Searxng.parse ~snippet_chars data ~limit

let record fields =
  `Assoc (("title", `String "t") :: ("url", `String "https://example.com/a") :: fields)

let results items = `Assoc [ ("results", `List items) ]

let the_fixture_yields_both_records () =
  let hits = parse sample_json in
  check_int "two results" 2 (List.length hits);
  check_string "the title" "Write-Ahead Logging" (List.hd hits).result.title;
  check_string "the url" "https://www.sqlite.org/wal.html" (List.hd hits).result.url;
  check_string "the second url" "https://example.com/wal-explained"
    (List.nth hits 1).result.url

let the_limit_is_honoured () =
  check_int "one of two" 1 (List.length (parse ~limit:1 sample_json))

let content_becomes_the_snippet () =
  let hits = parse sample_json in
  check_bool "the content became a snippet" true ((List.hd hits).result.snippet <> None);
  check_opt_string "text is never filled" None (List.hd hits).result.text

let the_snippet_is_truncated () =
  let hits = parse ~snippet_chars:40 sample_json in
  check_int "cut at the cap plus the ellipsis" 41 (chars (Option.get (List.hd hits).result.snippet))

let the_engine_and_infobox_metadata_are_dropped () =
  let hits = parse sample_json in
  let dumped = Yojson.Safe.to_string (Model.result_to_yojson (List.hd hits).result) in
  excludes "no engines field" "engines" dumped;
  excludes "no infobox prose" "infobox" dumped

let the_score_is_kept_when_numeric () =
  let hits = parse sample_json in
  check_opt_number "the first" (Some 12.5) (List.hd hits).result.score;
  check_opt_number "the second, an integer on the wire" (Some 8.) (List.nth hits 1).result.score

let a_non_numeric_score_is_not_coerced () =
  let hits = parse (results [ record [ ("score", `Assoc [ ("weird", `Int 1) ]) ] ]) in
  check_opt_number "an object score is dropped, not stringified" None (List.hd hits).result.score

let the_published_date_is_kept_only_when_a_string () =
  let hits = parse sample_json in
  check_opt_string "the declared date" (Some "2024-11-03T00:00:00Z")
    (List.hd hits).result.published_date;
  check_opt_string "the record without one" None (List.nth hits 1).result.published_date

let records_without_a_url_are_dropped () =
  check_int "no url" 0
    (List.length (parse (`Assoc [ ("results", `List [ `Assoc [ ("title", `String "No url here") ] ]) ])))

let records_without_a_title_are_dropped () =
  check_int "no title" 0
    (List.length (parse (`Assoc [ ("results", `List [ `Assoc [ ("url", `String "https://example.com") ] ]) ])))

let a_record_that_is_not_an_object_is_skipped () =
  check_int "the string is dropped, the object survives" 1
    (List.length (parse (results [ `String "nonsense"; record [] ])))

let missing_results_is_empty_not_an_error () =
  check_int "results is null" 0 (List.length (parse (`Assoc [ ("results", `Null) ])));
  check_int "results is absent" 0 (List.length (parse (`Assoc [])))

(* {1 The upstream field guard}

   A non-string [content] is dropped, not handed to the shared truncate helper,
   which called [text.split()] on whatever upstream sent in the oracle. A
   nested object, list or number there raised inside the parse rather than as a
   provider error, so it escaped the engine's handling and surfaced as an
   internal error instead of a field the adapter dropped. *)

let non_strings =
  [
    ("a nested object", `Assoc [ ("nested", `String "object") ]);
    ("a list", `List [ `String "a"; `String "b" ]);
    ("a number", `Int 7);
  ]

let a_non_string_content_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body = Yojson.Safe.to_string (results [ record [ ("content", value) ] ]) in
      let outcome, _ = search_of ~body ~query:(query ~max_results:1 ()) () in
      check_int (Printf.sprintf "the call succeeded through %s" what) 1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.snippet)
    non_strings

let a_string_content_still_reaches_the_model () =
  (* The guard must not change behaviour for a well-formed payload. *)
  let outcome, _ = search_of ~query:(query ~max_results:1 ()) () in
  check_opt_string
    "the snippet"
    (Some
       "The default method by which SQLite implements atomic commit is a rollback journal.")
    (List.hd outcome.results).result.snippet

(* {1 The request} *)

let get_with_the_json_format_and_no_auth () =
  let _, request = search_of ~query:(query ~text:"wal mode" ~max_results:2 ()) () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `GET);
  check_string "the instance URL plus the JSON API path" "http://searx.internal:8080/search"
    (Uri.with_query request.uri [] |> Uri.to_string);
  check_opt_string "the format that makes this a JSON read" (Some "json") (param request "format");
  check_opt_string "page one" (Some "1") (param request "pageno");
  check_opt_string "the query" (Some "wal mode") (param request "q");
  (* Nothing authenticates this name: an instance has no API key for a search,
     and a header would name this client to the operator's logs. *)
  check_bool "no authorization header" true
    (List.assoc_opt "authorization" request.headers = None);
  check_bool "no x-api-key header" true (List.assoc_opt "x-api-key" request.headers = None)

let the_instance_path_is_joined_not_replaced () =
  (* [search_uri] strips one trailing slash however the operator wrote it and
     appends the JSON API's own path, so a instance mounted under a prefix
     keeps that prefix. *)
  List.iter
    (fun (written, expected) ->
      check_string (Printf.sprintf "%s reaches %s" written expected) expected
        (Uri.to_string (Searxng.search_uri (Uri.of_string written))))
    [
      ("http://host:8080/", "http://host:8080/search");
      ("http://host:8080", "http://host:8080/search");
      ("http://host:8080/searx", "http://host:8080/searx/search");
      ("http://host:8080/searx/", "http://host:8080/searx/search");
    ]

let the_recency_maps_onto_time_range () =
  let provider, sent =
    dial_pages ~handler:(fun _ -> answering ()) ()
  in
  List.iter
    (fun period ->
      ignore (Provider.search provider (query ~max_results:2 ~recency:period ())))
    [ Model.Day; Model.Week; Model.Month; Model.Year ];
  check_strings "SearXNG's own enum, in the order asked"
    [ "day"; "week"; "month"; "year" ]
    (List.map (fun request -> Option.value ~default:"(absent)" (param request "time_range")) (sent ()));
  let _, request = search_of ~query:(query ~max_results:2 ()) () in
  check_bool "unasked, no time_range" false (has_param request "time_range")

let the_language_is_passed_verbatim () =
  (* The schema's two-letter code is the form the instance documents, so there
     is nothing to map. *)
  let _, request = search_of ~query:(query ~max_results:2 ~language:"de" ()) () in
  check_opt_string "language" (Some "de") (param request "language")

let the_domain_filters_ride_in_the_query () =
  let _, request =
    search_of
      ~query:
        (query ~text:"wal" ~max_results:2 ~include_domains:[ "sqlite.org" ]
           ~exclude_domains:[ "spam.example" ] ())
      ()
  in
  let q = Option.get (param request "q") in
  includes "the include rides a site: operator" "site:sqlite.org" q;
  includes "the exclude is negated" "-site:spam.example" q

(* {1 Paging} *)

let a_small_ask_stays_a_single_request () =
  (* [max_results] within what page one delivered never pages: the common ask
     costs the instance one fan-out, not three. *)
  let outcome, sent = search_pages_of ~query:(query ~max_results:1 ()) () in
  check_int "one request" 1 (List.length sent);
  check_opt_string "page one" (Some "1") (param (List.hd sent) "pageno");
  check_int "one result" 1 (List.length outcome.results)

let it_paginates_while_the_ask_exceeds_the_pages () =
  let handler request =
    let pageno = int_of_string (Option.value ~default:"1" (param request "pageno")) in
    answering ~body:(Yojson.Safe.to_string (n_results (if pageno = 1 then 2 else 1))) ()
  in
  let outcome, sent = search_pages_of ~handler ~query:(query ~max_results:3 ()) () in
  check_strings "the pages asked for" [ "1"; "2" ]
    (List.map (fun request -> Option.value ~default:"?" (param request "pageno")) sent);
  check_int "the ask, made whole" 3 (List.length outcome.results)

let paging_stops_when_a_page_runs_dry () =
  let handler request =
    let pageno = int_of_string (Option.value ~default:"1" (param request "pageno")) in
    answering ~body:(Yojson.Safe.to_string (n_results (if pageno = 1 then 2 else 0))) ()
  in
  let outcome, sent = search_pages_of ~handler ~query:(query ~max_results:10 ()) () in
  check_strings "it did not keep asking" [ "1"; "2" ]
    (List.map (fun request -> Option.value ~default:"?" (param request "pageno")) sent);
  check_int "the two the instance had" 2 (List.length outcome.results)

let paging_is_bounded_at_three_pages () =
  (* The bound caps how much instance fan-out one search can cause, even when
     the caller asks for more than three pages hold. *)
  let handler _ = answering ~body:(Yojson.Safe.to_string (n_results 5)) () in
  let outcome, sent = search_pages_of ~handler ~query:(query ~max_results:20 ()) () in
  check_int "three requests, no more" 3 (List.length sent);
  check_int "and the fifteen they carried, not twenty" 15 (List.length outcome.results)

let a_failed_continuation_keeps_the_first_page () =
  (* A flaky or rate-limited second page must not destroy a search that already
     succeeded; returning fewer results than asked is normal SERP behaviour,
     not an error. *)
  List.iter
    (fun status ->
      let handler request =
        let pageno = int_of_string (Option.value ~default:"1" (param request "pageno")) in
        if pageno > 1 then answering ~status ~body:"{}" ()
        else answering ~body:(Yojson.Safe.to_string (n_results 2)) ()
      in
      let outcome, sent = search_pages_of ~handler ~query:(query ~max_results:10 ()) () in
      check_strings (Printf.sprintf "HTTP %d asked for two pages" status) [ "1"; "2" ]
        (List.map (fun request -> Option.value ~default:"?" (param request "pageno")) sent);
      check_int (Printf.sprintf "HTTP %d kept the first page" status) 2 (List.length outcome.results))
    [ 429; 500 ]

let the_first_page_fails_the_call () =
  (* The mirror of the case above: page one is required, so its failures decide
     the call. *)
  let provider, _ = dial ~status:500 ~body:"{}" () in
  match Provider.search provider (query ~max_results:2 ()) with
  | Ok outcome -> A.failf "a failed first page yielded %d results" (List.length outcome.results)
  | Error failure -> check_string "the status row" "HTTP 500" failure.message

(* {1 The constraint report} *)

let the_notice_names_the_country_it_cannot_honour () =
  let outcome, _ = search_of ~query:(query ~max_results:2 ~country:"de" ()) () in
  check_string "the country sentence" "cannot filter by country; that constraint was ignored"
    (Option.get outcome.notice)

let a_language_beside_a_country_is_still_honoured () =
  (* Both halves set: only the country is dropped, and only it is named. The
     joined country/language token an earlier revision emitted claimed the
     language went too, while [language] was carrying it to the instance. *)
  let outcome, request =
    search_of ~query:(query ~max_results:2 ~country:"de" ~language:"de" ()) ()
  in
  check_opt_string "the language rode the wire" (Some "de") (param request "language");
  check_string "only the country is named"
    "cannot filter by country; that constraint was ignored" (Option.get outcome.notice)

let a_language_alone_is_honoured_without_a_notice () =
  let outcome, _ = search_of ~query:(query ~max_results:2 ~language:"de" ()) () in
  check_opt_string "nothing dropped" None outcome.notice

let the_safe_search_maps_onto_safesearch () =
  (* [true] is SearXNG's strict state; its [1] (moderate) is unreachable. Both
     values are honoured exactly, so there is no partially-honoured case to word
     — the property the boolean rests on. *)
  List.iter
    (fun (value, wire) ->
      let outcome, request =
        search_of ~query:(query ~max_results:2 ~safe_search:value ()) ()
      in
      check_opt_string (Printf.sprintf "safesearch=%s" wire) (Some wire) (param request "safesearch");
      check_opt_string "and nothing was dropped" None outcome.notice)
    [ (true, "2"); (false, "0") ]

let the_safesearch_is_omitted_when_none () =
  (* [None] sends nothing, so the instance's own default stands. *)
  let _, request = search_of ~query:(query ~max_results:2 ()) () in
  check_bool "no safesearch parameter" false (has_param request "safesearch")

let a_safe_search_is_not_claimed_as_dropped () =
  (* The country still goes, and only the country is named. *)
  let outcome, _ = search_of ~query:(query ~max_results:2 ~country:"de" ~safe_search:true ()) () in
  check_string "the country sentence, once"
    "cannot filter by country; that constraint was ignored" (Option.get outcome.notice)

let no_notice_for_what_it_honours () =
  let outcome, _ =
    search_of
      ~query:
        (query ~max_results:2 ~include_domains:[ "sqlite.org" ] ~language:"de"
           ~recency:Model.Week ~safe_search:true ())
      ()
  in
  check_opt_string "nothing dropped" None outcome.notice

let the_result_reports_a_flat_zero_cost () =
  let outcome, _ = search_of ~query:(query ~max_results:2 ()) () in
  check_string "named by the adapter that served it" "searxng" outcome.provider;
  check_opt_number "a self-hosted instance bills no one" (Some 0.) outcome.cost_usd

(* {1 The failures this adapter owns}

   The six rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml — including the auth row's own wording, which this
   adapter spells out because a locked-down instance can refuse the JSON format
   specifically and the operator is the one who can enable it. What stays here
   is the quota rung and the leak regression. *)

let the_rate_limit_is_quota () =
  let provider, _ = dial ~status:429 ~body:"{}" () in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "HTTP 429 was accepted"
  | Error failure ->
      check_string "the instance's own sentence" "rate limited by the instance" failure.message;
      check_bool "the quota kind" true (failure.kind = Provider.Quota);
      check_bool "a rate limit is not retried through the same instance" false failure.retryable

let a_payment_status_falls_to_the_generic_row () =
  (* Nothing bills this transport, so a 402 is the reverse proxy sitting in
     front of the instance, not quota. 429 from the limiter is the whole quota
     row. *)
  let provider, _ = dial ~status:402 ~body:"{}" () in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "HTTP 402 was accepted"
  | Error failure ->
      check_string "the status row" "HTTP 402" failure.message;
      check_bool "not a quota failure" true (failure.kind = Provider.Failure)

let a_network_error_does_not_echo_the_request () =
  let provider =
    refusal Caps.Error.Denied ~message:"connection refused to http://searx.internal:8080/search"
  in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "a refused grant was accepted"
  | Error failure ->
      check_string "the network row" "network error" failure.message;
      check_bool "the instance is not named in the failure" false
        (contains ~haystack:(Provider.render_error failure) ~needle:"searx.internal")

(* {1 Cost and the instance} *)

let the_cost_is_flat_zero () =
  let provider, _ = dial () in
  check_number "one page" 0. (Provider.cost_for provider 1);
  check_number "and a full ask" 0. (Provider.cost_for provider 20)

let config_can_correct_the_figure_but_zero_is_the_default () =
  let provider, _ = dial ~cost_per_1k:5.0 () in
  check_number "a metered instance can be priced by the operator" 0.005
    (Provider.cost_for provider 1)

let the_endpoint_is_the_instance_the_grant_allows () =
  (* This name has no fixed host: the destination is the config value, read once
     by the registry and handed here as [endpoint], so the adapter dials the
     very instance it was built from — scheme, port and any mount prefix. *)
  let provider, sent =
    dial_pages ~instance:(Uri.of_string "http://searx.internal:8888/mirror")
      ~handler:(fun _ -> answering ()) ()
  in
  ignore (Provider.search provider (query ~max_results:1 ()));
  let request = List.hd (sent ()) in
  check_string "the dialed URI is the instance's search path"
    "http://searx.internal:8888/mirror/search"
    (Uri.with_query request.uri [] |> Uri.to_string);
  check_string "the scheme is the instance's" "http" (Option.get (Uri.scheme request.uri));
  check_string "the port is the instance's" "8888"
    (string_of_int (Option.value ~default:0 (Uri.port request.uri)))

let () =
  A.
    (run "seekwright/searxng"
       [
         ( "parsing",
             [
               test_case "the live fixture yields both records" `Quick the_fixture_yields_both_records;
               test_case "the limit is honoured" `Quick the_limit_is_honoured;
               test_case "content becomes the snippet" `Quick content_becomes_the_snippet;
               test_case "the snippet is truncated" `Quick the_snippet_is_truncated;
               test_case "the engine and infobox metadata are dropped" `Quick
                 the_engine_and_infobox_metadata_are_dropped;
               test_case "the score is kept when numeric" `Quick the_score_is_kept_when_numeric;
               test_case "a non-numeric score is not coerced" `Quick a_non_numeric_score_is_not_coerced;
               test_case "the published date is kept only when a string" `Quick
                 the_published_date_is_kept_only_when_a_string;
               test_case "records without a url are dropped" `Quick records_without_a_url_are_dropped;
               test_case "records without a title are dropped" `Quick
                 records_without_a_title_are_dropped;
               test_case "a record that is not an object is skipped" `Quick
                 a_record_that_is_not_an_object_is_skipped;
               test_case "missing results is empty, not an error" `Quick
                 missing_results_is_empty_not_an_error;
             ] );
         ( "the upstream field guards",
             [
               test_case "a non-string content is dropped and the call succeeds" `Quick
                 a_non_string_content_is_dropped_and_the_call_succeeds;
               test_case "a string content still reaches the model" `Quick
                 a_string_content_still_reaches_the_model;
             ] );
         ( "the request",
             [
               test_case "GET with the JSON format and no auth" `Quick
                 get_with_the_json_format_and_no_auth;
               test_case "the instance path is joined, not replaced" `Quick
                 the_instance_path_is_joined_not_replaced;
               test_case "the recency maps onto time_range" `Quick the_recency_maps_onto_time_range;
               test_case "the language is passed verbatim" `Quick the_language_is_passed_verbatim;
               test_case "the domain filters ride in the query" `Quick
                 the_domain_filters_ride_in_the_query;
             ] );
         ( "paging",
             [
               test_case "a small ask stays a single request" `Quick
                 a_small_ask_stays_a_single_request;
               test_case "it pages while the ask exceeds the pages" `Quick
                 it_paginates_while_the_ask_exceeds_the_pages;
               test_case "paging stops when a page runs dry" `Quick paging_stops_when_a_page_runs_dry;
               test_case "paging is bounded at three pages" `Quick paging_is_bounded_at_three_pages;
               test_case "a failed continuation keeps the first page" `Quick
                 a_failed_continuation_keeps_the_first_page;
               test_case "the first page fails the call" `Quick the_first_page_fails_the_call;
             ] );
         ( "the constraint report",
             [
               test_case "the notice names the country it cannot honour" `Quick
                 the_notice_names_the_country_it_cannot_honour;
               test_case "a language beside a country is still honoured" `Quick
                 a_language_beside_a_country_is_still_honoured;
               test_case "a language alone is honoured without a notice" `Quick
                 a_language_alone_is_honoured_without_a_notice;
               test_case "the safe-search maps onto safesearch" `Quick
                 the_safe_search_maps_onto_safesearch;
               test_case "the safesearch is omitted when none" `Quick
                 the_safesearch_is_omitted_when_none;
               test_case "a safe search is not claimed as dropped" `Quick
                 a_safe_search_is_not_claimed_as_dropped;
               test_case "no notice for what it honours" `Quick no_notice_for_what_it_honours;
               test_case "the result reports a flat zero cost" `Quick
                 the_result_reports_a_flat_zero_cost;
             ] );
         ( "the failures this adapter owns",
             [
               test_case "the rate limit is quota" `Quick the_rate_limit_is_quota;
               test_case "a payment status falls to the generic row" `Quick
                 a_payment_status_falls_to_the_generic_row;
               test_case "a network error does not echo the request" `Quick
                 a_network_error_does_not_echo_the_request;
             ] );
         ( "cost and the instance",
             [
               test_case "the cost is flat zero" `Quick the_cost_is_flat_zero;
               test_case "config can correct the figure, and zero is the default" `Quick
                 config_can_correct_the_figure_but_zero_is_the_default;
               test_case "the endpoint is the instance the grant allows" `Quick
                 the_endpoint_is_the_instance_the_grant_allows;
             ] );
       ])
