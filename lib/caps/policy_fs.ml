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
  max_read_bytes : int;
  max_entries : int;
}

let default_max_read_bytes = 65_536
let default_max_entries = 200

(* A local read inside an opened subtree, so the bound is here for a wedged
   filesystem or a pathological pipe, not for a slow peer — which is why it sits
   well below the network default in policy_net.ml, and still high enough that
   ordinary disk contention cannot make it fire. *)
let default_operation_timeout_seconds = 5.0

let ( / ) = Eio.Path.( / )
let ( >>= ) = Result.bind

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
   [list_dir] wrap one in [Controls.run], which is where the time bound, the
   budget and the audit line come from (§3, §6). Keeping them apart is what stops
   the bounds from being re-implemented per operation. *)
let read_file_body t ~max_bytes path =
  let ( let* ) = Result.bind in
  let limit = ceiling ~grant_max:t.max_read_bytes max_bytes in
  let* target = resolve t.root path in
  let* kind = kind_of ~follow:true ~label:path target >>= classify_kind ~path in
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
  let ( let* ) = Result.bind in
  let limit = ceiling ~grant_max:t.max_entries max_entries in
  let* target = resolve t.root path in
  let* kind = kind_of ~follow:true ~label:path target >>= classify_kind ~path in
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
  Controls.run controls ~operation:"fs.read_file"
    ~measure:(fun content -> Some (String.length content))
    (fun () -> read_file_body t ~max_bytes path)

(* [entries=] is a count, so the audit line stays content-free whatever the
   directory holds; a listing of names would be content, and it is not logged. *)
let list_dir ~controls ?max_entries t path =
  Controls.run controls ~operation:"fs.list_dir"
    ~notes:(fun entries -> [("entries", string_of_int (List.length entries))])
    (fun () -> list_dir_body t ~max_entries path)

let with_root ~sw ?max_read_bytes ?max_entries ~parent name =
  let ( let* ) = Result.bind in
  let* max_read_bytes =
    operator_limit ~name:"max_read_bytes" ~default:default_max_read_bytes max_read_bytes
  in
  let* max_entries = operator_limit ~name:"max_entries" ~default:default_max_entries max_entries in
  open_root ~sw ~parent name >>= fun root -> Ok { root; max_read_bytes; max_entries }

