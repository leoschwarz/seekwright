(** Provider, extractor and fetcher construction from config and environment.

    Port of [src/seekwright/factory.py]. Kept out of the server module so the
    CLI diagnostic path ([--check], [--metrics]) can build providers — and
    report the extraction backend — without constructing the MCP server: the
    check path in [bin/main.ml] never calls [Server.registry] or a transport,
    and nothing here names mcp-kit at all, only the capability layer's grants.

    Each adapter is built with its own endpoint-scoped [Net] grant
    ([Policy.with_endpoints] over the adapter's single
    {!Mcp_caps.Policy.endpoint}), so a provider can dial only the vendor it
    was built for; [fetch]'s local reader gets the public-web grant
    ([Policy.with_public_web]). The grant sets are derived from enabled
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
  (** Enabled names this build has no adapter for, in config order. The startup
      line binds them and emits [startup.providers_unsupported], so the silence
      that used to make a config name look served is gone. *)
}

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
    primary route (behind the public-web grant) plus the fallback ladder —
    empty in v1, where the third-party fallbacks are deferred with P6 — adapted
    to the engine's [fetcher] record. The keyed/self-hosted fallbacks are not
    built: nothing that could bill is left around unfired. *)

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
(** Build the process-wide {!Seekwright.Server.app}: the usage recorder (a bad
    [dashboard.history_path] is a config problem and reads as one), the shared
    health board, the search engine over the built providers, the fetch engine
    when enabled, and the agent engine when enabled (its model endpoint gets
    its own endpoint-scoped grant over [[agent] base_url]). The {!providers}
    pass travels back with the app so the startup line can bind the names this
    build could not dispatch. *)
