(** Constructs the application runtime context ([Server.app]) and providers. *)

val build_app :
  sw:Eio.Switch.t ->
  env:
    < net : [> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    ; fs : Eio.Fs.dir_ty Eio.Path.t
    ; mono_clock : [> Eio.Time.Mono.ty ] Eio.Resource.t
    ; .. > ->
  now:(unit -> float) ->
  log:Seekwright.Engine.log ->
  allowed_hosts:string list ->
  Seekwright.Config.t ->
  (Seekwright.Server.app * Provider_set.providers, string) result
(** [build_app ~sw ~env ~now ~log ~allowed_hosts config] builds runtime components: usage recorder,
    provider set, health board, search engine, fetch engine, and agent engine. Returns [Error msg]
    on startup refusal. *)
