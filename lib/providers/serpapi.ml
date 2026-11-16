module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "serpapi"

let endpoint = Uri.of_string "https://serpapi.com/search"

let policy_endpoint = Provider.policy_of_uri endpoint

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
  let records =
    match Provider.Json.list (Provider.Json.field "organic_results" data) with
    | Some items -> items
    | None -> []
  in
  let rec take n items acc =
    if n <= 0 then List.rev acc
    else match items with [] -> List.rev acc | item :: rest -> take (n - 1) rest (item :: acc)
  in
  List.filter_map
    (fun item ->
      match (Provider.Json.string_field "link" item, Provider.Json.string_field "title" item) with
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
                  published_date = Provider.Json.string_field "date" item;
                  score = None;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

let check_status status =
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then
    (* 402/429 indicates quota exhaustion or rate limiting. *)
    Error (Provider.quota_exhausted ~provider:name ~message:"rate limited or out of searches" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* Flat rate per request. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let request =
    {
      Caps.Authority.Net.meth = `GET;
      (* Key rides query parameter; errors must not echo the URI. *)
      uri = Uri.with_query endpoint (request_params ~key q);
      headers = [];
      body = None;
    }
  in
  match net.request request with
  | Error failure -> Error (Provider.transport_error ~provider:name failure)
  | Ok response ->
      let* () = check_status response.status in
      let* data = Provider.decode_json_object ~provider:name response.body in
      Ok
        {
          Provider.provider = name;
          results = parse ~snippet_chars data ~limit:q.Model.max_results;
          answer = None;
          cost_usd = Some (cost_for ~cost_per_1k q.Model.max_results);
          notice =
            Provider.ignored_constraints q ~domains:true ~dates:true ~geo:true ~language:(Some true)
              ~safety:true;
        }

let make ?(cost_per_1k = 0.0) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
