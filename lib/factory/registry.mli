(** One declarative row per provider name: what building an adapter costs, needs, and is allowed to
    reach. *)

(** Where the name's credential rides, when it has one. This is the shape the adapter uses on the
    wire {i and} the shape the readiness probe uses — one declaration, so a probe that authenticates
    differently from a search is a bug this module cannot express.

    [Key_in_query] is [serpapi]'s documented shape, and the reason {!Seekwright.Provider.redact_url}
    is not optional hygiene: a key in a query string is a key in every URL that names the request.
    [App_id_and_key] is [algolia]'s pair, where the first header is a public identifier and only the
    second is the secret. *)
type credential =
  | No_credential
  | Header of { header : string; prefix : string }
  | App_id_and_key of { id_header : string; key_header : string }
  | Key_in_query of string

(** What a name needs before it can be built. [Api_key] is read from the environment and from
    nowhere else; the rest are this name's own [[providers.<name>]] keys. Config validation already
    refuses an enabled [searxng] without a [url] and an enabled [algolia] without [app_id]/[index],
    so a row's answer here is what narrows those values to a present string in the builder — the job
    the oracle's factory guards do — and a deployment built around validation is refused rather than
    half-built. *)
type prerequisite = Api_key | Config_url | App_id | Index

(** How the per-query figure the row's price implies is computed. [Flat] is one request, one charge.
    [Extra_results] is [exa]'s published shape: the row's rate covers the first [first] results and
    each result beyond them adds [per_extra_1k] per thousand. [Credit_multiplier] is [serper]'s: the
    vendor bills [multiplier] credits for a request once the ask passes [over] results, so the price
    per thousand is a per-{i credit} figure and a 20-result search costs double a 5-result one. A
    name fixed at zero answers zero whatever this says. *)
type cost_model =
  | Flat
  | Extra_results of { first : int; per_extra_1k : float }
  | Credit_multiplier of { over : int; multiplier : int }

(** The destination, and whether the config gets a say in it. [Fixed_uri] is a module constant — for
    a built name it {i is} that adapter's own [endpoint] value, so the row and the adapter hold one
    URI rather than two. [Url_override] is [exa], [exa:free] and [parallel:free]:
    [[providers.<name>] url] when the operator wrote one, the vendor's hosted endpoint otherwise.
    [Url_required] is [searxng], whose only address is the operator's instance. [Algolia_index] is
    derived from [app_id] and [index], because that host {i is} the deployment. *)
type endpoint_source = Fixed_uri of Uri.t | Url_override of Uri.t | Url_required | Algolia_index

type args = {
  net : Seekwright.Provider.Net.t;
  now : unit -> float;
  key : string option;
  endpoint : Uri.t;
  entry : Seekwright.Config.provider_config;
  cost_for : int -> float;
  snippet_chars : int;
  text_chars : int;
  log : Seekwright.Log.log option;
}
(** What a row's builder is handed, resolved once per config entry so no builder re-derives a price,
    a cap, or a timeout: [factory._BuildArgs] in the oracle. [key] is already the row's own, see
    {!key_for}; [endpoint] is that row's {!uri} already resolved, which is what lets a
    config-derived destination ([searxng]'s instance) be dialed from the same reading the grant was
    built from rather than re-parsed from the config key. [entry] rides along because which of a
    name's keys its adapter reads is that adapter's business: a builder reads the fields it needs
    off the record, and no row keeps an index of them. [log] rides along for the one adapter that
    narrates its own ladder — the [exa] row's free-before-key walk logs [exa.escalated],
    [exa.cooldown] and [exa.both_failed] as it runs — and every other builder ignores it. *)

(** Whether this build holds the adapter. [Adapter_session] builds a {!Seekwright.Provider.session}
    pair (adapter plus warmup) for MCP-backed adapters. *)
type build =
  | Adapter of (args -> Seekwright.Provider.t)
  | Adapter_session of (args -> Seekwright.Provider.session)
  | Deferred of string

type probe_source = No_probe | Probe of (Seekwright.Config.t -> string option -> string option)

type row = {
  name : Seekwright.Config.name;
  build : build;
  endpoint : endpoint_source;
  credential : credential;
  requires : prerequisite list;
  default_cost : float option;
  cost_model : cost_model;
  timeout_floor : float;
  probe : probe_source;
  ocaml_live_tested : bool;
}

val rows : row list

val row : Seekwright.Config.name -> row option
(** The row for a name, if the inventory carries one. A name outside the frozen seventeen has none,
    and {!Seekwright.Config} cannot produce one. *)

(** {1 Reading a row} *)

val names : Seekwright.Config.name list
(** The row names, sorted. *)

val uri : row -> Seekwright.Config.provider_config -> (Uri.t, string) result
(** The one place a destination is computed: the module constant, the operator's override, or the
    derived host. [Error] is a config value that names no absolute http(s) URL, or one that carries
    credentials in its userinfo — a construction failure the operator sees, never a grant that
    silently allows nothing. *)

val grant_endpoint :
  row -> Seekwright.Config.provider_config -> (Mcp_caps.Policy.endpoint, string) result
(** {!uri} in the form [Policy.with_endpoints] takes: scheme, host, and an explicit port when the
    URI carries one, so an override that pins [:8443] pins that port in the grant too. *)

val timeout_seconds : row -> policy_seconds:float -> float
(** [max policy_seconds row.timeout_floor] — the oracle's merge, and the reason a raised policy
    timeout still gives [tavily] its normal budget while [exa] keeps its thirty seconds. *)

val rate : row -> Seekwright.Config.provider_config -> float
(** What the name is built at, per thousand: config's [cost_per_1k] wins, unless the row fixes the
    price. This is the figure [--check] prints. *)

val cost_of : row -> cost_per_1k:float -> int -> float
(** The row's {!cost_model} applied to a rate the caller names — the shape of the charge on its own.
    {!price} is what a build hands the adapter; this is the same arithmetic with the rate spelled
    out, which is what lets the registry suite pin each row's published shape against a figure. *)

val price : row -> Seekwright.Config.provider_config -> int -> float
(** The row's price rule applied to {!rate}, as a function of the result count the caller asked for
    — the one place a per-query figure comes from. The rule is the row's {!cost_model}, never the
    adapter's: an adapter is handed this function and reports its answer in the result's [cost_usd],
    so [--check --live] and the caller's figure cannot disagree. *)

val key_for : row -> string option
(** The name's credential, environment-only, and only for a row that declares [Api_key]. A keyless
    name answers [None] even when its variable is set, which is what keeps [exa:free] anonymous
    while [exa] spends the key. *)

val missing_prerequisite : row -> Seekwright.Config.provider_config -> string option
(** Why this deployment cannot build this name, in one sentence naming every missing prerequisite,
    or [None] when all are present. A name whose row can build it is not an unsupported name: it is
    this deployment's incomplete configuration, and the two deserve different sentences. It reads
    the row's own [provider_config] and the environment, so no whole [{!Seekwright.Config.t}] is
    needed to answer it. *)

val probe_spec : row -> Seekwright.Health.probe_spec
(** The probe row: the row's [probe] for the destination and its [credential] for the headers, so
    the probe asks the adapter's destination with the adapter's credential shape. [No_probe] gives
    {!Seekwright.Health.no_probe}. *)

val is_built : row -> bool
(** Whether this build carries the adapter, i.e. whether the row's [build] names a builder —
    [Adapter] or [Adapter_session]. *)
