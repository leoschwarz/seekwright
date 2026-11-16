type log =
  Config.log_level -> string -> (string * Yojson.Safe.t) list -> unit

(* Bounded classification of raised exceptions avoiding leaking payload/endpoints. *)
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
