module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "querit"

let endpoint = Uri.of_string "https://api.querit.ai/v1/search"

let policy_endpoint = Provider.policy_of_uri endpoint

(* Documented maximum result count (10). *)
let max_results = 10

let time_range = function
  | Model.Day -> "d1"
  | Model.Week -> "w1"
  | Model.Month -> "m1"
  | Model.Year -> "y1"

let language_names =
  [
    ("de", "german");
    ("en", "english");
    ("es", "spanish");
    ("fr", "french");
    ("ja", "japanese");
    ("ko", "korean");
    ("pt", "portuguese");
    ("ru", "russian");
  ]

let country_names =
  [
    ("ar", "argentina");
    ("au", "australia");
    ("br", "brazil");
    ("ca", "canada");
    ("co", "colombia");
    ("de", "germany");
    ("es", "spain");
    ("fr", "france");
    ("gb", "united kingdom");
    ("id", "indonesia");
    ("in", "india");
    ("jp", "japan");
    ("kr", "south korea");
    ("mx", "mexico");
    ("ng", "nigeria");
    ("ph", "philippines");
    ("us", "united states");
  ]

let language_param code = List.assoc_opt (String.lowercase_ascii code) language_names
let country_param code = List.assoc_opt code country_names

let request_body ~(country : string option) ~(language : string option) (q : Provider.search_query)
    =
  let filters =
    let sites =
      let s = [] in
      let s =
        if q.Model.include_domains <> [] then
          ("include", `List (List.map (fun d -> `String d) q.Model.include_domains)) :: s
        else s
      in
      let s =
        if q.Model.exclude_domains <> [] then
          ("exclude", `List (List.map (fun d -> `String d) q.Model.exclude_domains)) :: s
        else s
      in
      List.rev s
    in
    let f = if sites <> [] then [ ("sites", `Assoc sites) ] else [] in
    let f =
      match q.Model.recency with
      | Some period -> f @ [ ("timeRange", `Assoc [ ("date", `String (time_range period)) ]) ]
      | None -> f
    in
    let f =
      match country with
      | Some country ->
          f
          @ [ ("geo", `Assoc [ ("countries", `Assoc [ ("include", `List [ `String country ]) ]) ]) ]
      | None -> f
    in
    let f =
      match language with
      | Some language -> f @ [ ("languages", `Assoc [ ("include", `List [ `String language ]) ]) ]
      | None -> f
    in
    f
  in
  let fields =
    [
      ("query", `String q.Model.query); ("count", `Int (Stdlib.min q.Model.max_results max_results));
    ]
  in
  let fields = if filters <> [] then fields @ [ ("filters", `Assoc filters) ] else fields in
  Yojson.Safe.to_string (`Assoc fields)

(* Hits live under results.result[]. *)
let parse ~snippet_chars data ~limit =
  Provider.map_records ~list_path:[ "results"; "result" ] ~url_field:"url" ~title_field:"title"
    ~snippet_field:"snippet" ~snippet_chars
    ~date:(Provider.Json.string_field "page_age")
    ~limit data

(* 429 indicates rate limit; 402 indicates quota exhaustion. *)
let check_status =
  Provider.check_status ~provider:name ~quota_message:"rate limited or out of monthly calls"

(* Flat rate per request. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  let country = match q.Model.country with Some code -> country_param code | None -> None in
  let language = match q.Model.language with Some code -> language_param code | None -> None in
  (* A filter the vendor has no code for is dropped from the body, so the
     notice has to say so. *)
  let geo_honoured = q.Model.country = None || country <> None in
  let language_honoured = q.Model.language = None || language <> None in
  Provider.http_search ~provider:name ~net ~status:check_status
    ~request:
      {
        Caps.Authority.Net.meth = `POST;
        uri = endpoint;
        headers = [ ("Authorization", "Bearer " ^ key); ("Content-Type", "application/json") ];
        body = Some (request_body ~country ~language q);
      }
    ~cost_for:(cost_for ~cost_per_1k) ~parse:(parse ~snippet_chars)
    ~notice:(fun q _data ->
      Provider.ignored_constraints q ~domains:true ~dates:true ~geo:geo_honoured
        ~language:(Some language_honoured) ~safety:false)
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
