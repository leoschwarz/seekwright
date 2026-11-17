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
  let params = [ ("q", [ Provider.site_filtered_query q ]); ("format", [ "json" ]) ] in
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

(* A SearXNG instance puts its snippet in [content]. *)
let parse ~snippet_chars data ~limit =
  Provider.map_records ~list_path:[ "results" ] ~url_field:"url" ~title_field:"title"
    ~snippet_field:"content" ~snippet_chars
    ~date:(Provider.Json.string_field "publishedDate")
    ~score:(Provider.Json.number_field "score")
    ~limit data

(* 401/403 on a self-hosted instance usually means [format=json] is not enabled
   for this client, which an API key cannot fix, so the sentence names the fix
   the operator has to apply. 429 is the instance's rate limit; there is no 402
   row on a SearXNG. *)
let instance_error =
  Provider.provider_error ~retryable:false ~provider:name
    "authentication rejected (enable `format=json` for this client)"

let check_status =
  Provider.check_status ~provider:name ~quota:[ 429 ] ~quota_message:"rate limited by the instance"
    ~named:[ (401, instance_error); (403, instance_error) ]

let get_strict (net : Provider.Net.t) (uri : Uri.t) =
  let request = { Caps.Authority.Net.meth = `GET; uri; headers = []; body = None } in
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

let search ~cost_per_1k ~snippet_chars ~endpoint (net : Provider.Net.t) (q : Provider.search_query)
    =
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
  let results = Provider.take q.Model.max_results (List.rev collected) in
  Ok
    {
      Provider.provider = name;
      results;
      answer = None;
      cost_usd = Some (cost_for ~cost_per_1k q.Model.max_results);
      notice =
        Provider.ignored_constraints q ~domains:true ~dates:true ~geo:false ~language:(Some true)
          ~safety:true ~drops_exclude_domains:false;
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
