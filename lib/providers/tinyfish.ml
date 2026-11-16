module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "tinyfish"

let endpoint = Uri.of_string "https://api.search.tinyfish.ai"

let policy_endpoint = Provider.policy_of_uri endpoint

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

let published_date item = Provider.Json.string_field "date" item

let parse ~snippet_chars data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "results" data) with
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
  (* Upstream lacks result-count parameter; slicing happens here. *)
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
                  score = None;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

let check_status status =
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then
    (* 402/429 indicates Search API access not enabled or rate limit. *)
    Error
      (Provider.quota_exhausted ~provider:name
         ~message:"rate limited or no Search API access on this account" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* Search API requests are free; flat zero cost. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let request =
    {
      Caps.Authority.Net.meth = `GET;
      uri = request_uri q;
      headers = [ ("X-API-Key", key) ];
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
            Provider.ignored_constraints q ~domains:true ~dates:true ~geo:true
              ~language:None ~safety:false;
        }

let make ?(cost_per_1k = 0.) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
