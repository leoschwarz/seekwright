(* Hermetic pins for the live harness. No socket, no key and no clock: the case
   table, the one-selector rule and the per-adapter assertions are values, so a
   live vendor call is never needed to know whether the harness would accept a
   response. The tests that do reach a provider are not here and never run under
   [dune runtest]. *)

module Cases = Live_harness.Cases
module Checks = Live_harness.Checks
module Config = Seekwright.Config
module Model = Seekwright.Model
module Registry = Seekwright_factory.Registry
module A = Alcotest

let contains haystack needle =
  let h = String.length haystack and n = String.length needle in
  let rec go i = i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1)) in
  n = 0 || go 0

let names selectors = List.map Cases.name selectors

let result ?snippet ?text ?(title = "A title") ?(url = "https://example.com/page") () =
  {
    Model.title;
    url;
    snippet;
    text;
    text_truncated = None;
    published_date = None;
    score = None;
  }

let response ?(query = "q") ?(provider = "freeserp") ?(results = []) ?answer ?notice () =
  { Model.query; provider; results; answer; retrieved_at = None; notice }

let page ?(url = "https://example.com/") ?(title = None) ?(text = "Example Domain")
    ?(content_type = Some "text/html") ?(status_code = Some 200) () =
  {
    Model.url;
    requested_url = "https://example.com/";
    title;
    text = Some text;
    content_type;
    status_code;
    retrieved_at = None;
    truncated = false;
    total_chars = None;
    offset = None;
    matches = None;
    image = None;
    notice = None;
  }

let answer ?(answer = "It is a forge.") ?(sources = []) ?(depth = Model.Brief)
    ?(searches = 1) ?notice () =
  {
    Model.query = "q";
    answer;
    sources;
    model = "operator-model";
    depth;
    searches;
    fetched = 0;
    retrieved_at = None;
    truncated = None;
    notice;
  }

let source = { Model.source_title = "Gitea"; source_url = "https://gitea.io/"; source_provider = "freeserp" }

(* {1 The vocabulary} *)

let test_every_case_has_one_selector () =
  let all = Cases.all in
  A.(check int "17 providers + 6 fetch cases + 2 agent depths" 25 (List.length all));
  A.(check int "no selector is listed twice" (List.length all)
       (List.length (List.sort_uniq String.compare (names all))));
  List.iter
    (fun name ->
      match Cases.parse name with
      | Ok (Cases.Provider parsed) ->
          A.(check string "a provider parses back to itself" name parsed)
      | Ok _ -> A.failf "%s parsed as something other than a provider" name
      | Error message -> A.failf "%s did not parse: %s" name message)
    Config.known_providers

let test_fetch_and_agent_selectors () =
  let expect spelling expected =
    match Cases.parse spelling with
    | Ok selector -> A.(check string "the selector" expected (Cases.name selector))
    | Error message -> A.failf "%s did not parse: %s" spelling message
  in
  expect "fetch:local" "fetch:local";
  expect "fetch:metadata" "fetch:metadata";
  expect "fetch:jina" "fetch:jina";
  expect "fetch:scrappa" "fetch:scrappa";
  expect "fetch:tavily" "fetch:tavily";
  expect "fetch:linkup" "fetch:linkup";
  expect "agent:brief" "agent:brief";
  expect "agent:report" "agent:report";
  (* A flavoured provider name has a colon too, and must stay a provider. *)
  expect "exa:free" "exa:free"

let test_there_is_no_all_providers_mode () =
  let refused spelling =
    match Cases.parse spelling with
    | Ok selector -> A.failf "%S selected %s, but a sweep must not exist" spelling (Cases.name selector)
    | Error message ->
        A.(check bool ("the refusal for " ^ spelling ^ " has a sentence") true
             (String.length (String.trim message) > 0));
        message
  in
  List.iter
    (fun spelling ->
      let message = refused spelling in
      A.(check bool "the sweep spellings name the one-case rule" true
           (contains message "exactly one" || contains message "named")))
    [ ""; "all"; "*"; "every" ];
  let message = refused "fetch:" in
  A.(check bool "an empty fetch case names the namespace" true (contains message "fetch case"));
  let message = refused "agent:deep" in
  A.(check bool "an unknown agent case names the namespace" true (contains message "agent case"))

let test_every_provider_has_ported_steps () =
  List.iter
    (fun name ->
      let steps = Cases.provider_steps name in
      A.(check bool (name ^ " has at least one step") true (steps <> []));
      List.iter
        (fun (step : Cases.step) ->
          A.(check bool (name ^ "'s step has a query") true
               (String.length (String.trim step.Cases.spec.Cases.query) > 0));
          A.(check bool (name ^ "'s step has a label") true
               (String.length (String.trim step.Cases.label) > 0)))
        steps)
    Config.known_providers

let test_build_status_follows_the_registry () =
  let expect selector expected =
    match Cases.build_status selector with
    | Cases.Runnable -> A.(check string "runnable as the registry says" expected "runnable")
    | Cases.Deferred wave -> A.(check string "deferred as the registry says" expected wave)
  in
  expect (Cases.Provider "freeserp") "runnable";
  expect (Cases.Provider "anysearch") "runnable";
  expect (Cases.Provider "exa") "F5.1";
  expect (Cases.Provider "parallel:free") "F5.1";
  expect (Cases.Provider "serper") "F5.2";
  expect (Cases.Provider "tavily") "F5.3";
  expect (Cases.Provider "algolia") "F5.4";
  expect (Cases.Provider "deepseek") "F5.5";
  expect (Cases.Fetch Cases.Local) "runnable";
  expect (Cases.Fetch Cases.Metadata) "runnable";
  expect (Cases.Fetch Cases.Jina) "F6.1";
  expect (Cases.Agent Model.Brief) "runnable"

let test_cost_classes () =
  let unbilled selector = A.(check bool (Cases.name selector ^ " is unbilled") true (Cases.cost_class selector = Cases.Unbilled)) in
  let billed selector = A.(check bool (Cases.name selector ^ " is billed") true (Cases.cost_class selector = Cases.Billed)) in
  List.iter unbilled
    [
      Cases.Provider "exa:free";
      Cases.Provider "parallel:free";
      Cases.Provider "freeserp";
      Cases.Provider "anysearch";
      Cases.Provider "tinyfish";
    ];
  List.iter billed
    [
      Cases.Provider "serper";
      Cases.Provider "exa";
      Cases.Provider "algolia";
      Cases.Fetch Cases.Scrappa;
      Cases.Fetch Cases.Tavily;
      Cases.Agent Model.Brief;
    ];
  unbilled (Cases.Fetch Cases.Local);
  unbilled (Cases.Fetch Cases.Jina)

(* The published header names variables, not values: a sentinel key in the
   environment must not reach any line the harness prints for the case. *)
let test_no_secret_reaches_a_printed_line () =
  Unix.putenv "SEEKWRIGHT_SERPER_API_KEY" "sentinel-secret-value";
  Unix.putenv "SEEKWRIGHT_AGENT_API_KEY" "sentinel-secret-value";
  let selector = Cases.Provider "serper" in
  let agent = Cases.Agent Model.Brief in
  let lines =
    [ Cases.cost_prose selector; Cases.route selector; Cases.credential selector ]
    @ Cases.needs selector
    @ [ Cases.cost_prose agent; Cases.route agent; Cases.credential agent ]
    @ Cases.needs agent
  in
  List.iter
    (fun line ->
      A.(check bool ("no secret in " ^ line) false (contains line "sentinel-secret-value")))
    lines;
  A.(check (list string) "the key's variable is named" [ "SEEKWRIGHT_SERPER_API_KEY" ]
       (Cases.needs selector));
  A.(check string "the credential line names the variable" "SEEKWRIGHT_SERPER_API_KEY"
       (Cases.credential selector));
  Unix.putenv "SEEKWRIGHT_SERPER_API_KEY" "";
  Unix.putenv "SEEKWRIGHT_AGENT_API_KEY" ""

let test_live_status_agrees_with_the_records () =
  let from_record selector =
    match selector with
    | Cases.Provider name -> (
        match Registry.row name with
        | Some row -> row.Registry.ocaml_live_tested
        | None -> false)
    | Cases.Fetch _ | Cases.Agent _ -> List.mem (Cases.name selector) Cases.recorded_non_provider_runs
  in
  let with_record = List.filter from_record Cases.all in
  let with_status =
    List.filter (fun selector -> Cases.live_status selector = `Tested) Cases.all
  in
  A.(check (list string) "the harness and the records name the same cases"
       (names with_record) (names with_status))

(* {1 The per-adapter assertions} *)

let failures checks = Checks.failed_count checks

let test_freeserp_is_a_serp_backend () =
  let good =
    response ~results:[ result ~snippet:"A snippet" () ] ()
  in
  A.(check int "a snippet result passes every freeserp check" 0
       (failures (Checks.provider_step ~name:"freeserp" ~step:0 good)));
  let with_text =
    response ~results:[ result ~snippet:"A snippet" ~text:"page text" () ] ()
  in
  A.(check bool "a SERP result carrying text fails" true
       (failures (Checks.provider_step ~name:"freeserp" ~step:0 with_text) > 0));
  let no_snippet = response ~results:[ result ~text:"page text" () ] () in
  A.(check bool "a result with no snippet fails" true
       (failures (Checks.provider_step ~name:"freeserp" ~step:0 no_snippet) > 0));
  let empty = response () in
  A.(check bool "an empty result set fails" true
       (failures (Checks.provider_step ~name:"freeserp" ~step:0 empty) > 0))

let test_a_content_backend_never_carries_a_snippet () =
  let content = response ~provider:"parallel" ~results:[ result ~text:"page text" () ] () in
  A.(check int "text without a snippet passes parallel" 0
       (failures (Checks.provider_step ~name:"parallel" ~step:0 content)));
  let mixed = response ~provider:"parallel" ~results:[ result ~text:"page text" ~snippet:"s" () ] () in
  A.(check bool "a snippet on a content backend fails" true
       (failures (Checks.provider_step ~name:"parallel" ~step:0 mixed) > 0))

let test_an_answer_backend_answers () =
  let good =
    response ~provider:"tavily"
      ~results:[ result ~text:"page text" () ]
      ~answer:"A synthesised answer" ()
  in
  A.(check int "text, no snippet and an answer pass tavily" 0
       (failures (Checks.provider_step ~name:"tavily" ~step:0 good)));
  let no_answer = response ~provider:"tavily" ~results:[ result ~text:"page text" () ] () in
  A.(check bool "a missing answer fails tavily" true
       (failures (Checks.provider_step ~name:"tavily" ~step:0 no_answer) > 0))

let test_deepseek_may_fill_both_fields () =
  let deepseek =
    response ~provider:"deepseek" ~results:[ result ~snippet:"s" ~text:"t" () ] ()
  in
  A.(check int "snippet and text together pass deepseek" 0
       (failures (Checks.provider_step ~name:"deepseek" ~step:0 deepseek)))

let test_a_domain_filter_is_asserted () =
  let constrained =
    response ~provider:"serper"
      ~results:[ result ~url:"https://python.org/downloads" () ] ()
  in
  A.(check int "a python.org result passes the filter step" 0
       (failures (Checks.provider_step ~name:"serper" ~step:1 constrained)));
  let leaked = response ~provider:"serper" ~results:[ result ~url:"https://example.com/" () ] () in
  A.(check bool "an off-domain result fails the filter step" true
       (failures (Checks.provider_step ~name:"serper" ~step:1 leaked) > 0))

let test_a_substituted_provider_is_an_unexpected_call () =
  let substituted = response ~provider:"freeserp" ~results:[ result ~snippet:"s" () ] () in
  A.(check int "the mismatch is one failure" 1
       (failures (Checks.provider_step ~name:"serper" ~step:0 substituted)))

let test_a_step_with_no_ported_assertion_fails () =
  let response = response ~provider:"serper" ~results:[ result ~snippet:"s" () ] () in
  A.(check bool "an unported step never passes vacuously" true
       (failures (Checks.provider_step ~name:"serper" ~step:7 response) > 0));
  A.(check bool "an unported name never passes vacuously" true
       (failures (Checks.provider_step ~name:"unknown" ~step:0 response) > 0))

(* {1 Fetch and agent} *)

let test_the_local_reader_shape () =
  A.(check int "a real page passes" 0 (failures (Checks.verify_fetch Cases.Local (page ()))));
  let stripped = page ~text:"nothing useful here" () in
  A.(check bool "a page without its own text fails" true
       (failures (Checks.verify_fetch Cases.Local stripped) > 0));
  let wrong_type = page ~content_type:(Some "text/plain") () in
  A.(check bool "the content type is asserted" true
       (failures (Checks.verify_fetch Cases.Local wrong_type) > 0))

let test_the_agent_contract () =
  A.(check int "a cited brief passes" 0
       (failures (Checks.verify_agent ~depth:Model.Brief ~model:"operator-model"
                   (answer ~sources:[ source ] ()))));
  A.(check int "an uncited answer with the notice passes" 0
       (failures (Checks.verify_agent ~depth:Model.Brief ~model:"operator-model"
                   (answer ~notice:"the prose carries no citations" ()))));
  A.(check bool "an uncited answer with no notice fails" true
       (failures (Checks.verify_agent ~depth:Model.Brief ~model:"operator-model" (answer ())) > 0));
  A.(check bool "a brief call with two searches fails" true
       (failures (Checks.verify_agent ~depth:Model.Brief ~model:"operator-model"
                   (answer ~searches:2 ~sources:[ source ] ())) > 0));
  A.(check int "a report with three searches passes" 0
       (failures (Checks.verify_agent ~depth:Model.Report ~model:"operator-model"
                   (answer ~depth:Model.Report ~searches:3 ~sources:[ source ] ()))));
  A.(check bool "a different model fails" true
       (failures (Checks.verify_agent ~depth:Model.Brief ~model:"other-model"
                   (answer ~sources:[ source ] ())) > 0))

(* {1 Classification and the summary} *)

let test_a_rate_limited_run_is_inconclusive () =
  A.(check bool "the engine's quota advice is recognised" true
       (Checks.quota_limited
          "Search failed - anysearch: out of credits or rate limited. Do not retry immediately."));
  A.(check bool "a parser failure is not inconclusive" false
       (Checks.quota_limited "Search failed - serper: HTTP 500. Retry shortly."))

let test_the_summary_counts_failures () =
  let checks =
    [ Checks.passing "a"; Checks.expect "b" true ""; Checks.expect "c" false "nope" ]
  in
  A.(check int "one failure" 1 (Checks.failed_count checks));
  A.(check string "the summary names the ratio" "FAILED: 1 of 3 checks failed"
       (Checks.summary checks));
  A.(check string "all passed" "passed (2 checks)"
       (Checks.summary [ Checks.passing "a"; Checks.passing "b" ]))

let () =
  A.run "live harness"
    [
      ( "the case inventory",
        [
          A.test_case "every case has one selector" `Quick test_every_case_has_one_selector;
          A.test_case "fetch and agent selectors" `Quick test_fetch_and_agent_selectors;
          A.test_case "no all-providers mode" `Quick test_there_is_no_all_providers_mode;
          A.test_case "every provider has ported steps" `Quick test_every_provider_has_ported_steps;
          A.test_case "build status follows the registry" `Quick test_build_status_follows_the_registry;
          A.test_case "cost classes" `Quick test_cost_classes;
          A.test_case "no secret reaches a printed line" `Quick test_no_secret_reaches_a_printed_line;
          A.test_case "live status agrees with the records" `Quick test_live_status_agrees_with_the_records;
        ] );
      ( "the per-adapter assertions",
        [
          A.test_case "freeserp is a SERP backend" `Quick test_freeserp_is_a_serp_backend;
          A.test_case "a content backend carries no snippet" `Quick
            test_a_content_backend_never_carries_a_snippet;
          A.test_case "an answer backend answers" `Quick test_an_answer_backend_answers;
          A.test_case "deepseek may fill both" `Quick test_deepseek_may_fill_both_fields;
          A.test_case "a domain filter is asserted" `Quick test_a_domain_filter_is_asserted;
          A.test_case "a substituted provider is an unexpected call" `Quick
            test_a_substituted_provider_is_an_unexpected_call;
          A.test_case "an unported step fails" `Quick test_a_step_with_no_ported_assertion_fails;
        ] );
      ( "fetch, agent and classification",
        [
          A.test_case "the local reader shape" `Quick test_the_local_reader_shape;
          A.test_case "the agent contract" `Quick test_the_agent_contract;
          A.test_case "a rate-limited run is inconclusive" `Quick test_a_rate_limited_run_is_inconclusive;
          A.test_case "the summary counts failures" `Quick test_the_summary_counts_failures;
        ] );
    ]
