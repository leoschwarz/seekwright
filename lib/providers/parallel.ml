(* Parallel, ported from src/seekwright/providers/parallel.py: the billed REST
   adapter and the anonymous hosted-MCP free half. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Mcp = Mcp_client

let ( let* ) = Result.bind

let name = "parallel"

let endpoint = Uri.of_string "https://api.parallel.ai/v1/search"

(* Parallel's hosted Search MCP: the endpoint the free half dials anonymously,
   and — like Exa's — the same endpoint answers a keyed session. A key there
   would only bill what the anonymous call does for free, so the free row never
   reads one, and [parallel] itself is this REST adapter, where the filter
   surface lives. *)
let mcp_uri = Uri.of_string "https://search.parallel.ai/mcp"

let policy_endpoint = Provider.policy_of_uri endpoint

(* recency -> how far back [source_policy.after_date] reaches, with fixed
   30-day months and 365-day years: coarse freshness, not calendar
   arithmetic. *)
let recency_days = function
  | Model.Day -> 1
  | Model.Week -> 7
  | Model.Month -> 30
  | Model.Year -> 365

(* {1 Date arithmetic} *)

(* [datetime.now(UTC) - timedelta(days=n)] as [YYYY-MM-DD]. The clock is
   injected rather than read from the process so a suite can pin the date the
   request carries; the day-number walk is deepseek.ml's, and the UTC rule
   [usage.ml] uses. *)
let days_since_epoch (now : float) =
  let seconds = Int64.of_float (floor now) in
  let days = Int64.div seconds 86400L in
  let days =
    if seconds < 0L && Int64.rem seconds 86400L <> 0L then Int64.succ days else days
  in
  Int64.to_int days

(* Howard Hinnant's civil_from_days: the calendar date of a day number, with no
   timezone and no library — the walk [Deepseek], [Linkup] and [Freeserp] each
   also carry, because each adapter owns its copy rather than sharing a date
   module, so a change to one backend's window cannot reach another's by
   import. *)
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

let after_date ~(now : unit -> float) period =
  let days = days_since_epoch (now () -. float_of_int (recency_days period * 86400)) in
  let (year, month, day) = civil_from_days days in
  Printf.sprintf "%04d-%02d-%02d" year month day

(* {1 The result parser both halves share} *)

(* Parallel's [results[]] onto [Result], for either half: [resp.json()] on the
   REST adapter, [Yojson] of the MCP text block on the free one — so the shape
   is checked rather than assumed. Reads only [url], [title], [publish_date]
   and [excerpts]; a record with no URL is dropped, a null [title] falls back
   to the URL, dates pass through verbatim or stay absent — silence is not an
   invitation to guess — and the excerpts join into the capped [text]. *)
let parse_results data ~limit ~text_chars =
  let items =
    match data with
    | `Assoc _ -> (
        match Provider.Json.field "results" data with
        | `List items -> items
        | _ -> [])
    | _ -> []
    (* a JSON array or scalar is not a result set *)
  in
  let hits =
    List.filter_map
      (fun item ->
        match Provider.Json.string_field "url" item with
        | None | Some "" -> None
        | Some url ->
            (* [excerpts] is a list of strings; anything else in it is not
               prose and is skipped. *)
            let excerpts =
              match Provider.Json.field "excerpts" item with
              | `List parts ->
                  List.filter_map
                    (fun part ->
                      match part with `String text when text <> "" -> Some text | _ -> None)
                    parts
              | _ -> []
            in
            let clipped, truncated, uncapped_chars =
              Provider.truncate_text (Some (String.concat "\n\n" excerpts)) text_chars
            in
            let title =
              match Provider.Json.string_field "title" item with
              | Some title when title <> "" -> title
              | _ -> url
            in
            Some
              {
                Provider.result =
                  {
                    Model.title;
                    url;
                    snippet = None;
                    text = clipped;
                    text_truncated = (if truncated then Some true else None);
                    published_date = Provider.Json.string_field "publish_date" item;
                    score = None;
                  };
                uncapped_chars;
              })
      (List.filteri (fun i _ -> i < limit) items)
  in
  hits

(* {1 The REST request} *)

(* The body builder, field for field: [search_queries] is one string, [mode]
   the operator's preset, and [advanced_settings] carries the filters the
   surface has a native place for. Domain filters have one, so the query goes
   verbatim; [exclude_domains] is sent even alongside [include_domains], where
   Parallel ignores it — the notice says so, and the request stays an honest
   description. *)
let request_body ~(mode : string) ~(now : unit -> float) (q : Provider.search_query) =
  let source_policy =
    let s = [] in
    let s =
      if q.Model.include_domains <> [] then
        ("include_domains", `List (List.map (fun d -> `String d) q.Model.include_domains)) :: s
      else s
    in
    let s =
      if q.Model.exclude_domains <> [] then
        ("exclude_domains", `List (List.map (fun d -> `String d) q.Model.exclude_domains)) :: s
      else s
    in
    match q.Model.recency with
    | Some period -> ("after_date", `String (after_date ~now period)) :: s
    | None -> s
  in
  let advanced =
    let a = [ ("max_results", `Int q.Model.max_results) ] in
    let a = if source_policy <> [] then ("source_policy", `Assoc source_policy) :: a else a in
    match q.Model.country with
    | Some country -> ("location", `String country) :: a
    | None -> a
  in
  `Assoc
    [
      ("search_queries", `List [ `String q.Model.query ]);
      ("mode", `String mode);
      ("advanced_settings", `Assoc advanced);
    ]

(* {1 The notices, hand-composed} *)

(* Not [ignored_constraints]: the exclude-while-include rule is finer than any
   bucket, and country rides [location] rather than being refused, so no [geo]
   token belongs here. The upstream [warnings] are the vendor's own words, read
   once and echoed — the only third-party prose this adapter repeats. *)
let compose_notices (q : Provider.search_query) data =
  let parts =
    let p = [] in
    let p =
      if q.Model.include_domains <> [] && q.Model.exclude_domains <> [] then
        "parallel ignores exclude_domains while include_domains is set; that constraint was ignored"
        :: p
      else p
    in
    let p =
      if q.Model.language <> None then
        "cannot filter by language; that constraint was ignored" :: p
      else p
    in
    let p =
      if q.Model.safe_search <> None then
        "cannot filter by safe-search; that constraint was ignored" :: p
      else p
    in
    let warnings =
      match data with `Assoc _ -> Provider.Json.field "warnings" data | _ -> `Null
    in
    let p =
      match warnings with
      | `List entries ->
          let messages =
            List.filter_map
              (fun entry -> Provider.Json.string_field "message" entry)
              entries
          in
          if messages <> [] then
            ("upstream warnings: " ^ String.concat "; " messages) :: p
          else p
      | _ -> p
    in
    List.rev p
  in
  if parts = [] then None else Some (String.concat "; " parts)

(* {1 The billed REST adapter} *)

let check_status status =
  if status = 401 || status = 403 then Error (Provider.auth_error ~provider:name)
  else if status = 402 || status = 429 then
    Error (Provider.quota_exhausted ~provider:name ~message:"rate limited or out of credits" ())
  else if status >= 400 then Error (Provider.http_status_error ~provider:name status)
  else Ok ()

let make ?(cost_per_1k = 1.00) ?(text_chars = 2000) ?(mode = "fast") ~key ~now ~net () =
  let adapter =
    (module struct
      let name = name
      let cost_per_1k = cost_per_1k

      (* Per-query cost in USD. Flat: billed per request by [mode], so the
         argument is ignored rather than absent — callers treat [cost_for] as
         duck-typed, and [cost_per_1k] tracks the preset. *)
      let cost_for _max_results = cost_per_1k /. 1000.0

      let search (q : Provider.search_query) =
        let request : Caps.Authority.Net.request =
          {
            meth = `POST;
            uri = endpoint;
            headers =
              [ ("x-api-key", key); ("Content-Type", "application/json") ];
            body = Some (Yojson.Safe.to_string (request_body ~mode ~now q));
          }
        in
        let* response =
          Result.map_error
            (fun failure ->
              if Caps.Error.kind failure = Caps.Error.Timeout then
                Provider.timeout_error ~provider:name
              else Provider.network_error ~provider:name)
            (net.Provider.Net.request request)
        in
        let* () = check_status response.Caps.Authority.Net.status in
        let data =
          match Yojson.Safe.from_string response.Caps.Authority.Net.body with
          | exception Yojson.Json_error _ -> None
          | data -> Some data
        in
        match data with
        | None -> Error (Provider.provider_error ~provider:name "malformed JSON response")
        | Some data ->
            Ok
              {
                Provider.provider = name;
                results = parse_results data ~limit:q.Model.max_results ~text_chars;
                answer = None;
                cost_usd = Some (cost_for q.Model.max_results);
                notice = compose_notices q data;
              }

      (* The lifespan owns the shared client, and the grant is the caller's:
         there is nothing of ours to close. *)
      let aclose () = ()
    end : Provider.S)
  in
  adapter

(* {1 The anonymous hosted-MCP free half} *)

let mcp_tool = "web_search"

(* [web_search] requires both an objective and at least one query; the caller
   gives one string and there is no second to derive, so it serves as both. *)
let mcp_arguments (q : Provider.search_query) =
  `Assoc
    [
      ("objective", `String q.Model.query);
      ("search_queries", `List [ `String q.Model.query ]);
    ]

let make_mcp ?(cost_per_1k = 0.0) ?(text_chars = 2000) ~name ~uri ~net () =
  let client = Mcp.create ~provider:name ~net ~uri () in
  let adapter =
    (module struct
      let name = name
      let cost_per_1k = cost_per_1k

      (* The price shape is Exa's, inherited exactly as Python's
         [ParallelMcpProvider] inherits [ExaMcpProvider.cost_for]: a free row
         answers zero, and only a priced row would ride the extra-result rung. *)
      let cost_for = Exa.cost_for ~cost_per_1k

      let search q =
        let* answer = Mcp.call_tool client ~name:mcp_tool ~arguments:(mcp_arguments q) in
        (* The tool puts the same JSON in [structuredContent] and a text block;
           this trusts the text channel, which is what the client hands back. *)
        let data =
          match Yojson.Safe.from_string answer.Mcp.text with
          | exception Yojson.Json_error _ -> None
          | data -> Some data
        in
        match data with
        | None -> Error (Provider.provider_error ~provider:name "malformed JSON response")
        | Some data ->
            (* The tool surface takes no filter arguments at all, so it honours
               no constraint and says so in [notice]. *)
            Ok
              {
                Provider.provider = name;
                results = parse_results data ~limit:q.Model.max_results ~text_chars;
                answer = None;
                cost_usd = Some (cost_for q.Model.max_results);
                notice =
                  Provider.ignored_constraints q ~domains:false ~dates:false ~geo:false
                    ~language:None ~safety:false;
              }

      let aclose () = Mcp.aclose client
    end : Provider.S)
  in
  {
    Provider.adapter;
    (* The free half owns its session exactly as Exa's does: warm the handshake
       before the first search pays for it, never raising on a cold start. *)
    Provider.warmup = (fun () -> Result.is_ok (Mcp.connect client));
  }
