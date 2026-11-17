(* Search and fetch orchestration: the router decides, this module executes, and
   failure is a returned value. *)

module Utf8 = Seekwright_text.Utf8
module Repr = Seekwright_text.Repr

type log = Log.log

let quiet : log = fun _level _event _fields -> ()

type bound = { log : log; fields : (string * Yojson.Safe.t) list }

let bind (base : bound) fields = { log = base.log; fields = base.fields @ fields }

let emit (base : bound) level event fields = base.log level event (base.fields @ fields)

let elapsed (clock : unit -> float) (started : float) : int =
  int_of_float ((clock () -. started) *. 1000.)

let round1 (value : float) : float = Float.floor ((value *. 10.) +. 0.5) /. 10.

let safe ?(limit = 120) (value : string option) : string =
  Repr.py_repr (Utf8.take limit (match value with None -> "" | Some text -> text))

let host_of (url : string) : string =
  match Uri.host (Uri.of_string url) with Some host when host <> "" -> host | _ -> "?"

let query_fields (logging : Config.logging_config) (query : string) : (string * Yojson.Safe.t) list
    =
  let digest = Digestif.SHA256.(to_hex (digest_string query)) in
  [ ("qlen", `Int (Utf8.count query)); ("qhash", `String (String.sub digest 0 8)) ]
  @ if logging.Config.log_queries then [ ("query", `String query) ] else []

let result_fields (item : Model.result) (rank : int) ~(snippet_chars : int) ~(text_chars : int) :
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

let strip (text : string) : string = Utf8.strip text

let zero_results_advice =
  " Zero results usually means the phrasing, not an empty web: retry once on a"
  ^ " different provider or rephrase before concluding the answer does not" ^ " exist."

let error_class (kind : Provider.error_kind) : string =
  (* The journal's [error] is the failure class, never the message. *)
  match kind with
  | Provider.Failure -> "ProviderError"
  | Provider.Quota -> "QuotaExhausted"

type context = {
  config : Config.t;
  usage : Usage.t option;
  log : log;
  clock : unit -> float;
  now : unit -> float;
}

let context_of (config : Config.t) ~(usage : Usage.t option) ~(log : log option)
    ~(clock : unit -> float) ~(now : unit -> float) : context =
  { config; usage; log = (match log with None -> quiet | Some sink -> sink); clock; now }

let guard_route (route : unit -> 'a) : ('a, string) result =
  try Ok (route ()) with Router.Route_refused sentence -> Error sentence

let fallback_failed base event ~(fallback : Config.name) ~(reason : string)
    ~(original_reason : string) ~(ms : int) =
  emit
    (bind base
       [
         ("fallback", `String fallback);
         ("reason", `String reason);
         ("original_reason", `String original_reason);
         ("ms", `Int ms);
       ])
    Config.Log_warning event []

let fallback_served base event ~(fallback : Config.name) ~(reason : string) ~(ms : int) =
  emit
    (bind base [ ("fallback", `String fallback); ("reason", `String reason); ("ms", `Int ms) ])
    Config.Log_info event []

module Search = struct
  type error = Refused of string | Failed of string

  type t = { ctx : context; providers : (Config.name * Provider.t) list; health : Health.t }

  let create (config : Config.t) ?health ?usage ?log (providers : (Config.name * Provider.t) list)
      ~(clock : unit -> float) ~(now : unit -> float) () =
    {
      ctx = context_of config ~usage ~log ~clock ~now;
      providers;
      health = (match health with None -> Health.create ~now:clock () | Some board -> board);
    }

  let providers (t : t) = List.map fst t.providers

  (* Rebuilt per call, never cached: every set here is derived from the built
     adapters, so no route can name a name with no adapter behind it. *)
  let table (t : t) : Router.search_table =
    let built = List.map fst t.providers in
    {
      Router.providers = built;
      default = t.ctx.config.Config.default_provider;
      permitted = t.ctx.config.Config.permitted_providers;
      fallback =
        (match t.ctx.config.Config.search.fallback with None -> [] | Some ladder -> ladder);
      free_fallback =
        (match t.ctx.config.Config.search.free_fallback with None -> [] | Some ladder -> ladder);
      free = Config.free_providers;
      free_order = Config.free_provider_order;
      effective =
        (match t.ctx.config.Config.permitted_providers with
        | None -> built
        | Some permitted -> List.filter (fun name -> List.mem name permitted) built);
    }

  let resolve t ?mode requested =
    guard_route (fun () -> Router.resolve_search (table t) ?mode requested)

  let record_failure t ~(provider : Config.name) ~(ms : int) ~(fell_back : bool) ~(error : string)
      ?run ?step () =
    match t.ctx.usage with
    | None -> ()
    | Some usage ->
        Usage.record_search usage ~provider ~ms ~cost_usd:0.0 ~results:0 ~fell_back ~error ?run
          ?step ()

  let call (t : t) (name : Config.name) (q : Model.search_query) :
      (Provider.outcome, Provider.error) result =
    (* The board records every dispatch, a named provider included. *)
    match List.assoc_opt name t.providers with
    | None ->
        (* Unreachable in a served process; an engine a test assembled can still get here. *)
        Error (Provider.provider_error ~provider:name "no adapter was built for this name")
    | Some adapter -> (
        match Provider.search adapter q with
        | Error failure ->
            Health.record_failure t.health ~reason:failure.Provider.message name ();
            Error failure
        | Ok outcome ->
            Health.record_success t.health ~reason:"search succeeded" name ();
            Ok outcome)

  let compose_notice t (outcome : Provider.outcome) (name : Config.name) : string option =
    if outcome.Provider.results <> [] || outcome.answer <> None then outcome.notice
    else begin
      let others = List.filter (fun other -> other <> name) (providers t) in
      let detail =
        "No results from " ^ name ^ "."
        ^ (if others <> [] then " Other enabled providers: " ^ String.concat ", " others ^ "."
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
    (* [search.ok]'s field set is fixed; the suite pins it. *)
    emit
      (bind base
         [
           ("ms", `Int ms);
           ("results", `Int (List.length result.Model.results));
           ("cost_usd", match result.cost_usd with None -> `Null | Some cost -> `Float cost);
           ("answer", `Bool (result.answer <> None));
           ("notice", match notice with None -> `Null | Some text -> `String text);
           ("fell_back", `Bool fell_back);
           ("mode", match mode with None -> `Null | Some Router.Free -> `String "free");
           ("sanitized", `Int sanitized);
         ])
      Config.Log_info "search.ok" [];
    base

  let log_caps base t (result : Model.provider_result) (uncapped : int option list) =
    (* Counts only, never on [search.ok]: [max_results] is the calling model's pick. *)
    let policy = t.ctx.config.Config.policy in
    List.iteri
      (fun index (item, uncapped_chars) ->
        match uncapped_chars with
        | None -> ()
        | Some uncapped_chars ->
            (* A result carries [snippet] or [text], never both. *)
            let field, cap, chars =
              match item.Model.snippet with
              | Some snippet -> ("snippet", policy.Config.max_snippet_chars, Utf8.count snippet)
              | None ->
                  ( "text",
                    policy.Config.max_result_text_chars,
                    Utf8.count (match item.text with None -> "" | Some text -> text) )
            in
            emit base Config.Log_info "search.cap"
              [
                ("rank", `Int (index + 1));
                ("field", `String field);
                ("cap", `Int cap);
                ("chars", `Int chars);
                ("uncapped_chars", `Int uncapped_chars);
              ])
      (List.combine result.Model.results uncapped)

  let log_content base t (result : Model.provider_result) =
    if not t.ctx.config.Config.logging.log_content then ()
    else begin
      let policy = t.ctx.config.Config.policy in
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
    match resolve t ?mode requested with
    | Ok name -> Ok name
    | Error sentence ->
        emit { log = t.ctx.log; fields = [] } Config.Log_warning "search.rejected"
          [
            ("requested", `String (safe ~limit:40 requested));
            ("mode", match mode with None -> `Null | Some Router.Free -> `String "free");
            ("enabled", `String (String.concat "," (providers t)));
            ( "permitted",
              match t.ctx.config.Config.permitted_providers with
              | None -> `Null
              | Some names when names = [] -> `Null
              | Some names -> `String (String.concat "," names) );
          ];
        Error sentence

  let failure_line base original ~(ms : int) =
    emit
      (bind base
         [
           ("ms", `Int ms);
           ("kind", `String (error_class original.Provider.kind));
           ("reason", `String original.Provider.message);
           ("retryable", `Bool original.Provider.retryable);
         ])
      Config.Log_warning "search.failed" []

  let failure_sentence (failure : Provider.error) ~(note : string) : string =
    "Search failed - " ^ Provider.render_error failure ^ "." ^ note
    ^ Router.retry_advice ~quota:(failure.kind = Provider.Quota)

  let walk_fallbacks t (tried : Config.name) (q : Model.search_query) (original : Provider.error)
      base ~(started : float) ?(fallbacks : Config.name list option) ?mode ?run ?step () :
      (Provider.outcome, error) result =
    (* Each fallback at most once; when every rung fails the original error is what
       the caller reads. *)
    let failed : Config.name list ref = ref [] in
    let table = table t in
    let ladder = match fallbacks with None -> table.Router.fallback | Some names -> names in
    let gated = List.filter (fun name -> Health.is_open t.health name) ladder in
    let permitted =
      match t.ctx.config.Config.permitted_providers with None -> [] | Some names -> names
    in
    let rec go = function
      | [] ->
          let ms = elapsed t.ctx.clock started in
          failure_line base original ~ms;
          record_failure t ~provider:tried ~ms ~fell_back:true ~error:(error_class original.kind)
            ?run ?step ();
          Error
            (Failed
               (failure_sentence original
                  ~note:(Router.fallback_exhausted_note ~failed:!failed ~mode)))
      | rung :: rest -> (
          let fallback = rung.Router.name in
          match rung.Router.status with
          | Router.Skip -> go rest
          | Router.Unpermitted ->
              emit
                (bind base
                   [
                     ("fallback", `String fallback);
                     ("permitted", `String (String.concat "," permitted));
                   ])
                Config.Log_warning "search.fallback_unpermitted" [];
              go rest
          | Router.Open ->
              emit
                (bind base
                   [
                     ("fallback", `String fallback);
                     ("until_s", `Float (round1 (Health.open_for_s t.health fallback)));
                   ])
                Config.Log_info "search.fallback_skipped" [];
              go rest
          | Router.Candidate -> (
              let rung_started = t.ctx.clock () in
              match call t fallback q with
              | Error exc ->
                  fallback_failed base "search.fallback_failed" ~fallback
                    ~reason:exc.Provider.message ~original_reason:original.Provider.message
                    ~ms:(elapsed t.ctx.clock rung_started);
                  failed := !failed @ [ fallback ];
                  go rest
              | Ok outcome ->
                  fallback_served base "search.fallback" ~fallback ~reason:original.Provider.message
                    ~ms:(elapsed t.ctx.clock rung_started);
                  Ok
                    {
                      outcome with
                      Provider.notice =
                        Some
                          (Router.fallback_served_notice ~tried ~original_reason:original.message
                             ~fallback ~notice:outcome.notice);
                    }))
    in
    go (Router.fallback_rungs table ~ladder ~tried ~gated)

  let search t ?provider ?mode ?run ?step (q : Model.search_query) :
      (Model.search_response, error) result =
    if provider <> None && mode <> None then Error (Refused "pass `provider` or `mode`, not both")
    else begin
      let table = table t in
      let free = mode <> None in
      let walking_free = free || (provider = None && Router.unnamed_walks_free table) in
      let fallbacks = if walking_free then Some (Router.free_walk table) else None in
      match resolve_or_reject t ?mode provider with
      | Error sentence -> Error (Refused sentence)
      | Ok name -> (
          let base =
            {
              log = t.ctx.log;
              fields =
                [ ("provider", `String name); ("max_results", `Int q.Model.max_results) ]
                @ query_fields t.ctx.config.Config.logging q.Model.query;
            }
          in
          let started = t.ctx.clock () in
          let served =
            match call t name q with
            | Ok outcome -> Ok (outcome, false)
            | Error failure ->
                if walking_free then
                  (* The free walk cannot reach a paid name. *)
                  Result.map
                    (fun outcome -> (outcome, true))
                    (walk_fallbacks t name q failure base ~started ?fallbacks ?mode ?run ?step ())
                else if provider = None && table.Router.fallback <> [] then
                  Result.map
                    (fun outcome -> (outcome, true))
                    (walk_fallbacks t name q failure base ~started ?mode ?run ?step ())
                else begin
                  let ms = elapsed t.ctx.clock started in
                  failure_line base failure ~ms;
                  record_failure t ~provider:name ~ms ~fell_back:false
                    ~error:(error_class failure.kind) ?run ?step ();
                  Error (Failed (failure_sentence failure ~note:""))
                end
          in
          match served with
          | Error refused -> Error refused
          | Ok (outcome, fell_back) ->
              let notice = compose_notice t outcome outcome.Provider.provider in
              (* Escaped once: the log, the content events and the agent read this object. *)
              let escaped, sanitized =
                Model.sanitize_provider_result (Provider.to_provider_result outcome)
              in
              let uncapped =
                List.map (fun (hit : Provider.hit) -> hit.uncapped_chars) outcome.Provider.results
              in
              let ms = elapsed t.ctx.clock started in
              let ok = log_ok base escaped notice ~ms ~fell_back ?mode ~sanitized () in
              log_caps ok t escaped uncapped;
              (match t.ctx.usage with
              | None -> ()
              | Some usage ->
                  Usage.record_search usage ~provider:outcome.Provider.provider ~ms
                    ~cost_usd:(match outcome.cost_usd with None -> 0.0 | Some cost -> cost)
                    ~results:(List.length outcome.Provider.results)
                    ~fell_back ?run ?step ());
              log_content ok t escaped;
              Ok
                {
                  Model.query = q.query;
                  provider = outcome.provider;
                  results = escaped.results;
                  answer = escaped.answer;
                  retrieved_at = Some (Usage.iso_utc_seconds (t.ctx.now ()));
                  notice;
                })
    end
end

module Fetch = struct
  type image = Seekwright_wire.Page.image = { media_type : string; body : string }

  type page = Seekwright_wire.Page.page = {
    url : string;
    title : string option;
    text : string;
    content_type : string option;
    status_code : int;
    truncated : bool;
    total_chars : int;
    path_addressable : bool;
    image : image option;
  }

  type cap = Default | Limit of int | Uncapped

  type error = Refused of string | Failed of string

  type fetch_error =
    | Provider of Provider.error
    | Url_blocked of string
    | Redirect_blocked of string
    | Fetch_blocked of string

  type fetcher = {
    name : Config.name;
    cost_usd : float option;
    fetch : url:string -> offset:int -> max_chars:cap -> (page, fetch_error) result;
    aclose : unit -> unit;
  }

  module Readers = struct
    type selection = int * string

    type t = {
      parse_path : string -> (unit, string) result;
      render_schema : string -> string option;
      select_paths : text:string -> path:string -> max_chars:int -> selection list * int;
      select_passages : text:string -> query:string -> max_chars:int -> selection list * int;
    }
  end

  type served = { page : page; fallback : Config.name option; cached : bool }

  module Cache = struct
    type t = {
      preflight : string -> (string, fetch_error) result;
      read :
        rung:Config.name ->
        url:string ->
        offset:int ->
        max_chars:cap ->
        dispatch:(offset:int -> max_chars:cap -> (page, fetch_error) result) ->
        (page * bool, fetch_error) result;
    }
  end

  type t = {
    ctx : context;
    fetcher : fetcher;
    fallbacks : fetcher list;
    cache : Cache.t option;
    readers : Readers.t;
  }

  let primary_name (config : Config.t) =
    if config.Config.fetch.primary = "http" then None else Some config.Config.fetch.primary

  let unbuilt_primary (config : Config.t) =
    "fetch.primary names "
    ^ Repr.py_repr config.Config.fetch.primary
    ^ ", which this deployment did not build"

  let create (config : Config.t) (fetcher : fetcher) ~(readers : Readers.t) ?cache ?usage ?log
      ?(fallbacks = []) ~(clock : unit -> float) ~(now : unit -> float) () =
    match primary_name config with
    | Some name when not (List.exists (fun (fallback : fetcher) -> fallback.name = name) fallbacks)
      ->
        Error (unbuilt_primary config)
    | _ ->
        Ok { ctx = context_of config ~usage ~log ~clock ~now; fetcher; fallbacks; cache; readers }

  let table (t : t) : Router.fetch_table =
    {
      Router.built = List.map (fun (fallback : fetcher) -> fallback.name) t.fallbacks;
      primary = primary_name t.ctx.config;
    }

  let primary t =
    match primary_name t.ctx.config with
    | None -> Ok t.fetcher
    | Some name -> (
        match List.find_opt (fun (fallback : fetcher) -> fallback.name = name) t.fallbacks with
        | Some fallback -> Ok fallback
        | None -> Error (Failed (unbuilt_primary t.ctx.config)))

  (* The built fallbacks minus the primary: walking it twice would bill a name twice. *)
  let ladder t =
    let walked = Router.fetch_walk (table t) in
    List.filter (fun (fallback : fetcher) -> List.mem fallback.name walked) t.fallbacks

  let resolve t requested =
    match guard_route (fun () -> Router.resolve_fetch (table t) requested) with
    | Error sentence -> Error sentence
    | Ok None -> Ok None
    | Ok (Some name) -> (
        match List.find_opt (fun (fallback : fetcher) -> fallback.name = name) t.fallbacks with
        | Some fallback -> Ok (Some fallback)
        | None -> Error (Router.not_enabled (table t) name))

  (* [error_name] and not [name]: a [name] field would collide with [fetcher.name]. *)
  type failure_facts = {
    message : string;
    rendered : string;
    retryable : bool;
    blocked : bool;
    before_request : bool;
    error_name : string;
  }

  let guardrail ?(before_request = false) error_name message : failure_facts =
    {
      message;
      rendered = "fetch: " ^ message;
      retryable = false;
      blocked = true;
      before_request;
      error_name;
    }

  let classify (failure : fetch_error) : failure_facts =
    match failure with
    | Provider error ->
        {
          message = error.Provider.message;
          rendered = Provider.render_error error;
          retryable = error.Provider.retryable;
          blocked = false;
          before_request = false;
          error_name = error_class error.Provider.kind;
        }
    | Url_blocked message -> guardrail ~before_request:true "UrlBlocked" message
    | Redirect_blocked message -> guardrail "RedirectBlocked" message
    | Fetch_blocked message -> guardrail "FetchBlocked" message

  let log_for t (url : string) : bound =
    let base = { log = t.ctx.log; fields = [ ("host", `String (host_of url)) ] } in
    if t.ctx.config.Config.logging.log_queries then
      bind base [ ("url", `String (safe ~limit:200 (Some url))) ]
    else base

  let is_empty t (text : string) =
    Utf8.count (strip text) < max t.ctx.config.Config.fetch.min_text_chars 1

  let log_ok base (_t : t) (page : page) ~(fell_back : bool) ~(ms : int) ~(sanitized : int)
      ?image_bytes ~(cached : bool) () =
    let fields =
      [
        ("ms", `Int ms);
        ("status", `Int page.status_code);
        ("chars", `Int (Utf8.count page.text));
        ("truncated", `Bool page.truncated);
        ("fell_back", `Bool fell_back);
        ("sanitized", `Int sanitized);
        ("cached", `Bool cached);
      ]
      @ match image_bytes with None -> [] | Some size -> [ ("bytes", `Int size) ]
    in
    emit (bind base fields) Config.Log_info "fetch.ok" []

  (* What the rung that answered charges for one read, settled by the factory: the
     engine never learns that fetch prices are quoted per thousand. [None] is
     unbilled, not free — the journal then carries no [cost_usd]. *)
  let rung_price t (fallback : Config.name option) : float option =
    match fallback with
    | None -> None
    | Some name -> (
        match List.find_opt (fun (candidate : fetcher) -> candidate.name = name) t.fallbacks with
        | Some candidate -> candidate.cost_usd
        | None -> None)

  let finish_served_call base t (page : page) ~(fallback : Config.name option) ~(started : float)
      ~(sanitized : int) ?image_bytes ?(cached = false) ?run ?step () =
    (* A past-end offset still fetched and billed the page, so it is journalled and priced. *)
    let ms = elapsed t.ctx.clock started in
    log_ok base t page ~fell_back:(fallback <> None) ~ms ~sanitized ?image_bytes ~cached ();
    match t.ctx.usage with
    | None -> ()
    | Some usage ->
        (* A dispatch-free read is unbilled: the absent [cost_usd] is the journal's
         "nothing was spent". *)
        Usage.record_fetch usage ~ms ~chars:(Utf8.count page.text) ~fallback
          ?cost_usd:(if cached then None else rung_price t fallback)
          ?run ?step ()

  let raise_failure base t (exc : fetch_error) ~(started : float) ?(also_failed = "") ?(choice = "")
      ?run ?step () : error =
    let facts = classify exc in
    let ms = elapsed t.ctx.clock started in
    if facts.blocked then
      emit
        (bind base [ ("ms", `Int ms); ("reason", `String facts.message) ])
        Config.Log_info "fetch.blocked" []
    else
      emit
        (bind base
           [
             ("ms", `Int ms); ("reason", `String facts.message); ("retryable", `Bool facts.retryable);
           ])
        Config.Log_warning "fetch.failed" [];
    (match t.ctx.usage with
    | None -> ()
    | Some usage ->
        Usage.record_fetch usage ~ms ~chars:0 ~fallback:None ~error:facts.error_name ?run ?step ());
    let advice =
      if choice <> "" || not facts.retryable then ""
      else " Retry shortly, or search for the content."
    in
    let message = "Fetch failed - " ^ facts.rendered ^ "." ^ also_failed ^ advice ^ choice in
    if facts.before_request then Refused message else Failed message

  (* ["http"] keys the local reader's entry; the journal prices the rung's own name. *)
  let read_page (t : t) (fetcher : fetcher) ~(rung : Config.name option) ~(url : string)
      ~(offset : int) ~(max_chars : cap) : (served, fetch_error) result =
    match t.cache with
    | None ->
        Result.map
          (fun page -> { page; fallback = rung; cached = false })
          (fetcher.fetch ~url ~offset ~max_chars)
    | Some cache -> (
        match cache.Cache.preflight url with
        | Error exc -> Error exc
        | Ok validated ->
            let dispatch ~(offset : int) ~(max_chars : cap) =
              fetcher.fetch ~url:validated ~offset ~max_chars
            in
            let rung_name = match rung with None -> "http" | Some name -> name in
            Result.map
              (fun (page, cached) -> { page; fallback = rung; cached })
              (cache.Cache.read ~rung:rung_name ~url:validated ~offset ~max_chars ~dispatch))

  let try_fallbacks t (url : string) notices ~(original_reason : string) base
      ~(tried : Config.name list ref) ~(offset : int) ~(max_chars : cap) () : served option =
    (* The walk continues past an empty page: the paid-run-last rule. *)
    let why = ref original_reason in
    let rec go = function
      | [] -> None
      | fallback :: rest -> (
          tried := !tried @ [ fallback.name ];
          let started = t.ctx.clock () in
          match read_page t fallback ~rung:(Some fallback.name) ~url ~offset ~max_chars with
          | Error exc ->
              let facts = classify exc in
              fallback_failed base "fetch.fallback_failed" ~fallback:fallback.name
                ~reason:facts.message ~original_reason:!why ~ms:(elapsed t.ctx.clock started);
              why := facts.message;
              go rest
          | Ok rung ->
              fallback_served base "fetch.fallback" ~fallback:fallback.name ~reason:!why
                ~ms:(elapsed t.ctx.clock started);
              if not rung.cached then
                notices :=
                  !notices
                  @ [ Router.refetched_notice (table t) ~reason:!why ~fallback:fallback.name ];
              if is_empty t rung.page.text then begin
                why := "almost no readable text";
                match go rest with Some answer -> Some answer | None -> Some rung
              end
              else Some rung)
    in
    go (ladder t)

  let fetch_named t (named : fetcher) ~(url : string) ~(offset : int) ~(max_chars : cap) base
      ~(started : float) ?run ?step () : (served, error) result =
    (* One attempt: a caller using [provider] as a cost knob is not billed twice. *)
    match read_page t named ~rung:(Some named.name) ~url ~offset ~max_chars with
    | Error exc -> Error (raise_failure base t exc ~started ?run ?step ())
    | Ok rung -> Ok { rung with fallback = Some named.name }

  let fetch_page t ~(url : string) ~(offset : int) ~(max_chars : cap) notices base
      ~(started : float) ?named ~(auto_fallback : bool) ?run ?step () : (served, error) result =
    match named with
    | Some fallback -> fetch_named t fallback ~url ~offset ~max_chars base ~started ?run ?step ()
    | None -> (
        match primary t with
        | Error unbuilt -> Error unbuilt
        | Ok reader -> (
            let tried = ref [] in
            match read_page t reader ~rung:(primary_name t.ctx.config) ~url ~offset ~max_chars with
            | Error exc -> (
                if not auto_fallback then begin
                  let choice =
                    if (classify exc).blocked then "" else Router.choose_instead (table t)
                  in
                  Error (raise_failure base t exc ~started ~choice ?run ?step ())
                end
                else
                  match
                    try_fallbacks t url notices ~original_reason:(classify exc).message base ~tried
                      ~offset ~max_chars ()
                  with
                  | None ->
                      Error
                        (raise_failure base t exc ~started
                           ~also_failed:
                             (if !tried = [] then ""
                              else " Fallbacks also failed: " ^ String.concat ", " !tried ^ ".")
                           ?run ?step ())
                  | Some answer -> Ok answer)
            | Ok rung ->
                (* An image's empty text is the resource; three rows of a CSV are an answer. *)
                if
                  auto_fallback && rung.page.image = None && (not rung.page.path_addressable)
                  && offset = 0 && is_empty t rung.page.text
                then
                  match
                    try_fallbacks t url notices ~original_reason:"almost no readable text" base
                      ~tried ~offset ~max_chars ()
                  with
                  | Some escalated -> Ok escalated
                  | None -> Ok rung
                else Ok rung))

  let selections notices ~(path : string option) ~(budget : int) spans dropped :
      Model.fetch_match list option =
    if spans = [] then begin
      notices :=
        !notices
        @ [
            (match path with
            | Some _ ->
                (* "Nothing matched" must not be said of an over-budget document. *)
                if dropped > 0 then
                  "the part of this document that `path` addresses is larger than"
                  ^ " the selection budget (" ^ string_of_int budget
                  ^ " chars); ask for a narrower `path`, or a slice of an array, as"
                  ^ " in [0:5], or raise fetch.max_match_chars"
                else
                  "nothing in this document matches that `path`; fetch without"
                  ^ " `path` to read its structure, where every line names the path"
                  ^ " that addresses it"
            | None ->
                "none of the query terms appear on this page; fetch without" ^ " `query` to read it");
          ];
      Some []
    end
    else begin
      if dropped > 0 then
        notices :=
          !notices
          @ [
              (match path with
              | Some _ ->
                  "selection budget (" ^ string_of_int budget ^ " chars) reached; "
                  ^ string_of_int dropped ^ " more matching section(s) not returned; raise"
                  ^ " fetch.max_match_chars or ask for a narrower `path`, or a slice"
                  ^ " of an array, as in [0:5]"
              | None ->
                  "passage budget (" ^ string_of_int budget ^ " chars) reached; "
                  ^ string_of_int dropped ^ " more matching section(s) not returned; raise"
                  ^ " fetch.max_match_chars or fetch with `offset` near a match");
            ];
      Some (List.map (fun (offset, text) -> { Model.offset; text }) spans)
    end

  let select t (page : page) ?query ?path ~(empty_page : bool) notices :
      Model.fetch_match list option =
    let budget = t.ctx.config.Config.fetch.max_match_chars in
    if empty_page then None
    else if path <> None && not page.path_addressable then begin
      notices :=
        !notices
        @ [
            "`path` selects inside a JSON document or a CSV table, and this page"
            ^ " is not one this server could read; the whole page is returned";
          ];
      None
    end
    else
      match (path, query) with
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

  let build_response t ~(url : string) (page : page) ~(text : string option)
      ~(content_type : string option) ~(truncated : bool) ~(total_chars : int option)
      ~(offset : int option) ~(matches : Model.fetch_match list option)
      ~(image : Model.fetch_image option) ~(notice : string option) : Model.fetch_response =
    {
      Model.url = page.url;
      requested_url = url;
      title = page.title;
      text;
      content_type;
      status_code = Some page.status_code;
      retrieved_at = Some (Usage.iso_utc_seconds (t.ctx.now ()));
      truncated;
      total_chars;
      offset;
      matches;
      image;
      notice;
    }

  let response t ~(url : string) (page : page) ~(offset : int)
      ~(matches : Model.fetch_match list option) ~(image : Model.fetch_image option) notices :
      Model.fetch_response =
    build_response t ~url page
      ~text:(if matches <> None then None else Some page.text)
      ~content_type:page.content_type ~truncated:page.truncated ~total_chars:(Some page.total_chars)
      ~offset:(if offset = 0 then None else Some offset)
      ~matches ~image ~notice:(join_notices notices)

  let past_end t ~(url : string) (page : page) ~(offset : int) : Model.fetch_response =
    build_response t ~url page ~text:(Some "") ~content_type:page.content_type ~truncated:false
      ~total_chars:(Some page.total_chars) ~offset:(Some offset) ~matches:None ~image:None
      ~notice:
        (Some
           (Printf.sprintf "offset %d is past the end of the page (%d chars); nothing returned"
              offset page.total_chars))

  let base64 (body : string) : string =
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

  let image_notice image size carried =
    if carried then
      image.media_type ^ " image of " ^ string_of_int size
      ^ " bytes returned as image bytes: an image has no extracted text for"
      ^ " `query`, `path` or `offset` to address"
    else
      image.media_type ^ " image of " ^ string_of_int size
      ^ " bytes was fetched: `answer` builds its material from text, so its"
      ^ " bytes are not returned"

  let finish_image t ~(url : string) (page : page) (image : image) ~(fallback : Config.name option)
      base ~(started : float) (notices : string list) ~(run : string option) : Model.fetch_response
      =
    let size = String.length image.body in
    let carried =
      if run <> None then None else Some { Model.byte_count = size; base64 = base64 image.body }
    in
    finish_served_call base t page ~fallback ~started ~sanitized:0 ~image_bytes:size ();
    build_response t ~url page ~text:None ~content_type:(Some image.media_type) ~truncated:false
      ~total_chars:None ~offset:None ~matches:None ~image:carried
      ~notice:(join_notices (notices @ [ image_notice image size (carried <> None) ]))

  let log_content base t (page : page) ?(matches : Model.fetch_match list option) () =
    if not t.ctx.config.Config.logging.log_content then ()
    else
      let content =
        match matches with
        | None -> page.text
        | Some found ->
            String.concat "\n\n"
              (List.map (fun (item : Model.fetch_match) -> item.Model.text) found)
      in
      let fields =
        [
          ("title", `String (safe ~limit:200 page.title));
          ("text", `String (safe ~limit:t.ctx.config.Config.fetch.max_text_chars (Some content)));
        ]
      in
      emit (bind base fields) Config.Log_info "fetch.content" []

  let serve t ~(url : string) ~(offset : int) ?query ?path ~(structure : bool)
      ~(named : fetcher option) ~(auto_fallback : bool) ~(run : string option) ?step () :
      (Model.fetch_response, error) result =
    let notices : string list ref = ref [] in
    let max_chars = if query <> None || path <> None || structure then Uncapped else Default in
    let base = log_for t url in
    let started = t.ctx.clock () in
    match
      fetch_page t ~url ~offset ~max_chars notices base ~started ?named ~auto_fallback ?run ?step ()
    with
    | Error refused -> Error refused
    | Ok { page; fallback; cached } -> (
        match page.image with
        | Some image -> Ok (finish_image t ~url page image ~fallback base ~started !notices ~run)
        | None -> begin
            let page =
              if structure then (
                match (page.path_addressable, t.readers.render_schema page.text) with
                | true, Some rendered -> { page with text = rendered }
                | _ ->
                    notices :=
                      !notices
                      @ [
                          "`structure` reports a JSON or CSV table's shape, and this page"
                          ^ " is not one this server could read as either; the whole page"
                          ^ " is returned";
                        ];
                    page)
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
            if query = None && offset > 0 && offset >= page.total_chars then begin
              finish_served_call base t page ~fallback ~started ~sanitized ~cached ?run ?step ();
              Ok (past_end t ~url page ~offset)
            end
            else begin
              let empty_page =
                (not structure) && (not page.path_addressable) && offset = 0 && is_empty t page.text
              in
              if empty_page then begin
                emit
                  (bind base [ ("chars", `Int (Utf8.count (strip page.text))) ])
                  Config.Log_info "fetch.empty" [];
                notices := !notices @ [ Router.empty_notice (table t) ~walked:auto_fallback ]
              end;
              let matches = select t page ?query ?path ~empty_page notices in
              finish_served_call base t page ~fallback ~started ~sanitized ~cached ?run ?step ();
              log_content base t page ?matches ();
              Ok (response t ~url page ~offset ~matches !notices ~image:None)
            end
          end)

  let fetch t ?(offset = 0) ?query ?path ?(structure = false) ?provider ?auto_fallback ?run ?step
      (url : string) : (Model.fetch_response, error) result =
    let refusal =
      if query <> None && offset <> 0 then Some "pass `query` or `offset`, not both"
      else if path <> None && (query <> None || offset <> 0) then
        Some "pass `path`, `query` or `offset`, one at a time"
      else if structure && (query <> None || path <> None || offset <> 0) then
        Some
          ("pass `structure` alone; a shape read and a drill are each one read"
         ^ " -- take the shape, then pass `path`")
      else None
    in
    match refusal with
    | Some sentence -> Error (Refused sentence)
    | None -> (
        match resolve t provider with
        | Error sentence -> Error (Refused sentence)
        | Ok named -> (
            let auto_fallback =
              match auto_fallback with
              | None -> t.ctx.config.Config.fetch.auto_fallback
              | Some flag -> flag
            in
            match path with
            | Some selector -> (
                (* An unreadable selector should not cost a fetch. *)
                match t.readers.parse_path selector with
                | Error sentence -> Error (Refused ("`path` is not readable: " ^ sentence))
                | Ok () ->
                    serve t ~url ~offset ?query ?path ~structure ~named ~auto_fallback ~run ?step ()
                )
            | None ->
                serve t ~url ~offset ?query ?path ~structure ~named ~auto_fallback ~run ?step ()))
end
