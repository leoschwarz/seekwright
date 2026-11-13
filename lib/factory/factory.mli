(** Provider, extractor and fetcher construction from config and environment.

    Port of [src/seekwright/factory.py]. Kept out of the server module so the
    CLI diagnostic path ([--check], [--metrics]) can build providers — and
    report the extraction backend — without constructing the MCP server: the
    check path in [bin/main.ml] never calls [Server.registry] or a transport,
    and nothing here names mcp-kit at all, only the capability layer's grants.

    Each adapter is built with its own endpoint-scoped [Net] grant
    ([Policy.with_endpoints] over the adapter's single
    {!Mcp_caps.Policy.endpoint}), so a provider can dial only the vendor it
    was built for; [fetch]'s local reader gets a web grant — [Policy.with_public_web],
    or [Policy.with_private_web] when [fetch.allow_private_addresses] says the
    operator approved intranet reads. The grant sets are derived from enabled
    provider names — there is no second egress config key.

    {1 The audit trail}

    Every grant this module builds for the served process goes through one
    funnel, which sets the config's per-operation bound and wraps the grant in
    {!audit_sink} exactly once. One line per low-level operation therefore
    reaches the application's log: {!audit_sink} renders an {!Mcp_caps.Event.t}
    as the [caps.operation] event, and an [Event.t] cannot carry a URL, a query,
    a header, a body or a secret. A grant built without a sink is a diagnostic
    grant ([--check] probing a deployment), never a serving one.

    [Authority.with_operation_budget] is deliberately absent from this module.
    A budget is a caller's counter, and server construction has no caller scope
    to attach one to; see {!Mcp_caps.Budget}. *)

(** The audit sink: one [caps.operation] line per authority operation.

    Fields: [operation] (a constant name from the capability API), [outcome]
    ([ok] or [failed:<kind>]), [bytes] when the operation measured a payload, and
    one field per bounded note the operation attached ([status] for a network
    request, [entries] for a directory listing). A note whose key would collide
    with one of the three fixed fields is written under [note_<key>], so the
    line's shape never depends on what an operation happened to report.

    Exported so the field dictionary can be pinned without driving a socket;
    {!build_app} is what installs it, on every grant. *)
val audit_sink : Seekwright.Engine.log -> Mcp_caps.Event.t -> unit

(** What one pass of {!build_providers} produced. *)
type providers = {
  built : (Seekwright.Config.name * Seekwright.Provider.t) list;
  (** The adapters this deployment can dispatch, in config order. A name with
      no adapter in this build (the MCP-backed and keyed adapters deferred past
      P4) is absent — and is listed in [unsupported] rather than silently
      dropped; Python raises for a missing key and never skips. *)
  probe_table : (Seekwright.Config.name * Seekwright.Health.probe_spec) list;
  (** The [--check] probe rows for the built names, built from the adapters'
      own endpoint constants. *)
  endpoints : Mcp_caps.Policy.endpoint list;
  (** The union of the built adapters' endpoints: the allowlist one shared
      [--check] grant is built over. *)
  grant_errors : (Seekwright.Config.name * string) list;
  (** Names whose grant could not be constructed (a missing trust store, say).
      [--check] reports them as problems; {!build_app} refuses to start. *)
  unsupported : Seekwright.Config.name list;
  (** Enabled names this build has no adapter for, sorted. These are a
      startup failure under {!startup_verdict} — a served process must never
      hold a config name with no adapter behind it — and under an implicit
      keyless default they are the skipped keyless names, which the startup
      line names through [startup.providers_unsupported]. *)
}

(** {1 One routable set, and the configs that may serve it}

    Runtime routing — the engine's registry, its effective set, its default,
    its free walk and its fallback rungs — describes exactly the names this
    build constructed and the permission set permits. These two functions
    state which configurations may hold such a set: {!build_app} runs
    {!startup_verdict} before it builds an engine, and [--check] reads
    {!classify} for its provider section, so both paths report the same fact
    from one classification. *)

type set_report = {
  enabled : Seekwright.Config.name list;
  (** The names the config enables, sorted — what the file {i asks} for. *)
  effective : Seekwright.Config.name list;
  (** Enabled ∩ permitted — what the permission set {i allows}. *)
  built : Seekwright.Config.name list;
  (** The names this process can dispatch, sorted — what the build {i has}.
      Routing chooses only from this set. *)
  unsupported : Seekwright.Config.name list;
  (** Enabled with no adapter, from an explicitly enabled set: startup-fatal.
      Empty under an implicit keyless default, where the same fact is
      [skipped]. *)
  skipped : Seekwright.Config.name list;
  (** The implicit keyless defaults this build has no adapter for: skipped,
      logged by name at startup, and out of every routing set. *)
  untested : Seekwright.Config.name list;
  (** Enabled names with no live verification on {i this port}: the four
      Python itself calls untested, plus every name this build dispatches —
      an OCaml live run of the shipped provider set is what retires one. This is a disclosure, never a readiness verdict: a built, probed,
      reachable name is still untested until its own live run is recorded. *)
}

val classify : Seekwright.Config.t -> providers -> set_report
(** The five sets [--check] prints, from one config and one build pass. The
    categories partition {i nothing}: a name can be enabled, effective,
    untested and unsupported at once (Python's four untested names have no
    adapter here), and [classify] reports each fact once rather than
    collapsing them into one word. *)

val startup_verdict :
  Seekwright.Config.t -> providers -> (unit, string) result
(** Whether {!build_app} may construct an engine over this pair:

    - an explicitly enabled name with no adapter is refused, naming {i all}
      the offending names sorted with "not built on this port" — one row per
      offender would make an operator fix a config one restart at a time;
    - an implicit keyless default that leaves no keyless adapter built is
      refused too: the skipped-names disclosure is honest only while the
      built remainder can route;
    - a [default_provider] outside the built set is refused wherever it came
      from (config validation already refuses one outside [enabled]; the
      enabled⇒built step is this verdict's).

    A permitted-but-not-enabled name, and a fallback ladder naming an
    enabled name the implicit default skipped, keep the oracle's runtime
    sentences — a refusal, or an inert rung — because neither is a server
    holding a name it cannot dispatch. *)

val build_providers :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  now:(unit -> float) ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Seekwright.Config.t ->
  providers
(** Instantiate every enabled provider that has the credentials and the
    adapter this build carries.

    [?audit] is the sink each built adapter's grant is wrapped with; [build_app]
    supplies it, and [--check] does not, because a probe of a deployment is not a
    served request. *)

val grant_of_endpoint :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  timeout_seconds:float ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Mcp_caps.Policy.endpoint ->
  (Mcp_caps.Authority.Net.t, string) result
(** One endpoint-scoped [Net] grant, wrapped once in [?audit], with its
    per-operation bound set from config — [policy.provider_timeout_seconds] for a provider or a probe,
    [fetch.timeout_seconds] for the fetch grant, [agent.model_timeout_seconds]
    for the model request. Exposed so the timeout's behaviour can be pinned
    against a stalling loopback server. *)

val probe_net :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  timeout_seconds:float ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Mcp_caps.Policy.endpoint list ->
  Seekwright.Provider.Net.t
(** The shared network seam for the readiness probes: one grant over the union
    of the given endpoints, bounded by [timeout_seconds], wrapped once in
    [?audit]. An empty list answers
    [Unavailable] to every request rather than building a grant that allows
    nothing. [--check] and the serving path's health monitor both read it, so
    the two probes dial under the same policy. *)

val build_extractor : Seekwright.Config.t -> (Seekwright_fetch.Extractor.backend, string) result
(** Instantiate the extraction backend [[fetch] extractor] names. [stdlib] is
    the one this build carries; the name is validated at config load, so an
    unknown one here means a config built around validation. *)

val build_fetch_stack :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Seekwright.Config.t ->
  ((Seekwright.Engine.Fetch.fetcher * Seekwright.Engine.Fetch.fetcher list), string) result option
(** [None] when [[fetch] enabled = false]. Otherwise the local reader as the
    primary route plus the fallback ladder — empty in v1, where the third-party
    fallbacks are deferred with P6 — adapted to the engine's [fetcher] record.
    The local reader's grant is the web variant the config's
    [fetch.allow_private_addresses] names: [Policy.with_private_web] when the
    operator approved intranet reads, [Policy.with_public_web] otherwise. The
    keyed/self-hosted fallbacks are not built: nothing that could bill is left
    around unfired, and when they land their grants stay endpoint-scoped and
    public-only, because that key licenses this process, not a third party's
    view of the intranet.

    Extraction runs on an {!Seekwright_fetch.Extract_pool:}t — one pool per
    built stack, its workers fed through the system temp dir,
    [fetch.timeout_seconds] applied to the parse and twice that to the whole
    request, and the reader's [aclose] draining the pool
    (plans/ocaml-finalisation.md, F2.2). A pool that cannot be built refuses
    the stack rather than quietly extracting inline. *)

val readers : Seekwright.Engine.Fetch.Readers.t
(** The document readers the fetch engine selects with: [jsondoc]'s path
    grammar, schema rendering and path selection, and the shared passage
    selection. *)

val build_app :
  sw:Eio.Switch.t ->
  env:< net : [> [> `Generic ] Eio.Net.ty] Eio.Resource.t;
    fs : Eio.Fs.dir_ty Eio.Path.t;
    mono_clock : [> Eio.Time.Mono.ty] Eio.Resource.t;
    .. > ->
  now:(unit -> float) ->
  log:Seekwright.Engine.log ->
  allowed_hosts:string list ->
  Seekwright.Config.t ->
  (Seekwright.Server.app * providers, string) result
(** Build the process-wide {!Seekwright.Server.app}: {!startup_verdict} first
    (an unusable config is refused before anything is constructed around it),
    then the usage recorder (a bad [dashboard.history_path] is a config
    problem and reads as one), the shared health board, the search engine over
    the built providers, the fetch engine when enabled, and the agent engine
    when enabled (its model endpoint gets its own endpoint-scoped grant over
    [[agent] base_url]). The {!providers} pass travels back with the app so
    the startup line can bind the names this build skipped, and so [/healthz]
    and the engines all read one built set. *)
