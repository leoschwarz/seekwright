(** The process build: the app a served process runs on, in the order its parts
    have to exist.

    Private to [Seekwright_factory]: [Factory] re-exports {!build_app} and
    nothing else here. This is the only module in the library that can construct
    an engine — which is why the CLI diagnostic path ([--check], [--metrics])
    never names it: a diagnosis builds providers, an extractor and probe grants,
    and never a server around them. *)

(** Build the process-wide app: the verdict, the usage recorder, the providers,
    the health board, the search engine, the fetch engine and the agent engine,
    in that order. The full contract — including what is refused and what travels
    back with the app — is on [Factory.build_app] in [factory.mli]. *)
val build_app :
  sw:Eio.Switch.t ->
  env:< net : [> [> `Generic ] Eio.Net.ty] Eio.Resource.t;
    fs : Eio.Fs.dir_ty Eio.Path.t;
    mono_clock : [> Eio.Time.Mono.ty] Eio.Resource.t;
    .. > ->
  now:(unit -> float) ->
  log:Seekwright.Engine.log ->
  allowed_hosts:string list ->
  Seekwright.Config.t ->
  (Seekwright.Server.app * Provider_set.providers, string) result
