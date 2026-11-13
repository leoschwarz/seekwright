(* Serper: response parsing, the guard on upstream field shapes, the request
   body, and the one constraint the adapter cannot honour.

   Port of tests/providers/test_serper.py. Serper is a raw SERP backend —
   [organic[]] records carry a [snippet] and a [date], both documented as
   strings — but nothing upstream enforces that. A nested object, list or
   number in [date] used to reach [Result.published_date] unguarded in the
   oracle, and the same shape in [snippet] raised out of the shared truncate
   helper; neither was a provider error, so both escaped the engine's handling
   as an internal error rather than being dropped the way every sibling drops a
   non-string. [the_upstream_field_guards] pins both guards; the parsing cases
   pin that a well-formed payload is unchanged.

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

   The [organic[]] payload: the fields the mapping reads, and the [credits]
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

let sample_json =
  match Yojson.Safe.from_string sample with
  | `Assoc _ as json -> json
  | _ -> A.failf "the fixture is not an object"

(* {1 The seam}

   A {!Seekwright.Provider.Net.t} that records what was dialed and answers with
   a canned response. Every request-shape case is
   [let provider, sent = dial () in …; let request = sent ()]. *)
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
  let provider =
    Serper.make ?cost_per_1k ~snippet_chars ~key:test_key ~net ()
  in
  (provider, fun () -> Option.get !sent)

let refusal kind ~message =
  let net =
    {
      Provider.Net.request =
        (fun _ -> Error (Caps.Error.make kind ~message));
    }
  in
  Serper.make ~key:test_key ~net ()

(* The adapter, driven: [search_of ()] answers with the fixture and hands back
   both the outcome and the request that was dialed. *)
let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k
    ?(query = query ()) () =
  let provider, sent = dial ~status ~body ~snippet_chars ?cost_per_1k () in
  match Provider.search provider query with
  | Ok outcome -> (outcome, sent ())
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

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

(* {1 Parsing} *)

let parse ?(snippet_chars = 500) ?(limit = 10) data = Serper.parse ~snippet_chars data ~limit

let record fields =
  `Assoc (("title", `String "t") :: ("link", `String "https://example.com/a") :: fields)

let organic items = `Assoc [ ("organic", `List items) ]

let the_fixture_yields_both_records () =
  let hits = parse sample_json in
  check_int "two results" 2 (List.length hits);
  check_string "the title" "Write-Ahead Logging" (List.hd hits).result.title;
  check_string "the url" "https://www.sqlite.org/wal.html" (List.hd hits).result.url;
  check_string "the second url" "https://example.com/wal-explained"
    (List.nth hits 1).result.url

let the_limit_is_honoured () =
  check_int "one of two" 1 (List.length (parse ~limit:1 sample_json))

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
    (List.length (parse (`Assoc [ ("organic", `List [ `Assoc [ ("title", `String "No url here") ] ]) ])))

let records_without_a_title_are_dropped () =
  check_int "no title" 0
    (List.length (parse (`Assoc [ ("organic", `List [ `Assoc [ ("link", `String "https://example.com") ] ]) ])))

let a_record_that_is_not_an_object_is_skipped () =
  check_int "the string is dropped, the object survives" 1
    (List.length (parse (organic [ `String "nonsense"; record [] ])))

let missing_organic_is_empty_not_an_error () =
  check_int "organic is null" 0 (List.length (parse (`Assoc [ ("organic", `Null) ])));
  check_int "organic is absent" 0 (List.length (parse (`Assoc [])))

(* {1 The upstream field guards}

   A non-string [date] or [snippet] is dropped, not handed to the wire model or
   to the truncate helper. The payload is untrusted: the fields are documented
   as strings, and a shape drift must not turn into an internal error that
   escapes the engine's provider-error handling. The call has to succeed with
   the field dropped, exactly as the sibling adapters drop a non-string. *)

let non_strings =
  [ ("a nested object", `Assoc [ ("nested", `String "object") ]); ("a list", `List [ `String "a"; `String "b" ]); ("a number", `Int 7) ]

let a_non_string_date_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body = Yojson.Safe.to_string (organic [ record [ ("date", value) ] ]) in
      let outcome, _ = search_of ~body ~query:(query ~max_results:1 ()) () in
      check_int (Printf.sprintf "the call succeeded through %s" what) 1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.published_date)
    non_strings

let a_non_string_snippet_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body = Yojson.Safe.to_string (organic [ record [ ("snippet", value) ] ]) in
      let outcome, _ = search_of ~body ~query:(query ~max_results:1 ()) () in
      check_int (Printf.sprintf "the call succeeded through %s" what) 1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.snippet)
    non_strings

let a_string_date_still_reaches_the_model () =
  (* The guard must not change behaviour for a well-formed payload. *)
  let outcome, _ = search_of ~query:(query ~max_results:1 ()) () in
  check_opt_string "the date" (Some "2024-11-03")
    (List.hd outcome.results).result.published_date

let a_string_snippet_still_reaches_the_model () =
  let outcome, _ = search_of ~query:(query ~max_results:1 ()) () in
  check_opt_string
    "the snippet"
    (Some
       "The default method by which SQLite implements atomic commit is a rollback journal.")
    (List.hd outcome.results).result.snippet

(* {1 The request} *)

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
  check_bool "and no key in the query" true
    (Uri.query request.Caps.Authority.Net.uri = [])

let the_country_reaches_gl_and_the_recency_reaches_tbs () =
  List.iter
    (fun (period, code) ->
      let _, request =
        search_of ~query:(query ~country:"de" ~recency:period ()) ()
      in
      check_opt_string "gl carries the country" (Some "de") (body_field "gl" request);
      check_opt_string (Printf.sprintf "%s reaches tbs" code) (Some code)
        (body_field "tbs" request))
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

(* {1 The constraint report} *)

let a_safe_search_is_noticed_for_both_values () =
  List.iter
    (fun value ->
      let outcome, _ = search_of ~query:(query ~safe_search:value ()) () in
      check_string "the safe-search sentence"
        "cannot filter by safe-search; that constraint was ignored"
        (Option.get outcome.notice))
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
        (query ~include_domains:[ "sqlite.org" ] ~country:"de" ~language:"de"
           ~recency:Model.Week ())
      ()
  in
  check_opt_string "no notice at all when safe-search is unasked" None outcome.notice

(* {1 The failures this adapter owns}

   The six rows every HTTP adapter owes are pinned once for all of them by
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
    refusal Caps.Error.Denied ~message:"connection refused to X-API-KEY: test-key"
  in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "a refused grant was accepted"
  | Error failure ->
      check_string "the network row" "network error" failure.message;
      check_bool "nothing about the request rides along" false
        (contains ~haystack:(Provider.render_error failure) ~needle:test_key)

(* {1 Cost and endpoint} *)

let the_cost_doubles_past_ten_results () =
  (* "2 credits for more than 10 results" is the published rule, and the flat
     [cost_per_1k /. 1000.] reading would under-report a 20-result search by
     half. *)
  check_number "one credit at the threshold" 0.001 (Provider.cost_for (fst (dial ())) Serper.credit_over);
  check_number "two credits past it" 0.002 (Provider.cost_for (fst (dial ())) (Serper.credit_over + 1));
  check_number "the schema ceiling is two credits" 0.002 (Provider.cost_for (fst (dial ())) 20)

let the_result_carries_the_credit_figure () =
  let outcome, _ = search_of ~query:(query ~max_results:20 ()) () in
  check_string "named by the adapter that served it" "serper" outcome.provider;
  check_opt_number "two credits, not one" (Some 0.002) outcome.cost_usd

let the_default_price_is_the_rows_figure () =
  (* The adapter default and the registry row's [default_cost] are one fact:
     [$1.00/1k] is what Serper publishes, and [--check --live] prints whichever
     of the two is wrong. *)
  let provider, _ = dial () in
  check_number "the published figure" 1.00 (Provider.cost_per_1k provider)

let an_operator_corrected_cost_reaches_the_adapter () =
  let provider, _ = dial ~cost_per_1k:0.50 () in
  check_number "the corrected figure" 0.50 (Provider.cost_per_1k provider);
  check_number "and its per-query reading at one credit" 0.0005 (Provider.cost_for provider 10);
  check_number "and at two" 0.001 (Provider.cost_for provider 11)

let the_endpoint_is_the_one_the_grant_allows () =
  check_string "the endpoint" "https://google.serper.dev/search" (Uri.to_string Serper.endpoint);
  check_string "the policy host" "google.serper.dev" Serper.policy_endpoint.Caps.Policy.host;
  check_bool "https" true (Serper.policy_endpoint.Caps.Policy.scheme = `Https);
  check_bool "the default port" true (Serper.policy_endpoint.Caps.Policy.port = None);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.Caps.Authority.Net.uri = Some Serper.policy_endpoint.Caps.Policy.host)

let () =
  A.
    (run "seekwright/serper"
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
               test_case "the cost doubles past ten results" `Quick
                 the_cost_doubles_past_ten_results;
               test_case "the result carries the credit figure" `Quick
                 the_result_carries_the_credit_figure;
               test_case "the default price is the row's figure" `Quick
                 the_default_price_is_the_rows_figure;
               test_case "an operator-corrected cost reaches the adapter" `Quick
                 an_operator_corrected_cost_reaches_the_adapter;
               test_case "the endpoint is the one the grant allows" `Quick
                 the_endpoint_is_the_one_the_grant_allows;
             ] );
       ])
