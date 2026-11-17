module Civil = Seekwright_time.Civil

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "freeserp"

let endpoint = Uri.of_string "https://freeserp.ai/api.php"

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
  Provider.map_records ~list_path:[ "results" ] ~url_field:"url" ~title_field:"title"
    ~snippet_field:"snippet" ~snippet_chars ~date:published_date ~score ~limit data

(* [engine_fallback] inside a 200 marks a web-engine failure: the keyless tier
   switched index and has nothing to answer with, which is transient. The status
   rows are the shared mapping's defaults, 402/429 as [quota exhausted]. *)
let check_engine data =
  if Provider.Json.is_true_field "engine_fallback" data then
    Error (Provider.provider_error ~provider:name "upstream index unavailable")
  else Ok ()

(* Keyless; zero cost. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~(now : unit -> float) (net : Provider.Net.t)
    (q : Provider.search_query) =
  Provider.http_search ~provider:name ~net
    ~request:{ Caps.Authority.Net.meth = `GET; uri = request_uri ~now q; headers = []; body = None }
    ~cost_for:(cost_for ~cost_per_1k) ~parse:(parse ~snippet_chars) ~check:check_engine
    ~notice:(fun q _data ->
      Provider.ignored_constraints q ~domains:false ~dates:true ~geo:false ~language:(Some true)
        ~safety:false ~drops_exclude_domains:false)
    q

let make ?(cost_per_1k = 0.) ?(snippet_chars = 500) ~(now : unit -> float) ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~now net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
