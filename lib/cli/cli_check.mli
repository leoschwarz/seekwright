(** The check report — the port of [src/seekwright/cli.py]'s [--check] path,
    with its inputs injected: the config, the environment the probes run on
    and an [emit] line callback, so the report can be driven from a test with
    no config file and its output read as a list. The module writes to no
    stream and calls no [exit]: [bin/main.ml] owns stdout and the status.

    The invariants this module owns, ported with the Python's:

    - it never builds the MCP server, a transport or a tool registry;
    - every offender row prints — a diagnosis never stops at the first one,
      and the problem count feeds the exit code so it carries the whole
      diagnosis;
    - the five-set distinction (enabled, effective, built, skipped,
      unsupported) is read from {!Factory.classify}, the same classification
      the server's startup verdict reads;
    - what the config asks for that this port does not run is named twice —
      beside the row it qualifies and in one aggregated list at the end. *)

val outcome_prose : Seekwright.Health.outcome -> string
(** [outcome_prose outcome] is a probe row's right-hand wording — the one
    [bin/main.ml] and the report share. *)

val default_route_line : Seekwright.Config.t -> string
(** [default_route_line config] names the default route, or says why there is
    none — the free-walk sentence and the must-name-a-provider sentence. *)

val transitional_features : Seekwright.Config.t -> (string * string) list
(** [transitional_features config] is one [(feature, detail)] row per feature
    the config asks for and this port has not built. Each feature names the
    phase that lands its consumer; a permanent entry here is the "parsed, not
    honoured" table the plan refuses. *)

val report_fetch :
  (string -> unit) -> Seekwright.Config.t -> int -> int
(** [report_fetch emit config problems] writes the fetch block and returns the
    problem count plus whatever this block found. *)

val report_agent :
  (string -> unit) -> Seekwright.Config.t -> int -> int
(** [report_agent emit config problems] writes the agent block. *)

val run :
  env:< net : [> [> `Generic ] Eio.Net.ty] Eio.Resource.t;
    mono_clock : [> Eio.Time.Mono.ty] Eio.Resource.t;
    .. > ->
  sw:Eio.Switch.t ->
  config:Seekwright.Config.t ->
  emit:(string -> unit) ->
  live:bool ->
  int
(** [run ~env ~config ~emit ~live] writes the whole report and returns the
    exit code. [live] asks for one real search per ready provider — the only
    path in this module that bills, and never one a test suite runs. *)
