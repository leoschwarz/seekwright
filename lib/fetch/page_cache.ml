(* page_cache.mli states the contract; this file is the entry format, the two
   read paths, and the three bounds. Port of [src/seekwright/pagecache.py]'s
   [DiskPageCache].

   Every byte goes through an [Authority.Fs] grant: this module never opens a
   path of its own, so the confinement the cache lives under is the confinement
   the capability layer decided at startup, and the negative-compilation pin
   keeps it that way. *)

module Caps = Mcp_caps
module Fs = Caps.Authority.Fs

let ( let* ) = Result.bind

(* [window_text] looks at [[offset, offset + max_chars + 1]] for its cut, and one
   codepoint past that answers "more remains" without a second read. *)
let window_lookahead = 2

let body_suffix = ".body"

let meta_suffix = ".meta.json"

let chunk_bytes = 65_536
(** Streaming read size; only the head, never the whole body, is held. It has to
    fit the grant's read ceiling, which is what the factory's written root sets
    above the per-entry cap. *)

let default_max_bytes = 268_435_456
(** The directory cap, 256 MiB: room for pages by the hundred, small enough that
    a burst of large pages cannot fill a disk. *)

let default_max_entry_bytes = 33_554_432
(** The per-entry cap, 32 MiB: a page above it is never stored, so it is fetched
    live on every read rather than staking a lifetime of disk. *)

let default_ttl_seconds = 300.0
(** The default freshness window: five minutes is a page a caller pagers over,
    not an archive; an operator who wants longer sets [cache_ttl_seconds]. *)

let entry_name ~rung ~url =
  Digestif.SHA256.(to_hex (digest_string (rung ^ "\000" ^ url)))

type cached_page = {
  url : string;
  title : string option;
  text : string;
  content_type : string option;
  status_code : int;
  path_addressable : bool;
  total_chars : int;
  truncated : bool;
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

let of_page (page : Seekwright_wire.Page.page) : cached_page = {
  url = page.url;
  title = page.title;
  text = page.text;
  content_type = page.content_type;
  status_code = page.status_code;
  path_addressable = page.path_addressable;
  total_chars = page.total_chars;
  truncated = false;
}

let to_page (entry : cached_page) : Seekwright_wire.Page.page = {
  url = entry.url;
  title = entry.title;
  text = entry.text;
  content_type = entry.content_type;
  status_code = entry.status_code;
  truncated = entry.truncated;
  total_chars = entry.total_chars;
  path_addressable = entry.path_addressable;
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
  while !i < len && !seen < limit && not !bad && !cut < 0 do
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
        if (Char.code text.[at] land 0xC0) = 0x80 then incr k else whole := false
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
let is_valid_utf8 text =
  match walk text max_int with `Complete _ -> true | _ -> false

(* {1 The sidecar} *)

(* The sidecar is this module's own record, written by [put] and read back by the
   two read paths; the only foreign file it has to survive is a half write from an
   older build, which reads as a miss. *)
let meta_of (page : cached_page) ~(created : float) =
  `Assoc
    [
      ("url", `String page.url);
      ("title", (match page.title with None -> `Null | Some title -> `String title));
      ("content_type", (match page.content_type with None -> `Null | Some t -> `String t));
      ("status_code", `Int page.status_code);
      ("path_addressable", `Bool page.path_addressable);
      ("total_chars", `Int page.total_chars);
      ("created", `Float created);
      ("body_bytes", `Int (String.length page.text));
      ("accessed", `Float created);
    ]

let meta_str fields key =
  match List.assoc_opt key fields with Some (`String v) -> Some v | _ -> None

let meta_int fields key =
  match List.assoc_opt key fields with Some (`Int v) -> v | _ -> 0

let meta_float fields key default =
  match List.assoc_opt key fields with Some (`Float v) -> v | _ -> default

let meta_bool fields key = List.assoc_opt key fields = Some (`Bool true)

(* One entry's sidecar, with expired entries removed: the pre-body check.

   Both read paths apply this before touching the body — an expired entry is a
   miss whatever the body still holds, and a truncated or foreign sidecar is as
   good as an absent one, so the entry is removed and the caller re-fetches. *)
let read_meta t name =
  match Fs.read_file t.fs (meta_name name) with
  | Error _ -> None
  | Ok text -> (
      match (try Ok (Yojson.Safe.from_string text) with _ -> Error ()) with
      | Error () -> None
      | Ok (`Assoc fields) -> (
          match List.assoc_opt "created" fields with
          | Some (`Float created) ->
              if t.now () -. created > t.ttl_seconds
              then begin
                ignore (Fs.unlink t.fs (body_name name));
                ignore (Fs.unlink t.fs (meta_name name));
                None
              end
              else Some fields
          | _ -> None)
      | Ok _ -> None)

(* LRU currency: the divergence the interface states. A hit refreshes the
   sidecar's [accessed] and never rewrites the body, which is the half eviction
   measures and the half a rewrite would cost. *)
let touch t name fields =
  let set key value fields =
    let rec go = function
      | [] -> [ (key, value) ]
      | (k, _) as row :: rest -> if k = key then (k, value) :: rest else row :: go rest
    in
    go fields
  in
  let fields = set "accessed" (`Float (t.now ())) fields in
  ignore (Fs.atomic_write t.fs ~path:(meta_name name) ~contents:(Yojson.Safe.to_string (`Assoc fields)))

(* {1 The reads} *)

let page_of_fields fields ~url ~text ~truncated =
  {
    url = (match meta_str fields "url" with Some u -> u | None -> url);
    title = meta_str fields "title";
    text;
    content_type = meta_str fields "content_type";
    status_code = meta_int fields "status_code";
    path_addressable = meta_bool fields "path_addressable";
    total_chars = meta_int fields "total_chars";
    truncated;
  }

let get t ~rung ~url =
  let name = entry_name ~rung ~url in
  match read_meta t name with
  | None -> None
  | Some fields -> (
      match Fs.read_file ~max_bytes:t.max_entry_bytes t.fs (body_name name) with
      | Error _ -> None
      | Ok text when not (is_valid_utf8 text) -> None
      | Ok text ->
          touch t name fields;
          Some (page_of_fields fields ~url ~text ~truncated:false))

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
      | Ok (chunk, more) ->
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
                end
  in
  go 0 0 ""

let get_window t ~rung ~url ~offset ~max_chars =
  let name = entry_name ~rung ~url in
  match read_meta t name with
  | None -> None
  | Some fields -> (
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
          touch t name fields;
          Some (page_of_fields fields ~url ~text:window ~truncated))

(* {1 The bounds} *)

(* The directory's entry stems — the name without [.body], which is what
   [body_name] and [meta_name] build a path from. The cap is measured over bodies,
   so a body whose sidecar vanished still counts here and is a miss on the read
   paths. *)
let list_bodies t =
  match Fs.list_dir t.fs "" with
  | Ok names ->
      List.filter_map
        (fun name ->
          if Filename.check_suffix name body_suffix
          then Some (String.sub name 0 (String.length name - String.length body_suffix))
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
        match read_meta t name with
        | Some fields -> meta_float fields "accessed" info.Fs.accessed_at
        | None -> info.Fs.accessed_at
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
  if total <= t.max_bytes
  then ()
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
        if !remaining > t.max_bytes
        then begin
          ignore (Fs.unlink t.fs (body_name name));
          ignore (Fs.unlink t.fs (meta_name name));
          remaining := !remaining - size
        end)
      sorted

(* {1 The write} *)

let put t ~rung ~url ~(page : cached_page) =
  let body = page.text in
  if String.length body > t.max_entry_bytes
  then false
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
        ~contents:(Yojson.Safe.to_string (meta_of page ~created))
    in
    match writes with
    | Error _ -> false
    | Ok () ->
        (* Eviction lists and unlinks concurrently with reads and writes; one
           in-process lock serialises those, and atomic writes already mean a
           reader never sees a half entry whatever this lock does. *)
        Eio.Mutex.use_rw ~protect:true t.evictions (fun () -> evict_to_cap t);
        true

(* {1 Diagnosis} *)

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
