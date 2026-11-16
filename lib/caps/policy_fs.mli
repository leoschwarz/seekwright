(** Filesystem confinement record and bounded operations. Confinement uses [Eio.Path.open_subtree]
    to prevent escapes via symlinks or [".."]. [t] is abstract and constructed only via [with_root]
    or [with_written_root]. *)

type t

val default_max_read_bytes : int
val default_max_entries : int
val default_operation_timeout_seconds : float

val with_root :
  sw:Eio.Switch.t ->
  ?max_read_bytes:int ->
  ?max_entries:int ->
  parent:_ Eio.Path.t ->
  string ->
  (t, Error.t) result
(** [with_root ~sw ~parent name] opens [parent / name] confined via [open_subtree]. Root is
    read-only: writes and unlinks return [Denied]. *)

val default_max_write_bytes : int

val with_written_root :
  sw:Eio.Switch.t ->
  ?max_read_bytes:int ->
  ?max_write_bytes:int ->
  ?max_entries:int ->
  parent:_ Eio.Path.t ->
  string ->
  (t, Error.t) result
(** [with_written_root ~sw ~parent name] creates [parent / name] if missing (mode 0o700) and opens a
    writable confined root supporting atomic writes and unlinks. *)

val read_file : controls:Controls_raw.t -> ?max_bytes:int -> t -> string -> (string, Error.t) result

val list_dir :
  controls:Controls_raw.t -> ?max_entries:int -> t -> string -> (string list, Error.t) result

val read_range :
  controls:Controls_raw.t ->
  ?max_bytes:int ->
  t ->
  offset:int ->
  string ->
  (string * bool, Error.t) result

val stat : controls:Controls_raw.t -> t -> string -> (int * float, Error.t) result

val atomic_write :
  controls:Controls_raw.t ->
  ?max_bytes:int ->
  t ->
  path:string ->
  contents:string ->
  (unit, Error.t) result

val unlink : controls:Controls_raw.t -> t -> string -> (unit, Error.t) result
