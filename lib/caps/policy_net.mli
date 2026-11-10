(** The checked DNS, connection, redirect and response-bound machinery behind a
    [Net] grant.

    [t] is abstract and [Policy.with_endpoints] / [Policy.with_public_web] are
    the only producers of one, exactly as [Policy_fs] is for the filesystem
    (§4, §5); [Authority.Net.of_confinement] turns a witness into the grant a
    tool is registered with. This module has no public constructor and no way to
    hand back an unconstrained connection: every path to a socket runs through
    the policy stored in [t].

    {2 What a [Net] grant guarantees, and where each half lives}

    - {b The endpoint decision.} A request is matched against the grant's
      policy — an exact (scheme, host, port) set for [with_endpoints], or
      HTTP(S) on the default ports for [with_public_web] — before any name is
      looked up. An unlisted host is refused without a DNS query, so a grant
      cannot be probed by resolver traffic.
    - {b The address binding.} [Eio.Net.getaddrinfo_stream] answers the
      allowlisted name, every answer is filtered against the policy, and
      [Eio.Net.connect] is then called with one {b of those vetted addresses}.
      The HTTP client is built with [Cohttp_eio.Client.make_generic] over a
      connector that ignores the URI it is handed and returns the socket for
      that address, so the client cannot resolve the name a second time: the
      address in the certificate of the connection is the address that passed
      the policy check. This is the DNS-rebinding fix the plan names (§5);
      checking DNS and then letting the HTTP library resolve again is the race.
    - {b TLS.} HTTPS is implemented, not stubbed: [tls-eio] over the vetted
      socket with [ca-certs] as the trust anchor store and the {b endpoint's}
      hostname (or IP, for an IP literal) as the peer name, so SNI and
      certificate hostname verification both stay on. Verification is never
      disabled, and if the trust store or the RNG cannot be obtained,
      construction fails rather than returning a grant whose https path would
      fail later (§5: an http-only implementation is not a completed M3).
    - {b Redirects.} Never followed. A 3xx is returned to the caller as-is, so
      no request leaves without the caller deciding; and a 3xx whose [Location]
      names a target this grant would refuse is itself a [Denied] — an off-list
      redirect is a refusal, not a hint. Because nothing is ever followed, there
      is no hop to leak credentials along and no hop count to bound.
    - {b Bounds.} One [Eio.Time.Timeout] over the whole operation (DNS, connect,
      TLS, headers, body) via [Controls.run]; the response body is streamed
      through [Eio.Buf_read] with a hard ceiling of min(grant, caller) bytes and
      is refused rather than truncated, with no [Content-Length] trust involved.
      Request bodies and headers are bounded and validated before they are sent,
      and a header name or value that could split a request is [Invalid].
    - {b Proxies.} The connector is ours, so [Cohttp_eio.Client.set_proxies]
      (a process-global) cannot move the destination outside the checked
      connection: this grant ignores that setting entirely.

    {2 Known limit, recorded rather than papered over}

    [Cohttp_eio.Client] reads the response {b headers} with its own
    [Eio.Buf_read.of_flow ~max_size:max_int], so the header block is bounded by
    the operation timeout and by the peer's willingness to send, not by
    [max_response_bytes]. The body ceiling is ours and is exact. Closing that
    gap means capping the wire at the flow level (§5 asks for "a hard
    decoded-byte cap"); it is the one bound in [Net] that is timeout-bounded
    rather than byte-bounded. *)

type method_ = [ `GET | `POST | `PUT | `PATCH | `DELETE ]

type request = {
  meth : method_;
  uri : Uri.t;
  headers : (string * string) list;
  body : string option;
}

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

(** An operator's egress decision, before normalisation. *)
type endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
}

type t

val default_max_response_bytes : int
(** What a grant carries when the operator does not choose: a page or a provider
    JSON body lives well inside it, and an uncapped body lets the calling model
    decide how large our own response is. *)

val default_operation_timeout_seconds : float
(** The whole-operation bound a grant carries by default (§5). *)

val with_endpoints :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  max_response_bytes:int ->
  endpoint list ->
  (t, Error.t) result
(** The confinement decision behind [Policy.with_endpoints]: normalise and
    validate the endpoint list (host form, port range, duplicates) and, if any
    entry is https, resolve the trust anchor store now so a missing one is a
    construction failure. [sw] is the switch the grant is expected to live under;
    v1 registers nothing on it because a connection is opened and closed inside
    one operation rather than pooled across a server's life. *)

val with_public_web :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  max_response_bytes:int ->
  unit ->
  (t, Error.t) result
(** The decision behind [Policy.with_public_web]: HTTP(S] on ports 80/443 only,
    and every resolved destination must be a globally routable unicast address.
    The ranges refused are listed on [satisfies_address] in the implementation:
    loopback, private, link-local, multicast, unspecified, broadcast, the
    IPv4-mapped IPv6 forms, unique-local, CGNAT, the IETF reserved and
    documentation blocks, 6to4 and Teredo. *)

val request :
  controls:Controls.t ->
  ?max_response_bytes:int ->
  t ->
  request ->
  (response, Error.t) result
(** The operation behind [Authority.Net.request]. [max_response_bytes] lowers
    the grant's ceiling, never raises it. *)
