(* The filesystem confinement: one subtree handle, and the bounded operations
   that stay inside it. policy_fs.mli keeps the record abstract, so this is the
   only place a handle becomes a grant, and policy.ml re-exports [with_root] as
   the entry point applications call.

   The tests in test/test_authority_fs.ml are the evidence for the confinement
   half of what the comments below claim: they run against the real backend, on
   both the io_uring and the posix loop, because the refusal of [".."] and of a
   symlink out of the root is [openat2] semantics, not our own check. *)

type t = {
  root : Eio.Fs.dir_ty Eio.Path.t;
  (* Whether this confinement was opened for writing. [with_root] says no and
     every write operation refuses on the spot; [with_written_root] says yes, and
     is what a server holding a writable directory — the page cache — opens. The
     flag is part of the record rather than a property of the operations because
     the record is the thing that outlives the call: a grant made from a
     [with_root] decision cannot be talked into writing by its caller. *)
  writable : bool;
  max_read_bytes : int;
  max_write_bytes : int;
  max_entries : int;
}

let default_max_read_bytes = 65_536
let default_max_write_bytes = 65_536
let default_max_entries = 200

(* A local read inside an opened subtree, so the bound is here for a wedged
   filesystem or a pathological pipe, not for a slow peer — which is why it sits
   well below the network default in policy_net.ml, and still high enough that
   ordinary disk contention cannot make it fire. *)
let default_operation_timeout_seconds = 5.0

let ( / ) = Eio.Path.( / )
let ( let* ) = Result.bind

(* A caller may lower a ceiling, never raise it (§4). Clamping rather than
   refusing keeps [read_file ~max_bytes:1_000_000] working on a small grant —
   it just does not get a megabyte. *)
let ceiling ~grant_max requested =
  match requested with
  | None -> grant_max
  | Some requested -> min grant_max requested

(* An operator limit sets the grant's ceiling, so unlike a caller limit it is
   taken as given. A non-positive one is a construction mistake: saying so at
   startup beats a grant that reads nothing, or reads without a bound. *)
let operator_limit ~name ~default requested =
  match requested with
  | None -> Ok default
  | Some requested when requested <= 0 ->
      Error
        (Error.make Error.Invalid
           ~message:(Printf.sprintf "%s must be a positive count of bytes or entries" name))
  | Some requested -> Ok requested

(* The path grammar a tool caller gets: root-relative, one component at a time.
   Refusing an absolute path, "." and ".." here is an API decision, not the
   security: [Eio.Path.open_subtree] refuses them too, along with symlinks, and
   that is what a test has to prove. Keeping the lexical check anyway is what
   makes [".."] a refusal with a sentence attached instead of a backend-dependent
   [Eio] failure. *)
let max_path_bytes = 4096

let valid_component part =
  match part with
  | "" | "." | ".." -> false
  | _ -> String.for_all (fun char -> Char.code char >= 32 && Char.code char <> 127) part

let resolve root path =
  if String.length path = 0 then Ok root
  else if String.length path > max_path_bytes then
    Error
      (Error.make Error.Invalid
         ~message:(Printf.sprintf "the path is longer than %d bytes" max_path_bytes))
  else if path.[0] = '/' then
    Error
      (Error.make Error.Invalid
         ~message:"paths are relative to the grant root; an absolute path is refused")
  else
    let parts = String.split_on_char '/' path in
    if List.for_all valid_component parts then Ok (List.fold_left ( / ) root parts)
    else
      Error
        (Error.make Error.Invalid
           ~message:
             "a path is root-relative components separated by \"/\": no absolute path, no \".\" \
              or \"..\", no empty component, no control characters")

(* One classification for every Eio failure at this boundary, so no raw Eio
   exception, backtrace, or native path ever reaches a tool result (§3). The
   message names only the path the caller already has. *)
let classify exn ~path =
  match exn with
  (* Cancellation is Eio's control flow, not a tool failure: it propagates. *)
  | Eio.Cancel.Cancelled _ | Eio.Exn.Multiple _ -> raise exn
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
      Error (Error.make Error.Unavailable ~message:(path ^ ": not found under the grant root"))
  | Eio.Io (Eio.Fs.E (Eio.Fs.Permission_denied _), _) ->
      Error
        (Error.make Error.Denied
           ~message:
             (path
             ^ ": refused — it leaves the grant root (a \"..\", an absolute path, or a symlink \
                out of the root)"))
  | Eio.Io (Eio.Fs.E Eio.Fs.Symlink, _) ->
      Error
        (Error.make Error.Denied
           ~message:(path ^ ": refused — a symlink that does not resolve inside the grant root"))
  | Eio.Io (Eio.Fs.E Eio.Fs.File_too_large, _) ->
      Error
        (Error.make Error.Denied ~message:(path ^ ": refused — the file is beyond the root's size limit"))
  | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) ->
      Error (Error.make Error.Failed ~message:(path ^ ": a file already exists where one was needed"))
  | Eio.Io _ -> Error (Error.make Error.Failed ~message:(path ^ ": the read failed"))
  | _ -> raise exn

(* The root is opened once, on the switch that outlives the server. Eio's own
   failure text names the handle's native path, which is the operator's layout
   and not the caller's business, so the message is ours: [name] is a path the
   operator chose, so naming it back leaks nothing. *)
let open_root ~sw ~parent name =
  let refusal =
    Error.make Error.Unavailable
      ~message:
        (Printf.sprintf "the grant root %s could not be opened as a directory"
           (Error.sanitize name))
  in
  try Ok (Eio.Path.open_subtree ~sw (parent / name))
  with
  | Eio.Cancel.Cancelled _ | Eio.Exn.Multiple _ as exn -> raise exn
  | Eio.Io _ -> Error refusal

(* [Eio.Path.kind] reports a missing path as a value rather than an exception,
   and reports a symlink that escapes the root as a [Permission_denied] failure
   — both of which want a different [Error.t] kind than a plain read error. *)
let kind_of ~follow ~label path =
  try Ok (Eio.Path.kind ~follow path) with ex -> classify ex ~path:label

(* A directory, a symlink that does not resolve, and a missing path are all
   refusals to state up front, so [read_file] and [list_dir] never open the
   wrong thing and then explain an [Eio] failure. The check is for the message;
   the open that follows is what is confined, so a rename between the two cannot
   turn it into an escape. *)
let classify_kind kind ~path =
  match (kind :> [ `Regular_file | `Directory | `Symbolic_link | `Not_found | `Fifo | `Socket
                 | `Block_device | `Character_special | `Unknown ])
  with
  | `Not_found -> Error (Error.make Error.Unavailable ~message:(path ^ ": not found under the root"))
  | `Directory -> Ok `Directory
  | `Regular_file -> Ok `Regular_file
  | `Symbolic_link ->
      Error (Error.make Error.Denied ~message:(path ^ ": refused — the symlink does not resolve inside the root"))
  | `Fifo | `Socket | `Block_device | `Character_special | `Unknown ->
      Error (Error.make Error.Invalid ~message:(path ^ ": only regular files and directories are readable"))

(* Bounded read: [Buf_read.of_flow ~max_size] is the ceiling — it stops reading
   and allocates no more than [limit + 1] bytes, so an over-long file is refused
   without being buffered in full. [Eio.Path.load] plus a size check first would
   be the wrong shape: [load] allocates the whole file, and the size a [stat]
   reported is not the size the bytes turn out to have (§4). *)
let read_capped flow limit =
  let reader = Eio.Buf_read.of_flow flow ~max_size:(limit + 1) in
  Eio.Buf_read.take_all reader

(* The two bodies below are the operation logic; the public [read_file] and
   [list_dir] wrap one in [Controls_raw.run], which is where the time bound, the
   budget and the audit line come from (§3, §6). Keeping them apart is what stops
   the bounds from being re-implemented per operation — and keeping [run] in the
   private module is what stops a consumer from calling a body with bounds of its
   own, because the [~controls] argument these signatures take has no producer
   outside a grant. *)
let read_file_body t ~max_bytes path =
  let limit = ceiling ~grant_max:t.max_read_bytes max_bytes in
  let* target = resolve t.root path in
  let* kind = kind_of ~follow:true ~label:path target in
  let* kind = classify_kind ~path kind in
  match kind with
  | `Directory ->
      Error (Error.make Error.Invalid ~message:(path ^ ": that is a directory — list it, do not read it"))
  | `Regular_file -> (
      try
        match Eio.Path.with_open_in target (fun flow -> Ok (read_capped flow limit)) with
        | Ok content -> Ok content
        | Error error -> Error error
      with
      | Eio.Buf_read.Buffer_limit_exceeded ->
          Error
            (Error.make Error.Denied
               ~message:
                 (Printf.sprintf
                    "%s: refused — the file is larger than the %d-byte ceiling (max_bytes may \
                     lower it, never raise it)"
                    path limit))
      | ex -> classify ex ~path)

let list_dir_body t ~max_entries path =
  let limit = ceiling ~grant_max:t.max_entries max_entries in
  let* target = resolve t.root path in
  let* kind = kind_of ~follow:true ~label:path target in
  let* kind = classify_kind ~path kind in
  match kind with
  | `Regular_file ->
      Error (Error.make Error.Invalid ~message:(path ^ ": that is a file — read it, do not list it"))
  | `Directory -> (
      try
        (* Counted as it streams: [Eio.Path.read_dir] builds the whole listing
           first, so the ceiling would then limit only what we report, not what
           we allocate. The count is a counter, not [List.length], so the scan
           stays linear however high the operator sets the ceiling. *)
        let found = ref [] in
        let counted = ref 0 in
        let over = ref false in
        Eio.Path.with_dir_entries target (fun entries ->
          Seq.iter
            (fun (_kind, name) ->
              if !over then ()
              else if !counted >= limit then over := true
              else
                (
                  incr counted;
                  found := name :: !found ))
          entries);
        if !over then
          Error
            (Error.make Error.Denied
               ~message:
                 (Printf.sprintf
                    "%s: refused — the directory holds more than %d entries (max_entries may \
                     lower it, never raise it)"
                    path limit))
        else Ok (List.sort String.compare !found)
      with ex -> classify ex ~path)

let read_file ~controls ?max_bytes t path =
  Controls_raw.run controls ~operation:"fs.read_file"
    ~measure:(fun content -> Some (String.length content))
    (fun () -> read_file_body t ~max_bytes path)

(* [entries=] is a count, so the audit line stays content-free whatever the
   directory holds; a listing of names would be content, and it is not logged. *)
let list_dir ~controls ?max_entries t path =
  Controls_raw.run controls ~operation:"fs.list_dir"
    ~notes:(fun entries -> [("entries", string_of_int (List.length entries))])
    (fun () -> list_dir_body t ~max_entries path)

(* The ceilings one construction call can be given, validated the same way. *)
let ceilings ?max_read_bytes ?max_write_bytes ?max_entries () =
  let* max_read_bytes =
    operator_limit ~name:"max_read_bytes" ~default:default_max_read_bytes max_read_bytes
  in
  let* max_write_bytes =
    operator_limit ~name:"max_write_bytes" ~default:default_max_write_bytes max_write_bytes
  in
  let* max_entries = operator_limit ~name:"max_entries" ~default:default_max_entries max_entries in
  Ok (max_read_bytes, max_write_bytes, max_entries)

let with_root ~sw ?max_read_bytes ?max_entries ~parent name =
  match ceilings ?max_read_bytes ?max_entries () with
  | Error error -> Error error
  | Ok (max_read_bytes, max_write_bytes, max_entries) -> (
      match open_root ~sw ~parent name with
      | Error error -> Error error
      | Ok root -> Ok { root; writable = false; max_read_bytes; max_write_bytes; max_entries })

(* A directory the server owns — the page cache is the case that exists today — is
   opened for writing, which means creating it when it is missing: an operator who
   names [fetch.cache_dir] expects the server to make the directory and to say so
   at startup if it cannot, not to fail at the first store. [mkdirs ~exists_ok] is
   the whole of the create half; the confinement half is the same [open_subtree]
   call [with_root] makes, so a written root is confined exactly as a read-only
   one is, and test/test_authority_fs.ml runs the write cases against both
   backends.

   The mode is [0o700]: this directory holds page text the server fetched, and on
   a shared host the group and the world have no business reading it. *)
let open_written_root ~sw ~parent name =
  match
    try Ok (Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (parent / name))
    with
    | Eio.Cancel.Cancelled _ | Eio.Exn.Multiple _ as exn -> raise exn
    | Eio.Io _ ->
        Error
          (Error.make Error.Unavailable
             ~message:
               (Printf.sprintf "the writable root %s could not be created as a directory"
                  (Error.sanitize name)))
  with
  | Error error -> Error error
  | Ok () -> open_root ~sw ~parent name

let with_written_root ~sw ?max_read_bytes ?max_write_bytes ?max_entries ~parent name =
  match ceilings ?max_read_bytes ?max_write_bytes ?max_entries () with
  | Error error -> Error error
  | Ok (max_read_bytes, max_write_bytes, max_entries) -> (
      match open_written_root ~sw ~parent name with
      | Error error -> Error error
      | Ok root -> Ok { root; writable = true; max_read_bytes; max_write_bytes; max_entries })

(* Every write answers two questions before it touches the backend: may this
   confinement write at all, and is the payload inside the grant's ceiling. The
   first is a property of the decision, so it is a [Denied], and it is answered
   before any file is opened — a read-only root never ends up with a [.tmp] in it. *)
let not_writable path =
  Error
    (Error.make Error.Denied
       ~message:(path ^ ": refused — this grant's root is read-only (it was opened by Policy.with_root)"))

let writable t path = if t.writable then Ok () else not_writable path

(* A write ceiling is a ceiling of the same kind as a read ceiling: a caller may
   lower it, never raise it. *)
let write_body t ~max_bytes path ~contents =
  let* () = writable t path in
  let limit = ceiling ~grant_max:t.max_write_bytes max_bytes in
  if String.length contents > limit then
    Error
      (Error.make Error.Denied
         ~message:
           (Printf.sprintf
              "%s: refused — %d bytes is beyond the %d-byte write ceiling (max_bytes may lower \
               it, never raise it)"
              path (String.length contents) limit))
  else
    let* target = resolve t.root path in
    (* Atomic replacement in the order that makes a crash cheap: write the whole
       payload to a name no reader looks at, then [rename] it into place. A crash
       leaves either the old file or the new one at [path], never a half-written
       one. The temp name carries a process-local counter because two writers of
       one path must not share a temp file, and [`Exclusive] is what makes sharing
       one impossible rather than merely unlikely: the loser's [save] fails and it
       takes the next number. *)
    let rec attempt n =
      match resolve t.root (Printf.sprintf "%s.tmp%d" path n) with
      | Error error -> Error error
      | Ok temp -> (
          match
            try
              Eio.Path.save ~create:(`Exclusive 0o600) temp contents;
              Ok ()
            with
            | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) when n < 8 -> Error `busy
            | ex -> Error (`other ex)
          with
          | Error `busy -> attempt (n + 1)
          | Error (`other ex) -> classify ex ~path
          | Ok () -> (
              match (try Ok (Eio.Path.rename temp target) with ex -> classify ex ~path) with
              | Ok () -> Ok ()
              | Error error ->
                  (* The payload is stuck at a name nothing reads; remove it, so a
                     failed write does not litter the root. *)
                  (try ignore (Eio.Path.unlink ~missing_ok:true temp) with _ -> ());
                  Error error))
    in
    attempt 1

let atomic_write ~controls ?max_bytes t ~path ~contents =
  Controls_raw.run controls ~operation:"fs.atomic_write"
    ~measure:(fun () -> Some (String.length contents))
    (fun () -> write_body t ~max_bytes path ~contents)

(* A positional read, which is what lets a caller look at the middle of a large
   file without reading the whole thing: [Eio.File.pread] reads [limit] bytes from
   [offset] and allocates only those. [read_file] refuses a file over its ceiling
   because a tool that asked for a file and got half of it would be reading a
   document nobody named; a range read is the opposite shape — the caller asked
   for a window — so it returns what is there plus [more], the flag that says
   bytes follow. An [offset] at or past the end is an empty window with [more =
   false], not a failure: it is the ordinary answer for a caller walking to the
   end of a document. *)
let read_range_body t ~max_bytes ~offset path =
  let limit = ceiling ~grant_max:t.max_read_bytes max_bytes in
  let* target = resolve t.root path in
  let* kind = kind_of ~follow:true ~label:path target in
  let* kind = classify_kind ~path kind in
  match kind with
  | `Directory ->
      Error (Error.make Error.Invalid ~message:(path ^ ": that is a directory — list it, do not read it"))
  | `Regular_file -> (
      try
        Eio.Path.with_open_in target (fun flow ->
          let size = Optint.Int63.to_int (Eio.File.size flow) in
          if offset >= size then Ok ("", false)
          else
            let want = min limit (size - offset) in
            let buffer = Cstruct.create want in
            Eio.File.pread_exact flow ~file_offset:(Optint.Int63.of_int offset) [buffer];
            let got = Cstruct.to_string buffer in
            Ok (got, size - (offset + String.length got) > 0))
      with ex -> classify ex ~path)

let read_range ~controls ?max_bytes t ~offset path =
  Controls_raw.run controls ~operation:"fs.read_range"
    ~measure:(fun (content, _more) -> Some (String.length content))
    ~notes:(fun (_content, more) -> [("offset", string_of_int offset); ("more", string_of_bool more)])
    (fun () -> read_range_body t ~max_bytes ~offset path)

(* The metadata the eviction pass needs: how big an entry is, and when it was last
   touched. [atime] is the mount's, so it is a fallback rather than a counter —
   the cache keeps its own access clock in the sidecar, and this is the number a
   foreign entry (one this process did not write) is ranked by. *)
let stat_body t path =
  let* target = resolve t.root path in
  try
    let info = Eio.Path.stat ~follow:true target in
    Ok (Optint.Int63.to_int info.Eio.File.Stat.size, info.Eio.File.Stat.atime)
  with ex -> classify ex ~path

let stat ~controls t path =
  Controls_raw.run controls ~operation:"fs.stat"
    ~notes:(fun (size, _atime) -> [("size", string_of_int size)])
    (fun () -> stat_body t path)

(* Removal is idempotent: eviction races readers and other processes, and an entry
   that vanished between choosing it and removing it has already been removed
   successfully. The confinement is [openat2] again — the [unlinkat] runs against
   the subtree handle — so a [".."] cannot remove anything outside the root. *)
let unlink_body t path =
  let* () = writable t path in
  let* target = resolve t.root path in
  try Ok (Eio.Path.unlink ~missing_ok:true target) with ex -> classify ex ~path

let unlink ~controls t path =
  Controls_raw.run controls ~operation:"fs.unlink" (fun () -> unlink_body t path)

