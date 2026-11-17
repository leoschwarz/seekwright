(* Search1API: response parsing, request shape and cost.

   The fixture is the documented [/search] payload from the operator's OpenAPI
   schema, and the request-shape cases drive the adapter through a fake
   {!Seekwright.Provider.Net.t} — the position [httpx.MockTransport] holds in
   Python, and possible here for the same reason: the client is injected.

   The wiring cases from that suite ([test_built_only_when_a_key_is_present],
   the cost-correction cases through the factory) belong to the registry and
   config suites: an adapter never decides whether it is enabled. What stays
   here is the adapter's own default price, pinned against the figure the row
   builds it with.

   The adapter is shipped untested — no live verification against the real
   endpoint has happened in-repo — so these hermetic cases are the whole
   coverage that exists. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Search1api = Seekwright_providers.Search1api
module A = Alcotest
module Utf8 = Seekwright_text.Utf8
open Test_support
open Adapter_support

(* The documented payload: [results[]] with the four fields the mapping reads
   — the second record without the optional [published_date], as the schema
   omits it when the source exposes none — beside the [searchParameters] echo
   the parse never touches. *)
let sample =
  {|{
  "searchParameters": {
    "query": "write-ahead logging",
    "search_service": "google",
    "max_results": 5,
    "crawl_results": 0,
    "include_sites": [],
    "exclude_sites": []
  },
  "results": [
    {
      "title": "Write-Ahead Logging",
      "link": "https://www.sqlite.org/wal.html",
      "snippet": "The default method by which SQLite implements atomic commit is a rollback journal.",
      "published_date": "2024-11-03"
    },
    {
      "title": "SQLite WAL mode explained",
      "link": "https://example.com/wal-explained",
      "snippet": "WAL allows readers and one writer to proceed concurrently."
    }
  ]
}|}

let sample_json = json_object sample

let dial ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k () =
  let net, sent = answered ~status ~body in
  (Search1api.make ?cost_per_1k ~snippet_chars ~key:test_key ~net (), sent)

let refusal kind ~message = Search1api.make ~key:test_key ~net:(refusing kind ~message) ()

let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k
    ?(query = query ()) () =
  let provider, sent = dial ~status ~body ~snippet_chars ?cost_per_1k () in
  drive provider sent query

(* The request body, read the way the Python suite reads
   [json.loads(request.content)]. *)
let body_json (request : Caps.Authority.Net.request) =
  match Yojson.Safe.from_string (Option.get request.Caps.Authority.Net.body) with
  | `Assoc fields -> fields
  | _ -> A.failf "the request body is not an object"

let body_field request name = List.assoc_opt name (body_json request)

let body_string request name =
  match List.assoc_opt name (body_json request) with
  | Some (`String value) -> Some value
  | _ -> None

let body_rendered request name = Option.map Yojson.Safe.to_string (body_field request name)

let has_body_field request name = body_field request name <> None

let parse ?(snippet_chars = 500) ?(limit = 10) data = Search1api.parse ~snippet_chars data ~limit

let record fields = `Assoc (("title", `String "t") :: ("link", `String "https://x") :: fields)

let results items = `Assoc [ ("results", `List items) ]

let the_fixture_yields_both_records () =
  let hits = parse sample_json in
  check_int "two results" 2 (List.length hits);
  check_string "the title" "Write-Ahead Logging" (List.hd hits).result.title;
  check_string "the url" "https://www.sqlite.org/wal.html" (List.hd hits).result.url;
  check_string "the second url" "https://example.com/wal-explained" (List.nth hits 1).result.url

let the_limit_is_honoured () = check_int "one of two" 1 (List.length (parse ~limit:1 sample_json))

let the_snippet_is_kept_and_never_text () =
  (* A SERP backend fills snippet, never text. *)
  let hit = List.hd (parse sample_json) in
  check_bool "the snippet is there" true (hit.result.snippet <> None);
  check_opt_string "and no text" None hit.result.text

let the_snippet_is_truncated () =
  let hits = parse ~snippet_chars:40 sample_json in
  let snippet = Option.get (List.hd hits).result.snippet in
  check_int "cut at the cap plus the ellipsis" 41 (Utf8.count snippet);
  check_opt_int "the pre-cap length" (Some 82) (List.hd hits).uncapped_chars

let the_length_the_cap_discarded_is_recorded () =
  (* [search.cap] reads this: the pre-cap length, log-only and off the wire. *)
  let hits = parse ~snippet_chars:40 sample_json in
  let hit = List.hd hits in
  let uncapped = Option.get hit.uncapped_chars in
  check_int "the whole snippet was longer than the cap" 82 uncapped;
  check_bool "and longer than what shipped" true
    (uncapped > Utf8.count (Option.get hit.result.snippet));
  (* Private, so a caller can never see it: the response carries the clipped
     snippet, never a measurement of the clip. *)
  excludes "absent from the wire model" "uncapped"
    (Yojson.Safe.to_string (Model.result_to_yojson hit.result))

let a_short_snippet_reports_its_own_length () =
  (* The denominator: a hit the cap did not bite is still measured. *)
  let hit = List.nth (parse sample_json) 1 in
  check_bool "the snippet is there" true (hit.result.snippet <> None);
  check_opt_int "measured at its own length"
    (Some (Utf8.count (Option.get hit.result.snippet)))
    hit.uncapped_chars

let the_published_date_is_kept_only_when_a_string () =
  (* The schema omits the date per result when the source exposes none, so
     nothing is invented. *)
  let hits = parse sample_json in
  check_opt_string "the fixture's date" (Some "2024-11-03") (List.hd hits).result.published_date;
  check_opt_string "and its absence" None (List.nth hits 1).result.published_date

let records_without_a_link_are_dropped () =
  check_int "no link" 0
    (List.length
       (parse (`Assoc [ ("results", `List [ `Assoc [ ("title", `String "No link here") ] ]) ])))

let records_without_a_title_are_dropped () =
  check_int "no title" 0
    (List.length
       (parse
          (`Assoc [ ("results", `List [ `Assoc [ ("link", `String "https://example.com") ] ]) ])))

let a_record_that_is_not_an_object_is_skipped () =
  check_int "the string is dropped, the object survives" 1
    (List.length (parse (results [ `String "nonsense"; record [] ])))

let missing_results_is_empty_not_an_error () =
  check_int "results is null" 0 (List.length (parse (`Assoc [ ("results", `Null) ])));
  check_int "results is absent" 0 (List.length (parse (`Assoc [])))

(* A non-string [snippet] or [published_date] is dropped, not handed to the
   shared truncate helper: a nested object, list or number there must read as a
   missing field, not raise out of the engine's provider-error handling. *)

let non_strings =
  [
    ("a nested object", `Assoc [ ("nested", `String "object") ]);
    ("a list", `List [ `String "a"; `String "b" ]);
    ("a number", `Int 7);
  ]

let a_non_string_date_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body = Yojson.Safe.to_string (results [ record [ ("published_date", value) ] ]) in
      let outcome, _ = search_of ~body ~query:(query ~max_results:1 ()) () in
      check_int
        (Printf.sprintf "the call succeeded through %s" what)
        1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.published_date)
    non_strings

let a_non_string_snippet_is_dropped_and_the_call_succeeds () =
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

(* Domains, dates and language ride native parameters, so three buckets are
   honoured. There is no country parameter and no safe-search parameter in the
   documented schema, so those halves drop — and the notice is the only thing
   between a caller that asked for them and the belief that it got them. *)

let post_with_the_bearer_key () =
  let _, request = search_of () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `POST);
  check_opt_string "the bearer header"
    (Some ("Bearer " ^ test_key))
    (List.assoc_opt "Authorization" request.Caps.Authority.Net.headers);
  check_opt_string "the content type" (Some "application/json")
    (List.assoc_opt "Content-Type" request.Caps.Authority.Net.headers);
  check_string "the endpoint" "https://api.search1api.com/search"
    (Uri.to_string request.Caps.Authority.Net.uri)

let the_query_and_max_results_are_sent () =
  let _, request = search_of ~query:(query ~text:"wal mode" ~max_results:3 ()) () in
  check_opt_string "the query" (Some "wal mode") (body_string request "query");
  check_opt_string "max_results" (Some "3") (body_rendered request "max_results")

let the_domain_filters_ride_their_native_fields () =
  let _, request =
    search_of
      ~query:(query ~include_domains:[ "sqlite.org" ] ~exclude_domains:[ "spam.example" ] ())
      ()
  in
  check_string "include_sites" "[\"sqlite.org\"]"
    (Yojson.Safe.to_string (Option.get (body_field request "include_sites")));
  check_string "exclude_sites" "[\"spam.example\"]"
    (Yojson.Safe.to_string (Option.get (body_field request "exclude_sites")))

let the_domain_fields_are_absent_without_filters () =
  let _, request = search_of () in
  check_bool "no include_sites" false (has_body_field request "include_sites");
  check_bool "no exclude_sites" false (has_body_field request "exclude_sites")

let the_recency_maps_onto_time_range () =
  List.iter
    (fun (period, word) ->
      let _, request = search_of ~query:(query ~recency:period ()) () in
      check_opt_string
        (Printf.sprintf "%s reaches time_range" word)
        (Some word)
        (body_rendered request "time_range"))
    [
      (Model.Day, "\"day\"");
      (Model.Week, "\"week\"");
      (Model.Month, "\"month\"");
      (Model.Year, "\"year\"");
    ];
  let _, request = search_of () in
  check_bool "unasked, no time_range" false (has_body_field request "time_range")

let the_language_is_lowercased_on_the_wire () =
  let outcome, request = search_of ~query:(query ~language:"DE" ()) () in
  check_opt_string "language" (Some "\"de\"") (body_rendered request "language");
  (* Language is honoured, so a language-only constraint carries no notice. *)
  check_opt_string "no notice" None outcome.notice;
  let _, request = search_of () in
  check_bool "and absent without a language" false (has_body_field request "language")

let never_a_billing_or_engine_field () =
  (* [crawl_results] would add a credit per crawled page; [image],
     [search_service] and [page] are choices this deployment makes for its
     operators, not the caller's. None of them may appear in a body at all. *)
  let _, request =
    search_of
      ~query:
        (query ~include_domains:[ "sqlite.org" ] ~exclude_domains:[ "spam.example" ] ~language:"en"
           ~recency:Model.Day ~country:"de" ~safe_search:true ())
      ()
  in
  List.iter
    (fun field ->
      check_bool (Printf.sprintf "no %s in the body" field) false (has_body_field request field))
    [ "crawl_results"; "image"; "search_service"; "page" ]

let the_notice_cases () =
  (* An unconstrained query carries no notice. *)
  let outcome, _ = search_of () in
  check_opt_string "unconstrained" None outcome.notice;
  (* A country constraint is noticed: no parameter carries it. *)
  let outcome, _ = search_of ~query:(query ~country:"de" ()) () in
  check_opt_string "country" (Some "cannot filter by country; that constraint was ignored")
    outcome.notice;
  (* And safe-search, for both values: [Some false] is a request too. *)
  List.iter
    (fun value ->
      let outcome, _ = search_of ~query:(query ~safe_search:value ()) () in
      check_opt_string
        (Printf.sprintf "safe_search=%b" value)
        (Some "cannot filter by safe-search; that constraint was ignored") outcome.notice)
    [ true; false ];
  (* Country and safe-search together name both halves. *)
  let outcome, _ = search_of ~query:(query ~country:"de" ~safe_search:true ()) () in
  check_opt_string "country or safe-search"
    (Some "cannot filter by country or safe-search; that constraint was ignored") outcome.notice

let the_honoured_buckets_stay_silent () =
  (* Domains, dates and language are honoured, so only the dropped halves may
     appear in the notice. *)
  let outcome, _ =
    search_of
      ~query:
        (query ~include_domains:[ "sqlite.org" ] ~recency:Model.Month ~language:"en" ~country:"de"
           ())
      ()
  in
  check_opt_string "only country is named"
    (Some "cannot filter by country; that constraint was ignored") outcome.notice

let the_result_reports_its_flat_cost () =
  let outcome, _ = search_of ~query:(query ~max_results:5 ()) () in
  check_string "named by the adapter that served it" "search1api" outcome.provider;
  check_opt_number "one credit at the entry plan's rate" (Some 0.00076) outcome.cost_usd

(* The six rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is this adapter's quota statuses,
   its own message wording, and the leak regression that proves the redaction
   rule for the place its key actually rides. *)

let payment_and_rate_limit_are_quota () =
  (* 402 is documented ([application/problem+json]): for a keyed client that
     means the credits are gone, not a malformed request. 429 is presumed rate
     limiting, since the limits are undocumented. *)
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:"{}" () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string "the house sentence" "out of credits or rate limited" failure.message;
          check_bool "the quota kind" true (failure.kind = Provider.Quota);
          check_bool "a spent quota is not transient" false failure.retryable)
    [ 402; 429 ]

let a_network_error_does_not_echo_the_request () =
  let provider =
    refusal Caps.Error.Denied ~message:"connection refused to Authorization: test-key"
  in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "a refused grant was accepted"
  | Error failure ->
      check_string "the network row" "network error" failure.message;
      check_bool "the key is nowhere in the failure" false
        (contains ~haystack:(Provider.render_error failure) ~needle:test_key)

let cost_does_not_scale_with_result_count () =
  let provider, _ = dial () in
  check_number "one query, whatever max_results says" 0.00076 (Provider.cost_for provider 1);
  check_number "and at the ceiling" 0.00076 (Provider.cost_for provider 20)

let the_default_price_is_the_rows_figure () =
  (* The adapter default and the registry row's [default_cost] are one fact:
     [$0.76/1k] is the entry Basic plan's rate, a cheaper plan corrects it, and
     [--check --live] prints whichever of the two is wrong. *)
  let provider, _ = dial () in
  check_number "the entry plan's rate" 0.76 (Provider.cost_per_1k provider);
  let provider, _ = dial ~cost_per_1k:0.49 () in
  check_number "an operator on a cheaper plan can correct it" 0.49 (Provider.cost_per_1k provider)

let the_endpoint_is_the_one_the_grant_allows () =
  check_string "the endpoint" "https://api.search1api.com/search"
    (Uri.to_string Search1api.endpoint);
  check_string "the policy host" "api.search1api.com" Search1api.policy_endpoint.Caps.Policy.host;
  check_bool "https" true (Search1api.policy_endpoint.Caps.Policy.scheme = `Https);
  check_bool "the default port" true (Search1api.policy_endpoint.Caps.Policy.port = None);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.Caps.Authority.Net.uri = Some Search1api.policy_endpoint.Caps.Policy.host);
  (* The key rides a header, so the URL the grant confines never carries it. *)
  check_bool "no key in the URL" false
    (contains ~haystack:(Uri.to_string request.Caps.Authority.Net.uri) ~needle:test_key)

let () =
  A.(
    run "seekwright/search1api"
      [
        ( "parsing",
          [
            test_case "the fixture yields both records" `Quick the_fixture_yields_both_records;
            test_case "the limit is honoured" `Quick the_limit_is_honoured;
            test_case "the snippet is kept and never text" `Quick the_snippet_is_kept_and_never_text;
            test_case "the snippet is truncated" `Quick the_snippet_is_truncated;
            test_case "the length the cap discarded is recorded" `Quick
              the_length_the_cap_discarded_is_recorded;
            test_case "a short snippet reports its own length" `Quick
              a_short_snippet_reports_its_own_length;
            test_case "the published date is kept only when a string" `Quick
              the_published_date_is_kept_only_when_a_string;
            test_case "records without a link are dropped" `Quick records_without_a_link_are_dropped;
            test_case "records without a title are dropped" `Quick
              records_without_a_title_are_dropped;
            test_case "a record that is not an object is skipped" `Quick
              a_record_that_is_not_an_object_is_skipped;
            test_case "missing results is empty, not an error" `Quick
              missing_results_is_empty_not_an_error;
          ] );
        ( "the upstream field guards",
          [
            test_case "a non-string date is dropped and the call succeeds" `Quick
              a_non_string_date_is_dropped_and_the_call_succeeds;
            test_case "a non-string snippet is dropped and the call succeeds" `Quick
              a_non_string_snippet_is_dropped_and_the_call_succeeds;
            test_case "a string snippet still reaches the model" `Quick
              a_string_snippet_still_reaches_the_model;
          ] );
        ( "the request",
          [
            test_case "POST with the bearer key" `Quick post_with_the_bearer_key;
            test_case "the query and max_results are sent" `Quick the_query_and_max_results_are_sent;
            test_case "the domain filters ride their native fields" `Quick
              the_domain_filters_ride_their_native_fields;
            test_case "the domain fields are absent without filters" `Quick
              the_domain_fields_are_absent_without_filters;
            test_case "the recency maps onto time_range" `Quick the_recency_maps_onto_time_range;
            test_case "the language is lowercased on the wire" `Quick
              the_language_is_lowercased_on_the_wire;
            test_case "never a billing or engine field" `Quick never_a_billing_or_engine_field;
            test_case "the notice cases" `Quick the_notice_cases;
            test_case "the honoured buckets stay silent" `Quick the_honoured_buckets_stay_silent;
            test_case "the result reports its flat cost" `Quick the_result_reports_its_flat_cost;
          ] );
        ( "the failures this adapter owns",
          [
            test_case "payment and rate limit are quota" `Quick payment_and_rate_limit_are_quota;
            test_case "a network error does not echo the request" `Quick
              a_network_error_does_not_echo_the_request;
          ] );
        ( "cost and endpoint",
          [
            test_case "cost does not scale with result count" `Quick
              cost_does_not_scale_with_result_count;
            test_case "the default price is the row's figure" `Quick
              the_default_price_is_the_rows_figure;
            test_case "the endpoint is the one the grant allows" `Quick
              the_endpoint_is_the_one_the_grant_allows;
          ] );
      ])
