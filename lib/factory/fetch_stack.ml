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
module Fetcher = Seekwright_fetch.Fetcher
module Jsondoc = Seekwright_fetch.Jsondoc
module Policy = Mcp_caps.Policy
module Provider = Seekwright.Provider

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
