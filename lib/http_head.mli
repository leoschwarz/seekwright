(** The HTTP heads this server owns, and the byte ceilings they are read and
    written under.

    The listener reads a request head before anything else looks at the
    connection, and it writes every refusal itself. Both directions are wire
    bytes from a peer or to a peer, so both have a named ceiling here rather
    than an inherited default: {!request_head_limit} bounds what this process
    will buffer from a client, {!response_head_limit} bounds what it will write
    back as a head. The limits are counted on the bytes that actually arrived,
    not on the size a buffer happened to grow to.

    {1 Why these numbers}

    The request ceiling matches h11's [MAX_INCOMPLETE_EVENT_SIZE] (16 KiB),
    which is the bound the Python oracle inherits from uvicorn's transport
    without ever writing it down. A port that left the reader at [max_int]
    would accept an unbounded head from an unauthenticated peer — the listener
    has no authentication, so the head is the first thing a stranger can make
    this process allocate.

    {1 Failures are values}

    {!read_request_head} answers with {!read_error} and {!response_head} with
    {!head_error}; nothing here raises for a peer's framing. The one exception
    that can escape is [Eio.Buf_read.Buffer_limit_exceeded], which is a
    defence-in-depth guard the caller has already made unreachable by sizing
    its reader this module's way ({!request_reader}); callers still map it, and
    no other exception crosses this boundary. *)

(** {1 The ceilings} *)

val request_head_limit : int
(** The request-line and header block ceiling, in wire bytes, terminators
    included. A head of exactly this many bytes is accepted; the byte that would
    make it one more is refused. *)

val response_head_limit : int
(** The outbound response-head ceiling, in wire bytes. No route in this tree
    produces a head near it; it exists so that a route which starts echoing a
    caller-shaped value into a header cannot turn an answer into an allocation
    the caller chose. *)

(** {1 Reading a request head} *)

type request_head = {
  request_line : string;
  header_lines : string list;
}
(** The head as text: the request line (terminator removed) and the header lines
    in arrival order, each with its terminator removed. Header lines are not
    parsed here — {!Seekwright.Server.headers_of_lines} folds them into the
    transport's header type, and that is the one place a header is interpreted. *)

type read_error =
  | Client_closed
  (** End of file before the first byte: a connect-and-close probe. Nothing is
      answered, because there is no request to answer. *)
  | Request_head_too_large
  (** The head reached {!request_head_limit} bytes without its blank line. *)
  | Malformed_request_head
  (** End of file inside the head: the blank line that ends it never arrived. *)
(** Why a request head could not be read. A value, not an exception: the caller
    decides which bounded refusal each one gets. *)

val request_reader : ?limit:int -> _ Eio.Flow.source -> Eio.Buf_read.t
(** The reader to parse a head from: a [Buf_read] whose buffer cannot grow past
    [limit + 1], so a single unbounded line is stopped by the buffer as well as
    by {!read_request_head}'s own counter. Sizing the two together is the point
    — a caller that builds its own [Buf_read] with [max_size:max_int] re-opens
    the hole this module exists to close. *)

val read_request_head :
  ?limit:int ->
  Eio.Buf_read.t ->
  (request_head * string, read_error) result
(** Read a request line and the header lines that follow it, up to and including
    the blank line, refusing once the consumed wire bytes would pass [limit]
    (default {!request_head_limit}).

    The second half of the result is the exact bytes consumed, terminator
    styles preserved. The listener has to hand the same bytes to the transport
    that parses the request, and reconstructing them from the parsed lines would
    change a bare-LF head into a CRLF one.

    Bytes are counted one at a time, so the ceiling is enforced before the
    [Buf_read] is asked for the byte that would pass it. *)

(** {1 Writing a response head} *)

type head_error = Response_head_too_large
(** The rendered head would pass {!response_head_limit}. *)

val response_head :
  ?limit:int ->
  status:int ->
  headers:(string * string) list ->
  body_length:int ->
  unit ->
  (string, head_error) result
(** Render one HTTP/1.1 response head: the status line, [headers] in order,
    [content-length] computed from [body_length], [connection: close], and the
    blank line. The body is not part of it, and the caller appends the body.

    The length is computed before any of it is built, so an over-cap header list
    is refused without being rendered. [content-length] and [connection] are
    this function's, never a caller's: the style rule the whole tree keeps is
    that hand-written protocol bytes compute their own lengths. *)

val reason_phrase : int -> string
(** The reason phrase for a status code, with the one word [http] 6.3 does not
    carry: 421 is [Misdirected Request], not the decimal code the library
    answers in its place. *)
