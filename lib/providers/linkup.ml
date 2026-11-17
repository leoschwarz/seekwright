module Civil = Seekwright_time.Civil

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let name = "linkup"

let endpoint = Uri.of_string "https://api.linkup.so/v1/search"

(* Output format: Sourced_answer returns prose answer and citations;
   Search_results returns structured hits. *)
type output = Sourced_answer | Search_results

let show_output = function Sourced_answer -> "sourcedAnswer" | Search_results -> "searchResults"

(* Coarse freshness to day count: Day (1), Week (7), Month (30), Year (365). *)
let age_days = function Model.Day -> 1 | Model.Week -> 7 | Model.Month -> 30 | Model.Year -> 365

(* The injected clock is what makes the vendor's date field testable. *)
let format_utc = Civil.iso_utc_seconds

let from_date (now : unit -> float) period =
  format_utc (now () -. float_of_int (age_days period * 86400))

(* Upstream request body encoding: query, depth, outputType, maxResults, filters. *)
let request_body ~depth ~output ~(from_date : string option) (q : Provider.search_query) =
  let fields =
    [
      ("q", `String q.Model.query);
      ("depth", `String depth);
      ("outputType", `String (show_output output));
      ("maxResults", `Int q.Model.max_results);
    ]
  in
  let fields =
    if q.Model.include_domains <> [] then
      fields
      @ [
          ("includeDomains", `List (List.map (fun domain -> `String domain) q.Model.include_domains));
        ]
    else fields
  in
  let fields =
    if q.Model.exclude_domains <> [] then
      fields
      @ [
          ("excludeDomains", `List (List.map (fun domain -> `String domain) q.Model.exclude_domains));
        ]
    else fields
  in
  let fields =
    match from_date with Some date -> fields @ [ ("fromDate", `String date) ] | None -> fields
  in
  Yojson.Safe.to_string (`Assoc fields)

(* Records without a name use the URL as fallback title. *)
let title_of item url =
  match Provider.Json.string_field "name" item with
  | Some title when title <> "" -> title
  | _ -> url

let hit ~snippet_chars ~title url item field =
  let snippet, uncapped_chars =
    Provider.truncate_snippet (Provider.Json.string_field field item) snippet_chars
  in
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

let source_url item =
  match Provider.Json.string_field "url" item with Some url when url <> "" -> Some url | _ -> None

let parse_sources ~snippet_chars data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "sources" data) with
    | Some items -> items
    | None -> []
  in
  List.filter_map
    (fun item ->
      match source_url item with
      | None -> None
      | Some url -> Some (hit ~snippet_chars ~title:(title_of item url) url item "snippet"))
    (Provider.take limit records)

let parse_results ~snippet_chars data ~limit =
  let records =
    match Provider.Json.list (Provider.Json.field "results" data) with
    | Some items -> items
    | None -> []
  in
  let rec walk n items acc =
    if n <= 0 then List.rev acc
    else
      match items with
      | [] -> List.rev acc
      | item :: rest -> (
          match source_url item with
          | None -> walk n rest acc
          | Some url ->
              if Provider.Json.string_field "type" item = Some "image" then walk n rest acc
              else
                walk (n - 1) rest
                  (hit ~snippet_chars ~title:(title_of item url) url item "content" :: acc))
  in
  walk limit records []

let answer ~output data =
  match output with
  | Search_results -> None
  | Sourced_answer -> Provider.Json.string_field "answer" data

(* Flat rate per request; max_results does not affect price. *)
let cost_for ~cost_per_1k _max_results = cost_per_1k /. 1000.

(* 429 indicates rate limiting (10 QPS org-wide); Linkup answers no 402 at all,
   so its quota list holds one status. *)
let check_status =
  Provider.check_status ~provider:name ~quota:[ 429 ]
    ~quota_message:"rate limited (10 QPS org-wide)"

let search ~cost_per_1k ~snippet_chars ~depth ~output ~key ~(now : unit -> float)
    (net : Provider.Net.t) (q : Provider.search_query) =
  (* [output] picks both the record list and whether an answer is expected. *)
  let parse data ~limit =
    match output with
    | Sourced_answer -> parse_sources ~snippet_chars data ~limit
    | Search_results -> parse_results ~snippet_chars data ~limit
  in
  let date =
    match q.Model.recency with Some period -> Some (from_date now period) | None -> None
  in
  Provider.http_search ~provider:name ~net ~status:check_status
    ~request:
      {
        Caps.Authority.Net.meth = `POST;
        uri = endpoint;
        (* Bearer token in header. *)
        headers = [ ("Authorization", "Bearer " ^ key); ("Content-Type", "application/json") ];
        body = Some (request_body ~depth ~output ~from_date:date q);
      }
    ~cost_for:(cost_for ~cost_per_1k) ~parse ~answer:(answer ~output)
    ~notice:(fun q _data ->
      Provider.ignored_constraints q ~domains:true ~dates:true ~geo:false ~language:None
        ~safety:false)
    q

let make ?(cost_per_1k = 6.00) ?(snippet_chars = 500) ?(depth = "standard")
    ?(output = Sourced_answer) ~key ~(now : unit -> float) ~net () : Provider.t =
  (module struct
    let name = name
    let cost_per_1k = cost_per_1k
    let cost_for = cost_for ~cost_per_1k
    let search = search ~cost_per_1k ~snippet_chars ~depth ~output ~key ~now net

    (* Shared network grant; must not be closed by adapter instance. *)
    let aclose () = ()
  end : Provider.S)
