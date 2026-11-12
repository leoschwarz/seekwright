(** Configuration: what a deployment enables, and what it refuses to start on.

    Port of [src/seekwright/config.py]. Two rules decide every failure here:

    - Secrets come from the environment only ([SEEKWRIGHT_*]), never from the
      file, because files get committed. The one exception is
      [fetch.crawl4ai_token], which authenticates this server to an internal
      service the same file already names.
    - Nothing is inferred. An unknown provider name, an unknown key, a ladder
      name that cannot run, or an enabled provider with no key is a startup
      failure naming the file and the fault: a setting that parses, loads and
      does nothing is the failure mode every validator here exists to remove.

    What is *not* a failure is a config that enables nothing. That resolves to
    {!keyless_providers} -- the names that reach their endpoint with no account,
    key or card -- and {!t.providers_defaulted} records that the set was
    implicit, so the startup line and [--check] can say it out loud rather than
    assume it.

    The Python tree validates through pydantic models. This module decodes the
    TOML table into plain records and then runs the same validators in the same
    order -- fetch and search section rules first, then the provider block,
    then the permission set -- so one file yields the same config, or the same
    refusal sentence, in either tree. pydantic's structured wrapper
    ([type=extra_forbidden], the input value it echoes back) is not reproduced;
    the sentence each validator raises is, quoting and sorted name lists
    included.

    A bad config is an [Error] value carrying the whole operator-facing message,
    not an exception: the CLI (P8) prints it and exits 1 where Python raises
    [SystemExit]. Nothing in here logs, so a caller decides what a failure is
    worth saying. *)

(** A provider name: [backend] or [backend:flavour] ([exa], [exa:free]). The
    flavour decides the *route*, the backend decides the account -- and the
    environment variable holding the key, since [:] cannot appear in one. *)
type name = string

(** The frozen vocabularies. These are the names the validators accept, and the
    sets the routing decisions read; they are facts about the adapters this
    build ships, not a pricing page. Each is a sorted list, which is both the
    set semantics Python's [frozenset] gives and the order a refusal sentence
    prints them in. *)

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
(** What a config that enables nothing resolves to, in that order. Not a set:
    the order is the install default's walk. *)

val free_provider_order : name list
(** Walk order for [search(mode="free")] and for an unnamed search on an
    all-free deployment. [search.free_fallback] narrows it. *)

val untested_providers : name list
(** Shipped, but no live run in-repo. The startup line and [--check] say so;
    a name leaves only once a live run has passed. *)

val known_extractors : string list
(** One name per extraction backend this port can build; [fetch.extractor] is
    validated against this, exactly as a provider name is against
    {!known_providers}. Python's [trafilatura] is absent because its library
    does not ride on the port, so naming it here would accept a config that
    construction then refuses. *)

(** One row of the fetch fallback registry: what [fetch.fallback] may name, and
    the two facts the ladder and the report need from it. Ported from
    [fetcher.KNOWN_FALLBACKS]'s data columns; what Python's row carries besides
    these is its builder, which is the P6 fetch stack's, keyed by this name. *)
type fetch_fallback = {
  name : name;  (** what the ladder and the journal record *)
  billable : bool;  (** the tier: [fetch.fallback] refuses it anywhere but last *)
  endpoint : string option;  (** the constant it dials... *)
  fetch_key : string option;  (** ...or the [fetch] key holding its host *)
}

val known_fetch_fallbacks : fetch_fallback list
val default_user_agent : string
val default_config_path : string
(** The install default: [~/.config/seekwright/config.toml], [~] expanded by
    {!config_path}. *)

(** {2 The sections} *)

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
(** The spelling loguru names the level by, and the spelling [logging.level]
    takes in TOML. *)

type log_format =
  | Log_text  (** stdio's human reader *)
  | Log_json  (** a cluster's log shipper *)

val show_log_format : log_format -> string

(** One provider's entry: [[providers.<name>]]. Every key has a working default
    except where a later check makes it required -- [searxng]'s [url] and
    [algolia]'s [app_id]/[index] -- and those are startup errors, not
    half-built adapters. *)
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

(** The [fetch] tool's settings. A section of its own, not a [[providers]]
    entry: a fetcher has no key, no cost per 1k, and no name a caller pins. *)
type fetch_config = {
  enabled : bool;
  extractor : string;
  timeout_seconds : float;
  max_download_bytes : int;  (** a memory guardrail, not a content policy *)
  max_text_chars : int;
  min_text_chars : int;  (** under this the page counts as having no content *)
  max_match_chars : int;
  max_redirects : int;
  allow_private_addresses : bool;  (** off: the URL is model-supplied *)
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

(** Agent mode: the [answer] tool. Off by default, and that default is the
    decision -- turning it on is what creates a third-party egress point. *)
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

type logging_config = {
  level : log_level;
  format : log_format;
  library_level : log_level;
  access_log : bool;
  log_queries : bool;  (** query text and fetched URLs are the caller's *)
  log_content : bool;
}

type dashboard_config = {
  enabled : bool;
  history_path : string option;  (** opt-in append-only JSONL journal *)
}

(** A resolved configuration. Build one with {!resolve} (the port of
    [Config(...)] plus its model validators) or read it from a file with
    {!load}; {!default} is what a fresh install with no file at all gets. *)
type t = {
  providers : (name * provider_config) list;
  (** The entries this file declares, in the TOML table's key order. When the
      file declared no enabled name this is {!keyless_providers} in its walk
      order, not the empty list. Nothing dispatches off this order;
      {!enabled_providers} is the sorted list every sentence prints. *)
  default_provider : name option;
  (** [None] with several enabled names means callers pass [provider]. With
      exactly one enabled name it resolves to that name. *)
  permitted_providers : name list option;
  (** [None] is permissive. A declared list is deny-by-default, and [Some [] ]
      refuses every name -- the absent key and [[]] are different answers. *)
  policy : policy_config;
  fetch : fetch_config;
  search : search_config;
  agent : agent_config;
  logging : logging_config;
  dashboard : dashboard_config;
  providers_defaulted : bool;
  (** Whether {!t.providers} is the implicit keyless set. There is no
      [providers_defaulted] key in the file: this is a report, never a setting. *)
}

(** The tables the file may declare, in the order they are decoded. The
    documentation guard reads this, so a section that no operator page names fails
    a run instead of arriving undocumented — the reason it is public. *)
val section_names : string list

(** The sections' defaults, as the file's absent keys leave them. *)
val default_provider_config : provider_config
val default_policy_config : policy_config
val default_fetch_config : fetch_config
val default_search_config : search_config
val default_agent_config : agent_config
val default_logging_config : logging_config
val default_dashboard_config : dashboard_config
val default : t

(** {2 Reading answers off a configuration} *)

val provider : t -> name -> provider_config option
val enabled_providers : t -> name list
(** Enabled names, sorted. *)

val effective_providers : t -> name list
(** The names this deployment may actually dispatch to: enabled [intersection]
    permitted. This is the one home for "unset is permissive". *)

val is_permitted : t -> name -> bool
(** Asked *after* the enabled question, never instead of it. *)

val default_route_is_free_only : t -> bool
(** Whether an unnamed [search] may walk the free set instead of refusing: true
    only while every name it may dispatch to cannot bill. Read by the engine's
    resolve and by [--check]'s [default] line, so the route taken and the route
    reported cannot disagree. *)

val api_key_env_var : name -> string
(** The variable holding a provider's key, named for the backend segment. Every
    site that names a variable goes through here, so the operator-facing
    messages cannot drift from {!api_key}. *)

val api_key : t -> name -> string option
(** Read from the environment; an empty value reads as absent, as Python's [or
    None] does. *)

val agent_api_key : unit -> string option
(** The model endpoint's key. Not [SEEKWRIGHT_<provider>_API_KEY]: the model is
    not a provider -- not searchable, not pinnable, not one of the
    interchangeable things [[providers]] lists. *)

val missing_api_keys : t -> name list
(** Enabled providers whose key is absent. Reported, never raised: [server.main]
    refuses to start on this while [--check] prints the same fact and keeps
    going. *)

val missing_agent_settings : t -> string list
(** What [[agent] enabled = true] needs and does not have, by name. Reported for
    the same reason as {!missing_api_keys}. *)

(** {2 The validators} *)

(** Each returns the refusal sentence pydantic's [ValueError] carries, or [Ok ()].
    They are public because the rules are facts a caller re-checks -- the
    fallback ladder's shape is read by the fetch stack (P6) and by [--check] (P8)
    against the registry, not only by the loader. *)

val validate_provider_names : name list -> (unit, string) result
(** An unknown provider name, naming its replacement when it is a retired
    spelling. *)

val validate_fetch_extractor : string -> (unit, string) result
val validate_fetch_fallbacks : fetch_fallback list -> name list -> (unit, string) result
(** At most one attempt each, every name in the registry, and the one name that
    can bill last -- asked of each row's [billable] flag, never of a name, so a
    priced vendor this build has never heard of inherits the rule. *)

val validate_fetch_primary : fetch_fallback list -> name -> (unit, string) result
(** The primary route's shape: a name, and no tier rule. A billable primary is
    the operator paying a named price for every unnamed fetch. *)

val validate_search_fallbacks : name list -> (unit, string) result
val validate_search_free_fallbacks : name list -> (unit, string) result
(** {!validate_search_fallbacks}'s shape plus the rule that makes the mode
    honest: no fallback that can bill. *)

val validate_permitted_providers : name list -> (name list option, string) result
(** Duplicates and unknown names are errors; a list containing ["*"] normalises
    to [None], because "*" is not a provider name and "everything" is the same
    list as no list. An explicitly empty list stays [Some [] ]. *)

(** {2 Resolution and loading} *)

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
(** The port of [Config(...)] and its model validators, in pydantic's order:
    fetch's section rules, search's section rules, the provider block (unknown
    names, the keyless default, [searxng]'s url, [algolia]'s index, the default
    provider, the two ladders' enabled names), then the permission set. *)

val config_path : name option -> string
(** [path], else [$SEEKWRIGHT_CONFIG], else {!default_config_path}; [~] expanded
    either way. An empty value is unset, as Python's [or] chain treats it. *)

val load : name option -> (t, string) result
(** Read one config file. A missing file is the first run and loads the
    defaults; a malformed one is an [Error] naming the path and the fault, with
    the keyless example appended when the file itself named providers. *)

val example_config : string
(** Shown to an operator whose file named something this build could not build:
    keyless, needing no export line, and in the quoted table form a flavoured
    name requires. *)
