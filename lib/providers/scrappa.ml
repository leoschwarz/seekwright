module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "scrappa"

let endpoint = Uri.of_string "https://scrappa.co/api/search-light"

(* Documented ceiling: max 20 results. *)
let max_num = 20

let num_of max_results = min max_results max_num

let date_restrict_of = function
  | Model.Day -> "d1"
  | Model.Week -> "w1"
  | Model.Month -> "m1"
  | Model.Year -> "y1"

let request_uri (q : Provider.search_query) =
  let params =
    [
      ("query", [ Provider.site_filtered_query q ]);
      ("num", [ string_of_int (num_of q.Model.max_results) ]);
    ]
  in
  let params =
    match q.Model.country with Some code -> params @ [ ("gl", [ code ]) ] | None -> params
  in
  let params =
    match q.Model.language with
    | Some code -> params @ [ ("hl", [ String.lowercase_ascii code ]) ]
    | None -> params
  in
  let params =
    match q.Model.recency with
    | Some period -> params @ [ ("dateRestrict", [ date_restrict_of period ]) ]
    | None -> params
  in
  let params =
    match q.Model.safe_search with
    | Some true -> params @ [ ("safe", [ "active" ]) ]
    | Some false -> params @ [ ("safe", [ "off" ]) ]
    | None -> params
  in
  Uri.with_query endpoint params

let parse ~snippet_chars data ~limit =
  Provider.map_records ~list_path:[ "organic_results" ] ~url_field:"link" ~title_field:"title"
    ~snippet_field:"snippet" ~snippet_chars ~limit data

(* Flat rate per request. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

(* 402 is credit exhaustion; 429 is rate limit. *)
let check_status =
  Provider.check_status ~provider:name ~quota_message:"rate limited or out of credits"

(* Every constraint in the request has a parameter here — site operators, [gl],
   [hl], [dateRestrict], [safe] — so the constraint report is always [None]. *)
let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  Provider.http_search ~provider:name ~net ~status:check_status
    ~request:
      {
        Caps.Authority.Net.meth = `GET;
        uri = request_uri q;
        headers = [ ("x-api-key", key) ];
        body = None;
      }
    ~cost_for:(cost_for ~cost_per_1k) ~parse:(parse ~snippet_chars)
    ~notice:(fun q _data ->
      Provider.ignored_constraints q ~domains:true ~dates:true ~geo:true ~language:(Some true)
        ~safety:true)
    q

let make ?(cost_per_1k = 0.30) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
