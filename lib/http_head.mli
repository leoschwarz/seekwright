(** HTTP head parsing, rendering, and wire byte ceilings.

    The listener reads a request head before any other inspection, and writes
    refusals itself. Ceilings bound wire memory: {!request_head_limit} bounds
    buffered client bytes, {!response_head_limit} bounds outbound head bytes. *)

val request_head_limit : int
(** The request-line and header block ceiling in wire bytes (terminators included). *)

val response_head_limit : int
(** Outbound response-head ceiling in wire bytes. *)

type request_head = {
  request_line : string;
  header_lines : string list;
}
(** Head lines in arrival order with line terminators stripped. *)

type read_error =
  | Client_closed
  | Request_head_too_large
  | Malformed_request_head

val request_reader : ?limit:int -> _ Eio.Flow.source -> Eio.Buf_read.t
(** Builds an [Eio.Buf_read.t] bounded at [limit + 1] bytes. *)

val read_request_head :
  ?limit:int ->
  Eio.Buf_read.t ->
  (request_head * string, read_error) result
(** Reads request line and headers up to the terminating blank line. Returns
    the parsed head and the verbatim wire bytes consumed. *)

type head_error = Response_head_too_large

val response_head :
  ?limit:int ->
  status:int ->
  headers:(string * string) list ->
  body_length:int ->
  unit ->
  (string, head_error) result
(** Renders an HTTP/1.1 response head with computed [content-length] and [connection: close]. *)

val reason_phrase : int -> string
(** Standard HTTP reason phrase for a status code (e.g. 421 -> "Misdirected Request"). *)
