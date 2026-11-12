(* Search and fetch orchestration; the port of [src/seekwright/engine.py].

   The interface states the shape: the router decides, this module executes, and
   failure is a returned value rather than an exception. What the toplevel of this
   file holds is the machinery both engines share and Python keeps in [logs.py] —
   the bound-field threading, the [safe] rendering, [host_of], the query and hit
   field builders. It lives here rather than in a [logs.ml] of its own because
   today the engines are its only clients, and a module only one caller uses is
   that caller's detail. *)

module Utf8 = Seekwright_text.Utf8
module Repr = Seekwright_text.Repr

type log = Log.log
(* The sink type has one owner — [Log] — and the engines alias it, so a new
   parameter is one declaration rather than four that must agree (style review
   M1). *)

let quiet : log = fun _level _event _fields -> ()

(* A bound logger, as loguru's: [bind] extends the field set and each event
   renders base fields then event fields, which is the order loguru merges
   [extra] in. That field set {i is} the operator-facing contract, so the order is
   written down rather than left to a printer. *)
type bound = { log : log; fields : (string * Yojson.Safe.t) list }

let bind (base : bound) fields = { log = base.log; fields = base.fields @ fields }

let emit (base : bound) level event fields = base.log level event (base.fields @ fields)

let elapsed (clock : unit -> float) (started : float) : int =
  (* Python's [int((monotonic() - started) * 1000)]: truncates toward zero. The
     clock is injected, so a suite can make the figure exact instead of a range. *)
  int_of_float ((clock () -. started) *. 1000.)

let round1 (value : float) : float =
  (* [round(seconds, 1)] on the [search.fallback_skipped] line: one decimal, so a
     cooldown reads as a duration and not as a float artefact. Half-up; Python's
     [round] is half-to-even, which differs only on an exact [.x5], and nothing
     routes on this field. *)
  Float.floor (value *. 10. +. 0.5) /. 10.

(* {2 The [logs.py] helpers} *)

let utf8_width (byte : char) : int =
  let c = Char.code byte in
  if c < 0x80 then 1
  else if c < 0xC0 then 1 (* a continuation byte: counted, never skipped *)
  else if c < 0xE0 then 2
  else if c < 0xF0 then 3
  else 4

let codepoints (text : string) : int =
  (* Every length in this module counts codepoints, as Python's [len()] does: a
     byte count would disagree with [fetch.max_text_chars] the moment a page is
     not ASCII. *)
  let count = ref 0 in
  let i = ref 0 in
  while !i < String.length text do
    i := !i + utf8_width text.[!i];
    incr count
  done;
  !count

let take (limit : int) (text : string) : string =
  (* Python's [text[:limit]], which counts codepoints. [String.sub] counts bytes,
     and a byte slice can cut a character in half. *)
  let target = max limit 0 in
  let seen = ref 0 in
  let i = ref 0 in
  while !i < String.length text && !seen < target do
    i := !i + utf8_width text.[!i];
    incr seen
  done;
  String.sub text 0 !i

let py_repr (value : string) : string =
  (* Python's [repr] of a str, which is what [safe] renders through: single quotes
     unless the text holds a single quote and no double quote, in which case double
     quotes; the backslash and the chosen quote escaped, [\n]/[\r]/[\t] named, other
     control bytes as [\xNN], printable non-ASCII left alone. The rule this serves
     is that a newline in a scraped title cannot close one log record and open a
     fabricated one, so what has to match Python exactly is the quoting and the
     escaping. *)
  let quote =
    if String.contains value '\'' && not (String.contains value '"') then '"' else '\''
  in
  let buffer = Buffer.create (String.length value + 8) in
  Buffer.add_char buffer quote;
  String.iter
    (fun ch ->
      match ch with
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '"' when quote = '"' -> Buffer.add_string buffer "\\\""
      | '\'' when quote = '\'' -> Buffer.add_string buffer "\\'"
      | chr when Char.code chr < 0x20 || Char.code chr = 0x7F ->
        Buffer.add_string buffer (Printf.sprintf "\\x%02x" (Char.code chr))
      | chr -> Buffer.add_char buffer chr)
    value;
  Buffer.add_char buffer quote;
  Buffer.contents buffer

let safe ?(limit = 120) (value : string option) : string =
  (* [repr((value or "")[:limit])]: [None] and the empty string render the same
     way, which is why [search.rejected]'s [requested] is always a string. *)
  py_repr (take limit (match value with None -> "" | Some text -> text))

let host_of (url : string) : string =
  (* [urlsplit(url).hostname or "?"], and never raises: the malformed URL that
     [urlsplit] refuses is the same input that produces the [fetch.blocked] event
     this feeds, so a helper that raised would turn a clean refusal into a 500. *)
  match Uri.host (Uri.of_string url) with
  | Some host when host <> "" -> host
  | _ -> "?"

let query_fields (logging : Config.logging_config) (query : string) : (string * Yojson.Safe.t) list =
  (* [qlen]/[qhash] always, the text only under [logging.log_queries]. The hash is
     a correlation handle and not anonymisation, and unsalted on purpose —
     [logs.py] states why. [digestif] stands in for [hashlib.sha256]. *)
  let digest = Digestif.SHA256.(to_hex (digest_string query)) in
  [
    ("qlen", `Int (codepoints query));
    ("qhash", `String (String.sub digest 0 8));
  ]
  @
  if logging.Config.log_queries then [ ("query", `String query) ] else []

let result_fields
    (item : Model.result)
    (rank : int)
    ~(snippet_chars : int)
    ~(text_chars : int) :
    (string * Yojson.Safe.t) list =
  let base =
    [
      ("rank", `Int rank);
      ("title", `String (safe ~limit:200 (Some item.Model.title)));
      ("url", `String (safe ~limit:200 (Some item.Model.url)));
    ]
  in
  let base =
    match item.Model.snippet with
    | None -> base
    | Some snippet -> base @ [ ("snippet", `String (safe ~limit:snippet_chars (Some snippet))) ]
  in
  let base =
    match item.Model.text with
    | None -> base
    | Some text -> base @ [ ("text", `String (safe ~limit:text_chars (Some text))) ]
  in
  match item.Model.text_truncated with
  | Some true -> base @ [ ("text_truncated", `Bool true) ]
  | _ -> base

let base64 (body : string) : string =
  (* [base64.b64encode]: the stdlib has no codec, and the alphabet is not a
     judgement call. *)
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let buffer = Buffer.create ((String.length body / 3 * 4) + 4) in
  let byte at = if at < String.length body then Char.code body.[at] else -1 in
  let i = ref 0 in
  while !i < String.length body do
    let a = byte !i in
    let b = byte (!i + 1) in
    let c = byte (!i + 2) in
    let bits = (a lsl 16) lor (max b 0 lsl 8) lor max c 0 in
    Buffer.add_char buffer alphabet.[(bits lsr 18) land 63];
    Buffer.add_char buffer alphabet.[(bits lsr 12) land 63];
    Buffer.add_char buffer (if b < 0 then '=' else alphabet.[(bits lsr 6) land 63]);
    Buffer.add_char buffer (if c < 0 then '=' else alphabet.[bits land 63]);
    i := !i + 3
  done;
  Buffer.contents buffer

let grouped (n : int) : string =
  (* Python's [f"{size:,}"], which is how an image notice counts its bytes. *)
  let digits = string_of_int n in
  let last = String.length digits - 1 in
  let buffer = Buffer.create (String.length digits + (String.length digits / 3) + 1) in
  String.iteri
    (fun i ch ->
      Buffer.add_char buffer ch;
      if i < last && (last - i) mod 3 = 0 then Buffer.add_char buffer ',')
    digits;
  Buffer.contents buffer

let strip (text : string) : string =
  (* [str.strip()], over the whitespace an extraction actually leaves behind. *)
  let is_space ch =
    match ch with ' ' | '\t' | '\n' | '\r' | '\011' | '\012' -> true | _ -> false
  in
  let first = ref 0 in
  while !first < String.length text && is_space text.[!first] do
    incr first
  done;
  let last = ref (String.length text) in
  while !last > !first && is_space text.[!last - 1] do
    decr last
  done;
  String.sub text !first (!last - !first)

let zero_results_advice =
  " Zero results usually means the phrasing, not an empty web: retry once on a"
  ^ " different provider or rephrase before concluding the answer does not"
  ^ " exist."

let error_class (kind : Provider.error_kind) : string =
  (* [type(exc).__name__]: the journal's [error] field names the failure class and
     never its message. *)
  match kind with Provider.Failure -> "ProviderError" | Provider.Quota -> "QuotaExhausted"

(* {1 The search engine} *)

module Search = struct
  type error = Refused of string | Failed of string

  type t = {
    config : Config.t
  ; providers : (Config.name * Provider.t) list
  ; health : Health.t
  ; usage : Usage.t option
  ; log : log
  ; clock : unit -> float
  ; now : unit -> float
  }

  let create
      (config : Config.t)
      ?health
      ?usage
      ?log
      (providers : (Config.name * Provider.t) list)
      ~(clock : unit -> float)
      ~(now : unit -> float)
      () =
    { config
    ; providers
    ; health = (match health with None -> Health.create ~now:clock () | Some board -> board)
    ; usage
    ; log = (match log with None -> quiet | Some sink -> sink)
    ; clock
    ; now
    }

  let providers (t : t) = List.map fst t.providers

  (* Rebuilt on every read and never cached at construction. Python's [_table] is
     a property because [providers] and [config] are public attributes a caller
     may swap; here those are values, so the only way to change them is to build
     another engine — and reading the table per call is what makes a route come
     from what this engine holds at the moment it routes, however it got those
     fields. *)
  let table (t : t) : Router.search_table =
    { Router.providers = List.map fst t.providers
    ; default = t.config.Config.default_provider
    ; permitted = t.config.Config.permitted_providers
    ; fallback = (match t.config.Config.search.fallback with None -> [] | Some ladder -> ladder)
    ; free_fallback =
        (match t.config.Config.search.free_fallback with None -> [] | Some ladder -> ladder)
    ; free = Config.free_providers
    ; free_order = Config.free_provider_order
    ; effective = Config.effective_providers t.config
    }

  let resolve t ?mode requested =
    try Ok (Router.resolve_search (table t) ?mode requested)
    with Router.Route_refused sentence -> Error sentence

  let record_failure
      t
      ~(provider : Config.name)
      ~(ms : int)
      ~(fell_back : bool)
      ~(error : string)
      ?run
      ?step
      () =
    (* A terminal search failure: nothing was billed, and the class is named. *)
    match t.usage with
    | None -> ()
    | Some usage ->
      Usage.record_search usage ~provider ~ms ~cost_usd:0.0 ~results:0 ~fell_back ~error ?run ?step ()

  let call (t : t) (name : Config.name) (q : Model.search_query) :
      (Provider.outcome, Provider.error) result =
    (* The health board sees {i every} dispatch, a named provider included: the
       board describes the provider, and whether the route substitutes for it is a
       separate question. A named failure still fails, and still counts. *)
    match List.assoc_opt name t.providers with
    | None ->
      (* Unreachable through [resolve], which answers only names taken from this
         same registry. Guarded rather than assumed, because [search] promises to
         fail through its return value and not by raising. *)
      Error (Provider.provider_error ~provider:name "no adapter was built for this name")
    | Some adapter ->
      (match Provider.search adapter q with
      | Error failure ->
        Health.record_failure t.health ~reason:failure.Provider.message name ();
        Error failure
      | Ok outcome ->
        Health.record_success t.health ~reason:"search succeeded" name ();
        Ok outcome)

  let compose_notice t (outcome : Provider.outcome) (name : Config.name) : string option =
    (* The adapter's notice joined with the zero-results diagnostic; either alone.
       The diagnostic fires on an empty response only — a nag on every response
       would bury the one that matters — and names the other enabled providers so
       a flaky backend and a genuinely empty result are told apart. Python's
       condition is truthiness, so an empty-string notice is dropped rather than
       joined with a dangling "; ". *)
    if outcome.Provider.results <> [] || outcome.answer <> None
    then outcome.notice
    else begin
      let others = List.filter (fun other -> other <> name) (providers t) in
      let detail =
        "No results from " ^ name ^ "."
        ^ (if others <> []
          then " Other enabled providers: " ^ String.concat ", " others ^ "."
          else " " ^ name ^ " is the only enabled provider.")
        ^ zero_results_advice
      in
      match outcome.notice with
      | None -> Some detail
      | Some existing when existing <> "" -> Some (existing ^ "; " ^ detail)
      | Some _ -> Some detail
    end

  let log_ok base (result : Model.provider_result) (notice : string option) ~(ms : int)
      ~(fell_back : bool) ?mode ~(sanitized : int) () : bound =
    (* The one line an operator aggregates on, and its field set is fixed:
       [fell_back] and [mode] are always bound, whatever the route.

       [reported_cost_usd] has no counterpart on [Provider.outcome]: Python hangs
       it on the private [ProviderResult._reported_cost_usd], which an adapter
       fills from upstream usage, and no adapter in this port has that measurement
       to make yet. So the line never carries it, and the suite pins the absence
       rather than inventing a value for it. *)
    emit
      (bind
         base
         [
           ("ms", `Int ms)
         ; ("results", `Int (List.length result.Model.results))
         ; ("cost_usd", match result.cost_usd with None -> `Null | Some cost -> `Float cost)
         ; ("answer", `Bool (result.answer <> None))
         ; ("notice", match notice with None -> `Null | Some text -> `String text)
         ; ("fell_back", `Bool fell_back)
         ; ("mode", match mode with None -> `Null | Some Router.Free -> `String "free")
         ; ("sanitized", `Int sanitized)
         ])
      Config.Log_info
      "search.ok"
      [];
    (* [base] is what comes back, not the logger [search.ok] was emitted on:
       [search.cap], [search.result] and [search.answer] carry [provider], [qlen]
       and [qhash] — the fields that tie a content event to its decision line
       without repeating the query — and none of the counts and flags that belong
       to [search.ok] alone. *)
    base

  let log_caps base t (result : Model.provider_result) (uncapped : int option list) =
    (* One [search.cap] per hit that carried a capped field: the length the policy
       cap discarded, which is what makes [max_snippet_chars] measurable from real
       traffic. Counts only, never on [search.ok], so the aggregate's field set
       cannot grow with [max_results] — a number the calling model picks.
       Unconditional, unlike the content events: these are counts, not caller
       content. *)
    let policy = t.config.Config.policy in
    List.iteri
      (fun index (item, uncapped_chars) ->
        match uncapped_chars with
        | None -> () (* a hit with no capped field is skipped *)
        | Some uncapped_chars ->
          (* A result carries [snippet] or [text], never both, so which one is set
             names the cap that applied. *)
          let field, cap, chars =
            match item.Model.snippet with
            | Some snippet -> ("snippet", policy.Config.max_snippet_chars, codepoints snippet)
            | None ->
              ( "text"
              , policy.Config.max_result_text_chars
              , codepoints (match item.text with None -> "" | Some text -> text) )
          in
          emit base Config.Log_info "search.cap"
            [
              ("rank", `Int (index + 1))
            ; ("field", `String field)
            ; ("cap", `Int cap)
            ; ("chars", `Int chars)
            ; ("uncapped_chars", `Int uncapped_chars)
            ])
      (List.combine result.Model.results uncapped)

  let log_content base t (result : Model.provider_result) =
    (* Content rides its own events so [search.ok] keeps a fixed shape, and one
       record bounds one hit rather than letting [max_results] set line length. *)
    if not t.config.Config.logging.log_content
    then ()
    else begin
      let policy = t.config.Config.policy in
      List.iteri
        (fun index item ->
          emit base Config.Log_info "search.result"
            (result_fields item (index + 1) ~snippet_chars:policy.Config.max_snippet_chars
               ~text_chars:policy.Config.max_result_text_chars))
        result.Model.results;
      match result.Model.answer with
      | None -> ()
      | Some answer ->
        emit base Config.Log_info "search.answer"
          [ ("answer", `String (safe ~limit:policy.Config.max_result_text_chars (Some answer))) ]
    end

  let resolve_or_reject t ?mode requested =
    (* Resolve, or log [search.rejected] for the operator and hand the refusal
       back. [permitted] sits beside [enabled] so the operator's line tells the two
       refusals apart: a name this deployment does not serve, and one it will not
       dispatch. *)
    match resolve t ?mode requested with
    | Ok name -> Ok name
    | Error sentence ->
      emit
        { log = t.log; fields = [] }
        Config.Log_warning
        "search.rejected"
        [
          ("requested", `String (safe ~limit:40 requested))
        ; ("mode", match mode with None -> `Null | Some Router.Free -> `String "free")
        ; ("enabled", `String (String.concat "," (providers t)))
        ; ( "permitted"
          , match t.config.Config.permitted_providers with
            | None -> `Null
            | Some names when names = [] -> `Null
            | Some names -> `String (String.concat "," names) )
        ];
      Error sentence

  let failure_line base original ~(ms : int) =
    emit
      (bind
         base
         [
           ("ms", `Int ms)
         ; ("kind", `String (error_class original.Provider.kind))
         ; ("reason", `String original.Provider.message)
         ; ("retryable", `Bool original.Provider.retryable)
         ])
      Config.Log_warning
      "search.failed"
      []

  let walk_fallbacks
      t
      (tried : Config.name)
      (q : Model.search_query)
      (original : Provider.error)
      base
      ~(started : float)
      ?(fallbacks : Config.name list option)
      ?mode
      ?run
      ?step
      () : (Provider.outcome, error) result =
    (* Walk a ladder in walk order; the first result wins. [fallbacks] is the free
       walk when this is a free route — it cannot contain a paid name — and
       [search.fallback] otherwise. Each fallback at most once; the tried,
       unpermitted and open-circuit ones are skipped. When every fallback fails the
       {i original} error is what the caller reads: "serper: rate limited" explains
       the search that was asked for, a linkup error does not. *)
    let failed : Config.name list ref = ref [] in
    let table = table t in
    let ladder = match fallbacks with None -> table.Router.fallback | Some names -> names in
    (* Snapshotted once: the walk records the board only for names it attempts, and
       each name appears at most once, so a rung ahead of the walk cannot change
       state under it. *)
    let gated = List.filter (fun name -> Health.is_open t.health name) ladder in
    let permitted =
      match t.config.Config.permitted_providers with None -> [] | Some names -> names
    in
    let rec go = function
      | [] ->
        let ms = elapsed t.clock started in
        failure_line base original ~ms;
        record_failure t ~provider:tried ~ms ~fell_back:true ~error:(error_class original.kind) ?run
          ?step ();
        Error
          (Failed
             ("Search failed - " ^ Provider.render_error original ^ "."
             ^ Router.fallback_exhausted_note ~failed:!failed ~mode
             ^ Router.retry_advice ~quota:(original.kind = Provider.Quota)))
      | rung :: rest ->
        let fallback = rung.Router.name in
        match rung.Router.status with
        | Router.Skip -> go rest
        | Router.Unpermitted ->
          (* Warning rather than info, unlike the open-circuit skip below: a gated
             fallback is dead config the operator should fix. *)
          emit
            (bind
               base
               [
                 ("fallback", `String fallback)
               ; ("permitted", `String (String.concat "," permitted))
               ])
            Config.Log_warning
            "search.fallback_unpermitted"
            [];
          go rest
        | Router.Open ->
          emit
            (bind
               base
               [
                 ("fallback", `String fallback)
               ; ("until_s", `Float (round1 (Health.open_for_s t.health fallback)))
               ])
            Config.Log_info
            "search.fallback_skipped"
            [];
          go rest
        | Router.Candidate ->
          let rung_started = t.clock () in
          (match call t fallback q with
          | Error exc ->
            emit
              (bind
                 base
                 [
                   ("fallback", `String fallback)
                 ; ("reason", `String exc.Provider.message)
                 ; ("original_reason", `String original.Provider.message)
                 ; ("ms", `Int (elapsed t.clock rung_started))
                 ])
              Config.Log_warning
              "search.fallback_failed"
              [];
            failed := !failed @ [ fallback ];
            go rest
          | Ok outcome ->
            emit
              (bind
                 base
                 [
                   ("fallback", `String fallback)
                 ; ("reason", `String original.Provider.message)
                 ; ("ms", `Int (elapsed t.clock rung_started))
                 ])
              Config.Log_info
              "search.fallback"
              [];
            Ok
              {
                outcome with
                Provider.notice =
                  Some
                    (Router.fallback_served_notice ~tried ~original_reason:original.message ~fallback
                       ~notice:outcome.notice)
              })
    in
    go (Router.fallback_rungs table ~ladder ~tried ~gated)

  let search t ?provider ?mode ?run ?step (q : Model.search_query) :
      (Model.search_response, error) result =
    if provider <> None && mode <> None
    then
      (* Two ways to name a route hides a precedence rule, so neither wins; a
         refusal rather than a failure, since nothing was billed. *)
      Error (Refused "pass `provider` or `mode`, not both")
    else begin
      let table = table t in
      let free = mode <> None in
      let walking_free = free || (provider = None && Router.unnamed_walks_free table) in
      (* Resolved once: the first attempt and the fallbacks walked behind it must
         come from the same list, or a fallback could be tried twice. *)
      let fallbacks = if walking_free then Some (Router.free_walk table) else None in
      match resolve_or_reject t ?mode provider with
      | Error sentence -> Error (Refused sentence)
      | Ok name ->
        (* [provider] stays the first attempt for every event of this call; a
           substitute is named by [search.fallback] and by the response's
           [provider]. *)
        let base =
          { log = t.log
          ; fields =
              [ ("provider", `String name); ("max_results", `Int q.Model.max_results) ]
              @ query_fields t.config.Config.logging q.Model.query
          }
        in
        let started = t.clock () in
        let served =
          match call t name q with
          | Ok outcome -> Ok (outcome, false)
          | Error failure ->
            if walking_free
            then
              (* [fallbacks] is the free walk, so this cannot reach a paid name. *)
              Result.map (fun outcome -> (outcome, true))
                (walk_fallbacks t name q failure base ~started ?fallbacks ?mode ?run ?step ())
            else if provider = None && table.Router.fallback <> []
            then
              Result.map (fun outcome -> (outcome, true))
                (walk_fallbacks t name q failure base ~started ?mode ?run ?step ())
            else begin
              let ms = elapsed t.clock started in
              failure_line base failure ~ms;
              record_failure t ~provider:name ~ms ~fell_back:false ~error:(error_class failure.kind)
                ?run ?step ();
              Error
                (Failed
                   ("Search failed - " ^ Provider.render_error failure ^ "."
                   ^ Router.retry_advice ~quota:(failure.kind = Provider.Quota)))
            end
        in
        match served with
        | Error refused -> Error refused
        | Ok (outcome, fell_back) ->
          (* The serving provider, not the first attempt: after a walk the
             zero-results sentence names the fallback that answered, the way
             Python passes [result.provider]. *)
          let notice = compose_notice t outcome outcome.Provider.provider in
          (* Escaped once: the decision line, the content log, and the agent's
             retrieval material all read this one escaped object. The notice is
             composed {i before} the pass and is not itself escaped, as in Python,
             where [_compose_notice] read the adapter's field before
             [sanitize_model] replaced it. *)
          let escaped, sanitized =
            Model.sanitize_provider_result (Provider.to_provider_result outcome)
          in
          (* [search.cap] reads the pre-cap lengths the adapter measured, which ride
             beside the result on the provider boundary and are dropped at
             [to_provider_result]. *)
          let uncapped =
            List.map (fun (hit : Provider.hit) -> hit.uncapped_chars) outcome.Provider.results
          in
          let ms = elapsed t.clock started in
          let ok = log_ok base escaped notice ~ms ~fell_back ?mode ~sanitized () in
          log_caps ok t escaped uncapped;
          (match t.usage with
          | None -> ()
          | Some usage ->
            Usage.record_search usage ~provider:outcome.Provider.provider ~ms
              ~cost_usd:(match outcome.cost_usd with None -> 0.0 | Some cost -> cost)
              ~results:(List.length outcome.Provider.results)
              ~fell_back ?run ?step ());
          log_content ok t escaped;
          Ok
            { Model.query = q.query
            ; provider = outcome.provider
            ; results = escaped.results
            ; answer = escaped.answer
            ; retrieved_at = Some (Usage.iso_utc_seconds (t.now ()))
            ; notice
            }
    end
end

(* {1 The fetch engine} *)

module Fetch = struct
  type image = Seekwright_wire.Page.image = { media_type : string; body : string }

  type page = Seekwright_wire.Page.page = {
    url : string
  ; title : string option
  ; text : string
  ; content_type : string option
  ; status_code : int
  ; truncated : bool
  ; total_chars : int
  ; path_addressable : bool
  ; image : image option
  }

  type cap = Default | Limit of int | Uncapped

  type error = Refused of string | Failed of string

  type fetch_error =
    | Provider of Provider.error
    | Url_blocked of string
    | Redirect_blocked of string
    | Fetch_blocked of string

  type fetcher = {
    name : Config.name
  ; cost_per_1k : float option
  ; fetch : url:string -> offset:int -> max_chars:cap -> (page, fetch_error) result
  ; aclose : unit -> unit
  }

  module Readers = struct
    type selection = int * string

    type t = {
      parse_path : string -> (unit, string) result
    ; render_schema : string -> string option
    ; select_paths : text:string -> path:string -> max_chars:int -> selection list * int
    ; select_passages : text:string -> query:string -> max_chars:int -> selection list * int
    }
  end

  (* One route rung's answer: the page, the fallback that produced it ([None] is
     this server's own reader), and whether a warm cache entry served it. *)
  type served = { page : page; fallback : Config.name option; cached : bool }

  type t = {
    config : Config.t
  ; fetcher : fetcher
  ; fallbacks : fetcher list
  ; usage : Usage.t option
  ; readers : Readers.t
  ; log : log
  ; clock : unit -> float
  ; now : unit -> float
  }

  let primary_name (config : Config.t) =
    if config.Config.fetch.primary = "http" then None else Some config.Config.fetch.primary

  let unbuilt_primary (config : Config.t) =
    "fetch.primary names " ^ py_repr config.Config.fetch.primary
    ^ ", which this deployment did not build"

  let create
      (config : Config.t)
      (fetcher : fetcher)
      ~(readers : Readers.t)
      ?usage
      ?log
      ?(fallbacks = [])
      ~(clock : unit -> float)
      ~(now : unit -> float)
      () =
    (* When a fallback leads the unnamed route, the local read is out of that route
       entirely: the operator who set [fetch.primary] is saying this server's own
       IP should not be what the page sees. Membership is checked here and the
       object is resolved lazily, so a caller that swaps [fallbacks] after
       construction gets a route from what it holds now. Python's constructor
       raises [ValueError] — [server.main]'s pre-flight refuses this config before
       an engine is built — and [Error] is this port's one sentence for it, because
       falling back to the local reader would dial from this server's own IP
       against the operator's config. *)
    match primary_name config with
    | Some name when not (List.exists (fun (fallback : fetcher) -> fallback.name = name) fallbacks) ->
      Error (unbuilt_primary config)
    | _ ->
      Ok
        { config
        ; fetcher
        ; fallbacks
        ; usage
        ; readers
        ; log = (match log with None -> quiet | Some sink -> sink)
        ; clock
        ; now
        }

  (* Rebuilt per call, for the same reason the search table is: a caller may swap
     the ladder, and the route has to come from what it holds now. *)
  let table (t : t) : Router.fetch_table =
    { Router.built = List.map (fun (fallback : fetcher) -> fallback.name) t.fallbacks
    ; primary = primary_name t.config
    }

  let primary t =
    match primary_name t.config with
    | None -> Ok t.fetcher
    | Some name -> (
      match List.find_opt (fun (fallback : fetcher) -> fallback.name = name) t.fallbacks with
      | Some fallback -> Ok fallback
      | None -> Error (Failed (unbuilt_primary t.config)))

  (* The ladder the unnamed route walks: the built fallbacks minus the primary,
     which the route already tried — walking it twice would bill the same name
     twice. It is taken out by name and not by object identity, because a built
     ladder holds one object per name. *)
  let ladder t =
    let walked = Router.fetch_walk (table t) in
    List.filter (fun (fallback : fetcher) -> List.mem fallback.name walked) t.fallbacks

  (* Three cases collapse into one refusal: a name unknown to the fetch registry,
     one the registry has but this deployment never built for want of a key or a
     url, and one the permission set excluded. A search-set name like [serper] is
     the first case. The object comes back rather than the name because the object,
     not the name, is what the call is priced from. *)
  let resolve t requested =
    let resolved =
      try Ok (Router.resolve_fetch (table t) requested)
      with Router.Route_refused sentence -> Error sentence
    in
    match resolved with
    | Error sentence -> Error sentence
    | Ok None -> Ok None
    | Ok (Some name) -> (
      match List.find_opt (fun (fallback : fetcher) -> fallback.name = name) t.fallbacks with
      | Some fallback -> Ok (Some fallback)
      | None -> Error (Router.not_enabled (table t) name))

  let reason (failure : fetch_error) : string =
    match failure with
    | Provider error -> error.Provider.message
    | Url_blocked message | Redirect_blocked message | Fetch_blocked message -> message

  (* Python's [str()] of the exception, which is what the failure sentence quotes:
     a provider failure names the provider that raised it, and a guardrail refusal
     is the [fetch] provider's own. *)
  let render (failure : fetch_error) : string =
    match failure with
    | Provider error -> Provider.render_error error
    | Url_blocked message | Redirect_blocked message | Fetch_blocked message -> "fetch: " ^ message

  (* Every [FetchBlocked] is non-retryable: the answer will be the same next time,
     and a model that reads "retry shortly" will do exactly that. *)
  let retryable (failure : fetch_error) : bool =
    match failure with Provider error -> error.Provider.retryable | _ -> false

  let blocked (failure : fetch_error) : bool =
    match failure with Provider _ -> false | _ -> true

  (* Only the URL-level refusals are refused {i before} the request, which is what
     the REST projection reports as 400 rather than 502. [Redirect_blocked] is a
     sibling and not a child, precisely so this arm does not catch it. *)
  let before_request (failure : fetch_error) : bool =
    match failure with Url_blocked _ -> true | _ -> false

  let error_name (failure : fetch_error) : string =
    match failure with
    | Provider error -> error_class error.Provider.kind
    | Url_blocked _ -> "UrlBlocked"
    | Redirect_blocked _ -> "RedirectBlocked"
    | Fetch_blocked _ -> "FetchBlocked"

  let log_for t (url : string) : bound =
    (* A URL a model chose off a third-party page is the same sensitivity class as a
       query, so it rides the same switch; the host always. *)
    let base = { log = t.log; fields = [ ("host", `String (host_of url)) ] } in
    if t.config.Config.logging.log_queries
    then bind base [ ("url", `String (safe ~limit:200 (Some url))) ]
    else base

  let is_empty t (text : string) =
    (* Whether an extraction found so little that it counts as nothing. The floor of
       1 keeps a blank page empty at every setting. *)
    codepoints (strip text) < max t.config.Config.fetch.min_text_chars 1

  let log_ok base (_t : t) (page : page) ~(fell_back : bool) ~(ms : int) ~(sanitized : int) ?image_bytes
      ~(cached : bool) () =
    (* Counts and flags, never content. [fell_back] is true whenever a route other
       than this server's own reader served — an operator-configured primary
       included — and [cached] is always bound the same way. [bytes] rides only on
       an image page. *)
    let fields =
      [
        ("ms", `Int ms)
      ; ("status", `Int page.status_code)
      ; ("chars", `Int (codepoints page.text))
      ; ("truncated", `Bool page.truncated)
      ; ("fell_back", `Bool fell_back)
      ; ("sanitized", `Int sanitized)
      ; ("cached", `Bool cached)
      ]
      @
      match image_bytes with None -> [] | Some size -> [ ("bytes", `Int size) ]
    in
    emit (bind base fields) Config.Log_info "fetch.ok" []

  (* The declared price of the one call [fallback] made, or [None] — which covers
     both cases where nothing was billed: the local reader served it, or the
     fallback cannot bill at all ([crawl4ai] is the operator's own renderer, [jina]
     is keyless). The journal line then carries no [cost_usd] rather than a [0.0]
     that would read as a measured free call. Per {i call}, not per delivered
     character, because a past-end [offset] still fetched and billed the page. Read
     off the object and not re-derived from config: the object already resolved
     [fetch.cost_per_1k] when the ladder was built, and a second resolution could
     disagree with it. *)
  let fallback_cost_usd t (fallback : Config.name option) : float option =
    match fallback with
    | None -> None
    | Some name -> (
      match List.find_opt (fun (candidate : fetcher) -> candidate.name = name) t.fallbacks with
      | Some candidate -> (
        match candidate.cost_per_1k with None -> None | Some rate -> Some (rate /. 1000.))
      | None -> None)

  let finish_served_call base t (page : page) ~(fallback : Config.name option) ~(started : float)
      ~(sanitized : int)
      ?image_bytes
      ?(cached = false)
      ?run
      ?step
      () =
    (* The shared tail of every served fetch. A past-end offset goes through here
       too: its page was still fetched and billed, so the operator's line and the
       dashboard's fetch counter must see the call, and it is priced like any
       other, because the {i call} is what a fallback bills. *)
    let ms = elapsed t.clock started in
    log_ok base t page ~fell_back:(fallback <> None) ~ms ~sanitized ?image_bytes ~cached ();
    match t.usage with
    | None -> ()
    | Some usage ->
      (* [chars] counts extracted text, which an image page has none of; the call is
         what the journal prices, and it was made. A dispatch-free read is unbilled
         whatever the rung's price: the absence is the journal's "nothing was
         spent", so a cache easing repeat reads never reads as a provider turned
         free. *)
      Usage.record_fetch usage ~ms ~chars:(codepoints page.text) ~fallback
        ?cost_usd:(if cached then None else fallback_cost_usd t fallback)
        ?run ?step ()

  let raise_failure base t (exc : fetch_error) ~(started : float) ?(also_failed = "") ?(choice = "")
      ?run
      ?step
      () : error =
    (* Log the failure and answer with model-facing advice. [also_failed] names the
       members a walk ran and lost — that caller already had the choice. [choice] is
       the recovery sentence for a read never walked, and it {i replaces} the generic
       retry advice rather than doubling it: one says wait and retry, the other retry
       on a named provider. A guardrail refusal is the SSRF policy working, so it is
       levelled apart; that one branch covers every [FetchBlocked] site. *)
    let ms = elapsed t.clock started in
    if blocked exc
    then emit (bind base [ ("ms", `Int ms); ("reason", `String (reason exc)) ]) Config.Log_info "fetch.blocked" []
    else
      emit
        (bind
           base
           [ ("ms", `Int ms); ("reason", `String (reason exc)); ("retryable", `Bool (retryable exc)) ])
        Config.Log_warning
        "fetch.failed"
        [];
    (match t.usage with
    | None -> ()
    (* Nothing was billed: neither the local refusals nor the fallback failures that
       led here cost a credit. *)
    | Some usage ->
      Usage.record_fetch usage ~ms ~chars:0 ~fallback:None ~error:(error_name exc) ?run ?step ());
    let advice =
      if choice <> "" || not (retryable exc) then "" else " Retry shortly, or search for the content."
    in
    let message = "Fetch failed - " ^ render exc ^ "." ^ also_failed ^ advice ^ choice in
    if before_request exc then Refused message else Failed message

  (* One route rung's page read. [rung] is the rung's own name, or [None] for the
     local reader: it keys the cache entry and it is what the journal prices, so the
     local read and a fallback's stay different answers to the same URL.

     This port has no page cache yet, which is Python's [self.cache is None] path:
     every read dispatches, [cached] is [false], and no window is recomputed out of
     a stored whole page. The cache changes this function and nothing else in here,
     which is why the flag is threaded through the calls below even though no caller
     sets it yet. *)
  let read_page (_t : t) (fetcher : fetcher) ~(rung : Config.name option) ~(url : string) ~(offset : int)
      ~(max_chars : cap) : (served, fetch_error) result =
    Result.map
      (fun page -> { page; fallback = rung; cached = false })
      (fetcher.fetch ~url ~offset ~max_chars)

  let try_fallbacks t (url : string) notices ~(original_reason : string) base
      ~(tried : Config.name list ref)
      ~(offset : int) ~(max_chars : cap) () : served option =
    (* Walk the fallbacks in order; the best page found, or [None]. Never fails: the
       caller keeps the {i original} failure, whose reason is what the walk's members
       are told and whose sentence the caller gets. [tried] fills with every name
       {i reached} — a walk that returned no page had all of them raise, and that is
       the list the failure sentence reports. The walk continues past an empty
       fallback page: the paid-run-last rule. *)
    let why = ref original_reason in
    let rec go = function
      | [] -> None
      | fallback :: rest ->
        tried := !tried @ [ fallback.name ];
        let started = t.clock () in
        match read_page t fallback ~rung:(Some fallback.name) ~url ~offset ~max_chars with
        | Error exc ->
          emit
            (bind
               base
               [
                 ("fallback", `String fallback.name)
               ; ("reason", `String (reason exc))
               ; ("original_reason", `String !why)
               ; ("ms", `Int (elapsed t.clock started))
               ])
            Config.Log_warning
            "fetch.fallback_failed"
            [];
          why := reason exc; (* its failure is the next fallback's reason to exist *)
          go rest
        | Ok rung ->
          emit
            (bind
               base
               [ ("fallback", `String fallback.name); ("reason", `String !why); ("ms", `Int (elapsed t.clock started)) ])
            Config.Log_info
            "fetch.fallback"
            [];
          if not rung.cached then
            notices := !notices @ [ Router.refetched_notice (table t) ~reason:!why ~fallback:fallback.name ];
          if is_empty t rung.page.text
          then begin
            why := "almost no readable text";
            match go rest with Some answer -> Some answer | None -> Some rung
          end
          else Some rung
    in
    go (ladder t)

  let fetch_named t (named : fetcher) ~(url : string) ~(offset : int) ~(max_chars : cap) base
      ~(started : float) ?run ?step () : (served, error) result =
    (* Serve the page through the one provider the caller named: one attempt, and its
       name is the fallback the call is journalled to, which prices the line. No
       local fetch fails first and no walk substitutes for it, so a caller using
       [provider] as a cost knob is not billed by a second name — [search]'s rule. *)
    match read_page t named ~rung:(Some named.name) ~url ~offset ~max_chars with
    | Error exc -> Error (raise_failure base t exc ~started ?run ?step ())
    | Ok rung -> Ok { rung with fallback = Some named.name }

  let fetch_page t ~(url : string) ~(offset : int) ~(max_chars : cap) notices base ~(started : float)
      ?named ~(auto_fallback : bool) ?run ?step () : (served, error) result =
    match named with
    | Some fallback -> fetch_named t fallback ~url ~offset ~max_chars base ~started ?run ?step ()
    | None -> (
      (* The primary first; [fallback] is that rung's journal name, [None] when the
         local reader leads. *)
      match primary t with
      | Error unbuilt -> Error unbuilt
      | Ok reader ->
        let tried = ref [] in
        (match read_page t reader ~rung:(primary_name t.config) ~url ~offset ~max_chars with
        | Error exc ->
          if not auto_fallback
          then begin
            (* The withheld walk is a choice only where the failure left one: a
               guardrail refusal names providers that would refuse the same URL,
               because every remote fallback applies the SSRF policy itself. Its
               reason already says what was refused. *)
            let choice = if blocked exc then "" else Router.choose_instead (table t) in
            Error (raise_failure base t exc ~started ~choice ?run ?step ())
          end
          else
            (match try_fallbacks t url notices ~original_reason:(reason exc) base ~tried ~offset
                   ~max_chars ()
             with
            | None ->
              Error
                (raise_failure
                   base
                   t
                   exc
                   ~started
                   ~also_failed:
                     (if !tried = []
                      then ""
                      else " Fallbacks also failed: " ^ String.concat ", " !tried ^ ".")
                   ?run ?step ())
            | Some answer -> Ok answer)
        | Ok rung ->
          (* An image's empty text is the resource itself, not the JS-shell symptom
             this gate exists to catch: escalating would bill a renderer and a
             scraper to look for prose in a photograph. A structure page is exempt
             for the same shape of reason — three rows of a CSV are an answer, not a
             page that failed to yield text. *)
          if auto_fallback && rung.page.image = None && not rung.page.path_addressable && offset = 0
             && is_empty t rung.page.text
          then
            (match try_fallbacks t url notices ~original_reason:"almost no readable text" base ~tried
                   ~offset ~max_chars ()
             with
            | Some escalated -> Ok escalated
            | None -> Ok rung)
          else Ok rung))

  let selections notices ~(path : string option) ~(budget : int) spans dropped :
      Model.fetch_match list option =
    if spans = []
    then begin
      notices
        := !notices
           @ [
               (match path with
               | Some _ ->
                 (* [dropped] counts sections that matched and were cut, so "nothing
                    matched" must not be said of a document that is merely over
                    budget. *)
                 if dropped > 0
                 then
                   "the part of this document that `path` addresses is larger than"
                   ^ " the selection budget ("
                   ^ string_of_int budget
                   ^ " chars); ask for a narrower `path`, or a slice of an array, as"
                   ^ " in [0:5], or raise fetch.max_match_chars"
                 else
                   "nothing in this document matches that `path`; fetch without"
                   ^ " `path` to read its structure, where every line names the path"
                   ^ " that addresses it"
               | None ->
                 "none of the query terms appear on this page; fetch without"
                 ^ " `query` to read it")
             ];
      Some []
    end
    else begin
      if dropped > 0
      then
        notices
          := !notices
             @ [
                 (match path with
                 | Some _ ->
                   "selection budget (" ^ string_of_int budget ^ " chars) reached; "
                   ^ string_of_int dropped
                   ^ " more matching section(s) not returned; raise"
                   ^ " fetch.max_match_chars or ask for a narrower `path`, or a slice"
                   ^ " of an array, as in [0:5]"
                 | None ->
                   "passage budget (" ^ string_of_int budget ^ " chars) reached; "
                   ^ string_of_int dropped
                   ^ " more matching section(s) not returned; raise"
                   ^ " fetch.max_match_chars or fetch with `offset` near a match")
               ];
      Some (List.map (fun (offset, text) -> { Model.offset = offset; text }) spans)
    end

  let select t (page : page) ?query ?path ~(empty_page : bool) notices :
      Model.fetch_match list option =
    (* What the caller asked to be shown: passages, a subtree, or the page. An
       unreadable page outranks a no-match, so an empty page skips selection and
       keeps the shell diagnosis instead of claiming nothing matched. *)
    let budget = t.config.Config.fetch.max_match_chars in
    if empty_page
    then None
    else if path <> None && not page.path_addressable
    then begin
      (* The extraction's own flag, not a reading of the text: a page whose first
         character happens to be [$] is not a document. The page was fetched and
         possibly billed, so it comes back entire with the constraint named rather
         than failing — the [providers.base.ignored_constraints] rule, which says a
         constraint the serving side cannot honour is reported, not dropped. *)
      notices
        := !notices
           @ [
               "`path` selects inside a JSON document or a CSV table, and this page"
               ^ " is not one this server could read; the whole page is returned"
             ];
      None
    end
    else
      match path, query with
      | None, None -> None
      | Some selector, _ ->
        let spans, dropped =
          t.readers.select_paths ~text:page.text ~path:selector ~max_chars:budget
        in
        selections notices ~path:(Some selector) ~budget spans dropped
      | None, Some terms ->
        let spans, dropped =
          t.readers.select_passages ~text:page.text ~query:terms ~max_chars:budget
        in
        selections notices ~path:None ~budget spans dropped

  let join_notices (notices : string list) : string option =
    match notices with [] -> None | _ -> Some (String.concat "; " notices)

  let response t ~(url : string) (page : page) ~(offset : int) ?matches ?image notices :
      Model.fetch_response =
    { Model.url = page.url
    ; requested_url = url
    ; title = page.title
    ; text = (if matches <> None then None else Some page.text)
    ; content_type = page.content_type
    ; status_code = Some page.status_code
    ; retrieved_at = Some (Usage.iso_utc_seconds (t.now ()))
    ; truncated = page.truncated
    ; total_chars = Some page.total_chars
    ; offset = (if offset = 0 then None else Some offset)
    ; matches
    ; image
    ; notice = join_notices notices
    }

  let past_end t ~(url : string) (page : page) ~(offset : int) : Model.fetch_response =
    (* An offset past a known-readable page: empty text and a plain notice. Only the
       body is withheld — this builder bills nothing, and the caller has already
       emitted [fetch.ok] and journalled the call. *)
    { Model.url = page.url
    ; requested_url = url
    ; title = page.title
    ; text = Some ""
    ; content_type = page.content_type
    ; status_code = Some page.status_code
    ; retrieved_at = Some (Usage.iso_utc_seconds (t.now ()))
    ; truncated = false
    ; total_chars = Some page.total_chars
    ; offset = Some offset
    ; matches = None
    ; image = None
    ; notice =
        Some
          (Printf.sprintf "offset %d is past the end of the page (%d chars); nothing returned" offset
             page.total_chars)
    }

  let image_notice image size carried =
    if carried
    then
      image.media_type ^ " image of " ^ grouped size
      ^ " bytes returned as image bytes: an image has no extracted text for"
      ^ " `query`, `path` or `offset` to address"
    else
      image.media_type ^ " image of " ^ grouped size
      ^ " bytes was fetched: `answer` builds its material from text, so its"
      ^ " bytes are not returned"

  let finish_image t ~(url : string) (page : page) (image : image) ~(fallback : Config.name option)
      base ~(started : float) (notices : string list) ~(run : string option) : Model.fetch_response =
    (* The whole path of an image page: journal it, say what it is, hand it over. An
       image has no text to escape, page through or select passages from, so it never
       reaches the text machinery, and the emptiness gate never walks the ladder for
       one. [answer] builds its material out of text, so an image fetched inside an
       [answer] walk is reported to the model rather than carried into a prompt that
       cannot read it — still journalled, because the call was still made. *)
    let size = String.length image.body in
    let carried =
      if run <> None
      then None
      else Some { Model.byte_count = size; base64 = base64 image.body }
    in
    finish_served_call base t page ~fallback ~started ~sanitized:0 ~image_bytes:size ();
    { Model.url = page.url
    ; requested_url = url
    ; title = page.title
    ; text = None
    ; content_type = Some image.media_type
    ; status_code = Some page.status_code
    ; retrieved_at = Some (Usage.iso_utc_seconds (t.now ()))
    ; truncated = false
    ; total_chars = None
    ; offset = None
    ; matches = None
    ; image = carried
    ; notice = join_notices (notices @ [ image_notice image size (carried <> None) ])
    }

  let log_content base t (page : page) ?(matches : Model.fetch_match list option) () =
    (* Off by default: this is the bulkiest record the process can emit, up to
       [fetch.max_text_chars] characters on one line. *)
    if not t.config.Config.logging.log_content
    then ()
    else
      let content =
        match matches with
        | None -> page.text
        | Some found ->
          String.concat "\n\n" (List.map (fun (item : Model.fetch_match) -> item.Model.text) found)
      in
      let fields =
        [
          ("title", `String (safe ~limit:200 page.title))
        ; ("text", `String (safe ~limit:t.config.Config.fetch.max_text_chars (Some content)))
        ]
      in
      emit (bind base fields) Config.Log_info "fetch.content" []

  (* The body of [fetch], once the one-axis and [path]-syntax refusals are out of the
     way: [fetch] reads the request, this does the route. *)
  let serve t ~(url : string) ~(offset : int) ?query ?path ~(structure : bool) ~(named : fetcher option)
      ~(auto_fallback : bool) ~(run : string option) ?step () : (Model.fetch_response, error) result =
    let notices : string list ref = ref [] in
    (* A selection by terms or by structure reads the whole document; the budget
       bounds the response, not the fetch. *)
    let max_chars = if query <> None || path <> None || structure then Uncapped else Default in
    let base = log_for t url in
    let started = t.clock () in
    match
      fetch_page t ~url ~offset ~max_chars notices base ~started ?named ~auto_fallback ?run ?step ()
    with
    | Error refused -> Error refused
    | Ok { page; fallback; cached } ->
      if page.image <> None
      then Ok (finish_image t ~url page (Option.get page.image) ~fallback base ~started !notices ~run)
      else begin
        (* The ladder is finished and this page is the page, so the escape lands here:
           everything downstream reads the escaped text. An offset taken from escaped
           text stays valid across a re-fetch; only a cut-boundary token drifts. *)
        let page =
          if structure
          then
            (* One shape replaced for one page read, {i before} the escape pass: the
               paths a schema carries come out of the page's keys, so its text escapes
               in the same pass any other page text would. A page that is not one this
               server read as either shape cannot give a schema, and the whole page is
               returned under the same sentence [path] answers with. *)
            match page.path_addressable, t.readers.render_schema page.text with
            | true, Some rendered -> { page with text = rendered }
            | _ ->
              notices
                := !notices
                   @ [
                       "`structure` reports a JSON or CSV table's shape, and this page"
                       ^ " is not one this server could read as either; the whole page"
                       ^ " is returned"
                     ];
              page
          else page
        in
        let text, escaped = Sanitize.sanitize_text page.text in
        let title, title_escaped =
          match page.title with
          | Some title ->
            let escaped, count = Sanitize.sanitize_text title in
            (Some escaped, count)
          | None -> (None, 0)
        in
        let page = { page with text; title } in
        let sanitized = escaped + title_escaped in
        if query = None && offset > 0 && offset >= page.total_chars
        then begin
          (* Offset > 0 only: an empty page at offset 0 is the JS-shell case, not a
             past-end bookmark. *)
          finish_served_call base t page ~fallback ~started ~sanitized ~cached ?run ?step ();
          Ok (past_end t ~url page ~offset)
        end
        else begin
          let empty_page =
            (* The emptiness gate is about a JS shell answering a read meant to find
               prose. It does not apply to a structure read, nor to a rendered JSON or
               table page, which is short because it is finished. *)
            not structure && not page.path_addressable && offset = 0 && is_empty t page.text
          in
          if empty_page
          then begin
            emit (bind base [ ("chars", `Int (codepoints (strip page.text))) ]) Config.Log_info
              "fetch.empty" [];
            notices := !notices @ [ Router.empty_notice (table t) ~walked:auto_fallback ]
          end;
          let matches = select t page ?query ?path ~empty_page notices in
          finish_served_call base t page ~fallback ~started ~sanitized ~cached ?run ?step ();
          log_content base t page ?matches ();
          Ok (response t ~url page ~offset ?matches !notices)
        end
      end

  let fetch t ?(offset = 0) ?query ?path ?(structure = false) ?provider ?auto_fallback ?run ?step
      (url : string) : (Model.fetch_response, error) result =
    let refusal =
      if query <> None && offset <> 0
      then Some "pass `query` or `offset`, not both"
      else if path <> None && (query <> None || offset <> 0)
      then Some "pass `path`, `query` or `offset`, one at a time"
      else if structure && (query <> None || path <> None || offset <> 0)
      then
        Some
          ("pass `structure` alone; a shape read and a drill are each one read"
          ^ " -- take the shape, then pass `path`")
      else None
    in
    match refusal with
    | Some sentence -> Error (Refused sentence)
    | None -> (
      (* Resolved ahead of any dispatch, as [search] resolves: a name this server
         cannot serve is refused with the list it can. *)
      match resolve t provider with
      | Error sentence -> Error (Refused sentence)
      | Ok named ->
        (* The walk belongs to the route as much as to the key: the [answer] plan asks
           for it per call, and that argument is what keeps it — not [run]/[step],
           which are observability and must not become load-bearing. *)
        let auto_fallback =
          match auto_fallback with
          | None -> t.config.Config.fetch.auto_fallback
          | Some flag -> flag
        in
        match path with
        | Some selector -> (
          (* Syntax first: an unreadable selector should not cost a fetch, let alone a
             fallback credit. *)
          match t.readers.parse_path selector with
          | Error sentence -> Error (Refused ("`path` is not readable: " ^ sentence))
          | Ok () -> serve t ~url ~offset ?query ?path ~structure ~named ~auto_fallback ~run ?step ())
        | None -> serve t ~url ~offset ?query ?path ~structure ~named ~auto_fallback ~run ?step ())
end
