module Config = Seekwright.Config
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Mcp = Mcp_client

let ( let* ) = Result.bind

let default_uri = Uri.of_string "https://mcp.exa.ai/mcp"

let tool_name = "web_search_exa"

(* Base price covers up to 10 results; extra results billed per item. Free mode costs 0. *)
let cost_for ~cost_per_1k max_results =
  if cost_per_1k = 0.0 then 0.0
  else
    let extra = max 0 (max_results - 10) in
    (cost_per_1k +. float_of_int extra *. 1.0) /. 1000.0

(* [Author], [ID] and [Score] are parsed only to terminate continuation runs. *)
let field_names = [ "title"; "url"; "published"; "author"; "highlights"; "text"; "id"; "score" ]

let body_fields = [ "highlights"; "text" ]

(* Custom whitespace stripping including vertical tab and form feed. *)
let strip line =
  let is_space = function
    | ' ' | '\t' | '\n' | '\r' | '\011' | '\012' -> true
    | _ -> false
  in
  let length = String.length line in
  let stop = ref length in
  while !stop > 0 && is_space line.[!stop - 1] do
    decr stop
  done;
  let start = ref 0 in
  while !start < !stop && is_space line.[!start] do
    incr start
  done;
  String.sub line !start (!stop - !start)

let field_of stripped =
  match String.index_opt stripped ':' with
  | Some i ->
      let name = String.lowercase_ascii (String.sub stripped 0 i) in
      if List.mem name field_names then
        Some (name, strip (String.sub stripped (i + 1) (String.length stripped - i - 1)))
      else None
  | None -> None

let put current key value = (key, value) :: List.remove_assoc key current

let parse ~text_chars text ~limit =
  let results = ref [] in
  let current = ref [] in
  let body = ref [] in
  let field = ref (None : string option) in
  let flush () =
    (match List.assoc_opt "url" !current with
    | Some url when url <> "" ->
        (* A content backend: the highlights join into [text] and [snippet]
           stays empty, because filling both ships the same prose twice. *)
        let clipped, truncated, uncapped_chars =
          Provider.truncate_text (Some (String.concat " " (List.rev !body))) text_chars
        in
        (* Exa sends [Title: N/A] for a page it could not name: the URL is a
           worse title but a true one, and dropping the record would lose a
           real result. *)
        let title =
          match List.assoc_opt "title" !current with Some title -> title | None -> url
        in
        results :=
          {
            Provider.result =
              {
                Model.title;
                url;
                snippet = None;
                text = clipped;
                text_truncated = (if truncated then Some true else None);
                published_date = List.assoc_opt "published" !current;
                score = None;
              };
            uncapped_chars;
          }
          :: !results
    | _ -> ());
    current := [];
    body := []
  in
  let take_limit found = List.filteri (fun i _ -> i < limit) found in
  let set name value =
    match name with
    (* [N/A] is Exa saying it could not name the page; flush falls back to the
       URL, and a date it could not read stays absent rather than guessed. *)
    | "title" -> if value <> "" && value <> "N/A" then current := put !current "title" value
    | "url" -> current := put !current "url" value
    (* [Published:] arrives as a date (or a longer stamp); the record keeps the
       leading ten characters, which is the ISO date inside it. *)
    | "published" ->
        if value <> "" && value <> "N/A" then
          current := put !current "published" (String.sub value 0 (min 10 (String.length value)))
    (* An empty value sets [field] but adds no line: the body that follows the
       field marker is what counts. *)
    | name when List.mem name body_fields ->
        if value <> "" then body := value :: !body
    | _ -> ()
  in
  let rec scan lines =
    match lines with
    | [] ->
        flush ();
        take_limit (List.rev !results)
    | raw :: rest ->
        let line = strip raw in
        match field_of line with
        | Some (name, value) ->
            if name = "title" then begin
              (* A new Title starts the next record — and once the limit is
                 spent, that last flush is the whole answer. *)
              flush ();
              if List.length !results >= limit then take_limit (List.rev !results)
              else begin
                field := Some name;
                set name value;
                scan rest
              end
            end
            else begin
              field := Some name;
              set name value;
              scan rest
            end
        | None ->
            if
              line <> ""
              && line <> "..."
              && (match !field with Some f -> List.mem f body_fields | None -> false)
            then body := line :: !body;
            scan rest
  in
  scan (String.split_on_char '\n' text)

let tool_arguments (q : Provider.search_query) =
  `Assoc [ ("query", `String q.Model.query); ("numResults", `Int q.Model.max_results) ]

let mcp_search ~name ~cost_per_1k ~text_chars ~tool client q =
  let* answer = Mcp.call_tool client ~name:tool ~arguments:(tool_arguments q) in
  Ok
    {
      Provider.provider = name;
      results = parse ~text_chars answer.Mcp.text ~limit:q.Model.max_results;
      answer = None;
      cost_usd = Some (cost_for ~cost_per_1k q.Model.max_results);
      notice =
        Provider.ignored_constraints q ~domains:false ~dates:false ~geo:false ~language:None
          ~safety:false;
    }

let make_mcp ?(cost_per_1k = 0.0) ?(text_chars = 2000) ~name ?auth ~uri ~net () =
  let client = Mcp.create ?auth ~provider:name ~net ~uri () in
  let adapter =
    (module struct
      let name = name
      let cost_per_1k = cost_per_1k
      let cost_for = cost_for ~cost_per_1k
      let search = mcp_search ~name ~cost_per_1k ~text_chars ~tool:tool_name client
      let aclose () = Mcp.aclose client
    end : Provider.S)
  in
  {
    Provider.adapter;
    (* Connects ahead of first request; failure at boot is logged, not fatal. *)
    Provider.warmup = (fun () -> Result.is_ok (Mcp.connect client));
  }

let round_decisecond value =
  let scaled = value *. 10.0 in
  let rounded = if scaled >= 0.0 then floor (scaled +. 0.5) else ceil (scaled -. 0.5) in
  rounded /. 10.0

let make_tiered ?(cost_per_1k = 7.00) ?(text_chars = 2000) ?(cooldown_seconds = 60.0) ~now ?log
    ~key ~uri ~net () =
  let sink level event fields =
    match log with Some log -> log level event fields | None -> ()
  in
  (* Both fallbacks report "exa" as provider name. *)
  let free = make_mcp ~cost_per_1k:0.0 ~text_chars ~name:"exa" ~uri ~net () in
  let keyed = make_mcp ~cost_per_1k ~text_chars ~name:"exa" ~auth:key ~uri ~net () in
  (* Monotonic timestamp for cooldown; wall-clock shifts must not affect it. *)
  let free_blocked_until = ref 0.0 in
  let cost (q : Provider.search_query) = cost_for ~cost_per_1k q.Model.max_results in
  let on_key q reason original =
    match Provider.search keyed.Provider.adapter q with
    | Ok result ->
        let parts = List.filter_map Fun.id [ result.Provider.notice; Some reason ] in
        Ok { result with Provider.notice = Some (String.concat "; " parts) }
    | Error (failure : Provider.error) -> (
        match (original : Provider.error option) with
        | None -> Error failure
        | Some (original : Provider.error) ->
            (* The free fallback's failure is the message; the keyed one is
               appended, never substituted, and the class is kept for the
               engine's retry advice. *)
            sink Config.Log_error "exa.both_failed"
              [ ("reason", `String failure.message); ("original_reason", `String original.message) ];
            let message =
              Printf.sprintf "%s; the API key also failed (%s)" original.message failure.message
            in
            Error
              (if original.Provider.kind = Provider.Quota then
                 Provider.quota_exhausted ~provider:"exa" ~message ()
               else Provider.provider_error ~retryable:original.retryable ~provider:"exa" message))
  in
  let search (q : Provider.search_query) =
    let t = now () in
    if t < !free_blocked_until then begin
      (* One line per call the cooldown bills for: [exa.escalated] said the
         free tier broke; this says the search was billed for it. *)
      sink Config.Log_info "exa.cooldown"
        [
          ("remaining_s", `Float (round_decisecond (!free_blocked_until -. t)));
          ("cost_usd", `Float (cost q));
        ];
      (* Not "was rate-limited": the cooldown is set by any free-fallback failure. *)
      on_key q "free tier failed recently, so this call used the API key" None
    end
    else
      match Provider.search free.Provider.adapter q with
      | Ok result -> Ok result
      | Error (failure : Provider.error) ->
          (* Any failure, not a classified quota: Exa's wording for exhaustion
             has never been observed, so a misclassification costs one paid
             search, not the tier. *)
          free_blocked_until := now () +. cooldown_seconds;
          (* WARNING because this is the moment the deployment stopped being free. *)
          sink Config.Log_warning "exa.escalated"
            [
              ("reason", `String failure.message);
              ("cooldown_s", `Float cooldown_seconds);
              ("cost_usd", `Float (cost q));
            ];
          on_key q
            (Printf.sprintf "free tier unavailable (%s), so this call used the API key"
               failure.message)
            (Some failure)
  in
  let adapter =
    (module struct
      let name = "exa"
      let cost_per_1k = cost_per_1k

      (* The billed fallback's price: what a caller should assume it might pay. *)
      let cost_for = cost_for ~cost_per_1k
      let search = search

      let aclose () =
        Provider.aclose free.Provider.adapter;
        Provider.aclose keyed.Provider.adapter
    end : Provider.S)
  in
  {
    Provider.adapter;
    (* Only the free fallback: the keyed one opens lazily on first escalation,
       and a rejected key completes the handshake anyway — warming it buys
       nothing. *)
    Provider.warmup = free.Provider.warmup;
  }
