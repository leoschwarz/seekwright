(** Structured logging discipline.

    Log messages are constant dotted event names; fields are named JSON values.
    Output is emitted to stderr only (leaving stdout clean for JSON-RPC stdio). *)

type log =
  Config.log_level -> string -> (string * Yojson.Safe.t) list -> unit
(** [log level event fields] emits one structured line to stderr if [level]
    satisfies the configured log level floor. *)

val classify_exn : exn -> string
(** Bounded classification of exceptions ([io], [cancelled], [sys_error], etc.)
    preventing arbitrary payload or credential leakage into logs. *)

type t
(** Configured logger holding level threshold and output format. *)

val make : Config.logging_config -> t

val apply_overrides :
  Config.logging_config ->
  Config.log_level option ->
  Config.log_format option ->
  Config.logging_config
(** Overrides configured level and format from CLI flags for this invocation. *)

val sink : t -> log
(** Builds the sink function shared across engines, usage recorder, and health board. *)
