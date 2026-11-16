module T = Toml.Types

(* Which keys a section's decoder actually consumed; see [section]. *)
module Name_set = Set.Make (String)

let ( let* ) = Result.bind

type name = string

let known_providers =
  [
    "algolia";
    "anysearch";
    "deepseek";
    "exa";
    "exa:free";
    "freeserp";
    "linkup";
    "parallel";
    "parallel:free";
    "querit";
    "scrappa";
    "search1api";
    "searxng";
    "serpapi";
    "serper";
    "tavily";
    "tinyfish";
  ]

(* The only non-provider name [permitted_providers] holds: a fetch fallback a
   declared set has to be able to vouch for. [jina] is the keyless third party. *)
let permitted_fetch_names = [ "jina" ]

(* Retired spellings and what replaced them for error hints. *)
let renamed_providers = [ ("exa_free", "exa:free"); ("parallel_free", "parallel:free") ]

(* Keyed providers: a metered free tier is an account allowance, so the key
   names whose balance a search spends. *)
let providers_requiring_key =
  [
    "algolia";
    "deepseek";
    "exa";
    "linkup";
    "parallel";
    "querit";
    "scrappa";
    "search1api";
    "serpapi";
    "serper";
    "tavily";
    "tinyfish";
  ]

let free_providers = [ "exa:free"; "freeserp"; "parallel:free"; "searxng"; "tinyfish" ]

let keyless_providers = [ "exa:free"; "parallel:free"; "freeserp" ]

let free_provider_order = keyless_providers @ [ "searxng"; "tinyfish" ]

let untested_providers = [ "deepseek"; "querit"; "search1api"; "serpapi" ]

let known_extractors = [ "stdlib" ]

type fetch_fallback = {
  name : name;
  billable : bool;
  endpoint : string option;
  fetch_key : string option;
  default_cost : float option;
}

(* Fallback registry: billable fallbacks must come last in the ladder. *)
let known_fetch_fallbacks =
  [
    {
      name = "crawl4ai";
      billable = false;
      endpoint = None;
      fetch_key = Some "crawl4ai_url";
      default_cost = None;
    };
    {
      name = "jina";
      billable = false;
      endpoint = Some "https://r.jina.ai/";
      fetch_key = None;
      default_cost = None;
    };
    (* The [v1/fetch] rate, not the [linkup] search row's higher one — the two
       are different vendor products. *)
    {
      name = "linkup";
      billable = true;
      endpoint = Some "https://api.linkup.so/v1/fetch";
      fetch_key = None;
      default_cost = Some 5.00;
    };
    (* One credit per page, which is the [scrappa] search row's rate too. *)
    {
      name = "scrappa";
      billable = true;
      endpoint = Some "https://scrappa.co/api/web-scraper";
      fetch_key = None;
      default_cost = Some 0.30;
    };
    (* The extract endpoint's rate, a fifth of the [tavily] search row's. *)
    {
      name = "tavily";
      billable = true;
      endpoint = Some "https://api.tavily.com/extract";
      fetch_key = None;
      default_cost = Some 1.60;
    };
  ]

let default_user_agent = Version.user_agent

let default_config_path = "~/.config/seekwright/config.toml"

type output_kind =
  | Sourced_answer
  | Search_results

let show_output_kind = function
  | Sourced_answer -> "sourcedAnswer"
  | Search_results -> "searchResults"

let output_kinds = [ Sourced_answer; Search_results ]

(* loguru's level names, in the order [logging.level]'s closed vocabulary lists
   them — which is the order the refusal sentence prints them in. *)
type log_level =
  | Log_trace
  | Log_debug
  | Log_info
  | Log_success
  | Log_warning
  | Log_error
  | Log_critical

let show_log_level = function
  | Log_trace -> "TRACE"
  | Log_debug -> "DEBUG"
  | Log_info -> "INFO"
  | Log_success -> "SUCCESS"
  | Log_warning -> "WARNING"
  | Log_error -> "ERROR"
  | Log_critical -> "CRITICAL"

let log_levels =
  [ Log_trace; Log_debug; Log_info; Log_success; Log_warning; Log_error; Log_critical ]

type log_format =
  | Log_text
  | Log_json

let show_log_format = function
  | Log_text -> "text"
  | Log_json -> "json"

let log_formats = [ Log_text; Log_json ]

type provider_config = {
  enabled : bool;
  cost_per_1k : float option;
  depth : string;
  output_type : output_kind;
  mode : string;
  url : string option;
  free_cooldown_seconds : float;
  app_id : string option;
  index : string option;
  title_attr : string option;
  url_attr : string option;
  snippet_attr : string option;
}

type policy_config = {
  max_snippet_chars : int;
  max_result_text_chars : int;
  provider_timeout_seconds : float;
}

type fetch_config = {
  enabled : bool;
  extractor : string;
  timeout_seconds : float;
  max_download_bytes : int;
  max_text_chars : int;
  min_text_chars : int;
  max_match_chars : int;
  max_redirects : int;
  allow_private_addresses : bool;
  allow_images : bool;
  user_agent : string;
  fallback : string list option;
  auto_fallback : bool;
  primary : string;
  cost_per_1k : float option;
  crawl4ai_url : string option;
  crawl4ai_token : string option;
  crawl4ai_timeout_seconds : float;
  cache_dir : string option;
  cache_max_bytes : int;
  cache_max_entry_bytes : int;
  cache_ttl_seconds : float;
}

type search_config = {
  fallback : string list option;
  free_fallback : string list option;
  health_interval_seconds : float;
  health_failure_threshold : int;
  health_cooldown_seconds : float;
}

type agent_config = {
  enabled : bool;
  base_url : string option;
  model : string option;
  timeout_seconds : float;
  model_timeout_seconds : float;
  max_material_chars : int;
  max_output_tokens_brief : int;
  max_output_tokens_report : int;
  max_cost_usd : float option;
  cost_per_1k_in : float option;
  cost_per_1k_out : float option;
}

type logging_config = {
  level : log_level;
  format : log_format;
  library_level : log_level;
  access_log : bool;
  log_queries : bool;
  log_content : bool;
}

type dashboard_config = { enabled : bool; history_path : string option }

type t = {
  providers : (name * provider_config) list;
  default_provider : name option;
  permitted_providers : name list option;
  policy : policy_config;
  fetch : fetch_config;
  search : search_config;
  agent : agent_config;
  logging : logging_config;
  dashboard : dashboard_config;
  providers_defaulted : bool;
}

(* The tables the file may declare, in the order [decode_table] reads them. A
   section added to {!t} belongs here too: the documentation guard in [test/]
   reads this list, so a section that no operator page documents fails a run
   rather than going undocumented. *)
let section_names =
  [ "providers"; "policy"; "fetch"; "search"; "logging"; "dashboard"; "agent" ]

let default_provider_config = {
  enabled = true;
  cost_per_1k = None;
  depth = "standard";
  output_type = Sourced_answer;
  mode = "fast";
  url = None;
  free_cooldown_seconds = 60.0;
  app_id = None;
  index = None;
  title_attr = None;
  url_attr = None;
  snippet_attr = None;
}

let default_policy_config = {
  max_snippet_chars = 500;
  max_result_text_chars = 2000;
  provider_timeout_seconds = 10.0;
}

let default_fetch_config = {
  enabled = true;
  extractor = "stdlib";
  timeout_seconds = 15.0;
  max_download_bytes = 8_388_608;
  max_text_chars = 40_000;
  min_text_chars = 200;
  max_match_chars = 6000;
  max_redirects = 3;
  allow_private_addresses = false;
  allow_images = false;
  user_agent = default_user_agent;
  fallback = None;
  auto_fallback = false;
  primary = "http";
  cost_per_1k = None;
  crawl4ai_url = None;
  crawl4ai_token = None;
  crawl4ai_timeout_seconds = 60.0;
  cache_dir = None;
  cache_max_bytes = 268_435_456;
  cache_max_entry_bytes = 33_554_432;
  cache_ttl_seconds = 300.0;
}

let default_search_config = {
  fallback = None;
  free_fallback = None;
  health_interval_seconds = 60.0;
  health_failure_threshold = 3;
  health_cooldown_seconds = 120.0;
}

(* Agent mode's [max_cost_usd] is on by default: an operator who writes no
   [agent] block still gets the early exit for a mispriced provider. An explicit
   [null] in the file is the way to leave the structural bound as the only
   ceiling. *)
let default_agent_config = {
  enabled = false;
  base_url = None;
  model = None;
  timeout_seconds = 90.0;
  model_timeout_seconds = 30.0;
  max_material_chars = 24000;
  max_output_tokens_brief = 500;
  max_output_tokens_report = 2500;
  max_cost_usd = Some 0.25;
  cost_per_1k_in = None;
  cost_per_1k_out = None;
}

let default_logging_config = {
  level = Log_info;
  format = Log_text;
  library_level = Log_warning;
  access_log = false;
  log_queries = false;
  log_content = false;
}

let default_dashboard_config = { enabled = true; history_path = None }

let quote name = "'" ^ name ^ "'"

let join names = String.concat ", " names

let or_list names =
  match List.rev names with
  | [] -> ""
  | [ single ] -> single
  | last :: rest -> String.concat ", " (List.rev rest) ^ " or " ^ last

let enabled_names (providers : (name * provider_config) list) =
  List.sort String.compare
    (List.filter_map
       (fun (name, (config : provider_config)) ->
         if config.enabled then Some name else None)
       providers)

let present = function
  | Some value when value <> "" -> true
  | _ -> false

(* Unset [permitted_providers] is permissive. *)
let is_permitted config name =
  match config.permitted_providers with
  | None -> true
  | Some names -> List.mem name names

let provider config name = List.assoc_opt name config.providers

let enabled_providers config = enabled_names config.providers

let effective_providers config =
  match config.permitted_providers with
  | None -> enabled_providers config
  | Some permitted -> List.filter (fun name -> List.mem name permitted) (enabled_providers config)

(* True only while every name the deployment may dispatch to is in the free set. *)
let default_route_is_free_only config =
  match effective_providers config with
  | [] -> false
  | names -> List.for_all (fun name -> List.mem name free_providers) names

(* The variable is named for the backend segment before any ':'. *)
let api_key_env_var name =
  let backend =
    match String.index_opt name ':' with
    | Some index -> String.sub name 0 index
    | None -> name
  in
  "SEEKWRIGHT_" ^ String.uppercase_ascii backend ^ "_API_KEY"

let env name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> Some value
  | _ -> None

let api_key name = env (api_key_env_var name)

let agent_api_key () = env "SEEKWRIGHT_AGENT_API_KEY"

let missing_api_keys config =
  List.filter
    (fun name -> List.mem name providers_requiring_key && api_key name = None)
    (enabled_providers config)

let missing_agent_settings config =
  if not config.agent.enabled
  then []
  else
    List.filter_map
      (fun (name, value) -> if present value then None else Some name)
      [
        ("agent.base_url", config.agent.base_url);
        ("agent.model", config.agent.model);
        ("SEEKWRIGHT_AGENT_API_KEY", agent_api_key ());
      ]

(* Names in [names] that are not in [vocabulary], de-duplicated and sorted: what
   each "unknown name(s) ..." sentence prints. *)
let unknown_in names vocabulary =
  names
  |> List.filter (fun name -> not (List.mem name vocabulary))
  |> List.sort_uniq String.compare

(* [; it is now "exa:free"] for every name an earlier build shipped; empty when
   nothing was renamed. *)
let renamed_hint unknown =
  let hints =
    List.filter_map
      (fun name ->
        match List.assoc_opt name renamed_providers with
        | Some replacement -> Some (Printf.sprintf "it is now %S" replacement)
        | None -> None)
      unknown
  in
  match hints with
  | [] -> ""
  | hints -> "; " ^ String.concat "; " hints

let has_duplicates names =
  List.length (List.sort_uniq String.compare names) <> List.length names

let validate_provider_names names =
  match unknown_in names known_providers with
  | [] -> Ok ()
  | unknown ->
      Error
        (Printf.sprintf "unknown provider(s) %s%s; supported: %s" (join unknown)
           (renamed_hint unknown) (join known_providers))

(* The ladder's shape, read off the registry rather than off a name: the last
   rule asks each row whether it can bill, so "every free fallback before a
   credit is spent" holds for a name this build has never heard of, and a second
   priced fallback is refused here rather than reordered at fetch time. *)
let validate_fetch_fallbacks registry fallbacks =
  let registry_names = List.map (fun (row : fetch_fallback) -> row.name) registry in
  let billable name =
    match List.find_opt (fun (row : fetch_fallback) -> row.name = name) registry with
    | Some row -> row.billable
    | None -> false
  in
  if fallbacks = []
  then Ok ()
  else if has_duplicates fallbacks
  then
    Error
      "fetch.fallback names a fallback more than once; each fallback gets one attempt per fetch"
  else
    match unknown_in fallbacks registry_names with
    | unknown when unknown <> [] ->
        Error
          (Printf.sprintf "fetch.fallback names unknown fallback(s) %s; supported: %s"
            (join unknown) (join registry_names))
    | _ ->
      let priced = fallbacks |> List.filter billable |> List.sort String.compare in
      (* At most one billable rung, and it must be the ladder's last name. *)
      let priced_too_late =
        Printf.sprintf
          "fetch.fallback: %s can bill and belongs last, so a page reaches every free fallback \
           before a credit is spent" (join priced)
      in
      match (List.rev fallbacks, priced) with
      | _, [] -> Ok ()
      | _, _ :: _ :: _ -> Error priced_too_late
      | last :: _, [only] -> if last = only then Ok () else Error priced_too_late
      | [], _ -> Ok ()

let validate_fetch_primary registry primary =
  let registry_names = List.map (fun (row : fetch_fallback) -> row.name) registry in
  if primary = "http" || List.mem primary registry_names
  then Ok ()
  else
    Error
      (Printf.sprintf "fetch.primary names unknown route %s; supported: http, %s" (quote primary)
         (join registry_names))

let validate_fetch_extractor extractor =
  if List.mem extractor known_extractors
  then Ok ()
  else
    Error
      (Printf.sprintf "fetch.extractor names unknown extractor %s; supported: %s" (quote extractor)
         (join known_extractors))

let validate_search_fallbacks fallbacks =
  if fallbacks = []
  then Ok ()
  else if has_duplicates fallbacks
  then
    Error "search.fallback names a provider more than once; each fallback gets one attempt per search"
  else
    match unknown_in fallbacks known_providers with
    | [] -> Ok ()
    | unknown ->
        Error
          (Printf.sprintf "search.fallback names unknown provider(s) %s%s; supported: %s"
             (join unknown) (renamed_hint unknown) (join known_providers))

(* Free ladder rule: no fallback that can bill. *)
let validate_search_free_fallbacks fallbacks =
  if fallbacks = []
  then Ok ()
  else if has_duplicates fallbacks
  then
    Error
      "search.free_fallback names a provider more than once; each fallback gets one attempt per \
       free search"
  else
    match unknown_in fallbacks known_providers with
    | unknown when unknown <> [] ->
        Error
          (Printf.sprintf "search.free_fallback names unknown provider(s) %s%s; supported: %s"
             (join unknown) (renamed_hint unknown) (join known_providers))
    | _ ->
      (match unknown_in fallbacks free_providers with
      | [] -> Ok ()
      | paid ->
          Error
            (Printf.sprintf
               "search.free_fallback names %s, which can bill; a free-only search walks only %s"
               (join paid) (join free_providers)))

(* A list containing ["*"] normalises to None (permissive). *)
let validate_permitted_providers declared =
  let vocabulary = List.sort String.compare (known_providers @ permitted_fetch_names) in
  if List.mem "*" declared
  then Ok None
  else if has_duplicates declared
  then Error "permitted_providers names a provider more than once; each name gets one entry"
  else
    match unknown_in declared vocabulary with
    | [] -> Ok (Some declared)
    | unknown ->
        Error
          (Printf.sprintf "permitted_providers names unknown provider(s) %s%s; supported: %s"
             (join unknown) (renamed_hint unknown) (join vocabulary))

(* The enabled-provider checks about an adapter's prerequisites rather than its
   name: SearXNG has no public endpoint to fall back to, and Algolia searches one
   operator-named index, so a half-configured one is a startup error. *)
(* [enabled] is a label four sections carry, so the lookup goes through a helper
   whose argument type makes the access concrete. *)
let enabled_provider (providers : (name * provider_config) list) name =
  match List.assoc_opt name providers with
  | Some config when config.enabled -> Some config
  | _ -> None

let validate_provider_prerequisites providers =
  match enabled_provider providers "searxng" with
  | Some config when not (present config.url) ->
      Error "provider 'searxng' is enabled but no url is configured; it has no public default"
  | _ ->
    (match enabled_provider providers "algolia" with
    | Some config when not (present config.app_id && present config.index) ->
        Error
          "provider 'algolia' is enabled but app_id and index are required; it searches one \
           operator-named index"
    | _ -> Ok ())

(* Every rung of a search ladder has to be able to run; the default itself may
   appear, and is skipped as already tried at walk time. *)
let ladder_is_enabled field fallbacks enabled =
  List.fold_left
    (fun result name ->
      let* () = result in
      if List.mem name enabled
      then Ok ()
      else
        Error
          (Printf.sprintf "%s names %s, which is not an enabled provider (enabled: %s)" field
             (quote name)
             (join (if enabled = [] then [ "none" ] else enabled))))
    (Ok ())
    fallbacks

let validate_fetch_section fetch =
  let* () = validate_fetch_extractor fetch.extractor in
  let* () =
    validate_fetch_fallbacks known_fetch_fallbacks (Option.value ~default:[] fetch.fallback)
  in
  validate_fetch_primary known_fetch_fallbacks fetch.primary

let validate_search_section search =
  let* () = validate_search_fallbacks (Option.value ~default:[] search.fallback) in
  validate_search_free_fallbacks (Option.value ~default:[] search.free_fallback)

(* library_level and access_log are uvicorn-specific; non-default values are refused. *)
let validate_logging_on_this_port logging =
  if logging.library_level <> default_logging_config.library_level
  then
    Error
      "logging.library_level is not honoured on this port: there is no uvicorn here, so no \
       third-party logger has a level to hold down (remove the key; the default loads and does \
       nothing)"
  else if logging.access_log <> default_logging_config.access_log then
    Error
      "logging.access_log is not honoured on this port: there is no uvicorn here, so there is \
       no per-request access log to switch on or off (remove the key; the default loads and \
       does nothing)"
  else Ok ()

let resolve ?(providers = []) ?default_provider ?permitted_providers
    ?(policy = default_policy_config) ?(fetch = default_fetch_config)
    ?(search = default_search_config) ?(agent = default_agent_config)
    ?(logging = default_logging_config) ?(dashboard = default_dashboard_config) () =
  let* () = validate_logging_on_this_port logging in
  let* () = validate_fetch_section fetch in
  let* () = validate_search_section search in
  let providers = List.sort (fun (a, _) (b, _) -> String.compare a b) providers in
  let* () = validate_provider_names (List.map fst providers) in
  (* Nothing enabled resolves to the default keyless set. *)
  let providers, providers_defaulted =
    match enabled_names providers with
    | [] -> (List.map (fun name -> (name, default_provider_config)) keyless_providers, true)
    | _ -> (providers, false)
  in
  let enabled = enabled_names providers in
  let* () = validate_provider_prerequisites providers in
  let* default_provider =
    match default_provider with
    | Some name when not (List.mem name enabled) ->
        Error
          (Printf.sprintf "default_provider %s is not an enabled provider (enabled: %s)"
             (quote name)
             (join (if enabled = [] then [ "none" ] else enabled)))
    | declared ->
        Ok
          (match (declared, enabled) with
          | Some name, _ -> Some name
          | None, [ single ] -> Some single
          | _ -> None)
  in
  let* () =
    ladder_is_enabled "search.fallback" (Option.value ~default:[] search.fallback) enabled
  in
  let* () =
    ladder_is_enabled "search.free_fallback"
      (Option.value ~default:[] search.free_fallback)
      enabled
  in
  let* permitted_providers =
    match permitted_providers with
    | None -> Ok None
    | Some declared -> validate_permitted_providers declared
  in
  Ok {
    providers;
    default_provider;
    permitted_providers;
    policy;
    fetch;
    search;
    agent;
    logging;
    dashboard;
    providers_defaulted;
  }

let default =
  match resolve () with
  | Ok config -> config
  | Error fault -> failwith ("Config.default: " ^ fault)

(* Strip outer quotes added by [Toml.Types.Table.Key.to_string] for non-bare keys. *)
let key_name key =
  let spelling = T.Table.Key.to_string key in
  let last = String.length spelling - 1 in
  if last > 0 && spelling.[0] = '"' && spelling.[last] = '"'
  then String.sub spelling 1 (last - 1)
  else spelling

let bindings table = T.Table.fold (fun key value acc -> (key_name key, value) :: acc) table []

let kind_of = function
  | T.TBool _ -> "a boolean"
  | T.TInt _ -> "an integer"
  | T.TFloat _ -> "a float"
  | T.TString _ -> "a string"
  | T.TDate _ -> "a date"
  | T.TArray _ -> "a list"
  | T.TTable _ -> "a table"

(* What the operator wrote, printed back at them: the scalar kinds carry their
   value because [max_text_chars = "40k"] is a typo they can fix from the
   message alone, while a table or a list is only worth its kind. *)
let value_repr = function
  | T.TBool value -> string_of_bool value
  | T.TInt value -> string_of_int value
  | T.TFloat value -> string_of_float value
  | T.TString value -> "'" ^ value ^ "'"
  | value -> kind_of value

(* [loc] is the dotted prefix of the key, empty at the top level, which is how
   pydantic locates a fault: [providers.serper.enabledd]. *)
let dotted loc key = if loc = "" then key else loc ^ "." ^ key

let type_error loc key expected value =
  Printf.sprintf "%s: expected %s, found %s" (dotted loc key) expected (value_repr value)

let unknown_key loc key = Printf.sprintf "%s: unknown key" (dotted loc key)

(* TOML writes [15] and [15.0] differently, and an operator who wants a duration
   writes either, so an integer is accepted for a float and a boolean for either
   number. The same reading accepts a quoted number and the twelve boolean
   spellings, because a quoted number is the commonest typo in a config file and
   the Python deployment has always taken it: refusing it here would turn a
   working [config.toml] into a startup failure the operator cannot see. The
   accepted spellings below were read off pydantic 2.14 rather than guessed, and
   they are narrower than OCaml's own [float_of_string] on purpose — no
   hexadecimal, and an [_] separator only between two digits. *)

let trim s =
  let stop ch = ch <> ' ' && ch <> '\t' && ch <> '\n' && ch <> '\r' in
  let finish = ref (String.length s) in
  while !finish > 0 && not (stop s.[!finish - 1]) do
    decr finish
  done;
  let start = ref 0 in
  while !start < !finish && not (stop s.[!start]) do
    incr start
  done;
  String.sub s !start (!finish - !start)

let is_digit ch = ch >= '0' && ch <= '9'

(* An underscore separates digits, so it has to sit between two of them: [_1]
   and [1__0] are not numbers. *)
let drop_separators s =
  let buffer = Buffer.create (String.length s) in
  let ok = ref true in
  String.iteri
    (fun i ch ->
      if ch <> '_'
      then Buffer.add_char buffer ch
      else if
        i > 0 && i + 1 < String.length s && is_digit s.[i - 1] && is_digit s.[i + 1]
      then ()
      else ok := false)
    s;
  if !ok then Some (Buffer.contents buffer) else None

let lower = String.map Char.lowercase_ascii

let bool_words =
  [ ("true", true); ("t", true); ("yes", true); ("y", true); ("on", true); ("1", true)
  ; ("false", false); ("f", false); ("no", false); ("n", false); ("off", false)
  ; ("0", false) ]

let bool_from_string s = List.assoc_opt (lower s) bool_words

(* [0] and [1], and no other number: pydantic reads a boolean out of an integer
   or a float only when the value is exactly one of those two. *)
let bool_from_number value =
  if Float.equal value 0.0
  then Some false
  else if Float.equal value 1.0
  then Some true
  else None

(* A whole number written in decimal, with an optional fraction of nothing but
   zeros: ["1.000"] is [1], while ["1.001"], ["1e2"] and ["1."] are not
   integers. A value past what this build's [int] holds is refused; Python
   carries it as an arbitrary-precision integer, and no limit key here means
   anything near that size. *)
let int_from_string s =
  let digits_only text = text <> "" && String.for_all is_digit text in
  let zeros text = text <> "" && String.for_all (fun ch -> ch = '0') text in
  let signed sign digits =
    match digits with
    | Some digits when digits_only digits ->
        Option.map (( * ) sign) (int_of_string_opt digits)
    | _ -> None
  in
  let text = trim s in
  let sign, body =
    if text = ""
    then (1, "")
    else if text.[0] = '+'
    then (1, String.sub text 1 (String.length text - 1))
    else if text.[0] = '-'
    then (-1, String.sub text 1 (String.length text - 1))
    else (1, text)
  in
  match String.index_opt body '.' with
  | None -> signed sign (drop_separators body)
  | Some at ->
      let whole = String.sub body 0 at in
      let fraction = String.sub body (at + 1) (String.length body - at - 1) in
      if not (zeros fraction)
      then None
      else
        match drop_separators whole with
        | Some "" -> None
        | Some digits -> signed sign (Some digits)
        | None -> None

let float_from_string s =
  let text = trim s in
  let negative, body =
    if text <> "" && (text.[0] = '+' || text.[0] = '-')
    then (text.[0] = '-', String.sub text 1 (String.length text - 1))
    else (false, text)
  in
  match lower body with
  | "nan" -> Some Float.nan
  | "inf" | "infinity" -> Some (if negative then Float.neg infinity else infinity)
  | _ ->
      if String.exists (fun ch -> ch = 'x' || ch = 'X') text
      then None
      else (
        match drop_separators body with
        | Some digits -> float_of_string_opt digits
        | None -> None)

let unknown_keys loc keys =
  String.concat "; " (List.map (fun key -> unknown_key loc key) (List.sort String.compare keys))

let section loc table decode =
  let fields = bindings table in
  let read = ref Name_set.empty in
  let get key =
    read := Name_set.add key !read;
    List.assoc_opt key fields
  in
  let* value = decode get in
  match List.filter (fun (key, _) -> not (Name_set.mem key !read)) fields with
  | [] -> Ok value
  | extras -> Error (unknown_keys loc (List.map fst extras))

let bool_field get loc key default =
  let refuse loc key value = Error (type_error loc key "a boolean" value) in
  match get key with
  | None -> Ok default
  | Some (T.TBool value) -> Ok value
  | Some (T.TInt number as value) ->
      (match bool_from_number (float_of_int number) with
      | Some flag -> Ok flag
      | None -> refuse loc key value)
  | Some (T.TFloat number as value) ->
      (match bool_from_number number with
      | Some flag -> Ok flag
      | None -> refuse loc key value)
  | Some (T.TString text as value) ->
      (match bool_from_string text with
      | Some flag -> Ok flag
      | None -> refuse loc key value)
  | Some value -> refuse loc key value

let float_of_value value =
  match value with
  | T.TFloat number -> Some number
  | T.TInt number -> Some (float_of_int number)
  | T.TBool value -> Some (if value then 1.0 else 0.0)
  | T.TString text -> float_from_string text
  | _ -> None

let float_field get loc key default =
  match get key with
  | None -> Ok default
  | Some value ->
      (match float_of_value value with
      | Some number -> Ok number
      | None -> Error (type_error loc key "a number" value))

let float_opt_field get loc key =
  match get key with
  | None -> Ok None
  | Some value ->
      (match float_of_value value with
      | Some number -> Ok (Some number)
      | None -> Error (type_error loc key "a number" value))

let int_field get loc key default =
  match get key with
  | None -> Ok default
  | Some (T.TInt value) -> Ok value
  | Some (T.TFloat value) ->
      if Float.equal value (Float.floor value) && Float.abs value < 1e18
      then Ok (int_of_float value)
      else
        Error
          (Printf.sprintf "%s: expected an integer, found a number with a fractional part"
             (dotted loc key))
  | Some (T.TBool value) -> Ok (if value then 1 else 0)
  | Some (T.TString text as given) ->
      (match int_from_string text with
      | Some value -> Ok value
      | None -> Error (type_error loc key "an integer" given))
  | Some value -> Error (type_error loc key "an integer" value)

let string_field get loc key default =
  match get key with
  | None -> Ok default
  | Some (T.TString value) -> Ok value
  | Some value -> Error (type_error loc key "a string" value)

let string_opt_field get loc key =
  match get key with
  | None -> Ok None
  | Some (T.TString value) -> Ok (Some value)
  | Some value -> Error (type_error loc key "a string" value)

let names_of = function
  | T.TArray (T.NodeString names) -> Some names
  | T.TArray T.NodeEmpty -> Some []
  | _ -> None

(* A bare string is a startup error, not a one-name ladder. *)
let names_opt_field get loc key =
  match get key with
  | None -> Ok None
  | Some value ->
      (match names_of value with
      | Some names -> Ok (Some names)
      | None -> Error (type_error loc key "a list of names" value))

(* A closed vocabulary — pydantic's [Literal]: anything else names every accepted
   spelling. A free [str] key with a validator, like [extractor] or [primary], is
   a string field plus a validator call instead. *)
let choice_field get loc key default show choices =
  match get key with
  | None -> Ok default
  | Some (T.TString value) ->
      (match List.find_opt (fun choice -> show choice = value) choices with
      | Some choice -> Ok choice
      | None ->
          Error
            (Printf.sprintf "%s: input should be %s, not %s" (dotted loc key)
               (or_list (List.map show choices)) (quote value)))
  | Some value -> Error (type_error loc key "one of the accepted names" value)

(* A section that may be absent whole. [get] has already recorded the key, so an
   unknown key inside the section is still refused. *)
let subsection get name default decode =
  match get name with
  | None -> Ok default
  | Some (T.TTable table) -> decode name table
  | Some value -> Error (type_error "" name "a table" value)

let decode_provider_config loc table =
  section loc table (fun get ->
    let* enabled = bool_field get loc "enabled" true in
    let* cost_per_1k = float_opt_field get loc "cost_per_1k" in
    let* depth = string_field get loc "depth" "standard" in
    let* output_type =
      choice_field get loc "output_type" Sourced_answer show_output_kind output_kinds
    in
    let* mode = string_field get loc "mode" "fast" in
    let* url = string_opt_field get loc "url" in
    let* free_cooldown_seconds = float_field get loc "free_cooldown_seconds" 60.0 in
    let* app_id = string_opt_field get loc "app_id" in
    let* index = string_opt_field get loc "index" in
    let* title_attr = string_opt_field get loc "title_attr" in
    let* url_attr = string_opt_field get loc "url_attr" in
    let* snippet_attr = string_opt_field get loc "snippet_attr" in
    Ok {
      enabled;
      cost_per_1k;
      depth;
      output_type;
      mode;
      url;
      free_cooldown_seconds;
      app_id;
      index;
      title_attr;
      url_attr;
      snippet_attr;
    })

(* A [[providers]] table, or a quoted [[providers."backend:flavour"]] one: the
   [:] ends a bare TOML key, which is why the quoting is not optional. *)
let decode_providers get =
  match get "providers" with
  | None -> Ok []
  | Some (T.TTable table) ->
      List.fold_left
        (fun result (name, value) ->
          let* entries = result in
          match value with
          | T.TTable entry ->
              let* config = decode_provider_config ("providers." ^ name) entry in
              Ok ((name, config) :: entries)
          | value ->
              Error (Printf.sprintf "providers.%s: expected a table, found %s" name (kind_of value)))
        (Ok []) (bindings table)
  | Some value -> Error (type_error "" "providers" "a table" value)

let decode_policy_config loc table =
  section loc table (fun get ->
    let* max_snippet_chars = int_field get loc "max_snippet_chars" 500 in
    let* max_result_text_chars = int_field get loc "max_result_text_chars" 2000 in
    let* provider_timeout_seconds = float_field get loc "provider_timeout_seconds" 10.0 in
    Ok { max_snippet_chars; max_result_text_chars; provider_timeout_seconds })

let decode_fetch_config loc table =
  section loc table (fun get ->
    let* enabled = bool_field get loc "enabled" true in
    let* extractor = string_field get loc "extractor" "stdlib" in
    let* timeout_seconds = float_field get loc "timeout_seconds" 15.0 in
    let* max_download_bytes = int_field get loc "max_download_bytes" 8_388_608 in
    let* max_text_chars = int_field get loc "max_text_chars" 40_000 in
    let* min_text_chars = int_field get loc "min_text_chars" 200 in
    let* max_match_chars = int_field get loc "max_match_chars" 6000 in
    let* max_redirects = int_field get loc "max_redirects" 3 in
    let* allow_private_addresses = bool_field get loc "allow_private_addresses" false in
    let* allow_images = bool_field get loc "allow_images" false in
    let* user_agent = string_field get loc "user_agent" default_user_agent in
    let* fallback = names_opt_field get loc "fallback" in
    let* auto_fallback = bool_field get loc "auto_fallback" false in
    let* primary = string_field get loc "primary" "http" in
    let* cost_per_1k = float_opt_field get loc "cost_per_1k" in
    let* crawl4ai_url = string_opt_field get loc "crawl4ai_url" in
    let* crawl4ai_token = string_opt_field get loc "crawl4ai_token" in
    let* crawl4ai_timeout_seconds = float_field get loc "crawl4ai_timeout_seconds" 60.0 in
    let* cache_dir = string_opt_field get loc "cache_dir" in
    let* cache_max_bytes = int_field get loc "cache_max_bytes" 268_435_456 in
    let* cache_max_entry_bytes = int_field get loc "cache_max_entry_bytes" 33_554_432 in
    let* cache_ttl_seconds = float_field get loc "cache_ttl_seconds" 300.0 in
    Ok {
      enabled;
      extractor;
      timeout_seconds;
      max_download_bytes;
      max_text_chars;
      min_text_chars;
      max_match_chars;
      max_redirects;
      allow_private_addresses;
      allow_images;
      user_agent;
      fallback;
      auto_fallback;
      primary;
      cost_per_1k;
      crawl4ai_url;
      crawl4ai_token;
      crawl4ai_timeout_seconds;
      cache_dir;
      cache_max_bytes;
      cache_max_entry_bytes;
      cache_ttl_seconds;
    })

let decode_search_config loc table =
  section loc table (fun get ->
    let* fallback = names_opt_field get loc "fallback" in
    let* free_fallback = names_opt_field get loc "free_fallback" in
    let* health_interval_seconds = float_field get loc "health_interval_seconds" 60.0 in
    let* health_failure_threshold = int_field get loc "health_failure_threshold" 3 in
    let* health_cooldown_seconds = float_field get loc "health_cooldown_seconds" 120.0 in
    Ok {
      fallback;
      free_fallback;
      health_interval_seconds;
      health_failure_threshold;
      health_cooldown_seconds;
    })

let decode_agent_config loc table =
  section loc table (fun get ->
    let* enabled = bool_field get loc "enabled" false in
    let* base_url = string_opt_field get loc "base_url" in
    let* model = string_opt_field get loc "model" in
    let* timeout_seconds = float_field get loc "timeout_seconds" 90.0 in
    let* model_timeout_seconds = float_field get loc "model_timeout_seconds" 30.0 in
    let* max_material_chars = int_field get loc "max_material_chars" 24000 in
    let* max_output_tokens_brief = int_field get loc "max_output_tokens_brief" 500 in
    let* max_output_tokens_report = int_field get loc "max_output_tokens_report" 2500 in
    let* max_cost_usd = float_opt_field get loc "max_cost_usd" in
    let* cost_per_1k_in = float_opt_field get loc "cost_per_1k_in" in
    let* cost_per_1k_out = float_opt_field get loc "cost_per_1k_out" in
    Ok {
      enabled;
      base_url;
      model;
      timeout_seconds;
      model_timeout_seconds;
      max_material_chars;
      max_output_tokens_brief;
      max_output_tokens_report;
      (* TOML has no [null], so the ceiling the default carries is what an absent
         key means; [max_cost_usd = "none"] is not a spelling this file accepts.
         An operator who wants the structural bound as the only ceiling leaves
         the key out and reads the default — P8's [--check] prints it. *)
      max_cost_usd = (match max_cost_usd with None -> Some 0.25 | Some value -> Some value);
      cost_per_1k_in;
      cost_per_1k_out;
    })

let decode_logging_config loc table =
  section loc table (fun get ->
    let* level = choice_field get loc "level" Log_info show_log_level log_levels in
    let* format = choice_field get loc "format" Log_text show_log_format log_formats in
    let* library_level =
      choice_field get loc "library_level" Log_warning show_log_level log_levels
    in
    let* access_log = bool_field get loc "access_log" false in
    let* log_queries = bool_field get loc "log_queries" false in
    let* log_content = bool_field get loc "log_content" false in
    Ok { level; format; library_level; access_log; log_queries; log_content })

let decode_dashboard_config loc table =
  section loc table (fun get ->
    let* enabled = bool_field get loc "enabled" true in
    let* history_path = string_opt_field get loc "history_path" in
    Ok { enabled; history_path })

(* [providers_defaulted] is a report, never a key: it is not in the vocabulary
   the decoder reads, so a file that writes it is refused as an unknown key. *)
let decode_table table =
  section "" table (fun get ->
    let* providers = decode_providers get in
    let* default_provider = string_opt_field get "" "default_provider" in
    let* permitted_providers = names_opt_field get "" "permitted_providers" in
    let* policy = subsection get "policy" default_policy_config decode_policy_config in
    let* fetch = subsection get "fetch" default_fetch_config decode_fetch_config in
    let* search = subsection get "search" default_search_config decode_search_config in
    let* agent = subsection get "agent" default_agent_config decode_agent_config in
    let* logging = subsection get "logging" default_logging_config decode_logging_config in
    let* dashboard = subsection get "dashboard" default_dashboard_config decode_dashboard_config in
    resolve ~providers ?default_provider ?permitted_providers ~policy ~fetch ~search ~agent ~logging
      ~dashboard ())

let expanduser path =
  match (path, Sys.getenv_opt "HOME") with
  | "~", Some home when home <> "" -> home
  | _, Some home when home <> "" && String.length path > 1 && path.[0] = '~' && path.[1] = '/' ->
      home ^ String.sub path 1 (String.length path - 1)
  | _ -> path

let config_path path =
  let named =
    match path with
    | Some value when value <> "" -> Some value
    | _ ->
        (match Sys.getenv_opt "SEEKWRIGHT_CONFIG" with
        | Some value when value <> "" -> Some value
        | _ -> None)
  in
  expanduser (Option.value ~default:default_config_path named)

let is_file path =
  try Sys.file_exists path && not (Sys.is_directory path) with Sys_error _ -> false

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
    really_input_string channel (in_channel_length channel))

let example_config =
  {|[providers."exa:free"]
enabled = true

[providers."parallel:free"]
enabled = true
|}

let keyless_hint table =
  match List.assoc_opt "providers" (bindings table) with
  | Some (T.TTable entries) when bindings entries <> [] ->
      "\n\nA config that needs no API key:\n\n" ^ example_config
  | _ -> ""

(* The [toml] library's lexer reads TOML 1.0's decimal integers and floats, but
   not non-decimal integer bases or [inf]/[nan] spellings. A hexadecimal, octal
   or binary integer becomes decimal; infinity or NaN becomes a quoted string.
   A signed non-decimal integer ([+0x10]) is invalid TOML and left for the parser
   to reject. *)
let value_terminator ch =
  ch = ' ' || ch = '\t' || ch = '\n' || ch = '\r' || ch = ',' || ch = ']' || ch = '}'
  || ch = '#'

let hex_digit ch = is_digit ch || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')

(* The digits' value as an OCaml int, or [None] once the accumulation would pass
   {!max_int}. [int_of_string] cannot be the reader here: for a hexadecimal,
   octal or binary literal it wraps modulo the int width rather than failing, so
   a literal one bit too wide would be rewritten to a wrong — possibly negative —
   decimal instead of being left for the parser to refuse. *)
let digits_value base digits =
  let digit_value ch =
    if ch >= '0' && ch <= '9'
    then Char.code ch - Char.code '0'
    else if ch >= 'a' && ch <= 'f'
    then Char.code ch - Char.code 'a' + 10
    else Char.code ch - Char.code 'A' + 10
  in
  let base = Int64.of_int base in
  let limit = Int64.of_int max_int in
  let value = ref 0L in
  let fits = ref true in
  String.iter
    (fun ch ->
      if !fits
      then
        let d = Int64.of_int (digit_value ch) in
        if Int64.compare !value (Int64.div (Int64.sub limit d) base) > 0
        then fits := false
        else value := Int64.add (Int64.mul !value base) d)
    digits;
  if !fits then Some (Int64.to_int !value) else None

(* [i] is at a [0]; the non-decimal literal that starts there, if any, as
   (decimal spelling, end index). A run of digits and single underscores is
   required, and the token has to end at a value boundary. A value wider than an
   OCaml int is left alone so the parser reports it rather than the pass
   truncating it. *)
let non_decimal_literal text i =
  let n = String.length text in
  let digit, base =
    if i + 1 >= n || text.[i] <> '0'
    then (fun _ -> false), 0
    else
      match text.[i + 1] with
      | 'x' -> hex_digit, 16
      | 'o' -> (fun ch -> ch >= '0' && ch <= '7'), 8
      | 'b' -> (fun ch -> ch = '0' || ch = '1'), 2
      | _ -> (fun _ -> false), 0
  in
  if base = 0
  then None
  else begin
    let j = ref (i + 2) in
    let digits = Buffer.create 8 in
    let prev_digit = ref false in
    let valid = ref true in
    while !j < n && (digit text.[!j] || text.[!j] = '_') do
      if text.[!j] = '_'
      then begin
        if not !prev_digit then valid := false;
        prev_digit := false
      end
      else begin
        Buffer.add_char digits text.[!j];
        prev_digit := true
      end;
      incr j
    done;
    if (not !valid) || Buffer.length digits = 0 || not !prev_digit
    then None
    else if !j < n && not (value_terminator text.[!j])
    then None
    else
      match digits_value base (Buffer.contents digits) with
      | Some value -> Some (string_of_int value, !j)
      | None -> None
  end

(* [i] is at the start of an infinity or NaN value, with an optional sign, as
   (quoted spelling, end index). The quoted spelling is what the loader's number
   reader takes, so the parser never has to know the word. *)
let inf_nan_literal text i =
  let n = String.length text in
  let signed = i < n && (text.[i] = '+' || text.[i] = '-') in
  let body = if signed then i + 1 else i in
  let word =
    if body + 3 <= n && String.sub text body 3 = "inf"
    then Some "inf"
    else if body + 3 <= n && String.sub text body 3 = "nan"
    then Some "nan"
    else None
  in
  match word with
  | None -> None
  | Some _ ->
      let stop = body + 3 in
      if stop < n && not (value_terminator text.[stop])
      then None
      else Some ("\"" ^ String.sub text i (stop - i) ^ "\"", stop)

let translate_toml_literals text =
  let n = String.length text in
  let out = Buffer.create (n + 16) in
  let i = ref 0 in
  let expect_value = ref false in
  let squares = ref 0 in
  let braces = ref 0 in
  let line_start = ref true in
  let in_header = ref false in
  let copy () =
    Buffer.add_char out text.[!i];
    incr i
  in
  let copy_string quote triple =
    let width = if triple then 3 else 1 in
    Buffer.add_substring out text !i width;
    i := !i + width;
    let closed = ref false in
    while (not !closed) && !i < n do
      if quote = '"' && text.[!i] = '\\' && !i + 1 < n
      then begin
        copy ();
        copy ()
      end
      else if triple && !i + 2 < n && text.[!i] = quote && text.[!i + 1] = quote
              && text.[!i + 2] = quote
      then begin
        Buffer.add_substring out text !i 3;
        i := !i + 3;
        closed := true
      end
      else if (not triple) && text.[!i] = quote
      then begin
        copy ();
        closed := true
      end
      else copy ()
    done
  in
  while !i < n do
    let ch = text.[!i] in
    if !in_header
    then begin
      if ch = ']' then in_header := false;
      if ch = '\n' then line_start := true
      else if ch <> ' ' && ch <> '\t' && ch <> '\r' then line_start := false;
      copy ()
    end
    else if ch = '#'
    then while !i < n && text.[!i] <> '\n' do
      copy ()
    done
    else if ch = '\n'
    then begin
      if !squares = 0 && !braces = 0 then expect_value := false;
      line_start := true;
      copy ()
    end
    else if ch = ' ' || ch = '\t' || ch = '\r'
    then copy ()
    else begin
      let was_line_start = !line_start in
      line_start := false;
      match ch with
      | '"' ->
          let triple = !i + 2 < n && text.[!i + 1] = '"' && text.[!i + 2] = '"' in
          copy_string '"' triple;
          expect_value := false
      | '\'' ->
          let triple = !i + 2 < n && text.[!i + 1] = '\'' && text.[!i + 2] = '\'' in
          copy_string '\'' triple;
          expect_value := false
      | '=' ->
          copy ();
          expect_value := true
      | '[' ->
          copy ();
          if was_line_start && !squares = 0 && !braces = 0
          then in_header := true
          else begin
            incr squares;
            expect_value := true
          end
      | ']' ->
          copy ();
          if !squares > 0 then decr squares;
          expect_value := false
      | '{' ->
          copy ();
          incr braces;
          expect_value := false
      | '}' ->
          copy ();
          if !braces > 0 then decr braces;
          expect_value := false
      | ',' ->
          copy ();
          expect_value := !squares > 0 && !braces = 0
      | _ ->
          if !expect_value
          then (
            match
              match non_decimal_literal text !i with
              | Some literal -> Some literal
              | None -> inf_nan_literal text !i
            with
            | Some (replacement, stop) ->
                Buffer.add_string out replacement;
                i := stop;
                expect_value := false
            | None ->
                copy ();
                expect_value := false)
          else copy ()
    end
  done;
  Buffer.contents out

(* A stdio server that dies silently is miserable to debug, so a bad config
   names the file and the fault rather than falling back to defaults. A config
   that enables *nothing* is not bad: it resolves to the keyless set, and
   [providers_defaulted] is what lets the startup line name that set. *)
let load path =
  let candidate = config_path path in
  let* text =
    if not (is_file candidate)
    then Ok None
    else
      (try Ok (Some (read_file candidate))
       with Sys_error message ->
         Error (Printf.sprintf "seekwright: cannot read %s: %s" candidate message))
  in
  match text with
  | None -> resolve ()
  | Some text ->
      (match Toml.Parser.from_string (translate_toml_literals text) with
      | `Error (message, _) ->
          Error (Printf.sprintf "seekwright: invalid TOML in %s: %s" candidate message)
      | `Ok table ->
          (match decode_table table with
          | Ok config -> Ok config
          | Error fault ->
              Error
                (Printf.sprintf "seekwright: invalid config in %s: %s%s" candidate fault
                   (keyless_hint table))))
