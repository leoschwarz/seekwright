(** Confined grant constructors: the only way to obtain an ['kind Authority.t].

    Every operation a grant offers is bounded by how the grant was built, so
    this module is where confinement is decided and therefore where an audit
    starts. [with_root] returns a [Policy_fs.t] — a confinement decision — and
    [Authority.Fs.of_confinement] is what turns that decision into the grant a
    tool is registered with; there is no other way to get either, which is the
    property [test/should_not_compile] pins down.

    The M3 network constructors are declared here too, and answer [Error
    Unavailable] until M3 implements them: a constructor that returned an
    unconstrained grant would make the layer's central claim false while still
    compiling. *)

(** The ceilings a grant carries when the operator does not choose them. They
    are deliberately modest: a [read_source]-shaped tool needs tens of
    kilobytes, and an uncapped read lets the calling model's parameters decide
    how large our response is. *)
val default_max_read_bytes : int

val default_max_entries : int

(** M1, plans/capability-gated-mcp-server.md §4. Opens [parent / name] with
    [Eio.Path.open_subtree ~sw]; the subtree handle, not a path string, is what
    confines reads, so [..], symlinks and component-replacement races cannot
    escape it. [name] is the operator's path and is not itself confined — it
    defines the confinement. [sw] must outlive every server that can serve a
    tool holding the grant.

    [max_read_bytes] and [max_entries] set the grant's ceilings; a tool caller
    may lower them per call, never raise them. A non-positive value is an
    [Error Invalid] at construction. *)
val with_root :
  sw:Eio.Switch.t ->
  ?max_read_bytes:int ->
  ?max_entries:int ->
  parent:_ Eio.Path.t ->
  string ->
  (Policy_fs.t, Error.t) result

type endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
  (** [None] is the scheme's default port; an explicit one is part of what the
      grant pins, so a vendor endpoint cannot be reached on another port. *)
}

(** M3, §5. Operator-selected vendor and self-hosted endpoints: scheme, host and
  port are pinned and re-validated on every connection. *)
val with_endpoints :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  max_response_bytes:int ->
  endpoint list ->
  (Authority.net Authority.t, Error.t) result

(** M3, §5. What [fetch] gets: HTTP(S) only, globally routable unicast
    destinations only, with the loopback/private/link-local/multicast/special-use
    and IPv4-mapped-IPv6 ranges denied by one documented policy. *)
val with_public_web :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  max_response_bytes:int ->
  unit ->
  (Authority.net Authority.t, Error.t) result

(* [with_operation_timeout] and [with_log] (§6) are declared when they are
   implemented: an endo-function on an abstract grant that returns its argument
   unchanged would compile and silently promise a bound it never applies. *)
