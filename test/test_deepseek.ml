(* DeepSeek Search: parsing, the query fold, the 128-codepoint budget and cost.

   The fixture is the documented [/v1/tools/search] payload: each hit carries
   [rerank_score], [title], [url], [snippet], [summary], [content], [site_name],
   [site_icon], [date] and [authority]. [snippet] is the short UI preview and
   [summary] the longer one "intended to be read by a model", so a parsed result
   fills [snippet] and [text] while [content] — the page body, filled only behind
   [need_content], which this adapter never sends — never appears in one.

   The clock is pinned to 2026-10-21T00:00:00Z (epoch 1,792,540,800), the
   instant the Python suite hand-passes as [today=date(2026, 10, 21)]: the
   [after:] arithmetic is what the request-shape cases assert against, and an
   injected clock is what lets them pin it.

   The wiring cases from that suite belong to the registry and config suites;
   what stays here is the adapter's own default price — the published rate,
   there being no free tier — pinned against the figure the row builds it with.
   The adapter is shipped untested, so these hermetic cases are the whole
   coverage that exists. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Deepseek = Seekwright_providers.Deepseek
module A = Alcotest
open Test_support

(* 2026-10-21T00:00:00Z: the day the Python fold cases stand in. *)
let clock () = 1_792_540_800.

let utf8_count s =
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

(* The documented payload: [results[]] with the preview pair, the rerank score
   and the RFC 3339 date, the second record answering [null] to the optional
   fields, [content] empty because [need_content] was never asked. *)
let sample =
  {|{
  "results": [
    {
      "rerank_score": 2.4,
      "title": "DeepSeek V4 model released",
      "url": "https://example.com/deepseek-v4",
      "snippet": "DeepSeek V4 is now available, with tool calling.",
      "summary": "DeepSeek has released the V4 model. The release adds improved tool calling and long-context support for agent workflows.",
      "content": "",
      "site_name": "Example News",
      "site_icon": "https://example.com/favicon.ico",
      "date": "2026-06-01T00:00:00+00:00",
      "authority": 3
    },
    {
      "rerank_score": 1.1,
      "title": "Model card",
      "url": "https://example.org/v4-card",
      "snippet": "Weights, benchmarks and licence.",
      "summary": "The model card lists benchmarks.",
      "content": "",
      "site_name": null,
      "site_icon": null,
      "date": null,
      "authority": -1
    }
  ]
}|}

let sample_json =
  match Yojson.Safe.from_string sample with
  | `Assoc _ as json -> json
  | _ -> A.failf "the fixture is not an object"

let dial ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?(text_chars = 2000) ?cost_per_1k
    () =
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
    Deepseek.make ?cost_per_1k ~snippet_chars ~text_chars ~key:test_key ~now:clock ~net ()
  in
  (provider, fun () -> Option.get !sent)

let refusal kind ~message =
  let net = { Provider.Net.request = (fun _ -> Error (Caps.Error.make kind ~message)) } in
  Deepseek.make ~key:test_key ~now:clock ~net ()

let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?(text_chars = 2000)
    ?cost_per_1k ?(query = query ~text:"deepseek v4" ()) () =
  let provider, sent = dial ~status ~body ~snippet_chars ~text_chars ?cost_per_1k () in
  match Provider.search provider query with
  | Ok outcome -> (outcome, sent ())
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

(* The request body as Yojson, read the way the Python suite reads
   [json.loads(request.content)]. *)
let body (request : Caps.Authority.Net.request) =
  match Yojson.Safe.from_string (Option.get request.Caps.Authority.Net.body) with
  | `Assoc _ as json -> json
  | _ -> A.failf "the request body is not an object"

let body_field request name = Provider.Json.string_field name (body request)

let body_has request name = Provider.Json.field name (body request) <> `Null

let parse ?(snippet_chars = 500) ?(text_chars = 2000) ?(limit = 10) data =
  Deepseek.parse ~snippet_chars ~text_chars data ~limit

let record fields = `Assoc (("title", `String "T") :: ("url", `String "https://e.com") :: fields)

let results items = `Assoc [ ("results", `List items) ]

let the_fixture_yields_both_records () =
  let found = parse sample_json in
  check_strings "the two urls"
    [ "https://example.com/deepseek-v4"; "https://example.org/v4-card" ]
    (List.map (fun (hit : Provider.hit) -> hit.result.url) found)

let the_limit_is_honoured () = check_int "one of two" 1 (List.length (parse ~limit:1 sample_json))

let the_snippet_and_the_model_facing_summary_both_survive () =
  let hit = List.hd (parse ~limit:2 sample_json) in
  check_opt_string "the preview" (Some "DeepSeek V4 is now available, with tool calling.")
    hit.result.snippet;
  check_opt_string "the summary rides text"
    (Some
       "DeepSeek has released the V4 model. The release adds improved tool calling and \
        long-context support for agent workflows.")
    hit.result.text;
  (* Nothing was cut, so nothing is claimed to have been cut. *)
  A.(check (option bool) "no truncation flag" None hit.result.text_truncated)

let a_long_summary_is_cut_at_the_text_cap () =
  let long_summary = String.concat " " (List.init 600 (fun _ -> "word")) in
  let payload = results [ record [ ("summary", `String long_summary) ] ] in
  let hit = List.hd (parse ~text_chars:50 ~limit:1 payload) in
  check_bool "the extract is inside the cap" true (utf8_count (Option.get hit.result.text) <= 50);
  A.(check (option bool) "and says it was cut" (Some true) hit.result.text_truncated);
  (* The cap happened inside the adapter, so the length it discarded only
     reaches an operator through this log-only field ([search.cap]). *)
  check_opt_int "measured at the whole summary's length"
    (Some (utf8_count long_summary))
    hit.uncapped_chars

let a_record_with_no_summary_reports_no_length () =
  (* No text field at all, so the cap never ran and there is no length for
     [search.cap] to report. *)
  let payload = results [ record [ ("snippet", `String "x") ] ] in
  check_opt_int "no measurement" None (List.hd (parse ~limit:1 payload)).uncapped_chars

let the_rerank_score_is_the_score () =
  let found = parse ~limit:2 sample_json in
  check_opt_number "the first hit" (Some 2.4) (List.hd found).result.score;
  check_opt_number "the second" (Some 1.1) (List.nth found 1).result.score

let the_date_is_kept_only_when_a_string () =
  let found = parse ~limit:2 sample_json in
  check_opt_string "the RFC 3339 date" (Some "2026-06-01T00:00:00+00:00")
    (List.hd found).result.published_date;
  check_opt_string "and its null" None (List.nth found 1).result.published_date

let the_page_content_never_reaches_a_result () =
  (* [content] is a page body, and [fetch] is where bodies belong. *)
  let payload = results [ record [ ("content", `String "the full page text") ] ] in
  check_opt_string "text stays empty" None (List.hd (parse ~limit:1 payload)).result.text

let records_without_a_url_are_dropped () =
  check_int "no url" 0
    (List.length
       (parse ~limit:5
          (`Assoc
             [
               ( "results",
                 `List [ `Assoc [ ("title", `String "No url"); ("snippet", `String "x") ] ] );
             ])))

let records_without_a_title_are_dropped () =
  check_int "no title" 0
    (List.length
       (parse ~limit:5
          (`Assoc
             [
               ( "results",
                 `List
                   [ `Assoc [ ("url", `String "https://example.com/x"); ("snippet", `String "x") ] ]
               );
             ])))

let a_record_that_is_not_an_object_is_skipped () =
  check_int "the string is dropped, the object survives" 1
    (List.length (parse ~limit:5 (results [ `String "not-a-record"; record [] ])))

let missing_results_is_empty_not_an_error () =
  check_int "results is absent" 0 (List.length (parse ~limit:5 (`Assoc [])))

let a_non_list_results_container_is_empty_not_an_error () =
  check_int "results drifted to an object" 0
    (List.length (parse ~limit:5 (`Assoc [ ("results", `Assoc [ ("nope", `Int 1) ]) ])))

(* Shape drift in an untrusted payload drops the field, never the call: [date],
   [summary], [snippet] and [rerank_score] are documented as a string, a string,
   a string and a number, and nothing on the wire enforces it — an exception out
   of the parse would escape the engine's provider-error handling instead of
   reading as a missing field. *)

let a_field_of_the_wrong_shape_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (field, value, what) ->
      let payload = Yojson.Safe.to_string (results [ record [ (field, value) ] ]) in
      let outcome, _ = search_of ~body:payload ~query:(query ~max_results:1 ()) () in
      check_int
        (Printf.sprintf "the call succeeded through a non-string %s" field)
        1 (List.length outcome.results);
      let hit = List.hd outcome.results in
      match what with
      | `date -> check_opt_string "date dropped" None hit.result.published_date
      | `text -> check_opt_string "summary dropped" None hit.result.text
      | `snippet -> check_opt_string "snippet dropped" None hit.result.snippet
      | `score -> check_opt_number "score dropped" None hit.result.score)
    [
      ("date", `Int 1780000000, `date);
      ("summary", `Assoc [ ("parts", `List [ `String "x" ]) ], `text);
      ("snippet", `List [ `String "a"; `String "b" ], `snippet);
      ("rerank_score", `String "2.4", `score);
    ]

(* This backend has no filter fields on the request body at all: what it
   documents is a set of query operators, so domains, dates and language ride
   inside [query] — in the order and the shape its own example uses. The whole
   request is bounded by a 128-codepoint query, which the fold can push past,
   and [country] has no wire form ([localization] takes an IP address) while
   [safe_search] has no parameter. *)

let post_with_the_bearer_key () =
  let _, request = search_of () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `POST);
  check_opt_string "the bearer header"
    (Some ("Bearer " ^ test_key))
    (List.assoc_opt "Authorization" request.Caps.Authority.Net.headers);
  check_string "the endpoint" "https://api.deepseek.com/v1/tools/search"
    (Uri.to_string request.Caps.Authority.Net.uri)

let the_query_and_count_are_sent () =
  let _, request = search_of ~query:(query ~text:"deepseek v4" ~max_results:3 ()) () in
  check_opt_string "the query" (Some "deepseek v4") (body_field request "query");
  check_string "count" "3" (Yojson.Safe.to_string (Provider.Json.field "count" (body request)))

let count_is_clamped_to_the_documented_range () =
  (* [count] is documented as 1..50, so the request never asks for more: the
     response simply carries fewer hits than asked, which is a shorter answer
     rather than a dropped constraint. *)
  List.iter
    (fun max_results ->
      let outcome, request = search_of ~query:(query ~max_results ()) () in
      check_string
        (Printf.sprintf "count at max_results=%d" max_results)
        (string_of_int Deepseek.max_results)
        (Yojson.Safe.to_string (Provider.Json.field "count" (body request)));
      check_int "the range top is fifty" 50 Deepseek.max_results;
      check_opt_string "no notice over the clamp" None outcome.notice)
    [ 51; 100 ]

let the_fold_is_the_operators_own_example () =
  let folded =
    Deepseek.fold_operators ~now:clock
      (query ~text:"DeepSeek"
         ~include_domains:[ "github.com"; "huggingface.co" ]
         ~exclude_domains:[ "example.com" ] ~language:"EN" ~recency:Model.Week ())
  in
  check_string "term, site:, lang:, after:"
    "DeepSeek site:github.com OR site:huggingface.co -site:example.com lang:en after:2026-10-14"
    folded

let the_fold_adds_nothing_to_an_unconstrained_query () =
  check_string "bare" "q" (Deepseek.fold_operators ~now:clock (query ~text:"q" ()))

let each_rung_opens_the_window_that_many_days_back () =
  List.iter
    (fun (period, days, date) ->
      let folded = Deepseek.fold_operators ~now:clock (query ~text:"q" ~recency:period ()) in
      check_string (Printf.sprintf "after: for the %d-day rung" days) ("q after:" ^ date) folded;
      check_int "the day count on the rung" days (Deepseek.recency_days period))
    [
      (Model.Day, 1, "2026-10-20");
      (Model.Week, 7, "2026-10-14");
      (Model.Month, 31, "2026-09-20");
      (Model.Year, 366, "2025-10-20");
    ]

let a_domain_filter_folds_into_the_query () =
  let _, request =
    search_of
      ~query:
        (query ~text:"deepseek v4" ~include_domains:[ "example.com" ]
           ~exclude_domains:[ "spam.example" ] ())
      ()
  in
  check_opt_string "the operators ride inside query"
    (Some "deepseek v4 site:example.com -site:spam.example") (body_field request "query")

let a_multi_site_include_is_the_documented_or_form () =
  (* No parentheses: the operator's example joins [site:] clauses with [OR],
     and this adapter sends the shape it documents — which is why it does not
     use [Provider.site_filtered_query]. *)
  let _, request =
    search_of
      ~query:(query ~text:"deepseek v4" ~include_domains:[ "github.com"; "huggingface.co" ] ())
      ()
  in
  check_opt_string "the OR form" (Some "deepseek v4 site:github.com OR site:huggingface.co")
    (body_field request "query")

let language_folds_as_the_lang_operator () =
  let outcome, request = search_of ~query:(query ~text:"deepseek v4" ~language:"EN" ()) () in
  check_opt_string "lang:" (Some "deepseek v4 lang:en") (body_field request "query");
  check_opt_string "no notice" None outcome.notice

let recency_folds_as_an_after_operator_relative_to_today () =
  let outcome, request = search_of ~query:(query ~text:"deepseek v4" ~recency:Model.Day ()) () in
  check_opt_string "after: against the pinned clock" (Some "deepseek v4 after:2026-10-20")
    (body_field request "query");
  check_opt_string "no notice" None outcome.notice

let country_is_never_sent_and_is_named_as_dropped () =
  (* [localization] takes an IP address, and a two-letter country code is not
     one, so the ask goes to [notice] rather than to the wire. *)
  let outcome, request = search_of ~query:(query ~text:"deepseek v4" ~country:"de" ()) () in
  check_opt_string "the query rides bare" (Some "deepseek v4") (body_field request "query");
  check_opt_string "country is named" (Some "cannot filter by country; that constraint was ignored")
    outcome.notice

let a_safe_search_is_noticed_for_both_values () =
  List.iter
    (fun value ->
      let outcome, _ = search_of ~query:(query ~safe_search:value ()) () in
      check_opt_string
        (Printf.sprintf "safe_search=%b" value)
        (Some "cannot filter by safe-search; that constraint was ignored") outcome.notice)
    [ true; false ]

let an_unconstrained_query_carries_no_notice () =
  let outcome, _ = search_of () in
  check_opt_string "unconstrained" None outcome.notice

let never_a_content_or_localization_field () =
  (* [need_content] would ask for page bodies, [ori_question] is the question
     behind the search (unknown here), and [localization] takes an IP this
     proxy does not have. None of them may appear in a body. *)
  let _, request =
    search_of ~query:(query ~include_domains:[ "example.com" ] ~country:"us" ()) ()
  in
  List.iter
    (fun field ->
      check_bool (Printf.sprintf "no %s in the body" field) false (body_has request field))
    [ "need_content"; "ori_question"; "localization" ]

let a_query_past_the_documented_limit_is_refused_before_sending () =
  (* The tool surface allows 400 characters, this backend allows 128: the
     adapter names the limit rather than forwarding a 400, and the request is
     not retryable — it would have to change to succeed. The request never
     reaches the grant. *)
  let dialed = ref false in
  let net =
    {
      Provider.Net.request =
        (fun _ ->
          dialed := true;
          Ok { Caps.Authority.Net.status = 200; headers = []; body = sample });
    }
  in
  let provider = Deepseek.make ~key:test_key ~now:clock ~net () in
  match Provider.search provider (query ~text:(String.make 129 'x') ()) with
  | Ok _ -> A.failf "a 129-codepoint query was sent"
  | Error failure ->
      check_bool "not retryable" false failure.retryable;
      includes "the message names the limit" "128-character" failure.message;
      check_bool "and nothing was dialed" false !dialed

let operators_come_off_when_the_folded_query_would_not_fit () =
  (* The filters live inside the query, so a fold past 128 codepoints is a
     request the backend refuses. The bare query goes out and every bucket
     that came off is named: an unfiltered search the caller can see is better
     than a confident failure. *)
  let bare = String.make 100 'a' in
  let outcome, request =
    search_of
      ~query:
        (query ~text:bare
           ~include_domains:[ "example.com"; "example.org"; "example.net"; "example.io" ]
           ~recency:Model.Year ~language:"en" ())
      ()
  in
  check_opt_string "the bare query went out" (Some bare) (body_field request "query");
  check_bool "and it fits" true (utf8_count bare <= Deepseek.max_query_chars);
  check_opt_string "every dropped bucket is named"
    (Some "cannot filter by domain or dates or language; that constraint was ignored")
    outcome.notice

let the_fold_stays_when_it_fits () =
  let sixty = String.make 60 'a' in
  let outcome, request =
    search_of
      ~query:(query ~text:sixty ~include_domains:[ "example.com" ] ~recency:Model.Year ())
      ()
  in
  let sent = Option.get (body_field request "query") in
  includes "the fold survived" (sixty ^ " site:example.com after:") sent;
  check_opt_string "no notice" None outcome.notice

(* The rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is this adapter's quota statuses,
   its retryable upstream timeout, and the leak regression that proves the
   no-echo rule for the place its key actually rides. *)

let balance_and_rate_limit_are_quota () =
  (* 402 is this API's documented "insufficient balance" and 429 its
     documented account-level QPS breach; both are terminal for one call. *)
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:"{}" () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string "the house sentence" "rate limited or out of account balance" failure.message;
          check_bool "the quota kind" true (failure.kind = Provider.Quota);
          check_bool "a spent quota is not transient" false failure.retryable)
    [ 402; 429 ]

let the_upstream_timeout_row_is_retryable () =
  (* 408 is documented as "reading the request body timed out", and the
     operator says to retry it. It is the one status this adapter reads
     differently from the table's [HTTP <code>] row. *)
  let provider, _ = dial ~status:408 ~body:"{}" () in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "HTTP 408 was accepted"
  | Error failure ->
      check_string "the adapter's own sentence" "upstream timed out reading the request"
        failure.message;
      check_bool "and retryable" true failure.retryable

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

(* Search bills per successful request, whatever [count] says. *)

let cost_does_not_scale_with_result_count () =
  let provider, _ = dial ~cost_per_1k:0.75 () in
  check_number "one request, whatever count says" 0.00075 (Provider.cost_for provider 1);
  check_number "even at the range top" 0.00075 (Provider.cost_for provider 50)

let the_result_reports_its_flat_cost () =
  let outcome, _ = search_of ~query:(query ~max_results:5 ()) () in
  check_string "named by the adapter that served it" "deepseek" outcome.provider;
  check_opt_number "the published rate" (Some 0.00075) outcome.cost_usd

let a_search_with_no_results_is_not_billed () =
  (* The operator bills "per successful request" and states that an empty
     [results] array is not billed at all, so the call reports no cost. *)
  let outcome, _ = search_of ~body:{|{"results": []}|} () in
  check_int "no hits" 0 (List.length outcome.results);
  check_opt_number "and no cost" (Some 0.) outcome.cost_usd

let the_default_price_is_the_rows_figure () =
  (* The adapter default and the registry row's [default_cost] are one fact:
     no free tier is documented, so the default is the published rate itself,
     and an operator on different terms corrects it in config. *)
  let provider, _ = dial () in
  check_number "the published rate" 0.75 (Provider.cost_per_1k provider);
  let provider, _ = dial ~cost_per_1k:1.0 () in
  check_number "different terms can correct it" 1.0 (Provider.cost_per_1k provider)

let the_endpoint_is_the_one_the_grant_allows () =
  check_string "the endpoint" "https://api.deepseek.com/v1/tools/search"
    (Uri.to_string Deepseek.endpoint);
  check_string "the policy host" "api.deepseek.com" Deepseek.policy_endpoint.Caps.Policy.host;
  check_bool "https" true (Deepseek.policy_endpoint.Caps.Policy.scheme = `Https);
  check_bool "the default port" true (Deepseek.policy_endpoint.Caps.Policy.port = None);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.Caps.Authority.Net.uri = Some Deepseek.policy_endpoint.Caps.Policy.host);
  (* The key rides a header, so the URL the grant confines never carries it. *)
  check_bool "no key in the URL" false
    (contains ~haystack:(Uri.to_string request.Caps.Authority.Net.uri) ~needle:test_key)

let () =
  A.(
    run "seekwright/deepseek"
      [
        ( "parsing",
          [
            test_case "the fixture yields both records" `Quick the_fixture_yields_both_records;
            test_case "the limit is honoured" `Quick the_limit_is_honoured;
            test_case "the snippet and the summary both survive" `Quick
              the_snippet_and_the_model_facing_summary_both_survive;
            test_case "a long summary is cut at the text cap" `Quick
              a_long_summary_is_cut_at_the_text_cap;
            test_case "a record with no summary reports no length" `Quick
              a_record_with_no_summary_reports_no_length;
            test_case "the rerank score is the score" `Quick the_rerank_score_is_the_score;
            test_case "the date is kept only when a string" `Quick
              the_date_is_kept_only_when_a_string;
            test_case "the page content never reaches a result" `Quick
              the_page_content_never_reaches_a_result;
            test_case "records without a url are dropped" `Quick records_without_a_url_are_dropped;
            test_case "records without a title are dropped" `Quick
              records_without_a_title_are_dropped;
            test_case "a record that is not an object is skipped" `Quick
              a_record_that_is_not_an_object_is_skipped;
            test_case "missing results is empty, not an error" `Quick
              missing_results_is_empty_not_an_error;
            test_case "a non-list results container is empty, not an error" `Quick
              a_non_list_results_container_is_empty_not_an_error;
          ] );
        ( "the upstream field guards",
          [
            test_case "a field of the wrong shape is dropped and the call succeeds" `Quick
              a_field_of_the_wrong_shape_is_dropped_and_the_call_succeeds;
          ] );
        ( "the request",
          [
            test_case "POST with the bearer key" `Quick post_with_the_bearer_key;
            test_case "the query and count are sent" `Quick the_query_and_count_are_sent;
            test_case "count is clamped to the documented range" `Quick
              count_is_clamped_to_the_documented_range;
            test_case "the fold is the operator's own example" `Quick
              the_fold_is_the_operators_own_example;
            test_case "the fold adds nothing to an unconstrained query" `Quick
              the_fold_adds_nothing_to_an_unconstrained_query;
            test_case "each rung opens the window that many days back" `Quick
              each_rung_opens_the_window_that_many_days_back;
            test_case "a domain filter folds into the query" `Quick
              a_domain_filter_folds_into_the_query;
            test_case "a multi-site include is the documented OR form" `Quick
              a_multi_site_include_is_the_documented_or_form;
            test_case "language folds as the lang operator" `Quick
              language_folds_as_the_lang_operator;
            test_case "recency folds as an after operator" `Quick
              recency_folds_as_an_after_operator_relative_to_today;
            test_case "country is never sent and is named as dropped" `Quick
              country_is_never_sent_and_is_named_as_dropped;
            test_case "a safe search is noticed for both values" `Quick
              a_safe_search_is_noticed_for_both_values;
            test_case "an unconstrained query carries no notice" `Quick
              an_unconstrained_query_carries_no_notice;
            test_case "never a content or localization field" `Quick
              never_a_content_or_localization_field;
            test_case "a query past the limit is refused before sending" `Quick
              a_query_past_the_documented_limit_is_refused_before_sending;
            test_case "operators come off when the fold would not fit" `Quick
              operators_come_off_when_the_folded_query_would_not_fit;
            test_case "the fold stays when it fits" `Quick the_fold_stays_when_it_fits;
          ] );
        ( "the failures this adapter owns",
          [
            test_case "balance and rate limit are quota" `Quick balance_and_rate_limit_are_quota;
            test_case "the upstream timeout row is retryable" `Quick
              the_upstream_timeout_row_is_retryable;
            test_case "a network error does not echo the request" `Quick
              a_network_error_does_not_echo_the_request;
          ] );
        ( "cost",
          [
            test_case "cost does not scale with result count" `Quick
              cost_does_not_scale_with_result_count;
            test_case "the result reports its flat cost" `Quick the_result_reports_its_flat_cost;
            test_case "a search with no results is not billed" `Quick
              a_search_with_no_results_is_not_billed;
            test_case "the default price is the row's figure" `Quick
              the_default_price_is_the_rows_figure;
            test_case "the endpoint is the one the grant allows" `Quick
              the_endpoint_is_the_one_the_grant_allows;
          ] );
      ])
