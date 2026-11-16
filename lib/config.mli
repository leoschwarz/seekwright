(** Configuration: what a deployment enables, and what it refuses to start on.

    - Secrets come from the environment only ([SEEKWRIGHT_*]), never from the
      file, because files get committed. The one exception is
      [fetch.crawl4ai_token], which authenticates this server to an internal
      service the same file already names.
    - Nothing is inferred. An unknown provider name, an unknown key, a ladder
      name that cannot run, or an enabled provider with no key is a startup
      failure naming the file and the fault.
    - An empty configuration that enables nothing resolves to {!keyless_providers}
      and {!t.providers_defaulted} is set to true. *)

(** A provider name: [backend] or [backend:flavour] ([exa], [exa:free]). The
    flavour decides the route, the backend decides the account and the
    environment variable name. *)
type name = string

val known_providers : name list
val permitted_fetch_names : name list
(** The only non-provider name {!t.permitted_providers} may hold: a fetch
    fallback a declared permission set has to be able to vouch for. *)

val renamed_providers : (name * name) list
(** Retired spellings and what replaced them. A rename is hard -- there is no
    alias -- so an error naming one of these names its replacement. *)

val providers_requiring_key : name list
val free_providers : name list
(** The names a free route may dispatch to: the ones that cannot bill whatever
    the caller holds. A metered free tier can bill, so it is out. *)

val keyless_providers : name list
(** What a config that enables nothing resolves to, in that order. *)

val free_provider_order : name list
(** Walk order for [search(mode="free")] and for an unnamed search on an
    all-free deployment. [search.free_fallback] narrows it. *)

val untested_providers : name list
(** Shipped, but no live run in-repo. The startup line and [--check] say so;
    a name leaves only once a live run has passed. *)

val known_extractors : string list
(** One name per extraction backend this build can build; [fetch.extractor] is
    validated against this. *)

(** One row of the fetch fallback registry: what [fetch.fallback] may name, and
    the facts the ladder and the report need from it. *)
type fetch_fallback = {
  name : name;  (** what the ladder and the journal record *)
  billable : bool;  (** the tier: [fetch.fallback] refuses it anywhere but last *)
  endpoint : string option;  (** the constant it dials... *)
  fetch_key : string option;  (** ...or the [fetch] key holding its host *)
  default_cost : float option;  (** the price the journal records; [None] is
      nothing billed, not free, and [fetch.cost_per_1k] corrects a priced row *)
}

val known_fetch_fallbacks : fetch_fallback list
val default_user_agent : string
val default_config_path : string
(** The install default: [~/.config/seekwright/config.toml], [~] expanded by
    {!config_path}. *)

type output_kind =
  | Sourced_answer  (** Linkup's prose answer *)
  | Search_results  (** Linkup's result list; Parallel's preset works likewise *)

val show_output_kind : output_kind -> string

type log_level =
  | Log_trace
  | Log_debug
  | Log_info
  | Log_success
  | Log_warning
  | Log_error
  | Log_critical

val show_log_level : log_level -> string
(** The spelling [logging.level] takes in TOML. *)

type log_format =
  | Log_text  (** stdio's human reader *)
  | Log_json  (** a cluster's log shipper *)

val show_log_format : log_format -> string

(** One provider's entry: [[providers.<name>]]. Every key has a working default
    except where a later check makes it required -- [searxng]'s [url] and
    [algolia]'s [app_id]/[index]. *)
type provider_config = {
  enabled : bool;
  cost_per_1k : float option;  (** reporting only; nothing routes on it *)
  depth : string;  (** Linkup only: [deep] is a ~10x cost cliff *)
  output_type : output_kind;
  mode : string;  (** Parallel only: the preset that decides the price *)
  url : string option;  (** Exa/Parallel override; SearXNG's required instance *)
  free_cooldown_seconds : float;  (** [exa] only: skip the free tier this long *)
  app_id : string option;  (** Algolia only: a public identifier, not a secret *)
  index : string option;
  title_attr : string option;
  url_attr : string option;
  snippet_attr : string option;
}

(** Per-deployment limits applied to every provider call. *)
type policy_config = {
  max_snippet_chars : int;
  max_result_text_chars : int;
  provider_timeout_seconds : float;
}

(** The [fetch] tool's settings. *)
type fetch_config = {
  enabled : bool;
  extractor : string;
  timeout_seconds : float;
  max_download_bytes : int;  (** a memory guardrail, not a content policy *)
  max_text_chars : int;
  min_text_chars : int;  (** under this the page counts as having no content *)
  max_match_chars : int;
  max_redirects : int;
  allow_private_addresses : bool;
  (** Off by default. When on, private intranet addresses may be fetched by the
      local reader. Third-party fallbacks remain public-only. *)
  allow_images : bool;
  user_agent : string;
  fallback : string list option;  (** the walk's order; [None] is the absent key *)
  auto_fallback : bool;  (** whether a failed local read walks it unasked *)
  primary : string;  (** the route an unnamed fetch leads with; ["http"] is local *)
  cost_per_1k : float option;
  crawl4ai_url : string option;
  crawl4ai_token : string option;  (** the one credential that lives in the file *)
  crawl4ai_timeout_seconds : float;
  cache_dir : string option;  (** unset is off: every fetch fetches *)
  cache_max_bytes : int;
  cache_max_entry_bytes : int;
  cache_ttl_seconds : float;
}

(** The [search] tool's default route and provider health. The route that
    substitutes here is the default one only: a caller that names a provider
    keeps the terminal error. *)
type search_config = {
  fallback : string list option;
  free_fallback : string list option;
  health_interval_seconds : float;  (** [0.0] disables the periodic ping *)
  health_failure_threshold : int;
  health_cooldown_seconds : float;
}

(** Agent mode: the [answer] tool. Off by default. *)
type agent_config = {
  enabled : bool;
  base_url : string option;
  model : string option;
  timeout_seconds : float;  (** the whole call, retrieval included *)
  model_timeout_seconds : float;  (** the model request inside it *)
  max_material_chars : int;
  max_output_tokens_brief : int;
  max_output_tokens_report : int;
  max_cost_usd : float option;  (** [None] leaves the structural bound alone *)
  cost_per_1k_in : float option;
  cost_per_1k_out : float option;
}

(** What this process logs, and at what level. [level], [format], [log_queries]
    and [log_content] are honoured.

    [library_level] and [access_log] defaults load and do nothing; an explicitly
    non-default value is a load-time refusal. *)
type logging_config = {
  level : log_level;
  format : log_format;
  library_level : log_level;  (** inert at its default; refused at any other value *)
  access_log : bool;  (** inert at its default; refused at [true] *)
  log_queries : bool;  (** query text and fetched URLs are the caller's *)
  log_content : bool;
}

type dashboard_config = {
  enabled : bool;
  history_path : string option;  (** opt-in append-only JSONL journal *)
}

(** A resolved configuration. Build one with {!resolve} or read it from a file
    with {!load}; {!default} is what a fresh install with no file gets. *)
type t = {
  providers : (name * provider_config) list;
  (** The entries this file declares, in the TOML table's key order. When the
      file declared no enabled name this is {!keyless_providers} in its walk
      order, not the empty list. *)
  default_provider : name option;
  (** [None] with several enabled names means callers pass [provider]. With
      exactly one enabled name it resolves to that name. *)
  permitted_providers : name list option;
  (** [None] is permissive. A declared list is deny-by-default, and [Some []]
      refuses every name. *)
  policy : policy_config;
  fetch : fetch_config;
  search : search_config;
  agent : agent_config;
  logging : logging_config;
  dashboard : dashboard_config;
  providers_defaulted : bool;
  (** Whether {!t.providers} is the implicit keyless set. *)
}

val section_names : string list

val default_provider_config : provider_config
val default_policy_config : policy_config
val default_fetch_config : fetch_config
val default_search_config : search_config
val default_agent_config : agent_config
val default_logging_config : logging_config
val default_dashboard_config : dashboard_config
val default : t

val provider : t -> name -> provider_config option
val enabled_providers : t -> name list
(** Enabled names, sorted. *)

val effective_providers : t -> name list
(** The names this deployment may actually dispatch to: enabled [intersection]
    permitted. *)

val is_permitted : t -> name -> bool

val default_route_is_free_only : t -> bool
(** Whether an unnamed [search] may walk the free set instead of refusing: true
    only while every name it may dispatch to cannot bill. *)

val api_key_env_var : name -> string
(** The variable holding a provider's key, named for the backend segment. *)

val api_key : name -> string option
(** Read from the environment; an empty value reads as absent. *)

val agent_api_key : unit -> string option
(** The model endpoint's key ([SEEKWRIGHT_AGENT_API_KEY] or [OPENAI_API_KEY]). *)

val missing_api_keys : t -> name list
(** Enabled providers whose key is absent. *)

val missing_agent_settings : t -> string list
(** What [[agent] enabled = true] needs and does not have, by name. *)

val validate_provider_names : name list -> (unit, string) result
(** An unknown provider name, naming its replacement when it is a retired
    spelling. *)

val validate_fetch_extractor : string -> (unit, string) result
val validate_fetch_fallbacks : fetch_fallback list -> name list -> (unit, string) result
(** At most one attempt each, every name in the registry, and the one name that
    can bill last. *)

val validate_fetch_primary : fetch_fallback list -> name -> (unit, string) result
val validate_search_fallbacks : name list -> (unit, string) result
val validate_search_free_fallbacks : name list -> (unit, string) result
(** {!validate_search_fallbacks}'s shape plus the rule that makes the mode
    honest: no fallback that can bill. *)

val validate_permitted_providers : name list -> (name list option, string) result
(** Duplicates and unknown names are errors; a list containing ["*"] normalises
    to [None]. An explicitly empty list stays [Some []]. *)

val validate_logging_on_this_port : logging_config -> (unit, string) result
(** The two uvicorn-shaped keys, refused when they carry a non-default value. *)

val resolve
  :  ?providers:(name * provider_config) list
  -> ?default_provider:name
  -> ?permitted_providers:name list
  -> ?policy:policy_config
  -> ?fetch:fetch_config
  -> ?search:search_config
  -> ?agent:agent_config
  -> ?logging:logging_config
  -> ?dashboard:dashboard_config
  -> unit
  -> (t, string) result

val config_path : string option -> string
(** [path], else [$SEEKWRIGHT_CONFIG], else {!default_config_path}; [~] expanded
    either way. An empty value is treated as unset.

    A path is a {i path}, not a [name]: the two are different vocabularies. *)

val load : string option -> (t, string) result
(** Read one config file. A missing file loads the defaults; a malformed one is
    an [Error] naming the path and the fault. *)

val example_config : string
(** Shown to an operator whose file named something this build could not build:
    keyless, needing no export line, and in the quoted table form a flavoured
    name requires. *)
