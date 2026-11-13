(* Algolia: the schemaless-record mapping, the config-derived deployment, and
   the quota pair this name answers with its own 402.

   Port of tests/providers/test_algolia.py. The fixture is a captured-style
   [/1/indexes/{index}/query] payload, and because records are schemaless JSON the
   five hits deliberately walk the whole mapping: the [title/name/question] and
   [url/link] chains, the DocSearch [hierarchy] shape whose title lives at the
   deepest non-empty level, the two drop cases (no title, no url) and the snippet
   chain's [description/summary/excerpt/content/answer] run. An explicitly
   configured [*]_attr is used alone — no chain, no hierarchy fallback — which is
   what the third hit of the explicit-attrs case costs its slot for.

   The wiring cases from that suite belong to the registry and config suites: an
   adapter never decides whether it is enabled, and here the destination itself is
   config ([app_id] names the host, [index] names the path segment), so the host
   construction is pinned from both ends — {!Seekwright_providers.Algolia}
   deriving it, and the row handing the adapter that same URI to dial.

   The request-shape cases drive the adapter through a fake
   {!Seekwright.Provider.Net.t} — the position [httpx.MockTransport] holds in
   Python. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Algolia = Seekwright_providers.Algolia
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

(* Never sent to anything real: it is the string a leak would carry. *)
let test_key = "test-key"

(* The deployment every case is about: an app id names the host, an index names
   the segment. *)
let app_id = "app123"

let index = "products"

let deployment = Algolia.endpoint_of_deployment ~app_id ~index

(* The list accessors, so a missing record fails with its label rather than
   [Stdlib.Failure("hd")]. *)
let hd label = function
  | x :: _ -> x
  | [] -> A.failf "%s was empty" label

let nth label index xs =
  match List.nth_opt xs index with
  | Some x -> x
  | None -> A.failf "%s has no item %d" label index

(* {1 The fixture}

   Five hits: the [title/url/description] chain, the [name/link/summary] chain,
   the DocSearch hierarchy (whose [lvl2] is null and whose title is [lvl2]'s
   emptier neighbour [lvl1]), and the two drop cases. *)
let sample =
  {|{
  "hits": [
    {
      "objectID": "1",
      "title": "Write-Ahead Logging",
      "url": "https://www.sqlite.org/wal.html",
      "description": "The default method by which SQLite implements atomic commit is a rollback journal."
    },
    {
      "objectID": "2",
      "name": "SQLite WAL mode explained",
      "link": "https://example.com/wal-explained",
      "summary": "WAL allows readers and one writer to proceed concurrently."
    },
    {
      "objectID": "3",
      "hierarchy": {"lvl0": "Docs", "lvl1": "Search", "lvl2": null},
      "url": "https://docs.example.com/search",
      "content": "How full-text search works in this index."
    },
    {
      "objectID": "4",
      "title": "A title with no URL",
      "description": "Dropped: no URL to send the caller to."
    },
    {
      "objectID": "5",
      "url": "https://example.com/no-title",
      "content": "Dropped: no title."
    }
  ],
  "nbHits": 5,
  "page": 0,
  "nbPages": 1,
  "hitsPerPage": 20,
  "processingTimeMS": 3,
  "query": "wal"
}|}

let sample_json =
  match Yojson.Safe.from_string sample with
  | `Assoc _ as json -> json
  | _ -> A.failf "the fixture is not an object"

(* {1 The seam}

   A {!Seekwright.Provider.Net.t} that records what was dialed and answers with a
   canned response. Every request-shape case is
   [let provider, sent = dial () in …; let request = sent ()]. *)
let dial ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k
    ?title_attr ?url_attr ?snippet_attr () =
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
    Algolia.make ?cost_per_1k ~snippet_chars ?title_attr ?url_attr ?snippet_attr
      ~app_id ~key:test_key ~endpoint:deployment ~net ()
  in
  (provider, fun () -> Option.get !sent)

let refusal kind ~message =
  let net =
    {
      Provider.Net.request = (fun _ -> Error (Caps.Error.make kind ~message));
    }
  in
  Algolia.make ~app_id ~key:test_key ~endpoint:deployment ~net ()

let search_of ?(status = 200) ?(body = sample) ?(snippet_chars = 500) ?cost_per_1k
    ?title_attr ?url_attr ?snippet_attr ?(query = query ()) () =
  let provider, sent =
    dial ~status ~body ~snippet_chars ?cost_per_1k ?title_attr ?url_attr
      ?snippet_attr ()
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
  | `Null -> None
  | other -> Some (Yojson.Safe.to_string other)

let has_body_field name request =
  match Provider.Json.members (body_of request) with
  | Some fields -> List.mem_assoc name fields
  | None -> false

(* {1 Parsing schemaless records} *)

let parse ?title_attr ?url_attr ?snippet_attr ?(limit = 10) data =
  Algolia.parse ~snippet_chars:500 ?title_attr ?url_attr ?snippet_attr data ~limit

let the_default_chains_fill_all_three_fields () =
  let hits = parse sample_json in
  check_int "three of the five hits survive" 3 (List.length hits);
  let first = hd "results" hits in
  check_string "the first title" "Write-Ahead Logging" first.Provider.result.title;
  check_string "the first url" "https://www.sqlite.org/wal.html" first.Provider.result.url;
  check_opt_string "the first snippet"
    (Some
       "The default method by which SQLite implements atomic commit is a rollback \
        journal.")
    first.Provider.result.snippet;
  let second = nth "results" 1 hits in
  check_string "the name/link/summary chain" "SQLite WAL mode explained"
    second.Provider.result.title;
  check_string "and its url" "https://example.com/wal-explained" second.Provider.result.url;
  check_opt_string "and its snippet"
    (Some "WAL allows readers and one writer to proceed concurrently.")
    second.Provider.result.snippet

let the_hierarchy_title_uses_the_deepest_level () =
  let hit = nth "results" 2 (parse sample_json) in
  check_string "lvl1, the most specific non-empty level" "Search" hit.Provider.result.title;
  check_string "the url rides through" "https://docs.example.com/search"
    hit.Provider.result.url;
  check_opt_string "content is part of the snippet chain"
    (Some "How full-text search works in this index.") hit.Provider.result.snippet;
  (* An empty [lvl6] does not win over a filled [lvl5]: the fallback is the most
     specific {i non-empty} level, as DocSearch's own frontend renders it. *)
  check_opt_string "levels past the null one are still read" (Some "deep")
    (Algolia.hierarchy_title
       (`Assoc
          [
            ( "hierarchy"
            , `Assoc
                [
                  ("lvl0", `String "Docs");
                  ("lvl1", `Null);
                  ("lvl2", `String "");
                  ("lvl5", `Assoc [ ("nested", `String "not a string") ]);
                  ("lvl6", `String "deep");
                ] );
          ]))

let explicit_attrs_win_over_the_default_chain () =
  (* A configured title_attr is used alone, so only a hit with all three named
     attrs survives — hit 3's [hierarchy] title and [content] snippet buy it
     nothing once the operator has named the fields. *)
  let hits = parse ~title_attr:"name" ~url_attr:"link" ~snippet_attr:"summary" sample_json in
  check_int "one hit" 1 (List.length hits);
  check_string "the named title" "SQLite WAL mode explained"
    (hd "results" hits).Provider.result.title;
  check_string "the named url" "https://example.com/wal-explained"
    (hd "results" hits).Provider.result.url;
  check_opt_string "the named snippet"
    (Some "WAL allows readers and one writer to proceed concurrently.")
    (hd "results" hits).Provider.result.snippet

let a_single_named_snippet_attr_replaces_the_chain () =
  let hits = parse ~snippet_attr:"objectID" sample_json in
  check_opt_string "the named attribute is text, not a chain lookup" (Some "1")
    (hd "results" hits).Provider.result.snippet;
  (* The named attribute wins over the chain even where it is not a string, and a
     wrong type there is the same absent as anywhere else: the hit stands with no
     snippet rather than failing. *)
  let hits =
    parse ~snippet_attr:"hierarchy"
      (`Assoc
         [
           ( "hits"
           , `List
               [
                 `Assoc
                   [
                     ("title", `String "t");
                     ("url", `String "https://example.com/a");
                     ("hierarchy", `Assoc [ ("lvl0", `String "not prose") ]);
                     ("description", `String "would have won the chain");
                   ];
               ] );
         ])
  in
  check_int "the hit stands" 1 (List.length hits);
  check_opt_string "and the chain is not consulted" None (hd "results" hits).result.snippet

let hits_missing_a_title_or_url_are_dropped () =
  (* Hits 4 and 5 in the sample, plus the count above. An {i empty} title or url
     counts as missing the way the oracle's [if not title or not url] reads it —
     a result the caller cannot cite or follow is not a result. *)
  check_int "the sample drops two" 3 (List.length (parse sample_json));
  let hits =
    parse
      (`Assoc
         [
           ( "hits"
         , `List
             [
               `Assoc [ ("title", `String ""); ("url", `String "https://a/x") ];
               `Assoc [ ("title", `String "t"); ("url", `String "") ];
             ] );
         ])
  in
  check_int "empty strings are missing strings" 0 (List.length hits)

let non_object_records_are_skipped () =
  check_int "the string is dropped, the record survives" 1
    (List.length
       (parse
          (`Assoc
             [
               ("hits", `List [ `String "nonsense"; `Assoc [ ("title", `String "t"); ("url", `String "https://x") ] ]);
             ])))

let missing_hits_container_is_empty_not_an_error () =
  check_int "no hits key at all" 0 (List.length (parse (`Assoc [])));
  check_int "hits is null" 0 (List.length (parse (`Assoc [ ("hits", `Null) ])));
  (* The slice costs the unusable row: the cap is over the upstream list before
     anything is dropped, so a hit that fails to map spends one of the slots. *)
  check_int "the slice comes before the filter" 0
    (List.length
       (parse ~limit:1
          (`Assoc
             [
               ( "hits"
           , `List
               [
                 `Assoc [ ("title", `String "no url") ];
                 `Assoc [ ("title", `String "t"); ("url", `String "https://kept/x") ];
               ] );
             ])))

let the_limit_is_honoured () =
  check_int "one" 1 (List.length (parse ~limit:1 sample_json));
  check_int "more than the payload holds" 3 (List.length (parse ~limit:99 sample_json))

let nothing_is_invented_per_hit () =
  let first = hd "results" (parse sample_json) in
  check_opt_string "no text" None first.Provider.result.text;
  check_opt_string "no published date" None first.Provider.result.published_date;
  check_bool "no score" true (first.Provider.result.score = None);
  check_bool "no answer from a provider that returns records" true
    ((fst (search_of ())).answer = None)

(* {1 The upstream field guards}

   A non-string snippet attribute is dropped, never handed to the truncate
   helper, and the call still succeeds: records are schemaless, so the coercion
   happens at the adapter boundary and a wrong type counts as absent. A number
   is the one non-string shape kept — it is coerced, because a number in a
   [description] column is prose the operator stored. *)

let a_non_string_snippet_attribute_is_dropped_and_the_call_succeeds () =
  List.iter
    (fun (what, value) ->
      let body =
        Yojson.Safe.to_string
          (`Assoc
             [
               ( "hits"
           , `List
               [
                 `Assoc
                   [
                     ("title", `String "t");
                     ("url", `String "https://example.com/a");
                     ("description", value);
                   ];
               ] );
             ])
      in
      let outcome, _ = search_of ~body () in
      check_int "the hit survives" 1 (List.length outcome.results);
      check_opt_string what None (hd "results" outcome.results).result.snippet)
    [
      ("a nested object", `Assoc [ ("nested", `String "object") ]);
      ("a list", `List [ `String "a"; `String "b" ]);
      ("a boolean", `Bool true);
    ]

let a_numeric_snippet_attribute_is_still_coerced () =
  List.iter
    (fun (value, expected) ->
      let body =
        Yojson.Safe.to_string
          (`Assoc
             [
               ( "hits"
           , `List
               [
                 `Assoc
                   [
                     ("title", `String "t");
                     ("url", `String "https://example.com/a");
                     ("description", value);
                   ];
               ] );
             ])
      in
      let outcome, _ = search_of ~body () in
      check_opt_string "the number is prose, not a dropped field" (Some expected)
        (hd "results" outcome.results).result.snippet)
    [
      (`Int 7, "7");
      (`Float 7.5, "7.5");
      (`Intlit "12345678901234567890123", "12345678901234567890123");
    ]

let a_string_snippet_still_reaches_the_model () =
  let outcome, _ = search_of () in
  check_opt_string
    "the guard must not change a well-formed payload"
    (Some
       "The default method by which SQLite implements atomic commit is a rollback \
        journal.")
    (hd "results" outcome.results).result.snippet

(* {1 The request} *)

let post_with_both_headers_and_the_body () =
  let _, request = search_of ~query:(query ~text:"wal mode" ~max_results:3 ()) () in
  check_bool "the method" true (request.Caps.Authority.Net.meth = `POST);
  check_string "the DSN host carries the app id, the path carries the index"
    "https://app123-dsn.algolia.net/1/indexes/products/query"
    (Uri.to_string request.Caps.Authority.Net.uri);
  check_opt_string "the Application-ID header names the deployment" (Some app_id)
    (List.assoc_opt "x-algolia-application-id" request.Caps.Authority.Net.headers);
  check_opt_string "the API key header authorises the index" (Some test_key)
    (List.assoc_opt "x-algolia-api-key" request.Caps.Authority.Net.headers);
  check_opt_string "and a JSON body needs its content type" (Some "application/json")
    (List.assoc_opt "Content-Type" request.Caps.Authority.Net.headers);
  check_opt_string "the query" (Some "wal mode") (body_field "query" request);
  check_opt_string "hitsPerPage follows max_results" (Some "3")
    (body_field "hitsPerPage" request)

let the_index_is_percent_encoded_in_the_path () =
  (* The slash is encoded so it cannot escape the index segment; the host stays
     the deployment's. *)
  let encoded = Algolia.endpoint_of_deployment ~app_id ~index:"products/2026" in
  check_string "the encoded segment"
    "https://app123-dsn.algolia.net/1/indexes/products%2F2026/query"
    (Uri.to_string encoded);
  check_string "and the host is still the deployment" "app123-dsn.algolia.net"
    (Option.value ~default:"?" (Uri.host encoded));
  let request =
    let sent = ref None in
    let net =
      {
        Provider.Net.request =
          (fun request ->
            sent := Some request;
            Ok { Caps.Authority.Net.status = 200; headers = []; body = sample });
      }
    in
    let provider =
      Algolia.make ~app_id ~key:test_key
        ~endpoint:(Algolia.endpoint_of_deployment ~app_id ~index:"products/2026")
        ~net ()
    in
    ignore (Provider.search provider (query ()));
    Option.get !sent
  in
  check_string "the adapter dials the encoded path"
    "https://app123-dsn.algolia.net/1/indexes/products%2F2026/query"
    (Uri.to_string request.Caps.Authority.Net.uri)

let the_app_id_rides_the_header_and_the_host () =
  (* The pair in one fact: the same [app_id] builds the host's left half and fills
     the header, so a request that reaches a host cannot claim another deployment. *)
  let _, request = search_of () in
  check_string "the host carries it" "app123-dsn.algolia.net"
    (Option.value ~default:"?" (Uri.host request.Caps.Authority.Net.uri));
  check_string "the header carries it" app_id
    (Option.value ~default:"?"
       (List.assoc_opt "x-algolia-application-id" request.Caps.Authority.Net.headers));
  check_bool "and no credential rides the URL" false
    (contains ~haystack:(Uri.to_string request.Caps.Authority.Net.uri) ~needle:test_key)

(* {1 The constraint report} *)

let an_unconstrained_query_has_no_notice () =
  let outcome, _ = search_of () in
  check_opt_string "nothing dropped" None outcome.notice;
  check_string "named by the adapter that served it" "algolia" outcome.provider;
  check_opt_number "billed for the request itself" (Some 0.0005) outcome.cost_usd

let dropped_constraints_are_noticed_and_not_sent () =
  let outcome, request =
    search_of
      ~query:
        (query ~include_domains:["sqlite.org"] ~recency:Model.Day ~country:"de"
           ~language:"de" ~safe_search:true ())
      ()
  in
  let notice = Option.get outcome.notice in
  List.iter
    (fun token -> includes ("the notice names " ^ token) token notice)
    [ "domain"; "dates"; "country/language"; "safe-search" ];
  (* The body carries no filter keys at all: there is no field to send, so the
     adapter must not invent one and let a caller believe its filter ran. *)
  List.iter
    (fun name ->
      check_bool ("no " ^ name ^ " field is invented") false (has_body_field name request))
    [ "filters"; "facetFilters"; "numericFilters"; "tagFilters"; "restrictSearchableAttributes" ];
  check_string "the whole document, even constrained"
    "{\"query\":\"q\",\"hitsPerPage\":5}"
    (Yojson.Safe.to_string (body_of request))

let safe_search_false_is_noticed_too () =
  (* Both values of the boolean are drops here: there is no safety parameter, so
     a caller asking for the filter {i off} is ignored exactly as completely as
     one asking for it on. *)
  List.iter
    (fun value ->
      let outcome, _ = search_of ~query:(query ~safe_search:value ()) () in
      check_string "the safe-search sentence"
        "cannot filter by safe-search; that constraint was ignored"
        (Option.get outcome.notice))
    [ true; false ]

(* {1 The failures this adapter owns}

   The rows every HTTP adapter owes are pinned once for all of them by
   test_provider_contract.ml. What stays here is the quota pair — 402 is Algolia's
   [FeatureNotEnabled], a plan question like the 429 rate limit — and the leak
   regression for the place this key actually rides. *)

let the_plan_and_the_rate_limit_are_quota () =
  List.iter
    (fun status ->
      let provider, _ = dial ~status ~body:{|{"message":"no"}|} () in
      match Provider.search provider (query ()) with
      | Ok _ -> A.failf "HTTP %d was accepted" status
      | Error failure ->
          check_string "the house sentence" "quota exhausted" failure.message;
          check_string (Printf.sprintf "HTTP %d is quota" status) "quota"
            (match failure.kind with Provider.Quota -> "quota" | Provider.Failure -> "failure");
          check_bool "a spent quota is not transient" false failure.retryable)
    [ 402; 429 ]

let a_network_failure_does_not_echo_the_request () =
  let provider =
    refusal Caps.Error.Denied
      ~message:"connection refused, x-algolia-api-key: test-key"
  in
  match Provider.search provider (query ()) with
  | Ok _ -> A.failf "a refused grant was accepted"
  | Error failure ->
      check_string "the network row" "network error" failure.message;
      check_bool "nothing about the request rides along" false
        (contains ~haystack:(Provider.render_error failure) ~needle:test_key)

(* {1 Cost and endpoint} *)

let the_cost_does_not_scale_with_result_count () =
  check_number "one call" 0.0005 (Algolia.cost_for ~cost_per_1k:0.5 1);
  check_number "and the same call at twenty results" 0.0005 (Algolia.cost_for ~cost_per_1k:0.5 20)

let the_default_price_is_the_grow_overage_rate () =
  (* The cheapest {i paid} rate: free is 10K requests a month, and the key is
     mandatory on every tier, so the plan decides the price and the credential
     never does. *)
  let provider, _ = dial () in
  check_number "the published figure" 0.50 (Provider.cost_per_1k provider);
  let provider, _ = dial ~cost_per_1k:1.75 () in
  check_number "and the Grow Plus correction, which reaches the adapter" 1.75
    (Provider.cost_per_1k provider)

let a_search_that_returns_nothing_still_costs () =
  (* Billed per request, whatever it returns: an empty [hits[]] is a served search
     at the same price. *)
  let outcome, _ = search_of ~body:{|{"hits": []}|} () in
  check_int "no results" 0 (List.length outcome.results);
  check_opt_number "still billed" (Some 0.0005) outcome.cost_usd

let the_snippet_cap_follows_the_policy () =
  let body =
    Yojson.Safe.to_string
      (`Assoc
         [
           ( "hits"
       , `List
           [
             `Assoc
               [
                 ("title", `String "t");
                 ("url", `String "https://example.com/a");
                 ("description", `String (String.make 40 'x'));
               ];
           ] );
         ])
  in
  let outcome, _ = search_of ~snippet_chars:10 ~body () in
  let hit = hd "results" outcome.results in
  check_opt_string "clipped with the ellipsis" (Some (String.make 10 'x' ^ "…"))
    hit.result.snippet;
  check_bool "the pre-cap length is reported" true (hit.uncapped_chars = Some 40)

let the_endpoint_is_the_deployment_the_grant_allows () =
  check_string "the derivation" "https://app123-dsn.algolia.net/1/indexes/products/query"
    (Uri.to_string deployment);
  let _, request = search_of () in
  check_string "and the adapter dials exactly that" (Uri.to_string deployment)
    (Uri.to_string request.Caps.Authority.Net.uri)

let () =
  A.
    (run "seekwright/algolia"
       [
         ( "parsing schemaless records"
         , [
             test_case "the default chains fill all three fields" `Quick
               the_default_chains_fill_all_three_fields;
             test_case "the hierarchy title uses the deepest non-empty level" `Quick
               the_hierarchy_title_uses_the_deepest_level;
             test_case "explicit attrs win over the default chain" `Quick
               explicit_attrs_win_over_the_default_chain;
             test_case "a single named snippet attr replaces the chain" `Quick
               a_single_named_snippet_attr_replaces_the_chain;
             test_case "hits missing a title or url are dropped" `Quick
               hits_missing_a_title_or_url_are_dropped;
             test_case "non-object records are skipped" `Quick
               non_object_records_are_skipped;
             test_case "missing hits container is empty, not an error" `Quick
               missing_hits_container_is_empty_not_an_error;
             test_case "the limit is honoured" `Quick the_limit_is_honoured;
             test_case "nothing is invented per hit" `Quick nothing_is_invented_per_hit;
           ] );
         ( "the upstream field guards"
         , [
             test_case "a non-string snippet attribute is dropped and the call succeeds"
               `Quick a_non_string_snippet_attribute_is_dropped_and_the_call_succeeds;
             test_case "a numeric snippet attribute is still coerced" `Quick
               a_numeric_snippet_attribute_is_still_coerced;
             test_case "a string snippet still reaches the model" `Quick
               a_string_snippet_still_reaches_the_model;
           ] );
         ( "the request"
         , [
             test_case "POST with both headers and the body" `Quick
               post_with_both_headers_and_the_body;
             test_case "the index is percent-encoded in the path" `Quick
               the_index_is_percent_encoded_in_the_path;
             test_case "the app id rides the header and the host" `Quick
               the_app_id_rides_the_header_and_the_host;
           ] );
         ( "the constraint report"
         , [
             test_case "an unconstrained query has no notice" `Quick
               an_unconstrained_query_has_no_notice;
             test_case "dropped constraints are noticed and not sent" `Quick
               dropped_constraints_are_noticed_and_not_sent;
             test_case "safe-search false is noticed too" `Quick
               safe_search_false_is_noticed_too;
           ] );
         ( "the failures this adapter owns"
         , [
             test_case "the plan and the rate limit are quota" `Quick
               the_plan_and_the_rate_limit_are_quota;
             test_case "a network failure does not echo the request" `Quick
               a_network_failure_does_not_echo_the_request;
           ] );
         ( "cost and endpoint"
         , [
             test_case "the cost does not scale with result count" `Quick
               the_cost_does_not_scale_with_result_count;
             test_case "the default price is the Grow overage rate" `Quick
               the_default_price_is_the_grow_overage_rate;
             test_case "a search that returns nothing still costs" `Quick
               a_search_that_returns_nothing_still_costs;
             test_case "the snippet cap follows the policy" `Quick
               the_snippet_cap_follows_the_policy;
             test_case "the endpoint is the deployment the grant allows" `Quick
               the_endpoint_is_the_deployment_the_grant_allows;
           ] );
       ])
