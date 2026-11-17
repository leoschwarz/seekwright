(** The shared half of a remote fetch fallback: failure types, the network seam, the request tail
    every vendor reader shares, and JSON response parsing. *)

type error = Url_blocked of string | Rejected of string | Quota of string | Failed of string

type page = Seekwright_wire.Page.page

type net = {
  request :
    max_response_bytes:int option ->
    Mcp_caps.Authority.Net.request ->
    (Mcp_caps.Authority.Net.response, Mcp_caps.Error.t) result;
}

val of_grant : Mcp_caps.Authority.Net.t -> net

type status_rule = (int list * error) list
(** What a vendor's status line means, in the order it wants the codes tested: the codes it answers
    and the fact each one means. *)

val status_error : Mcp_caps.Authority.Net.response -> status_rule -> error option
(** [None] when the response may be read. A code the rule does not name is still refused, as
    [Failed "HTTP n"] — a vendor that adds no row gains no pass. *)

val send : net -> Mcp_caps.Authority.Net.request -> (Mcp_caps.Authority.Net.response, error) result
(** One request on the seam with the grant failure already turned into [Failed], and the response
    ceiling left to the grant. *)

val send_json :
  net -> status_rule -> Mcp_caps.Authority.Net.request -> (Yojson.Safe.t, error) result
(** [send], then {!status_error}, then {!Json.decode_object} on the body — the order that keeps an
    error page's status sentence ahead of a JSON parse failure. *)

val malformed : unit -> error

module Json : sig
  val decode_object : string -> (Yojson.Safe.t, error) result
  val field : string -> Yojson.Safe.t -> Yojson.Safe.t
  val string_field : string -> Yojson.Safe.t -> string option
  val int_field : string -> Yojson.Safe.t -> int option
  val list_field : string -> Yojson.Safe.t -> Yojson.Safe.t list option
  val is_false : Yojson.Safe.t -> bool
end

val or_string : string option -> string option -> string option

val windowed :
  string ->
  url:string ->
  max_text_chars:int ->
  offset:int ->
  max_chars:int option ->
  title:string option ->
  status_code:int ->
  page
