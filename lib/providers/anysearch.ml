(* AnySearch, ported from src/seekwright/providers/anysearch.py. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "anysearch"

let endpoint = Uri.of_string "https://api.anysearch.com/v1/search"

(* The grant entry for the URI this adapter dials, derived rather than spelled
   again: see [Seekwright.Provider.policy_of_uri]. *)
let policy_endpoint = Provider.policy_of_uri endpoint

let max_results = 10

let clamp_results n = min (max n 1) max_results

(* Documented range 1-10; see [max_results] for why the clamp lives here. Only
   [language] rides the wire: [zone] is a binary a country code cannot map into,
   and [tag], [params] and [format] are operator policy and an encoding for the
   extract this adapter does not read. *)
let request_body (q : Provider.search_query) =
  let fields =
    [ ("query", `String q.Model.query); ("max_results", `Int (clamp_results q.Model.max_results)) ]
  in
  let fields =
    match q.Model.language with
    (* Lowercased, not split: the docs' own examples are ISO codes ("en", "zh-CN"). *)
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
                  (* No date field exists upstream, so none is invented. *)
                  published_date = None;
                  score = None;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

let check_status status =
  (* The Failures table, with this backend's quota row. Keyless today; the
     mapping is the contract's table, ready for a future key. *)
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then
    (* 402 is the documented anonymous-quota exhaustion and its body may carry
       the auto-generated credentials: the constant message is the redaction
       rule. *)
    Error
      (Provider.quota_exhausted ~provider:name ~message:"out of credits or rate limited" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* The envelope's own contract: success is [code: 0], so a missing [code] is a
   failure like any other value. The error channel's [message] is operator text
   the 402 flow shows can hold credentials, so the raised message is a constant
   and the body is never quoted. *)
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
          (* Only [language] rides the wire: no domain, date, zone or safe-search
             field, and the bucket is split so the notice names only what really
             dropped. *)
          notice =
            Provider.ignored_constraints q ~domains:false ~dates:false ~geo:false
              ~language:(Some true) ~safety:false;
        }

(* Per-query cost in USD. Flat zero: the keyless mode cannot bill. The argument is
   ignored rather than absent for the reason [freeserp.cost_for] gives: callers
   treat it as a duck-typed method. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let make ?(cost_per_1k = 0.) ?(snippet_chars = 500) ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars net

    (* The grant is the server's, not the adapter's: closing it would break the
       sibling providers that share the same confinement. *)
    let aclose () = ()
  end : Provider.S)
