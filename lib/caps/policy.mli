(** Confined grant constructors: the only way to obtain an ['kind Authority.t].

    Every operation a grant offers is bounded by how the grant was built, so
    this module is where confinement is decided and therefore where an audit
    starts. Nothing below is implemented at M0: each constructor answers
    [Error Unavailable] naming the milestone that implements it, because a
    constructor that returned an unconfined value would make the layer's
    central claim false while still compiling. *)

type endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
  (** [None] is the scheme's default port; an explicit one is part of what the
      grant pins, so a vendor endpoint cannot be reached on another port. *)
}

(** M1, plans/capability-gated-mcp-server.md §4. Opens an Eio subtree with
    [Eio.Path.open_subtree ~sw]; the subtree handle, not a path string, is what
    confines reads, so [..], symlinks and component-replacement races cannot
    escape it. [sw] must outlive the server. *)
val with_root :
  sw:Eio.Switch.t -> _ Eio.Path.t -> string -> (Authority.fs Authority.t, Error.t) result

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
   unchanged would compile at M0 and silently promise a bound it never applies. *)
