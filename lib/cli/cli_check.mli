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
    - a configured fetch route answers with what this build made of it — built
      and how it pays, or [(inactive: …)] naming the prerequisite that is
      missing — and only an unbuilt {!report_fetch} primary counts as a problem,
      because that is the one the server refuses to start on;
    - a built name whose probe this port does not implement is neither counted
      ready nor counted as a problem: the summary names those rows as a gap in
      the diagnosis, and "no providers ready" stays unprinted unless a build or
      a probe actually failed — a hole in what this binary can check is not a
      fault in the deployment. *)

val outcome_prose : Seekwright.Health.outcome -> string
(** [outcome_prose outcome] is a probe row's right-hand wording — the one
    [bin/main.ml] and the report share. *)

val default_route_line : Seekwright.Config.t -> string
(** [default_route_line config] names the default route, or says why there is
    none — the free-walk sentence and the must-name-a-provider sentence. *)

val report_fetch :
  ?cache_stats:((int * int) option, string) result ->
  (string -> unit) -> Seekwright.Config.t -> int -> int
(** [report_fetch emit config problems] writes the fetch block and returns the
    problem count plus whatever this block found.

    [?cache_stats] is the measured half of the cache row: [Factory.page_cache_stats]
    read over the directory [fetch.cache_dir] names, so the row can say how many
    entries and how many body bytes are actually there. An absent argument means
    not measured, which the row prints as the cap and ttl with no figures beside
    them; an [Error] means the directory could not be opened, which is a problem
    because the server refuses to start on such a config. *)

val report_agent :
  (string -> unit) -> Seekwright.Config.t -> int -> int
(** [report_agent emit config problems] writes the agent block. *)

val run :
  env:< net : [> [> `Generic ] Eio.Net.ty] Eio.Resource.t;
    fs : Eio.Fs.dir_ty Eio.Path.t;
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
