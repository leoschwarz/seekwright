(** Failures that are safe to hand to a model.

    A tool's [run] returns one of these when it refuses or fails: a stable
    [kind] the caller can branch on, plus a message. The message is the whole
    point of the module — it is copied into an MCP tool result and from there
    into a caller's model context, so it must never carry an exception, a
    backtrace, a header, a credential, a response body, or a local value
    (plans/capability-gated-mcp-server.md §3). [make] runs every message
    through [sanitize], which is the one place text is reduced to a single
    bounded line; [sanitize] is exported so [Event] notes go through it too. *)

type kind =
  | Denied  (** the operation is outside what the grant allows *)
  | Invalid  (** the input was rejected before any I/O was attempted *)
  | Unavailable  (** the endpoint could not be reached, or the path is unimplemented *)
  | Timeout  (** the operation exceeded its bound *)
  | Failed  (** it reached the thing and still failed *)

type t

val make : kind -> message:string -> t
(** [make kind ~message] sanitizes [message] on the way in, so a value that
    came from a provider response cannot smuggle a second line or an overlong
    payload into a tool result. *)

val kind : t -> kind
val message : t -> string
(** The already-sanitized message: safe to render, never the raw input. *)

val kind_to_string : kind -> string
val render : t -> string
(** One line, [kind]-prefixed, for an MCP tool result or a log field. *)

val sanitize : string -> string
(** Collapse control characters (including newlines) to spaces, trim, and cut
    at [max_message_bytes] on a UTF-8 boundary. Exported for reuse by [Event];
    nothing else in the library should write its own truncation. *)

val max_message_bytes : int
