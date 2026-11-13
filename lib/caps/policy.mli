(** Confined grant constructors: the only way to obtain an ['kind Authority.t].

    Every operation a grant offers is bounded by how the grant was built, so
    this module is where confinement is decided and therefore where an audit
    starts. [with_root] returns a [Policy_fs.t] — a confinement decision — and
    [Authority.Fs.of_confinement] is what turns that decision into the grant a
    tool is registered with; there is no other way to get either, which is the
    property [test/should_not_compile] pins down.

    The M3 network constructors are here too, and like [with_root] they return a
    [Policy_net.t] — the confinement decision — rather than a grant: a
    constructor that handed back an unconstrained grant, or one that answered
    [Error Unavailable] forever, would make the layer's central claim false while
    still compiling. *)

(** The ceilings a grant carries when the operator does not choose them. They
    are deliberately modest: a [read_source]-shaped tool needs tens of
    kilobytes, and an uncapped read lets the calling model's parameters decide
    how large our response is. *)
val default_max_read_bytes : int

val default_max_entries : int

(** The response-body ceiling [Policy_net]'s defaults speak of, re-exported so an
    operator writing [~max_response_bytes] has one module to look at. *)
val default_max_response_bytes : int

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

type endpoint = Policy_net.endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
  (** [None] is the scheme's default port; an explicit one is part of what the
      grant pins, so a vendor endpoint cannot be reached on another port. *)
}

(** M3, §5. Operator-selected vendor and self-hosted endpoints: scheme, host and
  port are pinned and re-validated on every connection. Returns the confinement
  decision, like [with_root]; [Authority.Net.of_confinement] is what turns it
  into the grant a tool is registered with.

  The list is normalised (host lowercased, a written-out default port folded to
  the scheme's default) and must be non-empty with no two entries naming the
  same destination — a duplicate is a configuration mistake an operator wants
  told about at startup, not a first-match rule to remember. An https entry reads
  the system trust anchors here, so a deployment that cannot find them fails
  construction instead of handing back a grant whose https path fails in
  production. [max_response_bytes] is the grant's ceiling on a response body; a
  caller may lower it per request, never raise it.

  {b Note the two trust models.} An endpoint list pins {b names}: an operator who
  writes [searxng.internal] or [127.0.0.1] has decided that destination is
  allowed, and this layer makes the connection really go to what that name
  resolves to rather than second-guessing the choice — which is how a
  self-hosted provider on a private network is reachable at all. The address
  rules below are [with_public_web]'s. *)
val with_endpoints :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  max_response_bytes:int ->
  endpoint list ->
  (Policy_net.t, Error.t) result

(** M3, §5. What [fetch] gets: HTTP(S) only, no URI userinfo, and globally
    routable unicast destinations only — with the
    loopback/private/link-local/multicast/unspecified/special-use and
    IPv4-mapped-IPv6 ranges denied by one documented policy
    ([Policy_net.satisfies_address]). A name that resolves only to refused
    addresses is a [Denied] before any connection is attempted.

    [port_policy] is separate from the address rule. The default,
    [Default_ports], accepts only each scheme's default port — the safe mode.
    [Any_port] is the seekwright mode: any port in 1..65535 when the resolved
    address is public, matching Python's fetch. Neither mode relaxes the
    address check, and permission for private addresses is a separate axis. *)
type port_policy = Policy_net.port_policy = Default_ports | Any_port

val with_public_web :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?port_policy:port_policy ->
  max_response_bytes:int ->
  unit ->
  (Policy_net.t, Error.t) result

(** F1.4: the operator-approved private-web variant, and the only way this layer
    reaches a non-public address without an endpoint list naming it. Same HTTP(S)
    shape, same port modes, same trust anchors as [with_public_web]; what differs
    is one axis — the address rule admits the operator's own network (loopback,
    private, link-local, unique-local) while still refusing a multicast group, a
    broadcast address and the unspecified address.

    The variant is a construction decision, not a per-request one: a grant built
    here stays private-web for its whole life, and a grant built anywhere else
    cannot be widened. That is what enforces the oracle's asymmetry —
    [fetch.allow_private_addresses] lets {i this server} read the intranet, and
    says nothing about handing an internal hostname to a third-party fetch
    service, so a fallback's grant is [with_endpoints] over its vendor and never
    this. *)
val with_private_web :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?port_policy:port_policy ->
  max_response_bytes:int ->
  unit ->
  (Policy_net.t, Error.t) result

(* [with_operation_timeout] and [with_log] (§6) live in [Authority], beside the
   grant type they change: an endo-function on an abstract grant that returns its
   argument unchanged would compile and silently promise a bound it never
   applies, so they are declared where the bounds record they rewrite is real —
   and that record's module is private, which is what keeps it out of reach here. *)
