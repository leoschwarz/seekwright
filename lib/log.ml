(* The log discipline, ported from [src/seekwright/logs.py]: a constant dotted
   event name, every value a named bound field, stderr only, never a backtrace,
   never an exception object. stdout is the JSON-RPC channel under stdio, so
   nothing here ever writes to it; [--check] and [--metrics] print their report
   to stdout themselves, and that is the one sanctioned exception.

   The sink type is this module's own — see {!log} — and {!Engine}, {!Usage} and
   {!Health} alias it, so the server hands one function to all four. Levels are
   [Config]'s vocabulary, because [logging.level] in TOML spells them that way. *)

type log =
  Config.log_level -> string -> (string * Yojson.Safe.t) list -> unit

(* A raised exception is classified by constructor family, never rendered:
   rendering it would carry the payload, and an [Eio.Io]'s payload names the
   path or endpoint that failed. The set is deliberately finite so a log field
   says the same thing on every run. *)
let classify_exn = function
  | Eio.Io _ -> "io"
  | Eio.Cancel.Cancelled _ -> "cancelled"
  | End_of_file -> "end_of_file"
  | Sys_error _ -> "sys_error"
  | Failure _ -> "failure"
  | Invalid_argument _ -> "invalid_value"
  | Not_found -> "not_found"
  | _ -> "other"

let level_rank = function
  | Config.Log_trace -> 0
  | Config.Log_debug -> 1
  | Config.Log_info -> 2
  | Config.Log_success -> 3
  | Config.Log_warning -> 4
  | Config.Log_error -> 5
  | Config.Log_critical -> 6

let apply_overrides config level format_ =
  let level = Option.value ~default:config.Config.level level in
  let format = Option.value ~default:config.Config.format format_ in
  { config with Config.level; format }

type t = {
  level : Config.log_level;
  format_ : Config.log_format;
}

let make config = { level = config.Config.level; format_ = config.Config.format }

let render_fields fields =
  String.concat " "
    (List.map
       (fun (name, value) -> name ^ "=" ^ Yojson.Safe.to_string value)
       fields)

let sink { level; format_ } event_level event fields =
  if level_rank event_level >= level_rank level then
    let line =
      match format_ with
      | Config.Log_text ->
          Printf.sprintf "%s %s %s"
            (Config.show_log_level event_level)
            event
            (render_fields fields)
      | Config.Log_json ->
          Yojson.Safe.to_string
            (`Assoc
               [
                 ("level", `String (Config.show_log_level event_level));
                 ("event", `String event);
                 ("fields", `Assoc fields);
               ])
    in
    prerr_endline line
