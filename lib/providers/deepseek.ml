module Civil = Seekwright_time.Civil

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Utf8 = Seekwright_text.Utf8

let name = "deepseek"

let endpoint = Uri.of_string "https://api.deepseek.com/v1/tools/search"

let policy_endpoint = Provider.policy_of_uri endpoint

(* Documented count range is 1..50. *)
let max_results = 50

(* Upstream accepts 1 to 128 Unicode characters for the entire folded query. *)
let max_query_chars = 128

(* 31/366 use the long month/year so a recency window does not miss days. *)
let recency_days = function
  | Model.Day -> 1
  | Model.Week -> 7
  | Model.Month -> 31
  | Model.Year -> 366

let after_date ~(now : unit -> float) period =
  Civil.date_of_days
    (Civil.days_of_secs
       (Civil.whole_seconds (now () -. float_of_int (recency_days period * 86400))))

(* Fold query operators: site, lang, after. Parentheses are not supported upstream. *)
let fold_operators ~(now : unit -> float) (q : Provider.search_query) =
  let parts = [ q.Model.query ] in
  let parts =
    if q.Model.include_domains <> [] then
      parts
      @ [ String.concat " OR " (List.map (fun domain -> "site:" ^ domain) q.Model.include_domains) ]
    else parts
  in
  let parts = parts @ List.map (fun domain -> "-site:" ^ domain) q.Model.exclude_domains in
  let parts =
    match q.Model.language with
    | Some code -> parts @ [ "lang:" ^ String.lowercase_ascii code ]
    | None -> parts
  in
  let parts =
    match q.Model.recency with
    | Some period -> parts @ [ "after:" ^ after_date ~now period ]
    | None -> parts
  in
  String.concat " " parts

let request_body ~(query : string) (q : Provider.search_query) =
  Yojson.Safe.to_string
    (`Assoc
       [ ("query", `String query); ("count", `Int (Stdlib.min q.Model.max_results max_results)) ])

let score item = Provider.Json.number_field "rerank_score" item

(* Snippet capped at snippet_chars; summary capped at text_chars. *)
let parse ~snippet_chars ~text_chars data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "results" data) with
    | Some items -> items
    | None -> []
  in
  let rec take n items acc =
    if n <= 0 then List.rev acc
    else match items with [] -> List.rev acc | item :: rest -> take (n - 1) rest (item :: acc)
  in
  List.filter_map
    (fun item ->
      match (Provider.Json.string_field "url" item, Provider.Json.string_field "title" item) with
      | Some url, Some title when url <> "" && title <> "" ->
          let snippet, _snippet_uncapped =
            Provider.truncate_snippet (Provider.Json.string_field "snippet" item) snippet_chars
          in
          let text, truncated, uncapped_chars =
            Provider.truncate_text (Provider.Json.string_field "summary" item) text_chars
          in
          Some
            {
              Provider.result =
                {
                  Model.title;
                  url;
                  snippet;
                  text;
                  text_truncated = (if truncated then Some true else None);
                  published_date = Provider.Json.string_field "date" item;
                  score = score item;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

let check_status status =
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then
    (* 402 is insufficient balance; 429 is QPS breach. *)
    Error
      (Provider.quota_exhausted ~provider:name ~message:"rate limited or out of account balance" ())
  else if status = 408 then
    (* Upstream request-body timeout is transient and retryable. *)
    Error (Provider.provider_error ~provider:name "upstream timed out reading the request")
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* Flat rate per successful request. Zero cost if results list is empty. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~text_chars ~key ~(now : unit -> float)
    (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  if Utf8.count q.Model.query > max_query_chars then
    (* Upstream limit is 128 characters; fail immediately if bare query exceeds it. *)
    Error
      (Provider.provider_error ~retryable:false ~provider:name
         (Printf.sprintf "query exceeds the backend's %d-character limit" max_query_chars))
  else
    let folded = fold_operators ~now q in
    (* If folded query exceeds 128 codepoints, drop operators and send bare query. *)
    let folded_fits = Utf8.count folded <= max_query_chars in
    let request =
      {
        Caps.Authority.Net.meth = `POST;
        uri = endpoint;
        headers = [ ("Authorization", "Bearer " ^ key); ("Content-Type", "application/json") ];
        body = Some (request_body ~query:(if folded_fits then folded else q.Model.query) q);
      }
    in
    match net.request request with
    | Error failure -> Error (Provider.transport_error ~provider:name failure)
    | Ok response ->
        let* () = check_status response.status in
        let* data = Provider.decode_json_object ~provider:name response.body in
        let results = parse ~snippet_chars ~text_chars data ~limit:q.Model.max_results in
        Ok
          {
            Provider.provider = name;
            results;
            answer = None;
            (* 200 with empty results is not billed upstream. *)
            cost_usd =
              (if results <> [] then Some (cost_for ~cost_per_1k q.Model.max_results) else Some 0.0);
            notice =
              Provider.ignored_constraints q ~domains:folded_fits ~dates:folded_fits ~geo:false
                ~language:(Some (folded_fits || q.Model.language = None))
                ~safety:false;
          }

let make ?(cost_per_1k = 0.75) ?(snippet_chars = 500) ?(text_chars = 2000) ~key ~now ~net () :
    Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~text_chars ~key ~now net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
