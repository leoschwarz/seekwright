(** The grant funnel: where confinement decisions become running grants and receive their audit
    sinks. *)

val audit_sink : Seekwright.Engine.log -> Mcp_caps.Event.t -> unit
(** The audit sink: the one [caps.operation] line per authority operation, with the field dictionary
    [test_caps_audit] pins. [Factory.audit_sink] is the public spelling of the same function. *)

val grant_of_decision :
  mono_clock:_ Eio.Time.Mono.t ->
  timeout_seconds:float ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Mcp_caps.Policy_net.t ->
  Mcp_caps.Authority.Net.t
(** [grant_of_decision ~mono_clock ~timeout_seconds ?audit decision] is the funnel:
    [Authority.Net.of_confinement] for the decision, bounded by the config's per-operation timeout,
    wrapped once in [Authority.with_log]. [?audit] is absent only on the [--check] diagnostic path,
    which probes a deployment without serving a request; [Factory.build_app] always supplies it. *)

val grant_of_endpoint :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  timeout_seconds:float ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Mcp_caps.Policy.endpoint ->
  (Mcp_caps.Authority.Net.t, string) result
(** One endpoint-scoped [Net] grant, wrapped once in [?audit], with its per-operation bound set from
    config. The public contract, including which config key bounds which route, is on
    [Factory.grant_of_endpoint] in [factory.mli]. *)

val probe_net :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  timeout_seconds:float ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Mcp_caps.Policy.endpoint list ->
  Seekwright.Provider.Net.t
(** The shared network seam for the readiness probes: one grant over the union of the given
    endpoints. The public contract is on [Factory.probe_net] in [factory.mli]. *)

val fs_grant_of_written_root :
  sw:Eio.Switch.t ->
  parent:_ Eio.Path.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  max_bytes:int ->
  max_entries:int ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  string ->
  (Mcp_caps.Authority.Fs.t, string) result
(** [fs_grant_of_written_root ~sw ~parent ~mono_clock ~max_bytes ~max_entries ?audit dir] is the
    same funnel for the one filesystem grant the server runs: [Policy.with_written_root] opens [dir]
    under [parent] — creating it, mode [0o700], when it is absent — with [max_bytes] as both the
    read and the write ceiling and [max_entries] the entry ceiling, and
    [Authority.Fs.of_confinement] turns that decision into the grant the page cache is built on. A
    directory this process cannot create or open is an [Error] naming the layer's reason, which is
    what [Factory.build_page_cache] reports as a startup failure.

    This is the library's only [Authority.Fs.of_confinement], for the same reason
    [grant_of_decision] is its only network one: a write path outside the funnel is a write path no
    audit line describes. *)
