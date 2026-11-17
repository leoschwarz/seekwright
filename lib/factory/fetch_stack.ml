module Caps = Mcp_caps
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Extract_pool = Seekwright_fetch.Extract_pool
module Extractor = Seekwright_fetch.Extractor
module Fallback = Seekwright_fetch.Fallback
module Fetcher = Seekwright_fetch.Fetcher
module Jsondoc = Seekwright_fetch.Jsondoc
module Page_cache = Seekwright_fetch.Page_cache
module Policy = Mcp_caps.Policy
module Provider = Seekwright.Provider
module Remote_target = Seekwright_fetch.Remote_target

let ( let* ) = Result.bind

let grant_of_decision = Grants.grant_of_decision

let build_extractor config =
  match config.Config.fetch.Config.extractor with
  | "stdlib" -> Ok (Extractor.of_module (module Seekwright_fetch_stdlib.Stdlib))
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
    select_paths = Jsondoc.select_paths;
    select_passages = Extractor.select_passages;
  }

let cap_of (cap : Engine.Fetch.cap) : int option =
  match cap with
  | Engine.Fetch.Default -> None
  | Engine.Fetch.Limit n -> Some n
  | Engine.Fetch.Uncapped -> Some Fetcher.uncapped

(* The row's declared price is the default; the operator's override applies only
   where a price exists, so an unbilled rung still records [None]. *)
let fallback_cost config (row : Config.fetch_fallback) =
  match row.Config.default_cost with
  | None -> None
  | Some declared -> Some (Option.value ~default:declared config.Config.fetch.Config.cost_per_1k)

let fallback_error_of (name : Config.name) error =
  match error with
  | Fallback.Url_blocked message -> Engine.Fetch.Url_blocked message
  | Fallback.Rejected message ->
      Engine.Fetch.Provider (Provider.provider_error ~retryable:false ~provider:name message)
  | Fallback.Quota message ->
      Engine.Fetch.Provider (Provider.quota_exhausted ~provider:name ~message ())
  | Fallback.Failed message ->
      Engine.Fetch.Provider (Provider.provider_error ~provider:name message)

let wrap_fallback (name : Config.name) cost fetch =
  {
    Engine.Fetch.name;
    cost_per_1k = cost;
    fetch =
      (fun ~url ~offset ~max_chars ->
        match fetch url ~offset ~max_chars:(cap_of max_chars) with
        | Ok page -> Ok page
        | Error error -> Error (fallback_error_of name error));
    aclose = (fun () -> ());
  }

(* The keyed vendor rows, and no others: a registry row outside this list has no
   builder here and stays unbuilt, like a name a gate refuses. *)
let keyed_vendor name =
  match name with
  | "scrappa" -> Some `Scrappa
  | "tavily" -> Some `Tavily
  | "linkup" -> Some `Linkup
  | _ -> None

(* [fetch.timeout_seconds] bounds a static read; a vendor browser or extraction
   waits longer, so a remote rung's grant floors here. *)
let grant_floor = 30.0

(* Tavily's own [timeout_seconds] is a body parameter [Fallback_tavily] clamps
   to 1–60 seconds. It is not this grant's timeout; the two floors only look
   alike. *)
let tavily_body_floor = 30.0

(* The remote prologue every vendor rung shares: the row's constant endpoint, the
   grant on it, and the target the rung re-vets on each call. *)
let grant_and_target ~sw ~net ~mono_clock ?audit config row =
  let endpoint =
    Provider.policy_of_uri (Uri.of_string (Option.value ~default:"" row.Config.endpoint))
  in
  let* grant =
    Grants.grant_of_endpoint ~sw ~net ~mono_clock
      ~timeout_seconds:(Float.max config.Config.fetch.Config.timeout_seconds grant_floor)
      ?audit endpoint
  in
  Ok (grant, Remote_target.make net)

let build_fallback ~sw ~net ~mono_clock ?audit config name =
  let fetch = config.Config.fetch in
  let row =
    List.find_opt
      (fun (r : Config.fetch_fallback) -> r.Config.name = name)
      Config.known_fetch_fallbacks
  in
  match row with
  | None ->
      Error
        (Printf.sprintf "unknown fetch fallback %S; supported: %s" name
           (String.concat ", "
              (List.sort compare (List.map (fun r -> r.Config.name) Config.known_fetch_fallbacks))))
  | Some row -> (
      let keyed () =
        match Config.api_key name with Some key when key <> "" -> Some key | _ -> None
      in
      match name with
      | "jina" ->
          if not (Config.is_permitted config name) then Ok None
          else
            let* grant, target = grant_and_target ~sw ~net ~mono_clock ?audit config row in
            Ok
              (Some
                 (wrap_fallback name (fallback_cost config row)
                    (Seekwright_fetch.Fallback_jina.fetch
                       {
                         net = Fallback.of_grant grant;
                         target;
                         max_text_chars = fetch.Config.max_text_chars;
                         user_agent = fetch.Config.user_agent;
                       })))
      | "crawl4ai" -> (
          (* The self-hosted renderer: no key and no permission gate, so
             [fetch.crawl4ai_url] is the whole prerequisite — and its endpoint
             is the operator's own config, not a constant. *)
          match fetch.Config.crawl4ai_url with
          | None | Some "" -> Ok None
          | Some base_url ->
              let* grant =
                Grants.grant_of_endpoint ~sw ~net ~mono_clock
                  ~timeout_seconds:fetch.Config.crawl4ai_timeout_seconds ?audit
                  (Provider.policy_of_uri (Uri.of_string base_url))
              in
              let target = Remote_target.make net in
              Ok
                (Some
                   (wrap_fallback name (fallback_cost config row)
                      (Seekwright_fetch.Fallback_crawl4ai.fetch
                         {
                           net = Fallback.of_grant grant;
                           target;
                           max_text_chars = fetch.Config.max_text_chars;
                           base_url;
                           token = fetch.Config.crawl4ai_token;
                         }))))
      | _ -> (
          if
            (* Both keyed gates before anything is built: a permission set that
             omits the name, or an empty [api_key], leaves the rung unbuilt
             rather than firing it. *)
            not (Config.is_permitted config name)
          then Ok None
          else
            match keyed () with
            | None -> Ok None
            | Some api_key -> (
                match keyed_vendor name with
                | None -> Ok None
                | Some vendor ->
                    let* grant, target = grant_and_target ~sw ~net ~mono_clock ?audit config row in
                    let vendor_net = Fallback.of_grant grant in
                    let max_text_chars = fetch.Config.max_text_chars in
                    let rung =
                      match vendor with
                      | `Scrappa ->
                          Seekwright_fetch.Fallback_scrappa.fetch
                            { net = vendor_net; target; max_text_chars; api_key }
                      | `Linkup ->
                          Seekwright_fetch.Fallback_linkup.fetch
                            { net = vendor_net; target; max_text_chars; api_key }
                      | `Tavily ->
                          Seekwright_fetch.Fallback_tavily.fetch
                            {
                              net = vendor_net;
                              target;
                              max_text_chars;
                              api_key;
                              timeout_seconds =
                                Float.max fetch.Config.timeout_seconds tavily_body_floor;
                            }
                    in
                    Ok (Some (wrap_fallback name (fallback_cost config row) rung)))))

(* [error_of] is a translation, not a copy, and stays one: [Fetcher.refusal] and
   [Engine.Fetch.fetch_error] are different vocabularies on purpose — a
   [Blocked] becomes the engine's mid-flight refusal, a [Failed] becomes a
   provider error carrying the route's name. The page records beside them are the
   same type under both names ([Seekwright_wire.Page]), so the reader below hands
   the page straight over (style review M5). *)
let error_of (error : Fetcher.error) : Engine.Fetch.fetch_error =
  match error with
  | Fetcher.Refusal (Fetcher.Url_blocked message) -> Engine.Fetch.Url_blocked message
  | Fetcher.Refusal (Fetcher.Redirect_blocked message) -> Engine.Fetch.Redirect_blocked message
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
          (* The local reader's grant respects allow_private_addresses; fallbacks remain strictly public. *)
          (if fetch.Config.allow_private_addresses then Policy.with_private_web
           else Policy.with_public_web)
            ~sw ~net ~port_policy:Policy.Any_port
            ~max_response_bytes:fetch.Config.max_download_bytes ()
        with
        | Error error -> Some (Error (Caps.Error.render error))
        | Ok decision -> (
            match
              Extract_pool.make ~net ~mono_clock ~dir:(Filename.get_temp_dir_name ()) ~extractor
                ~max_body_bytes:fetch.Config.max_download_bytes ()
            with
            | Error message -> Some (Error message)
            | Ok workers -> (
                let grant =
                  grant_of_decision ~mono_clock ~timeout_seconds:fetch.Config.timeout_seconds ?audit
                    decision
                in
                let fetcher =
                  Fetcher.make ~net:grant ~extractor ~workers
                    ~parse_timeout_seconds:fetch.Config.timeout_seconds
                    ~max_download_bytes:fetch.Config.max_download_bytes
                    ~max_text_chars:fetch.Config.max_text_chars
                    ~max_redirects:fetch.Config.max_redirects
                    ~allow_images:fetch.Config.allow_images ~user_agent:fetch.Config.user_agent ()
                in
                let local =
                  {
                    Engine.Fetch.name = "http";
                    cost_per_1k = fetch.Config.cost_per_1k;
                    fetch =
                      (fun ~url ~offset ~max_chars ->
                        match
                          Fetcher.fetch
                            ~chain_timeout:
                              (Eio.Time.Timeout.seconds mono_clock
                                 (2. *. fetch.Config.timeout_seconds))
                            fetcher url ~offset ~max_chars:(cap_of max_chars)
                        with
                        | Ok page -> Ok page
                        | Error error -> Error (error_of error));
                    aclose = (fun () -> Extract_pool.close workers);
                  }
                in
                let build_ladder names =
                  let* acc =
                    List.fold_left
                      (fun acc name ->
                        let* acc = acc in
                        match build_fallback ~sw ~net ~mono_clock ?audit config name with
                        | Error message -> Error message
                        | Ok None -> Ok acc
                        | Ok (Some rung) -> Ok (rung :: acc))
                      (Ok []) names
                  in
                  Ok (List.rev acc)
                in
                match build_ladder (Option.value ~default:[] fetch.Config.fallback) with
                | Error message -> Some (Error message)
                | Ok ladder -> Some (Ok (local, ladder)))))

let cache_read_floor = 65_536
let cache_max_entries = 10_000

let preflight_of ~(net : _ Eio.Net.t) config =
  let fetch = config.Config.fetch in
  fun (raw : string) ->
    match Remote_target.vet ~net ~private_web_allowed:fetch.Config.allow_private_addresses raw with
    | Ok validated -> Ok validated
    | Error message -> Error (Engine.Fetch.Url_blocked message)

let cache_seam ~(net : _ Eio.Net.t) config (cache : Page_cache.t) =
  let fetch = config.Config.fetch in
  let fills : (string, (unit, Engine.Fetch.fetch_error) result Eio.Promise.t) Hashtbl.t =
    Hashtbl.create 16
  in
  let read ~rung ~url ~offset ~max_chars ~dispatch =
    let cap = Fetcher.resolved_cap fetch.Config.max_text_chars (cap_of max_chars) in
    let lookup () =
      match max_chars with
      | Engine.Fetch.Uncapped -> Page_cache.get cache ~rung ~url
      | _ -> Page_cache.get_window cache ~rung ~url ~offset ~max_chars:cap
    in
    match lookup () with
    | Some entry -> Ok (entry, true)
    | None -> (
        let key = Page_cache.entry_name ~rung ~url in
        match Hashtbl.find_opt fills key with
        | Some waiting -> (
            match Eio.Promise.await waiting with
            | Error exc -> Error exc
            | Ok () -> (
                match lookup () with
                | Some entry -> Ok (entry, true)
                | None -> Result.map (fun page -> (page, false)) (dispatch ~offset ~max_chars)))
        | None ->
            let waiting, resolve = Eio.Promise.create () in
            Hashtbl.add fills key waiting;
            Fun.protect
              ~finally:(fun () ->
                Hashtbl.remove fills key;
                (* Wake waiters if cancelled before resolution. *)
                ignore
                  (Eio.Promise.try_resolve resolve
                     (Error
                        (Engine.Fetch.Provider
                           (Provider.provider_error ~provider:"http"
                              "the page fetch was interrupted")))))
              (fun () ->
                match dispatch ~offset:0 ~max_chars:Engine.Fetch.Uncapped with
                | Error exc ->
                    Eio.Promise.resolve resolve (Error exc);
                    Error exc
                | Ok full -> (
                    if full.image = None then ignore (Page_cache.put cache ~rung ~url ~page:full);
                    Eio.Promise.resolve resolve (Ok ());
                    match lookup () with
                    | Some entry -> Ok (entry, false)
                    | None ->
                        if max_chars = Engine.Fetch.Uncapped then Ok (full, false)
                        else
                          let window, truncated =
                            Fetcher.window_text full.text ~offset ~max_chars:cap
                          in
                          Ok ({ full with text = window; truncated }, false))))
  in
  { Engine.Fetch.Cache.preflight = preflight_of ~net config; read }

let open_cache_grant ~sw ~mono_clock ~fs ?audit config =
  let fetch = config.Config.fetch in
  match fetch.Config.cache_dir with
  | None -> Ok None
  | Some dir ->
      Result.map
        (fun grant -> Some grant)
        (Grants.fs_grant_of_written_root ~sw ~parent:fs ~mono_clock
           ~max_bytes:(Stdlib.max fetch.Config.cache_max_entry_bytes cache_read_floor)
           ~max_entries:cache_max_entries ?audit dir)

let build_page_cache ~sw ~(net : _ Eio.Net.t) ~mono_clock ~now ?audit ~fs config =
  match open_cache_grant ~sw ~mono_clock ~fs ?audit config with
  | Error message -> Error message
  | Ok None -> Ok None
  | Ok (Some grant) ->
      let fetch = config.Config.fetch in
      let cache =
        Page_cache.create ~fs:grant ~max_bytes:fetch.Config.cache_max_bytes
          ~max_entry_bytes:fetch.Config.cache_max_entry_bytes
          ~ttl_seconds:fetch.Config.cache_ttl_seconds ~now ()
      in
      Ok (Some (cache_seam ~net config cache))

let page_cache_stats ~sw ~mono_clock ~fs config =
  match open_cache_grant ~sw ~mono_clock ~fs config with
  | Error message -> Error message
  | Ok None -> Ok None
  | Ok (Some grant) ->
      Ok (Some (Page_cache.stats (Page_cache.create ~fs:grant ~now:(fun () -> 0.0) ())))
