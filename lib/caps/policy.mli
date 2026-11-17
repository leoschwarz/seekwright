(** Confined grant policy constructors. Produces [Policy_fs.t] and [Policy_net.t] confinement
    decisions wrapped into grants by {!Authority}. *)

val default_max_read_bytes : int
val default_max_entries : int
val default_max_response_bytes : int
val max_configurable_response_bytes : int

val with_root :
  sw:Eio.Switch.t ->
  ?max_read_bytes:int ->
  ?max_entries:int ->
  parent:_ Eio.Path.t ->
  string ->
  (Policy_fs.t, Error.t) result
(** [with_root ~sw ~parent name] opens [parent / name] confined via [open_subtree]. Root is
    read-only; writes and unlinks return [Denied]. *)

val default_max_write_bytes : int

val with_written_root :
  sw:Eio.Switch.t ->
  ?max_read_bytes:int ->
  ?max_write_bytes:int ->
  ?max_entries:int ->
  parent:_ Eio.Path.t ->
  string ->
  (Policy_fs.t, Error.t) result
(** [with_written_root ~sw ~parent name] creates [parent / name] if missing (mode 0o700) and opens a
    writable confined root supporting atomic writes and unlinks. *)

type endpoint = Policy_net.endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
}

val endpoint_of_uri : Uri.t -> (endpoint, Error.t) result
(** See {!Policy_net.endpoint_of_uri}: the scheme, host and port rules a request is checked against,
    applied to a URI a caller wants to build a grant for. *)

val with_endpoints :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  max_response_bytes:int ->
  endpoint list ->
  (Policy_net.t, Error.t) result
(** [with_endpoints ~sw ~net ~max_response_bytes endpoints] normalizes and pins allowed
    destinations. Response body is bounded by [max_response_bytes]. *)

type port_policy = Policy_net.port_policy = Default_ports | Any_port

val with_public_web :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?port_policy:port_policy ->
  max_response_bytes:int ->
  unit ->
  (Policy_net.t, Error.t) result
(** [with_public_web ~sw ~net ?port_policy ~max_response_bytes ()] confines outbound HTTP(S) to
    public IP addresses, rejecting private, loopback, and broadcast ranges. *)

val with_private_web :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?port_policy:port_policy ->
  max_response_bytes:int ->
  unit ->
  (Policy_net.t, Error.t) result
(** [with_private_web ~sw ~net ?port_policy ~max_response_bytes ()] confines outbound HTTP(S)
    allowing operator-approved intranet/private IP addresses while still rejecting multicast and
    broadcast ranges. *)
