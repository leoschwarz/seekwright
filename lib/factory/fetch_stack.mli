(** The fetch half of construction: the extraction backend, the document readers
    the engine selects with, and the local reader with its own web grant.

    Private to [Seekwright_factory]: [Factory] re-exports {!build_extractor},
    {!readers} and {!build_fetch_stack}, and keeps the two translations
    ([cap_of], [error_of]) here because they are vocabulary conversions between
    the fetcher and the engine, not a public surface.

    This module holds the library's only web-grant construction, and the only
    place a config key decides a capability's address rule:
    [fetch.allow_private_addresses] selects [Policy.with_private_web] over
    [Policy.with_public_web] at construction time, once, and
    [test/test_fetch_grant.ml] counts those two constructions across the whole
    library. Every other route's grant comes from [Grants], whose endpoint grants
    have no private-web form to be given. *)

(** Instantiate the extraction backend [[fetch] extractor] names. The public
    contract is on [Factory.build_extractor] in [factory.mli]. *)
val build_extractor : Seekwright.Config.t -> (Seekwright_fetch.Extractor.backend, string) result

(** The document readers the fetch engine selects with. The public contract is on
    [Factory.readers] in [factory.mli]. *)
val readers : Seekwright.Engine.Fetch.Readers.t

(** [None] when [[fetch] enabled = false]; otherwise the local reader and the
    fallback ladder. The public contract, including which web variant the reader
    is built with and why the fallbacks stay public-only, is on
    [Factory.build_fetch_stack] in [factory.mli]. *)
val build_fetch_stack :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Seekwright.Config.t ->
  ((Seekwright.Engine.Fetch.fetcher * Seekwright.Engine.Fetch.fetcher list), string) result option

(** The page cache's seam: [None] when [fetch.cache_dir] is unset, and otherwise
    the two questions the fetch engine asks of one directory of entries. The
    directory is opened (and created, mode [0o700]) by
    {!Mcp_caps.Policy.with_written_root}, so an operator's [cache_dir] this process
    cannot create or use is an [Error] here — the refusal to start the oracle
    raises in its builder, rather than a miss typed lazily all day long. The
    public contract is on [Factory.build_page_cache] in [factory.mli]. *)
val build_page_cache :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  now:(unit -> float) ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  fs:_ Eio.Path.t ->
  Seekwright.Config.t ->
  (Seekwright.Engine.Fetch.Cache.t option, string) result

(** [Some (entries, body_bytes)] for the directory [fetch.cache_dir] names, [None]
    when it is unset: the figures [--check] prints, read off the same written root
    the served process builds. A diagnosis reads the directory; it does not go
    through the serving path, which is why this is a call of its own rather than a
    field of the seam. *)
val page_cache_stats :
  sw:Eio.Switch.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  fs:_ Eio.Path.t ->
  Seekwright.Config.t ->
  ((int * int) option, string) result
