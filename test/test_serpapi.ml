(* SerpAPI: response parsing, request shape, redaction and cost.

   The fixture is the documented [/search] payload: [organic_results[]] with
   [position], [title], [link], [snippet] and an optional display [date]
   ("Sep 20, 2018"), beside [search_metadata] and the other element families
   that are dropped.

   Two facts shape the tests here. The API key rides in the query string — the
   operator's documented shape, which diverges from this tree's header
   convention — so the request URL is a secret surface, and the redaction cases
   assert no failure path can echo it. And the adapter is shipped untested, so
   these hermetic cases are the whole coverage that exists.

   The wiring cases from that suite belong to the registry and config suites;
   what stays here is the adapter's own default price — the free plan's zero —
   pinned against the figure the row builds it with. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Serpapi = Seekwright_providers.Serpapi
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

(* The documented payload: the ranked list beside [search_metadata],
   [search_information] and the [answer_box] sibling — the element families the
   parse drops rather than models. *)
let sample =
  {|{
  "search_metadata": {"id": "61afb3ace7d08a685b3bcbb1", "status": "Success"},
  "search_information": {
    "organic_results_state": "Results for exact spelling",
    "query_displayed": "coffee",
    "total_results": 1340000000
  },
  "answer_box": {
    "title": "Coffee",
    "answer": "Coffee is a brewed drink prepared from roasted coffee beans."
  },
  "organic_results": [
    {
      "position": 1,
      "title": "Coffee - Wikipedia",
      "link": "https://en.wikipedia.org/wiki/Coffee",
      "displayed_link": "https://en.wikipedia.org > wiki > Coffee",
      "snippet": "Coffee is a brewed drink prepared from roasted coffee beans, the seeds of berries of certain flowering plants.",
      "date": "Sep 20, 2018"
    },
    {
      "position": 2,
      "title": "Is coffee good for you?",
      "link": "https://time.com/4768860/is-coffee-good-for-you/",
      "snippet": "Coffee is one of the world's most popular beverages."
    }
  ]
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
  let provider = Serpapi.make ?cost_per_1k ~snippet_chars ~key:test_key ~net () in
  (provider, fun () -> Option.get !sent)

let refusal kind ~message =
  let net = { Provider.Net.request = (fun _ -> Error (Caps.Error.make kind ~message)) } in
  Serpapi.make ~key:test_key ~net ()

let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k
    ?(query = query ~text:"coffee" ()) () =
  let provider, sent = dial ~status ~body ~snippet_chars ?cost_per_1k () in
  match Provider.search provider query with
  | Ok outcome -> (outcome, sent ())
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

(* The request's query string, read the way the Python suite reads
   [request.url.params]. *)
let params (request : Caps.Authority.Net.request) = Uri.query request.uri

let param (request : Caps.Authority.Net.request) name = Uri.get_query_param request.uri name

let has_param request name = List.exists (fun (key, _) -> key = name) (params request)

let parse ?(snippet_chars = 500) ?(limit = 10) data = Serpapi.parse ~snippet_chars data ~limit

let record fields = `Assoc (("title", `String "t") :: ("link", `String "https://x") :: fields)

let organic items = `Assoc [ ("organic_results", `List items) ]

let the_fixture_yields_both_records () =
  let hits = parse sample_json in
  check_int "two results" 2 (List.length hits);
  check_string "the title" "Coffee - Wikipedia" (List.hd hits).result.title;
  check_string "the url" "https://en.wikipedia.org/wiki/Coffee" (List.hd hits).result.url;
  check_string "the second url" "https://time.com/4768860/is-coffee-good-for-you/"
    (List.nth hits 1).result.url

let the_limit_is_honoured () = check_int "one of two" 1 (List.length (parse ~limit:1 sample_json))

let the_snippet_is_kept_and_never_text () =
  (* A SERP backend fills snippet, never text. *)
  let hit = List.hd (parse sample_json) in
  check_bool "the snippet is there" true (hit.result.snippet <> None);
  check_opt_string "and no text" None hit.result.text

let the_snippet_is_truncated () =
  let hits = parse ~snippet_chars:40 sample_json in
  let snippet = Option.get (List.hd hits).result.snippet in
  check_int "cut at the cap plus the ellipsis" 41 (chars snippet);
  check_opt_int "the pre-cap length" (Some 110) (List.hd hits).uncapped_chars

let the_length_the_cap_discarded_is_recorded () =
  (* [search.cap] reads this: the pre-cap length, log-only and off the wire. *)
  let hits = parse ~snippet_chars:40 sample_json in
  let hit = List.hd hits in
  let uncapped = Option.get hit.uncapped_chars in
  check_int "the whole snippet was longer than the cap" 110 uncapped;
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

let the_display_date_is_kept_only_when_a_string () =
  (* The documented [date] is a display string, omitted per record, so nothing
     is invented. *)
  let hits = parse sample_json in
  check_opt_string "the fixture's date" (Some "Sep 20, 2018") (List.hd hits).result.published_date;
  check_opt_string "and its absence" None (List.nth hits 1).result.published_date

let records_without_a_link_are_dropped () =
  check_int "no link" 0
    (List.length
       (parse
          (`Assoc [ ("organic_results", `List [ `Assoc [ ("title", `String "No link here") ] ]) ])))

let records_without_a_title_are_dropped () =
  check_int "no title" 0
    (List.length
       (parse
          (`Assoc
             [ ("organic_results", `List [ `Assoc [ ("link", `String "https://example.com") ] ]) ])))

let a_record_that_is_not_an_object_is_skipped () =
  check_int "the string is dropped, the object survives" 1
    (List.length (parse (organic [ `String "nonsense"; record [] ])))

let missing_organic_results_is_empty_not_an_error () =
  check_int "organic_results is null" 0
    (List.length (parse (`Assoc [ ("organic_results", `Null) ])));
  check_int "organic_results is absent" 0 (List.length (parse (`Assoc [])))

let the_other_element_families_are_dropped () =
  (* [answer_box] and the like are the documented payload's siblings of
     [organic_results]; the adapter reads the ranked list and nothing else. *)
  let hits = parse sample_json in
  check_int "the two ranked records, no answer box" 2 (List.length hits);
  List.iter
    (fun (hit : Provider.hit) ->
      excludes "no answer_box on the wire model" "answer_box"
        (Yojson.Safe.to_string (Model.result_to_yojson hit.result)))
    hits

(* A non-string [snippet] or [date] is dropped, not handed to the shared
   truncate helper: shape drift must read as a missing field, not raise out of
   the engine's provider-error handling. *)

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
      let outcome, _ = search_of ~body ~query:(query ~text:"q" ~max_results:1 ()) () in
      check_int
        (Printf.sprintf "the call succeeded through %s" what)
        1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.published_date)
    non_strings

let a_non_string_snippet_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body = Yojson.Safe.to_string (organic [ record [ ("snippet", value) ] ]) in
      let outcome, _ = search_of ~body ~query:(query ~text:"q" ~max_results:1 ()) () in
      check_int
        (Printf.sprintf "the call succeeded through %s" what)
        1 (List.length outcome.results);
      check_opt_string what None (List.hd outcome.results).result.snippet)
    non_strings

let a_string_snippet_still_reaches_the_model () =
  (* The guard must not change behaviour for a well-formed payload. *)
  let outcome, _ = search_of ~query:(query ~text:"q" ~max_results:1 ()) () in
  check_opt_string "the snippet"
    (Some
       "Coffee is a brewed drink prepared from roasted coffee beans, the seeds of berries of \
        certain flowering plants.")
    (List.hd outcome.results).result.snippet

(* Every constraint rides a documented parameter — [site:] operators in [q],
   [gl], [hl], [tbs] and [safe] — so all five buckets are honoured and the
   notice stays [None] whatever the caller asked for. What the cases below pin
   is what is never sent: fields that would change the billing or the response
   shape of a call this deployment has already priced. *)

let gets_to_the_documented_endpoint () =
  let _, request = search_of () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `GET);
  let uri = request.Caps.Authority.Net.uri in
  check_bool "the endpoint" true (Uri.host uri = Some "serpapi.com" && Uri.path uri = "/search");
  check_bool "no Authorization header" true
    (List.assoc_opt "Authorization" request.Caps.Authority.Net.headers = None)

let the_key_rides_in_the_query_string () =
  (* The documented shape — and the reason the redaction rule is a standing
     gotcha, not a one-off: the URL itself is the secret. *)
  let _, request = search_of () in
  check_opt_string "api_key" (Some test_key) (param request "api_key")

let the_query_and_engine_are_sent () =
  let _, request = search_of () in
  check_opt_string "q" (Some "coffee") (param request "q");
  check_opt_string "engine" (Some "google") (param request "engine")

let the_domain_filters_fold_into_the_query () =
  let _, request =
    search_of
      ~query:
        (query ~text:"coffee" ~include_domains:[ "sqlite.org" ] ~exclude_domains:[ "spam.example" ]
           ())
      ()
  in
  check_opt_string "q carries the operators" (Some "coffee site:sqlite.org -site:spam.example")
    (param request "q")

let the_country_rides_gl () =
  let _, request = search_of ~query:(query ~text:"coffee" ~country:"de" ()) () in
  check_opt_string "gl" (Some "de") (param request "gl");
  let _, request = search_of () in
  check_bool "and absent without a country" false (has_param request "gl")

let the_language_is_lowercased_on_the_wire () =
  let outcome, request = search_of ~query:(query ~text:"coffee" ~language:"DE" ()) () in
  check_opt_string "hl" (Some "de") (param request "hl");
  (* Language is honoured, so a language-only constraint carries no notice. *)
  check_opt_string "no notice" None outcome.notice;
  let _, request = search_of () in
  check_bool "and absent without a language" false (has_param request "hl")

let the_recency_maps_onto_tbs () =
  List.iter
    (fun (period, code) ->
      let _, request = search_of ~query:(query ~text:"coffee" ~recency:period ()) () in
      check_opt_string (Printf.sprintf "tbs=%s" code) (Some code) (param request "tbs"))
    [ (Model.Day, "qdr:d"); (Model.Week, "qdr:w"); (Model.Month, "qdr:m"); (Model.Year, "qdr:y") ];
  let _, request = search_of () in
  check_bool "unasked, no tbs" false (has_param request "tbs")

let safe_search_maps_onto_safe () =
  List.iter
    (fun (value, wire) ->
      let _, request = search_of ~query:(query ~text:"coffee" ~safe_search:value ()) () in
      check_opt_string (Printf.sprintf "safe=%s" wire) (Some wire) (param request "safe"))
    [ (true, "active"); (false, "off") ];
  (* And absent when unset: [None] sends neither, which is not the same as
     asking for no filter. *)
  let _, request = search_of () in
  check_bool "no safe parameter" false (has_param request "safe")

let never_a_shape_or_billing_field () =
  (* [output] would change the body to HTML or markdown and break the parse;
     [json_restrictor] would trim the fields the parse reads; [device],
     [start] and [timeout] are choices this deployment makes for its operators,
     not the caller's, and [num] is not in the documented parameter set. None
     of them may appear in a query string at all. *)
  let _, request =
    search_of
      ~query:
        (query ~text:"coffee" ~max_results:20 ~include_domains:[ "sqlite.org" ]
           ~exclude_domains:[ "spam.example" ] ~language:"en" ~recency:Model.Day ~country:"de"
           ~safe_search:true ())
      ()
  in
  List.iter
    (fun field ->
      check_bool (Printf.sprintf "no %s in the query string" field) false (has_param request field))
    [ "output"; "json_restrictor"; "device"; "start"; "num"; "timeout" ]

let the_notice_stays_none_for_every_shape_of_ask () =
  (* An unconstrained query carries no notice... *)
  let outcome, _ = search_of () in
  check_opt_string "unconstrained" None outcome.notice;
  (* ...and so does a fully constrained one: every bucket is honoured, the
     contrast with the sibling adapters, whose dropped halves name themselves
     here. *)
  let outcome, _ =
    search_of
      ~query:
        (query ~text:"coffee" ~include_domains:[ "sqlite.org" ] ~exclude_domains:[ "spam.example" ]
           ~language:"de" ~country:"fr" ~recency:Model.Week ~safe_search:true ())
      ()
  in
  check_opt_string "fully constrained" None outcome.notice

(* The provider-contract redaction rule: never interpolate an underlying
   exception or a raw response body into a message, because transport errors
   can echo the request they were built from — and this request's URL carries
   the API key. Each failure mode below is triggered with a refusal that {i
   does} carry the key, and the assertion is that the surfaced error does not. *)

let the_key_does_reach_the_endpoint () =
  (* The documented shape, asserted directly, so the redaction cases below are
     not passing vacuously on a URL that never carried the key. *)
  let _, request = search_of ~query:(query ~text:"q" ()) () in
  check_string "the whole URL, parameter order included"
    "https://serpapi.com/search?api_key=test-key&q=q&engine=google"
    (Uri.to_string request.Caps.Authority.Net.uri)

let no_failure_path_echoes_the_key () =
  List.iter
    (fun (label, provider) ->
      match Provider.search provider (query ~text:"q" ()) with
      | Ok _ -> A.failf "%s was accepted" label
      | Error failure ->
          let surfaced = Provider.render_error failure in
          check_bool (label ^ ": no key") false (contains ~haystack:surfaced ~needle:test_key);
          check_bool (label ^ ": no parameter name") false
            (contains ~haystack:surfaced ~needle:"api_key=");
          check_bool (label ^ ": no endpoint host") false
            (contains ~haystack:surfaced ~needle:"serpapi.com"))
    [
      (* The grant's own wording stands in for the httpx exception, and it
         quotes the URL the request was built from. *)
      ( "timeout",
        refusal Caps.Error.Timeout
          ~message:"timed out connecting to https://serpapi.com/search?api_key=test-key&q=q" );
      ( "connect",
        refusal Caps.Error.Denied
          ~message:"connection refused from https://serpapi.com/search?api_key=test-key&q=q" );
      ("malformed_json", fst (dial ~body:"<html>" ()));
    ]

let the_failure_messages_stay_constant () =
  (* A log message is a constant; values go through [bind()]. The adapter's
     half of that is: the message never carries the request. *)
  let provider =
    refusal Caps.Error.Timeout ~message:"timed out connecting to https://serpapi.com/search"
  in
  match Provider.search provider (query ~text:"q" ()) with
  | Ok _ -> A.failf "a timed-out grant was accepted"
  | Error failure -> check_string "the timeout row" "request timed out" failure.message

(* The six rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is this adapter's quota statuses
   and the wording the quota carries; its leak regression lives above, because
   this key rides in the request URL. *)

let payment_and_rate_limit_are_quota () =
  (* 429 is this API's throughput or allowance limit; 402 rides the contracted
     table. *)
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:"{}" () in
      match Provider.search provider (query ~text:"q" ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string "the house sentence" "rate limited or out of searches" failure.message;
          check_bool "the quota kind" true (failure.kind = Provider.Quota);
          check_bool "a spent quota is not transient" false failure.retryable)
    [ 402; 429 ]

let cost_does_not_scale_with_result_count () =
  let provider, _ = dial () in
  check_number "one query, whatever max_results says" 0. (Provider.cost_for provider 1);
  check_number "and at the ceiling" 0. (Provider.cost_for provider 20)

let the_result_reports_its_cost () =
  let outcome, _ = search_of ~query:(query ~text:"q" ~max_results:5 ()) () in
  check_string "named by the adapter that served it" "serpapi" outcome.provider;
  check_opt_number "the free plan costs nothing" (Some 0.) outcome.cost_usd

let a_paid_plan_corrects_the_cost () =
  let outcome, _ = search_of ~cost_per_1k:1.0 ~query:(query ~text:"q" ~max_results:5 ()) () in
  check_opt_number "and the figure tracks it" (Some 0.001) outcome.cost_usd

let the_default_price_is_the_rows_figure () =
  (* The adapter default and the registry row's [default_cost] are one fact:
     the 250-searches-a-month free plan is what an install most often runs on,
     and [--check --live] prints whichever figure is wrong. *)
  let provider, _ = dial () in
  check_number "the free plan" 0. (Provider.cost_per_1k provider);
  let provider, _ = dial ~cost_per_1k:1.0 () in
  check_number "an operator on a paid plan can correct it" 1.0 (Provider.cost_per_1k provider)

let the_endpoint_is_the_one_the_grant_allows () =
  check_string "the endpoint" "https://serpapi.com/search" (Uri.to_string Serpapi.endpoint);
  check_string "the policy host" "serpapi.com" Serpapi.policy_endpoint.Caps.Policy.host;
  check_bool "https" true (Serpapi.policy_endpoint.Caps.Policy.scheme = `Https);
  check_bool "the default port" true (Serpapi.policy_endpoint.Caps.Policy.port = None);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.Caps.Authority.Net.uri = Some Serpapi.policy_endpoint.Caps.Policy.host);
  (* This name is the exception: the credential rides the URL, so the grant's
     confinement cannot redact it — {!Seekwright.Provider.redact_url} is what
     every line naming one of these URLs passes through, and the row's probe
     carries the key the same way. *)
  check_bool "the key is in the URL, as documented" true
    (contains ~haystack:(Uri.to_string request.Caps.Authority.Net.uri) ~needle:test_key)

let () =
  A.(
    run "seekwright/serpapi"
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
            test_case "the display date is kept only when a string" `Quick
              the_display_date_is_kept_only_when_a_string;
            test_case "records without a link are dropped" `Quick records_without_a_link_are_dropped;
            test_case "records without a title are dropped" `Quick
              records_without_a_title_are_dropped;
            test_case "a record that is not an object is skipped" `Quick
              a_record_that_is_not_an_object_is_skipped;
            test_case "missing organic_results is empty, not an error" `Quick
              missing_organic_results_is_empty_not_an_error;
            test_case "the other element families are dropped" `Quick
              the_other_element_families_are_dropped;
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
            test_case "GET to the documented endpoint" `Quick gets_to_the_documented_endpoint;
            test_case "the key rides in the query string" `Quick the_key_rides_in_the_query_string;
            test_case "the query and engine are sent" `Quick the_query_and_engine_are_sent;
            test_case "the domain filters fold into the query" `Quick
              the_domain_filters_fold_into_the_query;
            test_case "the country rides gl, absent without one" `Quick the_country_rides_gl;
            test_case "the language is lowercased on the wire" `Quick
              the_language_is_lowercased_on_the_wire;
            test_case "the recency maps onto tbs" `Quick the_recency_maps_onto_tbs;
            test_case "safe-search maps onto safe, absent when unset" `Quick
              safe_search_maps_onto_safe;
            test_case "never a shape or billing field" `Quick never_a_shape_or_billing_field;
            test_case "the notice stays none for every shape of ask" `Quick
              the_notice_stays_none_for_every_shape_of_ask;
          ] );
        ( "the key in the query string",
          [
            test_case "the key does reach the endpoint" `Quick the_key_does_reach_the_endpoint;
            test_case "no failure path echoes the key" `Quick no_failure_path_echoes_the_key;
            test_case "the failure messages stay constant" `Quick the_failure_messages_stay_constant;
          ] );
        ( "the failures this adapter owns",
          [ test_case "payment and rate limit are quota" `Quick payment_and_rate_limit_are_quota ]
        );
        ( "cost and endpoint",
          [
            test_case "cost does not scale with result count" `Quick
              cost_does_not_scale_with_result_count;
            test_case "the result reports its cost" `Quick the_result_reports_its_cost;
            test_case "a paid plan corrects the cost" `Quick a_paid_plan_corrects_the_cost;
            test_case "the default price is the row's figure" `Quick
              the_default_price_is_the_rows_figure;
            test_case "the endpoint is the one the grant allows" `Quick
              the_endpoint_is_the_one_the_grant_allows;
          ] );
      ])
