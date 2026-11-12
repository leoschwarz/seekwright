(* Construction from config and environment. Port of
   [src/seekwright/factory.py]; see [factory.mli] for the shape.

   Only the two keyless HTTP adapters this build carries (P4) are built here.
   The other fifteen names have no adapter yet, so they are skipped and
   disclosed: [build_providers] returns them as [unsupported], and the startup
   line binds that list so an operator reads which names this build cannot
   dispatch. That is deliberately *not* Python's behaviour — Python raises on an
   enabled provider without a key and never skips — so the port says the
   absence out loud instead of leaving a config name looking served. Each built
   adapter gets its own endpoint-scoped grant, so the provider can dial only its
   own vendor. *)

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

(* One endpoint-scoped grant per adapter: the only network path a provider
   has. The operation bound is the config's, not the capability layer's
   default: [policy.provider_timeout_seconds] bounds a provider call,
   [fetch.timeout_seconds] a fetch, and [agent.model_timeout_seconds] the model
   request — the three keys Python feeds its clients. *)
let grant_of_endpoint ~sw ~net ~mono_clock ~timeout_seconds
    (endpoint : Policy.endpoint) =
  match
    Policy.with_endpoints ~sw ~net
      ~max_response_bytes:Policy.default_max_response_bytes
      [ endpoint ]
  with
  | Ok decision ->
      let grant = Authority.Net.of_confinement ~mono_clock decision in
      Ok
        (Authority.with_operation_timeout
           (Eio.Time.Timeout.seconds mono_clock timeout_seconds)
           grant)
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

let build_providers ~sw ~net ~mono_clock ~now config =
  let snippet_chars = config.Config.policy.Config.max_snippet_chars in
  let rec go built table endpoints errors unsupported = function
    | [] ->
        {
          built = List.rev built;
          probe_table = List.rev table;
          endpoints = List.rev endpoints;
          grant_errors = List.rev errors;
          unsupported = List.rev unsupported;
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
                  adapter.endpoint
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

(* The network seam the readiness probes share: one grant over the union of the
   built vendors' endpoints. With no endpoint there is nothing to allow, so
   every request answers [Unavailable] instead of building an empty grant. *)
let probe_net ~sw ~net ~mono_clock ~timeout_seconds endpoints =
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
          let grant = Authority.Net.of_confinement ~mono_clock decision in
          Provider.Net.of_grant
            (Authority.with_operation_timeout
               (Eio.Time.Timeout.seconds mono_clock timeout_seconds)
               grant)
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

let page_of (page : Fetcher.fetched_page) : Engine.Fetch.page =
  {
    Engine.Fetch.url = page.Fetcher.url;
    title = page.Fetcher.title;
    text = page.Fetcher.text;
    content_type = page.Fetcher.content_type;
    status_code = page.Fetcher.status_code;
    truncated = page.Fetcher.truncated;
    total_chars = page.Fetcher.total_chars;
    path_addressable = page.Fetcher.path_addressable;
    image =
      (match page.Fetcher.image with
      | None -> None
      | Some image -> Some { Engine.Fetch.media_type = image.Fetcher.media_type; body = image.Fetcher.body });
  }

let error_of (error : Fetcher.error) : Engine.Fetch.fetch_error =
  match error with
  | Fetcher.Refusal (Fetcher.Url_blocked message) -> Engine.Fetch.Url_blocked message
  | Fetcher.Refusal (Fetcher.Redirect_blocked message) ->
      Engine.Fetch.Redirect_blocked message
  | Fetcher.Refusal (Fetcher.Blocked message) -> Engine.Fetch.Fetch_blocked message
  | Fetcher.Failed message ->
      Engine.Fetch.Provider (Provider.provider_error ~provider:"http" message)

let build_fetch_stack ~sw ~net ~mono_clock config =
  let fetch = config.Config.fetch in
  if not fetch.Config.enabled then None
  else
    match build_extractor config with
    | Error message -> Some (Error message)
    | Ok extractor -> (
    match
      Policy.with_public_web ~sw ~net ~max_response_bytes:fetch.Config.max_download_bytes ()
    with
    | Error error -> Some (Error (Caps.Error.render error))
    | Ok decision ->
        let grant = Authority.Net.of_confinement ~mono_clock decision in
        let grant =
          Authority.with_operation_timeout
            (Eio.Time.Timeout.seconds mono_clock fetch.Config.timeout_seconds)
            grant
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
                  Fetcher.fetch fetcher url ~offset ~max_chars:(cap_of max_chars)
                with
                | Ok page -> Ok (page_of page)
                | Error error -> Error (error_of error));
            aclose = (fun () -> ());
          }
        in
        (* The keyed/self-hosted fallbacks are deferred with P6, so the ladder
           is empty in v1; a primary other than the local reader is refused by
           the server's startup checks rather than silently read locally. *)
        Some (Ok (local, [])))

let agent_net ~sw ~net ~mono_clock config =
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
        endpoint)

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
      let built =
        build_providers ~sw ~net:(env#net) ~mono_clock ~now config
      in
      match built.grant_errors with
      | (name, message) :: _ ->
          Error (Printf.sprintf "provider %s: %s" name message)
      | [] ->
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
            match build_fetch_stack ~sw ~net:(env#net) ~mono_clock config with
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
              match agent_net ~sw ~net:(env#net) ~mono_clock config with
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
                        probe_net ~sw ~net:(env#net) ~mono_clock
                          ~timeout_seconds:
                            config.Config.policy.Config.provider_timeout_seconds
                          built.endpoints;
                    };
              },
              built ))
