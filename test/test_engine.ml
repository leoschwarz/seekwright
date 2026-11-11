(* The search engine: dispatch, the two ladders, the allow-list, the zero-results
   diagnostic, and what the operator and the dashboard get out of a call. Ported
   case for case from [tests/test_engine.py]'s search half — the fetch half is in
   [test_fetch_engine.ml].

   Two things about the shape of a port show up here and are worth naming once.
   A provider is a module, so the Python suite's [StubProvider] subclassing
   ([Empty], [Clipping], [Recording]) becomes a fixture whose [behavior] field a
   case replaces; the case that subclass stated is still the case that is
   asserted. And the log the engine emits is captured through the injected sink
   rather than loguru's [log_records] fixture, so ["search.ok"] is a lookup in a
   list of events and their fields — which pins the field set exactly, because an
   unexpected field is a list entry rather than an attribute on an object.

   The two cases that cannot cross as written are both noted where they sit:
   [a non-object JSON body reaches the caller as advice] drives a real adapter
   behind the engine, and [serper] has no adapter in this port yet — [freeserp]
   does, so the same path is pinned through it, the adapter's body-shape guard
   answering with a {!Seekwright.Provider.error} rather than an exception the
   engine does not catch. And [a reread response is not escaped again] reads the
   idempotence of the escape pass rather than Python's counts, because a
   [Model.result] is immutable where Python's fixture [Result] was shared. *)

module Caps = Mcp_caps
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Freeserp = Seekwright_providers.Freeserp
module Health = Seekwright.Health
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Router = Seekwright.Router
module Sanitize = Seekwright.Sanitize
module Usage = Seekwright.Usage
module A = Alcotest

let z = Sanitize.zwsp

(* The one instant every case shares, so [retrieved_at] is a fact to assert on
   and not a moving clock. [clock] is the monotonic one the health board and the
   [ms] fields read and [now] the wall one [retrieved_at] is stamped from: both
   static, so every [ms] is exactly [0] and a skipped fallback's [until_s] is
   exactly the cooldown it was set with. *)
let clock () = 1768478400.
let now () = 1768478400.

(* {1 Reads}

   [Usage.snapshot] is a [Yojson.Safe.t] and the log capture is a field list; the
   helpers below are the loose typing the Python suite gets from dicts. *)
let get key = function
  | `Assoc fields -> (try List.assoc key fields with Not_found -> `Null)
  | _ -> `Null

let items = function `List xs -> xs | _ -> []
let str = function `String s -> s | `Null -> "" | v -> Yojson.Safe.to_string v

let int = function
  | `Int n -> n
  | `Float f -> int_of_float f
  | v -> A.failf "not a count: %s" (Yojson.Safe.to_string v)

let bool = function `Bool b -> b | v -> A.failf "not a flag: %s" (Yojson.Safe.to_string v)
let is_null = (( = ) `Null)

let find_sub needle text =
  (* [String.index_opt] takes a char, not a substring; this is the haystack scan
     the Python suite gets from [needle in text]. *)
  let needle_length = String.length needle in
  let haystack_length = String.length text in
  let rec go index =
    if index + needle_length > haystack_length
    then None
    else if String.sub text index needle_length = needle
    then Some index
    else go (index + 1)
  in
  go 0

let is_prefix prefix text =
  (* [String.prefix] and [String.is_suffix] are not in this stdlib; the two
     helpers are the prefix test the walk-coverage case needs. *)
  let length = String.length prefix in
  String.length text >= length && String.sub text 0 length = prefix

let is_suffix affix text =
  let length = String.length affix in
  String.length text >= length
  && String.sub text (String.length text - length) length = affix

let includes label needle text =
  match find_sub needle text with
  | Some _ -> ()
  | None -> A.failf "%s: the text did not contain %S\n     it was: %S" label needle text

let excludes label needle text =
  match find_sub needle text with
  | None -> ()
  | Some _ -> A.failf "%s: the text contained %S, and must not\n     it was: %S" label needle text

let money label expected = function
  | `Int n -> A.(check (float 1e-9) label (float_of_int n) expected)
  | `Float f -> A.(check (float 1e-9) label f expected)
  | v -> A.failf "%s: not a money figure: %s" label (Yojson.Safe.to_string v)

(* {1 The wire fixtures}

   Python builds these with keyword defaults; an OCaml record has none, so the
   optional argument is the field a case cares about and the rest are [None]. *)
let result ?snippet ?text ?(url = "https://example.com/a") title =
  {
    Model.title;
    url;
    snippet;
    text;
    text_truncated = None;
    published_date = None;
    score = None;
  }

let query ?(max_results = 5) ?(include_domains = []) ?(exclude_domains = []) ?country ?language
    ?recency ?safe_search text =
  {
    Model.query = text;
    max_results;
    include_domains;
    exclude_domains;
    country;
    language;
    recency;
    safe_search;
  }

(* {1 The stub provider}

   {!Seekwright.Provider.t} is a packaged module, so the stub is a record of
   mutable state plus a [behavior] field the module's [search] delegates to. A
   case Python writes as a subclass replaces that field instead — see [clip],
   [no_hits] and [recording]. *)
type stub = {
  name : string;
  calls : int ref;
  seen : Model.search_query list ref;
  answer : string option ref;
  notice : string option ref;
  behavior : (Model.search_query -> (Provider.outcome, Provider.error) result) ref;
}

let stub ?(name = "serper") ?fail ?(results = `Default) ?(cost_usd = Some 0.001) ?answer ?notice
    () =
  let s =
    {
      name;
      calls = ref 0;
      seen = ref [];
      answer = ref answer;
      notice = ref notice;
      behavior = ref (fun _ -> Error (Provider.provider_error ~provider:name "not configured"));
    }
  in
  s.behavior
    := (fun q ->
         incr s.calls;
         s.seen := q :: !(s.seen);
         match fail with
         | Some failure -> Error failure
         | None ->
           let hits =
             match results with
             | `Default -> [ result ~snippet:"a snippet" ("Result for " ^ q.Model.query) ]
             | `List hits -> hits
           in
           Ok
             {
               Provider.provider = s.name;
               results = List.map (fun hit -> { Provider.result = hit; uncapped_chars = None }) hits;
               answer = !(s.answer);
               cost_usd;
               notice = !(s.notice);
             });

  s

(* A stub that appends its own name to [order] before it answers: what a walk's
   order is measured by. *)
let recording order s =
  let inner = !(s.behavior) in
  s.behavior := (fun q -> order := !order @ [ s.name ]; inner q);
  s

(* A stub that reports the pre-cap length of its first hit, which is how an
   adapter says what its own policy cap discarded. *)
let clip ?(rank = 0) chars s =
  let inner = !(s.behavior) in
  s.behavior
    := (fun q ->
         match inner q with
         | Ok outcome ->
           Ok
             {
               outcome with
               Provider.results =
                 List.mapi
                   (fun index hit ->
                     if index = rank then { hit with Provider.uncapped_chars = Some chars } else hit)
                   outcome.Provider.results;
             }
         | Error failure -> Error failure);
  s

(* The zero-results fixtures: the same stub answering with no hits, and with an
   answer beside them. *)
let no_hits ?answer ?notice s =
  let inner = !(s.behavior) in
  s.behavior
    := (fun q ->
         match inner q with
         | Ok outcome ->
           Ok
             {
               outcome with
               Provider.results = [];
               answer = (match answer with Some text -> Some text | None -> outcome.answer);
               notice = (match notice with Some text -> Some text | None -> outcome.notice);
             }
         | Error failure -> Error failure);
  s

let provider (s : stub) : Provider.t =
  (module struct
    let name = s.name
    let cost_per_1k = 1.0
    let cost_for n = float_of_int n /. 1000.
    let search q = !(s.behavior) q
    let aclose () = ()
  end : Provider.S)

let failure ?(retryable = true) ~name message = Provider.provider_error ~retryable ~provider:name message
let quota ~name = Provider.quota_exhausted ~provider:name ()

(* {1 The log capture} *)

type captured = {
  level : Config.log_level;
  event : string;
  fields : (string * Yojson.Safe.t) list;
}

let sink lines : Engine.log =
  fun level event fields -> lines := !lines @ [ { level; event; fields } ]

let events lines name =
  List.filter_map (fun (c : captured) -> if c.event = name then Some c.fields else None) !lines

let event lines name =
  match events lines name with
  | [ only ] -> only
  | many -> A.failf "expected exactly one %s, got %d" name (List.length many)

let last_event lines name =
  match events lines name with
  | [] -> A.failf "no %s was logged" name
  | many -> List.nth many (List.length many - 1)

let field fields name = get name (`Assoc fields)
let count lines name = List.length (events lines name)

let level_name = function
  | Config.Log_debug -> "DEBUG"
  | Config.Log_info -> "INFO"
  | Config.Log_warning -> "WARNING"
  | Config.Log_error -> "ERROR"
  | Config.Log_critical -> "CRITICAL"
  | Config.Log_trace -> "TRACE"
  | Config.Log_success -> "SUCCESS"

(* {1 The engine fixture}

   [make_engine]'s mirror: the config's provider block is built from the stubs
   handed in, [searxng] carrying its url because that is the one provider whose
   config {i is} its prerequisite. The health board and the usage recorder are
   always built here and handed back, because the engine has no accessors for
   them and a case needs to read the board a walk left behind. *)
let config ?default ?permitted ?fallback ?free_fallback ?(logging = Config.default_logging_config)
    names =
  let entry name =
    ( name
    , { Config.default_provider_config with
        Config.enabled = true
      ; url = if name = "searxng" then Some "http://searxng.test:8080" else None } )
  in
  match
    Config.resolve ~providers:(List.map entry names) ?default_provider:default
      ?permitted_providers:permitted
      ~search:{ Config.default_search_config with Config.fallback; free_fallback }
      ~logging ()
  with
  | Error message -> A.failf "the fixture config was refused: %s" message
  | Ok config -> config

type rig = { stub : stub; provider : Provider.t; name : string }

let rig_of s = { stub = s; provider = provider s; name = s.name }

let rig ?name ?fail ?results ?cost_usd ?answer ?notice ?order () =
  let s = stub ?name ?fail ?results ?cost_usd ?notice ?answer () in
  (match order with Some seen -> ignore (recording seen s) | None -> ());
  { stub = s; provider = provider s; name = s.name }

(* [Usage.create] can refuse — the two journal checks Python makes before a
   server is ready to serve — and an in-memory recorder cannot fail. *)
let recorder () =
  match Usage.create ~now:clock () with
  | Ok usage -> usage
  | Error message -> A.failf "an in-memory recorder cannot fail: %s" message

type board = {
  engine : Engine.Search.t;
  lines : captured list ref;
  stubs : stub list;
  health : Health.t;
  usage : Usage.t option;
  config : Config.t;
}

let make_engine ?default ?permitted ?fallback ?free_fallback
    ?(health = Health.create ~now ()) ?usage ?logging rigs =
  let lines = ref [] in
  let names = List.map (fun (r : rig) -> r.name) rigs in
  let config = config ?default ?permitted ?fallback ?free_fallback ?logging names in
  let engine =
    Engine.Search.create config ~health ?usage ~log:(sink lines)
      (List.map (fun (r : rig) -> (r.name, r.provider)) rigs)
      ~clock ~now ()
  in
  {
    engine;
    lines;
    stubs = List.map (fun (r : rig) -> r.stub) rigs;
    health;
    usage;
    config;
  }

let calls board name =
  List.fold_left
    (fun total (s : stub) -> if s.name = name then total + !(s.calls) else total)
    0 board.stubs

let snapshot board =
  match board.usage with
  | None -> A.failf "this fixture has no usage recorder"
  | Some usage -> Usage.snapshot usage

let recent json = items (get "recent" json)
let one_recent json = match recent json with [ entry ] -> entry | many -> A.failf "expected one usage entry, got %d" (List.length many)

(* Answers and refusals. The Python suite reads [str(exc.value)] on both sides of
   [pytest.raises]; here the refusal and the failure are returned values whose
   payload is that same sentence, and the two channels stay apart because the
   REST projection reports them as 400 and 502. *)
let served board ?provider ?mode ?run ?step q =
  match Engine.Search.search board.engine ?provider ?mode ?run ?step q with
  | Ok response -> response
  | Error (Engine.Search.Refused sentence) -> A.failf "the search was refused: %s" sentence
  | Error (Engine.Search.Failed sentence) -> A.failf "the search failed: %s" sentence

let refused board ?provider ?mode q =
  match Engine.Search.search board.engine ?provider ?mode q with
  | Error (Engine.Search.Refused sentence) -> sentence
  | Error (Engine.Search.Failed sentence) ->
    A.failf "expected a refusal (400), got a failure (502): %s" sentence
  | Ok response -> A.failf "expected a refusal, got results from %s" response.Model.provider

let failed board ?provider ?mode q =
  match Engine.Search.search board.engine ?provider ?mode q with
  | Error (Engine.Search.Failed sentence) -> sentence
  | Error (Engine.Search.Refused sentence) ->
    A.failf "expected a failure (502), got a refusal (400): %s" sentence
  | Ok response -> A.failf "expected a failure, got results from %s" response.Model.provider

let check_string = A.(check string)
let check_int = A.(check int)
let check_bool = A.(check bool)

(* {1 TestSearch} *)

let results_are_returned () =
  let board = make_engine [ rig () ] in
  let r = served board (query "sqlite wal mode") in
  check_string "provider" "serper" r.Model.provider;
  check_string "url" "https://example.com/a" (List.hd r.Model.results).Model.url;
  check_bool "retrieved_at is not None" true (r.Model.retrieved_at <> None)

let every_call_reaches_the_provider () =
  let board = make_engine [ rig () ] in
  let q = query "sqlite wal mode" in
  ignore (served board q);
  ignore (served board q);
  check_int "there is no cache; each call is billed" 2 (calls board "serper")

let a_provider_notice_reaches_the_caller () =
  (* An unhonoured filter must be reported, not silently dropped. *)
  let board =
    make_engine [ rig ~notice:"cannot filter by domain; that constraint was ignored" () ]
  in
  let r = served board (query ~include_domains:[ "arxiv.org" ] "x y z") in
  includes "notice" "cannot filter by domain" (Option.value ~default:"" r.Model.notice)

(* {1 TestProviderSelection} *)

let a_named_provider_is_used () =
  let board = make_engine [ rig ~name:"serper" (); rig ~name:"linkup" () ] in
  let r = served board ~provider:"linkup" (query "x y") in
  check_string "provider" "linkup" r.Model.provider;
  check_int "the other name was never dialed" 0 (calls board "serper")

let an_omitted_provider_uses_the_default () =
  let board = make_engine ~default:"linkup" [ rig ~name:"serper" (); rig ~name:"linkup" () ] in
  check_string "provider" "linkup" (served board (query "x y")).Model.provider

let no_default_and_several_enabled_asks_the_caller_to_choose () =
  (* Picking one would spend at a price the caller never agreed to. *)
  let board = make_engine [ rig ~name:"serper" (); rig ~name:"linkup" () ] in
  let text = refused board (query "x y") in
  includes "advice" "pass `provider`" text;
  (* The error is the only place the enabled set can be reported, since the tool
     schema is fixed at import time. *)
  includes "enabled" "linkup" text;
  includes "enabled" "serper" text

let an_unknown_provider_names_the_available_ones () =
  let board = make_engine [ rig () ] in
  let text = refused board ~provider:"linkup" (query "x y") in
  includes "reason" "not enabled" text;
  includes "available" "serper" text;
  includes "advice" "Retry with one of those" text

let the_default_is_only_offered_when_there_is_one () =
  (* Otherwise the suggested recovery produces the other error instead. *)
  let board = make_engine [ rig ~name:"serper" (); rig ~name:"exa" () ] in
  excludes "no default to omit" "omit `provider`" (refused board ~provider:"linkup" (query "x y"));
  let with_default = make_engine ~default:"serper" [ rig ~name:"serper" () ] in
  includes "a default to omit" "omit `provider`" (refused with_default ~provider:"linkup" (query "x y"))

(* {1 TestProviderFailure} *)

let a_failure_carries_retry_advice () =
  let board = make_engine [ rig ~fail:(failure ~name:"serper" "503") () ] in
  includes "advice" "Retry shortly" (failed board (query "sqlite wal mode"))

let quota_exhausted_says_do_not_retry () =
  let board = make_engine [ rig ~fail:(quota ~name:"serper") () ] in
  includes "advice" "Do not retry immediately" (failed board (query "sqlite wal mode"))

let a_non_object_json_body_reaches_the_caller_as_advice () =
  (* A real adapter behind the engine, not a stub. What this pins is the end of
     the path where the adapter's body-shape guard answers with a
     {!Seekwright.Provider.error} rather than an exception the engine does not
     catch, which would surface as an internal error instead of the sentence a
     model can act on. The Python suite drives [serper] through
     [httpx.MockTransport]; [freeserp] is the adapter this port has, so a fake
     {!Seekwright.Provider.Net.t} answers it with a JSON array. *)
  let net =
    {
      Provider.Net.request =
        (fun _request -> Ok { Caps.Authority.Net.status = 200; headers = []; body = "[]" });
    }
  in
  let adapter = Freeserp.make ~now ~net () in
  let board = make_engine ~default:"freeserp" [ { stub = stub ~name:"freeserp" (); provider = adapter; name = "freeserp" } ] in
  check_string "the whole sentence"
    "Search failed - freeserp: malformed JSON response. Retry shortly or try a different phrasing."
    (failed board (query "sqlite wal mode"))

(* {1 TestDefaultRouteFailover} *)

let a_failed_default_is_served_by_the_fallback () =
  let board =
    make_engine ~default:"serper" ~fallback:[ "linkup" ]
      [
        rig ~name:"serper" ~fail:(failure ~name:"serper" "upstream 503") ();
        rig ~name:"linkup" ();
      ]
  in
  let r = served board (query "x y") in
  check_string "provider" "linkup" r.Model.provider;
  check_string "notice" "serper failed (upstream 503); served by linkup instead"
    (Option.value ~default:"" r.Model.notice);
  check_int "the default was tried" 1 (calls board "serper");
  check_int "the fallback served" 1 (calls board "linkup");
  let fallback = event board.lines "search.fallback" in
  check_string "fallback" "linkup" (str (field fallback "fallback"));
  check_string "reason" "upstream 503" (str (field fallback "reason"));
  check_bool "fell_back" true (bool (field (last_event board.lines "search.ok") "fell_back"))

let the_substitute_notice_joins_the_adapter_notice () =
  let failing = rig ~name:"serper" ~fail:(failure ~name:"serper" "upstream 503") () in
  let linkup = rig ~name:"linkup" () in
  linkup.stub.notice := Some "cannot filter by domain; that constraint was ignored";
  let board = make_engine ~default:"serper" ~fallback:[ "linkup" ] [ failing; linkup ] in
  check_string "notice"
    "serper failed (upstream 503); served by linkup instead; cannot filter by domain; that constraint was ignored"
    (Option.value ~default:"" (served board (query "x y")).Model.notice)

let a_named_provider_failure_stays_terminal () =
  let board =
    make_engine ~default:"serper" ~fallback:[ "linkup" ]
      [
        rig ~name:"serper" ~fail:(failure ~name:"serper" "upstream 503") ();
        rig ~name:"linkup" ();
      ]
  in
  includes "advice" "Retry shortly" (failed board ~provider:"serper" (query "x y"));
  check_int "the ladder behind the default is not walked" 0 (calls board "linkup");
  check_int "one failure line" 1 (count board.lines "search.failed");
  check_int "no walk at all" 0
    (List.length (List.filter (fun (c : captured) -> is_prefix "search.fallback" c.event) !(board.lines)))

let an_open_circuit_fallback_is_skipped () =
  let health = Health.create ~now ~failure_threshold:1 ~cooldown_seconds:60.0 () in
  Health.record_failure health ~reason:"probe unreachable" "linkup" ();
  let board =
    make_engine ~default:"serper" ~fallback:[ "linkup" ] ~health
      [
        rig ~name:"serper" ~fail:(failure ~name:"serper" "upstream 503") ();
        rig ~name:"linkup" ();
      ]
  in
  let text = failed board (query "x y") in
  check_int "the gated fallback was never dialed" 0 (calls board "linkup");
  let skip = event board.lines "search.fallback_skipped" in
  check_string "fallback" "linkup" (str (field skip "fallback"));
  check_bool "until_s is a positive cooldown" true (float_of_int (int (field skip "until_s")) > 0.0);
  (* No fallback attempted, so the message is exactly today's terminal one. *)
  check_string "the whole sentence"
    "Search failed - serper: upstream 503. Retry shortly or try a different phrasing." text

let when_every_fallback_fails_the_original_error_leads () =
  let board =
    make_engine ~default:"serper" ~fallback:[ "linkup"; "tavily" ]
      [
        rig ~name:"serper" ~fail:(failure ~name:"serper" "upstream 503") ();
        rig ~name:"linkup" ~fail:(failure ~name:"linkup" "HTTP 502") ();
        rig ~name:"tavily" ~fail:(failure ~name:"tavily" "HTTP 500") ();
      ]
  in
  let text = failed board (query "x y") in
  includes "the original reason leads" "upstream 503" text;
  includes "and the walk is named" " Fallbacks also failed: linkup, tavily." text;
  check_string "each rung's own reason and the reason it was tried"
    "linkup|HTTP 502|upstream 503;tavily|HTTP 500|upstream 503"
    (events board.lines "search.fallback_failed"
    |> List.map (fun fields ->
           String.concat "|"
             [
               str (field fields "fallback")
             ; str (field fields "reason")
             ; str (field fields "original_reason")
             ])
    |> String.concat ";");
  check_int "one failure line for the call" 1 (count board.lines "search.failed")

let each_fallback_runs_once_and_the_default_is_not_retried () =
  let board =
    make_engine ~default:"serper" ~fallback:[ "serper"; "linkup" ]
      [
        rig ~name:"serper" ~fail:(failure ~name:"serper" "upstream 503") ();
        rig ~name:"linkup" ();
      ]
  in
  let r = served board (query "x y") in
  check_int "the tried default is skipped, not retried" 1 (calls board "serper");
  check_string "provider" "linkup" r.Model.provider;
  check_int "the fallback served" 1 (calls board "linkup")

let a_direct_success_says_so_and_named_failures_still_feed_the_board () =
  let board = make_engine [ rig () ] in
  ignore (served board (query "q"));
  check_bool "fell_back" false (bool (field (last_event board.lines "search.ok") "fell_back"));
  (* No ladder configured: a named failure stays terminal, but the board still
     counts it — that is what a later search's ladder will read. *)
  let failing = make_engine [ rig ~name:"serper" ~fail:(failure ~name:"serper" "503") () ] in
  List.iter (fun _ -> ignore (failed failing ~provider:"serper" (query "q"))) [ 1; 2; 3 ];
  check_bool "three failures benched the name" true (Health.is_open failing.health "serper")

let quota_exhausted_reroutes_and_all_quota_keeps_its_advice () =
  let board =
    make_engine ~default:"serper" ~fallback:[ "linkup" ]
      [ rig ~name:"serper" ~fail:(quota ~name:"serper") (); rig ~name:"linkup" () ]
  in
  check_string "quota is a failure like any other here" "linkup"
    (served board (query "x y")).Model.provider;
  let both_quota =
    make_engine ~default:"serper" ~fallback:[ "linkup" ]
      [
        rig ~name:"serper" ~fail:(quota ~name:"serper") ();
        rig ~name:"linkup" ~fail:(quota ~name:"linkup") ();
      ]
  in
  let text = failed both_quota (query "x y") in
  includes "the walk is named" " Fallbacks also failed: linkup." text;
  check_bool "quota advice ends the sentence" true (is_suffix "Do not retry immediately." text)

(* {1 TestFreeMode} *)

(* The free names, in the order the Python suite hands them to the engine —
   never the walk's own order, which is what these cases are measuring. *)
let free_rigs ?(fail = []) ?order names =
  List.map
    (fun name ->
      rig ~name
        ?fail:(if List.mem name fail then Some (failure ~name "rate limited") else None)
        ?order ())
    names

let the_free_walk_is_the_constant_order_keyless_first () =
  let order = ref [] in
  let board =
    make_engine (free_rigs ~fail:[ "tinyfish"; "searxng"; "parallel:free"; "exa:free" ] ~order
        [ "tinyfish"; "searxng"; "parallel:free"; "exa:free" ])
  in
  ignore (failed board ~mode:Router.Free (query "x y"));
  check_string "the declaration order, not the order they were handed to the engine"
    "exa:free,parallel:free,searxng,tinyfish" (String.concat "," !order);
  check_int "each fallback at most once" (List.length !order)
    (List.length (List.sort_uniq String.compare !order))

let the_configured_free_ladder_decides_the_order_and_narrows_the_walk () =
  let order = ref [] in
  let exa_free = rig ~name:"exa:free" ~order () in
  let board =
    make_engine ~free_fallback:[ "tinyfish"; "searxng" ]
      [
        exa_free;
        rig ~name:"tinyfish" ~fail:(failure ~name:"tinyfish" "rate limited") ~order ();
        rig ~name:"searxng" ~order ();
      ]
  in
  let r = served board ~mode:Router.Free (query "x y") in
  check_string "the operator's order, only" "tinyfish,searxng" (String.concat "," !order);
  check_int "a ladder that does not name a fallback drops it" 0 !(exa_free.stub.calls);
  check_string "provider" "searxng" r.Model.provider;
  check_string "notice" "tinyfish failed (rate limited); served by searxng instead"
    (Option.value ~default:"" r.Model.notice)

let the_free_walk_does_not_consult_the_default () =
  (* The caller asked for a class, not for the deployment's default. *)
  let board = make_engine ~default:"serper" [ rig ~name:"serper" (); rig ~name:"exa:free" () ] in
  check_string "provider" "exa:free" (served board ~mode:Router.Free (query "x y")).Model.provider;
  check_int "the paid name was never dialed" 0 (calls board "serper")

let a_paid_provider_is_never_reached () =
  (* Criterion 1: the paid counter stays at zero however the walk ends — here
     with every free fallback failing and a paid ladder configured beside the
     mode, which the free walk must not read. *)
  let board =
    make_engine ~default:"serper" ~fallback:[ "serper" ]
      [
        rig ~name:"serper" ();
        rig ~name:"exa:free" ~fail:(failure ~name:"exa:free" "rate limited") ();
        rig ~name:"tinyfish" ~fail:(failure ~name:"tinyfish" "bot-walled") ();
      ]
  in
  let text = failed board ~mode:Router.Free (query "x y") in
  check_int "the paid name was never dialed" 0 (calls board "serper");
  includes "the original leads" "Search failed - exa:free: rate limited." text;
  includes "the walk is named" " Fallbacks also failed: tinyfish." text;
  includes "the reason nothing paid answered" "no paid provider was tried" text

let one_free_fallback_alone_still_says_why_nothing_paid_was_tried () =
  (* No fallback left to append, and the sentence still has to be there: the
     model cannot see the walk, so the message is the only place it can be told
     the mode is why no paid provider answered. *)
  let board =
    make_engine ~default:"serper"
      [
        rig ~name:"exa:free" ~fail:(failure ~name:"exa:free" "rate limited") ();
        rig ~name:"serper" ();
      ]
  in
  let text = failed board ~mode:Router.Free (query "x y") in
  includes "the reason is stated" "no paid provider was tried" text;
  excludes "nothing to append" "Fallbacks also failed" text

let an_open_circuit_free_fallback_is_skipped () =
  let health = Health.create ~now ~failure_threshold:1 ~cooldown_seconds:60.0 () in
  Health.record_failure health ~reason:"probe unreachable" "tinyfish" ();
  let board =
    make_engine ~health
      [
        rig ~name:"exa:free" ~fail:(failure ~name:"exa:free" "rate limited") ();
        rig ~name:"tinyfish" ();
      ]
  in
  let text = failed board ~mode:Router.Free (query "x y") in
  check_int "the gated fallback was never dialed" 0 (calls board "tinyfish");
  let skip = event board.lines "search.fallback_skipped" in
  check_string "fallback" "tinyfish" (str (field skip "fallback"));
  check_bool "until_s is a positive cooldown" true (float_of_int (int (field skip "until_s")) > 0.0);
  includes "the mode still explains itself" "no paid provider was tried" text

let a_failed_free_fallback_gates_on_the_health_board () =
  (* A rate-limited fallback is an ordinary failure: recorded on the board, so
     the breaker gates it for the cooldown like any other. *)
  let health = Health.create ~now ~failure_threshold:1 ~cooldown_seconds:60.0 () in
  let board =
    make_engine ~health
      [
        rig ~name:"exa:free" ~fail:(failure ~name:"exa:free" "rate limited") ();
        rig ~name:"tinyfish" ();
      ]
  in
  check_string "provider" "tinyfish" (served board ~mode:Router.Free (query "x y")).Model.provider;
  check_bool "the failed fallback is benched" true (Health.is_open health "exa:free");
  check_bool "the name that served is not" false (Health.is_open health "tinyfish")

let no_free_provider_enabled_is_a_clean_refusal () =
  (* The shape [fetch.enabled = false] uses: a refusal naming the set, not a tool
     that disappears — the schema is frozen at import, so the deployment's real
     set can only be reported here. *)
  let board = make_engine ~default:"serper" [ rig ~name:"serper" () ] in
  let text = refused board ~mode:Router.Free (query "x y") in
  includes "the reason" "No free provider is enabled" text;
  List.iter (fun name -> includes "the free set is named" name text) (List.sort String.compare Config.free_providers)

let naming_a_provider_and_a_mode_is_refused () =
  (* Two ways to name a route is an ambiguity with a precedence rule hiding in
     it, so neither wins. *)
  let board = make_engine ~default:"serper" [ rig ~name:"serper" (); rig ~name:"exa:free" () ] in
  (match Engine.Search.search board.engine ~provider:"serper" ~mode:Router.Free (query "x y") with
  | Error (Engine.Search.Refused sentence) ->
    includes "the rule" "pass `provider` or `mode`, not both" sentence
  | Error (Engine.Search.Failed sentence) -> A.failf "expected a refusal, got a failure: %s" sentence
  | Ok response -> A.failf "expected a refusal, got results from %s" response.Model.provider);
  check_int "nothing was dispatched" 0 (calls board "serper" + calls board "exa:free")

let mode_is_bound_on_search_ok_either_way () =
  (* Always bound — [null] when the caller did not ask — so the line keeps a
     fixed field set whatever the route. *)
  let board = make_engine ~default:"serper" [ rig ~name:"exa:free" (); rig ~name:"serper" () ] in
  ignore (served board ~mode:Router.Free (query "q"));
  check_string "mode" "free" (str (field (last_event board.lines "search.ok") "mode"));
  ignore (served board (query "q"));
  check_bool "mode is null when unasked" true (is_null (field (last_event board.lines "search.ok") "mode"))

let a_free_served_search_records_the_fallback_once () =
  (* One terminal record naming the fallback that served it, like the default
     route's ladder — the failed first fallback is not a terminal outcome. *)
  let usage = recorder () in
  let board =
    make_engine ~usage
      [
        rig ~name:"exa:free" ~fail:(failure ~name:"exa:free" "rate limited") ();
        rig ~name:"tinyfish" ();
      ]
  in
  ignore (served board ~mode:Router.Free (query "q"));
  let entry = one_recent (snapshot board) in
  check_string "provider" "tinyfish" (str (get "provider" entry));
  check_bool "fell_back" true (bool (get "fell_back" entry))

(* {1 TestTheFreeOnlyDefaultRoute} *)

let an_unnamed_search_is_served_by_the_free_walk () =
  let order = ref [] in
  let board =
    make_engine
      [
        rig ~name:"exa:free" ~fail:(failure ~name:"exa:free" "rate limited") ~order ();
        rig ~name:"parallel:free" ~order ();
      ]
  in
  let r = served board (query "x y") in
  check_string "walk order" "exa:free,parallel:free" (String.concat "," !order);
  check_string "provider" "parallel:free" r.Model.provider;
  check_string "notice" "exa:free failed (rate limited); served by parallel:free instead"
    (Option.value ~default:"" r.Model.notice)

let the_implicit_keyless_set_is_walked_whole () =
  (* A config that enables nothing resolves to the keyless {i set}, and an
     unnamed search walks every name in it. The third fallback is the point: the
     install default is the keyless set, not the keyless pair, so a bare [search]
     on an unconfigured install reaches [freeserp] too. *)
  let cfg = config [] in
  check_bool "the set was implicit" true cfg.Config.providers_defaulted;
  check_string "the enabled set" "exa:free,freeserp,parallel:free"
    (String.concat "," (Config.enabled_providers cfg));
  check_bool "three enabled names: callers choose" true (cfg.Config.default_provider = None);
  let order = ref [] in
  let rigs =
    List.map
      (fun name ->
        rig ~name
          ?fail:(if name <> "freeserp" then Some (failure ~name "rate limited") else None)
          ~order ())
      [ "exa:free"; "parallel:free"; "freeserp" ]
  in
  let lines = ref [] in
  let engine =
    Engine.Search.create cfg ~log:(sink lines)
      (List.map (fun (r : rig) -> (r.name, r.provider)) rigs)
      ~clock ~now ()
  in
  let r =
    match Engine.Search.search engine (query "x y") with
    | Ok response -> response
    | Error (Engine.Search.Failed sentence) -> A.failf "the walk failed: %s" sentence
    | Error (Engine.Search.Refused sentence) -> A.failf "the walk was refused: %s" sentence
  in
  check_string "the walk order" "exa:free,parallel:free,freeserp" (String.concat "," !order);
  check_string "the third fallback is reachable and serves" "freeserp" r.Model.provider

let the_free_order_and_only_free_names () =
  (* The at-most-once rule and the order are the mode's own, and no fallback
     outside the free set can be reached on this route either. *)
  let order = ref [] in
  let board =
    make_engine
      (free_rigs ~fail:[ "tinyfish"; "searxng"; "parallel:free"; "exa:free" ] ~order
         [ "tinyfish"; "searxng"; "parallel:free"; "exa:free" ])
  in
  ignore (failed board (query "x y"));
  check_string "walk order" "exa:free,parallel:free,searxng,tinyfish" (String.concat "," !order);
  check_int "each fallback at most once" (List.length !order)
    (List.length (List.sort_uniq String.compare !order));
  List.iter
    (fun name ->
      check_bool "only free names are reachable" true (List.mem name Config.free_providers))
    !order

let the_configured_free_ladder_orders_the_implicit_walk () =
  (* [search.free_fallback] is the order on this route too — the same walk, so
     the operator's ladder cannot mean one thing in [mode="free"] and another
     here. *)
  let order = ref [] in
  let exa_free = rig ~name:"exa:free" ~order () in
  let board =
    make_engine ~free_fallback:[ "tinyfish"; "searxng" ]
      [
        exa_free;
        rig ~name:"tinyfish" ~fail:(failure ~name:"tinyfish" "rate limited") ~order ();
        rig ~name:"searxng" ~order ();
      ]
  in
  let r = served board (query "x y") in
  check_string "walk order" "tinyfish,searxng" (String.concat "," !order);
  check_int "the unlisted name is dropped" 0 !(exa_free.stub.calls);
  check_string "provider" "searxng" r.Model.provider

let the_implicit_walks_ending_is_the_walks_own () =
  (* The first fallback's error leads, with the failed fallbacks appended. *)
  let board =
    make_engine
      [
        rig ~name:"exa:free" ~fail:(failure ~name:"exa:free" "rate limited") ();
        rig ~name:"parallel:free" ~fail:(failure ~name:"parallel:free" "HTTP 503") ();
      ]
  in
  let text = failed board (query "x y") in
  includes "the original leads" "Search failed - exa:free: rate limited." text;
  includes "the walk is named" " Fallbacks also failed: parallel:free." text

let an_open_circuit_is_skipped_on_the_implicit_walk () =
  let health = Health.create ~now ~failure_threshold:1 ~cooldown_seconds:60.0 () in
  Health.record_failure health ~reason:"probe unreachable" "parallel:free" ();
  let board =
    make_engine ~health
      [
        rig ~name:"exa:free" ~fail:(failure ~name:"exa:free" "rate limited") ();
        rig ~name:"parallel:free" ();
      ]
  in
  ignore (failed board (query "x y"));
  check_int "the gated fallback was never dialed" 0 (calls board "parallel:free");
  check_string "the skipped names" "parallel:free"
    (String.concat ","
       (List.map (fun fields -> str (field fields "fallback")) (events board.lines "search.fallback_skipped")))

let one_billable_name_brings_the_refusal_back () =
  (* The moment the deployment can spend, an unnamed search is the old error
     again — verbatim, listing what is available. *)
  let board = make_engine [ rig ~name:"exa:free" (); rig ~name:"serper" () ] in
  let text = refused board (query "x y") in
  includes "the reason" "No default provider is configured" text;
  includes "available" "exa:free" text;
  includes "available" "serper" text;
  check_int "nothing was dispatched" 0 (calls board "exa:free" + calls board "serper")

let a_free_tier_is_not_a_free_name () =
  (* [tinyfish] cannot bill and is in; [tavily] has a free tier and can, so one
     of it beside a keyless name is enough to restore the refusal. *)
  let board = make_engine [ rig ~name:"exa:free" (); rig ~name:"tavily" () ] in
  includes "the refusal is back" "No default provider is configured" (refused board (query "x y"))

let a_named_provider_is_unaffected_by_the_free_only_route () =
  let board = make_engine [ rig ~name:"exa:free" (); rig ~name:"parallel:free" () ] in
  let r = served board ~provider:"parallel:free" (query "x y") in
  check_string "provider" "parallel:free" r.Model.provider;
  check_int "the other name was never dialed" 0 (calls board "exa:free")

let a_single_free_provider_is_still_the_default () =
  (* The provider block gives a lone enabled name the default; that rule is
     untouched, so the walk is not the route here. *)
  let board = make_engine [ rig ~name:"exa:free" () ] in
  check_string "the lone name is the default" "exa:free"
    (Option.value ~default:"<unset>" board.config.Config.default_provider);
  let r = served board (query "x y") in
  check_string "provider" "exa:free" r.Model.provider;
  check_bool "no substitution to report" true (r.Model.notice = None)

let mode_stays_none_on_the_unnamed_walk () =
  (* The caller declared no mode, so the line says so — and [notice] is where
     the substitution is reported, in the existing wording. *)
  let board = make_engine [ rig ~name:"exa:free" (); rig ~name:"parallel:free" () ] in
  ignore (served board (query "q"));
  let ok = last_event board.lines "search.ok" in
  check_bool "mode is null" true (is_null (field ok "mode"));
  check_bool "fell_back" false (bool (field ok "fell_back"))

(* {1 TestTheAllowList} *)

let a_name_enabled_but_not_permitted_never_reaches_the_adapter () =
  let board = make_engine ~permitted:[ "linkup" ] [ rig ~name:"serper" (); rig ~name:"linkup" () ] in
  let message = refused board ~provider:"serper" (query "q") in
  check_int "the refusal is before dispatch, so nothing billed" 0 (calls board "serper");
  includes "the refused name is named" "'serper'" message;
  includes "and so is the list" "Permitted: linkup" message;
  excludes "the other refusal must not be reused" "not enabled" message;
  check_int "a refused call dispatches nothing to journal" 0 (count board.lines "search.ok");
  check_string "the operator's line is a warning" "WARNING"
    (level_name (List.hd (List.filter (fun (c : captured) -> c.event = "search.rejected") !(board.lines))).level)

let an_unset_permission_set_is_permissive () =
  (* No key means every enabled provider is permitted: the same call that is
     refused above dispatches, which is what keeps every existing config behaving
     as it does today. *)
  let board = make_engine [ rig ~name:"serper" (); rig ~name:"linkup" () ] in
  let r = served board ~provider:"serper" (query "q") in
  check_string "provider" "serper" r.Model.provider;
  check_int "one dispatch" 1 (calls board "serper")

let the_permission_intersection_holds_both_ways () =
  (* The two refusals are asserted apart, not merely asserted: permitted is not
     enabled, and enabled is not permitted. *)
  let board = make_engine ~permitted:[ "linkup" ] [ rig ~name:"serper" (); rig ~name:"linkup" () ] in
  (* Permitted but not enabled: the honest reason is "not enabled", and [linkup]
     is here precisely so the wording cannot be the other one. *)
  let enabled = refused board ~provider:"tavily" (query "q") in
  includes "the enabled sentence" "is not enabled on this server" enabled;
  excludes "not the permission sentence" "not permitted" enabled;
  (* Enabled but not permitted: the other sentence, and never the first. *)
  let permitted = refused board ~provider:"serper" (query "q") in
  includes "the permission sentence" "is not permitted on this server" permitted;
  excludes "not the enabled sentence" "is not enabled" permitted

let the_default_route_skips_an_unpermitted_fallback () =
  (* [search.fallback] keeps its own semantics minus the names the list removes:
     the fallback is skipped with a line saying so, and never called. *)
  let board =
    make_engine ~default:"linkup" ~fallback:[ "linkup"; "serper" ] ~permitted:[ "linkup" ]
      [
        rig ~name:"serper" ();
        rig ~name:"linkup" ~fail:(failure ~name:"linkup" "503") ();
      ]
  in
  ignore (failed board (query "q"));
  check_int "the default is still attempted first" 1 (calls board "linkup");
  check_int "the fallback the allow-list removes never fires" 0 (calls board "serper");
  let skip = event board.lines "search.fallback_unpermitted" in
  check_string "fallback" "serper" (str (field skip "fallback"));
  check_string "permitted" "linkup" (str (field skip "permitted"));
  (* Warning rather than info: a fallback the ladder names but the allow-list
     removes is dead config the operator should fix. *)
  check_string "level" "WARNING"
    (level_name (List.hd (List.filter (fun (c : captured) -> c.event = "search.fallback_unpermitted") !(board.lines))).level)

let an_unpermitted_default_is_refused_not_rerouted () =
  (* Never a silent reroute: the ladder behind the default is not walked, because
     the refusal is raised before the ladder exists to be walked. *)
  let board =
    make_engine ~default:"serper" ~fallback:[ "linkup" ] ~permitted:[ "linkup" ]
      [
        rig ~name:"serper" ~fail:(failure ~name:"serper" "503") ();
        rig ~name:"linkup" ();
      ]
  in
  let message = refused board (query "q") in
  includes "the reason" "The default provider 'serper' is not permitted" message;
  includes "the recovery" "Pass `provider` with one of those." message;
  check_int "nothing was dispatched" 0 (calls board "serper" + calls board "linkup")

let a_free_walk_never_reaches_an_unpermitted_fallback () =
  let order = ref [] in
  let board =
    make_engine ~free_fallback:[ "exa:free"; "parallel:free" ] ~permitted:[ "parallel:free" ]
      [
        rig ~name:"exa:free" ~order ();
        rig ~name:"parallel:free" ~order ();
      ]
  in
  let r = served board ~mode:Router.Free (query "q") in
  check_string "provider" "parallel:free" r.Model.provider;
  check_string "the walk" "parallel:free" (String.concat "," !order);
  check_int "the removed name never fired" 0 (calls board "exa:free")

let a_free_walk_emptied_by_the_list_says_permitted () =
  (* The two reasons a free walk is empty must not read alike: the operator has
     to know which key to fix. *)
  let board = make_engine ~permitted:[ "serper" ] [ rig ~name:"exa:free" () ] in
  let message = refused board ~mode:Router.Free (query "q") in
  includes "the reason" "No permitted free provider is enabled" message;
  includes "the list" "Permitted: serper" message;
  includes "the free set" "The free providers are: " message;
  excludes "not the other refusal" "No free provider is enabled" message

let a_rejection_binds_the_permitted_set () =
  (* The operator's line tells the two refusals apart; [enabled] stays. *)
  let board = make_engine ~permitted:[ "linkup" ] [ rig ~name:"serper" (); rig ~name:"linkup" () ] in
  ignore (refused board ~provider:"serper" (query "q"));
  let fields = event board.lines "search.rejected" in
  check_string "permitted" "linkup" (str (field fields "permitted"));
  includes "enabled" "serper" (str (field fields "enabled"))

let the_rejection_bind_is_none_when_unset () =
  let board = make_engine [ rig ~name:"serper" () ] in
  ignore (refused board ~provider:"linkup" (query "q"));
  check_bool "permitted is null" true (is_null (field (event board.lines "search.rejected") "permitted"))

(* {1 TestZeroResults} *)

let empty_results_are_not_an_error () =
  let r = served (make_engine [ rig ~results:(`List []) () ]) (query "asdkjhasdkjh") in
  check_int "no hits, and no error" 0 (List.length r.Model.results)

let a_zero_results_notice_names_the_other_providers () =
  let r =
    served
      (make_engine [ rig ~name:"serper" ~results:(`List []) (); rig ~name:"linkup" () ])
      ~provider:"serper" (query "asdkjhasdkjh")
  in
  let notice = Option.value ~default:"" r.Model.notice in
  includes "the fact" "No results from serper." notice;
  includes "the alternatives" "Other enabled providers: linkup." notice;
  includes "the advice" "rephrase" notice

let a_solo_provider_zero_results_says_it_is_alone () =
  let r = served (make_engine [ rig ~results:(`List []) () ]) (query "asdkjhasdkjh") in
  includes "the fact" "serper is the only enabled provider." (Option.value ~default:"" r.Model.notice)

let an_answered_zero_result_gets_no_notice () =
  (* An answer with no hits is content; a nag would be noise on it. *)
  let s = no_hits ~answer:"None." (stub ()) in
  let r = served (make_engine [ rig_of s ]) (query "asdkjhasdkjh") in
  check_bool "no notice" true (r.Model.notice = None)

let an_adapter_notice_is_joined_with_the_zero_notice () =
  let empty_serper = no_hits (stub ~name:"serper" ~notice:"cannot filter by domain; that constraint was ignored" ()) in
  let r =
    served
      (make_engine [ rig_of empty_serper; rig ~name:"linkup" () ])
      ~provider:"serper" (query "asdkjhasdkjh")
  in
  let notice = Option.value ~default:"" r.Model.notice in
  includes "the adapter first" "cannot filter by domain" notice;
  includes "then the diagnostic" "; No results from serper." notice

let a_fallback_serving_zero_results_names_the_fallback () =
  (* The diagnostic reads the serving provider, which after a walk is the
     fallback — Python passes [result.provider], not the first attempt — so the
     sentence names linkup and the "other providers" list names serper. *)
  let board =
    make_engine ~default:"serper" ~fallback:[ "linkup" ]
      [
        rig ~name:"serper" ~fail:(failure ~name:"serper" "upstream 503") ();
        rig ~name:"linkup" ~results:(`List []) ();
      ]
  in
  let r = served board (query "asdkjhasdkjh") in
  check_string "the fallback served" "linkup" r.Model.provider;
  let notice = Option.value ~default:"" r.Model.notice in
  includes "the walk is named first" "serper failed (upstream 503); served by linkup instead" notice;
  includes "the diagnostic names the fallback" "; No results from linkup." notice;
  includes "the alternatives name the default" "Other enabled providers: serper." notice

(* {1 TestObservability} *)

let a_search_records_cost_and_latency () =
  let board = make_engine [ rig () ] in
  ignore (served board (query "sqlite wal mode"));
  let fields = event board.lines "search.ok" in
  check_string "provider" "serper" (str (field fields "provider"));
  money "cost_usd" 0.001 (field fields "cost_usd");
  check_int "results" 1 (int (field fields "results"));
  check_bool "ms is a non-negative integer" true (int (field fields "ms") >= 0)

let reported_usage_is_absent_until_an_adapter_measures_it () =
  (* Python's [_reported_cost_usd] hangs an actual-usage figure on a private
     field of the provider boundary's result. An OCaml record has no private
     field, and no adapter in this port has that measurement to make, so the
     suite pins the absence rather than inventing a value for the channel. *)
  let board = make_engine [ rig () ] in
  ignore (served board (query "sqlite wal mode"));
  let fields = event board.lines "search.ok" in
  money "the estimate still rides the line" 0.001 (field fields "cost_usd");
  excludes "the actual-usage channel is not invented" "reported_cost_usd"
    (String.concat "," (List.map fst fields))

let query_text_is_withheld_by_default () =
  let board = make_engine [ rig () ] in
  ignore (served board (query "sqlite wal mode"));
  let fields = event board.lines "search.ok" in
  excludes "no query text field" "query" (String.concat "," (List.map fst fields));
  check_int "qlen" 15 (int (field fields "qlen"));
  check_bool "qhash is there" true (str (field fields "qhash") <> "")

let query_text_is_recorded_when_opted_in () =
  let board =
    make_engine ~logging:{ Config.default_logging_config with Config.log_queries = true } [ rig () ]
  in
  ignore (served board (query "sqlite wal mode"));
  check_string "query" "sqlite wal mode" (str (field (event board.lines "search.ok") "query"))

let result_content_is_withheld_by_default () =
  let board = make_engine [ rig () ] in
  ignore (served board (query "sqlite wal mode"));
  check_int "no content event" 0 (count board.lines "search.result");
  (* And [search.ok] keeps its shape: content never rides the line an operator
     aggregates on, whatever the setting says. *)
  let fields = String.concat "," (List.map fst (event board.lines "search.ok")) in
  excludes "no title on the aggregate" "title" fields;
  excludes "no snippet on the aggregate" "snippet" fields

let result_content_is_recorded_when_opted_in () =
  let board =
    make_engine ~logging:{ Config.default_logging_config with Config.log_content = true } [ rig () ]
  in
  ignore (served board (query "sqlite wal mode"));
  let fields = event board.lines "search.result" in
  check_int "rank" 1 (int (field fields "rank"));
  check_string "title" "'Result for sqlite wal mode'" (str (field fields "title"));
  check_string "snippet" "'a snippet'" (str (field fields "snippet"));
  (* The correlation handle rides along from the base logger, which is what ties
     this back to its [search.ok] without repeating the query. *)
  check_string "qhash" (str (field (event board.lines "search.ok") "qhash")) (str (field fields "qhash"))

let ranks_are_one_based_and_ordered () =
  let hits =
    List.init 3 (fun i ->
        result ~snippet:"s" (Printf.sprintf "t%d" i) ~url:(Printf.sprintf "https://x.test/%d" i))
  in
  let board =
    make_engine ~logging:{ Config.default_logging_config with Config.log_content = true }
      [ rig ~results:(`List hits) () ]
  in
  ignore (served board (query "q"));
  check_string "ranks" "1,2,3"
    (String.concat ","
       (List.map (fun fields -> string_of_int (int (field fields "rank"))) (events board.lines "search.result")));
  check_string "titles" "'t0','t1','t2'"
    (String.concat "," (List.map (fun fields -> str (field fields "title")) (events board.lines "search.result")))

let the_answer_is_recorded_only_when_there_is_one () =
  (* [search.ok] reduces it to a bool; this is what recovers the prose. *)
  let s = stub () in
  let board =
    make_engine ~logging:{ Config.default_logging_config with Config.log_content = true } [ rig_of s ]
  in
  ignore (served board (query "q"));
  check_int "no answer event yet" 0 (count board.lines "search.answer");
  s.answer := Some "WAL allows one writer and many readers.";
  ignore (served board (query "q"));
  includes "the prose" "one writer" (str (field (event board.lines "search.answer") "answer"))

let a_failure_records_the_sanitised_message_only () =
  let board = make_engine [ rig ~fail:(quota ~name:"serper") () ] in
  ignore (failed board (query "q"));
  let fields = event board.lines "search.failed" in
  check_string "kind" "QuotaExhausted" (str (field fields "kind"));
  (* [message], not the rendered error: the latter is what the adapters strip the
     httpx exception to avoid, and it carries the provider prefix. *)
  check_string "reason" "quota exhausted" (str (field fields "reason"));
  check_bool "retryable" false (bool (field fields "retryable"))

let an_unresolvable_provider_is_reported_before_dispatch () =
  let board = make_engine [ rig ~name:"serper" (); rig ~name:"linkup" () ] in
  ignore (refused board ~provider:"google" (query "q"));
  let fields = event board.lines "search.rejected" in
  includes "enabled" "serper" (str (field fields "enabled"));
  includes "enabled" "linkup" (str (field fields "enabled"));
  check_string "requested" "'google'" (str (field fields "requested"))

let a_forged_provider_name_cannot_break_the_line () =
  let board = make_engine [ rig () ] in
  ignore (refused board ~provider:"x\nWARNING fake.event" (query "q"));
  check_bool "no newline reaches the line" false
    (String.contains (str (field (event board.lines "search.rejected") "requested")) '\n')

let the_composed_notice_rides_search_ok () =
  let board = make_engine [ rig ~name:"serper" ~results:(`List []) (); rig ~name:"linkup" () ] in
  ignore (served board ~provider:"serper" (query "q"));
  let notice = str (field (event board.lines "search.ok") "notice") in
  includes "the fact" "No results from serper." notice;
  includes "the alternative" "linkup" notice

let the_answer_is_a_bool_on_search_ok () =
  let s = stub () in
  let board = make_engine [ rig_of s ] in
  ignore (served board (query "q"));
  check_bool "no answer" false (bool (field (last_event board.lines "search.ok") "answer"));
  s.answer := Some "None.";
  ignore (served board (query "q"));
  check_bool "an answer" true (bool (field (last_event board.lines "search.ok") "answer"))

let the_cap_lengths_ride_their_own_event () =
  (* [search.cap] is the measurement, and it carries counts only. The caps are
     applied inside the adapter, before any response is recorded, so the length
     one discarded exists nowhere else — which is why it rides a dedicated event
     rather than a field on [search.ok], and why it is emitted whatever
     [log_content] says: these are counts, not caller content, and a measurement
     that only ran with content logging on would not be measuring the default
     deployment. *)
  let s = clip 812 (stub ()) in
  let board = make_engine [ rig_of s ] in
  ignore (served board (query "sqlite wal mode"));
  check_int "the default deployment does not log content" 0 (count board.lines "search.result");
  let fields = event board.lines "search.cap" in
  check_int "rank" 1 (int (field fields "rank"));
  check_string "field" "snippet" (str (field fields "field"));
  check_int "cap" 500 (int (field fields "cap"));
  check_int "chars" 9 (int (field fields "chars"));
  check_int "uncapped_chars" 812 (int (field fields "uncapped_chars"));
  let ok = event board.lines "search.ok" in
  (* The correlation handle rides along from the base logger, the way it does on
     [search.result]. *)
  check_string "qhash" (str (field ok "qhash")) (str (field fields "qhash"));
  check_string "provider" (str (field ok "provider")) (str (field fields "provider"));
  (* Counts only: nothing carrying a hit's title, URL or text reaches this line. *)
  let names = String.concat "," (List.map fst fields) in
  List.iter (fun forbidden -> excludes "no content on the cap line" forbidden names) [ "title"; "url"; "snippet"; "text" ]

let a_result_with_no_capped_field_is_not_measured () =
  (* No snippet and no extract means no cap ran, so nothing was discarded. The
     population is the hits a cap actually saw, which is the denominator the "how
     often does it bite" question needs. *)
  let board = make_engine [ rig ~results:(`List [ result "t" ~url:"https://x.test/a" ]) () ] in
  ignore (served board (query "q"));
  check_int "nothing measured" 0 (count board.lines "search.cap")

let an_extract_is_measured_against_the_other_cap () =
  (* [field] is which cap applied, and it decides which limit is named. *)
  let s = clip 9000 (stub ~results:(`List [ result "t" ~url:"https://x.test/a" ~text:"body" ]) ()) in
  let board = make_engine [ rig_of s ] in
  ignore (served board (query "q"));
  let fields = event board.lines "search.cap" in
  check_string "field" "text" (str (field fields "field"));
  check_int "cap" 2000 (int (field fields "cap"));
  check_int "chars" 4 (int (field fields "chars"));
  check_int "uncapped_chars" 9000 (int (field fields "uncapped_chars"))

let the_cap_line_follows_search_oks_provider_rule () =
  (* The line names the first attempt of the call, as every event of that call
     does; a substitute is named by [search.fallback] and by the response's own
     [provider]. *)
  let serper = stub ~name:"serper" ~fail:(failure ~name:"serper" "upstream 503") () in
  let linkup = clip 812 (stub ~name:"linkup" ()) in
  let board = make_engine ~default:"serper" ~fallback:[ "linkup" ] [ rig_of serper; rig_of linkup ] in
  let r = served board (query "x y") in
  check_string "the substitute served" "linkup" r.Model.provider;
  let fields = event board.lines "search.cap" in
  check_string "the line names the first attempt" "serper" (str (field fields "provider"));
  check_int "and the length that first attempt discarded" 812 (int (field fields "uncapped_chars"))

(* {1 TestUsageRecording} *)

let a_success_records_provider_cost_and_results () =
  let board = make_engine ~usage:(recorder ()) [ rig () ] in
  ignore (served board (query "q"));
  let entry = one_recent (snapshot board) in
  check_string "tool" "search" (str (get "tool" entry));
  check_string "provider" "serper" (str (get "provider" entry));
  money "cost_usd" 0.001 (get "cost_usd" entry);
  check_int "results" 1 (int (get "results" entry));
  check_bool "fell_back" false (bool (get "fell_back" entry));
  check_bool "no error" true (is_null (get "error" entry))

let a_terminal_failure_records_the_class_and_attempted_provider () =
  let board =
    make_engine ~usage:(recorder ()) [ rig ~fail:(quota ~name:"serper") () ]
  in
  ignore (failed board (query "q"));
  let entry = one_recent (snapshot board) in
  check_string "error" "QuotaExhausted" (str (get "error" entry));
  check_string "provider" "serper" (str (get "provider" entry));
  money "cost_usd" 0. (get "cost_usd" entry);
  check_int "results" 0 (int (get "results" entry));
  check_bool "fell_back" false (bool (get "fell_back" entry))

let a_fallback_served_call_records_only_the_fallback () =
  let board =
    make_engine ~default:"serper" ~fallback:[ "linkup" ] ~usage:(recorder ())
      [
        rig ~name:"serper" ~fail:(failure ~name:"serper" "503") ();
        rig ~name:"linkup" ();
      ]
  in
  ignore (served board (query "q"));
  let snapshot = snapshot board in
  check_int "the failed default is not a terminal outcome" 1 (List.length (recent snapshot));
  check_string "provider" "linkup" (str (get "provider" (one_recent snapshot)));
  check_bool "fell_back" true (bool (get "fell_back" (one_recent snapshot)));
  check_int "totals.fallbacks" 1 (int (get "fallbacks" (get "totals" snapshot)))

let an_exhausted_ladder_records_the_tried_default () =
  let board =
    make_engine ~default:"serper" ~fallback:[ "linkup" ] ~usage:(recorder ())
      [
        rig ~name:"serper" ~fail:(failure ~name:"serper" "503") ();
        rig ~name:"linkup" ~fail:(failure ~name:"linkup" "502") ();
      ]
  in
  ignore (failed board (query "q"));
  let entry = one_recent (snapshot board) in
  check_string "provider" "serper" (str (get "provider" entry));
  check_bool "fell_back" true (bool (get "fell_back" entry));
  check_string "error" "ProviderError" (str (get "error" entry))

let a_pre_dispatch_reject_records_nothing () =
  (* Nothing was billed; the error is model-facing, not usage. *)
  let board =
    make_engine ~usage:(recorder ()) [ rig ~name:"serper" (); rig ~name:"linkup" () ]
  in
  ignore (refused board ~provider:"google" (query "q"));
  check_int "nothing journalled" 0 (List.length (recent (snapshot board)))

let no_recorder_means_nothing_is_counted () =
  (* The optional default keeps every existing two-argument call valid: with no
     recorder the call still runs its whole path, and there is nowhere for the
     terminal record to land. *)
  let board = make_engine [ rig () ] in
  let r = served board (query "q") in
  check_string "the search was served" "serper" r.Model.provider;
  check_int "and the operator still saw it" 1 (count board.lines "search.ok")

(* {1 TestSpecialTokenEscaping}

   The engine escapes the response object it returns — before the decision line
   is emitted, so the count has a home, and before the agent's retrieval material
   is assembled from the same objects. The serialisation boundary re-checks the
   same escape ([test_sanitize.ml]); together the two passes are one rule,
   because the escape is idempotent. *)

let sanitized board = int (field (event board.lines "search.ok") "sanitized")

let result_text_is_escaped_before_it_leaves () =
  let hits =
    [
      result "a title with <start_of_turn>" ~url:"https://example.com/tokens"
        ~text:"the page says <|endoftext|> and [INST] hi";
    ]
  in
  let board = make_engine [ rig ~results:(`List hits) () ] in
  let r = served board (query "special tokens") in
  let hit = List.hd r.Model.results in
  check_string "title" ("a title with <" ^ z ^ "start_of_turn>") hit.Model.title;
  check_string "text" (Printf.sprintf "the page says <%s|endoftext|> and [%sINST] hi" z z)
    (Option.value ~default:"" hit.Model.text);
  check_string "url is left alone" "https://example.com/tokens" hit.Model.url;
  check_int "sanitized" 3 (sanitized board)

let the_answer_tier_escapes_too () =
  let board = make_engine [ rig ~answer:"an answer quoting <|im_end|>" () ] in
  let r = served board (query "special tokens") in
  check_string "answer" ("an answer quoting <" ^ z ^ "|im_end|>") (Option.value ~default:"" r.Model.answer);
  check_int "sanitized" 1 (sanitized board)

let a_clean_result_counts_zero () =
  let board = make_engine [ rig () ] in
  ignore (served board (query "sqlite wal mode"));
  check_int "sanitized" 0 (sanitized board)

let a_reread_response_is_not_escaped_again () =
  (* The Python case hands the *same* [Result] object to the escape pass twice and
     reads [1, 0] off the counts, which is a fact about a mutable fixture: the
     first pass rewrites it, so the second finds nothing to escape. A
     {!Seekwright.Model.result} is immutable, so each serve escapes the fresh copy
     its adapter handed back and the counts read [1, 1]. What crosses over is the
     rule that makes that harmless — the escape is idempotent, so re-escaping a
     value that already left the engine escaped counts nothing and changes
     nothing, which is what the serialisation boundary relies on. *)
  let hits = [ result "t" ~url:"https://example.com/a" ~text:"raw <|im_start|> raw" ] in
  let board = make_engine [ rig ~results:(`List hits) () ] in
  let first = served board (query "special tokens") in
  let second = served board (query "special tokens") in
  check_string "first serve" ("raw <" ^ z ^ "|im_start|> raw")
    (Option.value ~default:"" (List.hd first.Model.results).Model.text);
  check_string "second serve is unchanged"
    (Option.value ~default:"" (List.hd first.Model.results).Model.text)
    (Option.value ~default:"" (List.hd second.Model.results).Model.text);
  check_string "the engine counts one escape per fresh adapter object" "1,1"
    (String.concat ","
       (List.map (fun fields -> string_of_int (int (field fields "sanitized"))) (events board.lines "search.ok")));
  let again, count =
    Model.sanitize_provider_result
      {
        Model.provider = "serper";
        results = first.Model.results;
        answer = None;
        cost_usd = None;
        notice = None;
      }
  in
  check_int "a second pass over an escaped value escapes nothing" 0 count;
  check_string "and changes nothing"
    (Option.value ~default:"" (List.hd first.Model.results).Model.text)
    (Option.value ~default:"" (List.hd again.Model.results).Model.text)

(* {1 The suite} *)

let search_cases =
  [
    A.test_case "results are returned" `Quick results_are_returned;
    A.test_case "every call reaches the provider" `Quick every_call_reaches_the_provider;
    A.test_case "a provider notice reaches the caller" `Quick a_provider_notice_reaches_the_caller;
  ]

let provider_selection_cases =
  [
    A.test_case "a named provider is used" `Quick a_named_provider_is_used;
    A.test_case "an omitted provider uses the default" `Quick an_omitted_provider_uses_the_default;
    A.test_case "no default and several enabled asks the caller to choose" `Quick
      no_default_and_several_enabled_asks_the_caller_to_choose;
    A.test_case "an unknown provider names the available ones" `Quick
      an_unknown_provider_names_the_available_ones;
    A.test_case "the default is only offered when there is one" `Quick
      the_default_is_only_offered_when_there_is_one;
  ]

let provider_failure_cases =
  [
    A.test_case "a failure carries retry advice" `Quick a_failure_carries_retry_advice;
    A.test_case "quota exhausted says do not retry" `Quick quota_exhausted_says_do_not_retry;
    A.test_case "a non-object JSON body reaches the caller as advice" `Quick
      a_non_object_json_body_reaches_the_caller_as_advice;
  ]

let default_route_cases =
  [
    A.test_case "a failed default is served by the fallback" `Quick a_failed_default_is_served_by_the_fallback;
    A.test_case "the substitute notice joins the adapter notice" `Quick the_substitute_notice_joins_the_adapter_notice;
    A.test_case "a named provider failure stays terminal" `Quick a_named_provider_failure_stays_terminal;
    A.test_case "an open circuit fallback is skipped" `Quick an_open_circuit_fallback_is_skipped;
    A.test_case "when every fallback fails the original error leads" `Quick
      when_every_fallback_fails_the_original_error_leads;
    A.test_case "each fallback runs once and the default is not retried" `Quick
      each_fallback_runs_once_and_the_default_is_not_retried;
    A.test_case "a direct success says so and named failures still feed the board" `Quick
      a_direct_success_says_so_and_named_failures_still_feed_the_board;
    A.test_case "quota exhausted reroutes and all quota keeps its advice" `Quick
      quota_exhausted_reroutes_and_all_quota_keeps_its_advice;
  ]

let free_mode_cases =
  [
    A.test_case "the free walk is the constant order, keyless first" `Quick
      the_free_walk_is_the_constant_order_keyless_first;
    A.test_case "the configured ladder decides the order and narrows the walk" `Quick
      the_configured_free_ladder_decides_the_order_and_narrows_the_walk;
    A.test_case "the free walk does not consult the default" `Quick the_free_walk_does_not_consult_the_default;
    A.test_case "a paid provider is never reached" `Quick a_paid_provider_is_never_reached;
    A.test_case "one free fallback alone still says why nothing paid was tried" `Quick
      one_free_fallback_alone_still_says_why_nothing_paid_was_tried;
    A.test_case "an open circuit free fallback is skipped" `Quick an_open_circuit_free_fallback_is_skipped;
    A.test_case "a failed free fallback gates on the health board" `Quick a_failed_free_fallback_gates_on_the_health_board;
    A.test_case "no free provider enabled is a clean refusal" `Quick no_free_provider_enabled_is_a_clean_refusal;
    A.test_case "naming a provider and a mode is refused" `Quick naming_a_provider_and_a_mode_is_refused;
    A.test_case "mode is bound on search.ok either way" `Quick mode_is_bound_on_search_ok_either_way;
    A.test_case "a free served search records the fallback once" `Quick a_free_served_search_records_the_fallback_once;
  ]

let free_only_default_route_cases =
  [
    A.test_case "an unnamed search is served by the free walk" `Quick an_unnamed_search_is_served_by_the_free_walk;
    A.test_case "the implicit keyless set is walked whole" `Quick the_implicit_keyless_set_is_walked_whole;
    A.test_case "the walk is the free order and only free names" `Quick the_free_order_and_only_free_names;
    A.test_case "the configured free ladder orders the implicit walk" `Quick
      the_configured_free_ladder_orders_the_implicit_walk;
    A.test_case "the ending is the walk's own" `Quick the_implicit_walks_ending_is_the_walks_own;
    A.test_case "an open circuit is skipped on the implicit walk" `Quick an_open_circuit_is_skipped_on_the_implicit_walk;
    A.test_case "one billable name brings the refusal back" `Quick one_billable_name_brings_the_refusal_back;
    A.test_case "a free tier is not a free name" `Quick a_free_tier_is_not_a_free_name;
    A.test_case "a named provider is unaffected" `Quick a_named_provider_is_unaffected_by_the_free_only_route;
    A.test_case "a single free provider is still the default" `Quick a_single_free_provider_is_still_the_default;
    A.test_case "mode stays none on the unnamed walk" `Quick mode_stays_none_on_the_unnamed_walk;
  ]

let allow_list_cases =
  [
    A.test_case "a name enabled but not permitted never reaches the adapter" `Quick
      a_name_enabled_but_not_permitted_never_reaches_the_adapter;
    A.test_case "unset is permissive" `Quick an_unset_permission_set_is_permissive;
    A.test_case "the intersection holds both ways" `Quick the_permission_intersection_holds_both_ways;
    A.test_case "the default route skips an unpermitted fallback" `Quick the_default_route_skips_an_unpermitted_fallback;
    A.test_case "an unpermitted default is refused not rerouted" `Quick an_unpermitted_default_is_refused_not_rerouted;
    A.test_case "a free walk never reaches an unpermitted fallback" `Quick a_free_walk_never_reaches_an_unpermitted_fallback;
    A.test_case "a free walk emptied by the list says permitted" `Quick a_free_walk_emptied_by_the_list_says_permitted;
    A.test_case "a rejection binds the permitted set" `Quick a_rejection_binds_the_permitted_set;
    A.test_case "the rejection bind is none when unset" `Quick the_rejection_bind_is_none_when_unset;
  ]

let zero_results_cases =
  [
    A.test_case "empty results are not an error" `Quick empty_results_are_not_an_error;
    A.test_case "a zero results notice names the other providers" `Quick a_zero_results_notice_names_the_other_providers;
    A.test_case "a solo provider zero results says it is alone" `Quick a_solo_provider_zero_results_says_it_is_alone;
    A.test_case "an answered zero result gets no notice" `Quick an_answered_zero_result_gets_no_notice;
    A.test_case "an adapter notice is joined with the zero notice" `Quick an_adapter_notice_is_joined_with_the_zero_notice;
    A.test_case "a fallback serving zero results names the fallback" `Quick a_fallback_serving_zero_results_names_the_fallback;
  ]

let observability_cases =
  [
    A.test_case "a search records cost and latency" `Quick a_search_records_cost_and_latency;
    A.test_case "reported usage is absent until an adapter measures it" `Quick reported_usage_is_absent_until_an_adapter_measures_it;
    A.test_case "query text is withheld by default" `Quick query_text_is_withheld_by_default;
    A.test_case "query text is recorded when opted in" `Quick query_text_is_recorded_when_opted_in;
    A.test_case "result content is withheld by default" `Quick result_content_is_withheld_by_default;
    A.test_case "result content is recorded when opted in" `Quick result_content_is_recorded_when_opted_in;
    A.test_case "ranks are one based and ordered" `Quick ranks_are_one_based_and_ordered;
    A.test_case "the answer is recorded only when there is one" `Quick the_answer_is_recorded_only_when_there_is_one;
    A.test_case "a failure records the sanitised message only" `Quick a_failure_records_the_sanitised_message_only;
    A.test_case "an unresolvable provider is reported before dispatch" `Quick an_unresolvable_provider_is_reported_before_dispatch;
    A.test_case "a forged provider name cannot break the line" `Quick a_forged_provider_name_cannot_break_the_line;
    A.test_case "the composed notice rides search.ok" `Quick the_composed_notice_rides_search_ok;
    A.test_case "the answer is a bool on search.ok" `Quick the_answer_is_a_bool_on_search_ok;
    A.test_case "the cap lengths ride their own event" `Quick the_cap_lengths_ride_their_own_event;
    A.test_case "a result with no capped field is not measured" `Quick a_result_with_no_capped_field_is_not_measured;
    A.test_case "an extract is measured against the other cap" `Quick an_extract_is_measured_against_the_other_cap;
    A.test_case "the cap line follows search.ok's provider rule" `Quick the_cap_line_follows_search_oks_provider_rule;
  ]

let usage_recording_cases =
  [
    A.test_case "a success records provider cost and results" `Quick a_success_records_provider_cost_and_results;
    A.test_case "a terminal failure records the class and attempted provider" `Quick
      a_terminal_failure_records_the_class_and_attempted_provider;
    A.test_case "a fallback served call records only the fallback" `Quick a_fallback_served_call_records_only_the_fallback;
    A.test_case "an exhausted ladder records the tried default" `Quick an_exhausted_ladder_records_the_tried_default;
    A.test_case "a pre dispatch reject records nothing" `Quick a_pre_dispatch_reject_records_nothing;
    A.test_case "no recorder means nothing is counted" `Quick no_recorder_means_nothing_is_counted;
  ]

let escaping_cases =
  [
    A.test_case "result text is escaped before it leaves" `Quick result_text_is_escaped_before_it_leaves;
    A.test_case "the answer tier escapes too" `Quick the_answer_tier_escapes_too;
    A.test_case "a clean result counts zero" `Quick a_clean_result_counts_zero;
    A.test_case "a reread response is not escaped again" `Quick a_reread_response_is_not_escaped_again;
  ]

let () =
  A.run "engine"
    [
      ("search", search_cases);
      ("provider selection", provider_selection_cases);
      ("provider failure", provider_failure_cases);
      ("default route failover", default_route_cases);
      ("free mode", free_mode_cases);
      ("the free-only default route", free_only_default_route_cases);
      ("the allow-list", allow_list_cases);
      ("zero results", zero_results_cases);
      ("observability", observability_cases);
      ("usage recording", usage_recording_cases);
      ("special token escaping", escaping_cases);
    ]
