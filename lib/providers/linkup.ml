module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "linkup"

let endpoint = Uri.of_string "https://api.linkup.so/v1/search"

let policy_endpoint = Provider.policy_of_uri endpoint

(* Output format: Sourced_answer returns prose answer and citations;
   Search_results returns structured hits. *)
type output =
  | Sourced_answer
  | Search_results

let show_output = function
  | Sourced_answer -> "sourcedAnswer"
  | Search_results -> "searchResults"

(* Coarse freshness to day count: Day (1), Week (7), Month (30), Year (365). *)
let age_days = function
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

(* Injected clock allows deterministic testing of date calculations. *)
let format_utc (epoch : float) =
  let days = days_since_epoch epoch in
  let seconds = Int64.of_float (floor epoch) in
  let (year, month, day) = civil_from_days days in
  let clock = Int64.to_int (Int64.sub seconds (Int64.mul 86400L (Int64.of_int days))) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" year month day
    (clock / 3600)
    ((clock mod 3600) / 60)
    (clock mod 60)

let from_date (now : unit -> float) period = format_utc (now () -. float_of_int (age_days period * 86400))

(* Upstream request body encoding: query, depth, outputType, maxResults, filters. *)
let request_body ~depth ~output ~(from_date : string option) (q : Provider.search_query) =
  let fields =
    [
      ("q", `String q.Model.query);
      ("depth", `String depth);
      ("outputType", `String (show_output output));
      ("maxResults", `Int q.Model.max_results);
    ]
  in
  let fields =
    if q.Model.include_domains <> [] then
      fields
      @ [
          ( "includeDomains",
            `List (List.map (fun domain -> `String domain) q.Model.include_domains) );
        ]
    else fields
  in
  let fields =
    if q.Model.exclude_domains <> [] then
      fields
      @ [
          ( "excludeDomains",
            `List (List.map (fun domain -> `String domain) q.Model.exclude_domains) );
        ]
    else fields
  in
  let fields =
    match from_date with
    | Some date -> fields @ [ ("fromDate", `String date) ]
    | None -> fields
  in
  Yojson.Safe.to_string (`Assoc fields)

(* Records without a name use the URL as fallback title. *)
let title_of item url =
  match Provider.Json.string_field "name" item with
  | Some title when title <> "" -> title
  | _ -> url

let hit ~snippet_chars ~title url item field =
  let snippet, uncapped_chars =
    Provider.truncate_snippet (Provider.Json.string_field field item) snippet_chars
  in
  {
    Provider.result =
      {
        Model.title;
        url;
        snippet;
        text = None;
        text_truncated = None;
        published_date = None;
        score = None;
      };
    uncapped_chars;
  }

let source_url item =
  match Provider.Json.string_field "url" item with
  | Some url when url <> "" -> Some url
  | _ -> None

let parse_sources ~snippet_chars data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "sources" data) with
    | Some items -> items
    | None -> []
  in
  let rec take n items acc =
    if n <= 0 then List.rev acc
    else
      match items with
      | [] -> List.rev acc
      | item :: rest -> take (n - 1) rest (item :: acc)
  in
  List.filter_map
    (fun item ->
      match source_url item with
      | None -> None
      | Some url -> Some (hit ~snippet_chars ~title:(title_of item url) url item "snippet"))
    (take limit records [])

let parse_results ~snippet_chars data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "results" data) with
    | Some items -> items
    | None -> []
  in
  let rec walk n items acc =
    if n <= 0 then List.rev acc
    else
      match items with
      | [] -> List.rev acc
      | item :: rest -> (
          match source_url item with
          | None -> walk n rest acc
          | Some url ->
              if Provider.Json.string_field "type" item = Some "image" then walk n rest acc
              else
                walk (n - 1) rest
                  (hit ~snippet_chars ~title:(title_of item url) url item "content" :: acc))
  in
  walk limit records []

let answer ~output data =
  match output with
  | Search_results -> None
  | Sourced_answer -> Provider.Json.string_field "answer" data

let check_status status =
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 429 then
    (* 429 indicates rate limiting (10 QPS org-wide). *)
    Error (Provider.quota_exhausted ~provider:name ~message:"rate limited (10 QPS org-wide)" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* Flat rate per request; max_results does not affect price. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~depth ~output ~key ~(now : unit -> float)
    (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let date =
    match q.Model.recency with
    | Some period -> Some (from_date now period)
    | None -> None
  in
  let request =
    {
      Caps.Authority.Net.meth = `POST;
      uri = endpoint;
      (* Bearer token in header. *)
      headers = [ ("Authorization", "Bearer " ^ key); ("Content-Type", "application/json") ];
      body = Some (request_body ~depth ~output ~from_date:date q);
    }
  in
  match net.request request with
  | Error failure -> Error (Provider.transport_error ~provider:name failure)
  | Ok response ->
      let* () = check_status response.status in
      let* data = Provider.decode_json_object ~provider:name response.body in
      let results =
        match output with
        | Sourced_answer -> parse_sources ~snippet_chars data ~limit:q.Model.max_results
        | Search_results -> parse_results ~snippet_chars data ~limit:q.Model.max_results
      in
      Ok
        {
          Provider.provider = name;
          results;
          answer = answer ~output data;
          cost_usd = Some (cost_for ~cost_per_1k q.Model.max_results);
          notice =
            Provider.ignored_constraints q ~domains:true ~dates:true ~geo:false ~language:None
              ~safety:false;
        }

let make ?(cost_per_1k = 6.00) ?(snippet_chars = 500) ?(depth = "standard")
    ?(output = Sourced_answer) ~key ~(now : unit -> float) ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~depth ~output ~key ~now net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
