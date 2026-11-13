(** One declarative row per provider name: what building [exa] costs, needs, and
    is allowed to reach, written down once instead of spread over a builder, a
    probe table, and a price somewhere inside the adapter.

    Port of [src/seekwright/factory.py]'s [_PROVIDERS] plus
    [src/seekwright/health.py]'s [_PROBES], merged: the oracle keeps a row per
    name in two files and a builder function per name in the first, and this
    module keeps one row that answers every question construction asks about a
    name — the endpoint and how it is derived, the price and the pricing model,
    the least time the backend needs, which policy cap bounds its results, where
    its credential rides, what its readiness probe asks, which of its own config
    keys it reads, and whether this port has a dispatch to it at all.

    {1 Why a row rather than a builder}

    A Python builder is a function, so the facts it uses are visible only by
    reading it; a row is data, so one suite can ask all seventeen names the same
    questions and a missing answer fails a diff rather than a review. Three
    properties the two-row factory could only assert in prose become checkable:

    - {b One destination.} {!uri} is the only place a name's destination is
      computed, and {!grant_endpoint} derives the [Policy] entry from it through
      {!Seekwright.Provider.policy_of_uri}. The adapter dials {!uri}; the grant
      allows {!grant_endpoint}; there is no third spelling of the host to keep in
      step. A config-derived destination — [searxng]'s instance, an [exa] or
      [parallel:free] [url] override, [algolia]'s [app_id]-derived host — is read
      from that one config value here and nowhere else.
    - {b One price.} {!price} merges the row's default with the config's
      correction, and a [default_cost] of [None] marks the one name whose price is
      fixed at zero rather than merely defaulted to it.
    - {b No credential crossing.} {!key_for} answers a key only for a row that
      declares [Api_key] among its prerequisites, so a keyless name cannot be
      handed one even when its environment variable is set:
      [SEEKWRIGHT_EXA_API_KEY] serves [exa], never [exa:free]. That key then
      reaches exactly one place — the {!args} of that one row's builder, whose
      adapter attaches it on its own fixed-endpoint grant.

    {1 Rows for names this port cannot dispatch yet}

    A row exists for all seventeen names; the row's [build] says whether this
    build holds the adapter. [Deferred wave] names the wave that will carry it
    (plans/ocaml-finalisation.md, F5), and such a name is still reported "not
    built on this port" by {!Seekwright_factory.Factory} — the row is the
    inventory, never a promise of dispatch. That is what lets a price, a floor, a
    cap, an endpoint derivation and a probe be pinned before the adapter lands,
    and what the adapter's own suite then checks its module against. *)

(** Which policy cap bounds this name's results. The oracle fills [snippet] from a
    SERP adapter and [text] from a content adapter, never both (AGENTS.md, "A
    result carries snippet or text, never both"); [deepseek] is the one name that
    fills both, its documented summary riding beside its snippet. *)
type context_cap =
  | Snippets
  | Text
  | Snippets_and_text

(** Where the name's credential rides, when it has one. This is the shape the
    adapter uses on the wire {i and} the shape the readiness probe uses — one
    declaration, so a probe that authenticates differently from a search is a bug
    this module cannot express.

    [Key_in_query] is [serpapi]'s documented shape, and the reason
    {!Seekwright.Provider.redact_url} is not optional hygiene: a key in a query
    string is a key in every URL that names the request. [App_id_and_key] is
    [algolia]'s pair, where the first header is a public identifier and only the
    second is the secret. *)
type credential =
  | No_credential
  | Header of { header : string; prefix : string }
  | App_id_and_key of { id_header : string; key_header : string }
  | Key_in_query of string

(** What a name needs before it can be built. [Api_key] is read from the
    environment and from nowhere else; the rest are this name's own
    [[providers.<name>]] keys. Config validation already refuses an enabled
    [searxng] without a [url] and an enabled [algolia] without [app_id]/[index],
    so a row's answer here is what narrows those values to a present string in the
    builder — the job [factory.py]'s guards do — and a deployment built around
    validation is refused rather than half-built. *)
type prerequisite =
  | Api_key
  | Config_url
  | App_id
  | Index

(** How the per-query figure the row's price implies is computed. [Flat] is one
    request, one charge. [Extra_results] is [exa]'s published shape: the row's
    rate covers the first [first] results and each result beyond them adds
    [per_extra_1k] per thousand. [Credit_multiplier] is [serper]'s: the vendor
    bills [multiplier] credits for a request once the ask passes [over] results,
    so the price per thousand is a per-{i credit} figure and a 20-result search
    costs double a 5-result one. A name fixed at zero answers zero whatever this
    says. *)
type cost_model =
  | Flat
  | Extra_results of { first : int; per_extra_1k : float }
  | Credit_multiplier of { over : int; multiplier : int }

(** The destination, and whether the config gets a say in it. [Fixed_uri] is a
    module constant — for a built name it {i is} that adapter's own [endpoint]
    value, so the row and the adapter hold one URI rather than two.
    [Url_override] is [exa], [exa:free] and [parallel:free]: [[providers.<name>]
    url] when the operator wrote one, the vendor's hosted endpoint otherwise.
    [Url_required] is [searxng], whose only address is the operator's instance.
    [Algolia_index] is derived from [app_id] and [index], because that host {i is}
    the deployment. *)
type endpoint_source =
  | Fixed_uri of Uri.t
  | Url_override of Uri.t
  | Url_required
  | Algolia_index

(** What a row's builder is handed, resolved once per config entry so no builder
    re-derives a price, a cap, or a timeout: [factory._BuildArgs] in the oracle.
    [key] is already the row's own, see {!key_for}; [endpoint] is that row's {!uri}
    already resolved, which is what lets a config-derived destination
    ([searxng]'s instance) be dialed from the same reading the grant was built
    from rather than re-parsed from the config key. [entry] rides along because
    which of a name's keys its adapter reads is that adapter's business, and the
    row names them in its [settings]. *)
type args = {
  net : Seekwright.Provider.Net.t;
  now : unit -> float;
  key : string option;
  endpoint : Uri.t;
  entry : Seekwright.Config.provider_config;
  cost_per_1k : float;
  snippet_chars : int;
  text_chars : int;
}

(** Whether this build holds the adapter. [Deferred wave] is a name the port has
    inventoried but not written: nothing builds it, so it reports as unsupported,
    and the wave says where it is planned. The constructor a built row names is
    the only producer of a provider value in this tree. *)
type build =
  | Adapter of (args -> Seekwright.Provider.t)
  | Deferred of string

(** What the readiness probe asks, or [No_probe] for the MCP-backed names
    ([exa], [exa:free], [parallel:free]) that the oracle proves with a session
    handshake instead — a [warmup] member this contract does not have yet, so on
    this port they answer {!Seekwright.Health.outcome} [Unsupported], like a name
    with no probe at all. The headers are {b not} part of this value: they come
    from the row's [credential], so a probe cannot authenticate in a shape its
    adapter does not. *)
type probe_source =
  | No_probe
  | Probe of (Seekwright.Config.t -> string option -> string option)

(** One name, as construction needs to know it. *)
type row = {
  name : Seekwright.Config.name;
  build : build;
  endpoint : endpoint_source;
  credential : credential;
  requires : prerequisite list;
  (** What must be present for this name to be built at all. *)
  default_cost : float option;
  (** [None] fixes the price at zero, config included — [exa:free] alone. A
      [Some] figure is the default a [[providers]] entry may correct. *)
  cost_model : cost_model;
  timeout_floor : float;
  (** The least time this name gets, whatever [policy.provider_timeout_seconds]
      says: a scrape, a metasearch fan-out, or an MCP handshake needs more than a
      cached SERP API. *)
  context : context_cap;
  probe : probe_source;
  settings : string list;
  (** The [[providers.<name>]] keys this name's adapter reads, besides [enabled]
      and [cost_per_1k], which the factory reads for every name. A key no row
      names and no module reads is a key that parses and does nothing — the
      failure mode plans/ocaml-finalisation.md F1.4 refuses — and a suite checks
      this field's union against the config's field list. *)
  ocaml_live_tested : bool;
  (** Whether this port has a recorded live run of this adapter. Never inherited
      from Python's live history, and no name is [true] on this branch yet: the
      live runner (F4.3) retires one in the change that records its run. *)
}

(** The seventeen rows, sorted by name — the same seventeen names
    {!Seekwright.Config.known_providers} freezes, and a suite pins the two sets
    against each other. *)
val rows : row list

(** The row for a name, if the inventory carries one. A name outside the frozen
    seventeen has none, and {!Seekwright.Config} cannot produce one. *)
val row : Seekwright.Config.name -> row option

(** {1 Reading a row} *)

val names : Seekwright.Config.name list
(** The row names, sorted. *)

val uri : row -> Seekwright.Config.provider_config -> (Uri.t, string) result
(** The one place a destination is computed: the module constant, the operator's
    override, or the derived host. [Error] is a config value that names no
    absolute http(s) URL, or one that carries credentials in its userinfo — a
    construction failure the operator sees, never a grant that silently allows
    nothing. *)

val grant_endpoint :
  row -> Seekwright.Config.provider_config -> (Mcp_caps.Policy.endpoint, string) result
(** {!uri} in the form [Policy.with_endpoints] takes: scheme, host, and an
    explicit port when the URI carries one, so an override that pins [:8443] pins
    that port in the grant too. *)

val timeout_seconds : row -> policy_seconds:float -> float
(** [max policy_seconds row.timeout_floor] — the oracle's merge, and the reason a
    raised policy timeout still gives [tavily] its normal budget while [exa] keeps
    its thirty seconds. *)

val price : row -> Seekwright.Config.provider_config -> float
(** What the name is built at: config wins, unless the row fixes the price. *)

val cost_of : row -> cost_per_1k:float -> int -> float
(** The per-query figure for a search that asks for [n] results: the row's
    [cost_model] applied to the price. This is the figure [--check --live] prints
    and the live runner (F4.3) reports; an adapter mirrors it in its own
    [cost_for], and the registry suite pins the two together for every adapter
    this build carries. *)

val key_for : row -> Seekwright.Config.t -> string option
(** The name's credential, environment-only, and only for a row that declares
    [Api_key]. A keyless name answers [None] even when its variable is set, which
    is what keeps [exa:free] anonymous while [exa] spends the key. *)

val missing_prerequisite :
  row -> Seekwright.Config.t -> Seekwright.Config.provider_config -> string option
(** Why this deployment cannot build this name, in one sentence naming every
    missing prerequisite, or [None] when all are present. A name whose row can
    build it is not an unsupported name: it is this deployment's incomplete
    configuration, and the two deserve different sentences. *)

val probe_spec : row -> Seekwright.Health.probe_spec
(** The probe row: the row's [probe] for the destination and its [credential] for
    the headers, so the probe asks the adapter's destination with the adapter's
    credential shape. [No_probe] gives {!Seekwright.Health.no_probe}. *)

val is_built : row -> bool
(** Whether this build carries the adapter, i.e. whether the row's [build] is
    [Adapter]. *)
