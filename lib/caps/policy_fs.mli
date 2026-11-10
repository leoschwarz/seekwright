(** The filesystem confinement record — the witness a grant is built from.

    [Policy.with_root] is the entry point applications call; this module is
    where that decision is actually made. The split exists for one concrete
    reason: [Authority.mli] has to name the witness type for
    [Authority.Fs.of_confinement], and if the witness lived in [Policy] the two
    interfaces would depend on each other (the net constructors in [Policy] name
    [Authority.net]). A record both can point at breaks the cycle, and it puts
    the handle and the ceilings in one file an auditor reads top to bottom.

    [t] is abstract: no module outside this one can build one or change what it
    points at, so the answer to "where may this tool's reads go" is always "at a
    [with_root] call". *)

(** An opened subtree and the ceilings that ride on it. *)
type t

val default_max_read_bytes : int
(** The read ceiling a grant carries when the operator does not choose one. *)

val default_max_entries : int
(** The directory-entry ceiling likewise. *)

val default_operation_timeout_seconds : float
(** The whole-operation bound an [Fs] grant carries when the operator does not
    choose one (§5's "one total operation timeout" applied to a local read). It
    is far shorter than the network default: a read inside an opened subtree is
    local I/O, and a bound that only fires on a wedged filesystem or a pathological
    pipe needs to be small to be worth having. *)

val with_root :
  sw:Eio.Switch.t ->
  ?max_read_bytes:int ->
  ?max_entries:int ->
  parent:_ Eio.Path.t ->
  string ->
  (t, Error.t) result
(** [with_root ~sw ~parent name] opens [parent / name] with
    [Eio.Path.open_subtree ~sw] and keeps the handle, so [".."], symlinks and
    component-replacement races fail instead of escaping
    (plans/capability-gated-mcp-server.md §4). [name] is the operator's path and
    is not itself confined — it defines the confinement. [sw] must outlive every
    server that can serve a tool holding the grant. *)

val read_file : controls:Controls.t -> ?max_bytes:int -> t -> string -> (string, Error.t) result
(** The operation behind [Authority.Fs.read_file]; see that interface for the
    contract. [controls] is not optional on purpose: it is where the operation's
    time bound, budget and audit event come from, and a call site that can name
    no controls is a call site that has not decided them (§3, §6). *)

val list_dir : controls:Controls.t -> ?max_entries:int -> t -> string -> (string list, Error.t) result
(** The operation behind [Authority.Fs.list_dir]. *)
