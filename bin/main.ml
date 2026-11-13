(* The CLI surface. Port of [src/seekwright/cli.py]: the server on either
   transport, [--check]/[--metrics] as diagnoses that never build the MCP
   server, and the three client verbs ([search]/[fetch]/[answer]) as a client
   of the REST projection — no config, no provider, no key.

   Dispatch is on the first token, not subparsers, exactly as Python's: a
   client flag is a field of the request body, a server flag is this
   invocation's, and [--json] is the one name both namespaces have.

   The [--check]/[--metrics] paths never call [Server.registry], a transport or
   [Factory.build_app]: they read config, build providers for probing and fold
   the journal, which is the OCaml shape of Python's "never imports
   [server]" rule — in OCaml there is no import-time side effect to avoid, so
   the discipline is that these paths never *construct* the server machinery.
   Logs go to stderr either way; stdout is the protocol channel under stdio
   and the report channel for the two diagnoses. *)

module Caps = Mcp_caps
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Factory = Seekwright_factory.Factory
module Health = Seekwright.Health
module Log = Seekwright.Log
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Server = Seekwright.Server
module Usage = Seekwright.Usage

let default_server = "http://127.0.0.1:8000"

let usage_error message =
  prerr_endline ("seekwright: " ^ message);
  exit 2

(* {1 JSON reads} *)

let json_field key = function
  | `Assoc fields -> ( match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

let json_string key json = match json_field key json with `String s -> Some s | _ -> None

let json_int key json =
  match json_field key json with
  | `Int n -> Some n
  | `Float f -> Some (int_of_float f)
  | _ -> None

let json_float key json =
  match json_field key json with
  | `Int n -> Some (float_of_int n)
  | `Float f -> Some f
  | _ -> None

let json_bool key json = match json_field key json with `Bool b -> Some b | _ -> None

let json_list key json = match json_field key json with `List items -> Some items | _ -> None

(* {1 Flag parsing} *)

type server_opts = {
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

(* The scanner reads [Server.server_flag_table], so a flag's spelling, its arity
   and the field it fills are one fact: [Server.server_flags] and the manifest
   are derived from the same rows. The key, not the spelling, is what these two
   functions match on — the only place a flag's name is written is the table. *)
let apply_boolean opts ~key ~flag =
  match key with
  | "check" -> { opts with check = true }
  | "live" -> { opts with live = true }
  | "metrics" -> { opts with metrics = true }
  | "json" -> { opts with json = true }
  | "http" -> { opts with http = true }
  | _ -> usage_error ("unknown flag " ^ flag)

let apply_value opts ~key ~flag value =
  match key with
  | "host" -> { opts with host = Some value }
  | "port" -> (
      match int_of_string_opt value with
      | Some n when n > 0 && n < 65536 -> { opts with port = Some n }
      | _ -> usage_error (flag ^ " needs a port number"))
  | "allowed_host" -> { opts with allowed_hosts = opts.allowed_hosts @ [ value ] }
  | "log_level" -> (
      match log_level_of_string value with
      | Some level -> { opts with log_level = Some level }
      | None -> usage_error (flag ^ " needs TRACE..CRITICAL"))
  | "log_format" -> (
      match log_format_of_string value with
      | Some format_ -> { opts with log_format = Some format_ }
      | None -> usage_error (flag ^ " needs text or json"))
  | _ -> usage_error ("unknown flag " ^ flag)

let parse_server_flags argv =
  let rec go opts = function
    | [] -> opts
    | flag :: rest -> (
        match Server.flag_spec flag with
        | None ->
            if String.length flag > 2 && String.sub flag 0 2 = "--" then
              usage_error ("unknown flag " ^ flag)
            else usage_error ("unexpected argument " ^ flag)
        | Some spec -> (
            match spec.Server.arity with
            | Server.Boolean ->
                go (apply_boolean opts ~key:spec.key ~flag) rest
            | Server.Value -> (
                match rest with
                | [] -> usage_error (flag ^ " needs a value")
                | value :: rest' ->
                    go (apply_value opts ~key:spec.key ~flag value) rest')))
  in
  let opts =
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
  (* The combination guards, ported from cli.py's parser.error calls. *)
  if opts.metrics && (opts.check || opts.live || opts.http || opts.host <> None || opts.port <> None || opts.allowed_hosts <> []) then
    usage_error
      "--metrics reports and exits; it cannot be combined with --check, --live, --http, --host, --port or --allowed-host";
  if opts.json && not opts.metrics then usage_error "--json only makes sense together with --metrics";
  if opts.live && not opts.check then usage_error "--live only makes sense together with --check";
  if (opts.host <> None || opts.port <> None || opts.allowed_hosts <> []) && not opts.http then
    usage_error "--host, --port and --allowed-host only make sense together with --http";
  opts

(* {1 The check} *)

let probe_prose = function
  | Health.Reachable -> "reachable"
  | Health.Reachable_no_key -> "reachable (no key sent)"
  | Health.Key_rejected -> "reachable, but API key rejected"
  | Health.Key_required -> "no API key (key is mandatory)"
  | Health.Unreachable -> "unreachable"
  | Health.Unsupported -> "unsupported (no connectivity probe)"

let default_route_line config =
  match config.Config.default_provider with
  | Some name -> name
  | None ->
      if Config.default_route_is_free_only config then
        "none (a bare search walks the free set)"
      else "none (callers must pass provider)"

let fallback_state config (row : Config.fetch_fallback) =
  if row.Config.endpoint <> None && not (Config.is_permitted config row.Config.name) then
    "(inactive: not permitted)"
  else if row.Config.billable && Config.api_key config row.Config.name = None then
    "(inactive: no API key)"
  else
    match row.Config.endpoint with
    | Some _ -> if row.Config.billable then "keyed" else "keyless"
    | None -> (
        match row.Config.fetch_key with
        | None -> "(inactive: the fallback row names no host)"
        | Some "crawl4ai_url" -> (
            match config.Config.fetch.Config.crawl4ai_url with
            | Some _ -> "configured"
            | None -> "(inactive: no fetch.crawl4ai_url)")
        | Some key -> "(inactive: no fetch." ^ key ^ ")")

let report_fetch config problems =
  let fetch = config.Config.fetch in
  print_endline "fetch";
  if not fetch.Config.enabled then print_endline "  disabled in config"
  else begin
    Printf.printf "  enabled   %d chars max, %d redirects, private addresses %s\n"
      fetch.Config.max_text_chars fetch.Config.max_redirects
      (if fetch.Config.allow_private_addresses then "allowed" else "blocked");
    if fetch.Config.primary = "http" then print_endline "  primary   http (the local reader)"
    else begin
      let row = List.find_opt (fun (r : Config.fetch_fallback) -> r.Config.name = fetch.Config.primary) Config.known_fetch_fallbacks in
      let state =
        match row with
        | Some row -> fallback_state config row
        | None -> "(inactive: no row in the fallback registry)"
      in
      Printf.printf "  primary   %s %s\n" fetch.Config.primary state;
      if String.length state > 9 && String.sub state 0 9 = "(inactive" then
        problems := !problems + 1
    end;
    (match Factory.build_extractor config with
    | Ok _ -> Printf.printf "  extractor %s\n" fetch.Config.extractor
    | Error message ->
        Printf.printf "  extractor %s  UNAVAILABLE: %s\n" fetch.Config.extractor message;
        problems := !problems + 1);
    (match fetch.Config.fallback with
    | None | Some [] -> ()
    | Some names ->
        Printf.printf "  fallback  %s\n" (String.concat " -> " names);
        List.iter
          (fun name ->
            match
              List.find_opt (fun (r : Config.fetch_fallback) -> r.Config.name = name) Config.known_fetch_fallbacks
            with
            | Some row -> Printf.printf "  %-9s %s\n" name (fallback_state config row)
            | None -> Printf.printf "  %-9s (inactive: no row in the fallback registry)\n" name)
          names);
    (match fetch.Config.cache_dir with
    | Some dir ->
        Printf.printf "  cache     %s (%.0f MiB cap, ttl %.0fs)\n" dir
          (float_of_int fetch.Config.cache_max_bytes /. 1_048_576.0)
          fetch.Config.cache_ttl_seconds
    | None -> print_endline "  cache     off")
  end

let report_agent config problems =
  print_endline "agent";
  let agent = config.Config.agent in
  if not agent.Config.enabled then print_endline "  disabled in config"
  else
    match Config.missing_agent_settings config with
    | [] ->
        Printf.printf "  model     %s\n" (Option.value ~default:"" agent.Config.model);
        Printf.printf "  endpoint  %s\n" (Option.value ~default:"" agent.Config.base_url)
    | missing ->
        Printf.printf "  enabled but incomplete: %s\n" (String.concat ", " missing);
        problems := !problems + 1

let check ~env ~sw ~live =
  match Config.load None with
  | Error message ->
      prerr_endline ("seekwright: " ^ message);
      1
  | Ok config ->
      let problems = ref 0 in
      print_endline "seekwright check";
      print_endline "================";
      let path = Config.config_path None in
      Printf.printf "config      %s  %s\n" path
        (if Sys.file_exists path then "(present)" else "(defaults)");
      Printf.printf "default     %s\n" (default_route_line config);
      let permitted =
        match config.Config.permitted_providers with
        | Some names -> String.concat ", " names
        | None -> "(unset: every enabled provider)"
      in
      Printf.printf "permitted   %s\n" permitted;
      print_endline "providers";
      if config.Config.providers_defaulted then
        Printf.printf "  implicit  nothing was enabled, so the keyless set (%s) is the effective set\n"
          (String.concat ", " Config.keyless_providers);
      let built = Factory.build_providers ~sw ~net:(env#net) ~mono_clock:(env#mono_clock) ~now:Unix.gettimeofday config in
      (* The five-set distinction, from the same classification the server's
         startup verdict reads: enabled, effective, built, unsupported, and
         OCaml-untested, each printed once, none folded into another. Every
         offending row is printed — a diagnosis never stops at the first one,
         and this is the same fact {!Factory.startup_verdict} refuses startup
         over for an explicit config. *)
      let sets = Factory.classify config built in
      Printf.printf "  enabled   %s\n"
        (if sets.Factory.enabled = [] then "(none)" else String.concat ", " sets.Factory.enabled);
      Printf.printf "  effective %s\n"
        (if sets.Factory.effective = []
        then "(none)"
        else String.concat ", " sets.Factory.effective);
      Printf.printf "  built     %s\n"
        (if sets.Factory.built = [] then "(none)" else String.concat ", " sets.Factory.built);
      (match sets.Factory.skipped with
      | [] -> ()
      | names ->
          Printf.printf "  skipped   %s  (keyless defaults not built on this port; routing uses the built remainder: %s)\n"
            (String.concat ", " names)
            (String.concat ", " sets.Factory.built));
      (match sets.Factory.unsupported with
      | [] -> ()
      | names -> begin
          (* Counting happens per offender row below, so the exit code carries
             one problem per name the operator has to remove. *)
          Printf.printf "  unsupported %s  (not built on this port; the server refuses to start on this config)\n"
            (String.concat ", " names)
        end);
      (match sets.Factory.untested with
      | [] -> ()
      | names ->
          let verb = if List.length names = 1 then "is" else "are" in
          Printf.printf "  untested  %s %s untested on this port: no live verification against the real endpoint has happened in the OCaml build, and a reachability probe is not one\n"
            (String.concat ", " names) verb);
      if config.Config.providers_defaulted && sets.Factory.built = []
      then begin
        (* The implicit keyless default with nothing keyless built: startup
           would refuse this, and [--check] says so without refusing it. *)
        Printf.printf "  startup   refused: no keyless provider is built on this port\n";
        problems := !problems + 1
      end
      else ();
      List.iter
        (fun (name, message) ->
          Printf.printf "  %-9s grant error: %s\n" name message;
          problems := !problems + 1)
        built.Factory.grant_errors;
      let mono_clock = env#mono_clock in
      let probe_net =
        Factory.probe_net ~sw ~net:(env#net) ~mono_clock
          ~timeout_seconds:config.Config.policy.Config.provider_timeout_seconds
          built.Factory.endpoints
      in
      let ready = ref 0 in
      let lines = ref [] in
      List.iter
        (fun name ->
          match List.assoc_opt name built.Factory.built with
          | None ->
              (* Enabled and not built: one row per offender, with the same
                 words the startup refusal uses. The old branch probed these
                 names and printed "unsupported (no connectivity probe)" —
                 which read as a connectivity verdict on a name that has no
                 adapter at all. *)
              lines := !lines @ [ Printf.sprintf "  %-9s not built on this port" name ];
              if List.mem name sets.Factory.unsupported then problems := !problems + 1
          | Some provider ->
              let outcome = Health.probe ~net:probe_net ~table:built.Factory.probe_table config name in
              let price =
                let cost = Provider.cost_per_1k provider in
                if cost > 0.0 then Printf.sprintf "$%.2f/1k" cost else "unbilled"
              in
              (match outcome with
              | Health.Reachable | Health.Reachable_no_key -> incr ready
              | _ -> problems := !problems + 1);
              lines := !lines @ [ Printf.sprintf "  %-9s %-22s %s" name (probe_prose outcome) price ])
        (Config.enabled_providers config);
      if live then
        lines := !lines @ [ "live probes (one real search per ready permitted provider):" ]
      else if !ready = 0 && !lines = [] then lines := [ "  (none ready)" ];
      List.iter print_endline !lines;
      let enabled = Config.enabled_providers config in
      if !ready > 0 then Printf.printf "%d of %d enabled providers ready\n" !ready (List.length enabled)
      else begin
        print_endline "no providers ready -- searches would fail until configured";
        problems := !problems + 1
      end;
      let effective = Config.effective_providers config in
      if List.length effective <> List.length enabled then
        (* The permission set's doing, spelled out after the rows because it is
           the reason a name above was never probed. *)
        Printf.printf "narrowed    %d of %d enabled providers permitted; not permitted: %s\n"
          (List.length effective) (List.length enabled)
          (String.concat ", " (List.filter (fun name -> not (List.mem name effective)) enabled));
      report_fetch config problems;
      report_agent config problems;
      if !problems > 0 then 1 else 0

(* {1 Metrics} *)

let metric_columns =
  [ "provider"; "calls"; "errors"; "fellback"; "samples"; "p50 ms"; "p95 ms"; "mean ms"; "cost usd"; "$/1k"; "last seen" ]

let milliseconds = function None -> "—" | Some n -> string_of_int n
let per_1k = function None -> "—" | Some v -> Printf.sprintf "%.4f" v

let seen value =
  match value with
  | None -> "—"
  | Some text ->
      (* The journal writes microsecond precision; the column wants seconds. *)
      let n = String.length text in
      let cut = match String.index_opt text '.' with Some i -> i | None -> ( match String.index_opt text '+' with Some i -> i | None -> n) in
      String.sub text 0 cut ^ "Z"

let metric_row entry =
  [
    Option.value ~default:"" (json_string "provider" entry);
    string_of_int (Option.value ~default:0 (json_int "calls" entry));
    string_of_int (Option.value ~default:0 (json_int "errors" entry));
    string_of_int (Option.value ~default:0 (json_int "fell_back_calls" entry));
    string_of_int (Option.value ~default:0 (json_int "latency_samples" entry));
    milliseconds (json_int "p50_ms" entry);
    milliseconds (json_int "p95_ms" entry);
    milliseconds (json_int "mean_ms" entry);
    Printf.sprintf "%.4f" (Option.value ~default:0.0 (json_float "cost_usd" entry));
    per_1k (json_float "cost_per_1k" entry);
    seen (json_string "last_seen" entry);
  ]

let format_row cells widths =
  let last = List.length cells - 1 in
  String.concat "  "
    (List.mapi
       (fun i cell ->
         if i = 0 || i = last then
           cell ^ String.make (max 0 (List.nth widths i - String.length cell)) ' '
         else
           String.make (max 0 (List.nth widths i - String.length cell)) ' ' ^ cell)
       cells)

let journal_state journal =
  match json_string "path" journal with
  | None -> "off — dashboard.history_path unset"
  | Some path ->
      Printf.sprintf "%s  %s" path
        (match json_bool "failed" journal with Some true -> "failed" | _ -> "ok")

let print_metrics endpoints journal =
  let today = Unix.gmtime (Unix.gettimeofday ()) in
  let window_days = Option.value ~default:14 (json_int "window_days" endpoints) in
  let first = Unix.gmtime (Unix.gettimeofday () -. float_of_int (window_days - 1) *. 86_400.0) in
  let iso day =
    Printf.sprintf "%04d-%02d-%02d" (day.Unix.tm_year + 1900) (day.Unix.tm_mon + 1) day.Unix.tm_mday
  in
  print_endline "seekwright metrics";
  print_endline "==================";
  Printf.printf "window      %d days, %s .. %s (UTC)\n" window_days (iso first) (iso today);
  Printf.printf "journal     %s\n" (journal_state journal);
  print_newline ();
  match json_list "providers" endpoints with
  | None | Some [] -> print_endline "no history"
  | Some entries ->
      let rows = List.map metric_row entries in
      let widths =
        List.mapi
          (fun i label ->
            List.fold_left (fun acc row -> max acc (String.length (List.nth row i))) (String.length label) rows)
          metric_columns
      in
      print_endline (format_row metric_columns widths);
      List.iter (fun row -> print_endline (format_row row widths)) rows

let metrics ~env ~as_json =
  match Config.load None with
  | Error message ->
      prerr_endline ("seekwright: " ^ message);
      1
  | Ok config -> (
      let history_path =
        match config.Config.dashboard.Config.history_path with
        | None -> None
        | Some path -> Some Eio.Path.(env#fs / path)
      in
      match Usage.create ~now:Unix.gettimeofday ?history_path () with
      | Error message ->
          prerr_endline ("seekwright: dashboard.history_path: " ^ message);
          1
      | Ok recorder -> (
          let snapshot = Usage.snapshot recorder in
          let endpoints = json_field "endpoints" snapshot in
          let journal = json_field "journal" snapshot in
          if as_json then begin
            print_endline (Yojson.Safe.pretty_to_string endpoints);
            0
          end
          else begin
            print_metrics endpoints journal;
            0
          end))

(* {1 The client} *)

type scanned = {
  positional : string list;
  flags : (string * string list) list;
  bools : string list;
}

let scan_args argv =
  let rec go scanned = function
    | [] -> scanned
    | "--json" :: rest -> go { scanned with bools = "--json" :: scanned.bools } rest
    | "--no-safe-search" :: rest ->
        go { scanned with flags = ("--safe-search", [ "false" ]) :: scanned.flags } rest
    | "--safe-search" :: rest ->
        go { scanned with flags = ("--safe-search", [ "true" ]) :: scanned.flags } rest
    | flag :: rest
      when String.length flag > 2 && String.sub flag 0 2 = "--" -> (
        if String.contains flag '=' then
          let eq = String.index flag '=' in
          let name = String.sub flag 0 eq in
          let value = String.sub flag (eq + 1) (String.length flag - eq - 1) in
          go { scanned with flags = (name, [ value ]) :: scanned.flags } rest
        else
          match rest with
          | value :: rest'
            when not (String.length value > 2 && String.sub value 0 2 = "--") ->
              go { scanned with flags = (flag, [ value ]) :: scanned.flags } rest'
          | _ -> usage_error (flag ^ " needs a value"))
    | arg :: rest -> go { scanned with positional = arg :: scanned.positional } rest
  in
  let scanned = go { positional = []; flags = []; bools = [] } argv in
  { scanned with positional = List.rev scanned.positional; flags = List.rev scanned.flags }

let flag_values scanned name =
  List.rev (List.concat_map (fun (flag, values) -> if flag = name then values else []) scanned.flags)

let flag_one scanned name = match flag_values scanned name with value :: _ -> Some value | [] -> None
let flag_bool scanned name = List.mem name scanned.bools

let recency_of_string = function
  | "day" -> Some Model.Day
  | "week" -> Some Model.Week
  | "month" -> Some Model.Month
  | "year" -> Some Model.Year
  | _ -> None

let int_flag scanned name ~default =
  match flag_one scanned name with
  | Some text -> (
      match int_of_string_opt text with Some n -> n | None -> usage_error (name ^ " needs a number"))
  | None -> default

let bool_flag scanned name =
  match flag_values scanned name with
  | "true" :: _ -> Some true
  | "false" :: _ -> Some false
  | _ -> None

let list_flag scanned name =
  match flag_values scanned name with [] -> None | values -> Some values

let domain_flags scanned =
  (list_flag scanned "--include-domain", list_flag scanned "--exclude-domain")

let validate_request decode json =
  match decode json with
  | Ok _ -> json
  | Error message -> usage_error ("Invalid request: " ^ message ^ ".")

let search_body scanned =
  let positional = scanned.positional in
  let query =
    match positional with
    | [ query ] -> query
    | [] -> usage_error "search needs a QUERY"
    | _ -> usage_error "search takes exactly one QUERY"
  in
  let include_domains, exclude_domains = domain_flags scanned in
  let recency =
    match flag_one scanned "--recency" with
    | Some text -> (
        match recency_of_string text with
        | Some r -> Some r
        | None -> usage_error "--recency needs day, week, month or year")
    | None -> None
  in
  let request : Model.search_request =
    {
      Model.query;
      provider = flag_one scanned "--provider";
      mode = None;
      max_results = int_flag scanned "--max-results" ~default:5;
      include_domains;
      exclude_domains;
      recency;
      language = flag_one scanned "--language";
      safe_search = bool_flag scanned "--safe-search";
    }
  in
  validate_request Model.search_request_of_yojson (Model.search_request_to_yojson request)

let fetch_body scanned =
  let url =
    match scanned.positional with
    | [ url ] -> url
    | [] -> usage_error "fetch needs a URL"
    | _ -> usage_error "fetch takes exactly one URL"
  in
  (* exclude_defaults, as the Python client spells it: a field the caller did
     not pass is absent from the body, and [structure] only when true. *)
  let fields =
    [ ("url", `String url) ]
    @ (match flag_one scanned "--query" with Some q -> [ ("query", `String q) ] | None -> [])
    @ (match flag_one scanned "--offset" with
      | Some text -> (
          match int_of_string_opt text with
          | Some n -> [ ("offset", `Int n) ]
          | None -> usage_error "--offset needs a number")
      | None -> [])
    @ (match flag_one scanned "--path" with Some p -> [ ("path", `String p) ] | None -> [])
    @ (if flag_bool scanned "--structure" then [ ("structure", `Bool true) ] else [])
    @ (match flag_one scanned "--provider" with Some p -> [ ("provider", `String p) ] | None -> [])
  in
  validate_request Model.fetch_request_of_yojson (`Assoc fields)

let answer_body scanned =
  let query =
    match scanned.positional with
    | [ query ] -> query
    | [] -> usage_error "answer needs a QUERY"
    | _ -> usage_error "answer takes exactly one QUERY"
  in
  let include_domains, exclude_domains = domain_flags scanned in
  let depth =
    match flag_one scanned "--depth" with
    | Some "brief" -> Some Model.Brief
    | Some "report" -> Some Model.Report
    | Some _ -> usage_error "--depth needs brief or report"
    | None -> None
  in
  let recency =
    match flag_one scanned "--recency" with
    | Some text -> (
        match recency_of_string text with
        | Some r -> Some r
        | None -> usage_error "--recency needs day, week, month or year")
    | None -> None
  in
  let request : Model.answer_request =
    {
      Model.query;
      extra_queries = list_flag scanned "--extra-query";
      depth;
      provider = flag_one scanned "--provider";
      include_domains;
      exclude_domains;
      recency;
      language = flag_one scanned "--language";
      safe_search = bool_flag scanned "--safe-search";
    }
  in
  validate_request Model.answer_request_of_yojson (Model.answer_request_to_yojson request)

let tls_client_config =
  lazy
    (match Ca_certs.authenticator () with
    | Error _ -> None
    | Ok authenticator -> (
        match Tls.Config.client ~authenticator () with
        | Ok config -> Some config
        | Error _ -> None))

let post_json ~env ~sw ~server path body =
  let uri = Uri.of_string (server ^ path) in
  let client =
    match Uri.scheme uri with
    | Some "https" -> (
        match Lazy.force tls_client_config with
        | Some config ->
            let host_of uri =
              Domain_name.host_exn (Domain_name.of_string_exn (Option.value ~default:"" (Uri.host uri)))
            in
            Cohttp_eio.Client.make
              ~https:(Some (fun uri flow -> Tls_eio.client_of_flow config ~host:(host_of uri) flow))
              env#net
        | None -> usage_error "https needs the system trust store, which is missing")
    | _ -> Cohttp_eio.Client.make ~https:None env#net
  in
  let headers =
    Http.Header.of_list
      [ ("content-type", "application/json"); ("accept", "application/json") ]
  in
  let response, response_body =
    Cohttp_eio.Client.call client ~sw ~headers
      ~body:(Cohttp_eio.Body.of_string body)
      `POST uri
  in
  let status = Http.Status.to_int (Http.Response.status response) in
  let text =
    Eio.Buf_read.(take_all (of_flow response_body ~max_size:(64 * 1024 * 1024)))
  in
  (status, text)

let error_message status text =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error _ ->
      Printf.sprintf "HTTP %d%s" status (if text = "" then "" else ": " ^ String.trim text)
  | json -> (
      match json_field "error" json with
      | `String message -> Printf.sprintf "HTTP %d: %s" status message
      | _ ->
          Printf.sprintf "HTTP %d%s" status
            (if String.trim text = "" then "" else ": " ^ String.trim text))

(* {1 Human rendering} *)

type human_response =
  | Human_search of Model.search_response
  | Human_fetch of Model.fetch_response
  | Human_answer of Model.answer_response

let print_human response =
  match response with
  | Human_search sresp ->
      print_endline "seekwright search";
      print_endline "=================";
      Printf.printf "query     %s\n" sresp.Model.query;
      Printf.printf "provider  %s\n" sresp.Model.provider;
      Printf.printf "results   %d\n" (List.length sresp.Model.results);
      if sresp.Model.results = [] then begin
        print_newline ();
        print_endline "no results"
      end;
      List.iteri
        (fun index (result : Model.result) ->
          print_newline ();
          Printf.printf "%d. %s\n" (index + 1) result.Model.title;
          Printf.printf "   %s\n" result.Model.url;
          let content =
            match result.Model.snippet with Some s -> Some s | None -> result.Model.text
          in
          match content with
          | Some text ->
              String.split_on_char '\n' text
              |> List.iter (fun line -> Printf.printf "   %s\n" line)
          | None -> ())
        sresp.Model.results;
      (match sresp.Model.notice with
      | Some notice ->
          print_newline ();
          Printf.printf "notice: %s\n" notice
      | None -> ())
  | Human_fetch fresp ->
      print_endline "seekwright fetch";
      print_endline "================";
      Printf.printf "url       %s\n" fresp.Model.url;
      if fresp.Model.requested_url <> fresp.Model.url then
        Printf.printf "requested %s\n" fresp.Model.requested_url;
      (match fresp.Model.title with
      | Some title -> Printf.printf "title     %s\n" title
      | None -> ());
      (match fresp.Model.total_chars with
      | Some total ->
          Printf.printf "chars     %d%s\n" total (if fresp.Model.truncated then ", truncated" else "")
      | None -> ());
      (match fresp.Model.image with
      | Some image ->
          Printf.printf "image     %s, %d bytes (base64 in --json)\n"
            (Option.value ~default:"" fresp.Model.content_type)
            image.Model.byte_count
      | None -> ());
      (match fresp.Model.text with
      | Some text when text <> "" ->
          print_newline ();
          print_endline text
      | _ -> ());
      (match fresp.Model.matches with
      | Some matches ->
          List.iter
            (fun (match_ : Model.fetch_match) ->
              print_newline ();
              Printf.printf "match at %d:\n" match_.Model.offset;
              print_endline match_.Model.text)
            matches
      | None -> ());
      (match fresp.Model.notice with
      | Some notice ->
          print_newline ();
          Printf.printf "notice: %s\n" notice
      | None -> ())
  | Human_answer aresp ->
      print_endline "seekwright answer";
      print_endline "==================";
      Printf.printf "query     %s\n" aresp.Model.query;
      Printf.printf "model     %s\n" aresp.Model.model;
      Printf.printf "depth     %s\n"
        (match aresp.Model.depth with Model.Brief -> "brief" | Model.Report -> "report");
      Printf.printf "searches  %d\n" aresp.Model.searches;
      Printf.printf "fetched   %d\n" aresp.Model.fetched;
      (match aresp.Model.truncated with
      | Some true -> print_endline "the answer stopped at the model's output cap and is cut short"
      | _ -> ());
      print_newline ();
      print_endline aresp.Model.answer;
      print_newline ();
      if aresp.Model.sources = [] then print_endline "sources   none cited"
      else begin
        Printf.printf "sources   %d\n" (List.length aresp.Model.sources);
        List.iteri
          (fun index (source : Model.answer_source) ->
            Printf.printf "%d. %s\n" (index + 1) source.Model.source_title;
            Printf.printf "   %s\n" source.Model.source_url;
            Printf.printf "   via %s\n" source.Model.source_provider)
          aresp.Model.sources
      end;
      (match aresp.Model.notice with
      | Some notice ->
          print_newline ();
          Printf.printf "notice: %s\n" notice
      | None -> ())

let run_client ~env command argv =
  Mirage_crypto_rng_unix.use_default ();
  let scanned = scan_args argv in
  let server =
    match flag_one scanned "--server" with
    | Some url -> String.sub url 0 (String.length url - (if String.length url > 0 && url.[String.length url - 1] = '/' then 1 else 0))
    | None -> default_server
  in
  let as_json = flag_bool scanned "--json" in
  let body, model_name, printer =
    match command with
    | "search" ->
        let body = search_body scanned in
        (body, "SearchResponse", `Search)
    | "fetch" ->
        let body = fetch_body scanned in
        (body, "FetchResponse", `Fetch)
    | _ ->
        let body = answer_body scanned in
        (body, "AnswerResponse", `Answer)
  in
  Eio.Switch.run @@ fun sw ->
  let status, text = post_json ~env ~sw ~server ("/api/v1/" ^ command) (Yojson.Safe.to_string body) in
  if status <> 200 then begin
    prerr_endline ("seekwright: " ^ error_message status text);
    1
  end
  else
    let parsed =
      match printer with
      | `Search -> (
          match Model.search_response_of_yojson (Yojson.Safe.from_string text) with
          | Ok response -> Some (Human_search response)
          | Error _ -> None)
      | `Fetch -> (
          match Model.fetch_response_of_yojson (Yojson.Safe.from_string text) with
          | Ok response -> Some (Human_fetch response)
          | Error _ -> None)
      | `Answer -> (
          match Model.answer_response_of_yojson (Yojson.Safe.from_string text) with
          | Ok response -> Some (Human_answer response)
          | Error _ -> None)
    in
    match parsed with
    | None ->
        prerr_endline ("seekwright: the response is not a " ^ model_name);
        1
    | Some response ->
        if as_json then print_endline text
        else print_human response;
        0

(* {1 The server} *)

let startup_log log config (built : Factory.providers) =
  log Config.Log_info "startup"
    [
      (* The built set — the same set and order [/healthz] reports — not the
         enabled set: an explicit enabled-without-adapter config never reaches
         this line ([Seekwright_factory.startup_verdict] refuses startup), and
         the [startup.providers_unsupported] warning below names exactly the
         keyless names the implicit default skipped. *)
      ("providers", `String (String.concat "," (List.map fst built.Factory.built)));
      ( "unsupported",
        (match built.Factory.unsupported with
        | [] -> `Null
        | names -> `String (String.concat "," names)) );
      ( "default_provider",
        (match config.Config.default_provider with
        | Some name -> `String name
        | None -> `Null) );
      ("providers_defaulted", `Bool config.Config.providers_defaulted);
      ("fetch", `Bool config.Config.fetch.Config.enabled);
      ("fetch_extractor", `String config.Config.fetch.Config.extractor);
      ("fetch_primary", `String config.Config.fetch.Config.primary);
      ( "agent",
        (match config.Config.agent.Config.model with
        | Some model -> `String model
        | None -> `Null) );
    ]

let run_server ~env ~sw opts =
  Mirage_crypto_rng_unix.use_default ();
  match Config.load None with
  | Error message ->
      prerr_endline ("seekwright: " ^ message);
      exit 1
  | Ok config ->
      let logging =
        Log.apply_overrides config.Config.logging opts.log_level opts.log_format
      in
      let log = Log.sink (Log.make logging) in
      (match Config.missing_api_keys config with
      | [] -> ()
      | missing ->
          prerr_endline
            ("seekwright: missing API key(s) for enabled provider(s): "
            ^ String.concat ", "
                (List.map (fun name -> name ^ " (" ^ Config.api_key_env_var name ^ ")") missing));
          exit 1);
      if config.Config.fetch.Config.enabled then (
        match Factory.build_extractor config with
        | Ok _ -> ()
        | Error message ->
            prerr_endline ("seekwright: " ^ message);
            exit 1);
      if config.Config.fetch.Config.enabled && config.Config.fetch.Config.primary <> "http" then begin
        prerr_endline
          (Printf.sprintf
             "seekwright: fetch.primary names %S, which this deployment cannot build (see `seekwright --check` for why); refusing to start rather than read from this server's own IP unasked"
             config.Config.fetch.Config.primary);
        exit 1
      end;
      (match Config.missing_agent_settings config with
      | [] -> ()
      | missing ->
          prerr_endline ("seekwright: agent mode is enabled but missing " ^ String.concat ", " missing);
          exit 1);
      match
        Factory.build_app ~sw ~env ~now:Unix.gettimeofday ~log ~allowed_hosts:opts.allowed_hosts config
      with
      | Error message ->
          prerr_endline ("seekwright: " ^ message);
          exit 1
      | Ok (app, built) ->
          startup_log log config built;
          (* Reachable only under the implicit keyless default: an explicit
             enabled name with no adapter was refused by the [build_app] arm
             above, so anything listed here is a skipped keyless default,
             disclosed by name exactly as [startup_verdict] skipped it. *)
          if built.Factory.unsupported <> [] then
            log Config.Log_warning "startup.providers_unsupported"
              [
                ( "unsupported",
                  `String (String.concat "," built.Factory.unsupported) );
              ];
          (match Server.mcp_server app with
          | Error (Caps.Server.Duplicate_tool name) ->
              prerr_endline ("seekwright: duplicate tool: " ^ name);
              exit 1
          | Error (Caps.Server.Invalid_declaration message) ->
              prerr_endline ("seekwright: " ^ message);
              exit 1
          | Ok server ->
              if opts.http then begin
                let host = Option.value ~default:"127.0.0.1" opts.host in
                let port = Option.value ~default:8000 opts.port in
                log Config.Log_info "http.listening"
                  [ ("host", `String host); ("port", `Int port) ];
                (match
                   Server.serve_http ~env ~sw ~log app server ~host ~port
                 with
                | Ok () -> ()
                | Error Server.Bind_address_unresolved ->
                    prerr_endline
                      "seekwright: cannot resolve the HTTP bind address";
                    exit 1
                | Error Server.Listener_unavailable ->
                    prerr_endline "seekwright: cannot open the HTTP listener";
                    exit 1)
              end
              else Mcp_kit_stdio.run_channels server stdin stdout)

(* {1 Main} *)

let () =
  (* Every path that can build a network grant needs a generator installed:
     the TLS stack reads one at grant-construction time, and the check path
     builds grants for its probes without ever building the MCP server. *)
  Mirage_crypto_rng_unix.use_default ();
  let argv = List.tl (Array.to_list Sys.argv) in
  match argv with
  | verb :: rest when List.mem verb Server.cli_verbs ->
      Eio_main.run @@ fun env -> exit (run_client ~env verb rest)
  | _ -> (
      let opts = parse_server_flags argv in
      if opts.metrics then
        Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun _sw -> exit (metrics ~env ~as_json:opts.json)
      else if opts.check then
        Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw -> exit (check ~env ~sw ~live:opts.live)
      else
        Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw -> run_server ~env ~sw opts)
