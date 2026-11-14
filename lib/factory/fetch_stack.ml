(* The fetch half of construction: the extraction backend the config names, the
   document readers the fetch engine selects with, and the local reader with its
   own web grant. Port of [src/seekwright/factory.py]'s build_fetch_stack and the
   reader wiring around it.

   This is the one place a config key decides a capability's address rule —
   [fetch.allow_private_addresses] picks the web variant the reader is built in —
   and [test_fetch_grant] pins that it is built exactly once across the library.
   Everything else that can reach the network goes through [Grants], which has no
   way to ask for the private-web variant. *)

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

(* The funnel, named here rather than called through [Grants] only so the body
   below reads as it did where it was written: the grant this stack builds is the
   same one every other route gets. *)
let grant_of_decision = Grants.grant_of_decision


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
    select_paths = Jsondoc.select_paths;
    select_passages = Extractor.select_passages;
  }

let cap_of (cap : Engine.Fetch.cap) : int option =
  match cap with
  | Engine.Fetch.Default -> None
  | Engine.Fetch.Limit n -> Some n
  | Engine.Fetch.Uncapped -> Some Fetcher.uncapped

(* The prices the fallback classes declare on themselves in the oracle — the
   figures the fetch journal records for a served page. They live here, at the
   wiring point, because the vendor modules are pure protocol and carry no
   billing: [fetch.cost_per_1k] is the operator's correction of these, one key
   for the whole ladder, and it corrects only the priced rows — a free row
   stays free whatever the key says, because "no price to record" is not a
   price of zero. *)
let fallback_price name =
  match name with
  | "scrappa" -> Some 0.30
  | "tavily" -> Some 1.60
  | "linkup" -> Some 5.00
  | _ -> None

let fallback_cost config name =
  match fallback_price name with
  | Some _ -> (
      match config.Config.fetch.Config.cost_per_1k with
      | Some c -> Some c
      | None -> fallback_price name)
  | None -> None

(* [Fallback.error] is the four-way split of the oracle's raises; the engine
   needs the same three distinctions its search path makes — the refusal the
   caller can act on, the non-retryable auth rejection, and the quota that
   benches the name for a cooldown — so this is a translation, not a copy, in
   the same spirit as [error_of] below. *)
let fallback_error_of (name : Config.name) error =
  match error with
  | Fallback.Url_blocked message -> Engine.Fetch.Url_blocked message
  | Fallback.Rejected message ->
      Engine.Fetch.Provider (Provider.provider_error ~retryable:false ~provider:name message)
  | Fallback.Quota message ->
      Engine.Fetch.Provider (Provider.quota_exhausted ~provider:name ~message ())
  | Fallback.Failed message ->
      Engine.Fetch.Provider (Provider.provider_error ~provider:name message)

(* One [Engine.Fetch.fetcher] per built fallback: the record is the same shape
   whatever the vendor, so only the call below and the credential differ. *)
let wrap_fallback (name : Config.name) cost fetch =
  {
    Engine.Fetch.name;
    cost_per_1k = cost;
    fetch =
      (fun ~url ~offset ~max_chars ->
        match fetch url ~offset ~max_chars:(cap_of max_chars) with
        | Ok page -> Ok page
        | Error error -> Error (fallback_error_of name error));
    (* Nothing to drain: the grant is the factory's, tied to the app switch,
       and the vendor module holds no socket of its own. *)
    aclose = (fun () -> ());
  }
(* The per-vendor build, mirroring the oracle's [_build_*] functions: each
   asks its own gates, returns [Ok None] when the deployment does not satisfy
   them, and builds the one grant the vendor's endpoint deserves. *)
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
           (String.concat ", " (List.sort compare (List.map (fun r -> r.Config.name)
              Config.known_fetch_fallbacks))))
  | Some row -> (
      (* The credential gate, for the keyed vendors: an empty [api_key] is an
         absent one, and a permission set that omits the name leaves the
         fallback unbuilt rather than firing it. *)
      let keyed () =
        match Config.api_key name with
        | Some key when key <> "" -> Some key
        | _ -> None
      in
      match name with
      | "jina" ->
          if not (Config.is_permitted config name) then Ok None
          else
            let* grant =
              Grants.grant_of_endpoint ~sw ~net ~mono_clock
                ~timeout_seconds:(Float.max fetch.Config.timeout_seconds 30.0)
                ?audit (Provider.policy_of_uri (Uri.of_string (Option.value ~default:"" row.Config.endpoint)))
            in
            let target = Remote_target.make net in
            let vendor_net = Fallback.of_grant grant in
            Ok
              (Some
                 (wrap_fallback name (fallback_cost config name)
                    (Seekwright_fetch.Fallback_jina.fetch
                       {
                         net = vendor_net;
                         target;
                         max_text_chars = fetch.Config.max_text_chars;
                         user_agent = fetch.Config.user_agent;
                       })))
      | "crawl4ai" ->
          (* The self-hosted renderer: no key and no permission gate, so
             [fetch.crawl4ai_url] is the whole prerequisite — and its endpoint
             is the operator's own config, not a constant. *)
          (match fetch.Config.crawl4ai_url with
          | None | Some "" -> Ok None
          | Some base_url ->
              let* grant =
                Grants.grant_of_endpoint ~sw ~net ~mono_clock
                  ~timeout_seconds:fetch.Config.crawl4ai_timeout_seconds
                  ?audit (Provider.policy_of_uri (Uri.of_string base_url))
              in
              let target = Remote_target.make net in
              Ok
                (Some
                   (wrap_fallback name (fallback_cost config name)
                      (Seekwright_fetch.Fallback_crawl4ai.fetch
                         {
                           net = Fallback.of_grant grant;
                           target;
                           max_text_chars = fetch.Config.max_text_chars;
                           base_url;
                           token = fetch.Config.crawl4ai_token;
                         }))))
      | _ ->
          (* The keyed third parties share the two gates and the timeout
             floor: [fetch.timeout_seconds] bounds a static read, and a
             vendor browser or extraction waits longer. *)
          if not (Config.is_permitted config name) then Ok None
          else
            match keyed () with
            | None -> Ok None
            | Some api_key -> (
                match Provider.policy_of_uri (Uri.of_string (Option.value ~default:"" row.Config.endpoint)) with
                | endpoint -> (
                    match
                      Grants.grant_of_endpoint ~sw ~net ~mono_clock
                        ~timeout_seconds:(Float.max fetch.Config.timeout_seconds 30.0)
                        ?audit endpoint
                    with
                    | Error message -> Error message
                    | Ok grant ->
                        let target = Remote_target.make net in
                        let vendor_net = Fallback.of_grant grant in
                        let built =
                          match name with
                          | "scrappa" ->
                              Some
                                (Seekwright_fetch.Fallback_scrappa.fetch
                                   {
                                     net = vendor_net;
                                     target;
                                     max_text_chars = fetch.Config.max_text_chars;
                                     api_key;
                                   })
                          | "tavily" ->
                              Some
                                (Seekwright_fetch.Fallback_tavily.fetch
                                   {
                                     net = vendor_net;
                                     target;
                                     max_text_chars = fetch.Config.max_text_chars;
                                     api_key;
                                     timeout_seconds =
                                       Float.max fetch.Config.timeout_seconds 30.0;
                                   })
                          | "linkup" ->
                              Some
                                (Seekwright_fetch.Fallback_linkup.fetch
                                   {
                                     net = vendor_net;
                                     target;
                                     max_text_chars = fetch.Config.max_text_chars;
                                     api_key;
                                   })
                          | _ -> None
                        in
                        match built with
                        | Some fetch_fn ->
                            Ok (Some (wrap_fallback name (fallback_cost config name) fetch_fn))
                        | None -> Ok None)))



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
            (* The fallback ladder, in config order. Each row of
               [Config.known_fetch_fallbacks] says what its build needs: a
               constant endpoint, or the [fetch.crawl4ai_url] key as the host.
               A name whose gates this deployment does not satisfy is not
               built — a permission set that omits the name leaves the
               fallback unbuilt rather than firing it, and a keyed fallback
               with no key in the environment is the same, exactly as the
               oracle's [_build_*] functions return [None].

               Every grant here is [grant_of_endpoint] over the vendor the
               row dials, which has no way to ask for the private-web
               variant: the public-only rule for a third-party route is a
               property of how its grant is built, not a runtime check (see
               the local reader's grant above for the one key that does
               choose a web variant). Crawl4AI's endpoint is this
               deployment's own config, so it may be an internal host — the
               operator wrote that URL — while the {i target} handed to it is
               still vetted public by [Remote_target], as for every other
               vendor: the renderer's browser would otherwise read the very
               network the caller's URL could not reach. *)
            let rec build_ladder = function
              | [] -> Ok []
              | name :: rest -> (
                  match build_fallback ~sw ~net ~mono_clock ?audit config name with
                  | Error message -> Error message
                  | Ok None -> build_ladder rest
                  | Ok Some fetcher ->
                      Result.map (( @ ) [ fetcher ]) (build_ladder rest))
            in
            match build_ladder (Option.value ~default:[] fetch.Config.fallback) with
            | Error message -> Some (Error message)
            | Ok ladder -> Some (Ok (local, ladder)))
)

(* {2 The page cache (F7)} *)

(* The wiring between [Seekwright_fetch.Page_cache] (the entry format, the bounds,
   the window cut) and [Engine.Fetch.Cache] (the two questions the engine asks).
   The three things that live only here are the grant over the operator's
   directory, the fill's singleflight table, and the preflight — and each is here
   for a layering reason rather than a taste one.

   The grant is the startup decision the oracle makes in its builder: a
   [cache_dir] this process cannot create or use is a refusal to start, not a miss
   typed lazily all day long. Its ceilings are the config's own — a stored page is
   one whole write and one whole read, so a ceiling below [cache_max_entry_bytes]
   would make the cache refuse its own entries — with a floor at the windowed
   read's chunk, because that is the read the streaming promise is about.
   [cache_max_entries] is deliberately not a config key: the directory cap bounds
   what fits whatever this says, and it only has to be above the entry count that
   cap allows at the smallest page this server stores. *)

(* [Page_cache]'s read chunk, as the grant's floor: a ceiling under it would make
   the streaming read refuse its own chunk. The two numbers have to agree, and this
   is a construction decision while the chunk is an implementation one. *)
let cache_read_floor = 65_536

(* The grant's entry ceiling: comfortably above what the byte cap can hold, so the
   cap that matters is the byte cap. *)
let cache_max_entries = 10_000

let preflight_of ~(net : _ Eio.Net.t) config =
  (* The URL-level guardrails, run before any cache lookup when the cache is on.

     [Fetcher.validate_url] is the normalisation the entry keys on, so a caller's
     spelling of a page and its post-redirect landing cannot share an entry, and a
     refused URL is refused with a warm entry just as without one. The address vet
     applies under the same rule the local reader applies it — opted out of by
     [fetch.allow_private_addresses], because the guardrail protects this server's
     network, not the fetcher's code path. The third-party fallbacks apply it
     always: [Remote_target] says why. The fetchers re-run their own guardrails on
     a miss; that reads as duplicate work only until it reads as what makes a warm
     hit safe. *)
  let fetch = config.Config.fetch in
  fun (raw : string) ->
    match Fetcher.validate_url raw with
    | Error message -> Error (Engine.Fetch.Url_blocked message)
    | Ok validated ->
        if fetch.Config.allow_private_addresses
        then Ok validated
        else (
          match Uri.host (Uri.of_string validated) with
          | None -> Error (Engine.Fetch.Url_blocked "URL has no host")
          | Some host -> (
              match Caps.Policy_net.vet_public_host ~net ~host with
              | Ok () -> Ok validated
              | Error error -> Error (Engine.Fetch.Url_blocked (Caps.Error.message error))))

(* The engine's seam over one [Page_cache.t]: the entry lookup, and the fill one
   caller leads while the rest wait for it.

   [fills] is the per-key in-flight table, and it sits here rather than inside
   [Page_cache] because what a follower inherits is the leader's {i fetch error},
   a type the cache module has no business naming. The rules are the oracle's: the
   fill dispatches uncapped at offset 0, so the whole extraction is what gets
   stored; a follower that finds an entry is dispatch-free and reported cached,
   and one whose fill could not store (an over-cap page) fetches its own window; a
   failed fill wakes every waiter with the one failure the leader saw and stores
   nothing; and the leader itself is a dispatch, even though it then serves its own
   window out of the entry it wrote — the flag answers "was this dispatch-free",
   not "was a cache used". An image page bypasses the store: bytes pass through as
   they do with no cache at all. *)
let cache_seam ~(net : _ Eio.Net.t) config (cache : Page_cache.t) =
  let fetch = config.Config.fetch in
  let fills : (string, (unit, Engine.Fetch.fetch_error) result Eio.Promise.t) Hashtbl.t =
    Hashtbl.create 16
  in
  let read ~rung ~url ~offset ~max_chars ~dispatch =
    (* The window this call serves, whichever way the entry arrives: [cap] is the
       same resolution the configured fetchers apply to the same request, which is
       what makes a cached window byte-identical to the live one. *)
    let cap = Fetcher.resolved_cap fetch.Config.max_text_chars (cap_of max_chars) in
    let lookup () =
      match max_chars with
      | Engine.Fetch.Uncapped -> Page_cache.get cache ~rung ~url
      | _ -> Page_cache.get_window cache ~rung ~url ~offset ~max_chars:cap
    in
    match lookup () with
    | Some entry -> Ok (Page_cache.to_page entry, true)
    | None -> (
      let key = Page_cache.entry_name ~rung ~url in
      match Hashtbl.find_opt fills key with
      | Some waiting -> (
          match Eio.Promise.await waiting with
          | Error exc -> Error exc
          | Ok () -> (
              match lookup () with
              | Some entry -> Ok (Page_cache.to_page entry, true)
              | None -> Result.map (fun page -> (page, false)) (dispatch ~offset ~max_chars)))
      | None ->
        let waiting, resolve = Eio.Promise.create () in
        Hashtbl.add fills key waiting;
        Fun.protect
          ~finally:(fun () ->
            Hashtbl.remove fills key;
            (* Only reaches a promise nobody resolved: a fill cut short by
               cancellation would otherwise leave every waiter parked on it. *)
            ignore
              (Eio.Promise.try_resolve
                 resolve
                 (Error
                    (Engine.Fetch.Provider
                       (Provider.provider_error ~provider:"http"
                          "the page fetch was interrupted")))))
          (fun () ->
            match dispatch ~offset:0 ~max_chars:Engine.Fetch.Uncapped with
            | Error exc ->
                Eio.Promise.resolve resolve (Error exc);
                Error exc
            | Ok full ->
                if full.image = None
                then ignore (Page_cache.put cache ~rung ~url ~page:(Page_cache.of_page full));
                Eio.Promise.resolve resolve (Ok ());
                (* The leader serves its own window through the entry it just
                   wrote, so a paged read streams only its window even on the call
                   that filled the cache. When the store refused the page, what is
                   left is the uncapped read this call was holding, cut to the
                   window a live paged fetch would have applied. *)
                match lookup () with
                | Some entry -> Ok (Page_cache.to_page entry, false)
                | None ->
                    if max_chars = Engine.Fetch.Uncapped
                    then Ok (full, false)
                    else
                      let window, truncated = Fetcher.window_text full.text ~offset ~max_chars:cap in
                      Ok ({ full with text = window; truncated }, false)))
  in
  { Engine.Fetch.Cache.preflight = preflight_of ~net config; read }

(* The written root, once: the same grant the served process builds, so [--check]
   reports the entries the server will read rather than a guess about them. The
   [0o700] is the cache's own, because a stored page is somebody else's text
   sitting in this host's filesystem, and a directory that cannot be created or
   opened is a refusal, not an empty report. The grant itself is minted in
   [Grants], the funnel every grant in this library comes from — including its
   audit decoration, which is what the [?audit] argument is for. *)
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

(* [None] when [fetch.cache_dir] is unset — the always-false [cached] path, with
   no directory touched. *)
let build_page_cache ~sw ~(net : _ Eio.Net.t) ~mono_clock ~now ?audit ~fs config =
  match open_cache_grant ~sw ~mono_clock ~fs ?audit config with
  | Error message -> Error message
  | Ok None -> Ok None
  | Ok Some grant ->
      let fetch = config.Config.fetch in
      let cache =
        Page_cache.create ~fs:grant
          ~max_bytes:fetch.Config.cache_max_bytes
          ~max_entry_bytes:fetch.Config.cache_max_entry_bytes
          ~ttl_seconds:fetch.Config.cache_ttl_seconds
          ~now ()
      in
      Ok (Some (cache_seam ~net config cache))

(* [entries, body_bytes] for the directory the config names: [--check]'s line, and
   the reason this is a separate call rather than a field of the seam — a
   diagnosis reads the directory, it does not go through the serving path. *)
let page_cache_stats ~sw ~mono_clock ~fs config =
  match open_cache_grant ~sw ~mono_clock ~fs config with
  | Error message -> Error message
  | Ok None -> Ok None
  | Ok Some grant -> Ok (Some (Page_cache.stats (Page_cache.create ~fs:grant ~now:(fun () -> 0.0) ())))

