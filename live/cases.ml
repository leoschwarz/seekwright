(* The case inventory. Pure by construction: it reads the environment and the
   provider registry (both values, no sockets), which is what lets a hermetic
   suite pin the whole table and the selection rules with no network at all.

   The provider half is the Python live suite's per-adapter tests as data — one
   entry per frozen name, with the queries and filters those tests use — so the
   runner has one place to look and a deferred name is skipped by the registry
   row's own [build] field instead of by a second hand-maintained list. *)

module Config = Seekwright.Config
module Model = Seekwright.Model
module Registry = Seekwright_factory.Registry

type fetch_case = Local | Metadata | Jina | Scrappa | Tavily | Linkup

type selector = Provider of Config.name | Fetch of fetch_case | Agent of Model.depth

type query_spec = {
  query : string;
  max_results : int;
  include_domains : string list;
  exclude_domains : string list;
  country : string option;
  recency : Model.recency option;
}

type step = { label : string; spec : query_spec }

type cost_class = Unbilled | Billed

type build_status = Runnable | Deferred of string

let fetch_case_name = function
  | Local -> "local"
  | Metadata -> "metadata"
  | Jina -> "jina"
  | Scrappa -> "scrappa"
  | Tavily -> "tavily"
  | Linkup -> "linkup"

let fetch_cases = [ Local; Metadata; Jina; Scrappa; Tavily; Linkup ]

(* Provider selectors first, in the frozen order: an [exa:free] token has a
   colon and so does [fetch:local], and the provider test has to win. *)
let all =
  List.map (fun name -> Provider name) Config.known_providers
  @ List.map (fun case -> Fetch case) fetch_cases
  @ [ Agent Model.Brief; Agent Model.Report ]

let name = function
  | Provider provider -> provider
  | Fetch case -> "fetch:" ^ fetch_case_name case
  | Agent Model.Brief -> "agent:brief"
  | Agent Model.Report -> "agent:report"

(* {1 The searches} *)

let mk ?(max_results = 3) ?(include_domains = []) ?country ?recency query =
  {
    query;
    max_results;
    include_domains;
    exclude_domains = [];
    country;
    recency;
  }

let step label spec = { label; spec }

(* One entry per frozen name, in the order the Python suite presents them. The
   two searches an adapter gets are separate steps because they are separate
   wire shapes: a plain query and the same backend's domain constraint. The
   queries are the Python tests' own, so a live run here is comparable with a
   live run there. *)
let provider_steps name =
  match name with
  | "serper" ->
      [
        step "search" (mk ~max_results:5 "python 3.14 release notes");
        step "domain filter" (mk ~max_results:5 ~include_domains:[ "python.org" ] "generators");
      ]
  | "scrappa" ->
      [
        step "search" (mk ~max_results:5 "python 3.14 release notes");
        step "domain filter" (mk ~max_results:5 ~include_domains:[ "python.org" ] "generators");
      ]
  | "linkup" ->
      [
        step "sourced answer" (mk "who discovered penicillin");
        step "geo constraint notice" (mk ~country:"de" "who discovered penicillin");
      ]
  | "exa" -> [ step "search" (mk ~max_results:2 "rust async runtime") ]
  | "exa:free" -> [ step "search" (mk ~max_results:2 "rust async runtime") ]
  | "freeserp" -> [ step "search" (mk ~max_results:5 "python asyncio tutorial") ]
  | "parallel" ->
      [
        step "search" (mk "python 3.14 release notes");
        step "domain filter" (mk ~max_results:5 ~include_domains:[ "python.org" ] "generators");
      ]
  | "parallel:free" -> [ step "search" (mk ~max_results:2 "rust async runtime") ]
  | "searxng" -> [ step "search" (mk "python 3.14 release notes") ]
  | "tavily" ->
      [
        step "search" (mk ~recency:Model.Month "python 3.14 release notes");
        step "domain filter" (mk ~max_results:5 ~include_domains:[ "python.org" ] "generators");
      ]
  | "tinyfish" -> [ step "search" (mk ~recency:Model.Week "python 3.14 release notes") ]
  | "algolia" -> [ step "search" (mk "python") ]
  | "search1api" -> [ step "search" (mk "python 3.14 release notes") ]
  | "anysearch" -> [ step "search" (mk ~max_results:5 "python asyncio tutorial") ]
  | "serpapi" -> [ step "search" (mk "python 3.14 release notes") ]
  | "querit" -> [ step "search" (mk "python 3.14 release notes") ]
  | "deepseek" -> [ step "search" (mk "python 3.14 release notes") ]
  | _ -> []

let call_count = function
  | Provider name -> max 1 (List.length (provider_steps name))
  | Fetch _ -> 1
  | Agent _ -> 1

(* {1 What a case needs}

   Two values only: the provider-config keys the Python live fixture supplies
   from the environment ([searxng]'s instance; [algolia]'s app id and index),
   and nothing else. A key is checked by the runner through
   [Registry.missing_prerequisite], which already owns "did this deployment
   supply what this name requires". *)

let non_empty_env variable =
  match Sys.getenv_opt variable with
  | Some value when String.length value > 0 -> Some value
  | _ -> None

let provider_config name =
  let base = Config.default_provider_config in
  match name with
  | "searxng" -> (
      match non_empty_env "SEEKWRIGHT_SEARXNG_URL" with
      | Some url -> Ok { base with Config.url = Some url }
      | None -> Error "SEEKWRIGHT_SEARXNG_URL is not set")
  | "algolia" -> (
      match (non_empty_env "SEEKWRIGHT_ALGOLIA_APP_ID", non_empty_env "SEEKWRIGHT_ALGOLIA_INDEX") with
      | Some app_id, Some index -> Ok { base with Config.app_id = Some app_id; index = Some index }
      | None, _ ->
          Error "SEEKWRIGHT_ALGOLIA_APP_ID and SEEKWRIGHT_ALGOLIA_INDEX are not set"
      | _, None ->
          Error "SEEKWRIGHT_ALGOLIA_APP_ID and SEEKWRIGHT_ALGOLIA_INDEX are not set")
  | _ -> Ok base

(* A provider's build status comes from its registry row: [Adapter] is runnable,
   [Deferred wave] names the phase that lands it. The two local fetch cases are
   this build's own reader; the four third-party fetch cases and both agent
   depths arrive with F6.1 and are named now so the selector is stable. *)
let build_status = function
  | Provider name -> (
      match Registry.row name with
      | Some row -> (
          match row.Registry.build with
          | Registry.Adapter _ -> Runnable
          | Registry.Deferred wave -> Deferred wave)
      | None -> Deferred "unlisted")
  | Fetch Local | Fetch Metadata -> Runnable
  | Fetch (Jina | Scrappa | Tavily | Linkup) -> Deferred "F6.1"
  | Agent _ -> Runnable

(* {1 Spend} *)

let keyless row = not (List.mem Registry.Api_key row.Registry.requires)

let price_note row =
  let price = Registry.price row Config.default_provider_config in
  if price = 0.0 then "unbilled"
  else
    match row.Registry.cost_model with
    | Registry.Flat -> Printf.sprintf "$%.2f per 1k" price
    | Registry.Extra_results { first; per_extra_1k } ->
        Printf.sprintf "$%.2f per 1k for the first %d results, then $%.2f per 1k"
          price first per_extra_1k
    | Registry.Credit_multiplier { over; multiplier } ->
        Printf.sprintf "$%.2f per 1k credits, x%d past %d results" price multiplier
          over

let cost_class selector =
  match selector with
  | Provider name -> (
      match Registry.row name with
      | Some row when Registry.price row Config.default_provider_config > 0.0 -> Billed
      | _ -> Unbilled)
  | Fetch (Scrappa | Tavily | Linkup) -> Billed
  | Fetch (Local | Metadata | Jina) -> Unbilled
  | Agent _ -> Billed

let calls_note selector =
  let count = call_count selector in
  if count = 1 then "1 call" else Printf.sprintf "%d calls" count

let free_tier_first = "the free tier is spent first, so a healthy run costs nothing"

let cost_prose selector =
  match selector with
  | Provider name -> (
      match Registry.row name with
      | None -> "unknown: this name has no registry row"
      | Some row ->
          let calls = calls_note selector in
          if Registry.price row Config.default_provider_config = 0.0 then
            if keyless row then Printf.sprintf "unbilled — keyless, %s" calls
            else
              Printf.sprintf
                "unbilled — the vendor charges nothing for a call, but the key names whose quota; %s"
                calls
          else
            let note = price_note row in
            let extra = if name = "exa" then "; " ^ free_tier_first else "" in
            Printf.sprintf "billed at %s%s; %s" note extra calls)
  | Fetch (Scrappa | Tavily | Linkup) ->
      Printf.sprintf
        "billed — the vendor's per-call price applies (docs/reference/providers.md); %s"
        (calls_note selector)
  | Fetch (Local | Metadata | Jina) -> Printf.sprintf "unbilled — %s" (calls_note selector)
  | Agent _ ->
      Printf.sprintf
        "billed — one model call at the operator's endpoint, retrieval keyless; %s"
        (calls_note selector)

(* {1 The environment a case needs} *)

let fetch_api_key name = Config.api_key_env_var name

let needs = function
  | Provider name -> (
      match Registry.row name with
      | None -> [ "nothing" ]
      | Some row ->
          let one need =
            match need with
            | Registry.Api_key -> Some (Config.api_key_env_var name)
            | Registry.Config_url -> Some "SEEKWRIGHT_SEARXNG_URL"
            | Registry.App_id -> Some "SEEKWRIGHT_ALGOLIA_APP_ID"
            | Registry.Index -> Some "SEEKWRIGHT_ALGOLIA_INDEX"
          in
          let names = List.filter_map one row.Registry.requires in
          if names = [] then [ "nothing" ] else names)
  | Fetch ((Scrappa | Tavily | Linkup) as case) -> [ fetch_api_key (fetch_case_name case) ]
  | Fetch (Local | Metadata | Jina) -> [ "nothing" ]
  | Agent _ ->
      [
        "SEEKWRIGHT_AGENT_BASE_URL";
        "SEEKWRIGHT_AGENT_MODEL";
        "SEEKWRIGHT_AGENT_API_KEY";
      ]

(* {1 Where it dials} *)

let uri_route uri =
  let scheme = Option.value ~default:"https" (Uri.scheme uri) in
  let host = Option.value ~default:"?" (Uri.host uri) in
  match Uri.port uri with
  | Some port -> Printf.sprintf "%s://%s:%d" scheme host port
  | None -> Printf.sprintf "%s://%s" scheme host

let endpoint_of_fallback name =
  match List.find_opt (fun (row : Config.fetch_fallback) -> row.Config.name = name) Config.known_fetch_fallbacks with
  | Some row -> (
      match row.Config.endpoint with
      | Some endpoint -> uri_route (Uri.of_string endpoint)
      | None -> "a self-hosted endpoint ([fetch] " ^ Option.value ~default:"url" row.Config.fetch_key ^ ")")
  | None -> "?"

let route = function
  | Provider name -> (
      match Registry.row name with
      | None -> "?"
      | Some row -> (
          match row.Registry.endpoint with
          | Registry.Fixed_uri uri | Registry.Url_override uri -> uri_route uri
          | Registry.Url_required -> "the configured instance (SEEKWRIGHT_SEARXNG_URL)"
          | Registry.Algolia_index -> "the configured index host (derived from app_id)"))
  | Fetch Local -> "local reader (stdlib extractor), public-web grant"
  | Fetch Metadata -> "local reader, public-web grant — the URL must be refused before any request"
  | Fetch Jina -> "jina -> " ^ endpoint_of_fallback "jina"
  | Fetch Scrappa -> "scrappa -> " ^ endpoint_of_fallback "scrappa"
  | Fetch Tavily -> "tavily -> " ^ endpoint_of_fallback "tavily"
  | Fetch Linkup -> "linkup -> " ^ endpoint_of_fallback "linkup"
  | Agent _ -> (
      match non_empty_env "SEEKWRIGHT_AGENT_BASE_URL" with
      | Some url -> uri_route (Uri.of_string url)
      | None -> "SEEKWRIGHT_AGENT_BASE_URL (unset)")

let credential = function
  | Provider name -> (
      match Registry.row name with
      | Some row when keyless row -> "none (keyless: no account, no key, no card)"
      | _ -> Config.api_key_env_var name)
  | Fetch ((Scrappa | Tavily | Linkup) as case) -> fetch_api_key (fetch_case_name case)
  | Fetch (Local | Metadata | Jina) -> "none"
  | Agent _ -> "SEEKWRIGHT_AGENT_API_KEY (the model endpoint; retrieval is keyless)"

(* {1 Live status} *)

let recorded_non_provider_runs = [ (* see cases.mli; empty until a run is recorded *) ]

let live_status selector =
  match selector with
  | Provider name -> (
      match Registry.row name with Some row when row.Registry.ocaml_live_tested -> `Tested | _ -> `Untested)
  | Fetch _ | Agent _ -> if List.mem (name selector) recorded_non_provider_runs then `Tested else `Untested

(* {1 Parsing} *)

let fetch_of_name = function
  | "local" -> Some Local
  | "metadata" -> Some Metadata
  | "jina" -> Some Jina
  | "scrappa" -> Some Scrappa
  | "tavily" -> Some Tavily
  | "linkup" -> Some Linkup
  | _ -> None

let parse raw =
  let spelling = String.trim raw in
  if List.mem spelling Config.known_providers then Ok (Provider spelling)
  else
    match String.index_opt spelling ':' with
    | Some split ->
        let namespace = String.sub spelling 0 split in
        let rest = String.sub spelling (split + 1) (String.length spelling - split - 1) in
        if namespace = "fetch" then (
          match fetch_of_name rest with
          | Some case -> Ok (Fetch case)
          | None -> Error (Printf.sprintf "no fetch case is named %S" rest))
        else if namespace = "agent" then (
          match rest with
          | "brief" -> Ok (Agent Model.Brief)
          | "report" -> Ok (Agent Model.Report)
          | _ -> Error (Printf.sprintf "no agent case is named %S" rest))
        else Error (Printf.sprintf "no case is named %S" spelling)
    | None ->
        if spelling = "" then Error "no case was named"
        else
          Error
            (Printf.sprintf
               "no provider is named %S. The default is no provider, not all configured ones: name \
                exactly one case, or pass --list"
               spelling)

let usage =
  String.concat "\n"
    [
      "seekwright-live — one explicitly named live case, never a sweep";
      "";
      "  seekwright-live --list            the inventory, with cost class and build status";
      "  seekwright-live <case>            run exactly that case";
      "  seekwright-live --help            this text";
      "";
      "A run needs SEEKWRIGHT_LIVE_TESTS=1. Exactly one case is accepted:";
      "  a provider name        freeserp, exa:free, anysearch, serper, …";
      "  a fetch case           fetch:local, fetch:metadata, fetch:jina,";
      "                         fetch:scrappa, fetch:tavily, fetch:linkup";
      "  an agent case          agent:brief, agent:report";
      "";
      "Missing configuration skips the case; an unexpected call or result fails it.";
      "Exit status: 0 passed or skipped, 1 failed, 2 refused or misused, 3 inconclusive";
      "  (a rate-limited or quota-exhausted run proves nothing about the parser).";
    ]
