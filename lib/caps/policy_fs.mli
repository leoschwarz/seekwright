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
    [with_root] call".

    {b This module is in dune's [private_modules].} Its interface is filed under
    [.private/] by [dune build @install], so a consumer of the installed package
    cannot call [read_file] or [list_dir] here at all: the filesystem operations
    are reachable only through [Authority.Fs]. (Inside this checkout the two
    names still resolve, because dune's alias module for a wrapped library re-exports
    private modules; [test/test_caps_audit.ml] is what keeps production modules
    from using that.) Keeping it separate rather than folding it into [Policy] is
    what lets [Authority.Fs.of_confinement] name its witness type without a
    module cycle. [Policy_net] cannot take the same shape — its request, response
    and endpoint records are the vocabulary a [Net] grant is called with, and a
    private module's records are unusable by an installed consumer — so its
    operations are sealed on their [~controls] argument instead, whose type is
    [Controls_raw.t]: also private, so equally unnameable. *)

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
    server that can serve a tool holding the grant.

    The root this opens is read-only: [atomic_write] and [unlink] through a grant
    made from it are [Denied], refused before the backend is touched. That is the
    default because the tool-facing roots are the operator's files, which no tool
    may edit. *)

val default_max_write_bytes : int
(** The write ceiling a written root carries when the operator does not choose
    one. The same default as the read ceiling, and lowered or raised by the same
    kind of operator limit. *)

val with_written_root :
  sw:Eio.Switch.t ->
  ?max_read_bytes:int ->
  ?max_write_bytes:int ->
  ?max_entries:int ->
  parent:_ Eio.Path.t ->
  string ->
  (t, Error.t) result
(** [with_written_root ~sw ~parent name] is [with_root] for a directory the server
    owns rather than reads: it creates [parent / name] (mode [0o700], missing
    parents included) when it is not there, and the confinement it opens allows
    [atomic_write] and [unlink] as well as the reads. Creating it is the point —
    an operator who names a cache directory expects the server to make it and to
    refuse at startup if it cannot, not to fail on the first store.

    Everything else is [with_root]'s: [open_subtree] confines the writes exactly
    as it confines the reads, so a write cannot leave the root, and the root's own
    permissions decide who else on the host can read what lands in it. *)

val read_file : controls:Controls_raw.t -> ?max_bytes:int -> t -> string -> (string, Error.t) result
(** The operation behind [Authority.Fs.read_file]; see that interface for the
    contract. [controls] is not optional on purpose: it is where the operation's
    time bound, budget and audit event come from, and a call site that can name
    no controls is a call site that has not decided them (§3, §6). Its type
    belongs to a private module, so outside [lib/caps] there is no argument that
    fills it: the only controls value in a running program is the one inside a
    grant. This module is private too, so a consumer of the package does not reach
    the operation in the first place. *)

val list_dir : controls:Controls_raw.t -> ?max_entries:int -> t -> string -> (string list, Error.t) result
(** The operation behind [Authority.Fs.list_dir]. *)

val read_range :
  controls:Controls_raw.t ->
  ?max_bytes:int ->
  t ->
  offset:int ->
  string ->
  (string * bool, Error.t) result
(** The operation behind [Authority.Fs.read_range]: a positional read, so a window
    into a large file allocates the window and not the file. *)

val stat : controls:Controls_raw.t -> t -> string -> (int * float, Error.t) result
(** The operation behind [Authority.Fs.stat]: the entry's size in bytes and its
    last access time. Counts only — the audit line carries [size=], never a name. *)

val atomic_write :
  controls:Controls_raw.t ->
  ?max_bytes:int ->
  t ->
  path:string ->
  contents:string ->
  (unit, Error.t) result
(** The operation behind [Authority.Fs.atomic_write]: a whole-payload write that
    becomes visible only once it is complete, and only inside a root opened by
    {!val:with_written_root}. *)

val unlink : controls:Controls_raw.t -> t -> string -> (unit, Error.t) result
(** The operation behind [Authority.Fs.unlink]: confined removal, idempotent on a
    missing path, and refused through a read-only root. *)
