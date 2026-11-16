(** Network confinement policy and bounded HTTP(S) execution.
    [t] is abstract, constructed via [with_endpoints], [with_public_web], or
    [with_private_web]. Enforces DNS-to-connect binding (anti-DNS rebinding),
    mandatory TLS hostname verification against system trust anchors, un-followed
    redirects, and streamed response body caps. *)

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

type endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
}

type t

val default_max_response_bytes : int
val default_operation_timeout_seconds : float

val with_endpoints :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  max_response_bytes:int ->
  endpoint list ->
  (t, Error.t) result
(** [with_endpoints ~sw ~net ~max_response_bytes endpoints] confines requests to
    an explicit allowlist of (scheme, host, port) endpoints. *)

type port_policy =
  | Default_ports
  | Any_port

val with_public_web :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?port_policy:port_policy ->
  max_response_bytes:int ->
  unit ->
  (t, Error.t) result
(** [with_public_web ~sw ~net ?port_policy ~max_response_bytes ()] confines outbound
    requests to globally routable public addresses, rejecting private/multicast/broadcast. *)

val with_private_web :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?port_policy:port_policy ->
  max_response_bytes:int ->
  unit ->
  (t, Error.t) result
(** [with_private_web ~sw ~net ?port_policy ~max_response_bytes ()] confines outbound
    requests allowing operator-approved intranet/private IP addresses while still
    rejecting multicast and broadcast ranges. *)

val vet_public_host : net:_ Eio.Net.t -> host:string -> (unit, Error.t) result
(** [vet_public_host ~net ~host] verifies via DNS that every resolved IP for [host]
    is globally routable and not private/loopback/multicast. Does not open sockets. *)

val request :
  controls:Controls_raw.t ->
  ?max_response_bytes:int ->
  t ->
  request ->
  (response, Error.t) result
(** The operation behind [Authority.Net.request]. [max_response_bytes] may lower
    the grant's response ceiling, never raise it. Over-ceiling responses return [Denied]. *)
