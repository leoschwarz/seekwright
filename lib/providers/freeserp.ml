(* FreeSerp, ported from src/seekwright/providers/freeserp.py. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "freeserp"

let endpoint = Uri.of_string "https://freeserp.ai/api.php"

(* The endpoint the grant must allow, in the policy's own words: scheme pinned,
   default port, so the adapter cannot be pointed at another port by a grant
   that says it allows this host. *)
let policy_endpoint =
  { Caps.Policy.scheme = `Https; host = "freeserp.ai"; port = None }

let agent = "seekwright"
let max_size = 100

(* Coarse freshness -> how far back [published_from] reaches, with fixed day
   multipliers like Linkup's [fromDate]: recency is "published within the
   last ...", not calendar math. *)
let age_days = function
  | Model.Day -> 1
  | Model.Week -> 7
  | Model.Month -> 30
  | Model.Year -> 365

(* Days since the epoch, floored: a wall clock reading before 1970 would
   otherwise truncate toward zero and name the wrong day. *)
let days_since_epoch (now : float) =
  let seconds = Int64.of_float (floor now) in
  let days = Int64.div seconds 86400L in
  let days =
    if seconds < 0L && Int64.rem seconds 86400L <> 0L then Int64.succ days else days
  in
  Int64.to_int days

(* Howard Hinnant's civil_from_days: the calendar date of a day number, with no
   timezone and no library. [datetime.strftime("%Y-%m-%d")] in the oracle. *)
let civil_from_days z0 =
  let z = z0 + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = (5 * doy + 2) / 153 in
  let day = doy - ((153 * mp + 2) / 5) + 1 in
  let month = if mp < 10 then mp + 3 else mp - 9 in
  let year = if month <= 2 then y + 1 else y in
  (year, month, day)

let published_from (now : unit -> float) period =
  let (year, month, day) =
    civil_from_days (days_since_epoch (now ()) - age_days period)
  in
  Printf.sprintf "%04d-%02d-%02d" year month day

(* The endpoint's ceiling on [size], clamped from a [max_results] the calling
   model chose. *)
let size_of max_results = min (max max_results 1) max_size

let request_uri ~(now : unit -> float) (q : Provider.search_query) =
  let params =
    [
      ("index", [ "web" ]);
      ("q", [ q.Model.query ]);
      ("size", [ string_of_int (size_of q.Model.max_results) ]);
      ("agent", [ agent ]);
      ("website", [ Provider.project_url ]);
    ]
  in
  let params =
    match q.Model.language with
    (* Lowercased, not split: [lang] is an ISO 639-1 code, and the region
       belongs to a [country] parameter this backend does not have. *)
    | Some code -> params @ [ ("lang", [ String.lowercase_ascii code ]) ]
    | None -> params
  in
  let params =
    match q.Model.recency with
    | Some period -> params @ [ ("published_from", [ published_from now period ]) ]
    | None -> params
  in
  Uri.with_query endpoint params

(* The published date, or the crawl date. The declared date is missing for many
   pages, and the crawl date is the honest stand-in: when the index last saw the
   page, not when it was written. Neither is invented when both are absent. *)
let published_date item =
  let rec try_keys keys =
    match keys with
    | [] -> None
    | key :: rest -> (
        match Provider.Json.string_field key item with
        | Some value when value <> "" -> Some value
        | _ -> try_keys rest)
  in
  try_keys [ "published_at"; "crawled_at" ]

(* The operator's BM25 x trust number, passed through as-is. Nothing downstream
   compares scores across providers, so there is nothing to rescale. A
   non-number is dropped rather than coerced: [Result.score] is a float, and a
   string the model cannot coerce would raise out of the record. *)
let score item = Provider.Json.number_field "score" item

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
  (* The limit slices the upstream list before anything is dropped, so a record
     that fails to parse still spends one of the slots. *)
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
                  published_date = published_date item;
                  score = score item;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

let check_status status =
  (* The Failures table, written out as the adapter sees it. Keyless today; the
     mapping is the contract's table, ready for a future key. *)
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then Error (Provider.quota_exhausted ~provider:name ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

let search ~cost_per_1k ~snippet_chars ~(now : unit -> float) (net : Provider.Net.t)
    (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let request =
    {
      Caps.Authority.Net.meth = `GET;
      uri = request_uri ~now q;
      headers = [];
      body = None;
    }
  in
  match net.request request with
  | Error failure -> Error (Provider.transport_error ~provider:name failure)
  | Ok response ->
      let* () = check_status response.status in
      let* data = Provider.decode_json_object ~provider:name response.body in
      if Provider.Json.is_true_field "engine_fallback" data then
        (* Their web engine did not answer and the sites index replied: site
           profiles are not search results, and the wire shape cannot carry the
           substitution. Transient, like the 5xx row: the walk may try again. *)
        Error (Provider.provider_error ~provider:name "upstream index unavailable")
      else
        Ok
          {
            Provider.provider = name;
            results = parse ~snippet_chars data ~limit:q.Model.max_results;
            answer = None;
            cost_usd = Some (cost_per_1k /. 1000.);
            (* No domain field, no [site:] operator, no country parameter and no
               safe-search parameter; [published_from] and [lang] are honoured, so
               geo splits in the notice. *)
            notice =
              Provider.ignored_constraints q ~domains:false ~dates:true ~geo:false
                ~language:(Some true) ~safety:false;
          }

(* Per-query cost in USD. Flat zero: there is nothing to bill. The argument is
   ignored rather than absent because callers treat [cost_for] as a duck-typed
   method and other adapters do scale with it. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let make ?(cost_per_1k = 0.) ?(snippet_chars = 500) ~(now : unit -> float) ~net ()
    : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~now net

    (* The grant is the server's, not the adapter's: closing it would break the
       sibling providers that share the same confinement. *)
    let aclose () = ()
  end : Provider.S)
