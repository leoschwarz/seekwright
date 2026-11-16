(** Content-free audit events for authority operations. Records operation name, outcome, byte
    counts, and bounded notes without logging sensitive request or response bodies. *)

type outcome = Ok | Failed of Error.kind

type t

val make : operation:string -> outcome -> t
(** [operation] is a constant name from the authority API, never a path or URL; it goes through
    [Error.sanitize] so the rendered line stays one line. *)

val with_bytes : int -> t -> t

val add_note : key:string -> value:string -> t -> t
(** Both the key and the value go through [Error.sanitize], and the list is capped at [max_notes],
    so a note cannot become the log line's length. *)

val operation : t -> string
(** a constant name from the authority API, never a path or URL *)

val outcome : t -> outcome

val outcome_to_string : outcome -> string
(** [ok], or [failed:] followed by [Error.kind_to_string]: the one spelling of an outcome, which
    [render] uses and an application writes as a field when it keeps its own log rather than a
    rendered line. *)

val bytes : t -> int option
(** size of what moved, not what moved *)

val notes : t -> (string * string) list
(** bounded; see [add_note] *)

val render : t -> string
val max_notes : int
