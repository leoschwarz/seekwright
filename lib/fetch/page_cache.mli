(** Disk page cache: atomic storage and windowed retrieval of fetched pages behind an Authority.Fs
    grant.

    The shape in and out is [Seekwright_wire.Page.page] — the record both halves of the fetch path
    already speak. The cache stores no image, so [image] is always [None] on a read, and [truncated]
    on a read describes the window the read cut, not the entry: a stored page is whole. On disk an
    entry is a [.body] file with the text and a [.meta.json] sidecar with the other fields plus the
    three keys the TTL and eviction rules read ([created], [body_bytes], [accessed]); that sidecar
    is this module's own format, written and read nowhere else, and its null-for-absent convention
    is its own, not the wire boundary's. A sidecar in a shape this build does not recognise is a
    miss, and a miss re-fetches. *)

type t

val create :
  fs:Mcp_caps.Authority.Fs.t ->
  ?max_bytes:int ->
  ?max_entry_bytes:int ->
  ?ttl_seconds:float ->
  now:(unit -> float) ->
  unit ->
  t

val entry_name : rung:string -> url:string -> string

val get : t -> rung:string -> url:string -> Seekwright_wire.Page.page option

val get_window :
  t -> rung:string -> url:string -> offset:int -> max_chars:int -> Seekwright_wire.Page.page option

val put : t -> rung:string -> url:string -> page:Seekwright_wire.Page.page -> bool

val stats : t -> int * int
