(** The shared half of a remote fetch fallback: failure types,
    the network seam, and JSON response parsing. *)

type error =
  | Url_blocked of string
  | Rejected of string
  | Quota of string
  | Failed of string

type page = Seekwright_wire.Page.page

type net = {
  request :
    max_response_bytes:int option ->
    Mcp_caps.Authority.Net.request ->
    (Mcp_caps.Authority.Net.response, Mcp_caps.Error.t) result
}

val of_grant : Mcp_caps.Authority.Net.t -> net

val transport_error : Mcp_caps.Error.t -> error

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
