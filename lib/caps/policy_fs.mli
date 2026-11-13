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
    server that can serve a tool holding the grant. *)

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
