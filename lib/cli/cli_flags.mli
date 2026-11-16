(** Server-flag parsing and startup validation decisions.
    Nothing here writes a stream or calls [exit]: a malformed command returns
    [Error sentence] and the caller exits 2. *)

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

val parse : string list -> (opts, string) result
(** [parse argv] validates server flags and combinations. Returns [Error sentence] on invalid flags or illegal combinations. *)

val startup_refusal :
  Seekwright.Config.t -> opts -> (unit, string) result
(** Returns [Ok ()] if startup preconditions pass, or [Error reason] (missing API keys, invalid extractor, unbuildable fetch primary, or incomplete agent settings). *)
