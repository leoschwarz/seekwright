(** One line of what a grant did, with no content in it.

    The audit surface of the layer (plans/capability-gated-mcp-server.md §6):
    the application supplies the sink, an event names the operation and its
    outcome, and the only payload it can carry is a byte count and a few
    operator-chosen notes. That is what lets a deployment log every authority
    operation without a page, a response body, or a header reaching the log. *)

type outcome =
  | Ok
  | Failed of Error.kind

(** Abstract on purpose: a record literal would let a caller bypass
    [make]/[add_note] and the sanitising and bounding they apply. *)
type t

val make : operation:string -> outcome -> t
(** [operation] is a constant name from the authority API, never a path or URL;
    it goes through [Error.sanitize] so the rendered line stays one line. *)

val with_bytes : int -> t -> t

val add_note : string -> string -> t -> t
(** Both the key and the value go through [Error.sanitize], and the list is
    capped at [max_notes], so a note cannot become the log line's length. *)

val operation : t -> string
(** a constant name from the authority API, never a path or URL *)

val outcome : t -> outcome
val bytes : t -> int option
(** size of what moved, not what moved *)

val notes : t -> (string * string) list
(** bounded; see [add_note] *)

val render : t -> string
val max_notes : int
