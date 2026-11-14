(** The disk page cache behind [fetch]: one download per page, many reads.

    Port of [src/seekwright/pagecache.py]. Repeated partial reads of one page —
    an [offset] continuation, a [path] drill, a [query] over the same document —
    each re-download and re-extract without it, and on a named billable fallback
    each is a credit. This module stores a page as
    [<sha256(rung, validated URL)>.body] plus a [.meta.json] sidecar in one
    operator-named directory, so the engine serves the repeats off disk.

    Bounded three ways, because a cache that cannot refuse a page cannot be
    defaulted on: an entry larger than [max_entry_bytes] is never stored; the
    directory is capped at [max_bytes] with LRU eviction; an entry older than
    [ttl_seconds] reads as a miss and is removed on read. Both files of an entry
    go through a temporary name and a rename ({!Mcp_caps.Authority.Fs.atomic_write}),
    so a crash never leaves a half entry visible — and a half entry, the sidecar
    without its body or the reverse, reads as a miss under the same rule.

    Nothing is resident in RAM between calls: a burst of distinct URLs grows the
    directory, never the heap. {!val:get_window} reads only the bytes a paged
    read serves — a chunked walk stopped once [offset + max_chars + 2] codepoints
    are in hand — and hands that head to {!val:Fetcher.window_text}, the {i same}
    function the live fetch cuts its window with, so a cached window is
    byte-identical to the live one and a paged read of a document far larger than
    its window holds the window, not the body. The Python oracle mirrors that cut
    as [_cut] because it may not import [fetcher]; the port has no mirror to keep
    true, and the parity test pins the byte-equality instead. The full body is
    read whole only by {!val:get}, for the selections that need the entire
    document, and is freed after the call.

    {2 The two seams}

    Every operation here is a call on a {!Mcp_caps.Authority.Fs.t} grant over the
    operator's directory: this module holds no path string it opens by itself,
    which is what the negative-compilation pin
    ([test/should_not_compile/cache_write_needs_grant.ml]) keeps true, and it is
    why a test drives the cache with a grant over a temp directory rather than
    with the real one. The clock is injected for the same reason: TTL, [created]
    and the LRU order are all decisions a suite asserts exactly.

    {2 The LRU divergence from the oracle}

    The oracle refreshes a hit with [os.utime] on the body and evicts by the
    body's atime. Eio has no [utimes], and Linux mounts default to [relatime],
    which would not move atime at cache timescales anyway. So the order is
    carried in the sidecar's [accessed] field and a hit rewrites {i the sidecar
    only} — never the body, which is the expensive half and the half eviction
    measures. {!Mcp_caps.Authority.Fs.stat}'s atime is the fallback rank for an entry
    this process did not write. plans/seekwright-ocaml-port.md (F7) records it,
    and [test/test_page_cache.ml] pins that a hit changes [accessed] and leaves
    the body's bytes and size untouched. *)

(** {1 What an entry holds} *)

type cached_page = {
  url : string;
  (** The {i landing} URL the store recorded, so a response built from a hit
      carries the same address a live fetch would have. *)
  title : string option;
  text : string;
  (** The full extraction on an entry built by {!val:put}, and the window to
      serve on one built by {!val:get_window} — the same shape either way,
      because the caller only turns one into a page. *)
  content_type : string option;
  status_code : int;
  path_addressable : bool;
  total_chars : int;
  (** Length of the {i full} extraction in codepoints, whatever this read held. *)
  truncated : bool;
  (** A windowed read's [more_remains]; a full entry leaves it [false]. *)
}

(** {1 The cache} *)

type t

val create :
  fs:Mcp_caps.Authority.Fs.t ->
  ?max_bytes:int ->
  ?max_entry_bytes:int ->
  ?ttl_seconds:float ->
  now:(unit -> float) ->
  unit ->
  t
(** [create ~fs ?max_bytes ?max_entry_bytes ?ttl_seconds ~now ()] speaks through
    a grant over the cache directory. The directory itself is the grant's
    concern: {!Mcp_caps.Policy.with_written_root} creates it (mode [0o700]) or refuses
    at startup, which is where a filesystem fault becomes a refusal to start
    rather than a miss typed lazily all day long.

    The three ceilings default to the oracle's: 256 MiB for the directory, 32 MiB
    per entry, five minutes of freshness. [now] is wall-clock seconds — the same
    clock the journal and [retrieved_at] use, because [created] has to mean
    "when this page was downloaded" to an operator reading the sidecar. *)

val entry_name : rung:string -> url:string -> string
(** One entry's file-name hash, keyed by the route rung and the {i validated} URL.

    The rung is in the key alongside the URL because the local read and a
    fallback's are different answers to the same page and never share an entry;
    the URL is the normalised string {!val:Fetcher.validate_url} returned, not
    the raw spelling a caller wrote, which is where the caller's preflight finds
    it. The NUL keeps the two fields from trading characters across the boundary.
    A hash rather than the URL itself keeps a model-supplied filesystem string
    out of a path. *)

(** {1 Reads} *)

val of_page : Seekwright_wire.Page.page -> cached_page
(** The entry an uncapped read gives: the page record's fields, with no window
    finding. An image page never becomes one — the caller keeps that rule, because
    it is the caller that knows a page {i is} an image. *)

val to_page : cached_page -> Seekwright_wire.Page.page
(** The page an entry gives back, with no image: an entry is a text extraction,
    and the image bypass is why [image] is [None] here rather than a field the
    entry forgot. *)

val get : t -> rung:string -> url:string -> cached_page option
(** The full entry, or [None] — for the reads that select over a page.

    The whole body reads into one string and the caller frees it after its
    selections run; that transient cost is the one a [query]/[path] call already
    pays against a live fetch. Any filesystem or decode fault reads as a miss, so
    a corrupted entry heals by re-fetching rather than failing a page. *)

val get_window :
  t ->
  rung:string ->
  url:string ->
  offset:int ->
  max_chars:int ->
  cached_page option
(** One window of an entry, read by chunk — the path a paged read takes.

    Reads only enough of the body to serve the window at [offset] of [max_chars]
    codepoints, and
    answer "more remains", then applies {!val:Fetcher.window_text} to that head.
    A paged read of a document far larger than the window holds the window, not
    the body — the RSS story the caller's paged reads make is this function's to
    keep. Counts are over the {i decoded} text, never the bytes, because the
    caller's offsets index the extraction.

    A decode or filesystem fault mid-read reads as a miss too. *)

(** {1 Writes} *)

val put : t -> rung:string -> url:string -> page:cached_page -> bool
(** Store one successful text page, atomically; [false] when too large.

    [page] is the {i whole} extraction — the uncapped read the caller is already
    holding on a miss, stored here before the window that call serves is cut back
    out of the entry. The per-entry cap is the first bound: a page above it is
    never an entry, so a hostile page fetched live once costs disk nothing.
    [total_chars] is stored rather than recounted on read — the sidecar is the
    one place the caller gets it without holding the body. A full disk or an
    unwritable directory returns [false] rather than a failure: the page was
    already downloaded and is served with or without an entry. *)

(** {1 Diagnosis} *)

val stats : t -> int * int
(** [entries, body_bytes] — the figures [--check] prints.

    Counts {i bodies}, since the cap is measured over them; a body whose sidecar
    vanished is a miss the read paths already treat as absent, and this figure is
    a diagnosis, not a serving decision. *)
