(* SearXNG, ported from src/seekwright/providers/searxng.py. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let ( let* ) = Result.bind

let name = "searxng"

(* Worst case pages per search. Each page is another request to the operator's
   instance, which fans it out to its engines behind the scenes — the bound is what
   keeps one caller's [max_results] from turning into an unbounded number of
   upstream scrapes. *)
let max_pages = 3

let rstrip_slashes path =
  let last = String.length path - 1 in
  let rec go at = if at >= 0 && path.[at] = '/' then go (at - 1) else at in
  let keep = go last in
  String.sub path 0 (keep + 1)

(* One trailing slash, however the operator wrote it, and the JSON API's own path. *)
let search_uri (instance : Uri.t) =
  Uri.with_path instance (rstrip_slashes (Uri.path instance) ^ "/search")

(* SearXNG's own enum is day/week/month/year, so this mapping is the identity;
   [language] is likewise passed as given, because the schema's two-letter code is
   the form the instance documents. *)
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
  (* [safesearch] is 0|1|2 and its [1] (moderate) is deliberately unreachable:
     [true] is the strongest on-state a backend has, and [None] sends nothing, so
     the instance's own default stands. *)
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
  (* The limit slices the upstream list before anything is dropped, so a record that
     fails to parse still spends one of the slots. *)
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
                  (* The JSON API serialises the date as a string; anything else is
                     ignored rather than rendered, and [score] is the instance's own
                     blend of engine ranks, not a relevance this port rescales. *)
                  published_date = Provider.Json.string_field "publishedDate" item;
                  score = Provider.Json.number_field "score" item;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

let check_status status =
  if status = 401 || status = 403 then
    (* A locked-down instance can refuse the JSON format specifically, and the
       operator is the one who can enable it — so the sentence names that fix rather
       than an API key this name never sends. *)
    Error
      (Provider.provider_error ~retryable:false ~provider:name
         "authentication rejected (enable `format=json` for this client)")
  else if status = 429 then
    (* The whole quota row: nothing bills this transport, and a 402 in front of an
       instance URL is the reverse proxy sitting there, not quota, so it falls to
       the generic status row below. *)
    Error (Provider.quota_exhausted ~provider:name ~message:"rate limited by the instance" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* One page of results: the response decoded as a JSON object. [Almost always] an
   instance that answers HTML has [search.formats] without [json], and the contracted
   sentence is all the caller hears — the page itself is not quoted. *)
let get_strict (net : Provider.Net.t) (uri : Uri.t) =
  let request =
    { Caps.Authority.Net.meth = `GET; uri; headers = []; body = None }
  in
  match net.request request with
  | Error failure -> Error (Provider.transport_error ~provider:name failure)
  | Ok response ->
      let* () = check_status response.status in
      Provider.decode_json_object ~provider:name response.body

(* The first page is required, so its failures decide the call. A later page fails
   soft: the caller already holds good results, and a flaky or rate-limited
   continuation must not destroy a search that succeeded. Fewer results than asked
   needs no notice — that field is for unhonoured constraints, not availability. *)
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
  (* [collected] is the pages in reverse order, each page's records reversed, so the
     accumulator only ever prepends — its size comes from pages the instance chose,
     not from a count known up front. *)
  let rec walk pageno collected =
    match get_page net (page_uri pageno) ~required:(pageno = 1) with
    | Error failure -> Error failure
    | Ok None -> Ok collected
    | Ok (Some data) ->
        let page = parse ~snippet_chars data ~limit:q.Model.max_results in
        let collected = List.rev page @ collected in
        (* The ask is satisfied, or this page ran dry: either way there is no reason
           to make the instance fan out again. *)
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
    (* The pages overshoot by construction: an instance's page size is its own, so a
       caller asking for three can be handed ten. *)
    take q.Model.max_results (List.rev collected) []
  in
  Ok
    {
      Provider.provider = name;
      results;
      answer = None;
      cost_usd = Some (cost_for ~cost_per_1k q.Model.max_results);
      (* Domains ride [site:] operators, recency maps onto [time_range], language and
         safe-search are native; no country parameter exists, so only that half falls,
         and the bucket is split so the sentence names only the country. *)
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

    (* The grant is the server's, not the adapter's: closing it would break the
       sibling providers that share the same confinement. *)
    let aclose () = ()
  end : Provider.S)
