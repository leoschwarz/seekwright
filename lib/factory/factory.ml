(* Construction from config and environment. Port of
   [src/seekwright/factory.py]; see [factory.mli] for the shape.

   A configured name with no adapter in this build is a construction-time
   fact, and it is acted on at construction: {!startup_verdict} refuses to
   start a server on an explicitly enabled name this port does not carry,
   naming every offender at once, because a running server holding such a
   config answers the named route with one refusal and the default route with
   a dispatch failure — and the honest choice is to refuse the half-configured
   deployment before it serves. The only exception is the implicit keyless
   default (no [providers] table at all), which may start over its built free
   remainder with the skipped names logged by name; when even that remainder
   is empty, it refuses too. [--check] reports the same facts through
   {!classify} without refusing anything, because a diagnosis of a deployment
   exits nowhere. Every routing decision then reads one built, permitted set,
   and the engine's runtime no-adapter branch is a guard, never a route. *)

module Caps = Mcp_caps
module Authority = Caps.Authority
module Policy = Caps.Policy
module Fetcher = Seekwright_fetch.Fetcher
module Extractor = Seekwright_fetch.Extractor
module Extract_pool = Seekwright_fetch.Extract_pool
module Jsondoc = Seekwright_fetch.Jsondoc
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Health = Seekwright.Health
module Provider = Seekwright.Provider
module Usage = Seekwright.Usage
module Agent = Seekwright.Agent
module Server = Seekwright.Server

let ( let* ) = Result.bind

type providers = Provider_set.providers = {
  built : (Config.name * Provider.t) list;
  probe_table : (Config.name * Health.probe_spec) list;
  endpoints : Policy.endpoint list;
  grant_errors : (Config.name * string) list;
  unsupported : Config.name list;
  warmups : (Config.name * (unit -> bool)) list;
}

let audit_sink = Grants.audit_sink
let grant_of_endpoint = Grants.grant_of_endpoint

let build_providers = Providers_build.build_providers

type set_report = Provider_set.set_report = {
  enabled : Config.name list;
  effective : Config.name list;
  built : Config.name list;
  unsupported : Config.name list;
  skipped : Config.name list;
  untested : Config.name list;
}

let classify = Verdict.classify
let startup_verdict = Verdict.startup_verdict

let probe_net = Grants.probe_net

let build_extractor = Fetch_stack.build_extractor
let readers = Fetch_stack.readers
let build_fetch_stack = Fetch_stack.build_fetch_stack

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
                match
                  Engine.Fetch.create config local ~readers ~usage ~log ~fallbacks
                    ~clock:mono_now ~now ()
                with
                | Ok engine -> Ok (Some engine)
                | Error message -> Error message)
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
