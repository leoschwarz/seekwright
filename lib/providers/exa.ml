(* Exa, ported from src/seekwright/providers/exa_mcp.py: the MCP-backed adapter
   and the free-before-key ladder over two of them. *)

module Config = Seekwright.Config
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Mcp = Mcp_client

let ( let* ) = Result.bind

let default_uri = Uri.of_string "https://mcp.exa.ai/mcp"

let tool_name = "web_search_exa"

(* Exa bills ~$7/1k up to 10 results, then ~$1/1k per extra result; a free
   fallback costs nothing whatever the count returns. The registry row spells
   the same shape as its [Extra_results] cost model, and the registry suite
   pins the two against each other. *)
let cost_for ~cost_per_1k max_results =
  if cost_per_1k = 0.0 then 0.0
  else
    let extra = max 0 (max_results - 10) in
    (cost_per_1k +. float_of_int extra *. 1.0) /. 1000.0

(* {1 The block-format parser} *)

(* The oracle's [_FIELD] regex matches a name that is a run of ASCII letters
   before the first colon, case-insensitively; spelled here as the eight tokens
   it enumerates, because [Author], [ID] and [Score] are matched only to be
   dropped — they still end the previous field's continuation run, and that is
   the only thing they do. Anything else is a continuation line, and
   continuation lines count only under the two body fields. *)
let field_names = [ "title"; "url"; "published"; "author"; "highlights"; "text"; "id"; "score" ]

let body_fields = [ "highlights"; "text" ]

(* [str.strip()] over the whitespace Python strips; [String.trim] would not
   agree on the vertical tab and form feed a scraped page can carry. *)
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

(* The oracle's field pattern: the name is the run before the first colon,
   case-insensitively, and the value is the rest stripped. *)
let field_of stripped =
  match String.index_opt stripped ':' with
  | Some i ->
      let name = String.lowercase_ascii (String.sub stripped 0 i) in
      if List.mem name field_names then
        Some (name, strip (String.sub stripped (i + 1) (String.length stripped - i - 1)))
      else None
  | None -> None

(* Dict-order-preserving set for the running record: the last write of a field
   wins, the record stays small. *)
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
  (* [splitlines()] and the line-based scan below run on [str] fields, which
     never carry a CR that is not already part of the stripped whitespace. *)
  scan (String.split_on_char '\n' text)

(* {1 One MCP session on one credential} *)

let tool_arguments (q : Provider.search_query) =
  (* The advertised surface and nothing else: ["additionalProperties": false],
     so there is no filter argument a caller's constraint could reach. *)
  `Assoc [ ("query", `String q.Model.query); ("numResults", `Int q.Model.max_results) ]

(* The oracle's [_search_once]: session, call, parse, notice. The session
   lifecycle — handshake, the one retry after a dead session, and the close —
   belongs to {!Mcp_client}, and so does the [isError] classification that
   Python runs here: the client's fixed failure vocabulary is what reaches the
   ladder, which escalates on any of it. *)
let mcp_search ~name ~cost_per_1k ~text_chars ~tool client q =
  let* answer = Mcp.call_tool client ~name:tool ~arguments:(tool_arguments q) in
  Ok
    {
      Provider.provider = name;
      results = parse ~text_chars answer.Mcp.text ~limit:q.Model.max_results;
      answer = None;
      cost_usd = Some (cost_for ~cost_per_1k q.Model.max_results);
      (* The tool surface takes no filter args, so no caller constraint can
         reach it; the parsed [Published:] dates are the freshness signal. *)
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

      (* The session is the adapter's own — the close half of the lifecycle
         Python inherits and this port reuses from the client. *)
      let aclose () = Mcp.aclose client
    end : Provider.S)
  in
  {
    Provider.adapter;
    (* Opens this adapter's own session ahead of the first request, and never
       raises: a cold start is a log line at boot, not a startup failure. *)
    Provider.warmup = (fun () -> Result.is_ok (Mcp.connect client));
  }

(* {1 The free-before-key ladder} *)

(* [exa.cooldown]'s [remaining_s] — the oracle's [round(x, 1)]. *)
let round_decisecond value =
  let scaled = value *. 10.0 in
  let rounded = if scaled >= 0.0 then floor (scaled +. 0.5) else ceil (scaled -. 0.5) in
  rounded /. 10.0

let make_tiered ?(cost_per_1k = 7.00) ?(text_chars = 2000) ?(cooldown_seconds = 60.0) ~now ?log
    ~key ~uri ~net () =
  let sink level event fields =
    match log with Some log -> log level event fields | None -> ()
  in
  (* Both fallbacks report [exa]: which credential served a search is a fact
     about cost, not a different provider. *)
  let free = make_mcp ~cost_per_1k:0.0 ~text_chars ~name:"exa" ~uri ~net () in
  let keyed = make_mcp ~cost_per_1k ~text_chars ~name:"exa" ~auth:key ~uri ~net () in
  (* Monotonic, not wall clock: a clock adjustment must not extend the
     cooldown. [now] is the caller's monotonic reading, the one the grants'
     timeouts run on too. *)
  let free_blocked_until = ref 0.0 in
  let cost (q : Provider.search_query) = cost_for ~cost_per_1k q.Model.max_results in
  let on_key q reason original =
    match Provider.search keyed.Provider.adapter q with
    | Ok result ->
        (* Silence here is the expensive kind: a deployment whose free tier
           quietly stopped working would keep answering, evidenced only by the
           invoice. *)
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
