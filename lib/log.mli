(** The log discipline, ported from [src/seekwright/logs.py].

    A message is a constant dotted event name; every value reaches a line only
    by being a named field, so the no-secrets rule stays checkable and one call
    site can render as text or JSON. stderr only — stdout is the protocol
    channel under stdio — never a backtrace, never an exception object.

    The sink type is this module's ({!log}) so that adding a parameter is one
    declaration: {!Engine}, {!Usage} and {!Health} each alias it, and the server
    (P8) hands one function to all four. *)

(** {1 The sink type} *)

type log =
  Config.log_level -> string -> (string * Yojson.Safe.t) list -> unit
(** [log level event fields] writes one line: the level decides whether the
    configured floor lets it out at all, [event] is the constant dotted name,
    [fields] the bound values. Written out once here because every module that
    {i takes} a sink — the engines, the usage recorder, the health board — names
    this one, so a new parameter is a change in one place and the type checker
    points at it there. *)

type t
(** A configured logger: the level floor and the format, from [logging]. *)

val make : Config.logging_config -> t

val apply_overrides :
  Config.logging_config ->
  Config.log_level option ->
  Config.log_format option ->
  Config.logging_config
(** [--log-level] / [--log-format] are properties of one invocation, so they
    override the file's [logging] section for that run only. *)

val sink : t -> log
(** The one function the engines, the usage recorder and the health board
    share: [sink t level event fields] writes one line to stderr when [level]
    clears the configured floor. *)
