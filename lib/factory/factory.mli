(** Provider, extractor and fetcher construction from config and environment.

    Each adapter is built with its own endpoint-scoped [Net] grant ([Policy.with_endpoints] over the
    adapter's single {!Mcp_caps.Policy.endpoint}), so a provider can dial only the vendor it was
    built for; [fetch]'s local reader gets a web grant — [Policy.with_public_web], or
    [Policy.with_private_web] when [fetch.allow_private_addresses] says the operator approved
    intranet reads.

    Every grant built for the served process goes through one funnel, which sets the config's
    per-operation bound and wraps the grant in {!audit_sink} exactly once. A grant built without a
    sink is a diagnostic grant ([--check] probing a deployment), never a serving one.

    The construction half of this surface is [Providers_build], [Verdict], [Fetch_stack] and [App]
    included, not re-typed: a name's type and contract live once, in the interface of the module
    that owns it, and this signature states only which of those modules a caller may name through
    [Factory]. The grant half is the exception — [Grants]'s funnel functions are deliberately absent
    (see its own interface), so the three grant names this layer does export are spelled here. *)

include module type of Providers_build
include module type of Verdict
include module type of Fetch_stack
include module type of App

val audit_sink : Seekwright.Engine.log -> Mcp_caps.Event.t -> unit
(** The audit sink: one [caps.operation] line per authority operation.

    Fields: [operation] (a constant name from the capability API), [outcome] ([ok] or
    [failed:<kind>]), [bytes] when the operation measured a payload, and one field per bounded note
    the operation attached ([status] for a network request, [entries] for a directory listing). A
    note whose key would collide with one of the three fixed fields is written under [note_<key>],
    so the line's shape never depends on what an operation happened to report.

    Exported so the field dictionary can be pinned without driving a socket; {!App.build_app} is
    what installs it, on every grant. *)

val grant_of_endpoint :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  timeout_seconds:float ->
  ?max_response_bytes:int ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Mcp_caps.Policy.endpoint ->
  (Mcp_caps.Authority.Net.t, string) result
(** One endpoint-scoped [Net] grant, wrapped once in [?audit], with its per-operation bound set from
    config — [policy.provider_timeout_seconds] for a provider or a probe, [fetch.timeout_seconds]
    for the fetch grant, [agent.model_timeout_seconds] for the model request, and no configured key
    at all for the CLI verb that dials its own server, which reads no config and so names a bound
    above what a served call can take rather than borrowing one that would cut it short.
    [?max_response_bytes] defaults to [Policy.default_max_response_bytes]; the CLI dial is the one
    consumer that raises it, to [Policy.max_configurable_response_bytes], because the response it
    reads is this server's own REST projection and its size belongs to [fetch] config the client
    does not load. Exposed so the timeout's behaviour can be pinned against a stalling loopback
    server. *)

val probe_net :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  timeout_seconds:float ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Mcp_caps.Policy.endpoint list ->
  Seekwright.Provider.Net.t
(** The shared network seam for the readiness probes: one grant over the union of the given
    endpoints, bounded by [timeout_seconds], wrapped once in [?audit]. An empty list answers
    [Unavailable] to every request rather than building a grant that allows nothing. [--check] and
    the serving path's health monitor both read it, so the two probes dial under the same policy. *)
