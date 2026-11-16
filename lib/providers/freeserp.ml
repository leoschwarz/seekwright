module Civil = Seekwright_time.Civil

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "freeserp"

let endpoint = Uri.of_string "https://freeserp.ai/api.php"

let policy_endpoint = Provider.policy_of_uri endpoint

let agent = "seekwright"
let max_size = 100

(* Coarse freshness to day count: Day (1), Week (7), Month (30), Year (365). *)
let age_days = function Model.Day -> 1 | Model.Week -> 7 | Model.Month -> 30 | Model.Year -> 365

let published_from (now : unit -> float) period =
  Civil.date_of_days (Civil.days_of_secs (Civil.whole_seconds (now ())) - age_days period)

let size_of max_results = min (max max_results 1) max_size

let request_uri ~(now : unit -> float) (q : Provider.search_query) =
  let params =
    [
      ("index", [ "web" ]);
      ("q", [ q.Model.query ]);
      ("size", [ string_of_int (size_of q.Model.max_results) ]);
      ("agent", [ agent ]);
      ("website", [ Provider.project_url ]);
    ]
  in
  let params =
    match q.Model.language with
    | Some code -> params @ [ ("lang", [ String.lowercase_ascii code ]) ]
    | None -> params
  in
  let params =
    match q.Model.recency with
    | Some period -> params @ [ ("published_from", [ published_from now period ]) ]
    | None -> params
  in
  Uri.with_query endpoint params

(* Uses published_at or falls back to crawled_at. *)
let published_date item =
  let rec try_keys keys =
    match keys with
    | [] -> None
    | key :: rest -> (
        match Provider.Json.string_field key item with
        | Some value when value <> "" -> Some value
        | _ -> try_keys rest)
  in
  try_keys [ "published_at"; "crawled_at" ]

(* BM25 score passed through directly. *)
let score item = Provider.Json.number_field "score" item

let parse ~snippet_chars data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "results" data) with
    | Some items -> items
    | None -> []
  in
  let rec take n items acc =
    if n <= 0 then List.rev acc
    else match items with [] -> List.rev acc | item :: rest -> take (n - 1) rest (item :: acc)
  in
  (* Limit slices upstream results before validation. *)
  List.filter_map
    (fun item ->
      match (Provider.Json.string_field "url" item, Provider.Json.string_field "title" item) with
      | Some url, Some title when url <> "" && title <> "" ->
          let snippet, uncapped_chars =
            Provider.truncate_snippet (Provider.Json.string_field "snippet" item) snippet_chars
          in
          Some
            {
              Provider.result =
                {
                  Model.title;
                  url;
                  snippet;
                  text = None;
                  text_truncated = None;
                  published_date = published_date item;
                  score = score item;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

let check_status status =
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then Error (Provider.quota_exhausted ~provider:name ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

let search ~cost_per_1k ~snippet_chars ~(now : unit -> float) (net : Provider.Net.t)
    (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let request =
    { Caps.Authority.Net.meth = `GET; uri = request_uri ~now q; headers = []; body = None }
  in
  match net.request request with
  | Error failure -> Error (Provider.transport_error ~provider:name failure)
  | Ok response ->
      let* () = check_status response.status in
      let* data = Provider.decode_json_object ~provider:name response.body in
      if Provider.Json.is_true_field "engine_fallback" data then
        (* engine_fallback indicates web engine failure; transient. *)
        Error (Provider.provider_error ~provider:name "upstream index unavailable")
      else
        Ok
          {
            Provider.provider = name;
            results = parse ~snippet_chars data ~limit:q.Model.max_results;
            answer = None;
            cost_usd = Some (cost_per_1k /. 1000.);
            notice =
              Provider.ignored_constraints q ~domains:false ~dates:true ~geo:false
                ~language:(Some true) ~safety:false;
          }

(* Keyless; zero cost. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let make ?(cost_per_1k = 0.) ?(snippet_chars = 500) ~(now : unit -> float) ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~now net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
