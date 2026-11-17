module Caps = Mcp_caps
module Fs = Caps.Authority.Fs

let ( let* ) = Result.bind

(* Window cut lookahead: 1 char for cut plus 1 char to detect remaining content. *)
let window_lookahead = 2

let body_suffix = ".body"

let meta_suffix = ".meta.json"

(** Streaming read size; only the head, never the whole body, is held. It has to fit the grant's
    read ceiling, which is what the factory's written root sets above the per-entry cap. *)
let chunk_bytes = 65_536

(** The directory cap, 256 MiB: room for pages by the hundred, small enough that a burst of large
    pages cannot fill a disk. *)
let default_max_bytes = 268_435_456

(** The per-entry cap, 32 MiB: a page above it is never stored, so it is fetched live on every read
    rather than staking a lifetime of disk. *)
let default_max_entry_bytes = 33_554_432

(** The default freshness window: five minutes is a page a caller pagers over, not an archive; an
    operator who wants longer sets [cache_ttl_seconds]. *)
let default_ttl_seconds = 300.0

let entry_name ~rung ~url = Digestif.SHA256.(to_hex (digest_string (rung ^ "\000" ^ url)))

(* The sidecar is the cache's own record: the page's fields the body file does not
   carry — [text] is the body, [image] is never stored and [truncated] is never
   stored because a stored page is whole and a windowed read reports the truncation
   of the window it cut — plus the three cache-only keys. It is one record with one
   encoder and one decoder; the field names used to be spelled in the entry type,
   in both conversions, in the writer and in the reader. *)
type sidecar = {
  url : string;
  title : string option;
  content_type : string option;
  status_code : int;
  path_addressable : bool;
  total_chars : int;
  created : float;
  body_bytes : int;
  accessed : float;
}

type t = {
  fs : Fs.t;
  max_bytes : int;
  max_entry_bytes : int;
  ttl_seconds : float;
  now : unit -> float;
  evictions : Eio.Mutex.t;
}

let create ~fs ?(max_bytes = default_max_bytes) ?(max_entry_bytes = default_max_entry_bytes)
    ?(ttl_seconds = default_ttl_seconds) ~(now : unit -> float) () =
  { fs; max_bytes; max_entry_bytes; ttl_seconds; now; evictions = Eio.Mutex.create () }

(* What a caller hands the cache is the shape the fetch path already speaks. The
   sidecar drops that page's [text] (the body file's whole content), its [image]
   and its [truncated]; [body_bytes] is the length the entry was written with,
   which no read path consumes — it is there for an operator reading the directory,
   and it is required, so a body edited out of band does not read as a
   well-formed entry. *)
let sidecar_of_page (page : Seekwright_wire.Page.page) ~(created : float) : sidecar =
  {
    url = page.url;
    title = page.title;
    content_type = page.content_type;
    status_code = page.status_code;
    path_addressable = page.path_addressable;
    total_chars = page.total_chars;
    created;
    body_bytes = String.length page.text;
    accessed = created;
  }

(* The entry a read hands back: the sidecar's fields, the text this read produced,
   and the truncation of the window that produced it. [image] is always [None]. *)
let entry_of_sidecar (s : sidecar) ~text ~truncated : Seekwright_wire.Page.page =
  {
    url = s.url;
    title = s.title;
    text;
    content_type = s.content_type;
    status_code = s.status_code;
    truncated;
    total_chars = s.total_chars;
    path_addressable = s.path_addressable;
    image = None;
  }

let body_name name = name ^ body_suffix
let meta_name name = name ^ meta_suffix

(* UTF-8 walking, in place of Python's incremental decoder.

   [walk text limit] counts complete codepoints from the front of [text] and stops
   at [limit] of them, reporting the byte index it reached. It answers [Invalid] for
   bytes no UTF-8 decoder accepts — the same fault that makes the oracle's
   [UnicodeDecodeError] a miss here, so a corrupted entry heals by re-fetching
   instead of serving mojibake. [Truncated at] says the buffer ends part-way through
   a sequence and [at] is where that sequence starts: {!val:read_head} carries those
   bytes into the next chunk, which is what lets a 64 KiB chunk boundary fall inside
   a codepoint without losing it or calling the body corrupt. *)
let walk (text : string) (limit : int) :
    [ `Stopped of int * int | `Complete of int * int | `Truncated of int | `Invalid ] =
  let len = String.length text in
  let i = ref 0 in
  let seen = ref 0 in
  let bad = ref false in
  let cut = ref (-1) in
  (* The inner scan is a loop over indices, not a recursive helper: [walk] runs over
     every byte of the head a paged read takes, so a closure per codepoint would
     cost the head again in the minor heap — and what a paged read allocates is the
     promise [get_window] makes. *)
  while !i < len && !seen < limit && (not !bad) && !cut < 0 do
    let lead = Char.code text.[!i] in
    (* A continuation byte in lead position, [C0]/[C1] (overlong), or [F5].. (out of
       range) is [width = 0]: no decoder takes it. *)
    let width =
      if lead < 0x80 then 1
      else if lead >= 0xC2 && lead <= 0xDF then 2
      else if lead >= 0xE0 && lead <= 0xEF then 3
      else if lead >= 0xF0 && lead <= 0xF4 then 4
      else 0
    in
    if width = 0 then bad := true
    else if !i + width > len then cut := !i
    else begin
      let k = ref 1 in
      let whole = ref true in
      while !whole && !k < width do
        let at = !i + !k in
        if Char.code text.[at] land 0xC0 = 0x80 then incr k else whole := false
      done;
      if not !whole then bad := true
      else begin
        i := !i + width;
        incr seen
      end
    end
  done;
  if !bad then `Invalid
  else if !seen >= limit then `Stopped (!seen, !i)
  else if !cut >= 0 then `Truncated !cut
  else `Complete (!seen, len)

(* A whole body has to end on a codepoint boundary, so [walk] reaching the end of
   the text is the only shape that says valid: [Truncated] there is a body cut in
   mid-sequence, and [Invalid] is the corrupt one. *)
let is_valid_utf8 text = match walk text max_int with `Complete _ -> true | _ -> false

(* The sidecar's null-for-absent convention is the cache's own, not the wire
   boundary's: the absent-field rule of [lib/wire] does not reach a file this
   module both writes and reads, and a reader has to tell "this page has no title"
   from "this sidecar is not one". The decoder refuses a shape it does not know —
   a missing or mistyped key is a miss, never a default — which is what makes a
   half write from an older build heal by re-fetching. *)
let sidecar_to_yojson (s : sidecar) : Yojson.Safe.t =
  `Assoc
    [
      ("url", `String s.url);
      ("title", match s.title with None -> `Null | Some title -> `String title);
      ("content_type", match s.content_type with None -> `Null | Some t -> `String t);
      ("status_code", `Int s.status_code);
      ("path_addressable", `Bool s.path_addressable);
      ("total_chars", `Int s.total_chars);
      ("created", `Float s.created);
      ("body_bytes", `Int s.body_bytes);
      ("accessed", `Float s.accessed);
    ]

let req_str fields key =
  match List.assoc_opt key fields with Some (`String v) -> Ok v | _ -> Error ()

let req_int fields key =
  match List.assoc_opt key fields with Some (`Int v) -> Ok v | _ -> Error ()

let req_float fields key =
  match List.assoc_opt key fields with Some (`Float v) -> Ok v | _ -> Error ()

let req_bool fields key =
  match List.assoc_opt key fields with Some (`Bool v) -> Ok v | _ -> Error ()

let opt_str fields key =
  match List.assoc_opt key fields with Some (`String v) -> Ok (Some v) | _ -> Ok None

let sidecar_of_fields (fields : (string * Yojson.Safe.t) list) : sidecar option =
  let found =
    let* url = req_str fields "url" in
    let* title = opt_str fields "title" in
    let* content_type = opt_str fields "content_type" in
    let* status_code = req_int fields "status_code" in
    let* path_addressable = req_bool fields "path_addressable" in
    let* total_chars = req_int fields "total_chars" in
    let* created = req_float fields "created" in
    let* body_bytes = req_int fields "body_bytes" in
    let* accessed = req_float fields "accessed" in
    Ok
      {
        url;
        title;
        content_type;
        status_code;
        path_addressable;
        total_chars;
        created;
        body_bytes;
        accessed;
      }
  in
  Result.to_option found

(* One entry's sidecar, with expired entries removed: the pre-body check.

   Both read paths apply this before touching the body — an expired entry is a
   miss whatever the body still holds, and a truncated or foreign sidecar is as
   good as an absent one, so the entry is removed and the caller re-fetches. *)
let read_meta t name =
  match Fs.read_file t.fs (meta_name name) with
  | Error _ -> None
  | Ok text -> (
      match try Ok (Yojson.Safe.from_string text) with _ -> Error () with
      | Error () -> None
      | Ok (`Assoc fields) -> (
          match sidecar_of_fields fields with
          | None -> None
          | Some entry ->
              if t.now () -. entry.created > t.ttl_seconds then begin
                ignore (Fs.unlink t.fs (body_name name));
                ignore (Fs.unlink t.fs (meta_name name));
                None
              end
              else Some entry)
      | Ok _ -> None)

(* LRU currency: the divergence the interface states. A hit refreshes the
   sidecar's [accessed] and never rewrites the body, which is the half eviction
   measures and the half a rewrite would cost. *)
let touch t name (entry : sidecar) =
  ignore
    (Fs.atomic_write t.fs ~path:(meta_name name)
       ~contents:(Yojson.Safe.to_string (sidecar_to_yojson { entry with accessed = t.now () })))

let get t ~rung ~url =
  let name = entry_name ~rung ~url in
  match read_meta t name with
  | None -> None
  | Some entry -> (
      match Fs.read_file ~max_bytes:t.max_entry_bytes t.fs (body_name name) with
      | Error _ -> None
      | Ok text when not (is_valid_utf8 text) -> None
      | Ok text ->
          touch t name entry;
          Some (entry_of_sidecar entry ~text ~truncated:false))

(* The head a windowed read needs: the first [want] codepoints of the body, or the
   body entire when it is shorter, read a chunk at a time. Each chunk is walked once
   where the accumulated buffer would be walked again from its front every time,
   which is a body-sized rescan per chunk; [carry] is the sequence the last chunk
   ended inside, and carrying it is what makes a 64 KiB boundary inside a codepoint
   a detail of the read rather than a corrupt body. [None] is the missing,
   unreadable or undecodable body — a miss, whatever the reason, so a damaged entry
   heals by re-fetching. *)
let read_head t name ~want =
  let head = Buffer.create chunk_bytes in
  let rec go seen pos carry =
    if seen >= want then Some (Buffer.contents head)
    else
      match Fs.read_range ~max_bytes:chunk_bytes t.fs ~offset:pos (body_name name) with
      | Error _ -> None
      | Ok (chunk, more) -> (
          if chunk = "" then if more then None else Some (Buffer.contents head)
          else
            let part = if String.equal carry "" then chunk else carry ^ chunk in
            let next = pos + String.length chunk in
            match walk part (want - seen) with
            | `Stopped (_count, at) ->
                Buffer.add_substring head part 0 at;
                Some (Buffer.contents head)
            | `Invalid -> None
            | `Complete (count, at) ->
                Buffer.add_substring head part 0 at;
                if more then go (seen + count) next "" else Some (Buffer.contents head)
            | `Truncated at ->
                if not more then None
                else begin
                  Buffer.add_substring head part 0 at;
                  go seen next (String.sub part at (String.length part - at))
                end)
  in
  go 0 0 ""

let get_window t ~rung ~url ~offset ~max_chars =
  let name = entry_name ~rung ~url in
  match read_meta t name with
  | None -> None
  | Some entry -> (
      (* The load-bearing part of the streaming promise: the bytes read are the
         bytes allocated, so looking at the middle of a large document costs the
         window. [want] is the oracle's [offset + max_chars + _WINDOW_LOOKAHEAD]
         codepoints, and the walk stops at the first chunk boundary past them. *)
      let want = offset + max_chars + window_lookahead in
      match read_head t name ~want with
      | None -> None
      | Some head ->
          (* [window_text] derives its total from the string it is given, and a head of
             [want] codepoints reports [offset + cut < total] wherever the whole body
             does — the window plus its one-codepoint probe always fits inside [want],
             and a body shorter than [want] arrives entire. So the cut it makes is the
             cut a live read of the whole page makes: the parity the oracle keeps with
             its [_cut] mirror, and what [test/test_page_cache.ml] pins over a sweep of
             bodies, offsets and caps. *)
          let window, truncated = Fetcher.window_text head ~offset ~max_chars in
          touch t name entry;
          Some (entry_of_sidecar entry ~text:window ~truncated))

(* The directory's entry stems — the name without [.body], which is what
   [body_name] and [meta_name] build a path from. The cap is measured over bodies,
   so a body whose sidecar vanished still counts here and is a miss on the read
   paths. *)
let list_bodies t =
  match Fs.list_dir t.fs "" with
  | Ok names ->
      List.filter_map
        (fun name ->
          if Filename.check_suffix name body_suffix then
            Some (String.sub name 0 (String.length name - String.length body_suffix))
          else None)
        names
  | Error _ -> []

let entry_rank t name =
  (* One body's size, and when the cache last read it. The size comes from [stat],
     because deciding what to throw away must not first read what it is throwing
     away; the recency comes from the sidecar's [accessed], with the filesystem's
     own atime as the rank for an entry this process did not write. *)
  match Fs.stat t.fs (body_name name) with
  | Error _ -> None
  | Ok info ->
      let accessed =
        match read_meta t name with Some entry -> entry.accessed | None -> info.Fs.accessed_at
      in
      Some (accessed, info.Fs.size_bytes, name)

let evict_to_cap t =
  (* Unlink the least-recently-read entries until the directory is under the cap.

     A caller's own entry is the most-recently-read thing on disk, so this never
     deletes what was just written before anything older. Bodies and sidecars die
     together per entry, and the byte counts are read off the bodies — the size a
     visitor measures the directory by. *)
  let ranked = List.filter_map (entry_rank t) (list_bodies t) in
  let total = List.fold_left (fun total (_accessed, size, _name) -> total + size) 0 ranked in
  if total <= t.max_bytes then ()
  else
    let sorted =
      List.sort
        (fun (a, _sa, na) (b, _sb, nb) ->
          match Float.compare a b with 0 -> String.compare na nb | c -> c)
        ranked
    in
    let remaining = ref total in
    List.iter
      (fun (_accessed, size, name) ->
        if !remaining > t.max_bytes then begin
          ignore (Fs.unlink t.fs (body_name name));
          ignore (Fs.unlink t.fs (meta_name name));
          remaining := !remaining - size
        end)
      sorted

let put t ~rung ~url ~(page : Seekwright_wire.Page.page) =
  let body = page.text in
  if String.length body > t.max_entry_bytes then false
  else
    let name = entry_name ~rung ~url in
    let created = t.now () in
    (* Both halves are written through a temporary name and a rename: a reader can
       only ever see the placed file or the old one, whatever order the two
       renames land in. [atomic_write] cleans up its own temporary, so a half pair
       is as good as a miss on both read paths and the losing temporary only has
       to stop existing. *)
    let writes =
      let* () =
        Fs.atomic_write t.fs ~max_bytes:t.max_entry_bytes ~path:(body_name name) ~contents:body
      in
      Fs.atomic_write t.fs ~path:(meta_name name)
        ~contents:(Yojson.Safe.to_string (sidecar_to_yojson (sidecar_of_page page ~created)))
    in
    match writes with
    | Error _ -> false
    | Ok () ->
        (* Eviction lists and unlinks concurrently with reads and writes; one
           in-process lock serialises those, and atomic writes already mean a
           reader never sees a half entry whatever this lock does. *)
        Eio.Mutex.use_rw ~protect:true t.evictions (fun () -> evict_to_cap t);
        true

let stats t =
  let bodies = list_bodies t in
  let total =
    List.fold_left
      (fun total name ->
        match Fs.stat t.fs (body_name name) with
        | Ok info -> total + info.Fs.size_bytes
        | Error _ -> total)
      0 bodies
  in
  (List.length bodies, total)
