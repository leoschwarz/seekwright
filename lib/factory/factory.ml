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
module Jsondoc = Seekwright_fetch.Jsondoc
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Health = Seekwright.Health
module Provider = Seekwright.Provider
module Usage = Seekwright.Usage
module Agent = Seekwright.Agent
module Server = Seekwright.Server
module Freeserp = Seekwright_providers.Freeserp
module Anysearch = Seekwright_providers.Anysearch

let ( let* ) = Result.bind

type providers = {
  built : (Config.name * Provider.t) list;
  probe_table : (Config.name * Health.probe_spec) list;
  endpoints : Policy.endpoint list;
  grant_errors : (Config.name * string) list;
  unsupported : Config.name list;
}

(* {1 The audit trail} *)

(* The field names the audit line owns. A note from an operation is written under
   its own key, except when that key would collide with one of these — the fixed
   fields are what the line's shape is pinned on, so a note never replaces one.
   [Event.add_note] already sanitises both halves and caps the list, so the line's
   length comes from the layer's field set, not from what a provider sent. *)
let reserved_audit_fields = [ "operation"; "outcome"; "bytes" ]

let audit_fields (event : Caps.Event.t) : (string * Yojson.Safe.t) list =
  let note (key, value) =
    let key =
      if List.mem key reserved_audit_fields then "note_" ^ key else key
    in
    (key, `String value)
  in
  ("operation", `String (Caps.Event.operation event))
  :: ("outcome", `String (Caps.Event.outcome_to_string (Caps.Event.outcome event)))
  :: (match Caps.Event.bytes event with
      | None -> []
      | Some bytes -> [ ("bytes", `Int bytes) ])
  @ List.map note (Caps.Event.notes event)

(* One line per authority operation, through the application's sink: stderr, never
   stdout, and a constant dotted event name with every value a named field, which
   is the rule the rest of the log follows. [Event.t] cannot carry a URL, a query,
   a header or a body — its payload is an operation name, an outcome, a byte count
   and bounded notes — so this is the whole of what a deployment learns about a
   grant's work, and it is what makes "which tool reached the network, and did it
   succeed" answerable from the log without a page in it. *)
let audit_sink (log : Engine.log) (event : Caps.Event.t) : unit =
  log Config.Log_info "caps.operation" (audit_fields event)

(* The one place this file turns a confinement decision into a serving grant: the
   config's per-operation bound, and exactly one audit sink. Every grant the server
   runs on is built here, so [of_confinement] and [with_log] each appear once in
   this file — a grant that forgets the audit trail is a compile error in review,
   not a forgotten line, and [test/test_caps_audit.ml] pins the count.

   [?audit] is absent only for the [--check] diagnostic path, which probes a
   deployment without serving a request; [build_app] always supplies it. *)
let grant_of_decision ~mono_clock ~timeout_seconds ?audit decision =
  let sink = Option.value ~default:(fun (_ : Caps.Event.t) -> ()) audit in
  Authority.with_log ~sink
    (Authority.with_operation_timeout
       (Eio.Time.Timeout.seconds mono_clock timeout_seconds)
       (Authority.Net.of_confinement ~mono_clock decision))

(* One endpoint-scoped grant per adapter: the only network path a provider
   has. The operation bound is the config's, not the capability layer's
   default: [policy.provider_timeout_seconds] bounds a provider call,
   [fetch.timeout_seconds] a fetch, and [agent.model_timeout_seconds] the model
   request — the three keys Python feeds its clients.

   No [Authority.with_operation_budget] here, on purpose: a counter attached at
   startup is a server-lifetime budget wearing a request's name, which
   plans/capability-gated-mcp-server.md §6 refuses. A budget belongs to a caller
   that has a scope, and nothing in server construction has one. *)
let grant_of_endpoint ~sw ~net ~mono_clock ~timeout_seconds ?audit
    (endpoint : Policy.endpoint) =
  match
    Policy.with_endpoints ~sw ~net
      ~max_response_bytes:Policy.default_max_response_bytes
      [ endpoint ]
  with
  | Ok decision ->
      Ok (grant_of_decision ~mono_clock ~timeout_seconds ?audit decision)
  | Error error -> Error (Caps.Error.render error)

let keyless_headers _config _key = []

(* The adapters this build carries, keyed by config name. A name absent here
   is not built; its probe row is absent too, so [--check] reports it
   unsupported rather than probing an endpoint nothing will serve. *)
type adapter = {
  make : net:Provider.Net.t -> now:(unit -> float) -> cost_per_1k:float -> snippet_chars:int -> Provider.t;
  endpoint : Policy.endpoint;
  probe_url : string;
}

let adapters : (Config.name * adapter) list =
  [
    ( "freeserp",
      {
        make =
          (fun ~net ~now ~cost_per_1k ~snippet_chars ->
            Freeserp.make ~cost_per_1k ~snippet_chars ~now ~net ());
        endpoint = Freeserp.policy_endpoint;
        probe_url = Uri.to_string Freeserp.endpoint ^ "?index=web&q=probe";
      } );
    ( "anysearch",
      {
        make =
          (fun ~net ~now:_ ~cost_per_1k ~snippet_chars ->
            Anysearch.make ~cost_per_1k ~snippet_chars ~net ());
        endpoint = Anysearch.policy_endpoint;
        probe_url = Uri.to_string Anysearch.endpoint;
      } );
  ]

let cost_of (pc : Config.provider_config) = Option.value ~default:0.0 pc.Config.cost_per_1k

let build_providers ~sw ~net ~mono_clock ~now ?audit config =
  let snippet_chars = config.Config.policy.Config.max_snippet_chars in
  let rec go built table endpoints errors unsupported = function
    | [] ->
        {
          built = List.rev built;
          probe_table = List.rev table;
          endpoints = List.rev endpoints;
          grant_errors = List.rev errors;
          (* Sorted, because the startup refusal and [--check] both list these
             names and an operator scanning two renderings of the same set
             should read the same order. *)
          unsupported = List.sort String.compare (List.rev unsupported);
        }
    | (name, pc0) :: rest ->
        let (pc : Config.provider_config) = pc0 in
        if not pc.Config.enabled then go built table endpoints errors unsupported rest
        else
          match List.assoc_opt name adapters with
          | None -> go built table endpoints errors (name :: unsupported) rest
          | Some adapter -> (
              match
                grant_of_endpoint ~sw ~net ~mono_clock
                  ~timeout_seconds:config.Config.policy.Config.provider_timeout_seconds
                  ?audit adapter.endpoint
              with
              | Error message ->
                  go built table endpoints ((name, message) :: errors) unsupported rest
              | Ok grant ->
                  let net = Provider.Net.of_grant grant in
                  let provider =
                    adapter.make ~net ~now ~cost_per_1k:(cost_of pc) ~snippet_chars
                  in
                  let row =
                    ( name,
                      {
                        Health.endpoint = Health.probe_endpoint_const adapter.probe_url;
                        headers = keyless_headers;
                      } )
                  in
                  go
                    ((name, provider) :: built)
                    (row :: table)
                    (adapter.endpoint :: endpoints)
                    errors unsupported rest)
  in
  go [] [] [] [] [] config.Config.providers

(* {1 One routable set, and the configs that may serve it} *)

type set_report = {
  enabled : Config.name list;
  effective : Config.name list;
  built : Config.name list;
  unsupported : Config.name list;
  skipped : Config.name list;
  untested : Config.name list;
}

let classify config (built : providers) =
  let built_names = List.sort String.compare (List.map fst built.built) in
  let missing = built.unsupported in
  (* OCaml-untested is a property of this port, not of Python's live history:
     [Config.untested_providers] are the names Python itself has never run
     live, and {i every} name this build dispatches joins them until the OCaml
     live runner records its own passing run. A probe ([--check], the
     health monitor) is a reachability check, not a live run — that is why
     this set is printed beside the ready count and never folded into it. *)
  let untested_pool = Config.untested_providers @ built_names in
  {
    enabled = Config.enabled_providers config;
    effective = Config.effective_providers config;
    built = built_names;
    (* The same fact, split by how the config came to hold it: an explicit
       [providers] table naming an unbuilt name is the operator's mistake and
       startup refuses it; the implicit keyless default naming one is the
       port's transition and startup logs it. *)
    unsupported = (if config.Config.providers_defaulted then [] else missing);
    skipped = (if config.Config.providers_defaulted then missing else []);
    untested =
      List.filter (fun name -> List.mem name untested_pool) (Config.enabled_providers config);
  }

let built_phrase sets =
  if sets.built = [] then "none" else String.concat ", " sets.built

let startup_verdict config (built : providers) =
  let sets = classify config built in
  match sets.unsupported with
  | [] ->
      if config.Config.providers_defaulted && sets.built = [] then
        (* The transition exception to the rule stops applying when applying
           it would serve nothing: an unconfigured install must fail with the
           names that are missing, not boot into an engine that refuses every
           search. *)
        Error
          (Printf.sprintf
             "no keyless provider is built on this port: the implicit default \
              (%s) is not built on this port, and this build has nothing to \
              route an unconfigured install through"
             (String.concat ", " sets.skipped))
      else (
        match config.Config.default_provider with
        | Some name when not (List.mem name sets.built) ->
            (* Config validation already refuses a default outside [enabled];
               this is the enabled⇒built step that keeps [resolve_search]'s
               default arm and the engine registry describing one set, whatever
               pair reached this point. *)
            Error
              (Printf.sprintf "default provider '%s' is not built on this port \
                               (this build can dispatch: %s)"
                 name (built_phrase sets))
        | _ -> Ok ())
  | names ->
      (* Every offender in one line, sorted: a config missing three names
         should take one restart to fix, and the list has to read the same
         here as it does in [--check]. *)
      Error
        (Printf.sprintf "the enabled providers %s are not built on this port \
                         (this build can dispatch: %s); remove them from the \
                         [providers] table or see `seekwright --check`"
           (String.concat ", " names) (built_phrase sets))

(* The network seam the readiness probes share: one grant over the union of the
   built vendors' endpoints. With no endpoint there is nothing to allow, so
   every request answers [Unavailable] instead of building an empty grant. *)
let probe_net ~sw ~net ~mono_clock ~timeout_seconds ?audit endpoints =
  match endpoints with
  | [] ->
      {
        Provider.Net.request =
          (fun _request ->
            Error
              (Caps.Error.make Caps.Error.Unavailable
                 ~message:"no endpoints configured"));
      }
  | endpoints -> (
      match
        Policy.with_endpoints ~sw ~net
          ~max_response_bytes:Policy.default_max_response_bytes endpoints
      with
      | Ok decision ->
          Provider.Net.of_grant
            (grant_of_decision ~mono_clock ~timeout_seconds ?audit decision)
      | Error _ ->
          {
            Provider.Net.request =
              (fun _request ->
                Error
                  (Caps.Error.make Caps.Error.Unavailable
                     ~message:"no endpoints configured"));
          })

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
    | Ok decision ->
        let grant =
          grant_of_decision ~mono_clock ~timeout_seconds:fetch.Config.timeout_seconds
            ?audit decision
        in
        let fetcher =
          Fetcher.make ~net:grant ~extractor
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
            aclose = (fun () -> ());
          }
        in
        (* The keyed/self-hosted fallbacks are deferred with P6, so the ladder
           is empty in v1; a primary other than the local reader is refused by
           the server's startup checks rather than silently read locally. When
           they land they are built by [grant_of_endpoint], which has no way to
           ask for the private-web variant: the public-only rule for a
           third-party route is a property of how its grant is built. *)
        Some (Ok (local, [])))

let agent_net ~sw ~net ~mono_clock ?audit config =
  match config.Config.agent.Config.base_url with
  | None -> Error "agent mode is enabled but [agent] base_url is unset"
  | Some url -> (
      let uri = Uri.of_string url in
      let scheme =
        match Uri.scheme uri with Some "https" -> `Https | _ -> `Http
      in
      let host = Option.value ~default:"" (Uri.host uri) in
      let endpoint = { Policy.scheme; host; port = Uri.port uri } in
      grant_of_endpoint ~sw ~net ~mono_clock
        ~timeout_seconds:config.Config.agent.Config.model_timeout_seconds
        ?audit endpoint)

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
        build_providers ~sw ~net:(env#net) ~mono_clock ~now ~audit config
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
