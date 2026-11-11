(* AnySearch: response parsing, request shape, cost and failures.

   Port of tests/providers/test_anysearch.py. The fixture is the documented
   [/v1/search] envelope from the operator's API docs (read 2026-10-16, the same
   shape the keyless probe observed), and the cases run through a fake
   {!Seekwright.Provider.Net.t} rather than a socket — the position
   [httpx.MockTransport] holds in Python.

   The wiring cases (built when enabled without a key, a disabled entry not
   built) belong to the config and factory suites, P3 and P5. What [anysearch]
   owes this suite that [freeserp] does not is the credential-bearing 402 body:
   the one response in this port whose text must never reach a failure message.

   The live run that cleared Python's untested-provider status for this name
   (tests/live/test_live.py, 2026-10-17) has no OCaml equivalent yet: there is no
   live harness in this tree, so the endpoint's real behaviour is unproven on
   this side of the port. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Anysearch = Seekwright_providers.Anysearch
module A = Alcotest

let check_string what expected got = A.(check string) what expected got
let check_bool what expected got = A.(check bool) what expected got
let check_int what expected got = A.(check int) what expected got
let check_opt what expected got = A.(check (option string)) what expected got
let check_opt_int what expected got = A.(check (option int)) what expected got

(* Alcotest's float testable takes the absolute error, not a labelled option. *)
let number = A.float 1e-9
let check_number what expected got = A.(check number) what expected got
let check_opt_number what expected got = A.(check (option number)) what expected got

let contains text needle =
  let n = String.length text and m = String.length needle in
  let rec from i =
    if i + m > n then false else String.sub text i m = needle || from (i + 1)
  in
  from 0

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

(* {1 The fixture}

   The envelope with three records: one well-formed, one whose [title] is
   documented as always present but empty (a drop), and one whose [snippet] is
   documented as omitted when unavailable (never invented). The first record
   also carries the [content] extract this adapter does not read. *)
let sample =
  {|{
  "code": 0,
  "message": "success",
  "request_id": "7d6f4e91-2a83-4c5b-9f10-6e8a3d27b541",
  "data": {
    "results": [
      {
        "title": "Go 1.26 Release Notes",
        "url": "https://go.dev/doc/go1.26",
        "snippet": "Introduction to the changes in Go 1.26.",
        "content": "Go 1.26 introduces changes to the language, toolchain, runtime, and libraries..."
      },
      {
        "title": "",
        "url": "https://example.com/untitled",
        "snippet": "A source that provides no title."
      },
      {
        "title": "Snippet omitted upstream",
        "url": "https://example.com/no-snippet"
      }
    ],
    "metadata": {"total_results": 3, "search_time_ms": 312}
  }
}|}

(* The envelope's [data] half, which is what the mapping is handed. *)
let sample_data =
  match Provider.Json.field "data" (Yojson.Safe.from_string sample) with
  | `Assoc _ as data -> data
  | _ -> A.failf "the fixture carries no data object"

(* {1 The seam} *)

let dial ?(status = 200) ?(body = sample) ?(snippet_chars = 500)
    ?(cost_per_1k = 0.) () =
  let sent = ref None in
  let net =
    {
      Provider.Net.request =
        (fun request ->
          sent := Some request;
          Ok { Caps.Authority.Net.status; headers = []; body });
    }
  in
  (Anysearch.make ~cost_per_1k ~snippet_chars ~net (), fun () -> Option.get !sent)

let refusal kind ~message =
  Anysearch.make ~net:{ Provider.Net.request = (fun _ -> Error (Caps.Error.make kind ~message)) } ()

let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500)
    ?(cost_per_1k = 0.) ?(query = query ()) () =
  let provider, sent = dial ~status ~body ~snippet_chars ~cost_per_1k () in
  match Provider.search provider query with
  | Ok outcome -> (outcome, sent ())
  | Error failure -> A.failf "the search failed: %s" (Provider.render_error failure)

let failed_search ?(status = 200) ?(body = sample) ?(query = query ()) () =
  let provider, _ = dial ~status ~body () in
  match Provider.search provider query with
  | Ok outcome ->
      A.failf "the failure was accepted as a result: %d hits" (List.length outcome.results)
  | Error failure -> failure

(* The body that would have gone out, decoded: the assertions are about the
   documented request document, not about a serialization. *)
(* [Policy_net] declares [body] and [headers] on both its request and its
   response record, so a caller has to say which record it means. *)
let body_of (request : Caps.Authority.Net.request) =
  match request.Caps.Authority.Net.body with
  | None -> A.failf "the request carried no body"
  | Some text -> (match Yojson.Safe.from_string text with json -> json)

let body_fields request = Option.get (Provider.Json.members (body_of request))

let has_field request name = List.exists (fun (key, _) -> key = name) (body_fields request)

let parse ?(snippet_chars = 500) ?(limit = 10) data =
  Anysearch.parse ~snippet_chars data ~limit

let record fields = `Assoc fields
let payload items = `Assoc [ ("results", `List items) ]

(* {1 Parsing} *)

let records_that_carry_a_title_and_url () =
  let hits = parse sample_data in
  (* The empty [title] drops the record the way a missing one does. *)
  check_int "two of three" 2 (List.length hits);
  check_string "the title" "Go 1.26 Release Notes" (List.hd hits).result.title;
  check_string "the url" "https://go.dev/doc/go1.26" (List.hd hits).result.url;
  check_string "the untitled record is gone" "https://example.com/no-snippet"
    (List.nth hits 1).result.url

let the_limit_is_honoured () =
  check_int "one of three" 1 (List.length (parse ~limit:1 sample_data))

let a_serp_record_keeps_snippet_and_never_text () =
  let hits = parse sample_data in
  check_opt "the snippet" (Some "Introduction to the changes in Go 1.26.")
    (List.hd hits).result.snippet;
  List.iter
    (fun (h : Provider.hit) -> check_opt "text is never filled" None h.result.text)
    hits

let the_content_extract_is_never_read () =
  (* Filling both would ship the same prose twice, and [content] is the extract
     that [fetch] is for. *)
  List.iter
    (fun (h : Provider.hit) ->
      check_opt "no text" None h.result.text;
      check_bool "the extract is not smuggled into the snippet" false
        (contains (Option.value ~default:"" h.result.snippet) "introduces changes to the language"))
    (parse sample_data)

let a_missing_snippet_stays_absent () =
  (* [snippet] is documented as omitted when unavailable, and a proxy that
     invents one is worse than one that says nothing. *)
  check_opt "no snippet" None (List.nth (parse sample_data) 1).result.snippet

let no_date_is_invented () =
  (* No date field exists upstream, so [published_date] stays empty. *)
  List.iter
    (fun (h : Provider.hit) -> check_opt "no date" None h.result.published_date)
    (parse sample_data)

let the_snippet_cap_clips () =
  (* The cap is below the fixture's normalised length (39), so the clip bites:
     a cap of 40 would keep the snippet whole and say nothing. *)
  let hits = parse ~snippet_chars:30 sample_data in
  let snippet = Option.get (List.hd hits).result.snippet in
  check_int "the cap plus one character for the ellipsis" 31 (chars snippet);
  check_opt_int "the length the cap received" (Some 39) (List.hd hits).uncapped_chars

let the_length_the_cap_discarded_is_recorded () =
  (* [search.cap] reads this: the pre-cap length, log-only and off the wire. *)
  let hit = List.hd (parse ~snippet_chars:30 sample_data) in
  check_opt_int "the pre-cap length" (Some 39) hit.uncapped_chars;
  check_bool "more than was shipped" true
    (hit.uncapped_chars > Option.map chars (Some (Option.get hit.result.snippet)));
  (* Python's [Result._uncapped_chars] is private so it cannot reach the wire;
     here the measurement sits beside the result on the provider boundary, and
     the wire model has no field for it. *)
  check_bool "absent from the wire model" false
    (contains (Yojson.Safe.to_string (Model.result_to_yojson hit.result)) "uncapped")

let records_without_a_url_or_title_are_dropped () =
  let drop items = List.length (parse (`Assoc [ ("results", `List items) ])) in
  check_int "no url" 0 (drop [ record [ ("title", `String "No url here") ] ]);
  check_int "no title" 0 (drop [ record [ ("url", `String "https://example.com") ] ]);
  (* Documented as always present but possibly empty — dropped, not kept. *)
  check_int "an empty title" 0
    (drop [ record [ ("title", `String ""); ("url", `String "https://example.com") ] ])

let a_record_that_is_not_an_object_is_skipped () =
  check_int "the string is dropped, the object survives" 1
    (List.length (parse (payload [ `String "nonsense"; record [ ("title", `String "t"); ("url", `String "https://x") ] ])))

let missing_container_is_empty_not_an_error () =
  List.iter
    (fun (what, data) ->
      check_int what 0 (List.length (parse data)))
    [
      ("results is null", `Assoc [ ("results", `Null) ]);
      ("results is absent", `Assoc []);
      ("the envelope is null", `Null);
      ("the envelope is a list", `List [ `String "a"; `String "b" ]);
      ("the envelope is a string", `String "a page, not a document");
    ]

(* {1 The upstream field guards}

   The payload is untrusted: the schema documents these fields as strings and
   nothing enforces it. Shape drift drops the field, it does not raise out of
   the engine's provider-error handling as an internal error. *)

let a_non_string_snippet_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let data =
        `Assoc
          [
            ("code", `Int 0);
            ("message", `String "success");
            ( "data",
              `Assoc
                [
                  ( "results",
                    `List
                      [
                        record
                          [
                            ("title", `String "t");
                            ("url", `String "https://example.com/a");
                            ("snippet", value);
                          ];
                      ] );
                ] );
          ]
      in
      let outcome, _ = search_of ~body:(Yojson.Safe.to_string data) () in
      check_int (Printf.sprintf "the call succeeds with a %s" what) 1
        (List.length outcome.results);
      check_opt "the snippet is dropped" None (List.hd outcome.results).result.snippet)
    [
      ("object", `Assoc [ ("nested", `String "object") ]);
      ("list", `List [ `String "a"; `String "b" ]);
      ("number", `Int 7);
    ]

let a_non_string_title_drops_the_record () =
  List.iter
    (fun (what, value) ->
      let data =
        `Assoc
          [
            ("code", `Int 0);
            ("data",
              `Assoc
                [
                  ( "results",
                    `List
                      [
                        record [ ("title", value); ("url", `String "https://example.com/a") ];
                        record [ ("title", `String "kept"); ("url", `String "https://example.com/b") ];
                      ] );
                ] );
          ]
      in
      let outcome, _ = search_of ~body:(Yojson.Safe.to_string data) () in
      A.(
        check (list string) ("a " ^ what ^ " title drops its record") [ "kept" ]
          (List.map (fun (h : Provider.hit) -> h.result.title) outcome.results)))
    [
      ("object", `Assoc [ ("nested", `String "object") ]);
      ("list", `List [ `String "a"; `String "b" ]);
      ("number", `Int 7);
    ]

let a_string_snippet_still_reaches_the_caller () =
  (* The guard must not change behaviour for a well-formed payload. *)
  let outcome, _ = search_of () in
  check_opt "the snippet" (Some "Introduction to the changes in Go 1.26.")
    (List.hd outcome.results).result.snippet

(* {1 The request}

   Only [language] rides the wire: there is no domain field, no date field, no
   safe-search field, and [zone] takes [cn] / [intl] — a binary a country code
   cannot map into without guessing. Every drop is named in the [notice], which
   is the only thing between a caller that asked for a filter and the belief
   that it got one. *)

let posts_json_to_the_documented_endpoint_without_auth () =
  let _, request = search_of () in
  check_bool "the method" true (request.meth = `POST);
  check_string "the host" "api.anysearch.com" (Option.get (Uri.host request.uri));
  check_string "the path" "/v1/search" (Uri.path request.uri);
  check_bool "the content type" true
    (List.assoc_opt "content-type" request.headers = Some "application/json");
  (* Keyless by scope: no Authorization header is ever sent, whatever the
     grant's endpoint list says. *)
  check_bool "no authorization header" false
    (List.exists
       (fun (name, _) -> String.lowercase_ascii name = "authorization")
       request.Caps.Authority.Net.headers)

let the_query_and_max_results_are_sent () =
  let _, request = search_of ~query:(query ~text:"wal mode" ~max_results:3 ()) () in
  check_opt "the query" (Some "wal mode") (Provider.Json.string_field "query" (body_of request));
  check_opt_number "max_results" (Some 3.) (Provider.Json.number_field "max_results" (body_of request))

let max_results_is_clamped_to_the_documented_range () =
  (* The tool caps [max_results] at 20; the API's range is 1-10, so 11-20 would
     be a documented-invalid request (400) rather than a search. *)
  let _, request = search_of ~query:(query ~max_results:20 ()) () in
  check_opt_number "the documented ceiling" (Some 10.)
    (Provider.Json.number_field "max_results" (body_of request));
  check_int "and the adapter's own ceiling" 10 Anysearch.max_results

let language_is_lowercased_on_the_wire () =
  let outcome, request = search_of ~query:(query ~language:"DE" ()) () in
  check_opt "lowercased" (Some "de") (Provider.Json.string_field "language" (body_of request));
  (* Language is honoured, so a language-only constraint carries no notice. *)
  check_opt "no notice" None outcome.notice

let language_is_absent_without_a_language () =
  let _, request = search_of () in
  check_bool "no language key in the body" false (has_field request "language")

let never_sends_a_region_or_capability_field () =
  (* [zone] is a binary a country cannot map into; [tag], [params] and [format]
     are operator policy and an encoding for the extract this adapter does not
     read. None of them may appear in a body at all. *)
  let _, request = search_of ~query:(query ~country:"de" ~language:"en" ()) () in
  List.iter
    (fun name -> check_bool (Printf.sprintf "no %s in the body" name) false (has_field request name))
    [ "zone"; "tag"; "params"; "format" ]

let an_unconstrained_query_carries_no_notice () =
  let outcome, _ = search_of () in
  check_opt "no notice" None outcome.notice

let each_dropped_constraint_is_noticed () =
  List.iter
    (fun (what, q, sentence) ->
      let outcome, _ = search_of ~query:q () in
      check_string what (Printf.sprintf "cannot filter by %s; that constraint was ignored" sentence)
        (Option.get outcome.notice))
    [
      ("a country", query ~country:"de" (), "country");
      ("a recency", query ~recency:Model.Week (), "dates");
      ("safe-search on", query ~safe_search:true (), "safe-search");
      ("safe-search off", query ~safe_search:false (), "safe-search");
      ("domain filters", query ~include_domains:[ "go.dev" ] ~exclude_domains:[ "spam.example" ] (), "domain");
      ("a language beside a country", query ~country:"de" ~language:"en" (), "country");
    ]

let all_dropped_buckets_are_named_together () =
  let outcome, _ =
    search_of
      ~query:
        (query ~include_domains:[ "go.dev" ] ~recency:Model.Day ~country:"de"
           ~safe_search:true ~language:"en" ())
      ()
  in
  check_string "four buckets, in the order the report writes them"
    "cannot filter by domain or dates or country or safe-search; that constraint was ignored"
    (Option.get outcome.notice)

(* {1 The failures this adapter owns} *)

let quota_and_rate_limit_are_quota () =
  List.iter
    (fun status ->
      let failure = failed_search ~status ~body:{|{"code":0,"data":{}}|} () in
      check_bool "the quota kind" true (failure.kind = Provider.Quota);
      check_bool "a spent quota is not transient" false failure.retryable)
    [ 402; 429 ]

let a_402_body_with_credentials_never_reaches_the_message () =
  (* The redaction rule's reason to exist: over the daily anonymous quota the
     gateway auto-registers an account, and its [message] carries the generated
     username, password and API key. *)
  let body =
    {|{"code": -1, "message": "Your account and API key have been automatically generated. Use the API key below to continue. username=op123 password=secret-password api_key=sk-live-abc"}|}
  in
  let failure = failed_search ~status:402 ~body () in
  check_string "the message is a constant" "out of credits or rate limited" failure.message;
  List.iter
    (fun secret ->
      check_bool (Printf.sprintf "the body never echoes %s" secret) false
        (contains (Provider.render_error failure) secret))
    [ "op123"; "secret-password"; "sk-live-abc" ]

let a_nonzero_business_code_fails_without_echoing_the_message () =
  (* The envelope's own contract: success is [code: 0]. The error channel's
     [message] is operator text the 402 flow shows can hold credentials, so the
     failure carries a constant. *)
  let failure =
    failed_search ~body:{|{"code": -1, "message": "Query is required. caller=seekwright-deployment"}|} ()
  in
  check_string "the contracted sentence" "search failed (business error)" failure.message;
  check_bool "the operator's text is not echoed" false
    (contains (Provider.render_error failure) "caller=seekwright-deployment")

let a_missing_business_code_fails_the_same_way () =
  let failure = failed_search ~body:{|{"message": "success", "data": {"results": []}}|} () in
  check_string "the same sentence" "search failed (business error)" failure.message

let a_zero_written_as_a_float_is_success () =
  (* [code: 0.0] is the same contract reading as [0]: the envelope is JSON, and
     a gateway that writes its integers as floats is not a failure. *)
  let outcome, _ = search_of ~body:{|{"code": 0.0, "data": {"results": []}}|} () in
  check_int "an empty result set, not a refusal" 0 (List.length outcome.results)

let a_network_failure_does_not_echo_the_request () =
  let provider =
    refusal Caps.Error.Denied
      ~message:"connection refused for https://api.anysearch.com/v1/search query=secret-query"
  in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "a refused grant was accepted"
  | Error failure ->
      check_string "the network row" "network error" failure.message;
      check_bool "nothing about the request rides along" false
        (contains (Provider.render_error failure) "secret-query")

(* {1 Cost and endpoint} *)

let cost_is_flat_zero () =
  let provider, _ = dial () in
  check_number "the reporting figure" 0. (Provider.cost_per_1k provider);
  check_number "flat at one result" 0. (Provider.cost_for provider 1);
  check_number "flat at the documented ceiling" 0. (Provider.cost_for provider 10)

let the_result_reports_its_flat_cost () =
  let outcome, _ = search_of ~query:(query ~max_results:5 ()) () in
  check_string "named by the adapter that served it" "anysearch" outcome.provider;
  check_opt_number "flat zero" (Some 0.) outcome.cost_usd;
  check_opt "no answer from a SERP adapter" None outcome.answer

let an_operator_corrected_cost_reaches_the_adapter () =
  (* An operator on a future paid tier can fix what [--check] reports; the
     Python row's [default_cost] in [factory._PROVIDERS] moves with it (P5). *)
  let provider, _ = dial ~cost_per_1k:0.5 () in
  check_number "the corrected figure" 0.5 (Provider.cost_per_1k provider);
  check_number "and its per-query reading" 0.0005 (Provider.cost_for provider 5)

let the_endpoint_is_the_one_the_grant_allows () =
  check_string "the endpoint" "https://api.anysearch.com/v1/search"
    (Uri.to_string Anysearch.endpoint);
  check_string "the policy host" "api.anysearch.com" Anysearch.policy_endpoint.Caps.Policy.host;
  check_bool "https" true (Anysearch.policy_endpoint.Caps.Policy.scheme = `Https);
  check_bool "the default port" true (Anysearch.policy_endpoint.Caps.Policy.port = None);
  let _, request = search_of () in
  check_bool "and the adapter dials that host" true
    (Uri.host request.uri = Some Anysearch.policy_endpoint.Caps.Policy.host)

let () =
  A.
    (run "seekwright/anysearch"
       [
         ( "parsing",
             [
               test_case "the records that carry a title and url" `Quick
                 records_that_carry_a_title_and_url;
               test_case "the limit is honoured" `Quick the_limit_is_honoured;
               test_case "a SERP record keeps snippet and never text" `Quick
                 a_serp_record_keeps_snippet_and_never_text;
               test_case "the content extract is never read" `Quick the_content_extract_is_never_read;
               test_case "a missing snippet stays absent" `Quick a_missing_snippet_stays_absent;
               test_case "no date is invented" `Quick no_date_is_invented;
               test_case "the snippet cap clips" `Quick the_snippet_cap_clips;
               test_case "the length the cap discarded is recorded" `Quick
                 the_length_the_cap_discarded_is_recorded;
               test_case "records without a url or title are dropped" `Quick
                 records_without_a_url_or_title_are_dropped;
               test_case "a record that is not an object is skipped" `Quick
                 a_record_that_is_not_an_object_is_skipped;
               test_case "a missing container is empty, not an error" `Quick
                 missing_container_is_empty_not_an_error;
             ] );
         ( "the upstream field guards",
             [
               test_case "a non-string snippet is dropped and the call succeeds" `Quick
                 a_non_string_snippet_is_dropped_and_the_call_succeeds;
               test_case "a non-string title drops the record" `Quick a_non_string_title_drops_the_record;
               test_case "a string snippet still reaches the caller" `Quick
                 a_string_snippet_still_reaches_the_caller;
             ] );
         ( "the request",
             [
               test_case "POST JSON to the documented endpoint, without auth" `Quick
                 posts_json_to_the_documented_endpoint_without_auth;
               test_case "the query and max_results are sent" `Quick the_query_and_max_results_are_sent;
               test_case "max_results is clamped to the documented range" `Quick
                 max_results_is_clamped_to_the_documented_range;
               test_case "language is lowercased on the wire" `Quick language_is_lowercased_on_the_wire;
               test_case "language is absent without a language" `Quick language_is_absent_without_a_language;
               test_case "never a region or capability field" `Quick
                 never_sends_a_region_or_capability_field;
               test_case "an unconstrained query carries no notice" `Quick
                 an_unconstrained_query_carries_no_notice;
               test_case "each dropped constraint is noticed" `Quick each_dropped_constraint_is_noticed;
               test_case "all dropped buckets are named together" `Quick
                 all_dropped_buckets_are_named_together;
             ] );
         ( "the failures this adapter owns",
             [
               test_case "quota and rate limit are quota" `Quick quota_and_rate_limit_are_quota;
               test_case "a 402 body with credentials never reaches the message" `Quick
                 a_402_body_with_credentials_never_reaches_the_message;
               test_case "a non-zero business code fails without echoing the message" `Quick
                 a_nonzero_business_code_fails_without_echoing_the_message;
               test_case "a missing business code fails the same way" `Quick
                 a_missing_business_code_fails_the_same_way;
               test_case "a zero written as a float is success" `Quick a_zero_written_as_a_float_is_success;
               test_case "a network failure does not echo the request" `Quick
                 a_network_failure_does_not_echo_the_request;
             ] );
         ( "cost and endpoint",
             [
               test_case "cost is flat zero" `Quick cost_is_flat_zero;
               test_case "the result reports its flat cost" `Quick the_result_reports_its_flat_cost;
               test_case "an operator-corrected cost reaches the adapter" `Quick
                 an_operator_corrected_cost_reaches_the_adapter;
               test_case "the endpoint is the one the grant allows" `Quick
                 the_endpoint_is_the_one_the_grant_allows;
             ] );
       ])
