module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let ( let* ) = Result.bind

let name = "searxng"

(* Maximum pages to fetch per search. *)
let max_pages = 3

let rstrip_slashes path =
  let last = String.length path - 1 in
  let rec go at = if at >= 0 && path.[at] = '/' then go (at - 1) else at in
  let keep = go last in
  String.sub path 0 (keep + 1)

let search_uri (instance : Uri.t) =
  Uri.with_path instance (rstrip_slashes (Uri.path instance) ^ "/search")

let base_params (q : Provider.search_query) =
  let params =
    [ ("q", [ Provider.site_filtered_query q ]); ("format", [ "json" ]) ]
  in
  let params =
    match q.Model.recency with
    | Some period ->
        let range =
          match period with
          | Model.Day -> "day"
          | Model.Week -> "week"
          | Model.Month -> "month"
          | Model.Year -> "year"
        in
        params @ [ ("time_range", [ range ]) ]
    | None -> params
  in
  let params =
    match q.Model.language with Some code -> params @ [ ("language", [ code ]) ] | None -> params
  in
  match q.Model.safe_search with
  | Some true -> params @ [ ("safesearch", [ "2" ]) ]
  | Some false -> params @ [ ("safesearch", [ "0" ]) ]
  | None -> params

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
  List.filter_map
    (fun item ->
      match (Provider.Json.string_field "url" item, Provider.Json.string_field "title" item) with
      | Some url, Some title when url <> "" && title <> "" ->
          let snippet, uncapped_chars =
            Provider.truncate_snippet (Provider.Json.string_field "content" item)
              snippet_chars
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
                  published_date = Provider.Json.string_field "publishedDate" item;
                  score = Provider.Json.number_field "score" item;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

let check_status status =
  if status = 401 || status = 403 then
    (* 401/403 suggests format=json is not enabled on instance. *)
    Error
      (Provider.provider_error ~retryable:false ~provider:name
         "authentication rejected (enable `format=json` for this client)")
  else if status = 429 then
    (* 429 indicates rate limiting. *)
    Error (Provider.quota_exhausted ~provider:name ~message:"rate limited by the instance" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

let get_strict (net : Provider.Net.t) (uri : Uri.t) =
  let request =
    { Caps.Authority.Net.meth = `GET; uri; headers = []; body = None }
  in
  match net.request request with
  | Error failure -> Error (Provider.transport_error ~provider:name failure)
  | Ok response ->
      let* () = check_status response.status in
      Provider.decode_json_object ~provider:name response.body

(* First page failure fails the call; subsequent page failures return partial results. *)
let get_page net uri ~required =
  match get_strict net uri with
  | Error failure -> if required then Error failure else Ok None
  | Ok data -> Ok (Some data)

let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~endpoint (net : Provider.Net.t)
    (q : Provider.search_query) =
  let search = search_uri endpoint in
  let page_uri pageno =
    Uri.with_query search (base_params q @ [ ("pageno", [ string_of_int pageno ]) ])
  in
  let rec walk pageno collected =
    match get_page net (page_uri pageno) ~required:(pageno = 1) with
    | Error failure -> Error failure
    | Ok None -> Ok collected
    | Ok (Some data) ->
        let page = parse ~snippet_chars data ~limit:q.Model.max_results in
        let collected = List.rev page @ collected in
        if List.length collected >= q.Model.max_results || page = [] then Ok collected
        else if pageno >= max_pages then Ok collected
        else walk (pageno + 1) collected
  in
  let* collected = walk 1 [] in
  let results =
    let rec take n items acc =
      if n <= 0 then List.rev acc
      else match items with [] -> List.rev acc | item :: rest -> take (n - 1) rest (item :: acc)
    in
    take q.Model.max_results (List.rev collected) []
  in
  Ok
    {
      Provider.provider = name;
      results;
      answer = None;
      cost_usd = Some (cost_for ~cost_per_1k q.Model.max_results);
      notice =
        Provider.ignored_constraints q ~domains:true ~dates:true ~geo:false
          ~language:(Some true) ~safety:true;
    }

let make ?(cost_per_1k = 0.) ?(snippet_chars = 500) ~endpoint ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~endpoint net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
