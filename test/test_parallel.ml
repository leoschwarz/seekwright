(* Parallel: the billed REST half's request grammar and hand-composed notices, the
   result parser both halves share, and the anonymous hosted-MCP half.

   Port of tests/providers/test_parallel.py. The REST half is driven through a
   fake {!Seekwright.Provider.Net.t} — the position the oracle's
   [httpx.MockTransport] holds — so nothing is dialed and the request that would
   have gone out is asserted on instead. The free half shares {!parse_results}
   with it, so the oracle tests its MCP surface without a session; here the
   session is scripted at the transport (the fixture is test_exa's), which pins
   the tool arguments where the client puts them rather than where the adapter
   builds them.

   [source_policy.after_date] is the one date this adapter computes, so the clock
   is injected and every date assertion names the instant it is true of — the
   oracle computes its window from the wall clock and pins no date at all. The
   day counts are fixed (30-day months, 365-day years) because recency is
   "published within the last {i n}", open-ended, with no upper bound to agree a
   calendar boundary with.

   The notices are hand-composed rather than the shared sentence, and that is the
   suite's main subject: [exclude_domains] is sent even where Parallel ignores it
   (the request stays an honest description) while the caller is told; [country]
   rides [location] and so draws no notice while [language] does; and the vendor's
   own [warnings] are echoed — the only third-party prose this adapter repeats.

   The wiring cases from that suite — which name builds under which config, and at
   what figure — belong to the registry and config suites: an adapter never
   decides whether it is enabled. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Parallel = Seekwright_providers.Parallel
module A = Alcotest
open Test_support

let query ?(text = "q") ?(max_results = 5) ?(include_domains = []) ?(exclude_domains = [])
    ?country ?language ?recency ?safe_search () : Model.search_query =
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

(* Never sent anywhere real: the string a leak would carry. *)
let test_key = "test-key"

(* The instant every date assertion below is true of: 2023-11-14T22:13:20Z, the
   same frozen clock the differential uses. *)
let fixed_now = 1_700_000_000.

let hd label = function
  | x :: _ -> x
  | [] -> A.failf "%s was empty" label

let nth label index xs =
  match List.nth_opt xs index with
  | Some x -> x
  | None -> A.failf "%s has no item %d" label index

(* {1 The fixture: a real REST payload}

   Copied from the oracle's suite, which captured it from the Search API: the
   [search_id] and [session_id] are the vendor's bookkeeping and never reach the
   caller, and the second record arrives with a null [title] and a null date. *)
let sample =
  {|{
  "search_id": "search_cad0a6d2dec046bd95ae900527d880e7",
  "results": [
    {
      "url": "https://docs.python.org/3/whatsnew/3.14.html",
      "title": "What's New In Python 3.14",
      "publish_date": "2025-10-07",
      "excerpts": [
        "Python 3.14 is the newest major release of the Python programming language.",
        "It contains many new features and optimizations."
      ]
    },
    {
      "url": "https://example.com/untitled",
      "title": null,
      "publish_date": null,
      "excerpts": ["A page Parallel could not name."]
    }
  ],
  "warnings": null,
  "session_id": "session_8a911eb27c7a4afaa20d0d9dc98d07c0"
}|}

let sample_json =
  match Yojson.Safe.from_string sample with `Assoc _ as json -> json | _ -> A.failf "the fixture is not an object"

(* {1 The seam} *)

let dial ?(status = 200) ?(body = sample) ?text_chars ?cost_per_1k ?mode () =
  let sent = ref None in
  let net =
    {
      Provider.Net.request =
        (fun request ->
          sent := Some request;
          Ok { Caps.Authority.Net.status; headers = []; body });
    }
  in
  let adapter =
    Parallel.make ?cost_per_1k ?text_chars ?mode ~key:test_key ~now:(fun () -> fixed_now) ~net ()
  in
  (adapter, fun () -> Option.get !sent)

let search_of ?status ?body ?text_chars ?cost_per_1k ?mode ?(query = query ()) () =
  let adapter, sent = dial ?status ?body ?text_chars ?cost_per_1k ?mode () in
  match Provider.search adapter query with
  | Ok outcome -> (outcome, sent ())
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

let body_of (request : Caps.Authority.Net.request) =
  match request.Caps.Authority.Net.body with
  | Some text -> Yojson.Safe.from_string text
  | None -> A.failf "the request carried no body"

let field name json = Provider.Json.string_field name json

let nested path json =
  List.fold_left
    (fun acc key -> match acc with None -> None | Some value -> Some (Provider.Json.field key value))
    (Some json) path

let strings_of path json =
  match nested path json with
  | Some (`List items) ->
      Some (List.filter_map (fun item -> match item with `String s -> Some s | _ -> None) items)
  | _ -> None

let has_field name json =
  match Provider.Json.members json with Some fields -> List.mem_assoc name fields | None -> false

(* {1 The parser both halves share} *)

let parse ?(limit = 10) ?(text_chars = 2000) data = Parallel.parse_results data ~limit ~text_chars

let the_result_list_becomes_results () =
  let hits = parse sample_json in
  check_int "two records" 2 (List.length hits);
  check_string "the title" "What's New In Python 3.14" (hd "results" hits).result.title;
  check_string "the url" "https://docs.python.org/3/whatsnew/3.14.html"
    (hd "results" hits).result.url

let excerpts_join_into_the_text () =
  let text = Option.get (hd "results" (parse sample_json)).result.text in
  includes "the first excerpt" "newest major release" text;
  includes "the second excerpt" "new features and optimizations" text;
  (* Joined verbatim, so the seam is exactly what the probe data holds. *)
  includes "the seam between them" "language. It contains" text

let the_limit_slices_the_result_list () =
  check_int "one record" 1 (List.length (parse ~limit:1 sample_json))

let the_cap_bites_and_says_so () =
  let capped =
    parse ~text_chars:40
      (`Assoc
          [
            ("results", `List [ `Assoc [
              ("url", `String "https://x.example/");
              ("title", `String "T");
              ("excerpts", `List [ `String "A first excerpt that runs on.";
                                   `String "and a second one that keeps going." ]);
            ] ]);
          ])
  in
  let hit = hd "results" capped in
  check_bool "one ellipsis, one cap" true (String.length (Option.get hit.result.text) <= 41);
  A.(check (option bool) "the flag rides" (Some true) hit.result.text_truncated);
  A.(check (option bool) "a short extract is not flagged" None
    (hd "results" (parse ~text_chars:2000 sample_json)).result.text_truncated)

let a_date_passes_through_and_is_never_invented () =
  let hits = parse sample_json in
  check_opt_string "the vendor's date, verbatim" (Some "2025-10-07")
    (hd "results" hits).result.published_date;
  check_opt_string "a null date stays absent" None (nth "results" 1 hits).result.published_date

let a_null_title_falls_back_to_the_url () =
  check_string "the url titles the record" "https://example.com/untitled"
    (nth "results" 1 (parse sample_json)).result.title

let a_content_backend_never_fills_a_snippet () =
  let hits = parse sample_json in
  check_bool "no snippet on any record" true
    (List.for_all (fun (hit : Provider.hit) -> hit.result.snippet = None) hits)

let a_record_without_a_url_is_dropped () =
  let no_url = `Assoc [ ("title", `String "No url"); ("excerpts", `List [ `String "x" ]) ] in
  check_int "a title and excerpts do not make a result" 0
    (List.length (parse (`Assoc [ ("results", `List [ no_url ]) ])))

let a_record_that_is_not_an_object_is_skipped () =
  let usable = `Assoc [ ("url", `String "https://a.example"); ("excerpts", `List []) ] in
  check_int "the string is dropped, the object survives" 1
    (List.length (parse (`Assoc [ ("results", `List [ `String "nonsense"; usable ]) ])))

let a_missing_result_list_is_empty_not_an_error () =
  check_int "results is null" 0 (List.length (parse (`Assoc [ ("results", `Null) ])));
  check_int "results is absent" 0 (List.length (parse (`Assoc [])))

(* A JSON array or scalar is not a result set: the REST half reads [resp.json()]
   and the MCP half reads a text block, and either can arrive as anything the
   upstream decided. *)
let a_document_that_is_not_an_object_is_empty_not_an_error () =
  check_int "an array" 0 (List.length (parse (`List [ `Int 1; `Int 2; `Int 3 ])));
  check_int "a scalar" 0 (List.length (parse (`String "not a result set")))

(* {1 The REST request} *)

let post_with_the_key_header_and_a_body () =
  let _outcome, request = search_of ~query:(query ~text:"python 3.14" ~max_results:3 ()) () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `POST);
  check_string "the endpoint" (Uri.to_string Parallel.endpoint)
    (Uri.to_string request.Caps.Authority.Net.uri);
  check_string "the credential rides x-api-key" "test-key"
    (Option.get
       (List.assoc_opt "x-api-key" request.Caps.Authority.Net.headers));
  let body = body_of request in
  check_strings "one query, verbatim" [ "python 3.14" ]
    (Option.get (strings_of [ "search_queries" ] body));
  check_string "the preset" "fast" (Option.get (field "mode" body));
  check_int "the count reaches advanced_settings" 3
    (match Provider.Json.field "max_results" (Option.get (nested [ "advanced_settings" ] body)) with
    | `Int n -> n
    | _ -> 0)

let the_key_never_rides_the_url () =
  let _outcome, request = search_of () in
  excludes "the URI names no key" test_key (Uri.to_string request.Caps.Authority.Net.uri);
  check_bool "and no query parameters" true (Uri.query request.Caps.Authority.Net.uri = [])

let the_preset_is_the_operators () =
  (* [mode] decides the price, so it is config and never a tool parameter. *)
  let _outcome, request = search_of ~mode:"advanced" () in
  check_string "advanced reaches the wire" "advanced" (Option.get (field "mode" (body_of request)))

let domains_go_to_source_policy_and_the_query_stays_verbatim () =
  let _outcome, request =
    search_of
      ~query:(query ~text:"wal mode" ~include_domains:[ "sqlite.org" ] ~exclude_domains:[ "spam.example" ] ())
      ()
  in
  let body = body_of request in
  let policy = Option.get (nested [ "advanced_settings"; "source_policy" ] body) in
  check_strings "include_domains" [ "sqlite.org" ] (Option.get (strings_of [ "include_domains" ] policy));
  check_strings "exclude_domains" [ "spam.example" ]
    (Option.get (strings_of [ "exclude_domains" ] policy));
  (* A native filter: the query is never folded into [site:] operators. *)
  check_strings "the query" [ "wal mode" ] (Option.get (strings_of [ "search_queries" ] body))

let recency_sets_after_date_at_the_injected_clock () =
  List.iter
    (fun (period, date, word) ->
      let _outcome, request = search_of ~query:(query ~recency:period ()) () in
      let policy = Option.get (nested [ "advanced_settings"; "source_policy" ] (body_of request)) in
      check_string (Printf.sprintf "%s sets after_date" word) date (Option.get (field "after_date" policy)))
    [
      (Model.Day, "2023-11-13", "day");
      (Model.Week, "2023-11-07", "week");
      (Model.Month, "2023-10-15", "month");
      (Model.Year, "2022-11-14", "year");
    ];
  check_int "a month is thirty days whatever the month" 30 (Parallel.recency_days Model.Month)

let country_sets_location () =
  let _outcome, request = search_of ~query:(query ~country:"de" ()) () in
  check_string "location is the vendor's own field" "de"
    (Option.get (field "location" (Option.get (nested [ "advanced_settings" ] (body_of request)))))

let an_unasked_filter_leaves_the_policy_out_entirely () =
  let _outcome, request = search_of () in
  let advanced = Option.get (nested [ "advanced_settings" ] (body_of request)) in
  check_bool "no source_policy" false (has_field "source_policy" advanced);
  check_bool "no location" false (has_field "location" advanced);
  check_int "only the count" 1 (List.length (Option.get (Provider.Json.members advanced)))

(* {1 The notices, hand-composed} *)

let exclude_is_sent_and_its_ignoring_is_noticed () =
  (* Sent verbatim even though Parallel ignores it while [include_domains] is
     set — the request stays an honest description of what was asked — and the
     caller is told rather than left believing it applied. *)
  let outcome, request =
    search_of ~query:(query ~include_domains:[ "python.org" ] ~exclude_domains:[ "spam.example" ] ())
      ()
  in
  let policy = Option.get (nested [ "advanced_settings"; "source_policy" ] (body_of request)) in
  check_strings "the filter still went out" [ "spam.example" ]
    (Option.get (strings_of [ "exclude_domains" ] policy));
  check_string "and the drop is named by the field the vendor ignores"
    "parallel ignores exclude_domains while include_domains is set; that constraint was ignored"
    (Option.get outcome.notice)

let language_is_noticed_while_country_is_honoured () =
  (* The finer reason the shared bucket sentence cannot state: [country] rides
     [location], so no geo token belongs in the notice, while [language] has no
     parameter behind it. *)
  let outcome, request = search_of ~query:(query ~country:"de" ~language:"de" ()) () in
  check_string "the country applied" "de"
    (Option.get (field "location" (Option.get (nested [ "advanced_settings" ] (body_of request)))));
  includes "the language did not" "cannot filter by language" (Option.get outcome.notice);
  excludes "and the honoured half is not named" "country" (String.lowercase_ascii (Option.get outcome.notice))

let safe_search_is_noticed_at_both_values () =
  List.iter
    (fun value ->
      let outcome, _request = search_of ~query:(query ~safe_search:value ()) () in
      check_string "the safe-search sentence"
        "cannot filter by safe-search; that constraint was ignored"
        (Option.get outcome.notice))
    [ true; false ]

let a_fully_honoured_query_carries_no_notice () =
  let outcome, _request =
    search_of ~query:(query ~include_domains:[ "python.org" ] ~country:"de" ~recency:Model.Week ()) ()
  in
  check_opt_string "every constraint applied, so nothing is said" None outcome.notice

let upstream_warnings_are_echoed () =
  (* The vendor's own words, read once and repeated: the only third-party prose
     this adapter puts in front of a model. *)
  let warned =
    {|{
  "results": [{"url": "https://example.com/a", "excerpts": ["x"]}],
  "warnings": [{"type": "quality", "message": "thin index"}]
}|}
  in
  let outcome, _request = search_of ~body:warned () in
  check_string "the warning rides through" "upstream warnings: thin index" (Option.get outcome.notice)

let the_notices_join_in_one_sentence () =
  let warned =
    {|{
  "results": [],
  "warnings": [{"type": "quality", "message": "thin index"}, {"type": "coverage", "message": "no dates"}]
}|}
  in
  let outcome, _request =
    search_of ~body:warned ~query:(query ~language:"de" ~safe_search:true ()) ()
  in
  check_string "each half named once, in the order the adapter composes them"
    "cannot filter by language; that constraint was ignored; cannot filter by safe-search; \
     that constraint was ignored; upstream warnings: thin index; no dates"
    (Option.get outcome.notice)

(* {1 The failures this adapter owns}

   The rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is this adapter's quota pair —
   [parallel] answers both the payment status and the rate limit with one
   sentence — and the leak regression for the place its key actually rides. *)

let payment_and_rate_limit_are_one_quota_row () =
  List.iter
    (fun status ->
      let adapter, _sent = dial ~status ~body:{|{}|} () in
      match Provider.search adapter (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string (Printf.sprintf "HTTP %d says what ran out" status)
            "rate limited or out of credits" failure.message;
          check_bool "and it is quota" true (failure.kind = Provider.Quota))
    [ 402; 429 ]

let a_network_failure_does_not_echo_the_request () =
  let net =
    {
      Provider.Net.request =
        (fun _ -> Error (Caps.Error.make Caps.Error.Denied ~message:"connection refused to x-api-key: test-key"));
    }
  in
  let adapter = Parallel.make ~key:test_key ~now:(fun () -> fixed_now) ~net () in
  match Provider.search adapter (query ()) with
  | Ok _ -> A.failf "a refused grant was accepted"
  | Error failure ->
      check_string "the house row" "network error" failure.message;
      excludes "no echo of the header that holds the key" test_key (Provider.render_error failure)

let malformed_json_is_the_adapters_own_sentence () =
  let adapter, _sent = dial ~body:"not json" () in
  match Provider.search adapter (query ()) with
  | Ok _ -> A.failf "a body that is not JSON was accepted"
  | Error failure -> includes "named as a malformed response" "malformed JSON" failure.message

(* {1 Cost and endpoints} *)

let the_price_tracks_the_preset_not_the_count () =
  let adapter, _sent = dial () in
  check_number "one call" 0.001 (Provider.cost_for adapter 1);
  check_number "the same call at twenty results" 0.001 (Provider.cost_for adapter 20);
  let priced, _sent = dial ~cost_per_1k:5.00 () in
  check_number "an operator-corrected figure" 0.005 (Provider.cost_for priced 5)

let the_result_carries_the_flat_figure () =
  let outcome, _request = search_of ~query:(query ~max_results:5 ()) () in
  check_string "named by the adapter that served it" "parallel" outcome.provider;
  check_opt_number "one call, not five" (Some 0.001) outcome.cost_usd

let the_endpoints_are_the_two_halves () =
  check_string "the billed REST endpoint" "https://api.parallel.ai/v1/search"
    (Uri.to_string Parallel.endpoint);
  check_string "the policy host" "api.parallel.ai" Parallel.policy_endpoint.Caps.Policy.host;
  check_string "the free half's hosted MCP" "https://search.parallel.ai/mcp"
    (Uri.to_string Parallel.mcp_uri);
  check_string "and its tool" "web_search" Parallel.mcp_tool

(* {1 The free half: the tool surface and its text channel} *)

(* The scripted MCP endpoint: the handshake answered, then one tool reply. Same
   shape as test_exa's fixture; the free half has no credential to tell apart, so
   its queue is the anonymous one. The [arguments] of each [tools/call] is
   recorded, which is where the tool surface gets pinned. *)
let calls = ref []

let mcp_endpoint ~text () =  let net =
    {
      Provider.Net.request =
        (fun (request : Caps.Authority.Net.request) ->
          match request.Caps.Authority.Net.body with
          | None -> Ok { Caps.Authority.Net.status = 204; headers = []; body = "" }
          | Some raw ->
              let message = Yojson.Safe.from_string raw in
              let id = match Provider.Json.field "id" message with `Int id -> id | _ -> 0 in
              let reply body =
                Ok
                  {
                    Caps.Authority.Net.status = 200;
                    headers = [ ("content-type", "application/json") ];
                    body;
                  }
              in
              match Provider.Json.string_field "method" message with
              | Some "initialize" ->
                  reply
                    (Yojson.Safe.to_string
                       (`Assoc
                          [
                            ("jsonrpc", `String "2.0");
                            ("id", `Int id);
                            ( "result"
                            , `Assoc
                                [
                                  ("protocolVersion", `String "2025-06-18");
                                  ("capabilities", `Assoc []);
                                  ("serverInfo", `Assoc [("name", `String "fixture"); ("version", `String "0")]);
                                ] );
                          ]))
              | Some "notifications/initialized" ->
                  Ok { Caps.Authority.Net.status = 202; headers = []; body = "" }
              | Some "tools/call" ->
                  let arguments =
                    Provider.Json.field "arguments" (Provider.Json.field "params" message)
                  in
                  let envelope =
                    Yojson.Safe.to_string
                      (`Assoc
                          [
                            ("jsonrpc", `String "2.0");
                            ("id", `Int id);
                            ( "result"
                            , `Assoc
                                [
                                  ( "content"
                                  , `List [ `Assoc [ ("type", `String "text"); ("text", `String text) ] ] );
                                  ("isError", `Bool false);
                                ] );
                          ])
                  in
                  calls := (arguments, request) :: !calls;
                  reply envelope
              | _ -> Ok { Caps.Authority.Net.status = 202; headers = []; body = "" });
    }
  in
  net

let free_half ?cost_per_1k text =
  calls := [];
  let net = mcp_endpoint ~text () in
  Parallel.make_mcp ?cost_per_1k ~name:"parallel:free" ~uri:Parallel.mcp_uri ~net ()

let the_free_half_asks_its_tool_with_the_query_twice () =
  (* [web_search] requires an [objective] and at least one [search_queries]
     entry; the caller gives one string and there is no second to derive, so it
     serves as both. *)
  let session = free_half sample in
  let outcome =
    match Provider.search session.Provider.adapter (query ~text:"rust async" ()) with
    | Ok outcome -> outcome
    | Error failure -> A.failf "the free half failed: %s" (Provider.render_error failure)
  in
  let arguments, (_ : Caps.Authority.Net.request) = hd "the tool call" !calls in
  check_string "the objective" "rust async" (Option.get (field "objective" arguments));
  check_strings "and the queries" [ "rust async" ]
    (Option.get (strings_of [ "search_queries" ] arguments));
  check_int "the shared parser read the text block" 2 (List.length outcome.results);
  check_string "titled by the url where the title was null" "https://example.com/untitled"
    (nth "results" 1 outcome.results).result.title

let the_free_half_answers_zero () =
  let session = free_half sample in
  check_number "the default figure" 0.0 (Provider.cost_per_1k session.Provider.adapter);
  check_number "at twenty results" 0.0 (Provider.cost_for session.Provider.adapter 20)

let the_free_half_reports_a_malformed_text_block () =
  let session = free_half "not json" in
  match Provider.search session.Provider.adapter (query ()) with
  | Ok _ -> A.failf "a text block that is not JSON was accepted"
  | Error failure -> includes "the same sentence the REST half uses" "malformed JSON" failure.message

let the_free_half_notices_a_filter_it_cannot_reach () =
  (* The tool arguments are [objective] and [search_queries]: no filter field at
     all, so the shared sentence covers it. *)
  let session = free_half sample in
  let outcome =
    match Provider.search session.Provider.adapter (query ~country:"de" ()) with
    | Ok outcome -> outcome
    | Error failure -> A.failf "the free half failed: %s" (Provider.render_error failure)
  in
  check_string "the joined geo bucket"
    "cannot filter by country/language; that constraint was ignored"
    (Option.get outcome.notice)

let the_free_half_owns_a_session () =
  let session = free_half sample in
  check_bool "warmup handshakes it" true (session.Provider.warmup ());
  Provider.aclose session.Provider.adapter

let () =
  A.
    (run "seekwright/parallel"
       [
         ( "the parser both halves share"
         , [
             test_case "the result list becomes results" `Quick the_result_list_becomes_results;
             test_case "excerpts join into the text" `Quick excerpts_join_into_the_text;
             test_case "the limit slices the result list" `Quick the_limit_slices_the_result_list;
             test_case "the cap bites and says so" `Quick the_cap_bites_and_says_so;
             test_case "a date passes through and is never invented" `Quick
               a_date_passes_through_and_is_never_invented;
             test_case "a null title falls back to the url" `Quick
               a_null_title_falls_back_to_the_url;
             test_case "a content backend never fills a snippet" `Quick
               a_content_backend_never_fills_a_snippet;
             test_case "a record without a url is dropped" `Quick
               a_record_without_a_url_is_dropped;
             test_case "a record that is not an object is skipped" `Quick
               a_record_that_is_not_an_object_is_skipped;
             test_case "a missing result list is empty, not an error" `Quick
               a_missing_result_list_is_empty_not_an_error;
             test_case "a document that is not an object is empty, not an error" `Quick
               a_document_that_is_not_an_object_is_empty_not_an_error;
           ] );
         ( "the REST request"
         , [
             test_case "POST with the key header and a body" `Quick
               post_with_the_key_header_and_a_body;
             test_case "the key never rides the URL" `Quick the_key_never_rides_the_url;
             test_case "the preset is the operator's" `Quick the_preset_is_the_operators;
             test_case "domains go to source_policy, the query stays verbatim" `Quick
               domains_go_to_source_policy_and_the_query_stays_verbatim;
             test_case "recency sets after_date at the injected clock" `Quick
               recency_sets_after_date_at_the_injected_clock;
             test_case "country sets location" `Quick country_sets_location;
             test_case "an unasked filter leaves the policy out entirely" `Quick
               an_unasked_filter_leaves_the_policy_out_entirely;
           ] );
         ( "the hand-composed notices"
         , [
             test_case "exclude is sent and its ignoring is noticed" `Quick
               exclude_is_sent_and_its_ignoring_is_noticed;
             test_case "language is noticed while country is honoured" `Quick
               language_is_noticed_while_country_is_honoured;
             test_case "safe-search is noticed at both values" `Quick
               safe_search_is_noticed_at_both_values;
             test_case "a fully honoured query carries no notice" `Quick
               a_fully_honoured_query_carries_no_notice;
             test_case "upstream warnings are echoed" `Quick upstream_warnings_are_echoed;
             test_case "the notices join in one sentence" `Quick the_notices_join_in_one_sentence;
           ] );
         ( "the failures this adapter owns"
         , [
             test_case "payment and rate limit are one quota row" `Quick
               payment_and_rate_limit_are_one_quota_row;
             test_case "a network failure does not echo the request" `Quick
               a_network_failure_does_not_echo_the_request;
             test_case "malformed JSON is the adapter's own sentence" `Quick
               malformed_json_is_the_adapters_own_sentence;
           ] );
         ( "cost and endpoints"
         , [
             test_case "the price tracks the preset, not the count" `Quick
               the_price_tracks_the_preset_not_the_count;
             test_case "the result carries the flat figure" `Quick
               the_result_carries_the_flat_figure;
             test_case "the endpoints are the two halves" `Quick the_endpoints_are_the_two_halves;
           ] );
         ( "the free half"
         , [
             test_case "its tool is asked with the query twice" `Quick
               the_free_half_asks_its_tool_with_the_query_twice;
             test_case "it answers zero" `Quick the_free_half_answers_zero;
             test_case "it reports a malformed text block" `Quick
               the_free_half_reports_a_malformed_text_block;
             test_case "it notices a filter it cannot reach" `Quick
               the_free_half_notices_a_filter_it_cannot_reach;
             test_case "it owns a session" `Quick the_free_half_owns_a_session;
           ] );
       ])
