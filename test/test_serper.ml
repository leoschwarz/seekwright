(* Serper: response parsing, the guard on upstream field shapes, the request
   body, and the one constraint the adapter cannot honour.

   Serper is a raw SERP backend — [organic[]] records carry a [snippet] and a
   [date], both documented as strings — but nothing upstream enforces that. A
   nested object, list or number in [date] used to reach [Result.published_date]
   unguarded in the oracle, and the same shape in [snippet] raised out of the
   shared truncate helper; neither was a provider error, so both escaped the
   engine's handling as an internal error rather than being dropped the way every
   sibling drops a non-string. [the_upstream_field_guards] pins both guards; the
   parsing cases pin that a well-formed payload is unchanged.

   The request-shape cases drive the adapter through a fake
   {!Seekwright.Provider.Net.t} — the position [httpx.MockTransport] holds in
   Python — and Serper has no safe-search parameter at all, which makes this
   adapter's [notice] the only thing standing between a caller that asked for
   filtered results and the belief that it got them.

   The wiring cases from that suite belong to the registry and config suites:
   an adapter never decides whether it is enabled. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Serper = Seekwright_providers.Serper
module A = Alcotest
open Test_support
open Adapter_support

(* The [organic[]] payload: the fields the mapping reads, and the [credits]
   counter it never touches. *)
let sample =
  {|{
  "organic": [
    {
      "title": "Write-Ahead Logging",
      "link": "https://www.sqlite.org/wal.html",
      "snippet": "The default method by which SQLite implements atomic commit is a rollback journal.",
      "date": "2024-11-03"
    },
    {
      "title": "SQLite WAL mode explained",
      "link": "https://example.com/wal-explained",
      "snippet": "WAL allows readers and one writer to proceed concurrently."
    }
  ],
  "credits": 1
}|}

let sample_json = json_object sample

(* A {!Seekwright.Provider.Net.t} that records what was dialed and answers with
   a canned response. Every request-shape case is
   [let provider, sent = dial () in …; let request = sent ()]. *)
(* The row owns this vendor's price rule — one credit per thousand up to ten results, two past ten —
   and the suite injects that rule so a driven search reports the credit figure the vendor bills. *)
let credit_price n = (if n > 10 then 2.0 else 1.0) *. published_price 1.00 n

let dial ?(status = 200) ?(body = sample) ?(snippet_chars = 500) () =
  let net, sent = answered ~status ~body in
  (Serper.make ~cost_for:credit_price ~snippet_chars ~key:test_key ~net (), sent)

let refusal kind ~message =
  Serper.make ~cost_for:credit_price ~key:test_key ~net:(refusing kind ~message) ()

(* The adapter, driven: [search_of ()] answers with the fixture and hands back
   both the outcome and the request that was dialed. *)
let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?(query = query ()) () =
  let provider, sent = dial ~status ~body ~snippet_chars () in
  drive provider sent query

let parse ?(snippet_chars = 500) ?(limit = 10) data = Serper.parse ~snippet_chars data ~limit

let record fields =
  `Assoc (("title", `String "t") :: ("link", `String "https://example.com/a") :: fields)

let organic items = `Assoc [ ("organic", `List items) ]

let the_fixture_yields_both_records () =
  let hits = parse sample_json in
  check_int "two results" 2 (List.length hits);
  check_string "the title" "Write-Ahead Logging" (List.hd hits).result.title;
  check_string "the url" "https://www.sqlite.org/wal.html" (List.hd hits).result.url;
  check_string "the second url" "https://example.com/wal-explained" (List.nth hits 1).result.url

let the_limit_is_honoured () = check_int "one of two" 1 (List.length (parse ~limit:1 sample_json))

let a_serp_record_fills_snippet_and_never_text () =
  let hits = parse sample_json in
  check_bool "the snippet is kept" true ((List.hd hits).result.snippet <> None);
  check_opt_string "text is never filled" None (List.hd hits).result.text

let the_date_is_kept_only_when_a_string () =
  let hits = parse sample_json in
  check_opt_string "the declared date" (Some "2024-11-03") (List.hd hits).result.published_date;
  check_opt_string "the record without one" None (List.nth hits 1).result.published_date

let records_without_a_url_are_dropped () =
  check_int "no link" 0
    (List.length
       (parse (`Assoc [ ("organic", `List [ `Assoc [ ("title", `String "No url here") ] ]) ])))

let records_without_a_title_are_dropped () =
  check_int "no title" 0
    (List.length
       (parse
          (`Assoc [ ("organic", `List [ `Assoc [ ("link", `String "https://example.com") ] ]) ])))

let a_record_that_is_not_an_object_is_skipped () =
  check_int "the string is dropped, the object survives" 1
    (List.length (parse (organic [ `String "nonsense"; record [] ])))

let missing_organic_is_empty_not_an_error () =
  check_int "organic is null" 0 (List.length (parse (`Assoc [ ("organic", `Null) ])));
  check_int "organic is absent" 0 (List.length (parse (`Assoc [])))

(* A non-string [date] or [snippet] is dropped, not handed to the wire model or
   to the truncate helper. The payload is untrusted: the fields are documented
   as strings, and a shape drift must not turn into an internal error that
   escapes the engine's provider-error handling. The call has to succeed with
   the field dropped, exactly as the sibling adapters drop a non-string. *)

let non_strings =
  [
    ("a nested object", `Assoc [ ("nested", `String "object") ]);
    ("a list", `List [ `String "a"; `String "b" ]);
    ("a number", `Int 7);
  ]

let a_non_string_date_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body = Yojson.Safe.to_string (organic [ record [ ("date", value) ] ]) in
      let outcome, _ = search_of ~body ~query:(query ~max_results:1 ()) () in
      check_int
        (Printf.sprintf "the call succeeded through %s" what)
        1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.published_date)
    non_strings

let a_non_string_snippet_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body = Yojson.Safe.to_string (organic [ record [ ("snippet", value) ] ]) in
      let outcome, _ = search_of ~body ~query:(query ~max_results:1 ()) () in
      check_int
        (Printf.sprintf "the call succeeded through %s" what)
        1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.snippet)
    non_strings

let a_string_date_still_reaches_the_model () =
  (* The guard must not change behaviour for a well-formed payload. *)
  let outcome, _ = search_of ~query:(query ~max_results:1 ()) () in
  check_opt_string "the date" (Some "2024-11-03") (List.hd outcome.results).result.published_date

let a_string_snippet_still_reaches_the_model () =
  let outcome, _ = search_of ~query:(query ~max_results:1 ()) () in
  check_opt_string "the snippet"
    (Some "The default method by which SQLite implements atomic commit is a rollback journal.")
    (List.hd outcome.results).result.snippet

let post_to_the_search_endpoint_with_the_key_header () =
  let _, request = search_of ~query:(query ~text:"wal mode" ~max_results:3 ()) () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `POST);
  check_string "the URI" (Uri.to_string Serper.endpoint)
    (Uri.to_string request.Caps.Authority.Net.uri);
  check_opt_string "the vendor's own header spelling" (Some test_key)
    (List.assoc_opt "X-API-KEY" request.Caps.Authority.Net.headers);
  check_opt_string "and a JSON body needs its content type" (Some "application/json")
    (List.assoc_opt "Content-Type" request.Caps.Authority.Net.headers);
  check_opt_string "the query" (Some "wal mode") (body_field "q" request);
  check_opt_string "num follows max_results" (Some "3") (body_field "num" request)

let the_key_never_rides_the_url () =
  (* The credential is a header, so no URL that reaches a log line or a failure
     message can carry it. *)
  let _, request = search_of () in
  check_bool "the URI names no key" false
    (contains ~haystack:(Uri.to_string request.Caps.Authority.Net.uri) ~needle:test_key);
  check_bool "and no key in the query" true (Uri.query request.Caps.Authority.Net.uri = [])

let the_country_reaches_gl_and_the_recency_reaches_tbs () =
  List.iter
    (fun (period, code) ->
      let _, request = search_of ~query:(query ~country:"de" ~recency:period ()) () in
      check_opt_string "gl carries the country" (Some "de") (body_field "gl" request);
      check_opt_string (Printf.sprintf "%s reaches tbs" code) (Some code) (body_field "tbs" request))
    [ (Model.Day, "qdr:d"); (Model.Week, "qdr:w"); (Model.Month, "qdr:m"); (Model.Year, "qdr:y") ];
  (* Unasked, neither field is sent: a bare [num] with no [tbs] is the
     unfiltered SERP, and a default there would narrow the search unasked. *)
  let _, request = search_of () in
  check_bool "no gl" false (has_body_field "gl" request);
  check_bool "no tbs" false (has_body_field "tbs" request)

let the_language_maps_onto_hl_lowercased () =
  let _, request = search_of ~query:(query ~language:"DE" ()) () in
  check_opt_string "hl" (Some "de") (body_field "hl" request)

let hl_is_absent_without_a_language () =
  let _, request = search_of () in
  check_bool "no hl" false (has_body_field "hl" request)

let domain_filters_ride_in_the_query () =
  let _, request =
    search_of
      ~query:
        (query ~text:"wal mode" ~include_domains:[ "sqlite.org" ]
           ~exclude_domains:[ "spam.example" ] ())
      ()
  in
  let q = Option.get (body_field "q" request) in
  includes "the include rides a site: operator" "site:sqlite.org" q;
  includes "the exclude is negated" "-site:spam.example" q;
  check_bool "no include_domains field" false (has_body_field "include_domains" request)

let no_safe_search_parameter_is_ever_sent () =
  List.iter
    (fun value ->
      let _, request = search_of ~query:(query ~safe_search:value ()) () in
      check_bool "no safe" false (has_body_field "safe" request);
      check_bool "no safe_search" false (has_body_field "safe_search" request))
    [ true; false ]

let a_safe_search_is_noticed_for_both_values () =
  List.iter
    (fun value ->
      let outcome, _ = search_of ~query:(query ~safe_search:value ()) () in
      check_string "the safe-search sentence"
        "cannot filter by safe-search; that constraint was ignored" (Option.get outcome.notice))
    [ true; false ]

let an_unconstrained_query_carries_no_notice () =
  let outcome, _ = search_of () in
  check_opt_string "nothing dropped" None outcome.notice

let the_honoured_buckets_draw_no_notice () =
  (* Domains ride [site:], [gl] and [hl] are native and [tbs] is the time
     restriction: three of the four buckets are honoured, so only safety is
     named — and the geo bucket stays joined because [hl] carries language. *)
  let outcome, _ =
    search_of
      ~query:
        (query ~include_domains:[ "sqlite.org" ] ~country:"de" ~language:"de" ~recency:Model.Week ())
      ()
  in
  check_opt_string "no notice at all when safe-search is unasked" None outcome.notice

(* The six rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is this adapter's quota row.

   Serper bills by credit pack ("50k credits ($1.00/1k)"), so a spent balance
   is a payment question and both 402 and 429 ride the quota row. No vendor page
   pins which status a spent key answers with, so this pin is the classing
   itself, not a transcription of vendor prose — and the adapter used to read
   only 429, which surfaced a spent account as the unclassified [HTTP 402] the
   engine does not treat as quota. *)

let spent_credits_and_rate_limit_are_quota () =
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:sample () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string "the house sentence" "rate limited or out of credits" failure.message;
          check_bool "the quota kind" true (failure.kind = Provider.Quota);
          check_bool "a spent quota is not transient" false failure.retryable)
    [ 402; 429 ]

let a_body_that_quotes_the_key_is_not_echoed () =
  let body = Printf.sprintf "<html>upstream echoed %s on a payment page</html>" test_key in
  let provider, _ = dial ~status:402 ~body () in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "HTTP 402 was accepted"
  | Error failure ->
      check_bool "the vendor's page is not quoted" false
        (contains ~haystack:(Provider.render_error failure) ~needle:test_key)

let a_network_failure_does_not_echo_the_request () =
  let provider = refusal Caps.Error.Denied ~message:"connection refused to X-API-KEY: test-key" in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "a refused grant was accepted"
  | Error failure ->
      check_string "the network row" "network error" failure.message;
      check_bool "nothing about the request rides along" false
        (contains ~haystack:(Provider.render_error failure) ~needle:test_key)

let the_result_carries_the_credit_figure () =
  let outcome, _ = search_of ~query:(query ~max_results:20 ()) () in
  check_string "named by the adapter that served it" "serper" outcome.provider;
  check_opt_number "two credits, not one" (Some 0.002) outcome.cost_usd

let the_adapter_dials_the_endpoint_it_declares () =
  check_string "the endpoint" "https://google.serper.dev/search" (Uri.to_string Serper.endpoint);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.Caps.Authority.Net.uri = Uri.host Serper.endpoint)

let () =
  A.(
    run "seekwright/serper"
      [
        ( "parsing",
          [
            test_case "the live fixture yields both records" `Quick the_fixture_yields_both_records;
            test_case "the limit is honoured" `Quick the_limit_is_honoured;
            test_case "a SERP record fills snippet and never text" `Quick
              a_serp_record_fills_snippet_and_never_text;
            test_case "the date is kept only when a string" `Quick
              the_date_is_kept_only_when_a_string;
            test_case "records without a url are dropped" `Quick records_without_a_url_are_dropped;
            test_case "records without a title are dropped" `Quick
              records_without_a_title_are_dropped;
            test_case "a record that is not an object is skipped" `Quick
              a_record_that_is_not_an_object_is_skipped;
            test_case "missing organic is empty, not an error" `Quick
              missing_organic_is_empty_not_an_error;
          ] );
        ( "the upstream field guards",
          [
            test_case "a non-string date is dropped and the call succeeds" `Quick
              a_non_string_date_is_dropped_and_the_call_succeeds;
            test_case "a non-string snippet is dropped and the call succeeds" `Quick
              a_non_string_snippet_is_dropped_and_the_call_succeeds;
            test_case "a string date still reaches the model" `Quick
              a_string_date_still_reaches_the_model;
            test_case "a string snippet still reaches the model" `Quick
              a_string_snippet_still_reaches_the_model;
          ] );
        ( "the request",
          [
            test_case "POST to the search endpoint, key in the header" `Quick
              post_to_the_search_endpoint_with_the_key_header;
            test_case "the key never rides the URL" `Quick the_key_never_rides_the_url;
            test_case "the country reaches gl and the recency reaches tbs" `Quick
              the_country_reaches_gl_and_the_recency_reaches_tbs;
            test_case "the language maps onto hl lowercased" `Quick
              the_language_maps_onto_hl_lowercased;
            test_case "hl is absent without a language" `Quick hl_is_absent_without_a_language;
            test_case "the domain filters ride in the query" `Quick domain_filters_ride_in_the_query;
            test_case "no safe-search parameter is ever sent" `Quick
              no_safe_search_parameter_is_ever_sent;
          ] );
        ( "the constraint report",
          [
            test_case "a safe-search is noticed for both values" `Quick
              a_safe_search_is_noticed_for_both_values;
            test_case "an unconstrained query carries no notice" `Quick
              an_unconstrained_query_carries_no_notice;
            test_case "the honoured buckets draw no notice" `Quick
              the_honoured_buckets_draw_no_notice;
          ] );
        ( "the failures this adapter owns",
          [
            test_case "spent credits and the rate limit are quota" `Quick
              spent_credits_and_rate_limit_are_quota;
            test_case "the body behind the payment status is not echoed" `Quick
              a_body_that_quotes_the_key_is_not_echoed;
            test_case "a network failure does not echo the request" `Quick
              a_network_failure_does_not_echo_the_request;
          ] );
        ( "cost and endpoint",
          [
            test_case "the result carries the credit figure" `Quick
              the_result_carries_the_credit_figure;
            test_case "the adapter dials the endpoint it declares" `Quick
              the_adapter_dials_the_endpoint_it_declares;
          ] );
      ])
