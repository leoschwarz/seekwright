(* Querit: response parsing, request shape and cost.

   The fixture is the documented [/v1/search] payload: [results] is an object
   and the hits live under its [result] key — the wire's shape. Each hit carries
   [url], [title], [snippet], [page_age] and [site_name]; every result field is
   documented optional. [sentence] (body text) exists upstream only behind
   [needContent: true] and [highlights] only behind its request field, which this
   adapter never sends — so a parsed result fills [snippet] and never [text].

   The wiring cases from that suite belong to the registry and config suites;
   what stays here is the adapter's own default price — the free plan's zero —
   pinned against the figure the row builds it with. The adapter is shipped
   untested, so these hermetic cases are the whole coverage that exists. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Querit = Seekwright_providers.Querit
module A = Alcotest
open Test_support

let chars s =
  let n = ref 0 and i = ref 0 in
  while !i < String.length s do
    let c = Char.code s.[!i] in
    i := !i + if c < 0x80 then 1 else if c < 0xe0 then 2 else if c < 0xf0 then 3 else 4;
    incr n
  done;
  !n

let query ?(text = "q") ?(max_results = 5) ?(include_domains = []) ?(exclude_domains = []) ?country
    ?language ?recency ?safe_search () : Model.search_query =
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

(* Never sent to anything real: the string a leak would carry. *)
let test_key = "test-key"

(* The documented payload: the [result] list under the [results] container,
   the second record without the optional [page_age], beside the [took] /
   [error_code] / [search_id] envelope the parse never touches. *)
let sample =
  {|{
  "took": "312ms",
  "error_code": 200,
  "error_msg": "",
  "search_id": 8842013,
  "query_context": {"query": "how vector databases handle hybrid search"},
  "results": {
    "result": [
      {
        "url": "https://example.com/post",
        "title": "Hybrid search explained",
        "snippet": "Hybrid search combines a vector index with BM25 for recall and precision.",
        "page_age": "2026-07-14T09:00:00Z",
        "site_name": "example.com"
      },
      {
        "url": "https://example.org/vector-databases",
        "title": "Vector databases in practice",
        "snippet": "Choosing an embedding dimension is a budget decision."
      }
    ]
  }
}|}

let sample_json =
  match Yojson.Safe.from_string sample with
  | `Assoc _ as json -> json
  | _ -> A.failf "the fixture is not an object"

let dial ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k () =
  let sent = ref None in
  let net =
    {
      Provider.Net.request =
        (fun request ->
          sent := Some request;
          Ok { Caps.Authority.Net.status; headers = []; body });
    }
  in
  let provider = Querit.make ?cost_per_1k ~snippet_chars ~key:test_key ~net () in
  (provider, fun () -> Option.get !sent)

let refusal kind ~message =
  let net = { Provider.Net.request = (fun _ -> Error (Caps.Error.make kind ~message)) } in
  Querit.make ~key:test_key ~net ()

let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k
    ?(query = query ~text:"hybrid search" ()) () =
  let provider, sent = dial ~status ~body ~snippet_chars ?cost_per_1k () in
  match Provider.search provider query with
  | Ok outcome -> (outcome, sent ())
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

(* The request body as a Yojson value, read the way the Python suite reads
   [json.loads(request.content)]. *)
let body (request : Caps.Authority.Net.request) =
  match Yojson.Safe.from_string (Option.get request.Caps.Authority.Net.body) with
  | `Assoc _ as json -> json
  | _ -> A.failf "the request body is not an object"

let body_has request name = Provider.Json.field name (body request) <> `Null

let body_path request path =
  List.fold_left (fun json key -> Provider.Json.field key json) (body request) path

let parse ?(snippet_chars = 500) ?(limit = 10) data = Querit.parse ~snippet_chars data ~limit

let record fields = `Assoc (("title", `String "t") :: ("url", `String "https://x") :: fields)

let hits items = `Assoc [ ("result", `List items) ]

let with_results container = `Assoc [ ("results", container) ]

let the_fixture_yields_both_records () =
  let found = parse sample_json in
  check_int "two results" 2 (List.length found);
  check_string "the title" "Hybrid search explained" (List.hd found).result.title;
  check_string "the url" "https://example.com/post" (List.hd found).result.url;
  check_string "the second url" "https://example.org/vector-databases" (List.nth found 1).result.url

let the_limit_is_honoured () = check_int "one of two" 1 (List.length (parse ~limit:1 sample_json))

let the_snippet_is_kept_and_never_text () =
  (* A SERP backend fills snippet, never text. *)
  let hit = List.hd (parse sample_json) in
  check_bool "the snippet is there" true (hit.result.snippet <> None);
  check_opt_string "and no text" None hit.result.text

let the_snippet_is_truncated () =
  let found = parse ~snippet_chars:40 sample_json in
  let snippet = Option.get (List.hd found).result.snippet in
  check_int "cut at the cap plus the ellipsis" 41 (chars snippet)

let the_length_the_cap_discarded_is_recorded () =
  (* [search.cap] reads this: the pre-cap length, log-only and off the wire. *)
  let found = parse ~snippet_chars:40 sample_json in
  let hit = List.hd found in
  let uncapped = Option.get hit.uncapped_chars in
  let whole = "Hybrid search combines a vector index with BM25 for recall and precision." in
  check_int "the whole snippet was longer than the cap" (chars whole) uncapped;
  check_bool "and longer than what shipped" true (uncapped > chars (Option.get hit.result.snippet));
  (* Private, so a caller can never see it: the response carries the clipped
     snippet, never a measurement of the clip. *)
  excludes "absent from the wire model" "uncapped"
    (Yojson.Safe.to_string (Model.result_to_yojson hit.result))

let a_short_snippet_reports_its_own_length () =
  (* The denominator: a hit the cap did not bite is still measured. *)
  let hit = List.nth (parse sample_json) 1 in
  check_bool "the snippet is there" true (hit.result.snippet <> None);
  check_opt_int "measured at its own length"
    (Some (chars (Option.get hit.result.snippet)))
    hit.uncapped_chars

let the_page_age_is_kept_only_when_a_string () =
  (* The schema marks every result field optional, so the second record stays
     empty. *)
  let found = parse sample_json in
  check_opt_string "the fixture's page_age" (Some "2026-07-14T09:00:00Z")
    (List.hd found).result.published_date;
  check_opt_string "and its absence" None (List.nth found 1).result.published_date

let records_without_a_url_are_dropped () =
  check_int "no url" 0
    (List.length (parse (with_results (hits [ `Assoc [ ("title", `String "No url here") ] ]))))

let records_without_a_title_are_dropped () =
  check_int "no title" 0
    (List.length
       (parse (with_results (hits [ `Assoc [ ("url", `String "https://example.com") ] ]))))

let a_record_that_is_not_an_object_is_skipped () =
  check_int "the string is dropped, the object survives" 1
    (List.length (parse (with_results (hits [ `String "nonsense"; record [] ]))))

let missing_results_is_empty_not_an_error () =
  check_int "results is null" 0 (List.length (parse (with_results `Null)));
  check_int "results is absent" 0 (List.length (parse (`Assoc [])))

let a_non_object_results_container_is_empty_not_an_error () =
  (* [results] is an object on the wire; a shape drift to a list — the
     intuitive reading of the name — is a missing container, not a failure. *)
  check_int "results drifted to a list" 0 (List.length (parse (with_results (`List [ record [] ]))));
  check_int "result is null" 0 (List.length (parse (with_results (`Assoc [ ("result", `Null) ]))))

(* A non-string [snippet] or [page_age] is dropped, not handed to the shared
   truncate helper: the schema marks every result field optional but nothing
   enforces the type, and shape drift must read as a missing field, not raise
   out of the engine's provider-error handling. *)

let non_strings =
  [
    ("a nested object", `Assoc [ ("nested", `String "object") ]);
    ("a list", `List [ `String "a"; `String "b" ]);
    ("a number", `Int 7);
  ]

let a_non_string_date_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body = Yojson.Safe.to_string (with_results (hits [ record [ ("page_age", value) ] ])) in
      let outcome, _ = search_of ~body ~query:(query ~max_results:1 ()) () in
      check_int
        (Printf.sprintf "the call succeeded through %s" what)
        1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.published_date)
    non_strings

let a_non_string_snippet_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body = Yojson.Safe.to_string (with_results (hits [ record [ ("snippet", value) ] ])) in
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
    (Some "Hybrid search combines a vector index with BM25 for recall and precision.")
    (List.hd outcome.results).result.snippet

(* Domains, dates and the mappable halves of country and language ride native
   filter fields ([filters.sites], [filters.timeRange.date],
   [filters.geo.countries.include] and [filters.languages.include]). A country
   or language the backend's strict enums cannot express is dropped and named
   in [notice]; there is no safe-search parameter. [count] is clamped to the
   free plan's 10-result cap, whatever [max_results] asks. *)

let post_with_the_bearer_key () =
  let _, request = search_of () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `POST);
  check_opt_string "the bearer header"
    (Some ("Bearer " ^ test_key))
    (List.assoc_opt "Authorization" request.Caps.Authority.Net.headers);
  check_string "the endpoint" "https://api.querit.ai/v1/search"
    (Uri.to_string request.Caps.Authority.Net.uri)

let the_query_and_count_are_sent () =
  let _, request = search_of ~query:(query ~text:"hybrid search" ~max_results:3 ()) () in
  check_string "the query" "\"hybrid search\""
    (Yojson.Safe.to_string (Provider.Json.field "query" (body request)));
  check_string "count" "3" (Yojson.Safe.to_string (Provider.Json.field "count" (body request)))

let count_is_clamped_to_the_free_plan_cap () =
  (* The free plan answers at most 10 results, so the request never asks it
     for more: clamped, documented, and the response simply carries fewer hits
     than asked — a shorter answer, not a notice. *)
  List.iter
    (fun max_results ->
      let outcome, request = search_of ~query:(query ~max_results ()) () in
      check_string
        (Printf.sprintf "count at max_results=%d" max_results)
        (string_of_int Querit.max_results)
        (Yojson.Safe.to_string (Provider.Json.field "count" (body request)));
      check_int "the cap is ten" 10 Querit.max_results;
      check_opt_string "no notice over the clamp" None outcome.notice)
    [ 11; 20; 100 ]

let the_domain_filters_ride_their_native_fields () =
  let _, request =
    search_of
      ~query:(query ~include_domains:[ "example.com" ] ~exclude_domains:[ "spam.example" ] ())
      ()
  in
  check_string "sites.include" "[\"example.com\"]"
    (Yojson.Safe.to_string (body_path request [ "filters"; "sites"; "include" ]));
  check_string "sites.exclude" "[\"spam.example\"]"
    (Yojson.Safe.to_string (body_path request [ "filters"; "sites"; "exclude" ]))

let the_domain_fields_are_absent_without_filters () =
  let _, request = search_of () in
  check_bool "no filters at all" false (body_has request "filters")

let an_include_only_sends_include () =
  let _, request = search_of ~query:(query ~include_domains:[ "example.com" ] ()) () in
  check_bool "no exclude half" false
    (Provider.Json.field "exclude" (body_path request [ "filters"; "sites" ]) <> `Null)

let the_recency_maps_onto_time_range () =
  List.iter
    (fun (period, date) ->
      let _, request = search_of ~query:(query ~recency:period ()) () in
      check_string
        (Printf.sprintf "timeRange.date for %s" date)
        ("\"" ^ date ^ "\"")
        (Yojson.Safe.to_string (body_path request [ "filters"; "timeRange"; "date" ])))
    [ (Model.Day, "d1"); (Model.Week, "w1"); (Model.Month, "m1"); (Model.Year, "y1") ];
  let _, request = search_of () in
  check_bool "unasked, no filters" false (body_has request "filters")

let the_language_maps_onto_the_enums_name () =
  (* The bridge is the eight-name enum; a code with no entry is never sent. *)
  List.iter
    (fun (code, wire) ->
      let outcome, request = search_of ~query:(query ~language:code ()) () in
      check_string
        (Printf.sprintf "languages.include for %s" code)
        ("[\"" ^ wire ^ "\"]")
        (Yojson.Safe.to_string (body_path request [ "filters"; "languages"; "include" ]));
      (* The language is honoured, so a language-only constraint carries no
         notice. *)
      check_opt_string "no notice" None outcome.notice)
    [
      ("en", "english");
      ("EN", "english");
      ("ja", "japanese");
      ("ko", "korean");
      ("de", "german");
      ("fr", "french");
      ("es", "spanish");
      ("pt", "portuguese");
      ("ru", "russian");
    ]

let an_unmappable_language_is_dropped_and_noticed () =
  (* The enum is strict: an ISO code with no entry is not sent (it would be a
     400, not a filter) and the drop is named instead. *)
  let outcome, request = search_of ~query:(query ~language:"zh" ()) () in
  check_bool "no filters at all" false (body_has request "filters");
  check_opt_string "the language is named"
    (Some "cannot filter by language; that constraint was ignored") outcome.notice

let the_country_maps_onto_the_enums_name () =
  List.iter
    (fun (code, wire) ->
      let outcome, request = search_of ~query:(query ~country:code ()) () in
      check_string
        (Printf.sprintf "geo.countries.include for %s" code)
        ("[\"" ^ wire ^ "\"]")
        (Yojson.Safe.to_string (body_path request [ "filters"; "geo"; "countries"; "include" ]));
      check_opt_string "no notice" None outcome.notice)
    [
      ("us", "united states");
      ("gb", "united kingdom");
      ("kr", "south korea");
      ("jp", "japan");
      ("de", "germany");
    ]

let an_unmappable_country_is_dropped_and_noticed () =
  let outcome, request = search_of ~query:(query ~country:"no" ()) () in
  check_bool "no filters at all" false (body_has request "filters");
  check_opt_string "the country is named"
    (Some "cannot filter by country; that constraint was ignored") outcome.notice

let the_notice_cases () =
  (* An unconstrained query carries no notice. *)
  let outcome, _ = search_of () in
  check_opt_string "unconstrained" None outcome.notice;
  (* There is no safe-search parameter, and [Some false] is a request too. *)
  List.iter
    (fun value ->
      let outcome, _ = search_of ~query:(query ~safe_search:value ()) () in
      check_opt_string
        (Printf.sprintf "safe_search=%b" value)
        (Some "cannot filter by safe-search; that constraint was ignored") outcome.notice)
    [ true; false ];
  (* Two dropped halves name themselves. *)
  let outcome, _ = search_of ~query:(query ~country:"no" ~language:"zh" ()) () in
  check_opt_string "country or language"
    (Some "cannot filter by country or language; that constraint was ignored") outcome.notice;
  (* A country half alone, with an honoured language: the buckets are split, so
     the sentence names only what dropped. *)
  let outcome, _ = search_of ~query:(query ~country:"no" ~language:"en" ()) () in
  check_opt_string "only country is named"
    (Some "cannot filter by country; that constraint was ignored") outcome.notice

let the_honoured_buckets_stay_silent () =
  (* Domains, dates, a mappable country and a mappable language are honoured,
     so only the dropped safe-search half may appear. *)
  let outcome, _ =
    search_of
      ~query:
        (query ~include_domains:[ "example.com" ] ~recency:Model.Month ~language:"en" ~country:"us"
           ~safe_search:true ())
      ()
  in
  check_opt_string "only safe-search is named"
    (Some "cannot filter by safe-search; that constraint was ignored") outcome.notice

let never_a_content_or_vertical_field () =
  (* [needContent] would move the call to the content tier (body text in
     [sentence], a [text] fill this adapter must not make); [highlights] and
     the deprecated [chunksPerDoc] bill against the same page-text budget;
     [vertical] is a deployment choice, not a caller's. None of them may
     appear in a body at all. *)
  let _, request =
    search_of
      ~query:
        (query ~include_domains:[ "example.com" ] ~exclude_domains:[ "spam.example" ] ~language:"en"
           ~recency:Model.Day ~country:"us" ~safe_search:true ())
      ()
  in
  List.iter
    (fun field ->
      check_bool (Printf.sprintf "no %s in the body" field) false (body_has request field))
    [ "needContent"; "highlights"; "chunksPerDoc"; "vertical" ]

(* The six rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is this adapter's quota statuses,
   its own message wording, and the leak regression that proves the redaction
   rule for the place its key actually rides. *)

let payment_and_rate_limit_are_quota () =
  (* 429 is documented by this API as the rate limit (1 QPS on the free plan);
     the exhausted monthly allowance answers the same code. *)
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:"{}" () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string "the house sentence" "rate limited or out of monthly calls" failure.message;
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
  check_number "one call, whatever count says" 0. (Provider.cost_for provider 1);
  check_number "and at the cap" 0. (Provider.cost_for provider 20)

let cost_tracks_the_declared_rate () =
  let provider, _ = dial ~cost_per_1k:4.0 () in
  check_number "the PAYG tier, flat" 0.004 (Provider.cost_for provider 1);
  check_number "whatever count says" 0.004 (Provider.cost_for provider 10)

let the_result_reports_its_flat_cost () =
  let outcome, _ = search_of ~query:(query ~max_results:5 ()) () in
  check_string "named by the adapter that served it" "querit" outcome.provider;
  check_opt_number "the free plan costs nothing" (Some 0.) outcome.cost_usd

let the_default_price_is_the_rows_figure () =
  (* The adapter default and the registry row's [default_cost] are one fact:
     the 1,000-calls-a-month free plan, with the $4/1k PAYG tier correcting it
     in config. *)
  let provider, _ = dial () in
  check_number "the free plan" 0. (Provider.cost_per_1k provider);
  let provider, _ = dial ~cost_per_1k:4.0 () in
  check_number "the PAYG tier" 4.0 (Provider.cost_per_1k provider)

let the_endpoint_is_the_one_the_grant_allows () =
  check_string "the endpoint" "https://api.querit.ai/v1/search" (Uri.to_string Querit.endpoint);
  check_string "the policy host" "api.querit.ai" Querit.policy_endpoint.Caps.Policy.host;
  check_bool "https" true (Querit.policy_endpoint.Caps.Policy.scheme = `Https);
  check_bool "the default port" true (Querit.policy_endpoint.Caps.Policy.port = None);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.Caps.Authority.Net.uri = Some Querit.policy_endpoint.Caps.Policy.host);
  (* The key rides a header, so the URL the grant confines never carries it. *)
  check_bool "no key in the URL" false
    (contains ~haystack:(Uri.to_string request.Caps.Authority.Net.uri) ~needle:test_key)

let () =
  A.(
    run "seekwright/querit"
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
            test_case "the page age is kept only when a string" `Quick
              the_page_age_is_kept_only_when_a_string;
            test_case "records without a url are dropped" `Quick records_without_a_url_are_dropped;
            test_case "records without a title are dropped" `Quick
              records_without_a_title_are_dropped;
            test_case "a record that is not an object is skipped" `Quick
              a_record_that_is_not_an_object_is_skipped;
            test_case "missing results is empty, not an error" `Quick
              missing_results_is_empty_not_an_error;
            test_case "a non-object results container is empty, not an error" `Quick
              a_non_object_results_container_is_empty_not_an_error;
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
            test_case "the query and count are sent" `Quick the_query_and_count_are_sent;
            test_case "count is clamped to the free plan cap" `Quick
              count_is_clamped_to_the_free_plan_cap;
            test_case "the domain filters ride their native fields" `Quick
              the_domain_filters_ride_their_native_fields;
            test_case "the domain fields are absent without filters" `Quick
              the_domain_fields_are_absent_without_filters;
            test_case "an include-only search sends include" `Quick an_include_only_sends_include;
            test_case "the recency maps onto timeRange.date" `Quick the_recency_maps_onto_time_range;
            test_case "the language maps onto the enum's name" `Quick
              the_language_maps_onto_the_enums_name;
            test_case "an unmappable language is dropped and noticed" `Quick
              an_unmappable_language_is_dropped_and_noticed;
            test_case "the country maps onto the enum's name" `Quick
              the_country_maps_onto_the_enums_name;
            test_case "an unmappable country is dropped and noticed" `Quick
              an_unmappable_country_is_dropped_and_noticed;
            test_case "the notice cases" `Quick the_notice_cases;
            test_case "the honoured buckets stay silent" `Quick the_honoured_buckets_stay_silent;
            test_case "never a content or vertical field" `Quick never_a_content_or_vertical_field;
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
            test_case "cost tracks the declared rate" `Quick cost_tracks_the_declared_rate;
            test_case "the result reports its flat cost" `Quick the_result_reports_its_flat_cost;
            test_case "the default price is the row's figure" `Quick
              the_default_price_is_the_rows_figure;
            test_case "the endpoint is the one the grant allows" `Quick
              the_endpoint_is_the_one_the_grant_allows;
          ] );
      ])
