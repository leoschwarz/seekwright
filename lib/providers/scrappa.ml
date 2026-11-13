(* Scrappa, ported from src/seekwright/providers/scrappa.py. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "scrappa"

let endpoint = Uri.of_string "https://scrappa.co/api/search-light"

(* The endpoint the grant must allow, in the policy's own words: derived from the
   URI this adapter dials rather than written beside it. *)
let policy_endpoint = Provider.policy_of_uri endpoint

(* The endpoint's documented ceiling: clamped rather than paginated, because every
   page would spend another credit and the caller asked for results, not requests. *)
let max_num = 20

let num_of max_results = min max_results max_num

(* Scrappa's date-restriction codes, unverified (docs/reference/providers.md says
   so): a live rejection means correcting this map and that entry together, not
   widening the timeout. *)
let date_restrict_of = function
  | Model.Day -> "d1"
  | Model.Week -> "w1"
  | Model.Month -> "m1"
  | Model.Year -> "y1"

(* The query string. Every field is added only when the caller answered that
   question: this endpoint reads an empty [gl] or [hl] as a {i value}, so sending
   the empty form is worse than sending nothing, and [safe=off] unasked would
   override a default the caller never asked about. *)
let request_uri (q : Provider.search_query) =
  let params =
    [
      ("query", [ Provider.site_filtered_query q ]);
      ("num", [ string_of_int (num_of q.Model.max_results) ]);
    ]
  in
  let params =
    match q.Model.country with
    | Some code -> params @ [ ("gl", [ code ]) ]
    | None -> params
  in
  let params =
    match q.Model.language with
    (* Lowercased, not split: the schema guarantees two letters, so there is no
       region half to narrow away. *)
    | Some code -> params @ [ ("hl", [ String.lowercase_ascii code ]) ]
    | None -> params
  in
  let params =
    match q.Model.recency with
    | Some period -> params @ [ ("dateRestrict", [ date_restrict_of period ]) ]
    | None -> params
  in
  let params =
    match q.Model.safe_search with
    | Some true -> params @ [ ("safe", [ "active" ]) ]
    | Some false -> params @ [ ("safe", [ "off" ]) ]
    | None -> params
  in
  Uri.with_query endpoint params

let parse ~snippet_chars data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "organic_results" data) with
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
      match (Provider.Json.string_field "link" item, Provider.Json.string_field "title" item) with
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
                  (* search-light reports no date and no relevance number, and
                     inventing either out of the snippet would be a guess the wire
                     model cannot qualify. *)
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
    (* 402 is Scrappa's x402 payment challenge: for a keyed client the credits are
       gone, which is a quota fact about this deployment rather than a malformed
       request. 429 is presumed rate limiting, since the limits are undocumented.
       Both bench the name out of the fallbacks, which is what a spent quota is for. *)
    Error (Provider.quota_exhausted ~provider:name ~message:"rate limited or out of credits" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* Per-query cost in USD. Flat: one credit, whatever [num] says. The argument is
   ignored rather than absent because callers treat [cost_for] as a duck-typed
   method and other providers scale with it. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let request =
    {
      Caps.Authority.Net.meth = `GET;
      uri = request_uri q;
      headers = [ ("x-api-key", key) ];
      body = None;
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
          (* No notice: Google's index behind it takes the domains, the country, the
             language, the date restriction and the safety flag, so nothing a caller
             asked for goes silently uncarried. *)
          notice = None;
        }

let make ?(cost_per_1k = 0.30) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* The grant is the server's, not the adapter's: closing it would break the
       sibling providers that share the same confinement. *)
    let aclose () = ()
  end : Provider.S)
