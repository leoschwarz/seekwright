(* Tavily: the content-style payload, the closed country enum, the request body,
   and the one constraint drop that is per-call rather than per-adapter.

   Tavily is a content backend, so [results[].content] becomes [Result.text] and
   [snippet] stays empty — filling both would ship the same prose twice, with the
   snippet as a prefix of the extract. That makes the text cap the one that
   matters here, and [text_truncated] the flag that tells a caller whether it is
   reading a whole page or the front of one.

   The country enum is the part of this adapter that cannot be read off the
   request surface: [country] is ISO alpha-2 in the tool schema and a closed list
   of English names at the vendor, so the mapping is asserted in both directions
   and an unmappable value is pinned as {i}omitted from the body and named in the
   notice — never sent upstream to be ignored there. The geo bucket splits per
   call for the same reason: [language] rides [language] on the very same request,
   so a notice that named both halves would be wrong about one of them.

   One row of the Python suite has no port. [usage.credits] becomes a private
   [_reported_cost_usd] on the oracle's [ProviderResult] and reaches only the
   cost-drift diff in [--check --live]; [Seekwright.Provider.outcome] has no
   private field to carry it and the wire model must not grow one, so the ask
   stays on the request ([include_usage] is pinned) and the reported figure is the
   one field this port leaves uncarried. The pin here is that the ask is on the
   wire and the flat cost is what the caller sees.

   The wiring cases from that suite belong to the registry and config suites: an
   adapter never decides whether it is enabled. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Tavily = Seekwright_providers.Tavily
module A = Alcotest
open Test_support

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

(* The documented payload: [answer] prose, [results[]] with an inline extract,
   the vendor's [response_time] envelope, and the [usage] block whose credits this
   port does not carry. *)
let sample =
  {|{
  "answer": "WAL lets readers proceed while one writer commits.",
  "results": [
    {
      "title": "Write-Ahead Logging",
      "url": "https://www.sqlite.org/wal.html",
      "content": "The default method by which SQLite implements atomic commit is a rollback journal. Beginning with version 3.7.0 the WAL option is available.",
      "score": 0.94,
      "published_date": "2024-11-03"
    },
    {
      "title": "SQLite WAL mode explained",
      "url": "https://example.com/wal-explained",
      "content": "WAL allows readers and one writer to proceed concurrently.",
      "score": 0.81
    }
  ],
  "response_time": 1.2
}|}

let sample_json =
  match Yojson.Safe.from_string sample with
  | `Assoc _ as json -> json
  | _ -> A.failf "the fixture is not an object"

(* A {!Seekwright.Provider.Net.t} that records what was dialed and answers with a
   canned response — the position [httpx.MockTransport] holds in Python. *)
let dial ?(status = 200) ?(body = sample) ?(text_chars = 2000) ?cost_per_1k () =
  let sent = ref None in
  let net =
    {
      Provider.Net.request =
        (fun request ->
          sent := Some request;
          Ok { Caps.Authority.Net.status; headers = []; body });
    }
  in
  let provider = Tavily.make ?cost_per_1k ~text_chars ~key:test_key ~net () in
  (provider, fun () -> Option.get !sent)

let refusal kind ~message =
  let net = { Provider.Net.request = (fun _ -> Error (Caps.Error.make kind ~message)) } in
  Tavily.make ~key:test_key ~net ()

let search_of ?(status = 200) ?(body = sample) ?(text_chars = 2000) ?cost_per_1k ?(query = query ())
    () =
  let provider, sent = dial ~status ~body ~text_chars ?cost_per_1k () in
  match Provider.search provider query with
  | Ok outcome -> (outcome, sent ())
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

let check_opt_bool label expected actual = A.(check (option bool)) label expected actual

(* An extract of a known length and no sentence boundary inside the cap, so the
   [search.cap] figure the adapter reports can be asserted as a number. *)
let long_content = String.concat " " (List.init 30 (fun _ -> "word"))

(* The body the adapter wrote, decoded: the request is a JSON document, so the
   shape assertions read a document rather than a query string. *)
let body_of (request : Caps.Authority.Net.request) =
  match request.Caps.Authority.Net.body with
  | Some text -> Yojson.Safe.from_string text
  | None -> A.failf "the request carried no body"

let body_field name request =
  match Provider.Json.field name (body_of request) with
  | `String value -> Some value
  | `Int value -> Some (string_of_int value)
  | `Null -> None
  | other -> Some (Yojson.Safe.to_string other)

let has_body_field name request =
  match Provider.Json.members (body_of request) with
  | Some fields -> List.mem_assoc name fields
  | None -> false

let body_list name request =
  match Provider.Json.field name (body_of request) with
  | `List items -> List.filter_map (fun item -> Provider.Json.string item) items
  | _ -> []

let parse ?(text_chars = 2000) ?(limit = 10) data = Tavily.parse ~text_chars data ~limit

let record fields =
  `Assoc (("title", `String "t") :: ("url", `String "https://example.com/a") :: fields)

let results items = `Assoc [ ("results", `List items) ]

let the_fixture_yields_both_records () =
  let hits = parse sample_json in
  check_int "two results" 2 (List.length hits);
  check_string "the title" "Write-Ahead Logging" (List.hd hits).result.title;
  check_string "the url" "https://www.sqlite.org/wal.html" (List.hd hits).result.url;
  check_string "the second url" "https://example.com/wal-explained" (List.nth hits 1).result.url

let the_limit_is_honoured () = check_int "one of two" 1 (List.length (parse ~limit:1 sample_json))

let a_content_record_fills_text_and_never_snippet () =
  (* Filling both would ship the same prose twice, the snippet as a prefix of the
     extract. *)
  let hits = parse sample_json in
  check_bool "the extract is kept" true ((List.hd hits).result.text <> None);
  check_opt_string "snippet is never filled" None (List.hd hits).result.snippet

let the_text_is_capped_and_the_cut_is_flagged () =
  let hits = parse ~text_chars:20 (results [ record [ ("content", `String long_content) ] ]) in
  let hit = List.hd hits in
  let text = Option.get hit.result.text in
  check_bool "the extract got shorter" true (String.length text < String.length long_content);
  check_opt_bool "and the cut is flagged for the caller" (Some true) hit.result.text_truncated;
  (* The length the cap discarded is counts, not content, and it rides beside the
     result rather than on it: [search.cap] reads it, the wire model never sees it. *)
  check_opt_int "the pre-cap length is measured" (Some 149) hit.uncapped_chars

let a_short_page_is_not_flagged_as_cut () =
  let hits = parse ~text_chars:40 (results [ record [ ("content", `String "short.") ] ]) in
  let hit = List.hd hits in
  check_opt_bool "nothing was cut" None hit.result.text_truncated;
  check_opt_string "and the page arrives whole" (Some "short.") hit.result.text;
  check_opt_int "with its length measured anyway" (Some 6) hit.uncapped_chars

let the_score_and_published_date_are_kept_when_present () =
  let hits = parse sample_json in
  check_opt_number "the relevance number" (Some 0.94) (List.hd hits).result.score;
  check_opt_string "the declared date" (Some "2024-11-03") (List.hd hits).result.published_date;
  check_opt_string "the record without one" None (List.nth hits 1).result.published_date

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

(* A non-string [content] is dropped, not handed to the shared truncate helper,
   which split on whitespace in whatever upstream sent: an [AttributeError] there
   escaped the engine's provider-error handling as an internal error rather than
   being dropped the way every sibling drops a non-string. [answer] has the same
   guard for the same reason — it goes to the wire model, where a nested object
   would have failed validation outright. *)

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
      check_int
        (Printf.sprintf "the call succeeded through %s" what)
        1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.text;
      check_opt_bool "nothing was cut" None (List.hd outcome.results).result.text_truncated)
    non_strings

let a_string_content_still_reaches_the_model () =
  (* The guard must not change behaviour for a well-formed payload. *)
  let outcome, _ = search_of ~query:(query ~max_results:1 ()) () in
  check_opt_string "the extract"
    (Some
       "The default method by which SQLite implements atomic commit is a rollback journal. \
        Beginning with version 3.7.0 the WAL option is available.")
    (List.hd outcome.results).result.text;
  check_opt_bool "and it was not cut" None (List.hd outcome.results).result.text_truncated

let a_non_string_answer_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let fields = Option.get (Provider.Json.members sample_json) in
      let body = Yojson.Safe.to_string (`Assoc (("answer", value) :: fields)) in
      let outcome, _ = search_of ~body () in
      check_opt_string what None outcome.answer;
      check_bool "the results still parse" true (outcome.results <> []))
    non_strings

let the_answer_reaches_the_caller () =
  let outcome, _ = search_of () in
  check_opt_string "the vendor's prose, which the [search] tool returns as [answer]"
    (Some "WAL lets readers proceed while one writer commits.") outcome.answer

let post_to_the_search_endpoint_with_a_bearer_token () =
  let _, request = search_of ~query:(query ~text:"wal mode" ~max_results:3 ()) () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `POST);
  check_string "the URI" (Uri.to_string Tavily.endpoint)
    (Uri.to_string request.Caps.Authority.Net.uri);
  check_opt_string "the key is a bearer token" (Some "Bearer test-key")
    (List.assoc_opt "Authorization" request.Caps.Authority.Net.headers);
  check_opt_string "and a JSON body needs its content type" (Some "application/json")
    (List.assoc_opt "Content-Type" request.Caps.Authority.Net.headers);
  check_opt_string "the query" (Some "wal mode") (body_field "query" request);
  check_opt_string "depth is pinned" (Some "basic") (body_field "search_depth" request);
  check_opt_string "max_results follows the request" (Some "3") (body_field "max_results" request);
  check_opt_string "the vendor's answer is asked for" (Some "basic")
    (body_field "include_answer" request);
  check_opt_string "raw page content is not" (Some "false")
    (body_field "include_raw_content" request)

let include_usage_is_asked_for () =
  (* The oracle reads the credits this asks for; the port has no channel for the
     figure, but the request stays the same one the vendor documents. *)
  let _, request = search_of () in
  check_opt_string "include_usage" (Some "true") (body_field "include_usage" request)

let the_key_never_rides_the_url () =
  (* The credential is a header, so no URL that reaches a log line or a failure
     message can carry it. *)
  let _, request = search_of () in
  check_bool "the URI names no key" false
    (contains ~haystack:(Uri.to_string request.Caps.Authority.Net.uri) ~needle:test_key);
  check_bool "and no key in the query" true (Uri.query request.Caps.Authority.Net.uri = [])

let the_query_goes_verbatim_and_the_domains_are_native () =
  (* Native [include_domains] and [exclude_domains] fields exist, so folding
     [site:] into the query would only degrade Tavily's own matching. *)
  let _, request =
    search_of
      ~query:
        (query ~text:"wal mode" ~include_domains:[ "sqlite.org" ]
           ~exclude_domains:[ "spam.example" ] ())
      ()
  in
  check_opt_string "no site: operators in the query" (Some "wal mode") (body_field "query" request);
  check_strings "the include list" [ "sqlite.org" ] (body_list "include_domains" request);
  check_strings "the exclude list" [ "spam.example" ] (body_list "exclude_domains" request)

let domain_fields_absent_without_filters () =
  let _, request = search_of () in
  check_bool "no include_domains" false (has_body_field "include_domains" request);
  check_bool "no exclude_domains" false (has_body_field "exclude_domains" request)

let recency_maps_onto_time_range () =
  List.iter
    (fun (period, word) ->
      let _, request = search_of ~query:(query ~recency:period ()) () in
      check_opt_string
        (Printf.sprintf "%s reaches time_range" word)
        (Some word) (body_field "time_range" request))
    [ (Model.Day, "day"); (Model.Week, "week"); (Model.Month, "month"); (Model.Year, "year") ];
  (* Unasked, the parameter is absent: Tavily's own default stands. *)
  let _, request = search_of () in
  check_bool "no time_range" false (has_body_field "time_range" request)

let the_language_is_lowercased () =
  let _, request = search_of ~query:(query ~language:"DE" ()) () in
  check_opt_string "language" (Some "de") (body_field "language" request);
  let _, request = search_of () in
  check_bool "and absent when unasked" false (has_body_field "language" request)

let safe_search_both_values_reach_the_wire () =
  (* A boolean parameter, so both values are honoured exactly and neither is
     noticed — and the depth the vendor's own caveat depends on is pinned at
     [basic] in the same body. *)
  List.iter
    (fun (value, spelling) ->
      let _, request = search_of ~query:(query ~safe_search:value ()) () in
      check_opt_string "safe_search" (Some spelling) (body_field "safe_search" request);
      check_opt_string "the depth the caveat depends on" (Some "basic")
        (body_field "search_depth" request))
    [ (true, "true"); (false, "false") ]

let safe_search_is_omitted_when_unasked () =
  (* [None] sends nothing, so Tavily's default stands. Not the same as [false]:
     an unasked-for off state would be a request the caller never made. *)
  let _, request = search_of () in
  check_bool "no safe_search" false (has_body_field "safe_search" request)

let a_country_name_passes_through () =
  let _, request = search_of ~query:(query ~country:"Switzerland" ()) () in
  check_opt_string "the enum's own word, lowercased" (Some "switzerland")
    (body_field "country" request);
  let outcome, _ = search_of ~query:(query ~country:"Switzerland" ()) () in
  check_opt_string "and no notice" None outcome.notice

let a_country_code_maps_onto_the_enum_name () =
  let _, request = search_of ~query:(query ~country:"DE" ()) () in
  check_opt_string "the code becomes the name" (Some "germany") (body_field "country" request)

let the_aliases_the_enum_omits_are_mapped () =
  (* [uk] and [usa] are what callers write and what the vendor enum does not
     list; [gb] and [us] are the ISO codes that are in it. *)
  List.iter
    (fun (code, name) ->
      check_opt_string
        (Printf.sprintf "%s maps onto %s" code name)
        (Some name) (Tavily.country_param code))
    [
      ("uk", "united kingdom");
      ("usa", "united states");
      ("gb", "united kingdom");
      ("us", "united states");
      ("cd", "congo");
      ("cg", "congo");
    ]

let an_unmappable_country_is_omitted_from_the_body () =
  let _, request = search_of ~query:(query ~country:"atlantis" ()) () in
  check_bool "no country parameter" false (has_body_field "country" request);
  check_bool "and nothing is guessed from the shape of the value" true
    (Tavily.country_param "atlantis" = None)

let the_enum_covers_the_codes_the_surface_sends () =
  (* The map is vendor data, and a reader checking it against the API reference
     should find the two Congo codes sharing one entry rather than a typo. *)
  check_int "the enum's entry count" 169 (List.length Tavily.country_by_code);
  check_bool "the two Congo codes are both present" true
    (List.mem_assoc "cg" Tavily.country_by_code && List.mem_assoc "cd" Tavily.country_by_code)

let an_unmappable_country_is_noticed_alone () =
  (* Only the country was dropped; [language] carries its half of the geo bucket
     on the very same request, so the joined [country/language] token would be
     wrong about one half of what it names. *)
  let outcome, _ = search_of ~query:(query ~country:"atlantis" ()) () in
  check_string "the country half" "cannot filter by country; that constraint was ignored"
    (Option.get outcome.notice);
  let outcome, _ = search_of ~query:(query ~country:"atlantis" ~language:"de" ()) () in
  check_string "and still only the country half beside a language"
    "cannot filter by country; that constraint was ignored" (Option.get outcome.notice)

let a_mappable_country_and_language_draw_no_notice () =
  let outcome, _ = search_of ~query:(query ~country:"DE" ~language:"de" ()) () in
  check_opt_string "both halves are sent" None outcome.notice

let an_unconstrained_query_carries_no_notice () =
  let outcome, _ = search_of () in
  check_opt_string "nothing dropped" None outcome.notice

let the_honoured_buckets_draw_no_notice () =
  (* Domains, [time_range], [country], [language] and [safe_search] are all native,
     so a fully constrained query is the case with no notice at all. *)
  let outcome, _ =
    search_of
      ~query:
        (query ~include_domains:[ "sqlite.org" ] ~country:"DE" ~language:"de" ~recency:Model.Week
           ~safe_search:true ())
      ()
  in
  check_opt_string "no notice at all" None outcome.notice

(* The six rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is this adapter's quota pair: 432 is
   Tavily's own monthly-credits-exhausted code and 429 its short-term rate limit,
   and both are the same month's quota question, so both are non-retryable. *)

let rate_limit_and_exhausted_credits_are_quota () =
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:sample () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string "the house sentence" "rate limited or out of credits" failure.message;
          check_bool "the quota kind" true (failure.kind = Provider.Quota);
          check_bool "a spent quota is not transient" false failure.retryable)
    [ 429; 432 ]

let a_payment_status_is_not_read_as_quota () =
  (* Tavily does not answer 402; the contract's [>= 400] row is what a surprise
     status deserves, and inventing a quota reading for it would bench this name
     on the health board for a status its billing model never emits. *)
  let provider, _ = dial ~status:402 ~body:"{}" () in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "HTTP 402 was accepted"
  | Error failure ->
      check_string "the generic row" "HTTP 402" failure.message;
      check_bool "not quota" true (failure.kind = Provider.Failure)

let a_body_that_quotes_the_key_is_not_echoed () =
  let body = Printf.sprintf "<html>upstream echoed %s on a credits page</html>" test_key in
  let provider, _ = dial ~status:432 ~body () in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "HTTP 432 was accepted"
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

let the_cost_does_not_scale_with_result_count () =
  (* A basic search is one credit whatever the result count, so the flat figure is
     the billed one at [max_results=1] and at the schema ceiling alike. *)
  let provider, _ = dial () in
  check_number "one credit at one result" 0.008 (Provider.cost_for provider 1);
  check_number "the same credit at five" 0.008 (Provider.cost_for provider 5);
  check_number "and at the schema ceiling" 0.008 (Provider.cost_for provider 20)

let the_result_carries_the_flat_figure () =
  let outcome, _ = search_of ~query:(query ~max_results:20 ()) () in
  check_string "named by the adapter that served it" "tavily" outcome.provider;
  check_opt_number "one credit, not twenty" (Some 0.008) outcome.cost_usd

let the_default_price_is_the_rows_figure () =
  (* The adapter default and the registry row's [default_cost] are one fact:
     [$0.008 a credit] is what Tavily publishes, and [--check --live] prints
     whichever of the two is wrong. *)
  let provider, _ = dial () in
  check_number "the published figure" 8.00 (Provider.cost_per_1k provider)

let an_operator_corrected_cost_reaches_the_adapter () =
  let provider, _ = dial ~cost_per_1k:4.00 () in
  check_number "the corrected figure" 4.00 (Provider.cost_per_1k provider);
  check_number "and its per-query reading" 0.004 (Provider.cost_for provider 5)

let the_text_cap_follows_the_value_the_factory_passes () =
  (* [policy.max_result_text_chars] reaches the adapter as [text_chars], so the cap
     the operator sets is the cap the extract is cut at — and a wider value leaves
     the same extract whole. *)
  let tight, _ = search_of ~text_chars:40 ~query:(query ~max_results:1 ()) () in
  check_opt_bool "cut at forty codepoints" (Some true) (List.hd tight.results).result.text_truncated;
  let loose, _ = search_of ~text_chars:2000 ~query:(query ~max_results:1 ()) () in
  check_opt_bool "whole at two thousand" None (List.hd loose.results).result.text_truncated

let the_endpoint_is_the_one_the_grant_allows () =
  check_string "the endpoint" "https://api.tavily.com/search" (Uri.to_string Tavily.endpoint);
  check_string "the policy host" "api.tavily.com" Tavily.policy_endpoint.Caps.Policy.host;
  check_bool "https" true (Tavily.policy_endpoint.Caps.Policy.scheme = `Https);
  check_bool "the default port" true (Tavily.policy_endpoint.Caps.Policy.port = None);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.Caps.Authority.Net.uri = Some Tavily.policy_endpoint.Caps.Policy.host)

let () =
  A.(
    run "seekwright/tavily"
      [
        ( "parsing",
          [
            test_case "the live fixture yields both records" `Quick the_fixture_yields_both_records;
            test_case "the limit is honoured" `Quick the_limit_is_honoured;
            test_case "a content record fills text and never snippet" `Quick
              a_content_record_fills_text_and_never_snippet;
            test_case "the text is capped and the cut is flagged" `Quick
              the_text_is_capped_and_the_cut_is_flagged;
            test_case "a short page is not flagged as cut" `Quick a_short_page_is_not_flagged_as_cut;
            test_case "the score and published_date are kept when present" `Quick
              the_score_and_published_date_are_kept_when_present;
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
            test_case "a non-string answer is dropped and the call succeeds" `Quick
              a_non_string_answer_is_dropped_and_the_call_succeeds;
            test_case "the answer reaches the caller" `Quick the_answer_reaches_the_caller;
          ] );
        ( "the request",
          [
            test_case "POST to the search endpoint, bearer token in the header" `Quick
              post_to_the_search_endpoint_with_a_bearer_token;
            test_case "include_usage is asked for" `Quick include_usage_is_asked_for;
            test_case "the key never rides the URL" `Quick the_key_never_rides_the_url;
            test_case "the query goes verbatim and the domains are native" `Quick
              the_query_goes_verbatim_and_the_domains_are_native;
            test_case "domain fields absent without filters" `Quick
              domain_fields_absent_without_filters;
            test_case "recency maps onto time_range" `Quick recency_maps_onto_time_range;
            test_case "the language is lowercased" `Quick the_language_is_lowercased;
            test_case "safe-search reaches the wire for both values" `Quick
              safe_search_both_values_reach_the_wire;
            test_case "safe-search is omitted when unasked" `Quick
              safe_search_is_omitted_when_unasked;
          ] );
        ( "the closed country enum",
          [
            test_case "a country name passes through" `Quick a_country_name_passes_through;
            test_case "a country code maps onto the enum name" `Quick
              a_country_code_maps_onto_the_enum_name;
            test_case "the aliases the enum omits are mapped" `Quick
              the_aliases_the_enum_omits_are_mapped;
            test_case "an unmappable country is omitted from the body" `Quick
              an_unmappable_country_is_omitted_from_the_body;
            test_case "the enum covers the codes the surface sends" `Quick
              the_enum_covers_the_codes_the_surface_sends;
          ] );
        ( "the constraint report",
          [
            test_case "an unmappable country is noticed alone" `Quick
              an_unmappable_country_is_noticed_alone;
            test_case "a mappable country and language draw no notice" `Quick
              a_mappable_country_and_language_draw_no_notice;
            test_case "an unconstrained query carries no notice" `Quick
              an_unconstrained_query_carries_no_notice;
            test_case "the honoured buckets draw no notice" `Quick
              the_honoured_buckets_draw_no_notice;
          ] );
        ( "the failures this adapter owns",
          [
            test_case "the rate limit and exhausted credits are quota" `Quick
              rate_limit_and_exhausted_credits_are_quota;
            test_case "a payment status is not read as quota" `Quick
              a_payment_status_is_not_read_as_quota;
            test_case "the body behind the quota status is not echoed" `Quick
              a_body_that_quotes_the_key_is_not_echoed;
            test_case "a network failure does not echo the request" `Quick
              a_network_failure_does_not_echo_the_request;
          ] );
        ( "cost, cap and endpoint",
          [
            test_case "the cost does not scale with result count" `Quick
              the_cost_does_not_scale_with_result_count;
            test_case "the result carries the flat figure" `Quick the_result_carries_the_flat_figure;
            test_case "the default price is the row's figure" `Quick
              the_default_price_is_the_rows_figure;
            test_case "an operator-corrected cost reaches the adapter" `Quick
              an_operator_corrected_cost_reaches_the_adapter;
            test_case "the text cap follows the value the factory passes" `Quick
              the_text_cap_follows_the_value_the_factory_passes;
            test_case "the endpoint is the one the grant allows" `Quick
              the_endpoint_is_the_one_the_grant_allows;
          ] );
      ])
