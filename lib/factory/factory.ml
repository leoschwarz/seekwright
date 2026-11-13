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
let grant_of_decision = Grants.grant_of_decision
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

let build_extractor config =
  match config.Config.fetch.Config.extractor with
  | "stdlib" ->
      Ok (Extractor.of_module (module Seekwright_fetch_stdlib.Stdlib))
  | name ->
      Error
        (Printf.sprintf "unknown fetch extractor %S; supported: %s" name
           (String.concat ", " (List.sort compare Config.known_extractors)))

let readers =
  {
    Engine.Fetch.Readers.parse_path =
      (fun selector ->
        try
          ignore (Jsondoc.parse_path selector);
          Ok ()
        with Jsondoc.Path_syntax message -> Error message);
    render_schema = Jsondoc.render_schema;
    select_paths = (fun ~text ~path ~max_chars -> Jsondoc.select_paths text path ~max_chars);
    select_passages =
      (fun ~text ~query ~max_chars -> Extractor.select_passages text query ~max_chars);
  }

let cap_of (cap : Engine.Fetch.cap) : int option =
  match cap with
  | Engine.Fetch.Default -> None
  | Engine.Fetch.Limit n -> Some n
  | Engine.Fetch.Uncapped -> Some Fetcher.uncapped

(* [error_of] is a translation, not a copy, and stays one: [Fetcher.refusal] and
   [Engine.Fetch.fetch_error] are different vocabularies on purpose — a
   [Blocked] becomes the engine's mid-flight refusal, a [Failed] becomes a
   provider error carrying the route's name. The page records beside them are the
   same type under both names ([Seekwright_wire.Page]), so the reader below hands
   the page straight over (style review M5). *)
let error_of (error : Fetcher.error) : Engine.Fetch.fetch_error =
  match error with
  | Fetcher.Refusal (Fetcher.Url_blocked message) -> Engine.Fetch.Url_blocked message
  | Fetcher.Refusal (Fetcher.Redirect_blocked message) ->
      Engine.Fetch.Redirect_blocked message
  | Fetcher.Refusal (Fetcher.Blocked message) -> Engine.Fetch.Fetch_blocked message
  | Fetcher.Failed message ->
      Engine.Fetch.Provider (Provider.provider_error ~provider:"http" message)

let build_fetch_stack ~sw ~net ~mono_clock ?audit config =
  let fetch = config.Config.fetch in
  if not fetch.Config.enabled then None
  else
    match build_extractor config with
    | Error message -> Some (Error message)
    | Ok extractor -> (
    match
      (* The local reader's grant, and the one place a config key decides a
         capability's address rule. [fetch.allow_private_addresses] picks the
         web variant the reader is built in — [with_private_web] when the
         operator approved intranet reads, [with_public_web] otherwise — rather
         than letting a per-request check widen an already-built grant. The
         third-party fallbacks below are not built this way and never will be:
         their grant is [grant_of_endpoint] over the vendor they dial, and the
         URL handed to them stays public-only whatever this key says, because
         the key says {i this server} may reach the intranet, not that an
         internal hostname may be posted to someone else's API. *)
      (if fetch.Config.allow_private_addresses then Policy.with_private_web else Policy.with_public_web)
        ~sw ~net ~port_policy:Policy.Any_port
        ~max_response_bytes:fetch.Config.max_download_bytes ()
    with
    | Error error -> Some (Error (Caps.Error.render error))
    | Ok decision -> (
        (* The extraction runner (F2.2): a fixed pool of worker domains so a
           slow parse costs its own core, not the loop's, and the parse gets a
           real deadline. The sockets live in the system temp dir — there is
           deliberately no config key for the directory: the sockets are
           [0600], process-scoped, and unlinked on close, so the temp dir is
           the answer everywhere this server runs. *)
        match
          Extract_pool.make ~net ~mono_clock
            ~dir:(Filename.get_temp_dir_name ())
            ~extractor ~max_body_bytes:fetch.Config.max_download_bytes ()
        with
        | Error message -> Some (Error message)
        | Ok workers ->
            let grant =
              grant_of_decision ~mono_clock
                ~timeout_seconds:fetch.Config.timeout_seconds ?audit decision
            in
            let fetcher =
              Fetcher.make ~net:grant ~extractor
                ~workers
                ~parse_timeout_seconds:fetch.Config.timeout_seconds
                ~max_download_bytes:fetch.Config.max_download_bytes
                ~max_text_chars:fetch.Config.max_text_chars
                ~max_redirects:fetch.Config.max_redirects
                ~allow_images:fetch.Config.allow_images
                ~user_agent:fetch.Config.user_agent
                ()
            in
            let local =
              {
                Engine.Fetch.name = "http";
                cost_per_1k = fetch.Config.cost_per_1k;
                fetch =
                  (fun ~url ~offset ~max_chars ->
                    match
                      (* Python bounds the whole redirect chain at twice the
                         per-request timeout (fetcher.py's asyncio.timeout); the
                         per-hop bound is the grant's, set above. *)
                      Fetcher.fetch
                        ~chain_timeout:
                          (Eio.Time.Timeout.seconds mono_clock
                             (2. *. fetch.Config.timeout_seconds))
                        fetcher url ~offset ~max_chars:(cap_of max_chars)
                    with
                    | Ok page -> Ok page
                    | Error error -> Error (error_of error));
                (* Closing the reader drains the pool: quit sentinels, then
                   join, so in-flight parses finish and their sockets go away
                   (extract_pool.mli, shutdown). *)
                aclose = (fun () -> Extract_pool.close workers);
              }
            in
            (* The keyed/self-hosted fallbacks are deferred with P6, so the
               ladder is empty in v1; a primary other than the local reader is
               refused by the server's startup checks rather than silently read
               locally. When they land they are built by [grant_of_endpoint],
               which has no way to ask for the private-web variant: the
               public-only rule for a third-party route is a property of how
               its grant is built. *)
            Some (Ok (local, []))))

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
