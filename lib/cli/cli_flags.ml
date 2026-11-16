let ( let* ) = Result.bind

module Config = Seekwright.Config
module Server = Seekwright.Server

type opts = {
  check : bool;
  live : bool;
  metrics : bool;
  json : bool;
  http : bool;
  host : string option;
  port : int option;
  allowed_hosts : string list;
  log_level : Config.log_level option;
  log_format : Config.log_format option;
}

let log_level_of_string = function
  | "TRACE" -> Some Config.Log_trace
  | "DEBUG" -> Some Config.Log_debug
  | "INFO" -> Some Config.Log_info
  | "SUCCESS" -> Some Config.Log_success
  | "WARNING" -> Some Config.Log_warning
  | "ERROR" -> Some Config.Log_error
  | "CRITICAL" -> Some Config.Log_critical
  | _ -> None

let log_format_of_string = function
  | "text" -> Some Config.Log_text
  | "json" -> Some Config.Log_json
  | _ -> None

let apply_boolean opts ~key ~flag =
  match key with
  | "check" -> Ok { opts with check = true }
  | "live" -> Ok { opts with live = true }
  | "metrics" -> Ok { opts with metrics = true }
  | "json" -> Ok { opts with json = true }
  | "http" -> Ok { opts with http = true }
  | _ -> Error ("unknown flag " ^ flag)

let apply_value opts ~key ~flag value =
  match key with
  | "host" -> Ok { opts with host = Some value }
  | "port" -> (
      match int_of_string_opt value with
      | Some n when n > 0 && n < 65536 -> Ok { opts with port = Some n }
      | _ -> Error (flag ^ " needs a port number"))
  | "allowed_host" -> Ok { opts with allowed_hosts = opts.allowed_hosts @ [ value ] }
  | "log_level" -> (
      match log_level_of_string value with
      | Some level -> Ok { opts with log_level = Some level }
      | None -> Error (flag ^ " needs TRACE..CRITICAL"))
  | "log_format" -> (
      match log_format_of_string value with
      | Some format_ -> Ok { opts with log_format = Some format_ }
      | None -> Error (flag ^ " needs text or json"))
  | _ -> Error ("unknown flag " ^ flag)

let parse argv =
  let rec go opts = function
    | [] -> Ok opts
    | flag :: rest -> (
        match Server.flag_spec flag with
        | None ->
            if String.length flag > 2 && String.sub flag 0 2 = "--" then
              Error ("unknown flag " ^ flag)
            else Error ("unexpected argument " ^ flag)
        | Some spec -> (
            match spec.Server.arity with
            | Server.Boolean -> (
                match apply_boolean opts ~key:spec.key ~flag with
                | Error _ as e -> e
                | Ok opts -> go opts rest)
            | Server.Value -> (
                match rest with
                | [] -> Error (flag ^ " needs a value")
                | value :: rest' -> (
                    match apply_value opts ~key:spec.key ~flag value with
                    | Error _ as e -> e
                    | Ok opts -> go opts rest'))))
  in
  let* opts =
    go
      {
        check = false;
        live = false;
        metrics = false;
        json = false;
        http = false;
        host = None;
        port = None;
        allowed_hosts = [];
        log_level = None;
        log_format = None;
      }
      argv
  in
  if
    opts.metrics
    && (opts.check || opts.live || opts.http || opts.host <> None || opts.port <> None
      || opts.allowed_hosts <> [])
  then
    Error
      "--metrics reports and exits; it cannot be combined with --check, --live, --http, --host, \
       --port or --allowed-host"
  else if opts.json && not opts.metrics then Error "--json only makes sense together with --metrics"
  else if opts.live && not opts.check then Error "--live only makes sense together with --check"
  else if (opts.host <> None || opts.port <> None || opts.allowed_hosts <> []) && not opts.http then
    Error "--host, --port and --allowed-host only make sense together with --http"
  else Ok opts

(** The startup refusals: test_p8_server.ml pins this marker to slice the scanner. *)
let startup_refusal config _opts =
  match Config.missing_api_keys config with
  | _ when config.Config.fetch.Config.enabled && config.Config.fetch.Config.primary <> "http" ->
      (* An unbuildable primary must refuse before keys: prevents falling back to local IP. *)
      Error
        (Printf.sprintf
           "fetch.primary names %S, which this deployment cannot build (see `seekwright --check` \
            for why); refusing to start rather than read from this server's own IP unasked"
           config.Config.fetch.Config.primary)
  | missing when missing <> [] ->
      Error
        ("missing API key(s) for enabled provider(s): "
        ^ String.concat ", "
            (List.map (fun name -> name ^ " (" ^ Config.api_key_env_var name ^ ")") missing))
  | _ -> (
      match Seekwright_factory.Factory.build_extractor config with
      | Ok _ -> (
          match Config.missing_agent_settings config with
          | [] -> Ok ()
          | missing -> Error ("agent mode is enabled but missing " ^ String.concat ", " missing))
      | Error message -> Error message)
