(* Linkup: the two payload shapes, the one date computation in the adapter
   inventory, and the quota row this name answers differently.

   The endpoint answers in one of two shapes, and which one it uses decides
   where the prose lives, which list holds the material, and {i how} the result
   cap is applied: [sourcedAnswer] slices [sources[]] before anything is
   dropped, because that list arrives already sized for the answer the endpoint
   wrote, while [searchResults] walks until [limit] usable rows are collected,
   because an image row on an index page should not cost the caller a result it
   asked for. That asymmetry is invisible from the wire and is what the two parse
   suites pin separately.

   [fromDate] is the only date arithmetic an adapter does, so the clock is
   injected and every date assertion here names the instant it is true of — the
   oracle computes its windows from the wall clock and pins no date at all. The
   day counts are fixed (30-day months, 365-day years) because recency is
   "published within the last {i n}", open-ended, with no [toDate] to agree a
   calendar boundary with.

   The request-shape cases drive the adapter through a fake
   {!Seekwright.Provider.Net.t} — the position [httpx.MockTransport] holds in
   Python. Linkup has no geo, language or safety parameter at all, so its geo
   bucket is the joined [country/language] token the default exists for.

   The wiring cases from that suite belong to the registry and config suites: an
   adapter never decides whether it is enabled. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Linkup = Seekwright_providers.Linkup
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

(* Never sent to anything real: the string a leak would carry. *)
let test_key = "test-key"

(* The list accessors, so a missing record fails with its label rather than
   [Stdlib.Failure("hd")]. *)
let hd label = function
  | x :: _ -> x
  | [] -> A.failf "%s was empty" label

let nth label index xs =
  match List.nth_opt xs index with
  | Some x -> x
  | None -> A.failf "%s has no item %d" label index

(* The instant every date assertion below is true of: 2023-11-14T22:13:20Z. The
   oracle reads the wall clock, so a ported date has to name its own. *)
let fixed_now = 1_700_000_000.

(* The [sourcedAnswer] payload: the prose, and the [sources[]] citations that
   carry it. [favicon] is upstream's and never reaches the model. *)
let sample =
  {|{
  "answer": "WAL lets readers proceed while one writer commits.",
  "sources": [
    {
      "name": "Write-Ahead Logging",
      "url": "https://www.sqlite.org/wal.html",
      "favicon": "https://www.sqlite.org/favicon.ico",
      "snippet": "The default method by which SQLite implements atomic commit is a rollback journal."
    },
    {
      "name": "SQLite WAL mode explained",
      "url": "https://example.com/wal-explained",
      "snippet": "WAL allows readers and one writer to proceed concurrently."
    }
  ]
}|}

let sample_json =
  match Yojson.Safe.from_string sample with
  | `Assoc _ as json -> json
  | _ -> A.failf "the fixture is not an object"

(* A {!Seekwright.Provider.Net.t} that records what was dialed and answers with a
   canned response. Every request-shape case is
   [let provider, sent = dial () in …; let request = sent ()]. *)
let dial ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k
    ?(depth = "standard") ?(output = Linkup.Sourced_answer) () =
  let sent = ref None in
  let net =
    {
      Provider.Net.request =
        (fun request ->
          sent := Some request;
          Ok { Caps.Authority.Net.status; headers = []; body });
    }
  in
  let provider =
    Linkup.make ?cost_per_1k ~snippet_chars ~depth ~output ~key:test_key
      ~now:(fun () -> fixed_now) ~net ()
  in
  (provider, fun () -> Option.get !sent)

let refusal kind ~message =
  let net =
    {
      Provider.Net.request = (fun _ -> Error (Caps.Error.make kind ~message));
    }
  in
  Linkup.make ~key:test_key ~now:(fun () -> fixed_now) ~net ()

let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k
    ?depth ?output ?(query = query ()) () =
  let provider, sent =
    dial ~status ~body ~snippet_chars ?cost_per_1k ?depth ?output ()
  in
  match Provider.search provider query with
  | Ok outcome -> (outcome, sent ())
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

(* The body the adapter wrote, decoded. *)
let body_of (request : Caps.Authority.Net.request) =
  match request.Caps.Authority.Net.body with
  | Some text -> Yojson.Safe.from_string text
  | None -> A.failf "the request carried no body"

let body_field name request =
  match Provider.Json.field name (body_of request) with
  | `String value -> Some value
  | `Int value -> Some (string_of_int value)
  | `Bool value -> Some (string_of_bool value)
  | `Float value -> Some (string_of_float value)
  | `Null -> None
  | other -> Some (Yojson.Safe.to_string other)

let has_body_field name request =
  match Provider.Json.members (body_of request) with
  | Some fields -> List.mem_assoc name fields
  | None -> false

let sources ?(snippet_chars = 500) ?(limit = 10) data =
  Linkup.parse_sources ~snippet_chars data ~limit

let source fields =
  `Assoc (("name", `String "t") :: ("url", `String "https://example.com/a") :: fields)

let the_citations_become_results () =
  let hits = sources (`Assoc [ ("sources", `List [ source []; source [ ("url", `String "https://example.com/wal-explained") ] ]) ]) in
  check_int "two results" 2 (List.length hits);
  check_string "the name is the title" "Write-Ahead Logging"
    (hd "results" (sources sample_json)).result.title;
  check_string "the url" "https://www.sqlite.org/wal.html"
    (hd "results" (sources sample_json)).result.url;
  check_string "the second url" "https://example.com/wal-explained"
    (nth "results" 1 (sources sample_json)).result.url

let a_citation_without_a_name_is_titled_by_its_url () =
  let hits = sources (`Assoc [ ("sources", `List [ `Assoc [ ("url", `String "https://example.com/a"); ("snippet", `String "s") ] ]) ]) in
  check_string "the url stands in for the name" "https://example.com/a"
    (hd "results" hits).result.title

let citations_without_a_url_are_dropped () =
  check_int "no url" 0
    (List.length (sources (`Assoc [ ("sources", `List [ `Assoc [ ("name", `String "no url") ] ]) ])))

let a_citation_that_is_not_an_object_is_skipped () =
  check_int "the string is dropped, the object survives" 1
    (List.length (sources (`Assoc [ ("sources", `List [ `String "nonsense"; source [] ]) ])))

let missing_sources_is_empty_not_an_error () =
  check_int "sources is null" 0 (List.length (sources (`Assoc [ ("sources", `Null) ])));
  check_int "sources is absent" 0 (List.length (sources (`Assoc [])))

let the_limit_slices_the_citation_list_before_filtering () =
  (* The slice is upstream's job: [sources] arrives sized for the answer the
     endpoint wrote, so a row the adapter drops still spends a slot. *)
  let payload =
    `Assoc
      [
        ( "sources"
        , `List
            [
              `Assoc [ ("name", `String "no url") ];
              source [ ("url", `String "https://example.com/kept") ];
            ] );
      ]
  in
  check_int "the unusable row spent the only slot" 0 (List.length (sources ~limit:1 payload));
  check_int "two slots keep it" 1 (List.length (sources ~limit:2 payload))

let results ?(snippet_chars = 500) ?(limit = 10) data =
  Linkup.parse_results ~snippet_chars data ~limit

let result_row ?(url = "https://example.com/a") fields =
  `Assoc (("name", `String "t") :: ("url", `String url) :: fields)

let results_fill_snippet_and_never_text () =
  let hits =
    results
      (`Assoc
         [
           ( "results"
           , `List [ result_row [ ("content", `String "The default method.") ] ] );
         ])
  in
  let hit = hd "results" hits in
  check_opt_string "content becomes the snippet" (Some "The default method.")
    hit.result.snippet;
  check_opt_string "text is never filled" None hit.result.text

let image_rows_are_skipped_and_the_walk_keeps_going () =
  (* No slice on this branch: the walk runs until [limit] usable rows, so an
     image row costs the caller nothing. *)
  let payload =
    `Assoc
      [
        ( "results"
        , `List
            [
              result_row [ ("type", `String "image") ];
              result_row ~url:"https://example.com/one" [];
              result_row ~url:"https://example.com/two" [];
            ] );
      ]
  in
  check_int "the image row costs no slot" 2 (List.length (results ~limit:2 payload));
  check_string "and the walk stopped at the cap" "https://example.com/one"
    (hd "results" (results ~limit:1 payload)).result.url

let a_row_without_a_name_is_titled_by_its_url () =
  let hits =
    results
      (`Assoc
         [
           ( "results"
           , `List [ `Assoc [ ("url", `String "https://example.com/unnamed") ] ] );
         ])
  in
  check_string "the url stands in for the name" "https://example.com/unnamed"
    (hd "results" hits).result.title

let missing_results_is_empty_not_an_error () =
  check_int "results is null" 0 (List.length (results (`Assoc [ ("results", `Null) ])));
  check_int "results is absent" 0 (List.length (results (`Assoc [])))

let the_answer_reaches_the_caller () =
  let outcome, _ = search_of () in
  check_opt_string "the prose rides through"
    (Some "WAL lets readers proceed while one writer commits.")
    outcome.answer

let the_other_shape_promises_no_answer () =
  (* A payload that carries [answer] anyway is not a field the caller was
     offered: [searchResults] is a list, and the answer stays unset whatever the
     body holds. *)
  let outcome, _ =
    search_of ~output:Linkup.Search_results
      ~body:{|{"results":[{"name":"t","url":"https://example.com/a","content":"c"}],"answer":"unasked prose"}|}
      ()
  in
  check_opt_string "no answer from a shape that has none" None outcome.answer;
  check_int "and the list still parses" 1 (List.length outcome.results)

let the_answer_is_read_from_the_key_the_shape_uses () =
  check_opt_string "sourcedAnswer reads answer" (Some "p")
    (Linkup.answer ~output:Linkup.Sourced_answer
       (`Assoc [ ("sourcedAnswer", `String "ignored"); ("answer", `String "p") ]));
  check_opt_string "searchResults reads none" None
    (Linkup.answer ~output:Linkup.Search_results (`Assoc [ ("answer", `String "p") ]))

(* A non-string [answer], [snippet] or [content] is dropped, not handed to the
   wire model or to the truncate helper. The payload is untrusted: the fields are
   documented as strings, and a shape drift must not turn into an internal error
   that escapes the engine's provider-error handling. The call has to succeed
   with the field dropped, exactly as the sibling adapters drop a non-string. *)

let non_strings =
  [
    ("a nested object", `Assoc [ ("nested", `String "object") ]);
    ("a list", `List [ `String "a"; `String "b" ]);
    ("a number", `Int 7);
  ]

let a_non_string_answer_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body =
        Yojson.Safe.to_string
          (`Assoc
             [
               ("answer", value);
               ( "sources"
               , `List [ source [ ("snippet", `String "The default method.") ] ] );
             ])
      in
      let outcome, _ = search_of ~body () in
      check_opt_string what None outcome.answer;
      check_bool "the citations still parse" true (outcome.results <> []))
    non_strings

let a_non_string_citation_snippet_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body =
        Yojson.Safe.to_string
          (`Assoc [ ("sources", `List [ source [ ("snippet", value) ] ]) ])
      in
      let outcome, _ = search_of ~body () in
      check_int "the citation survives" 1 (List.length outcome.results);
      check_opt_string what None (hd "results" outcome.results).result.snippet)
    non_strings

let a_non_string_result_content_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body =
        Yojson.Safe.to_string
          (`Assoc
             [
               ( "results"
               , `List [ result_row [ ("content", value); ("type", `String "text") ] ] );
             ])
      in
      let outcome, _ = search_of ~output:Linkup.Search_results ~body () in
      check_int "the row survives" 1 (List.length outcome.results);
      check_opt_string what None (hd "results" outcome.results).result.snippet)
    non_strings

let a_string_answer_still_reaches_the_model () =
  (* The guard must not change behaviour for a well-formed payload. *)
  let outcome, _ = search_of () in
  check_opt_string
    "the answer"
    (Some "WAL lets readers proceed while one writer commits.")
    outcome.answer

let a_string_snippet_still_reaches_the_model () =
  let outcome, _ = search_of () in
  check_opt_string
    "the snippet"
    (Some
       "The default method by which SQLite implements atomic commit is a rollback \
        journal.")
    (hd "results" outcome.results).result.snippet

let post_to_the_search_endpoint_with_the_bearer_token () =
  let _, request = search_of ~query:(query ~text:"wal mode" ~max_results:3 ()) () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `POST);
  check_string "the URI" (Uri.to_string Linkup.endpoint)
    (Uri.to_string request.Caps.Authority.Net.uri);
  check_opt_string "the credential rides Authorization as a bearer token"
    (Some "Bearer test-key")
    (List.assoc_opt "Authorization" request.Caps.Authority.Net.headers);
  check_opt_string "and a JSON body needs its content type" (Some "application/json")
    (List.assoc_opt "Content-Type" request.Caps.Authority.Net.headers);
  check_opt_string "the query" (Some "wal mode") (body_field "q" request);
  check_opt_string "maxResults follows max_results" (Some "3")
    (body_field "maxResults" request)

let the_key_never_rides_the_url () =
  let _, request = search_of () in
  check_bool "the URI names no key" false
    (contains ~haystack:(Uri.to_string request.Caps.Authority.Net.uri) ~needle:test_key);
  check_bool "and no key in the query" true
    (Uri.query request.Caps.Authority.Net.uri = [])

let the_settings_decide_the_payload_shape () =
  (* [depth] and [output_type] are the two operator settings, and both are on the
     wire: [depth] is the ~10x cost cliff and [outputType] is the shape that buys
     the prose. Neither is a tool parameter. *)
  let _, request = search_of ~depth:"deep" () in
  check_opt_string "depth" (Some "deep") (body_field "depth" request);
  check_opt_string "the answer-shaped output" (Some "sourcedAnswer")
    (body_field "outputType" request);
  let _, request = search_of ~output:Linkup.Search_results () in
  check_opt_string "the list-shaped output" (Some "searchResults")
    (body_field "outputType" request)

let max_results_reaches_the_request_verbatim () =
  (* The wire model owns [max_results]'s bounds, and the adapter passes the
     number straight through: [maxResults] is what sizes the vendor's own answer,
     and the parse cap is the guarantee the caller reads. *)
  let _, request = search_of ~query:(query ~max_results:3 ()) () in
  check_opt_string "carried as asked" (Some "3") (body_field "maxResults" request);
  let _, request = search_of ~query:(query ~max_results:20 ()) () in
  check_opt_string "and at the schema ceiling" (Some "20")
    (body_field "maxResults" request)

let the_recency_windows_are_fixed_day_counts () =
  check_int "day" 1 (Linkup.age_days Model.Day);
  check_int "week" 7 (Linkup.age_days Model.Week);
  check_int "month" 30 (Linkup.age_days Model.Month);
  check_int "year" 365 (Linkup.age_days Model.Year);
  (* 30-day months and 365-day years, not calendar ones: recency is "published
     within the last n", open-ended, and there is no [toDate] to agree a month
     boundary with. *)
  check_int "a month is thirty days whatever the month" 30 (Linkup.age_days Model.Month)

let utc_is_the_format_the_endpoint_documents () =
  check_string "the injected instant" "2023-11-14T22:13:20Z" (Linkup.format_utc fixed_now);
  check_string "the epoch" "1970-01-01T00:00:00Z" (Linkup.format_utc 0.);
  check_string "across a leap day" "2024-02-29T00:00:00Z" (Linkup.format_utc 1_709_164_800.)

let fromDate_is_the_window_from_the_adapters_own_clock () =
  List.iter
    (fun (period, date, word) ->
      let _, request = search_of ~query:(query ~recency:period ()) () in
      check_opt_string
        (Printf.sprintf "%s reaches fromDate" word)
        (Some date)
        (body_field "fromDate" request))
    [
      (Model.Day, "2023-11-13T22:13:20Z", "day");
      (Model.Week, "2023-11-07T22:13:20Z", "week");
      (Model.Month, "2023-10-15T22:13:20Z", "month");
      (Model.Year, "2022-11-14T22:13:20Z", "year");
    ];
  (* Unasked, no window: a default [fromDate] would narrow the search unasked. *)
  let _, request = search_of () in
  check_bool "no fromDate" false (has_body_field "fromDate" request)

let the_domain_filters_are_native () =
  let _, request =
    search_of
      ~query:
        (query ~include_domains:[ "sqlite.org" ] ~exclude_domains:[ "spam.example" ] ())
      ()
  in
  check_opt_string "includeDomains is the vendor's own spelling" (Some "[\"sqlite.org\"]")
    (body_field "includeDomains" request);
  check_opt_string "excludeDomains likewise" (Some "[\"spam.example\"]")
    (body_field "excludeDomains" request)

let the_geo_bucket_is_reported_joined () =
  (* No geo parameter and no language parameter at all, so neither half of the
     bucket is honoured and the token stays joined — which is the case
     [Provider.ignored_constraints]'s default exists for. *)
  let _, request = search_of ~query:(query ~country:"de" ~language:"de" ()) () in
  check_bool "no gl" false (has_body_field "gl" request);
  check_bool "no language" false (has_body_field "language" request);
  let outcome, _ = search_of ~query:(query ~country:"de" ~language:"de" ()) () in
  check_string "the joined bucket"
    "cannot filter by country/language; that constraint was ignored"
    (Option.get outcome.notice)

let a_language_alone_is_reported_joined () =
  let outcome, _ = search_of ~query:(query ~language:"de" ()) () in
  check_string "still the joined bucket"
    "cannot filter by country/language; that constraint was ignored"
    (Option.get outcome.notice)

let a_safe_search_is_noticed_for_both_values () =
  List.iter
    (fun value ->
      let _, request = search_of ~query:(query ~safe_search:value ()) () in
      check_bool "no safe_search" false (has_body_field "safe_search" request);
      let outcome, _ = search_of ~query:(query ~safe_search:value ()) () in
      check_string "the safe-search sentence"
        "cannot filter by safe-search; that constraint was ignored"
        (Option.get outcome.notice))
    [ true; false ]

let an_unconstrained_query_carries_no_notice () =
  let outcome, _ = search_of () in
  check_opt_string "nothing dropped" None outcome.notice

let the_domains_and_the_window_draw_no_notice () =
  (* Domains and [fromDate] are native here, so the two buckets that stay are
     exactly the two with no parameter behind them. *)
  let outcome, _ =
    search_of
      ~query:
        (query ~include_domains:[ "sqlite.org" ] ~recency:Model.Week ())
      ()
  in
  check_opt_string "no notice at all when nothing unasked is dropped" None outcome.notice

(* The rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is this adapter's quota row, which
   is narrower than the widened house row: Linkup's own error table reads "429 -
   Too Many Requests: You have run out of credit or you are sending too many
   concurrent requests", so 429 here is the vendor's spent-credit status and not
   a guess. Its 402 row is the x402 payment lane, a surface this adapter never
   enters because it always sends the Bearer key — which is why this name keeps
   402 off the quota rung where [scrappa], [tinyfish] and [anysearch] read it. *)

let the_rate_limit_is_the_spent_credit_status () =
  let provider, _ = dial ~status:429 ~body:{|{"detail":"Too Many Requests"}|} () in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "HTTP 429 was accepted"
  | Error failure ->
      check_string "the house sentence" "rate limited (10 QPS org-wide)" failure.message;
      check_bool "the quota kind" true (failure.kind = Provider.Quota);
      check_bool "a spent quota is not transient" false failure.retryable

let the_payment_lane_stays_an_ordinary_http_failure () =
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:{|{"detail":"no"}|} () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string (Printf.sprintf "HTTP %d says the status" status)
            (Printf.sprintf "HTTP %d" status)
            failure.message;
          check_bool "and is not quota" true (failure.kind = Provider.Failure))
    [ 400; 402; 504 ]

let a_body_that_quotes_the_key_is_not_echoed () =
  let body =
    Printf.sprintf "<html>upstream echoed %s on a payment page</html>" test_key
  in
  let provider, _ = dial ~status:402 ~body () in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "HTTP 402 was accepted"
  | Error failure ->
      check_bool "the vendor's page is not quoted" false
        (contains ~haystack:(Provider.render_error failure) ~needle:test_key)

let a_network_failure_does_not_echo_the_request () =
  let provider =
    refusal Caps.Error.Denied ~message:"connection refused to Authorization: Bearer test-key"
  in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "a refused grant was accepted"
  | Error failure ->
      check_string "the network row" "network error" failure.message;
      check_bool "nothing about the request rides along" false
        (contains ~haystack:(Provider.render_error failure) ~needle:test_key)

let the_cost_is_flat_per_call () =
  (* Linkup bills the request, so [max_results] never scales the figure, and
     [depth] — the ~10x cliff — is the operator's setting rather than a number
     the adapter can multiply. *)
  check_number "one call" 0.006 (Linkup.cost_for ~cost_per_1k:6.0 1);
  check_number "and the same call at twenty results" 0.006 (Linkup.cost_for ~cost_per_1k:6.0 20)

let the_result_carries_the_flat_figure () =
  let outcome, _ = search_of ~query:(query ~max_results:20 ()) () in
  check_string "named by the adapter that served it" "linkup" outcome.provider;
  check_opt_number "one call, not twenty" (Some 0.006) outcome.cost_usd

let the_default_price_is_the_rows_figure () =
  let provider, _ = dial () in
  check_number "the published figure" 6.00 (Provider.cost_per_1k provider)

let an_operator_corrected_cost_reaches_the_adapter () =
  let provider, _ = dial ~cost_per_1k:0.50 () in
  check_number "the corrected figure" 0.50 (Provider.cost_per_1k provider);
  check_number "and its per-call reading" 0.0005 (Provider.cost_for provider 1)

let the_snippet_cap_follows_the_policy () =
  let body =
    Yojson.Safe.to_string
      (`Assoc [ ("sources", `List [ source [ ("snippet", `String (String.make 40 'x')) ] ]) ])
  in
  let outcome, _ = search_of ~snippet_chars:10 ~body () in
  let hit = hd "results" outcome.results in
  check_opt_string "clipped with the ellipsis" (Some (String.make 10 'x' ^ "…"))
    hit.result.snippet;
  check_bool "the pre-cap length is reported" true
    (hit.uncapped_chars = Some 40)

let the_endpoint_is_the_one_the_grant_allows () =
  check_string "the endpoint" "https://api.linkup.so/v1/search"
    (Uri.to_string Linkup.endpoint);
  check_string "the policy host" "api.linkup.so" Linkup.policy_endpoint.Caps.Policy.host;
  check_bool "https" true (Linkup.policy_endpoint.Caps.Policy.scheme = `Https);
  check_bool "the default port" true (Linkup.policy_endpoint.Caps.Policy.port = None);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.Caps.Authority.Net.uri = Some Linkup.policy_endpoint.Caps.Policy.host)

let () =
  A.
    (run "seekwright/linkup"
       [
         ( "parsing the citation list"
         , [
             test_case "the citations become results" `Quick
               the_citations_become_results;
             test_case "a citation without a name is titled by its url" `Quick
               a_citation_without_a_name_is_titled_by_its_url;
             test_case "citations without a url are dropped" `Quick
               citations_without_a_url_are_dropped;
             test_case "a citation that is not an object is skipped" `Quick
               a_citation_that_is_not_an_object_is_skipped;
             test_case "missing sources is empty, not an error" `Quick
               missing_sources_is_empty_not_an_error;
             test_case "the limit slices the citation list before filtering" `Quick
               the_limit_slices_the_citation_list_before_filtering;
           ] );
         ( "parsing the result list"
         , [
             test_case "results fill snippet and never text" `Quick
               results_fill_snippet_and_never_text;
             test_case "image rows are skipped and the walk keeps going" `Quick
               image_rows_are_skipped_and_the_walk_keeps_going;
             test_case "a row without a name is titled by its url" `Quick
               a_row_without_a_name_is_titled_by_its_url;
             test_case "missing results is empty, not an error" `Quick
               missing_results_is_empty_not_an_error;
           ] );
         ( "the answer follows the shape"
         , [
             test_case "the answer reaches the caller" `Quick the_answer_reaches_the_caller;
             test_case "the other shape promises no answer" `Quick
               the_other_shape_promises_no_answer;
             test_case "the answer is read from the key the shape uses" `Quick
               the_answer_is_read_from_the_key_the_shape_uses;
           ] );
         ( "the upstream field guards"
         , [
             test_case "a non-string answer is dropped and the call succeeds" `Quick
               a_non_string_answer_is_dropped_and_the_call_succeeds;
             test_case "a non-string citation snippet is dropped and the call succeeds" `Quick
               a_non_string_citation_snippet_is_dropped_and_the_call_succeeds;
             test_case "a non-string result content is dropped and the call succeeds" `Quick
               a_non_string_result_content_is_dropped_and_the_call_succeeds;
             test_case "a string answer still reaches the model" `Quick
               a_string_answer_still_reaches_the_model;
             test_case "a string snippet still reaches the model" `Quick
               a_string_snippet_still_reaches_the_model;
           ] );
         ( "the request"
         , [
             test_case "POST to the search endpoint, bearer token in the header" `Quick
               post_to_the_search_endpoint_with_the_bearer_token;
             test_case "the key never rides the URL" `Quick the_key_never_rides_the_url;
             test_case "the settings decide the payload shape" `Quick
               the_settings_decide_the_payload_shape;
             test_case "maxResults reaches the request verbatim" `Quick
               max_results_reaches_the_request_verbatim;
             test_case "the domain filters are native" `Quick the_domain_filters_are_native;
           ] );
         ( "the date computation"
         , [
             test_case "the recency windows are fixed day counts" `Quick
               the_recency_windows_are_fixed_day_counts;
             test_case "UTC is the format the endpoint documents" `Quick
               utc_is_the_format_the_endpoint_documents;
             test_case "fromDate is the window from the adapter's own clock" `Quick
               fromDate_is_the_window_from_the_adapters_own_clock;
           ] );
         ( "the constraint report"
         , [
             test_case "the geo bucket is reported joined" `Quick
               the_geo_bucket_is_reported_joined;
             test_case "a language alone is reported joined" `Quick
               a_language_alone_is_reported_joined;
             test_case "a safe-search is noticed for both values" `Quick
               a_safe_search_is_noticed_for_both_values;
             test_case "an unconstrained query carries no notice" `Quick
               an_unconstrained_query_carries_no_notice;
             test_case "the domains and the window draw no notice" `Quick
               the_domains_and_the_window_draw_no_notice;
           ] );
         ( "the failures this adapter owns"
         , [
             test_case "the rate limit is the spent-credit status" `Quick
               the_rate_limit_is_the_spent_credit_status;
             test_case "the payment lane stays an ordinary HTTP failure" `Quick
               the_payment_lane_stays_an_ordinary_http_failure;
             test_case "a body that quotes the key is not echoed" `Quick
               a_body_that_quotes_the_key_is_not_echoed;
             test_case "a network failure does not echo the request" `Quick
               a_network_failure_does_not_echo_the_request;
           ] );
         ( "cost and endpoint"
         , [
             test_case "the cost is flat per call" `Quick the_cost_is_flat_per_call;
             test_case "the result carries the flat figure" `Quick
               the_result_carries_the_flat_figure;
             test_case "the default price is the row's figure" `Quick
               the_default_price_is_the_rows_figure;
             test_case "an operator-corrected cost reaches the adapter" `Quick
               an_operator_corrected_cost_reaches_the_adapter;
             test_case "the snippet cap follows the policy" `Quick
               the_snippet_cap_follows_the_policy;
             test_case "the endpoint is the one the grant allows" `Quick
               the_endpoint_is_the_one_the_grant_allows;
           ] );
       ])
