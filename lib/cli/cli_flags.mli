(** Server-flag parsing and the startup validation sentences — the half of the
    server command that is decisions rather than effects.

    The scanner reads {!Seekwright.Server.server_flag_table}, so a flag's
    spelling, its arity and the field it fills are one fact: the flag table
    and the manifest are derived from the same rows. The key, not the
    spelling, is what {!parse} matches on — the only place a flag's name is
    written is the table.

    Nothing here writes a stream or calls [exit]: a malformed command returns
    [{|Error sentence|}] and the caller (the binary) prints and exits 2, as
    the Python's [parser.error] does. *)

type opts = {
  check : bool;
  live : bool;
  metrics : bool;
  json : bool;
  http : bool;
  host : string option;
  port : int option;
  allowed_hosts : string list;
  log_level : Seekwright.Config.log_level option;
  log_format : Seekwright.Config.log_format option;
}
(** What this invocation asked of the server: the flag set, with the two
    logging overrides the CLI may carry over the config file's. *)

val parse : string list -> (opts, string) result
(** [parse argv] scans the server flags and applies the combination guards,
    ported from [cli.py]'s [parser.error] calls: [--metrics] stands alone,
    [--json] needs [--metrics], [--live] needs [--check], and the bind flags
    need [--http]. *)

val startup_refusal :
  Seekwright.Config.t -> opts -> (unit, string) result
(** [startup_refusal config opts] is the sentence for the first startup
    condition the server must refuse over: a missing API key naming every
    offender and its variable, an unbuildable extraction backend, a
    [fetch.primary] this deployment cannot build, or agent mode enabled
    without its settings. [Ok ()] means the caller may build the app. *)
