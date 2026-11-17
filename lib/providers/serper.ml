module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "serper"

let endpoint = Uri.of_string "https://google.serper.dev/search"

let tbs_of = function
  | Model.Day -> "qdr:d"
  | Model.Week -> "qdr:w"
  | Model.Month -> "qdr:m"
  | Model.Year -> "qdr:y"

(* 2 credits charged if max_results > 10. *)
let credit_over = 10

let credits max_results = if max_results > credit_over then 2 else 1

let cost_for ~cost_per_1k max_results = cost_per_1k /. 1000. *. float_of_int (credits max_results)

let request_body (q : Provider.search_query) =
  let fields =
    [ ("q", `String (Provider.site_filtered_query q)); ("num", `Int q.Model.max_results) ]
  in
  let fields =
    match q.Model.country with Some code -> fields @ [ ("gl", `String code) ] | None -> fields
  in
  let fields =
    match q.Model.language with
    | Some code -> fields @ [ ("hl", `String (String.lowercase_ascii code)) ]
    | None -> fields
  in
  let fields =
    match q.Model.recency with
    | Some period -> fields @ [ ("tbs", `String (tbs_of period)) ]
    | None -> fields
  in
  Yojson.Safe.to_string (`Assoc fields)

let parse ~snippet_chars data ~limit =
  Provider.map_records ~list_path:[ "organic" ] ~url_field:"link" ~title_field:"title"
    ~snippet_field:"snippet" ~snippet_chars
    ~date:(Provider.Json.string_field "date")
    ~limit data

(* 402/429 indicates credit exhaustion or rate limit. *)
let check_status =
  Provider.check_status ~provider:name ~quota_message:"rate limited or out of credits"

let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  Provider.http_search ~provider:name ~net ~status:check_status
    ~request:
      {
        Caps.Authority.Net.meth = `POST;
        uri = endpoint;
        headers = [ ("X-API-KEY", key); ("Content-Type", "application/json") ];
        body = Some (request_body q);
      }
    ~cost_for:(cost_for ~cost_per_1k) ~parse:(parse ~snippet_chars)
    ~notice:(fun q _data ->
      Provider.ignored_constraints q ~domains:true ~dates:true ~geo:true ~language:None
        ~safety:false)
    q

let make ?(cost_per_1k = 1.00) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
