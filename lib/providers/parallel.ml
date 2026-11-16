module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Mcp = Mcp_client

let ( let* ) = Result.bind

let name = "parallel"

let endpoint = Uri.of_string "https://api.parallel.ai/v1/search"

let mcp_uri = Uri.of_string "https://search.parallel.ai/mcp"

let policy_endpoint = Provider.policy_of_uri endpoint

(* Coarse freshness to day count: Day (1), Week (7), Month (30), Year (365). *)
let recency_days = function
  | Model.Day -> 1
  | Model.Week -> 7
  | Model.Month -> 30
  | Model.Year -> 365

(* Days since epoch, floored to handle pre-1970 dates correctly. *)
let days_since_epoch (now : float) =
  let seconds = Int64.of_float (floor now) in
  let days = Int64.div seconds 86400L in
  let days =
    if seconds < 0L && Int64.rem seconds 86400L <> 0L then Int64.succ days else days
  in
  Int64.to_int days

(* Howard Hinnant's civil_from_days: calendar date from day count without timezone. *)
let civil_from_days z0 =
  let z = z0 + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = (5 * doy + 2) / 153 in
  let day = doy - ((153 * mp + 2) / 5) + 1 in
  let month = if mp < 10 then mp + 3 else mp - 9 in
  let year = if month <= 2 then y + 1 else y in
  (year, month, day)

let after_date ~(now : unit -> float) period =
  let days = days_since_epoch (now () -. float_of_int (recency_days period * 86400)) in
  let (year, month, day) = civil_from_days days in
  Printf.sprintf "%04d-%02d-%02d" year month day

(* Shared result parser for both REST and MCP payloads. *)
let parse_results data ~limit ~text_chars =
  let items =
    match data with
    | `Assoc _ -> (
        match Provider.Json.field "results" data with
        | `List items -> items
        | _ -> [])
    | _ -> []
    (* a JSON array or scalar is not a result set *)
  in
  let hits =
    List.filter_map
      (fun item ->
        match Provider.Json.string_field "url" item with
        | None | Some "" -> None
        | Some url ->
            (* [excerpts] is a list of strings; anything else in it is not
               prose and is skipped. *)
            let excerpts =
              match Provider.Json.field "excerpts" item with
              | `List parts ->
                  List.filter_map
                    (fun part ->
                      match part with `String text when text <> "" -> Some text | _ -> None)
                    parts
              | _ -> []
            in
            let clipped, truncated, uncapped_chars =
              Provider.truncate_text (Some (String.concat "\n\n" excerpts)) text_chars
            in
            let title =
              match Provider.Json.string_field "title" item with
              | Some title when title <> "" -> title
              | _ -> url
            in
            Some
              {
                Provider.result =
                  {
                    Model.title;
                    url;
                    snippet = None;
                    text = clipped;
                    text_truncated = (if truncated then Some true else None);
                    published_date = Provider.Json.string_field "publish_date" item;
                    score = None;
                  };
                uncapped_chars;
              })
      (List.filteri (fun i _ -> i < limit) items)
  in
  hits

(* Request body with advanced_settings for domain, date, and location filters. *)
let request_body ~(mode : string) ~(now : unit -> float) (q : Provider.search_query) =
  let source_policy =
    let s = [] in
    let s =
      if q.Model.include_domains <> [] then
        ("include_domains", `List (List.map (fun d -> `String d) q.Model.include_domains)) :: s
      else s
    in
    let s =
      if q.Model.exclude_domains <> [] then
        ("exclude_domains", `List (List.map (fun d -> `String d) q.Model.exclude_domains)) :: s
      else s
    in
    match q.Model.recency with
    | Some period -> ("after_date", `String (after_date ~now period)) :: s
    | None -> s
  in
  let advanced =
    let a = [ ("max_results", `Int q.Model.max_results) ] in
    let a = if source_policy <> [] then ("source_policy", `Assoc source_policy) :: a else a in
    match q.Model.country with
    | Some country -> ("location", `String country) :: a
    | None -> a
  in
  `Assoc
    [
      ("search_queries", `List [ `String q.Model.query ]);
      ("mode", `String mode);
      ("advanced_settings", `Assoc advanced);
    ]

(* Upstream ignores exclude_domains when include_domains is present; notices report this. *)
let compose_notices (q : Provider.search_query) data =
  let parts =
    let p = [] in
    let p =
      if q.Model.include_domains <> [] && q.Model.exclude_domains <> [] then
        "parallel ignores exclude_domains while include_domains is set; that constraint was ignored"
        :: p
      else p
    in
    let p =
      if q.Model.language <> None then
        "cannot filter by language; that constraint was ignored" :: p
      else p
    in
    let p =
      if q.Model.safe_search <> None then
        "cannot filter by safe-search; that constraint was ignored" :: p
      else p
    in
    let warnings =
      match data with `Assoc _ -> Provider.Json.field "warnings" data | _ -> `Null
    in
    let p =
      match warnings with
      | `List entries ->
          let messages =
            List.filter_map
              (fun entry -> Provider.Json.string_field "message" entry)
              entries
          in
          if messages <> [] then
            ("upstream warnings: " ^ String.concat "; " messages) :: p
          else p
      | _ -> p
    in
    List.rev p
  in
  if parts = [] then None else Some (String.concat "; " parts)

let check_status status =
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then
    Error (Provider.quota_exhausted ~provider:name ~message:"rate limited or out of credits" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

let make ?(cost_per_1k = 1.00) ?(text_chars = 2000) ?(mode = "fast") ~key ~now ~net () =
  let adapter =
    (module struct
      let name = name
      let cost_per_1k = cost_per_1k
      let cost_for _max_results = cost_per_1k /. 1000.0

      let search (q : Provider.search_query) =
        let request : Caps.Authority.Net.request =
          {
            meth = `POST;
            uri = endpoint;
            headers =
              [ ("x-api-key", key); ("Content-Type", "application/json") ];
            body = Some (Yojson.Safe.to_string (request_body ~mode ~now q));
          }
        in
        let* response =
          Result.map_error
            (fun failure ->
              if Caps.Error.kind failure = Caps.Error.Timeout then
                Provider.timeout_error ~provider:name
              else Provider.network_error ~provider:name)
            (net.Provider.Net.request request)
        in
        let* () = check_status response.Caps.Authority.Net.status in
        let data =
          match Yojson.Safe.from_string response.Caps.Authority.Net.body with
          | exception Yojson.Json_error _ -> None
          | data -> Some data
        in
        match data with
        | None -> Error (Provider.provider_error ~provider:name "malformed JSON response")
        | Some data ->
            Ok
              {
                Provider.provider = name;
                results = parse_results data ~limit:q.Model.max_results ~text_chars;
                answer = None;
                cost_usd = Some (cost_for q.Model.max_results);
                notice = compose_notices q data;
              }

      let aclose () = ()
    end : Provider.S)
  in
  adapter

let mcp_tool = "web_search"

let mcp_arguments (q : Provider.search_query) =
  `Assoc
    [
      ("objective", `String q.Model.query);
      ("search_queries", `List [ `String q.Model.query ]);
    ]

let make_mcp ?(cost_per_1k = 0.0) ?(text_chars = 2000) ~name ~uri ~net () =
  let client = Mcp.create ~provider:name ~net ~uri () in
  let adapter =
    (module struct
      let name = name
      let cost_per_1k = cost_per_1k
      let cost_for = Exa.cost_for ~cost_per_1k

      let search q =
        let* answer = Mcp.call_tool client ~name:mcp_tool ~arguments:(mcp_arguments q) in
        let data =
          match Yojson.Safe.from_string answer.Mcp.text with
          | exception Yojson.Json_error _ -> None
          | data -> Some data
        in
        match data with
        | None -> Error (Provider.provider_error ~provider:name "malformed JSON response")
        | Some data ->
            Ok
              {
                Provider.provider = name;
                results = parse_results data ~limit:q.Model.max_results ~text_chars;
                answer = None;
                cost_usd = Some (cost_for q.Model.max_results);
                notice =
                  Provider.ignored_constraints q ~domains:false ~dates:false ~geo:false
                    ~language:None ~safety:false;
              }

      let aclose () = Mcp.aclose client
    end : Provider.S)
  in
  {
    Provider.adapter;
    Provider.warmup = (fun () -> Result.is_ok (Mcp.connect client));
  }
