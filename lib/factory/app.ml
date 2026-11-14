(* The process build: everything a served process holds, in the order it has to
   be built. Port of [src/seekwright/factory.py]'s build_app.

   The order is the contract. [startup_verdict] runs before a single engine
   exists, because an engine over a config this build cannot route is exactly
   what the verdict refuses; the usage recorder comes first because a bad
   [dashboard.history_path] is a config problem and reads as one; and every
   grant the served process runs on carries the audit sink installed here, once,
   through [Grants.grant_of_decision]. This is the only module in the library
   that constructs an engine, and the [--check] path never reaches it. *)

module Agent = Seekwright.Agent
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Health = Seekwright.Health
module Provider = Seekwright.Provider
module Server = Seekwright.Server
module Usage = Seekwright.Usage

let ( let* ) = Result.bind

(* The builders this pass drives, each named where it lives. None of them can
   construct a grant: the funnel is [Grants]', and what reaches here is already
   wrapped. *)
let audit_sink = Grants.audit_sink
let grant_of_endpoint = Grants.grant_of_endpoint
let probe_net = Grants.probe_net
let build_providers = Providers_build.build_providers
let build_fetch_stack = Fetch_stack.build_fetch_stack
let build_page_cache = Fetch_stack.build_page_cache
let readers = Fetch_stack.readers
let startup_verdict = Verdict.startup_verdict


let agent_net ~sw ~net ~mono_clock ?audit config =
  match config.Config.agent.Config.base_url with
  | None -> Error "agent mode is enabled but [agent] base_url is unset"
  | Some url -> (
      (* The same URI-to-grant-entry derivation the adapters use
         ([Seekwright.Provider.policy_of_uri]): [agent] is not a provider, but a
         second spelling of "scheme, host, port" is how two endpoints start to
         disagree. *)
      let endpoint = Provider.policy_of_uri (Uri.of_string url) in
      grant_of_endpoint ~sw ~net ~mono_clock
        ~timeout_seconds:config.Config.agent.Config.model_timeout_seconds ?audit endpoint)

let build_app ~sw
    ~(env : < net : [> [> `Generic ] Eio.Net.ty] Eio.Resource.t;
    fs : Eio.Fs.dir_ty Eio.Path.t;
    mono_clock : [> Eio.Time.Mono.ty] Eio.Resource.t;
    .. >)
    ~now ~log ~allowed_hosts config =
  let mono_clock = Eio.Stdenv.mono_clock env in
  let mono_now () = Int64.to_float (Mtime.to_uint64_ns (Eio.Time.Mono.now mono_clock)) /. 1e9 in
  let history_path =
    match config.Config.dashboard.Config.history_path with
    | None -> None
    | Some path -> Some Eio.Path.(env#fs / path)
  in
  match Usage.create ~now ?history_path ~log () with
  | Error message -> Error message
  | Ok usage -> (
      (* Every grant the served process runs on is wrapped with this sink, once,
         through [grant_of_decision]. The health monitor's probes are operations
         too: they reach the network on the server's switch, so they are audited
         like a request is. *)
      let audit = audit_sink log in
      let built =
        build_providers ~sw ~net:(env#net) ~mono_clock ~now ~audit ~log config
      in
      match built.grant_errors with
      | (name, message) :: _ ->
          Error (Printf.sprintf "provider %s: %s" name message)
      | [] ->
          (* The config is refused here, before a single engine exists to
             serve it: an engine over this pair of values is exactly what the
             verdict says may not run. *)
          let* () = startup_verdict config built in
          let board =
            Health.create ~now:mono_now
              ~failure_threshold:config.Config.search.Config.health_failure_threshold
              ~cooldown_seconds:config.Config.search.Config.health_cooldown_seconds
              ~log ()
          in
          let search =
            Engine.Search.create config ~health:board ~usage ~log built.built
              ~clock:mono_now ~now ()
          in
          let* fetch =
            match build_fetch_stack ~sw ~net:(env#net) ~mono_clock ~audit config with
            | None -> Ok None
            | Some (Error message) -> Error message
            | Some (Ok (local, fallbacks)) -> (
                (* The page cache is wired here rather than inside
                   [build_fetch_stack] because it is the engine's seam, not one of
                   the fetch routes: [fetch.cache_dir] unset leaves [cache] absent
                   and every read dispatching, and a [cache_dir] this process
                   cannot create or open refuses the start. *)
                match
                  build_page_cache ~sw ~net:(env#net) ~mono_clock ~now ~audit ~fs:(env#fs) config
                with
                | Error message -> Error message
                | Ok cache -> (
                    match
                      Engine.Fetch.create config local ~readers ?cache ~usage ~log ~fallbacks
                        ~clock:mono_now ~now ()
                    with
                    | Ok engine -> Ok (Some engine)
                    | Error message -> Error message))
          in
          let* agent =
            if not config.Config.agent.Config.enabled then Ok None
            else
              match agent_net ~sw ~net:(env#net) ~mono_clock ~audit config with
              | Error message -> Error message
              | Ok net ->
                  Ok
                    (Some
                       (Agent.create config ~net:(Provider.Net.of_grant net) search
                          ?fetch_engine:fetch ~usage ~log ~clock:mono_now ~now ()))
          in
          Ok
            ( {
                Server.config;
                search;
                usage;
                fetch;
                agent;
                started_at = mono_now ();
                mono_now;
                allowed_hosts;
                health =
                  Some
                    {
                      Server.board;
                      built = List.map fst built.probe_table;
                      probes = built.probe_table;
                      net =
                        probe_net ~sw ~net:(env#net) ~mono_clock ~audit
                          ~timeout_seconds:
                            config.Config.policy.Config.provider_timeout_seconds
                          built.endpoints;
                    };
              },
              built ))
