(** The check report with injected inputs (config, probe environment, and an
    [emit] line callback). Writes to no stream and calls no [exit]; returns
    problem counts and exit codes. *)

val outcome_prose : Seekwright.Health.outcome -> string

val default_route_line : Seekwright.Config.t -> string

val report_fetch :
  ?cache_stats:((int * int) option, string) result ->
  (string -> unit) -> Seekwright.Config.t -> int -> int
(** [report_fetch emit config problems] writes the fetch block and returns updated problem count.
    [?cache_stats]: [None] prints cap/ttl without live counts; [Error] increments problems. *)

val report_agent :
  (string -> unit) -> Seekwright.Config.t -> int -> int

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
(** [run ~env ~sw ~config ~emit ~live] writes the report and returns the exit
    code (0 on success, 1 on problems). [live:true] executes billable searches
    against ready providers. *)
