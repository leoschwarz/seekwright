(* TinyFish: the keyed aggregator whose search costs nothing, the comma-joined
   domain lists, and the result cap that lives only in the parse.

   Every constraint but safety has a native parameter here — [include_domains]
   and [exclude_domains] as comma-separated lists, [recency_minutes] as a window,
   [location] and [language] — so a fully constrained query draws no notice, and
   the missing safe-search parameter is the whole of what one can say.

   The result count is the odd one out in a different direction: there is {i} no
   count parameter upstream at all, so the slice in the parse is the only place
   [max_results] takes effect. The request the adapter sends is the same one
   whether the caller asked for two results or twenty, which is what the pin on
   the URL asserts: the promise is made by the parse, not by the wire.

   The wiring cases from that suite belong to the registry and config suites: an
   adapter never decides whether it is enabled. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Tinyfish = Seekwright_providers.Tinyfish
module A = Alcotest
open Test_support
open Adapter_support

(* The documented shape: [results[]] with [position], [site_name], [title],
   [snippet], [url] and [date]. The first two are the envelope the adapter drops:
   nothing in the surface carries a rank, and the site name is a fact the url
   already states. *)
let sample =
  {|{
  "results": [
    {
      "position": 1,
      "site_name": "sqlite.org",
      "title": "Write-Ahead Logging",
      "url": "https://www.sqlite.org/wal.html",
      "snippet": "The default method by which SQLite implements atomic commit is a rollback journal.",
      "date": "2024-11-03"
    },
    {
      "position": 2,
      "site_name": "example.com",
      "title": "SQLite WAL mode explained",
      "url": "https://example.com/wal-explained",
      "snippet": "WAL allows readers and one writer to proceed concurrently."
    }
  ]
}|}

let sample_json = json_object sample

(* The row's price rule lives in the factory, so the suite injects one: a Search API request draws
   nothing from the wallet, so the injected price is zero. *)
let dial ?(status = 200) ?(body = sample) ?(snippet_chars = 500) () =
  let net, sent = answered ~status ~body in
  (Tinyfish.make ~cost_for:(published_price 0.) ~snippet_chars ~key:test_key ~net (), sent)

let refusal kind ~message =
  Tinyfish.make ~cost_for:(published_price 0.) ~key:test_key ~net:(refusing kind ~message) ()

let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?(query = query ()) () =
  let provider, sent = dial ~status ~body ~snippet_chars () in
  drive provider sent query

let parse ?(snippet_chars = 500) ?(limit = 10) data = Tinyfish.parse ~snippet_chars data ~limit

let record fields =
  `Assoc (("title", `String "t") :: ("url", `String "https://example.com/a") :: fields)

let results items = `Assoc [ ("results", `List items) ]

let five_results =
  `Assoc
    [
      ( "results",
        `List (List.init 5 (fun n -> record [ ("snippet", `String (Printf.sprintf "hit %d" n)) ]))
      );
    ]

let the_fixture_yields_both_records () =
  let hits = parse sample_json in
  check_int "two results" 2 (List.length hits);
  check_string "the title" "Write-Ahead Logging" (List.hd hits).result.title;
  check_string "the url" "https://www.sqlite.org/wal.html" (List.hd hits).result.url;
  check_string "the second url" "https://example.com/wal-explained" (List.nth hits 1).result.url

let the_limit_is_honoured_in_the_parse () =
  check_int "one of two" 1 (List.length (parse ~limit:1 sample_json));
  check_int "two of five" 2 (List.length (parse ~limit:2 five_results))

let a_serp_record_fills_snippet_and_never_text () =
  let hits = parse sample_json in
  check_bool "the snippet is kept" true ((List.hd hits).result.snippet <> None);
  check_opt_string "text is never filled" None (List.hd hits).result.text

let the_snippet_is_capped_and_the_pre_cap_length_measured () =
  let long = "word word word word word word word word" in
  let hits = parse ~snippet_chars:20 (results [ record [ ("snippet", `String long) ] ]) in
  let hit = List.hd hits in
  check_opt_string "the clip keeps the head and marks the cut" (Some "word word word word…")
    hit.result.snippet;
  check_opt_int "the pre-cap length rides beside the result"
    (Some (String.length long))
    hit.uncapped_chars

let the_date_is_kept_only_when_a_string () =
  let hits = parse sample_json in
  check_opt_string "the declared date" (Some "2024-11-03") (List.hd hits).result.published_date;
  check_opt_string "the record without one" None (List.nth hits 1).result.published_date;
  let hits = parse (results [ record [ ("date", `Int 20241103) ] ]) in
  check_opt_string "a number where a date was documented" None (List.hd hits).result.published_date

let records_without_a_url_are_dropped () =
  check_int "no url" 0
    (List.length
       (parse (`Assoc [ ("results", `List [ `Assoc [ ("title", `String "No url here") ] ]) ])))

let records_without_a_title_are_dropped () =
  check_int "no title" 0
    (List.length (parse (results [ `Assoc [ ("url", `String "https://example.com") ] ])))

let a_record_that_is_not_an_object_is_skipped () =
  check_int "the string is dropped, the object survives" 1
    (List.length (parse (results [ `String "nonsense"; record [] ])))

let missing_results_is_empty_not_an_error () =
  check_int "results is null" 0 (List.length (parse (`Assoc [ ("results", `Null) ])));
  check_int "results is absent" 0 (List.length (parse (`Assoc [])))

let non_strings =
  [
    ("a nested object", `Assoc [ ("nested", `String "object") ]);
    ("a list", `List [ `String "a"; `String "b" ]);
    ("a number", `Int 7);
  ]

let a_non_string_snippet_is_dropped_and_the_call_succeeds () =
  (* [snippet] goes through the shared truncate helper, which split on whitespace
     in whatever upstream sent: an [AttributeError] there escaped the engine's
     provider-error handling as an internal error. *)
  List.iter
    (fun (what, value) ->
      let body = Yojson.Safe.to_string (results [ record [ ("snippet", value) ] ]) in
      let outcome, _ = search_of ~body ~query:(query ~max_results:1 ()) () in
      check_int
        (Printf.sprintf "the call succeeded through %s" what)
        1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.snippet)
    non_strings

let a_string_snippet_still_reaches_the_model () =
  (* The guard must not change behaviour for a well-formed payload. *)
  let outcome, _ = search_of ~query:(query ~max_results:1 ()) () in
  check_opt_string "the snippet"
    (Some "The default method by which SQLite implements atomic commit is a rollback journal.")
    (List.hd outcome.results).result.snippet

let query_param name request = Uri.get_query_param request.Caps.Authority.Net.uri name

let the_url_the_adapter_builds (request : Caps.Authority.Net.request) =
  Uri.to_string request.Caps.Authority.Net.uri

let get_to_the_endpoint_with_the_api_key_header () =
  let _, request = search_of ~query:(query ~text:"wal mode" ()) () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `GET);
  check_string "the destination, before the constraints are appended"
    (Uri.to_string Tinyfish.endpoint)
    (Uri.to_string (Uri.with_query request.Caps.Authority.Net.uri []));
  check_opt_string "the vendor's own header spelling" (Some test_key)
    (List.assoc_opt "X-API-Key" request.Caps.Authority.Net.headers);
  check_opt_string "the query goes verbatim" (Some "wal mode") (query_param "query" request)

let the_key_never_rides_the_url () =
  (* The credential is a header, so the one URL this adapter builds — which does
     carry the caller's constraints — stays free of it. *)
  let _, request = search_of ~query:(query ~country:"de" ~language:"de" ()) () in
  check_bool "no key in the URL" false
    (contains ~haystack:(the_url_the_adapter_builds request) ~needle:test_key);
  check_opt_string "and no key parameter either" None (query_param "api_key" request)

let the_domain_lists_are_comma_joined () =
  (* One parameter each, values joined: the endpoint documents a comma-separated
     list, not a repeated parameter. *)
  let _, request =
    search_of
      ~query:
        (query ~include_domains:[ "sqlite.org"; "docs.rs" ] ~exclude_domains:[ "spam.example" ] ())
      ()
  in
  check_opt_string "the include list is joined" (Some "sqlite.org,docs.rs")
    (query_param "include_domains" request);
  check_opt_string "the exclude list is joined" (Some "spam.example")
    (query_param "exclude_domains" request);
  check_opt_string "and the query itself stays verbatim" (Some "q") (query_param "query" request)

let domain_params_absent_without_filters () =
  let _, request = search_of () in
  check_opt_string "no include_domains" None (query_param "include_domains" request);
  check_opt_string "no exclude_domains" None (query_param "exclude_domains" request)

let recency_maps_onto_recency_minutes () =
  List.iter
    (fun (period, minutes) ->
      let _, request = search_of ~query:(query ~recency:period ()) () in
      check_opt_string
        (Printf.sprintf "a %s window" (string_of_int minutes))
        (Some (string_of_int minutes))
        (query_param "recency_minutes" request))
    [ (Model.Day, 1440); (Model.Week, 10080); (Model.Month, 43200); (Model.Year, 525600) ];
  let _, request = search_of () in
  check_opt_string "unasked, no window at all" None (query_param "recency_minutes" request)

let the_recency_windows_are_the_fixed_day_counts () =
  (* Fixed 30-day months and 365-day years, so the window is a count of minutes
     upstream and no clock is involved — unlike [linkup]'s [fromDate], which is a
     timestamp and does take one. *)
  check_int "a day" 1440 (Tinyfish.recency_minutes Model.Day);
  check_int "a week" 10080 (Tinyfish.recency_minutes Model.Week);
  check_int "a month of thirty days" 43200 (Tinyfish.recency_minutes Model.Month);
  check_int "a year of three hundred and sixty five days" 525600
    (Tinyfish.recency_minutes Model.Year)

let geo_maps_onto_location_and_language () =
  let _, request = search_of ~query:(query ~country:"de" ~language:"DE" ()) () in
  check_opt_string "the documented examples are uppercase codes" (Some "DE")
    (query_param "location" request);
  check_opt_string "and the language is lowercased" (Some "de") (query_param "language" request);
  let _, request = search_of () in
  check_opt_string "neither is sent unasked" None (query_param "location" request);
  check_opt_string "not even the language" None (query_param "language" request)

let no_result_count_is_ever_sent () =
  (* The acceptance row this whole file turns on: no count parameter upstream, so
     the request is identical at two results and at twenty, and only the parse
     differs. A [max_results] on the wire would promise a cap the endpoint does
     not implement. *)
  let _, narrow = search_of ~query:(query ~max_results:2 ()) () in
  let _, wide = search_of ~query:(query ~max_results:20 ()) () in
  check_string "the URL does not move with max_results"
    (the_url_the_adapter_builds narrow)
    (the_url_the_adapter_builds wide);
  check_opt_string "no max_results parameter" None (query_param "max_results" wide);
  check_opt_string "no num parameter" None (query_param "num" wide);
  check_opt_string "no limit parameter" None (query_param "limit" wide)

let no_safe_search_parameter_is_ever_sent () =
  List.iter
    (fun value ->
      let _, request = search_of ~query:(query ~safe_search:value ()) () in
      check_opt_string "no safe" None (query_param "safe" request);
      check_opt_string "no safe_search" None (query_param "safe_search" request))
    [ true; false ]

let safe_search_is_the_one_drop_it_notices () =
  List.iter
    (fun value ->
      let outcome, _ = search_of ~query:(query ~safe_search:value ()) () in
      check_string "the safe-search sentence"
        "cannot filter by safe-search; that constraint was ignored" (Option.get outcome.notice))
    [ true; false ]

let an_unconstrained_query_carries_no_notice () =
  let outcome, _ = search_of () in
  check_opt_string "nothing dropped" None outcome.notice

let every_other_constraint_is_honoured () =
  (* Domain lists, [recency_minutes], [location] and [language] are all native, so
     a query that sets all four and asks for no safety filter is answered with no
     notice at all. *)
  let outcome, _ =
    search_of
      ~query:
        (query ~include_domains:[ "sqlite.org" ] ~country:"de" ~language:"de" ~recency:Model.Month
           ())
      ()
  in
  check_opt_string "no notice" None outcome.notice

(* The six rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is this adapter's quota pair, and
   the fact that its 402 means something different from [linkup]'s. *)

let no_search_access_and_the_rate_limit_are_quota () =
  (* 402 here reads "Search API access is required for your account": an account
     question, not a malformed request, so it rides the quota row next to 429 and
     moves the fallback walk off this name. *)
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:sample () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string "the sentence names the account question"
            "rate limited or no Search API access on this account" failure.message;
          check_bool "the quota kind" true (failure.kind = Provider.Quota);
          check_bool "a spent account is not transient" false failure.retryable)
    [ 402; 429 ]

let a_body_that_quotes_the_key_is_not_echoed () =
  let body = Printf.sprintf "<html>upstream echoed %s on an access page</html>" test_key in
  let provider, _ = dial ~status:402 ~body () in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "HTTP 402 was accepted"
  | Error failure ->
      check_bool "the vendor's page is not quoted" false
        (contains ~haystack:(Provider.render_error failure) ~needle:test_key)

let a_network_failure_does_not_echo_the_request () =
  let provider = refusal Caps.Error.Denied ~message:"connection refused to X-API-Key: test-key" in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "a refused grant was accepted"
  | Error failure ->
      check_string "the network row" "network error" failure.message;
      check_bool "nothing about the request rides along" false
        (contains ~haystack:(Provider.render_error failure) ~needle:test_key)

let the_result_carries_the_zero () =
  let outcome, _ = search_of ~query:(query ~max_results:20 ()) () in
  check_string "named by the adapter that served it" "tinyfish" outcome.provider;
  check_opt_number "free, and reported as free" (Some 0.0) outcome.cost_usd

let the_adapter_dials_the_endpoint_it_declares () =
  check_string "the endpoint" "https://api.search.tinyfish.ai" (Uri.to_string Tinyfish.endpoint);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.Caps.Authority.Net.uri = Uri.host Tinyfish.endpoint)

let () =
  A.(
    run "seekwright/tinyfish"
      [
        ( "parsing",
          [
            test_case "the live fixture yields both records" `Quick the_fixture_yields_both_records;
            test_case "the limit is honoured in the parse" `Quick the_limit_is_honoured_in_the_parse;
            test_case "a SERP record fills snippet and never text" `Quick
              a_serp_record_fills_snippet_and_never_text;
            test_case "the snippet is capped and the pre-cap length measured" `Quick
              the_snippet_is_capped_and_the_pre_cap_length_measured;
            test_case "the date is kept only when a string" `Quick
              the_date_is_kept_only_when_a_string;
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
            test_case "a non-string snippet is dropped and the call succeeds" `Quick
              a_non_string_snippet_is_dropped_and_the_call_succeeds;
            test_case "a string snippet still reaches the model" `Quick
              a_string_snippet_still_reaches_the_model;
          ] );
        ( "the request",
          [
            test_case "GET to the endpoint, key in the X-API-Key header" `Quick
              get_to_the_endpoint_with_the_api_key_header;
            test_case "the key never rides the URL" `Quick the_key_never_rides_the_url;
            test_case "the domain lists are comma-joined" `Quick the_domain_lists_are_comma_joined;
            test_case "domain params absent without filters" `Quick
              domain_params_absent_without_filters;
            test_case "recency maps onto recency_minutes" `Quick recency_maps_onto_recency_minutes;
            test_case "the recency windows are the fixed day counts" `Quick
              the_recency_windows_are_the_fixed_day_counts;
            test_case "geo maps onto location and language" `Quick
              geo_maps_onto_location_and_language;
            test_case "no result count is ever sent" `Quick no_result_count_is_ever_sent;
            test_case "no safe-search parameter is ever sent" `Quick
              no_safe_search_parameter_is_ever_sent;
          ] );
        ( "the constraint report",
          [
            test_case "safe-search is the one drop it notices" `Quick
              safe_search_is_the_one_drop_it_notices;
            test_case "an unconstrained query carries no notice" `Quick
              an_unconstrained_query_carries_no_notice;
            test_case "every other constraint is honoured" `Quick every_other_constraint_is_honoured;
          ] );
        ( "the failures this adapter owns",
          [
            test_case "no search access and the rate limit are quota" `Quick
              no_search_access_and_the_rate_limit_are_quota;
            test_case "the body behind the payment status is not echoed" `Quick
              a_body_that_quotes_the_key_is_not_echoed;
            test_case "a network failure does not echo the request" `Quick
              a_network_failure_does_not_echo_the_request;
          ] );
        ( "cost and endpoint",
          [
            test_case "the result carries the zero" `Quick the_result_carries_the_zero;
            test_case "the adapter dials the endpoint it declares" `Quick
              the_adapter_dials_the_endpoint_it_declares;
          ] );
      ])
