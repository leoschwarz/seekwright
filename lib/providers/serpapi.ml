(* SerpAPI, ported from src/seekwright/providers/serpapi.py. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "serpapi"

let endpoint = Uri.of_string "https://serpapi.com/search"

let policy_endpoint = Provider.policy_of_uri endpoint

(* Google's standard time-restriction codes, applied via the [tbs] parameter SerpAPI
   forwards to the index — the same shape [serper]'s adapter carries. *)
let tbs = function
  | Model.Day -> "qdr:d"
  | Model.Week -> "qdr:w"
  | Model.Month -> "qdr:m"
  | Model.Year -> "qdr:y"

(* The query string, key included: the vendor's documented shape puts the
   credential in the URL rather than a header, which is the whole reason this name
   is the exception to the header convention and the reason
   [Provider.redact_url] exists. *)
let request_params ~key (q : Provider.search_query) =
  let params =
    [
      ("api_key", [ key ]);
      ("q", [ Provider.site_filtered_query q ]);
      ("engine", [ "google" ]);
    ]
  in
  let params =
    match q.Model.country with
    | Some country -> params @ [ ("gl", [ country ]) ]
    | None -> params
  in
  let params =
    match q.Model.language with
    (* Lowercased, not split: the schema guarantees two letters. *)
    | Some code -> params @ [ ("hl", [ String.lowercase_ascii code ]) ]
    | None -> params
  in
  let params =
    match q.Model.recency with
    | Some period -> params @ [ ("tbs", [ tbs period ]) ]
    | None -> params
  in
  let params =
    match q.Model.safe_search with
    (* Both values are honoured exactly, and [None] sends neither — which is not
       the same as asking for no filter. *)
    | Some value -> params @ [ ("safe", [ if value then "active" else "off" ]) ]
    | None -> params
  in
  params

(* [organic_results[]]: title, link, snippet, date. The other element families
   ([answer_box], [knowledge_graph], [related_questions], …) are dropped rather
   than modelled, as [serper] reads only [organic]. The limit slices the upstream
   list before anything is dropped. *)
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
  List.filter_map
    (fun item ->
      match (Provider.Json.string_field "link" item, Provider.Json.string_field "title" item) with
      (* Present but empty is the same drop as absent: [if not url or not title]
         in the oracle reads it that way too. *)
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
                  (* A display string ("5 days ago"), kept when it is a string:
                     parsing it into a date would invent precision the payload
                     never claimed. *)
                  published_date = Provider.Json.string_field "date" item;
                  score = None;
                };
              uncapped_chars;
            }
      | _ -> None)
    (take limit records [])

let check_status status =
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then
    (* 429 is documented as the hourly throughput limit, or an exhausted account:
       a keyed client cannot tell which one it heard, and 402 for this vendor says
       the same thing about the account. *)
    Error (Provider.quota_exhausted ~provider:name ~message:"rate limited or out of searches" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

(* Per-query cost in USD: one search per call, flat. Only successful searches count
   against the quota, so a probe that searches nothing is free. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

let search ~cost_per_1k ~snippet_chars ~key (net : Provider.Net.t) (q : Provider.search_query) =
  let ( let* ) = Result.bind in
  let request =
    {
      Caps.Authority.Net.meth = `GET;
      (* The documented shape: the key rides in the query string. That makes the
         URL a secret surface — httpx errors can echo the URL they were built
         from — which is why no failure message here interpolates anything from
         the request, and why {!Seekwright.Provider.transport_error} drops the
         grant's own wording wholesale. *)
      uri = Uri.with_query endpoint (request_params ~key q);
      headers = [];
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
          (* Every bucket rides a documented parameter — [site:] operators, [gl],
             [hl], [tbs], [safe] — so nothing can drop and the notice stays None. *)
          notice =
            Provider.ignored_constraints q ~domains:true ~dates:true ~geo:true
              ~language:(Some true) ~safety:true;
        }

let make ?(cost_per_1k = 0.0) ?(snippet_chars = 500) ~key ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~key net

    (* The grant is the server's, not the adapter's: closing it would break the
       sibling providers that share the same confinement. *)
    let aclose () = ()
  end : Provider.S)
