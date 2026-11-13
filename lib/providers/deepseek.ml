(* DeepSeek Search, ported from src/seekwright/providers/deepseek.py. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Utf8 = Seekwright_text.Utf8

let name = "deepseek"

let endpoint = Uri.of_string "https://api.deepseek.com/v1/tools/search"

let policy_endpoint = Provider.policy_of_uri endpoint

(* The documented [count] range is 1..50 (not a plan limit), so a hand-built
   [SearchQuery] stays inside it. *)
let max_results = 50

(* [query] is 1 to 128 Unicode characters, and every filter rides inside that
   string, so the limit bounds the folded query, not the typed one. *)
let max_query_chars = 128

(* [after:<YYYY-MM-DD>] is the documented date form; 31/366 are the long month and
   year, so a window never misses a day — the deliberate difference from [linkup]'s
   30/365: an [after:] that runs long loses nothing, one that closes early does. *)
let recency_days = function
  | Model.Day -> 1
  | Model.Week -> 7
  | Model.Month -> 31
  | Model.Year -> 366

(* Days since the epoch, floored: a wall clock reading before 1970 would otherwise
   truncate toward zero and name the wrong day. *)
let days_since_epoch (now : float) =
  let seconds = Int64.of_float (floor now) in
  let days = Int64.div seconds 86400L in
  let days =
    if seconds < 0L && Int64.rem seconds 86400L <> 0L then Int64.succ days else days
  in
  Int64.to_int days

(* Howard Hinnant's civil_from_days: the calendar date of a day number, with no
   timezone and no library — [datetime.date().isoformat()] in the oracle, whose
   date is UTC by construction here. The same walk [Seekwright_providers.Linkup]
   and [Seekwright_providers.Freeserp] carry: each adapter owns its copy rather
   than a shared date module, so a change to one backend's window cannot reach
   another's by import. *)
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

(* [today - timedelta(days=n)] as [YYYY-MM-DD]. The clock is injected rather than
   read here because the [after:] value moves with every call: a test that wants to
   pin the whole folded query pins the clock, and the server passes the one its
   grant was built with. *)
let after_date ~(now : unit -> float) period =
  let days = days_since_epoch (now () -. float_of_int (recency_days period * 86400)) in
  let (year, month, day) = civil_from_days days in
  Printf.sprintf "%04d-%02d-%02d" year month day

(* Compose the query with this API's operators folded in. Order is the operator's
   own example — term, [site:], [lang:], [after:] — and a multi-site include is the
   [site:a OR site:b] form its docs spell out. Not [Provider.site_filtered_query]:
   that helper parenthesises a multi-site filter, and parentheses are not part of
   this backend's documented syntax. *)
let fold_operators ~(now : unit -> float) (q : Provider.search_query) =
  let parts = [ q.Model.query ] in
  let parts =
    if q.Model.include_domains <> [] then
      parts
      @ [
          String.concat " OR "
            (List.map (fun domain -> "site:" ^ domain) q.Model.include_domains);
        ]
    else parts
  in
  let parts =
    parts @ List.map (fun domain -> "-site:" ^ domain) q.Model.exclude_domains
  in
  let parts =
    match q.Model.language with
    (* Lowercased, not split: the schema guarantees two letters, the shape [lang:]
       takes. *)
    | Some code -> parts @ [ "lang:" ^ String.lowercase_ascii code ]
    | None -> parts
  in
  let parts =
    match q.Model.recency with
    | Some period -> parts @ [ "after:" ^ after_date ~now period ]
    | None -> parts
  in
  String.concat " " parts

(* The request document. [query] is already decided — folded or bare — because the
   128-codepoint check that chose between them needs the clock and the fold;
   [count] is clamped to the documented range. [ori_question] is unknown here, and
   [need_content] stays at its documented default of false, so no page body is
   requested. *)
let request_body ~(query : string) (q : Provider.search_query) =
  Yojson.Safe.to_string
    (`Assoc
      [
        ("query", `String query);
        ("count", `Int (Stdlib.min q.Model.max_results max_results));
      ])

let score item = Provider.Json.number_field "rerank_score" item

(* [results[]]: title, url, snippet, summary, date, rerank_score. [snippet] (for
   display) and [summary] (for a model) ride the two policy caps, and this is the
   one name in the inventory that fills [snippet] {i and} [text]. The
   [uncapped_chars] measurement rides [text]: the snippet cap at 500 rarely bites
   a 100–200-character snippet, and the figure worth measuring is the 600–800
   character summary against its 2,000-character ceiling. *)
let parse ~snippet_chars ~text_chars data ~limit =
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
      (* Present but empty is the same drop as absent. *)
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
                  (* A clipped extract must be tellable from a short page. *)
                  text_truncated = (if truncated then Some true else None);
                  (* RFC 3339 UTC as the operator formats it, or absent. *)
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
    (* 402 is its "insufficient balance", 429 its account-level QPS breach; both
       are terminal for one call. *)
    Error
      (Provider.quota_exhausted ~provider:name ~message:"rate limited or out of account balance" ())
  else if status = 408 then
    (* Documented as the request-body read timing out, and the operator says
       retry: a transient fault on the request path, not the account. *)
    Error (Provider.provider_error ~provider:name "upstream timed out reading the request")
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* Per-query cost in USD: one successful request, flat. [count] does not affect the
   price; [search] zeroes it for an empty [results], which is documented as not
   billable. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~text_chars ~key ~(now : unit -> float)
    (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  if Utf8.count q.Model.query > max_query_chars then
    (* The tool surface allows 400 characters and this backend 128, so the mismatch
       is the adapter's to name. Not retryable: no retry changes the length. *)
    Error
      (Provider.provider_error ~retryable:false ~provider:name
         (Printf.sprintf "query exceeds the backend's %d-character limit" max_query_chars))
  else
    let folded = fold_operators ~now q in
    (* Past 128 the backend refuses outright: filters come off, the bare query goes
       out, and [notice] names each bucket dropped. The count is in codepoints —
       Python's [len] — because the limit is the backend's Unicode count, not a
       byte budget. *)
    let folded_fits = Utf8.count folded <= max_query_chars in
    let request =
      {
        Caps.Authority.Net.meth = `POST;
        uri = endpoint;
        (* A bearer token in a header, never a query parameter: the one URL this
           adapter builds stays free of the credential it sends. *)
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
            (* A 200 with an empty [results] array is documented as not billable:
               the figure tracks what the account paid, not what the call cost to
               attempt. *)
            cost_usd =
              (if results <> [] then Some (cost_for ~cost_per_1k q.Model.max_results) else Some 0.0);
            (* Domain, date and language ride the query operators while the folded
               query fits; [country] and safe-search have no wire form at all, and
               the language bucket only fires when a language was actually asked. *)
            notice =
              Provider.ignored_constraints q ~domains:folded_fits ~dates:folded_fits ~geo:false
                ~language:(Some (folded_fits || q.Model.language = None)) ~safety:false;
          }

let make ?(cost_per_1k = 0.75) ?(snippet_chars = 500) ?(text_chars = 2000) ~key ~now ~net ()
    : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~text_chars ~key ~now net

    (* The grant is the server's, not the adapter's: closing it would break the
       sibling providers that share the same confinement. *)
    let aclose () = ()
  end : Provider.S)
