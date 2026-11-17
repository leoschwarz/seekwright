module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "tinyfish"

let endpoint = Uri.of_string "https://api.search.tinyfish.ai"

(* recency_minutes: day (1440), week (10080), month (43200), year (525600). *)
let recency_minutes = function
  | Model.Day -> 1440
  | Model.Week -> 10080
  | Model.Month -> 43200
  | Model.Year -> 525600

let join_domains domains = String.concat "," domains

let request_uri (q : Provider.search_query) =
  let params = [ ("query", [ q.Model.query ]) ] in
  let params =
    if q.Model.include_domains <> [] then
      params @ [ ("include_domains", [ join_domains q.Model.include_domains ]) ]
    else params
  in
  let params =
    if q.Model.exclude_domains <> [] then
      params @ [ ("exclude_domains", [ join_domains q.Model.exclude_domains ]) ]
    else params
  in
  let params =
    match q.Model.recency with
    | Some period -> params @ [ ("recency_minutes", [ string_of_int (recency_minutes period) ]) ]
    | None -> params
  in
  let params =
    match q.Model.country with
    | Some code -> params @ [ ("location", [ String.uppercase_ascii code ]) ]
    | None -> params
  in
  let params =
    match q.Model.language with
    | Some code -> params @ [ ("language", [ String.lowercase_ascii code ]) ]
    | None -> params
  in
  Uri.with_query endpoint params

(* Upstream has no result-count parameter, so the caller's [max_results] is
   applied here and nowhere else. *)
let parse ~snippet_chars data ~limit =
  Provider.map_records ~list_path:[ "results" ] ~url_field:"url" ~title_field:"title"
    ~snippet_field:"snippet" ~snippet_chars
    ~date:(Provider.Json.string_field "date")
    ~limit data

(* 402/429 indicates Search API access not enabled or rate limit. *)
let check_status =
  Provider.check_status ~provider:name
    ~quota_message:"rate limited or no Search API access on this account"

(* Search API requests are free; flat zero cost. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  Provider.http_search ~provider:name ~net ~status:check_status
    ~request:
      {
        Caps.Authority.Net.meth = `GET;
        uri = request_uri q;
        headers = [ ("X-API-Key", key) ];
        body = None;
      }
    ~cost_for:(cost_for ~cost_per_1k) ~parse:(parse ~snippet_chars)
    ~notice:(fun q _data ->
      Provider.ignored_constraints q ~domains:true ~dates:true ~geo:true ~language:None
        ~safety:false ~drops_exclude_domains:false)
    q

let make ?(cost_per_1k = 0.) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
