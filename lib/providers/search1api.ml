(* Search1API, ported from src/seekwright/providers/search1api.py. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "search1api"

let endpoint = Uri.of_string "https://api.search1api.com/search"

let policy_endpoint = Provider.policy_of_uri endpoint

(* The request document. [time_range] takes the vendor's own four words, which are
   the four rungs of [recency] spelled the same way: a window, not a date, so no
   clock is needed here — the difference that keeps [deepseek] injecting one and
   this adapter out of the date-arithmetic crowd. *)
let request_body (q : Provider.search_query) =
  let fields =
    [ ("query", `String q.Model.query); ("max_results", `Int q.Model.max_results) ]
  in
  (* Native domain fields, so the query goes verbatim: no [site:] folding. *)
  let fields =
    if q.Model.include_domains <> [] then
      fields
      @ [
          ( "include_sites",
            `List (List.map (fun domain -> `String domain) q.Model.include_domains) );
        ]
    else fields
  in
  let fields =
    if q.Model.exclude_domains <> [] then
      fields
      @ [
          ( "exclude_sites",
            `List (List.map (fun domain -> `String domain) q.Model.exclude_domains) );
        ]
    else fields
  in
  let fields =
    match q.Model.language with
    (* Lowercased, not split: the schema guarantees two letters. *)
    | Some code -> fields @ [ ("language", `String (String.lowercase_ascii code)) ]
    | None -> fields
  in
  let fields =
    match q.Model.recency with
    | Some period ->
        let word =
          match period with
          | Model.Day -> "day"
          | Model.Week -> "week"
          | Model.Month -> "month"
          | Model.Year -> "year"
        in
        fields @ [ ("time_range", `String word) ]
    | None -> fields
  in
  Yojson.Safe.to_string (`Assoc fields)

(* A record's published date, kept only when it is a string: a non-string there is
   upstream shape drift, and the contract resolves that to a dropped field rather
   than an internal error. *)
let published_date item = Provider.Json.string_field "published_date" item

(* [results[]]: title, link, snippet, published_date. The limit slices the upstream
   list before anything is dropped, the same reading [scrappa] gives its organic
   block. A SERP backend: [snippet] filled, never [text] — [content] exists
   upstream only behind [crawl_results], which this adapter never sends. *)
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
    (* 402 is documented ([application/problem+json]), and every request here is
       bearer-keyed, so a payment status means the credits are gone — the same
       sentence as the rate limit, which is undocumented and presumed. *)
    Error (Provider.quota_exhausted ~provider:name ~message:"out of credits or rate limited" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* Per-query cost in USD: one credit per basic search, flat. Deep Search would add
   a credit per crawled page, and {!request_body} never asks for one. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let request =
    {
      Caps.Authority.Net.meth = `POST;
      uri = endpoint;
      (* A bearer token in a header, never a query parameter: the one URL this
         adapter builds stays free of the credential it sends. *)
      headers = [ ("Authorization", "Bearer " ^ key); ("Content-Type", "application/json") ];
      body = Some (request_body q);
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
          (* Domains, dates and language ride native parameters; with no country
             half the geo bucket is split and names [country] alone, and there is
             no safe-search field at all. *)
          notice =
            Provider.ignored_constraints q ~domains:true ~dates:true ~geo:false
              ~language:(Some true) ~safety:false;
        }

let make ?(cost_per_1k = 0.76) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* The grant is the server's, not the adapter's: closing it would break the
       sibling providers that share the same confinement. *)
    let aclose () = ()
  end : Provider.S)
