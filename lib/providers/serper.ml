module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "serper"

let endpoint = Uri.of_string "https://google.serper.dev/search"

let policy_endpoint = Provider.policy_of_uri endpoint

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

let published_date item = Provider.Json.string_field "date" item

let parse ~snippet_chars data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "organic" data) with
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
    (* 402/429 indicates credit exhaustion or rate limit. *)
    Error (Provider.quota_exhausted ~provider:name ~message:"rate limited or out of credits" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let request =
    {
      Caps.Authority.Net.meth = `POST;
      uri = endpoint;
      headers = [ ("X-API-KEY", key); ("Content-Type", "application/json") ];
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
          notice =
            Provider.ignored_constraints q ~domains:true ~dates:true ~geo:true ~language:None
              ~safety:false;
        }

let make ?(cost_per_1k = 1.00) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
