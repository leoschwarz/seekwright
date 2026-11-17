(** The fetch half of construction: the extraction backend, the document readers the engine selects
    with, and the local reader with its own web grant. *)

val build_extractor : Seekwright.Config.t -> (Seekwright_fetch.Extractor.backend, string) result
(** Instantiate the extraction backend [[fetch] extractor] names. [stdlib] is the one this build
    carries; the name is validated at config load, so an unknown one here means a config built
    around validation. *)

val readers : Seekwright.Engine.Fetch.Readers.t
(** The document readers the fetch engine selects with: [jsondoc]'s path grammar, schema rendering
    and path selection, and the shared passage selection. *)

val build_fetch_stack :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Seekwright.Config.t ->
  (Seekwright.Engine.Fetch.fetcher * Seekwright.Engine.Fetch.fetcher list, string) result option
(** [None] when [[fetch] enabled = false]. Otherwise the local reader as the primary route plus the
    fallback ladder [fetch.fallback] names — each name built by its vendor module and adapted to the
    engine's [fetcher] record, and each name whose gates this deployment does not satisfy (a
    permission set that omits it, a keyed vendor with no key, [crawl4ai] with no
    [fetch.crawl4ai_url]) simply absent. The local reader's grant is the web variant the config's
    [fetch.allow_private_addresses] names: [Policy.with_private_web] when the operator approved
    intranet reads, [Policy.with_public_web] otherwise. The fallbacks' grants are endpoint-scoped
    and their targets vetted public whatever that key says, because the key licenses this process,
    not a third party's view of the intranet.

    Extraction runs on an {!Seekwright_fetch.Extract_pool.t} — one pool per built stack, its workers
    fed through the system temp dir, [fetch.timeout_seconds] applied to the parse and twice that to
    the whole request, and the reader's [aclose] draining the pool. A pool that cannot be built
    refuses the stack rather than quietly extracting inline. *)

val build_page_cache :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  now:(unit -> float) ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  fs:_ Eio.Path.t ->
  Seekwright.Config.t ->
  (Seekwright.Engine.Fetch.Cache.t option, string) result
(** [None] when [fetch.cache_dir] is unset — the path on which every read dispatches and
    [fetch.ok]'s [cached] is always [false]. Otherwise the fetch engine's cache seam over one
    directory of page entries: the entry key is the hash of the route rung and the {i validated}
    URL, the directory is capped by [fetch.cache_max_bytes] with LRU eviction, an entry over
    [fetch.cache_max_entry_bytes] is never stored, and an entry older than [fetch.cache_ttl_seconds]
    reads as a miss. The directory is opened behind [Grants.fs_grant_of_written_root] — this
    library's only [Authority.Fs.of_confinement] — which creates it (mode [0o700]) or refuses: an
    operator's [cache_dir] this process cannot create or open is a startup failure, not a cache
    miss. See [Seekwright_fetch.Page_cache] for the entry format and the windowed read. *)

val page_cache_stats :
  sw:Eio.Switch.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  fs:_ Eio.Path.t ->
  Seekwright.Config.t ->
  ((int * int) option, string) result
(** [Some (entries, body_bytes)] for the directory [fetch.cache_dir] names, [None] when it is unset:
    the figures [--check] prints, read off the same written root the served process builds. A
    diagnosis reads the directory; it does not go through the serving path, which is why this is a
    call of its own rather than a field of the seam. *)
