(** HTTP serving loop shutdown and signal management. Handles SIGINT/SIGTERM, drains connections,
    and closes providers in order. *)

val run_http :
  env:< net : _ Eio.Net.t ; fs : _ Eio.Path.t ; mono_clock : _ Eio.Time.Mono.t ; .. > ->
  sw:Eio.Switch.t ->
  log:Seekwright.Log.log ->
  app:Seekwright.Server.app ->
  server:Mcp_kit.Server.t ->
  host:string ->
  port:int ->
  close:(unit -> unit) ->
  ?grace_seconds:float ->
  ?stop:unit Eio.Promise.t ->
  unit ->
  (Seekwright.Server.lifecycle, Seekwright.Server.serve_error) result
(** [run_http] serves HTTP until stopped, draining connections and calling [close] once on exit.
    Installs SIGINT/SIGTERM handlers unless [?stop] is provided. Re-raises fiber cancellation;
    [Error] carries only listener startup failures. *)
