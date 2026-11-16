type t = {
  root : Eio.Fs.dir_ty Eio.Path.t;
  writable : bool;
  max_read_bytes : int;
  max_write_bytes : int;
  max_entries : int;
}

let default_max_read_bytes = 65_536
let default_max_write_bytes = 65_536
let default_max_entries = 200
let default_operation_timeout_seconds = 5.0

let ( / ) = Eio.Path.( / )
let ( let* ) = Result.bind

(* Ceiling clamp: callers may lower limits, never raise them. *)
let ceiling ~grant_max requested =
  match requested with None -> grant_max | Some requested -> min grant_max requested

let operator_limit ~name ~default requested =
  match requested with
  | None -> Ok default
  | Some requested when requested <= 0 ->
      Error
        (Error.make Error.Invalid
           ~message:(Printf.sprintf "%s must be a positive count of bytes or entries" name))
  | Some requested -> Ok requested

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
             "a path is root-relative components separated by \"/\": no absolute path, no \".\" or \
              \"..\", no empty component, no control characters")

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
            ^ ": refused — it leaves the grant root (a \"..\", an absolute path, or a symlink out \
               of the root)"))
  | Eio.Io (Eio.Fs.E Eio.Fs.Symlink, _) ->
      Error
        (Error.make Error.Denied
           ~message:(path ^ ": refused — a symlink that does not resolve inside the grant root"))
  | Eio.Io (Eio.Fs.E Eio.Fs.File_too_large, _) ->
      Error
        (Error.make Error.Denied
           ~message:(path ^ ": refused — the file is beyond the root's size limit"))
  | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) ->
      Error
        (Error.make Error.Failed ~message:(path ^ ": a file already exists where one was needed"))
  | Eio.Io _ -> Error (Error.make Error.Failed ~message:(path ^ ": the read failed"))
  | _ -> raise exn

let open_root ~sw ~parent name =
  let refusal =
    Error.make Error.Unavailable
      ~message:
        (Printf.sprintf "the grant root %s could not be opened as a directory" (Error.sanitize name))
  in
  try Ok (Eio.Path.open_subtree ~sw (parent / name)) with
  | (Eio.Cancel.Cancelled _ | Eio.Exn.Multiple _) as exn -> raise exn
  | Eio.Io _ -> Error refusal

let kind_of ~follow ~label path =
  try Ok (Eio.Path.kind ~follow path) with ex -> classify ex ~path:label

let classify_kind kind ~path =
  match
    (kind
      :> [ `Regular_file
         | `Directory
         | `Symbolic_link
         | `Not_found
         | `Fifo
         | `Socket
         | `Block_device
         | `Character_special
         | `Unknown ])
  with
  | `Not_found ->
      Error (Error.make Error.Unavailable ~message:(path ^ ": not found under the root"))
  | `Directory -> Ok `Directory
  | `Regular_file -> Ok `Regular_file
  | `Symbolic_link ->
      Error
        (Error.make Error.Denied
           ~message:(path ^ ": refused — the symlink does not resolve inside the root"))
  | `Fifo | `Socket | `Block_device | `Character_special | `Unknown ->
      Error
        (Error.make Error.Invalid
           ~message:(path ^ ": only regular files and directories are readable"))

(* [Buf_read.of_flow ~max_size]: stops reading at bound before allocating body. *)
let read_capped flow limit =
  let reader = Eio.Buf_read.of_flow flow ~max_size:(limit + 1) in
  Eio.Buf_read.take_all reader

let read_file_body t ~max_bytes path =
  let limit = ceiling ~grant_max:t.max_read_bytes max_bytes in
  let* target = resolve t.root path in
  let* kind = kind_of ~follow:true ~label:path target in
  let* kind = classify_kind ~path kind in
  match kind with
  | `Directory ->
      Error
        (Error.make Error.Invalid
           ~message:(path ^ ": that is a directory — list it, do not read it"))
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
      Error
        (Error.make Error.Invalid ~message:(path ^ ": that is a file — read it, do not list it"))
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
                else (
                  incr counted;
                  found := name :: !found))
              entries);
        if !over then
          Error
            (Error.make Error.Denied
               ~message:
                 (Printf.sprintf
                    "%s: refused — the directory holds more than %d entries (max_entries may lower \
                     it, never raise it)"
                    path limit))
        else Ok (List.sort String.compare !found)
      with ex -> classify ex ~path)

let read_file ~controls ?max_bytes t path =
  Controls_raw.run controls ~operation:"fs.read_file"
    ~measure:(fun content -> Some (String.length content))
    (fun () -> read_file_body t ~max_bytes path)

let list_dir ~controls ?max_entries t path =
  Controls_raw.run controls ~operation:"fs.list_dir"
    ~notes:(fun entries -> [ ("entries", string_of_int (List.length entries)) ])
    (fun () -> list_dir_body t ~max_entries path)

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

let open_written_root ~sw ~parent name =
  match
    try Ok (Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (parent / name)) with
    | (Eio.Cancel.Cancelled _ | Eio.Exn.Multiple _) as exn -> raise exn
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

let not_writable path =
  Error
    (Error.make Error.Denied
       ~message:
         (path ^ ": refused — this grant's root is read-only (it was opened by Policy.with_root)"))

let writable t path = if t.writable then Ok () else not_writable path

let write_body t ~max_bytes path ~contents =
  let* () = writable t path in
  let limit = ceiling ~grant_max:t.max_write_bytes max_bytes in
  if String.length contents > limit then
    Error
      (Error.make Error.Denied
         ~message:
           (Printf.sprintf
              "%s: refused — %d bytes is beyond the %d-byte write ceiling (max_bytes may lower it, \
               never raise it)"
              path (String.length contents) limit))
  else
    let* target = resolve t.root path in
    (* Atomic write: write to tempfile, flush, rename over target. *)
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
              match try Ok (Eio.Path.rename temp target) with ex -> classify ex ~path with
              | Ok () -> Ok ()
              | Error error ->
                  (* Cleanup temp file on failed rename. *)
                  (try ignore (Eio.Path.unlink ~missing_ok:true temp) with _ -> ());
                  Error error))
    in
    attempt 1

let atomic_write ~controls ?max_bytes t ~path ~contents =
  Controls_raw.run controls ~operation:"fs.atomic_write"
    ~measure:(fun () -> Some (String.length contents))
    (fun () -> write_body t ~max_bytes path ~contents)

let read_range_body t ~max_bytes ~offset path =
  let limit = ceiling ~grant_max:t.max_read_bytes max_bytes in
  let* target = resolve t.root path in
  let* kind = kind_of ~follow:true ~label:path target in
  let* kind = classify_kind ~path kind in
  match kind with
  | `Directory ->
      Error
        (Error.make Error.Invalid
           ~message:(path ^ ": that is a directory — list it, do not read it"))
  | `Regular_file -> (
      try
        Eio.Path.with_open_in target (fun flow ->
            let size = Optint.Int63.to_int (Eio.File.size flow) in
            if offset >= size then Ok ("", false)
            else
              let want = min limit (size - offset) in
              let buffer = Cstruct.create want in
              Eio.File.pread_exact flow ~file_offset:(Optint.Int63.of_int offset) [ buffer ];
              let got = Cstruct.to_string buffer in
              Ok (got, size - (offset + String.length got) > 0))
      with ex -> classify ex ~path)

let read_range ~controls ?max_bytes t ~offset path =
  Controls_raw.run controls ~operation:"fs.read_range"
    ~measure:(fun (content, _more) -> Some (String.length content))
    ~notes:(fun (_content, more) ->
      [ ("offset", string_of_int offset); ("more", string_of_bool more) ])
    (fun () -> read_range_body t ~max_bytes ~offset path)

let stat_body t path =
  let* target = resolve t.root path in
  try
    let info = Eio.Path.stat ~follow:true target in
    Ok (Optint.Int63.to_int info.Eio.File.Stat.size, info.Eio.File.Stat.atime)
  with ex -> classify ex ~path

let stat ~controls t path =
  Controls_raw.run controls ~operation:"fs.stat"
    ~notes:(fun (size, _atime) -> [ ("size", string_of_int size) ])
    (fun () -> stat_body t path)

(* Unlink is idempotent on missing paths to tolerate concurrent eviction races. *)
let unlink_body t path =
  let* () = writable t path in
  let* target = resolve t.root path in
  try Ok (Eio.Path.unlink ~missing_ok:true target) with ex -> classify ex ~path

let unlink ~controls t path =
  Controls_raw.run controls ~operation:"fs.unlink" (fun () -> unlink_body t path)
