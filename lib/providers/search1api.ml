module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "search1api"

let endpoint = Uri.of_string "https://api.search1api.com/search"

let policy_endpoint = Provider.policy_of_uri endpoint

(* time_range takes "day", "week", "month", "year". *)
let request_body (q : Provider.search_query) =
  let fields = [ ("query", `String q.Model.query); ("max_results", `Int q.Model.max_results) ] in
  let fields =
    if q.Model.include_domains <> [] then
      fields
      @ [
          ("include_sites", `List (List.map (fun domain -> `String domain) q.Model.include_domains));
        ]
    else fields
  in
  let fields =
    if q.Model.exclude_domains <> [] then
      fields
      @ [
          ("exclude_sites", `List (List.map (fun domain -> `String domain) q.Model.exclude_domains));
        ]
    else fields
  in
  let fields =
    match q.Model.language with
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

let parse ~snippet_chars data ~limit =
  Provider.map_records ~list_path:[ "results" ] ~url_field:"link" ~title_field:"title"
    ~snippet_field:"snippet" ~snippet_chars
    ~date:(Provider.Json.string_field "published_date")
    ~limit data

(* Flat rate per request. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

(* 402/429 indicates credit exhaustion or rate limit. *)
let check_status =
  Provider.check_status ~provider:name ~quota_message:"out of credits or rate limited"

let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  Provider.http_search ~provider:name ~net ~status:check_status
    ~request:
      {
        Caps.Authority.Net.meth = `POST;
        uri = endpoint;
        headers = [ ("Authorization", "Bearer " ^ key); ("Content-Type", "application/json") ];
        body = Some (request_body q);
      }
    ~cost_for:(cost_for ~cost_per_1k) ~parse:(parse ~snippet_chars)
    ~notice:(fun q _data ->
      Provider.ignored_constraints q ~domains:true ~dates:true ~geo:false ~language:(Some true)
        ~safety:false)
    q

let make ?(cost_per_1k = 0.76) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
