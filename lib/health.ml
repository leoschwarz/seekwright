type log = Config.log_level -> string -> (string * Yojson.Safe.t) list -> unit

let default_failure_threshold = 3
let default_cooldown_seconds = 120.0

type state = {
  mutable consecutive : int;
  (* 0. = never opened / closed. A past deadline is a half-open gate. *)
  mutable open_until : float;
}

type t = {
  now : unit -> float;
  failure_threshold : int;
  cooldown_seconds : float;
  log : log option;
  mutable states : (Config.name * state) list;
}

let create ~now ?(failure_threshold = default_failure_threshold)
    ?(cooldown_seconds = default_cooldown_seconds) ?log () : t =
  { now; failure_threshold; cooldown_seconds; log; states = [] }

let emit (t : t) level event fields = match t.log with Some f -> f level event fields | None -> ()

let ensure (t : t) (name : Config.name) : state =
  match List.assoc_opt name t.states with
  | Some found -> found
  | None ->
      let created = { consecutive = 0; open_until = 0. } in
      t.states <- t.states @ [ (name, created) ];
      created

let find (t : t) (name : Config.name) : state option = List.assoc_opt name t.states

let armed (s : state) : bool = s.consecutive <> 0 || s.open_until <> 0.

let record_failure (t : t) ?(reason = "failed") ?(force_open = false) (name : Config.name) () : unit
    =
  let now = t.now () in
  let s = ensure t name in
  s.consecutive <- s.consecutive + 1;
  let was_open = s.open_until > now in
  let half_open = s.open_until <> 0. && not was_open in
  if force_open || half_open || s.consecutive >= t.failure_threshold then begin
    s.open_until <- now +. t.cooldown_seconds;
    if not was_open then
      emit t Config.Log_info "health.open"
        [
          ("provider", `String name); ("reason", `String reason); ("consecutive", `Int s.consecutive);
        ]
  end

let record_success (t : t) ?(reason = "succeeded") (name : Config.name) () : unit =
  match find t name with
  | None -> ()
  | Some s when not (armed s) -> ()
  | Some s ->
      let was_armed = s.open_until <> 0. in
      s.consecutive <- 0;
      s.open_until <- 0.;
      if was_armed then
        emit t Config.Log_info "health.closed"
          [ ("provider", `String name); ("reason", `String reason) ]

let is_open (t : t) (name : Config.name) : bool =
  match find t name with Some s -> s.open_until > t.now () | None -> false

let open_for_s (t : t) (name : Config.name) : float =
  match find t name with None -> 0. | Some s -> max 0. (s.open_until -. t.now ())

type outcome =
  | Reachable
  | Reachable_no_key
  | Key_rejected
  | Key_required
  | Unreachable
  | Unsupported

let show_outcome = function
  | Reachable -> "reachable"
  | Reachable_no_key -> "reachable_no_key"
  | Key_rejected -> "key_rejected"
  | Key_required -> "key_required"
  | Unreachable -> "unreachable"
  | Unsupported -> "unsupported"

type probe_spec = {
  endpoint : Config.t -> string option -> string option;
  headers : Config.t -> string option -> (string * string) list;
}

let no_headers (_ : Config.t) (_ : string option) : (string * string) list = []

let no_probe : probe_spec = { endpoint = (fun _ _ -> None); headers = no_headers }

let probe_endpoint_const (url : string) : Config.t -> string option -> string option =
 fun _ _ -> Some url

let probe_headers_const ?(prefix = "") (header : string) :
    Config.t -> string option -> (string * string) list =
 fun _ key -> match key with Some k -> [ (header, prefix ^ k) ] | None -> []

let url_form_escape (value : string) : string =
  let out = Buffer.create (String.length value * 3) in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '~' -> Buffer.add_char out c
      | ' ' -> Buffer.add_char out '+'
      | _ -> Buffer.add_string out (Printf.sprintf "%%%02X" (Char.code c)))
    value;
  Buffer.contents out

let rstrip_slash (url : string) : string =
  let rec last i =
    if i < 0 then "" else if url.[i] <> '/' then String.sub url 0 (i + 1) else last (i - 1)
  in
  last (String.length url - 1)

let searxng_endpoint (config : Config.t) (_key : string option) : string option =
  match Config.provider config "searxng" with
  | None -> None
  | Some pc -> (
      match pc.Config.url with
      | None -> None
      | Some base when String.length base = 0 -> None
      | Some base -> Some (rstrip_slash base ^ "/search?q=probe&format=json"))

let algolia_deployment (config : Config.t) : (string * string) option =
  match Config.provider config "algolia" with
  | None -> None
  | Some pc -> (
      match (pc.Config.app_id, pc.Config.index) with
      | Some app_id, Some index when String.length app_id > 0 && String.length index > 0 ->
          Some (app_id, index)
      | _ -> None)

let algolia_endpoint (config : Config.t) (_key : string option) : string option =
  match algolia_deployment config with
  | None -> None
  | Some (app_id, index) ->
      Some
        (Printf.sprintf "https://%s-dsn.algolia.net/1/indexes/%s/query" app_id
           (Provider.escape_path_segment index)
        ^ "?query=probe&hitsPerPage=notanumber")

let algolia_headers (config : Config.t) (key : string option) : (string * string) list =
  match algolia_deployment config with
  | None -> []
  | Some (app_id, _) -> (
      let base = [ ("x-algolia-application-id", app_id) ] in
      match key with Some k -> base @ [ ("x-algolia-api-key", k) ] | None -> base)

let serpapi_endpoint ~(base : string) : Config.t -> string option -> string option =
 fun _config key ->
  let value = Option.value ~default:"None" key in
  Some (base ^ "?api_key=" ^ url_form_escape value)

let probe ~(net : Provider.Net.t) ~table (config : Config.t) (name : Config.name) : outcome =
  let key = Config.api_key name in
  if key = None && List.mem name Config.providers_requiring_key then Key_required
  else
    let spec = match List.assoc_opt name table with Some s -> s | None -> no_probe in
    match spec.endpoint config key with
    | None -> Unsupported
    | Some url -> (
        let request : Mcp_caps.Authority.Net.request =
          { meth = `GET; uri = Uri.of_string url; headers = spec.headers config key; body = None }
        in
        match net.request request with
        | Error _ -> Unreachable
        | Ok response ->
            if key = None then Reachable_no_key
            else if response.status = 401 || response.status = 403 then Key_rejected
            else Reachable)

let probe_event = function
  | Reachable | Reachable_no_key | Unreachable | Key_rejected -> true
  | Key_required | Unsupported -> false

let run_probes (config : Config.t) ~built ~table ~(net : Provider.Net.t) (board : t) : unit =
  List.iter
    (fun name ->
      if not (List.mem name built) then ()
      else begin
        let started = board.now () in
        let outcome = probe ~net ~table config name in
        let ms = int_of_float ((board.now () -. started) *. 1000.) in
        emit board Config.Log_debug "health.probe"
          [
            ("provider", `String name); ("outcome", `String (show_outcome outcome)); ("ms", `Int ms);
          ];
        match outcome with
        | Reachable | Reachable_no_key -> record_success board ~reason:"probe reachable" name ()
        | Unreachable -> record_failure board ~reason:"probe unreachable" name ()
        | Key_rejected -> record_failure board ~reason:"probe key rejected" ~force_open:true name ()
        | _ -> ()
      end)
    (Config.enabled_providers config)
