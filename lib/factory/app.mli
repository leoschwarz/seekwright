(** The application runtime context: everything the served process holds, built in the one order
    that refuses an unusable config before constructing anything around it. *)

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
  (Seekwright.Server.app * Providers_build.providers, string) result
(** Build the process-wide {!Seekwright.Server.app}: {!Factory.startup_verdict} first (an unusable
    config is refused before anything is constructed around it), then the usage recorder (a bad
    [dashboard.history_path] is a config problem and reads as one), the shared health board, the
    search engine over the built providers, the fetch engine when enabled, and the agent engine when
    enabled (its model endpoint gets its own endpoint-scoped grant over [[agent] base_url]). The
    {!Providers_build.providers} pass travels back with the app so the startup line can bind the
    names this build skipped, and so [/healthz] and the engines all read one built set. *)
