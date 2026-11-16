(** The fetch half of construction: the extraction backend, the document readers
    the engine selects with, and the local reader with its own web grant. *)

(** Instantiate the extraction backend [[fetch] extractor] names. *)
val build_extractor : Seekwright.Config.t -> (Seekwright_fetch.Extractor.backend, string) result

(** The document readers the fetch engine selects with. *)
val readers : Seekwright.Engine.Fetch.Readers.t

(** [None] when [[fetch] enabled = false]; otherwise the local reader and the
    fallback ladder. *)
val build_fetch_stack :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  Seekwright.Config.t ->
  ((Seekwright.Engine.Fetch.fetcher * Seekwright.Engine.Fetch.fetcher list), string) result option

(** The page cache's seam: [None] when [fetch.cache_dir] is unset, and otherwise
    the operations the fetch engine asks of one directory of entries. A [cache_dir]
    this process cannot create or open is an [Error]. *)
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
