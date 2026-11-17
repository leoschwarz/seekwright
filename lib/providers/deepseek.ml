module Civil = Seekwright_time.Civil

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Utf8 = Seekwright_text.Utf8

let name = "deepseek"

let endpoint = Uri.of_string "https://api.deepseek.com/v1/tools/search"

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

(* [snippet] and the [summary] extract are capped separately; the reported
   uncapped length is the summary's, because that is the longer prose. *)
let parse ~snippet_chars ~text_chars data ~limit =
  Provider.map_content_records ~list_path:[ "results" ] ~url_field:"url" ~title_field:"title"
    ~content_field:"summary" ~content_chars:text_chars ~snippet:("snippet", snippet_chars)
    ~date:(Provider.Json.string_field "date")
    ~score ~limit data

(* 402 is insufficient balance; 429 is a QPS breach. A 408 is upstream's own
   timeout reading the request body: transient and retryable, and not the
   server-fault reading an [HTTP 408] would give a caller. *)
let check_status =
  Provider.check_status ~provider:name ~quota_message:"rate limited or out of account balance"
    ~named:
      [ (408, Provider.provider_error ~provider:name "upstream timed out reading the request") ]

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
    (* If the folded query overflows the ceiling the operators are dropped and
       the bare query goes, which is exactly what the notice has to report. *)
    let folded_fits = Utf8.count folded <= max_query_chars in
    let* outcome =
      Provider.http_search ~provider:name ~net ~status:check_status
        ~request:
          {
            Caps.Authority.Net.meth = `POST;
            uri = endpoint;
            headers = [ ("Authorization", "Bearer " ^ key); ("Content-Type", "application/json") ];
            body = Some (request_body ~query:(if folded_fits then folded else q.Model.query) q);
          }
        ~cost_for:(cost_for ~cost_per_1k)
        ~parse:(parse ~snippet_chars ~text_chars)
        ~notice:(fun q _data ->
          Provider.ignored_constraints q ~domains:folded_fits ~dates:folded_fits ~geo:false
            ~language:(Some (folded_fits || q.Model.language = None))
            ~safety:false)
        q
    in
    (* A 200 that answers with no records is not billed upstream. *)
    Ok
      {
        outcome with
        Provider.cost_usd =
          (if outcome.Provider.results <> [] then Some (cost_for ~cost_per_1k q.Model.max_results)
           else Some 0.0);
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
