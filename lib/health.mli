(** Provider health: a passive circuit breaker fed by real traffic, plus the probe
    that re-verifies a name without searching.

    Port of [src/seekwright/health.py]. Two signals land on one board: every
    dispatch records its outcome, and a provider that fails repeatedly is gated
    out of the {b default route's fallbacks} for a cooldown. The board gates
    ladder fallbacks only — the first attempt of any search, whether it is the
    resolved default or the name the caller gave, is never skipped: a breaker
    saves the second attempt, it does not pre-empt the first. {!Engine.Search}
    asks {!is_open} once per walk and passes the answer to {!Router.fallback_rungs},
    which is where the gate becomes a skip.

    Half-open is implicit: an expired gate reads closed, one more failure re-opens
    it without waiting for the threshold again, and any success closes it outright.

    {1 The clock}

    Python reads [asyncio.get_running_loop().time()] — monotonic per loop, so the
    plain attributes need no locks. This module has no loop to read, so the clock
    is {i injected} at {!create} and every comparison in here goes through it.
    That is what makes the state machine testable without sleeping: the suite
    moves the clock instead of waiting for it, and a cooldown that would otherwise
    be a race is an exact assertion. One fiber touches a board at a time, as in
    Python; {!t} is not shared across domains.

    {1 The log}

    The sink type is the one {!Usage} and {!Engine} take, so P8 hands the same
    function to all three. Two events, and each fires on the state {i change}:
    [health.open] with the provider, the reason and the failure count that opened
    the gate, and [health.closed] when an armed gate is cleared. Extending an
    already-open gate logs nothing, so a sustained outage says "open" once. *)

(** {1 The board} *)

type log = Log.log
(** The sink type is {!Log}'s, aliased here — style review M1. *)

type t
(** One board: per-name failure counts and open gates. *)

val create
  :  now:(unit -> float) ->
  ?failure_threshold:int ->
  ?cooldown_seconds:float ->
  ?log:log ->
  unit ->
  t
(** [create ~now ()] is the default board: {!default_failure_threshold} failures
    inside {!default_cooldown_seconds} opens a gate. [~now] is a monotonic clock
    in seconds; only its differences and its ordering matter. *)

val default_failure_threshold : int
(** [3], [search.health_failure_threshold]'s default. *)

val default_cooldown_seconds : float
(** [120.0], [search.health_cooldown_seconds]'s default. *)

val record_failure :
  t -> ?reason:string -> ?force_open:bool -> Config.name -> unit -> unit
(** Count one failure, opening the gate when the state machine says so.
    [~reason] is the failure's {i message}, never the exception, and it rides the
    [health.open] line only. [~force_open] is for failures that will not heal by
    accumulation — a probe that found the API key rejected — and opens from the
    first one. The state for an unknown name is created lazily, so recording a
    failure for a name no config mentioned is not an error. *)

val record_success : t -> ?reason:string -> Config.name -> unit -> unit
(** Reset the count and close the gate if one was armed. A name the board has
    never seen, or one with nothing armed, is a no-op that logs nothing. *)

val is_open : t -> Config.name -> bool
(** Whether [name]'s gate is up right now. Unknown names read closed. *)

val open_for_s : t -> Config.name -> float
(** Seconds left on [name]'s gate; the caller rounds for the log line. *)

(** {1 The probe} *)

type outcome =
  | Reachable
  | Reachable_no_key
  | Key_rejected
  | Key_required
  | Unreachable
  | Unsupported
(** What one bodyless GET concluded. [Unsupported] names a provider with no cheap
    probe, and [Key_required] the neighbouring case: the probe exists, but the
    key its endpoint always demands is absent, so there is nothing to ask. *)

val show_outcome : outcome -> string
(** The spelling [--check] prints and the [health.probe] line binds. *)

(** One name's probe shape: where the bodyless GET goes and what it carries. An
    endpoint builder that answers [None] says this deployment never named what
    that probe would need — [searxng]'s instance, [algolia]'s index — so the
    probe answers {!Unsupported} like a name with no probe at all. *)
type probe_spec = {
  endpoint : Config.t -> string option -> string option;
  headers : Config.t -> string option -> (string * string) list;
}

val no_probe : probe_spec
(** The row for a name with no cheap probe: no request, {!Unsupported}. The
    MCP-backed adapters are verified by their session handshake instead, which
    this port has no [warmup] member for yet. *)

val probe_endpoint_const : string -> Config.t -> string option -> string option
(** [probe_endpoint_const url] is the endpoint builder for a name whose probe asks
    the adapter's own endpoint: the name is ignored, because a module constant is
    the whole fact. *)

val probe_headers_const :
  ?prefix:string -> string -> Config.t -> string option -> (string * string) list
(** [probe_headers_const header] is the builder for a name whose key rides in
    [header]; [~prefix] is what the endpoint spells ahead of the key. No key, no
    header: the probe still goes out, since for an optional key a keyless GET is
    exactly what [--check] proves. *)

val searxng_endpoint : Config.t -> string option -> string option
(** The one endpoint that comes from config rather than a constant:
    [\[providers.searxng\] url] with the probe's own search path. No url, no probe. *)

val algolia_endpoint : Config.t -> string option -> string option
(** The malformed [hitsPerPage] is deliberate: a bodyless GET with valid
    parameters {i executes a search}, and every search request is billed against
    the monthly quota; a request rejected at parameter validation never runs one.
    A config that names no [app_id]/[index] addresses nothing, so it gets no probe. *)

val algolia_headers : Config.t -> string option -> (string * string) list
(** The application id is sent whenever the config names it, the key on top of it
    when the environment holds one. *)

val serpapi_endpoint : base:string -> Config.t -> string option -> string option
(** The key rides in the query string here — the operator's documented shape, not
    a header. [~base] is [serpapi.ENDPOINT], the adapter's constant: the caller
    that builds the row supplies the half that belongs to the adapter. *)

val probe :
  net:Provider.Net.t ->
  table:(Config.name * probe_spec) list ->
  Config.t ->
  Config.name ->
  outcome
(** One bodyless GET at [name]'s endpoint; every failure is an outcome, and it
    never raises.

    A name whose key is mandatory ([Config.providers_requiring_key]) is answered
    {!Key_required} {i before} the table is consulted, because [Reachable_no_key]
    is a readiness report and a provider that cannot be built keyless has none to
    report. A name with no row, or a row that cannot build a URL from this
    deployment's config, is {!Unsupported} without a request.

    {b The table is a parameter.} In Python it is a module-level dict keyed by
    name, built from each adapter's [ENDPOINT] constant. Those constants live with
    the adapters, and adapters live in [seekwright.providers], which depends on
    this library — so naming them from here would close a dependency cycle
    (plans/seekwright-ocaml-port.md, the P4 note). The caller that builds the
    adapters builds the rows; {!probe_endpoint_const}, {!probe_headers_const} and
    the four config-shaped builders above are the pieces it builds them from, and
    they are what the suite pins. *)

val probe_event : outcome -> bool
(** Whether the board moves for this outcome: [Reachable] and [Reachable_no_key]
    close, [Unreachable] counts a failure, [Key_rejected] opens at once, and
    [Unsupported] and [Key_required] touch the board not at all — neither is a
    provider the board could gate. *)

val run_probes :
  Config.t ->
  built:Config.name list ->
  table:(Config.name * probe_spec) list ->
  net:Provider.Net.t ->
  t ->
  unit
(** One tick of [HealthMonitor.run]: probe every enabled name this deployment
    built and feed the board by {!probe_event}. Python's loop sleeps
    [search.health_interval_seconds] and repeats; the sleep and the repeat belong
    to the server that owns the clock (P8), because this port has no loop to read
    a timer from. A name that is enabled but was not built — no key, no url — is
    skipped: there is no adapter to gate. [warmup] has no counterpart in this
    contract yet (the MCP-backed adapters are deferred), so a name is either
    probed or not built. *)
