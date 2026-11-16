module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "anysearch"

let endpoint = Uri.of_string "https://api.anysearch.com/v1/search"

let policy_endpoint = Provider.policy_of_uri endpoint

let max_results = 10

let clamp_results n = min (max n 1) max_results

(* Upstream limit 1-10; language code lowercased. *)
let request_body (q : Provider.search_query) =
  let fields =
    [ ("query", `String q.Model.query); ("max_results", `Int (clamp_results q.Model.max_results)) ]
  in
  let fields =
    match q.Model.language with
    | Some code -> fields @ [ ("language", `String (String.lowercase_ascii code)) ]
    | None -> fields
  in
  Yojson.Safe.to_string (`Assoc fields)

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
            Provider.truncate_snippet (Provider.Json.string_field "snippet" item)
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
                  published_date = None;
                  score = None;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

let check_status status =
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then
    (* 402 indicates quota exhaustion. Fixed message avoids leaking generated credentials. *)
    Error
      (Provider.quota_exhausted ~provider:name ~message:"out of credits or rate limited" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* Upstream success requires code 0. Body error message is not echoed for security. *)
let check_business_code data =
  match Provider.Json.field "code" data with
  | `Int 0 | `Float 0. -> Ok ()
  | _ -> Error (Provider.provider_error ~provider:name "search failed (business error)")

let search ~cost_per_1k ~snippet_chars (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let request =
    {
      Caps.Authority.Net.meth = `POST;
      uri = endpoint;
      headers = [ ("content-type", "application/json") ];
      body = Some (request_body q);
    }
  in
  match net.request request with
  | Error failure -> Error (Provider.transport_error ~provider:name failure)
  | Ok response ->
      let* () = check_status response.status in
      let* data = Provider.decode_json_object ~provider:name response.body in
      let* () = check_business_code data in
      Ok
        {
          Provider.provider = name;
          results = parse ~snippet_chars (Provider.Json.field "data" data) ~limit:q.Model.max_results;
          answer = None;
          cost_usd = Some (cost_per_1k /. 1000.);
          notice =
            Provider.ignored_constraints q ~domains:false ~dates:false ~geo:false
              ~language:(Some true) ~safety:false;
        }

(* Keyless; zero cost. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let make ?(cost_per_1k = 0.) ?(snippet_chars = 500) ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
