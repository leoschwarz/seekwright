module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "serpapi"

let endpoint = Uri.of_string "https://serpapi.com/search"

let tbs = function
  | Model.Day -> "qdr:d"
  | Model.Week -> "qdr:w"
  | Model.Month -> "qdr:m"
  | Model.Year -> "qdr:y"

(* Upstream puts the API key in query parameters rather than headers. *)
let request_params ~key (q : Provider.search_query) =
  let params =
    [ ("api_key", [ key ]); ("q", [ Provider.site_filtered_query q ]); ("engine", [ "google" ]) ]
  in
  let params =
    match q.Model.country with Some country -> params @ [ ("gl", [ country ]) ] | None -> params
  in
  let params =
    match q.Model.language with
    | Some code -> params @ [ ("hl", [ String.lowercase_ascii code ]) ]
    | None -> params
  in
  let params =
    match q.Model.recency with
    | Some period -> params @ [ ("tbs", [ tbs period ]) ]
    | None -> params
  in
  let params =
    match q.Model.safe_search with
    | Some value -> params @ [ ("safe", [ (if value then "active" else "off") ]) ]
    | None -> params
  in
  params

let parse ~snippet_chars data ~limit =
  Provider.map_records ~list_path:[ "organic_results" ] ~url_field:"link" ~title_field:"title"
    ~snippet_field:"snippet" ~snippet_chars
    ~date:(Provider.Json.string_field "date")
    ~limit data

(* Flat rate per request. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

(* 402/429 indicates quota exhaustion or rate limiting. *)
let check_status =
  Provider.check_status ~provider:name ~quota_message:"rate limited or out of searches"

(* The key rides the query string, so the URI never reaches a failure message. *)
let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  Provider.http_search ~provider:name ~net ~status:check_status
    ~request:
      {
        Caps.Authority.Net.meth = `GET;
        uri = Uri.with_query endpoint (request_params ~key q);
        headers = [];
        body = None;
      }
    ~cost_for:(cost_for ~cost_per_1k) ~parse:(parse ~snippet_chars)
    ~notice:(fun q _data ->
      Provider.ignored_constraints q ~domains:true ~dates:true ~geo:true ~language:(Some true)
        ~safety:true ~drops_exclude_domains:false)
    q

let make ?(cost_per_1k = 0.0) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
