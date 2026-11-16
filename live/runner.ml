(* The running half. Every construction path is the application's own: the
   provider registry, the fetch stack and the app are built by
   [Seekwright_factory], so a live run exercises the grants, timeouts and
   routing the served process uses rather than a harness-only shortcut.

   The harness adds exactly three things around that: the header (route, spend
   class, credential variable name — never a value), the checks read off the
   response, and a status the process can exit with. *)

module Cases = Cases
module Checks = Checks
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Factory = Seekwright_factory.Factory
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Registry = Seekwright_factory.Registry
module Server = Seekwright.Server

type status =
  | Passed
  | Skipped of string
  | Failed of string
  | Inconclusive of string

let status_exit = function
  | Passed | Skipped _ -> 0
  | Failed _ -> 1
  | Inconclusive _ -> 3

(* A live run's own lines are the report. The engines' log sink stays silent:
   a maintainer reading a one-case run wants the checks, and the audit lines
   would bury them. Nothing here can print a secret either way. *)
let no_log _level _event _fields = ()

(* One-shot process: no cooldown or millisecond field in a live report depends
   on a monotonic base, so the wall clock is enough for both of the engines'
   injected clocks. *)
let clock () = Unix.gettimeofday ()
let now () = Unix.gettimeofday ()

(* An environment variable the case needs, read as presence only: a live run
   never prints a value, and an empty one is an absence. *)
let env_value variable =
  match Sys.getenv_opt variable with
  | Some value when String.length value > 0 -> Some value
  | _ -> None

let live_status_prose selector =
  match Cases.live_status selector with
  | `Tested -> "recorded live run"
  | `Untested -> "untested live run"

let emit_header emit selector =
  emit (Printf.sprintf "seekwright live: %s" (Cases.name selector));
  emit "gate       SEEKWRIGHT_LIVE_TESTS=1";
  emit ("route      " ^ Cases.route selector);
  emit ("credential " ^ Cases.credential selector);
  emit ("cost       " ^ Cases.cost_prose selector);
  emit ("status     " ^ live_status_prose selector)

let print_checks emit checks =
  List.iter
    (fun (check : Checks.check) ->
      match check.Checks.failure with
      | None -> emit ("  [ok]   " ^ check.Checks.label)
      | Some sentence -> emit ("  [fail] " ^ check.Checks.label ^ " — " ^ sentence))
    checks

let conclude emit checks =
  let sentence = Checks.summary checks in
  emit ("result     " ^ sentence);
  if Checks.failed_count checks = 0 then Passed else Failed sentence

let skipped emit reason =
  emit ("result     skipped: " ^ reason);
  Skipped reason

let failed emit reason =
  emit ("result     FAILED: " ^ reason);
  Failed reason

let inconclusive emit reason =
  emit ("result     inconclusive: " ^ reason);
  Inconclusive reason

let to_query (spec : Cases.query_spec) : Model.search_query =
  {
    query = spec.Cases.query;
    max_results = spec.Cases.max_results;
    include_domains = spec.Cases.include_domains;
    exclude_domains = spec.Cases.exclude_domains;
    country = spec.Cases.country;
    language = None;
    recency = spec.Cases.recency;
    safe_search = None;
  }

let describe_step (spec : Cases.query_spec) =
  let filters =
    List.filter_map
      (fun (name, value) -> if value = "" then None else Some (name ^ "=" ^ value))
      [
        ("include_domains", String.concat "," spec.Cases.include_domains);
        ("country", Option.value ~default:"" spec.Cases.country);
        ( "recency"
        , match spec.Cases.recency with
          | None -> ""
          | Some Model.Day -> "day"
          | Some Model.Week -> "week"
          | Some Model.Month -> "month"
          | Some Model.Year -> "year" );
      ]
  in
  Printf.sprintf "query %S, max_results %d%s" spec.Cases.query spec.Cases.max_results
    (match filters with [] -> "" | _ -> ", " ^ String.concat ", " filters)

let run_provider_steps ~config ~(built : Factory.providers) ~name ~emit =
  let engine =
    Engine.Search.create config built.Factory.built ~log:no_log ~clock ~now ()
  in
  let steps = Cases.provider_steps name in
  let total = List.length steps in
  let rec go index collected = function
    | [] -> conclude emit collected
    | step :: rest ->
        emit (Printf.sprintf "step %d/%d  %s" (index + 1) total step.Cases.label);
        emit ("          " ^ describe_step step.Cases.spec);
        (match Engine.Search.search engine ~provider:name (to_query step.Cases.spec) with
        | Ok response ->
            let checks = Checks.provider_step ~name ~step:index response in
            print_checks emit checks;
            go (index + 1) (collected @ checks) rest
        | Error (Engine.Search.Failed message) ->
            print_checks emit [ Checks.expect "the search completes" false message ];
            if Checks.quota_limited message then inconclusive emit message else failed emit message
        | Error (Engine.Search.Refused message) ->
            (* A named, built, permitted provider is terminal, so a refusal here
               means the harness and the router disagree about this deployment:
               an unexpected route, which is a failure rather than a skip. *)
            print_checks
              emit
              [
                Checks.expect "a named provider the deployment built is served"
                  false
                  ("the route refused it: " ^ message);
              ];
            failed emit ("the route refused " ^ name ^ ": " ^ message))
  in
  go 0 [] steps

let run_provider ~env ~sw ~name ~emit =
  let selector = Cases.Provider name in
  emit_header emit selector;
  match Cases.build_status selector with
  | Cases.Deferred wave ->
      skipped emit (Printf.sprintf "not built on this port — the adapter lands with wave %s" wave)
  | Cases.Runnable -> (
      match Cases.provider_config name with
      | Error reason -> skipped emit reason
      | Ok pc -> (
          match Config.resolve ~providers:[ (name, pc) ] () with
          | Error message ->
              failed emit (Printf.sprintf "the harness could not build a config for %s: %s" name message)
          | Ok config -> (
              match Registry.row name with
              | None -> failed emit (name ^ " has no registry row")
              | Some row -> (
                  match Registry.missing_prerequisite row pc with
                  | Some reason -> skipped emit reason
                  | None ->
                      let built : Factory.providers =
                        Factory.build_providers ~sw ~net:env#net
                          ~mono_clock:env#mono_clock ~now config
                      in
                      let status =
                        match List.assoc_opt name built.Factory.grant_errors with
                        | Some message ->
                            failed emit
                              (Printf.sprintf "the grant for %s could not be built: %s" name message)
                        | None -> (
                            match List.assoc_opt name built.Factory.built with
                            | None ->
                                failed emit
                                  (Printf.sprintf
                                     "%s is enabled and configured, but this build did not construct it"
                                     name)
                            | Some _ -> run_provider_steps ~config ~built ~name ~emit)
                      in
                      (* Every provider this build constructed is closed once,
                         after the case: the adapters' [aclose] is a no-op today,
                         but an MCP-backed one owns a session. *)
                      List.iter (fun (_, provider) -> Provider.aclose provider) built.Factory.built;
                      status))))

let close_stack (local : Engine.Fetch.fetcher) (fallbacks : Engine.Fetch.fetcher list) =
  local.aclose ();
  List.iter (fun (fallback : Engine.Fetch.fetcher) -> fallback.aclose ()) fallbacks

(* How a fetch case reaches its page. [Local_page] and [Metadata_refusal] are the
   two this server's own reader answers; a [Vendor_route name] case goes through
   that rung by name, which is what a caller naming [fetch(provider=...)] asks
   for. The oracle's live suite instantiates each fallback class directly; this
   harness goes through the application's own construction instead, so the run
   covers the vendor grant, the key read, the request shape and the envelope
   parse the served process uses rather than a harness-only shortcut. *)
type dispatch =
  | Local_page
  | Metadata_refusal
  | Vendor_route of string

let dispatch_of_case = function
  | Cases.Local -> Local_page
  | Cases.Metadata -> Metadata_refusal
  | Cases.Jina -> Vendor_route "jina"
  | Cases.Scrappa -> Vendor_route "scrappa"
  | Cases.Tavily -> Vendor_route "tavily"
  | Cases.Linkup -> Vendor_route "linkup"

(* [build_fetch_stack] constructs only the rungs the config lists, so a vendor
   case declares its one rung in [fetch.fallback]. That is also the harness's
   guarantee against spending an unplanned call: with exactly that name in the
   ladder, no other vendor exists for this run to reach, and the ladder check
   below is what proves it. *)
let fetch_settings selector =
  match dispatch_of_case selector with
  | Vendor_route name -> { Config.default_fetch_config with fallback = Some [ name ] }
  | _ -> Config.default_fetch_config

(* The ladder this run built, by name: the sentence a failure prints, and the
   check that keeps a vendor case from being served by someone else's API. *)
let ladder_names fallbacks =
  List.map (fun (fallback : Engine.Fetch.fetcher) -> fallback.Engine.Fetch.name) fallbacks

let ladder_check (selector : Cases.fetch_case) fallbacks =
  match dispatch_of_case selector with
  | Vendor_route name ->
      Checks.expect
        "the ladder holds exactly the route this case named, so no other vendor can serve the run"
        (ladder_names fallbacks = [ name ])
        (Printf.sprintf "this build constructed: %s"
           (String.concat ", " (ladder_names fallbacks)))
  | _ ->
      Checks.expect
        "no third-party fetch fallback is built, so this run cannot reach another vendor"
        (fallbacks = [])
        "this build constructed a fetch fallback, which one selected case must not reach"

(* A keyed fallback with no key in the environment is missing configuration, the
   same fact an absent provider key is for a provider case: [build_fetch_stack]
   honestly does not construct the rung. Skipping with the variable's name is
   what keeps that from arriving as a router refusal called a failure. *)
let missing_fetch_credential selector =
  match Cases.needs (Cases.Fetch selector) with
  | [] | "nothing" :: _ -> None
  | variables -> List.find_opt (fun variable -> env_value variable = None) variables

let run_fetch ~env ~sw ~case ~emit =
  let selector = Cases.Fetch case in
  emit_header emit selector;
  match Cases.build_status selector with
  | Cases.Deferred wave ->
      skipped emit (Printf.sprintf "not built on this port — the fallback lands with wave %s" wave)
  | Cases.Runnable -> (
      match missing_fetch_credential case with
      | Some variable ->
          skipped emit
            (Printf.sprintf "%s is not set: this deployment does not construct that fallback"
               variable)
      | None -> (
          match Config.resolve ~providers:[] ~fetch:(fetch_settings case) () with
          | Error message -> failed emit message
          | Ok config -> (
              (* Only the fetch stack is built: a fetch case dials no provider, and
                 the keyless default a config with no provider resolves to is never
                 constructed here. *)
              match Factory.build_fetch_stack ~sw ~net:env#net ~mono_clock:env#mono_clock config with
              | None -> failed emit "the config the harness built disables fetch"
              | Some (Error message) -> failed emit message
              | Some (Ok (local, fallbacks)) -> (
                  match
                    Engine.Fetch.create config local ~readers:Factory.readers ~fallbacks
                      ~log:no_log ~clock ~now ()
                  with
                  | Error message -> failed emit message
                  | Ok engine ->
                      let status =
                        match dispatch_of_case case with
                        | Local_page ->
                            emit "step 1/1  fetch and extract a real page";
                            emit (Printf.sprintf "          url %S" Checks.fetch_url);
                            (match Engine.Fetch.fetch engine Checks.fetch_url with
                            | Ok page ->
                                let checks =
                                  ladder_check case fallbacks :: Checks.verify_fetch case page
                                in
                                print_checks emit checks;
                                conclude emit checks
                            | Error (Engine.Fetch.Refused message) ->
                                failed emit ("the local reader refused a public page: " ^ message)
                            | Error (Engine.Fetch.Failed message) ->
                                failed emit ("the page could not be read: " ^ message))
                        | Metadata_refusal ->
                            emit "step 1/1  the cloud metadata endpoint must be refused";
                            emit "          url \"http://169.254.169.254/latest/meta-data/\"";
                            (match Engine.Fetch.fetch engine "http://169.254.169.254/latest/meta-data/" with
                            | Ok _ ->
                                let checks =
                                  [
                                    ladder_check case fallbacks;
                                    Checks.expect
                                      "the public-web grant refuses the cloud metadata endpoint"
                                      false
                                      "a page came back: the guardrail let the request out";
                                  ]
                                in
                                print_checks emit checks;
                                conclude emit checks
                            | Error (Engine.Fetch.Refused message) ->
                                let checks =
                                  [
                                    ladder_check case fallbacks;
                                    Checks.expect "the URL is refused before any request leaves"
                                      true "";
                                    Checks.expect "the refusal carries a sentence"
                                      (String.length (String.trim message) > 0)
                                      "the refusal carried no sentence";
                                  ]
                                in
                                print_checks emit checks;
                                conclude emit checks
                            | Error (Engine.Fetch.Failed message) ->
                                let checks =
                                  [
                                    Checks.expect
                                      "the URL is refused before any request leaves" false
                                      ("the refusal arrived as a mid-flight failure: " ^ message);
                                  ]
                                in
                                print_checks emit checks;
                                conclude emit checks)
                        | Vendor_route name ->
                            emit "step 1/1  the named fallback route reads a real page";
                            emit (Printf.sprintf "          provider %S, url %S" name Checks.fetch_url);
                            (match Engine.Fetch.fetch engine ~provider:name Checks.fetch_url with
                            | Ok page ->
                                let checks =
                                  ladder_check case fallbacks :: Checks.verify_fetch case page
                                in
                                print_checks emit checks;
                                conclude emit checks
                            | Error (Engine.Fetch.Refused message) ->
                                (* The ladder check above says this deployment built
                                   the rung, so a refusal here means the harness and
                                   the router disagree about the route: a failure,
                                   not a skip, and the sentence says who refused. *)
                                failed emit
                                  (Printf.sprintf "the route refused %s: %s" name message)
                            | Error (Engine.Fetch.Failed message) ->
                                (* A vendor that benches its own name answers with the
                                   quota branch, and a rate-limited run proves nothing
                                   about the envelope parser. *)
                                print_checks emit
                                  [ Checks.expect "the fallback answers with a page" false message ];
                                if Checks.quota_limited message then inconclusive emit message
                                else failed emit message)
                      in
                      close_stack local fallbacks;
                      status))))

let agent_question = function
  | Model.Brief -> "What is the Gitea project, and what licence is it released under?"
  | Model.Report ->
      "How does Gitea differ from its upstream forge, and under what licence is it developed?"

let run_agent ~env ~sw ~depth ~emit =
  let selector = Cases.Agent depth in
  emit_header emit selector;
  let missing =
    List.filter_map
      (fun variable -> if Option.is_some (env_value variable) then None else Some variable)
      [ "SEEKWRIGHT_AGENT_BASE_URL"; "SEEKWRIGHT_AGENT_MODEL"; "SEEKWRIGHT_AGENT_API_KEY" ]
  in
  match missing with
  | _ :: _ ->
      skipped emit
        (Printf.sprintf
           "agent mode needs SEEKWRIGHT_AGENT_BASE_URL, SEEKWRIGHT_AGENT_MODEL and \
            SEEKWRIGHT_AGENT_API_KEY; missing: %s"
           (String.concat ", " missing))
  | [] -> (
      let model = Option.value ~default:"" (env_value "SEEKWRIGHT_AGENT_MODEL") in
      let model_timeout =
        match env_value "SEEKWRIGHT_AGENT_MODEL_TIMEOUT_SECONDS" with
        | None -> 30.0
        | Some raw -> ( match float_of_string_opt raw with Some value -> value | None -> 30.0)
      in
      let agent_settings =
        {
          Config.default_agent_config with
          enabled = true;
          base_url = env_value "SEEKWRIGHT_AGENT_BASE_URL";
          model = Some model;
          model_timeout_seconds = model_timeout;
          (* The shipped whole-call budget must exceed the model leg, as the
             Python live suite raises both together: a slow reasoning model needs
             the leg raised, and raising only it moves where the call dies. *)
          timeout_seconds = max 90.0 (model_timeout +. 30.0);
        }
      in
      (* Retrieval rides the keyless readers; the only spend is the model call.
         [freeserp] alone is enabled on purpose: every reachable name must be a
         free one for the unnamed route to walk them, and it is the one keyless
         adapter this build carries. *)
      match
        Config.resolve
          ~providers:[ ("freeserp", Config.default_provider_config) ]
          ~agent:agent_settings ()
      with
      | Error message -> failed emit message
      | Ok config -> (
          match Config.missing_agent_settings config with
          | _ :: _ as missing ->
              skipped emit ("agent mode is missing: " ^ String.concat ", " missing)
          | [] -> (
              match
                Factory.build_app ~sw ~env ~now ~log:no_log ~allowed_hosts:[] config
              with
              | Error message -> failed emit ("the app could not be built: " ^ message)
              | Ok (app, built) -> (
                  let status =
                    match app.Server.agent with
                    | None -> failed emit "the app built without an agent engine"
                    | Some agent -> (
                        emit "step 1/1  one fixed retrieval plan, one model call";
                        emit (Printf.sprintf "          question %S, depth %s"
                                (agent_question depth)
                                (match depth with Model.Brief -> "brief" | Model.Report -> "report"));
                        match Seekwright.Agent.answer agent ~query:(agent_question depth) ~depth () with
                        | Ok response ->
                            let checks = Checks.verify_agent ~depth ~model response in
                            print_checks emit checks;
                            conclude emit checks
                        | Error message -> failed emit message)
                  in
                  List.iter
                    (fun (_, provider) -> Provider.aclose provider)
                    built.Factory.built;
                  status))))

let run ~env ~sw ~selector ~emit =
  match selector with
  | Cases.Provider name -> run_provider ~env ~sw ~name ~emit
  | Cases.Fetch case -> run_fetch ~env ~sw ~case ~emit
  | Cases.Agent depth -> run_agent ~env ~sw ~depth ~emit
