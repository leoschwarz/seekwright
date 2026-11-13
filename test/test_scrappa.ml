(* Scrappa: response parsing, request shape and cost.

   Port of tests/providers/test_scrappa.py. The fixture is the documented
   [/api/search-light] payload (see docs/reference/providers.md), and the
   request-shape cases drive the adapter through a fake
   {!Seekwright.Provider.Net.t} — the position [httpx.MockTransport] holds in
   Python, and possible here for the same reason: the client is injected.

   The wiring cases from that suite ([test_built_only_when_a_key_is_present],
   the cost-correction cases through the factory) belong to the registry and
   config suites: an adapter never decides whether it is enabled. What stays
   here is the adapter's own default price, pinned against the figure the row
   builds it with. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Scrappa = Seekwright_providers.Scrappa
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

(* Never sent to anything real: the string a leak would carry. *)
let test_key = "test-key"

(* {1 The fixture}

   The search-light payload: [organic_results[]] with the four fields the
   mapping reads, and the [search_information] and [pagination] blocks it never
   touches. *)
let sample =
  {|{
  "search_information": {"total_results": 41800000},
  "organic_results": [
    {
      "position": 1,
      "title": "Write-Ahead Logging",
      "link": "https://www.sqlite.org/wal.html",
      "snippet": "The default method by which SQLite implements atomic commit is a rollback journal. Beginning with version 3.7.0 the WAL option is available."
    },
    {
      "position": 2,
      "title": "SQLite WAL mode explained",
      "link": "https://example.com/wal-explained",
      "snippet": "WAL allows readers and one writer to proceed concurrently."
    }
  ],
  "pagination": {"current": 1}
}|}

let sample_json =
  match Yojson.Safe.from_string sample with
  | `Assoc _ as json -> json
  | _ -> A.failf "the fixture is not an object"

(* {1 The seam} *)

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
  let provider = Scrappa.make ?cost_per_1k ~snippet_chars ~key:test_key ~net () in
  (provider, fun () -> Option.get !sent)

let refusal kind ~message =
  let net =
    {
      Provider.Net.request =
        (fun _ -> Error (Caps.Error.make kind ~message));
    }
  in
  Scrappa.make ~key:test_key ~net ()

let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k
    ?(query = query ()) () =
  let provider, sent = dial ~status ~body ~snippet_chars ?cost_per_1k () in
  match Provider.search provider query with
  | Ok outcome -> (outcome, sent ())
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

(* The request's query string, read the way the Python suite reads
   [request.url.params]. *)
let params (request : Caps.Authority.Net.request) = Uri.query request.uri

let param (request : Caps.Authority.Net.request) name =
  Uri.get_query_param request.uri name

let has_param request name =
  List.exists (fun (key, _) -> key = name) (params request)

(* {1 Parsing} *)

let parse ?(snippet_chars = 500) ?(limit = 10) data = Scrappa.parse ~snippet_chars data ~limit

let record fields =
  `Assoc (("title", `String "t") :: ("link", `String "https://example.com/a") :: fields)

let organic items = `Assoc [ ("organic_results", `List items) ]

let the_fixture_yields_both_records () =
  let hits = parse sample_json in
  check_int "two results" 2 (List.length hits);
  check_string "the title" "Write-Ahead Logging" (List.hd hits).result.title;
  check_string "the url" "https://www.sqlite.org/wal.html" (List.hd hits).result.url;
  check_string "the second url" "https://example.com/wal-explained"
    (List.nth hits 1).result.url

let the_limit_is_honoured () =
  check_int "one of two" 1 (List.length (parse ~limit:1 sample_json))

let the_snippet_is_truncated () =
  let hits = parse ~snippet_chars:40 sample_json in
  let snippet = Option.get (List.hd hits).result.snippet in
  check_int "cut at the cap plus the ellipsis" 41 (chars snippet);
  check_opt_int "the pre-cap length" (Some 140) (List.hd hits).uncapped_chars

let the_length_the_cap_discarded_is_recorded () =
  (* [search.cap] reads this: the pre-cap length, log-only and off the wire. *)
  let hits = parse ~snippet_chars:40 sample_json in
  let hit = List.hd hits in
  let uncapped = Option.get hit.uncapped_chars in
  check_int "the whole snippet was longer than the cap" 140 uncapped;
  check_bool "and longer than what shipped" true
    (uncapped > chars (Option.get hit.result.snippet));
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

let no_published_date_is_invented () =
  (* search-light does not report one, so the field stays empty rather than
     being guessed out of the snippet. *)
  check_opt_string "no date" None (List.hd (parse sample_json)).result.published_date;
  check_opt_number "and no score" None (List.hd (parse sample_json)).result.score

let records_without_a_link_are_dropped () =
  check_int "no link" 0
    (List.length
       (parse (`Assoc [ ("organic_results", `List [ `Assoc [ ("title", `String "No link here") ] ]) ])))

let records_without_a_title_are_dropped () =
  check_int "no title" 0
    (List.length
       (parse (`Assoc [ ("organic_results", `List [ `Assoc [ ("link", `String "https://example.com") ] ]) ])))

let a_record_that_is_not_an_object_is_skipped () =
  check_int "the string is dropped, the object survives" 1
    (List.length (parse (organic [ `String "nonsense"; record [] ])))

let missing_organic_results_is_empty_not_an_error () =
  check_int "organic_results is null" 0
    (List.length (parse (`Assoc [ ("organic_results", `Null) ])));
  check_int "organic_results is absent" 0 (List.length (parse (`Assoc [])))

(* {1 The upstream field guard}

   A non-string [snippet] is dropped, not handed to the shared truncate helper,
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

let a_non_string_snippet_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body = Yojson.Safe.to_string (organic [ record [ ("snippet", value) ] ]) in
      let outcome, _ = search_of ~body ~query:(query ~max_results:1 ()) () in
      check_int (Printf.sprintf "the call succeeded through %s" what) 1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.snippet)
    non_strings

let a_string_snippet_still_reaches_the_model () =
  (* The guard must not change behaviour for a well-formed payload. *)
  let outcome, _ = search_of ~query:(query ~max_results:1 ()) () in
  check_opt_string
    "the snippet"
    (Some
       "The default method by which SQLite implements atomic commit is a rollback \
        journal. Beginning with version 3.7.0 the WAL option is available.")
    (List.hd outcome.results).result.snippet

(* {1 The request} *)

let get_with_the_key_header_and_params () =
  let _, request = search_of ~query:(query ~text:"wal mode" ~max_results:3 ()) () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `GET);
  check_opt_string "the key header" (Some test_key)
    (List.assoc_opt "x-api-key" request.Caps.Authority.Net.headers);
  check_opt_string "the query" (Some "wal mode") (param request "query");
  check_opt_string "num follows max_results" (Some "3") (param request "num");
  (* Absent rather than empty: Scrappa reads an empty gl/hl as a value. *)
  check_bool "no gl" false (has_param request "gl");
  check_bool "no hl" false (has_param request "hl")

let num_is_clamped_to_the_endpoint_ceiling () =
  (* The tool schema caps [max_results] at 20 and this endpoint's ceiling is
     the same, but the adapter is callable directly, so the clamp lives here
     rather than being assumed. *)
  let _, request = search_of ~query:(query ~max_results:50 ()) () in
  check_opt_string "the endpoint's ceiling" (Some (string_of_int Scrappa.max_num))
    (param request "num")

let the_country_and_language_map_to_gl_and_hl () =
  let _, request = search_of ~query:(query ~text:"wal mode" ~country:"de" ~language:"de" ()) () in
  check_opt_string "gl carries the country" (Some "de") (param request "gl");
  (* Sent as given, lowercased — there is no region half to narrow away. *)
  check_opt_string "hl carries the language" (Some "de") (param request "hl")

let a_language_is_lowercased_on_the_wire () =
  let _, request = search_of ~query:(query ~language:"DE" ()) () in
  check_opt_string "hl" (Some "de") (param request "hl")

let the_recency_maps_onto_date_restrict () =
  List.iter
    (fun (period, code) ->
      let _, request = search_of ~query:(query ~recency:period ()) () in
      check_opt_string (Printf.sprintf "%s reaches dateRestrict" code) (Some code)
        (param request "dateRestrict"))
    [ (Model.Day, "d1"); (Model.Week, "w1"); (Model.Month, "m1"); (Model.Year, "y1") ];
  let _, request = search_of () in
  check_bool "unasked, no dateRestrict" false (has_param request "dateRestrict")

let safe_search_maps_onto_safe () =
  (* Both values are honoured exactly: [active] is the strongest on-state, and
     there is no partially-honoured case to word — which is why the parameter is
     a boolean rather than a level scale. *)
  List.iter
    (fun (value, wire) ->
      let outcome, request = search_of ~query:(query ~safe_search:value ()) () in
      check_opt_string (Printf.sprintf "safe=%s" wire) (Some wire) (param request "safe");
      check_opt_string "and nothing was dropped" None outcome.notice)
    [ (true, "active"); (false, "off") ]

let safe_is_omitted_when_none () =
  (* [None] sends nothing at all, so the backend's own default stands. This is
     not the same as [false]: sending [safe=off] unasked would override a
     default the caller never asked about. *)
  let _, request = search_of () in
  check_bool "no safe parameter" false (has_param request "safe")

let domain_filters_ride_in_the_query () =
  let _, request =
    search_of
      ~query:
        (query ~text:"wal mode" ~include_domains:[ "sqlite.org" ]
           ~exclude_domains:[ "spam.example" ] ())
      ()
  in
  let q = Option.get (param request "query") in
  includes "the include rides a site: operator" "site:sqlite.org" q;
  includes "the exclude is negated" "-site:spam.example" q

let the_result_reports_its_flat_cost () =
  let outcome, _ = search_of ~query:(query ~max_results:5 ()) () in
  check_string "named by the adapter that served it" "scrappa" outcome.provider;
  check_opt_number "one credit at the published price" (Some 0.0003) outcome.cost_usd

let no_constraint_notice_because_it_honours_them_all () =
  (* The one adapter that honours every bucket, so no helper call at all: the
     Google index behind it takes the domains, the country, the language, the
     date restriction and the safety flag. *)
  let outcome, _ =
    search_of
      ~query:
        (query ~include_domains:[ "sqlite.org" ] ~recency:Model.Week ~country:"de"
           ~language:"de" ~safe_search:true ())
      ()
  in
  check_opt_string "nothing dropped" None outcome.notice

(* {1 The failures this adapter owns}

   The six rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is this adapter's quota statuses
   and the leak regression that proves the redaction rule for the place its key
   actually rides. *)

let payment_and_rate_limit_are_quota () =
  (* 402 is Scrappa's x402 payment challenge; for a keyed client that means the
     credits are gone, not that the request was malformed. 429 is presumed rate
     limiting, since the limits are undocumented. *)
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:"{}" () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string "the house sentence" "rate limited or out of credits" failure.message;
          check_bool "the quota kind" true (failure.kind = Provider.Quota);
          check_bool "a spent quota is not transient" false failure.retryable)
    [ 402; 429 ]

let a_network_error_does_not_echo_the_request () =
  let provider =
    refusal Caps.Error.Denied ~message:"connection refused to x-api-key: test-key"
  in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "a refused grant was accepted"
  | Error failure ->
      check_string "the network row" "network error" failure.message;
      check_bool "the key is nowhere in the failure" false
        (contains ~haystack:(Provider.render_error failure) ~needle:test_key)

(* {1 Cost and endpoint} *)

let cost_does_not_scale_with_result_count () =
  let provider, _ = dial () in
  check_number "one query, whatever num says" 0.0003 (Provider.cost_for provider 1);
  check_number "and at the ceiling" 0.0003 (Provider.cost_for provider 20)

let it_is_cheaper_than_serper () =
  (* The reason for adopting it: same Google index, a third of the price. *)
  let provider, _ = dial () in
  check_bool "under Serper's $1.00/1k" true (Provider.cost_per_1k provider < 1.00)

let the_default_price_is_the_rows_figure () =
  (* The adapter default and the registry row's [default_cost] are one fact:
     [$0.30/1k] is what the vendor publishes, and [--check --live] prints
     whichever of the two is wrong. *)
  let provider, _ = dial () in
  check_number "the published figure" 0.30 (Provider.cost_per_1k provider);
  let provider, _ = dial ~cost_per_1k:0.15 () in
  check_number "an operator on another tier can correct it" 0.15 (Provider.cost_per_1k provider)

let the_endpoint_is_the_one_the_grant_allows () =
  check_string "the endpoint" "https://scrappa.co/api/search-light"
    (Uri.to_string Scrappa.endpoint);
  check_string "the policy host" "scrappa.co" Scrappa.policy_endpoint.Caps.Policy.host;
  check_bool "https" true (Scrappa.policy_endpoint.Caps.Policy.scheme = `Https);
  check_bool "the default port" true (Scrappa.policy_endpoint.Caps.Policy.port = None);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.Caps.Authority.Net.uri = Some Scrappa.policy_endpoint.Caps.Policy.host);
  (* The key rides a header, so the URL the grant confines never carries it. *)
  check_bool "no key in the URL" false
    (contains ~haystack:(Uri.to_string request.Caps.Authority.Net.uri) ~needle:test_key)

let () =
  A.
    (run "seekwright/scrappa"
       [
         ( "parsing",
             [
               test_case "the live fixture yields both records" `Quick the_fixture_yields_both_records;
               test_case "the limit is honoured" `Quick the_limit_is_honoured;
               test_case "the snippet is truncated" `Quick the_snippet_is_truncated;
               test_case "the length the cap discarded is recorded" `Quick
                 the_length_the_cap_discarded_is_recorded;
               test_case "a short snippet reports its own length" `Quick
                 a_short_snippet_reports_its_own_length;
               test_case "no published date is invented" `Quick no_published_date_is_invented;
               test_case "records without a link are dropped" `Quick records_without_a_link_are_dropped;
               test_case "records without a title are dropped" `Quick
                 records_without_a_title_are_dropped;
               test_case "a record that is not an object is skipped" `Quick
                 a_record_that_is_not_an_object_is_skipped;
               test_case "missing organic_results is empty, not an error" `Quick
                 missing_organic_results_is_empty_not_an_error;
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
               test_case "GET with the key header and params" `Quick
                 get_with_the_key_header_and_params;
               test_case "num is clamped to the endpoint ceiling" `Quick
                 num_is_clamped_to_the_endpoint_ceiling;
               test_case "the country and language map to gl and hl" `Quick
                 the_country_and_language_map_to_gl_and_hl;
               test_case "a language is lowercased on the wire" `Quick
                 a_language_is_lowercased_on_the_wire;
               test_case "the recency maps onto dateRestrict" `Quick
                 the_recency_maps_onto_date_restrict;
               test_case "safe-search maps onto safe" `Quick safe_search_maps_onto_safe;
               test_case "safe is omitted when none" `Quick safe_is_omitted_when_none;
               test_case "the domain filters ride in the query" `Quick domain_filters_ride_in_the_query;
               test_case "the result reports its flat cost" `Quick
                 the_result_reports_its_flat_cost;
               test_case "no constraint notice because it honours them all" `Quick
                 no_constraint_notice_because_it_honours_them_all;
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
               test_case "it is cheaper than serper" `Quick it_is_cheaper_than_serper;
               test_case "the default price is the row's figure" `Quick
                 the_default_price_is_the_rows_figure;
               test_case "the endpoint is the one the grant allows" `Quick
                 the_endpoint_is_the_one_the_grant_allows;
             ] );
       ])
