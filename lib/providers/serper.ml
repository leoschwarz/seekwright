(* Serper, ported from src/seekwright/providers/serper.py. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "serper"

let endpoint = Uri.of_string "https://google.serper.dev/search"

(* The endpoint the grant must allow, in the policy's own words: derived from the
   URI this adapter dials rather than written beside it, so what is asked for and
   what is allowed cannot disagree. *)
let policy_endpoint = Provider.policy_of_uri endpoint

(* Google's standard time-restriction codes, applied through [tbs]; verified on the
   first live call (docs/reference/providers.md). A bare [num] with no [tbs] is the
   unfiltered SERP, so an absent [recency] sends neither value rather than a
   default that would narrow the search unasked. *)
let tbs_of = function
  | Model.Day -> "qdr:d"
  | Model.Week -> "qdr:w"
  | Model.Month -> "qdr:m"
  | Model.Year -> "qdr:y"

(* "2 credits for more than 10 results", which is the whole reason this adapter has
   a non-flat [cost_for]. The figure is published as a credit rule, so it belongs on
   the row as well as here: the row's pricing model and this constant are one fact
   pinned against each other in [test_provider_registry.ml]. *)
let credit_over = 10

let credits max_results = if max_results > credit_over then 2 else 1

let cost_for ~cost_per_1k max_results =
  (cost_per_1k /. 1000.) *. float_of_int (credits max_results)

(* The request document. [q] carries the domain filters as [site:] operators, which
   is how the Google-backed backends take them; [gl] and [hl] are the vendor's own
   names for country and language, and [hl] is lowercased rather than split because
   the schema guarantees two letters and the region half is [gl]'s job. *)
let request_body (q : Provider.search_query) =
  let fields =
    [
      ("q", `String (Provider.site_filtered_query q));
      ("num", `Int q.Model.max_results);
    ]
  in
  let fields =
    match q.Model.country with
    | Some code -> fields @ [ ("gl", `String code) ]
    | None -> fields
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

(* The published date, kept only when it is a string. [organic[].date] is documented
   as one and nothing upstream enforces it: an object or a number there reaching
   [Result.published_date] would be a type failure inside the parse, which the
   contract resolves to an internal error rather than a dropped field. *)
let published_date item = Provider.Json.string_field "date" item

let parse ~snippet_chars data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "organic" data) with
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
     fails to parse still spends one of the slots, exactly as the Python slice does. *)
  List.filter_map
    (fun item ->
      match (Provider.Json.string_field "link" item, Provider.Json.string_field "title" item) with
      (* Present but empty is the same drop as absent: an empty title is no title,
         and [if not url or not title] in the oracle reads it that way too. *)
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
                  published_date = published_date item;
                  (* [organic[]] has no relevance number to carry. *)
                  score = None;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

let check_status status =
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then
    (* Both ride the quota row: a credit pack runs out, and a spent balance must
       reach the quota fallback so the walk moves off this name. The wording is the
       house sentence, and the body that came with the status is not quoted — it is
       vendor prose written about an account this deployment holds. *)
    Error (Provider.quota_exhausted ~provider:name ~message:"rate limited or out of credits" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let request =
    {
      Caps.Authority.Net.meth = `POST;
      uri = endpoint;
      (* The vendor's own header spelling, and the content type a JSON body needs.
         The key is a header, never a query parameter, so no URL that reaches a log
         or an error can carry it. *)
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
          (* [site:] emulation plus native [gl]/[hl]/[tbs] honour four buckets; the
             missing safe-search parameter is the only drop this adapter can report,
             and the geo bucket stays joined because [language] is not answered
             separately — [hl] carries it. *)
          notice =
            Provider.ignored_constraints q ~domains:true ~dates:true ~geo:true
              ~language:None ~safety:false;
        }

let make ?(cost_per_1k = 1.00) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* The grant is the server's, not the adapter's: closing it would break the
       sibling providers that share the same confinement. *)
    let aclose () = ()
  end : Provider.S)
