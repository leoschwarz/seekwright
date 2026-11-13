(** The grant funnel: the one place [Seekwright_factory] turns a confinement
    decision into a grant that runs, and the audit trail that grant carries.

    Private to the library, and deliberately so: [Factory] re-exports
    {!audit_sink}, {!grant_of_endpoint} and {!probe_net} — the three a caller
    outside [Seekwright_factory] has a reason to name — and keeps
    {!grant_of_decision} here, where {!grant_of_endpoint} and {!probe_net} are
    its only two callers.

    The single-funnel property is what this module is for. [Authority.with_log]
    and [Authority.Net.of_confinement] each occur exactly once across
    [lib/factory], both in {!grant_of_decision}, and
    [test/test_caps_audit.ml] counts that total over the whole library rather
    than over one file — a per-file count would let a split hide one unaudited
    grant path per new module. [Authority.with_operation_budget] appears in this
    library only as prose refusing it; no grant this module builds carries a
    counter, because nothing in server construction has a caller's scope for one
    (plans/capability-gated-mcp-server.md §6). *)

(** The audit sink: the one [caps.operation] line per authority operation, with
    the field dictionary [test_caps_audit] pins. [Factory.audit_sink] is the
    public spelling of the same function. *)
val audit_sink : Seekwright.Engine.log -> Mcp_caps.Event.t -> unit

(** [grant_of_decision ~mono_clock ~timeout_seconds ?audit decision] is the
    funnel: [Authority.Net.of_confinement] for the decision, bounded by the
    config's per-operation timeout, wrapped once in [Authority.with_log].
    [?audit] is absent only on the [--check] diagnostic path, which probes a
    deployment without serving a request; [Factory.build_app] always supplies it. *)
val grant_of_decision :
  mono_clock:_ Eio.Time.Mono.t ->
  timeout_seconds:float ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Mcp_caps.Policy_net.t ->
  Mcp_caps.Authority.Net.t

(** One endpoint-scoped [Net] grant, wrapped once in [?audit], with its
    per-operation bound set from config. The public contract, including which
    config key bounds which route, is on [Factory.grant_of_endpoint] in
    [factory.mli]. *)
val grant_of_endpoint :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  timeout_seconds:float ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Mcp_caps.Policy.endpoint ->
  (Mcp_caps.Authority.Net.t, string) result

(** The shared network seam for the readiness probes: one grant over the union of
    the given endpoints. The public contract is on [Factory.probe_net] in
    [factory.mli]. *)
val probe_net :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  timeout_seconds:float ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Mcp_caps.Policy.endpoint list ->
  Seekwright.Provider.Net.t
