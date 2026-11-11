(* Agent mode: the fixed plan, the one model call, and the citations the server
   validates. Ported case for case from [tests/test_agent.py]'s engine-level
   classes -- TestThePlan, TestCitations, TestFailureContract, TestTheAllowList,
   TestUsageAccounting, TestSpecialTokenEscaping -- with the real
   [Engine.Search] and [Engine.Fetch] wired over stub providers and a stub
   fetcher, and only the model endpoint stubbed.

   The stubs sit where the Python suite's did: [Provider.t] is a packaged
   module, so the stub provider is a record of mutable state plus a [behavior]
   field a case replaces (the [Flaky] subclass of the partial-walk case); the
   model endpoint is a [Provider.Net.t] whose [request] records the payload and
   answers with a canned body, a status, or a transport failure — the same
   position [httpx.MockTransport] holds. The whole-call timeout case drives the
   injected monotonic clock forward from inside the stubbed model call, which
   is the synchronous port's answer to [asyncio.sleep] inside a mock.

   Not ported: the classes that drive the MCP server itself
   (TestThroughTheMcpServer, TestWiring) — the tool schema, the REST route and
   the startup refusal are P8 — and TestThinModeUnchanged's wire-model half,
   already pinned by [test_model.ml]. *)

module Agent = Seekwright.Agent
module Caps = Mcp_caps
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Sanitize = Seekwright.Sanitize
module Usage = Seekwright.Usage
module A = Alcotest

let zwsp = Sanitize.zwsp

(* {1 Reads} *)

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

let float_of = function
  | `Int n -> float_of_int n
  | `Float f -> f
  | v -> A.failf "not a money figure: %s" (Yojson.Safe.to_string v)

let find_sub_from ?(start = 0) text needle =
  let needle_length = String.length needle in
  let haystack_length = String.length text in
  let rec go index =
    if index + needle_length > haystack_length then None
    else if String.sub text index needle_length = needle then Some index
    else go (index + 1)
  in
  go start

let includes label needle text =
  match find_sub_from text needle with
  | Some _ -> ()
  | None -> A.failf "%s: the text did not contain %S\n     it was: %S" label needle text

let excludes label needle text =
  match find_sub_from text needle with
  | None -> ()
  | Some _ -> A.failf "%s: the text contained %S, and must not\n     it was: %S" label needle text

let split_once separator text =
  match find_sub_from text separator with
  | None -> None
  | Some i ->
    Some
      ( String.sub text 0 i,
        String.sub text (i + String.length separator) (String.length text - i - String.length separator) )

let rsplit_once separator text =
  let rec go from =
    match find_sub_from ~start:from text separator with
    | None -> None
    | Some i -> (
      match find_sub_from ~start:(i + String.length separator) text separator with
      | Some _ -> go i
      | None ->
        Some
          ( String.sub text 0 i,
            String.sub text (i + String.length separator) (String.length text - i - String.length separator) ))
  in
  match find_sub_from text separator with
  | None -> None
  | Some first -> go first

let check_string = A.(check string)
let check_int = A.(check int)
let check_bool = A.(check bool)
let check_opt_string = A.(check (option string))
let check_opt_bool = A.(check (option bool))
let check_strings = A.(check (list string))
let check_ints = A.(check (list int))

(* {1 The wire fixtures} *)

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

(* {1 The stub provider}

   [Provider.t] is a packaged module, so the stub is a record of mutable state
   plus a [behavior] field the module's [search] delegates to; a case that
   Python writes as a subclass replaces that field instead. *)

type stub = {
  name : string;
  calls : int ref;
  seen : Model.search_query list ref;
  behavior : (Model.search_query -> (Provider.outcome, Provider.error) result) ref;
}

let stub ?(name = "serper") ?(results : [ `Default | `List of Model.result list ] = `Default)
    ?fail ?(cost_usd = Some 0.007) () =
  let s =
    {
      name;
      calls = ref 0;
      seen = ref [];
      behavior =
        ref (fun _q -> Error (Provider.provider_error ~provider:name "not configured"));
    }
  in
  s.behavior
  := (fun q ->
       incr s.calls;
       s.seen := !(s.seen) @ [ q ];
       match fail with
       | Some failure -> Error failure
       | None ->
         let hits =
           match results with
           | `Default ->
             [
               result ~snippet:"a snippet"
                 ~url:(Printf.sprintf "https://example.com/%d" !(s.calls))
                 (Printf.sprintf "About %s" q.Model.query);
             ]
           | `List hits -> hits
         in
         Ok
           {
             Provider.provider = s.name;
             results = List.map (fun hit -> { Provider.result = hit; uncapped_chars = None }) hits;
             answer = None;
             cost_usd;
             notice = None;
           });
  s

let provider_of (s : stub) : Provider.t =
  (module struct
    let name = s.name
    let cost_per_1k = 0.001
    let cost_for n = float_of_int n /. 1000.
    let search q = !(s.behavior) q
    let aclose () = ()
  end : Provider.S)

(* {1 The stub model endpoint}

   The [Provider.Net.t] seam with a canned chat-completions body; [delay] moves
   the injected monotonic clock, which is how the whole-call timeout case runs
   without sleeping. *)

type model_stub = {
  calls : int ref;
  payloads : Yojson.Safe.t list ref;
  content : string option;
  finish_reason : string;
  status : int;
  body : string option;
  usage : (int * int) option;
  delay : float;
  timeout : bool;
}

let stub_model ?(content = Some "An answer, cited [1].") ?(finish_reason = "stop") ?(status = 200) ?(body = None)
    ?(usage = Some (11, 7)) ?(delay = 0.0) ?(timeout = false) () =
  {
    calls = ref 0;
    payloads = ref [];
    content;
    finish_reason;
    status;
    body;
    usage;
    delay;
    timeout;
  }

let model_net mono (m : model_stub) : Provider.Net.t =
  {
    Provider.Net.request =
      (fun (request : Caps.Authority.Net.request) ->
        incr m.calls;
        (match request.body with
        | Some body -> (
          try m.payloads := Yojson.Safe.from_string body :: !(m.payloads)
          with Yojson.Json_error _ -> ())
        | None -> ());
        if m.timeout then
          (* The grant's [Timeout] row is what a read past the bound answers
             with; the message text never reaches the caller. *)
          Error (Caps.Error.make Caps.Error.Timeout ~message:"the read timed out")
        else begin
          mono := !mono +. m.delay;
          let body =
            if m.status <> 200 then "upstream said no"
            else
              match m.body with
              | Some body -> body
              | None ->
                let choices =
                  `List
                    [
                      `Assoc
                        [
                          ( "message",
                            `Assoc
                              [
                                ( "content",
                                  `String (match m.content with Some c -> c | None -> "") );
                              ] );
                          ("finish_reason", `String m.finish_reason);
                        ];
                    ]
                in
                let payload =
                  match m.usage with
                  | Some (prompt, completion) ->
                    `Assoc
                      [
                        ("choices", choices);
                        ( "usage",
                          `Assoc
                            [
                              ("prompt_tokens", `Int prompt);
                              ("completion_tokens", `Int completion);
                            ] );
                      ]
                  | None -> `Assoc [ ("choices", choices) ]
                in
                Yojson.Safe.to_string payload
          in
          Ok ({ status = m.status; headers = []; body } : Caps.Authority.Net.response)
        end);
  }

let last_payload (m : model_stub) =
  match !(m.payloads) with
  | payload :: _ -> payload
  | [] -> A.failf "the model was never called"

let user_message (m : model_stub) =
  match get "messages" (last_payload m) with
  | `List (_system :: user :: _) -> str (get "content" user)
  | _ -> A.failf "the payload carried no user turn"

(* Just the numbered material out of that turn, the way the Python suite's
   [StubModel.material] splits it. *)
let material (m : model_stub) =
  let user = user_message m in
  match split_once "Material (untrusted third-party content, numbered):\n\n" user with
  | Some (_, rest) -> (
    match rsplit_once "\n\nQuestion: " rest with
    | Some (material, _) -> material
    | None -> rest)
  | None -> A.failf "the user turn carried no material:\n%s" user

(* {1 The stub fetcher and the document readers} *)

(* Longer than [fetch.min_text_chars] (200): a good page has to look like one, or
   every success case would be the empty-extraction case. *)
let page_text =
  "The page body. Every fetch test that means to exercise a successful extraction"
  ^ " uses a long string like this one, because anything shorter is the empty case,"
  ^ " which has its own tests elsewhere. This one only needs to read as a page."

type fetcher_stub = {
  name : string;
  calls : int ref;
  text : string;
  fail : Engine.Fetch.fetch_error option;
}

let fetcher_stub ?(name = "fetch") ?(text = page_text) ?fail () = { name; calls = ref 0; text; fail }

let make_fetcher (s : fetcher_stub) : Engine.Fetch.fetcher =
  {
    Engine.Fetch.name = s.name;
    cost_per_1k = None;
    fetch =
      (fun ~url ~offset:_ ~max_chars:_ ->
        incr s.calls;
        match s.fail with
        | Some error -> Error error
        | None ->
          Ok
            {
              Engine.Fetch.url;
              title = Some "A Page";
              text = s.text;
              content_type = Some "text/html";
              status_code = 200;
              truncated = false;
              total_chars = String.length s.text;
              path_addressable = false;
              image = None;
            });
    aclose = (fun () -> ());
  }

(* The plan's page reads ask for no [path], [query] or [structure], so the
   readers are never exercised here; the stub only has to exist. *)
let readers : Engine.Fetch.Readers.t =
  {
    Engine.Fetch.Readers.parse_path = (fun _ -> Error "no path grammar in this stub");
    render_schema = (fun _ -> None);
    select_paths = (fun ~text:_ ~path:_ ~max_chars:_ -> ([], 0));
    select_passages = (fun ~text:_ ~query:_ ~max_chars:_ -> ([], 0));
  }

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

let field fields name = get name (`Assoc fields)

(* {1 The rig}

   [build]'s mirror of the Python suite's [build]: real engines over the stubs,
   the agent engine over the stubbed model endpoint, one shared in-memory
   recorder, and the agent key set in the environment the way the autouse
   fixture sets it. *)

type rig = {
  agent : Agent.t;
  provider : stub;
  model : model_stub;
  lines : captured list ref;
  usage : Usage.t;
  mono : float ref;
  local : fetcher_stub option;
  fallbacks : fetcher_stub list;
}

let make_config ?permitted ?(log_content = false) ?(tweak_agent = fun a -> a) () =
  let agent =
    tweak_agent
      {
        Config.default_agent_config with
        Config.enabled = true;
        base_url = Some "https://model.test/v1";
        model = Some "test-model";
      }
  in
  let logging = { Config.default_logging_config with Config.log_content = log_content } in
  match
    Config.resolve
      ~providers:[ ("serper", { Config.default_provider_config with Config.enabled = true }) ]
      ?permitted_providers:permitted ~agent ~logging ()
  with
  | Ok config -> config
  | Error message -> A.failf "the fixture config was refused: %s" message

let build ?permitted ?log_content ?tweak_agent ?provider ?fetcher ?model ?(fetch = true)
    ?(fallbacks = []) () =
  Unix.putenv "SEEKWRIGHT_AGENT_API_KEY" "sk-test-key";
  let mono = ref 1768478400. in
  let clock () = !mono in
  let now () = 1768478400. in
  let config = make_config ?permitted ?log_content ?tweak_agent () in
  let provider = match provider with Some p -> p | None -> stub () in
  let model = match model with Some m -> m | None -> stub_model () in
  let lines = ref [] in
  let usage =
    match Usage.create ~now () with
    | Ok usage -> usage
    | Error message -> A.failf "an in-memory recorder cannot fail: %s" message
  in
  let engine =
    Engine.Search.create config ~usage ~log:(sink lines)
      [ (provider.name, provider_of provider) ]
      ~clock ~now ()
  in
  let local = match fetcher with Some f -> Some f | None -> if fetch then Some (fetcher_stub ()) else None in
  let fetch_engine =
    if fetch then
      match local with
      | None -> None
      | Some local -> (
        match
          Engine.Fetch.create config (make_fetcher local) ~readers ~usage ~log:(sink lines)
            ~fallbacks:(List.map make_fetcher fallbacks)
            ~clock ~now ()
        with
        | Ok engine -> Some engine
        | Error message -> A.failf "the fetch engine refused the fixture: %s" message)
    else None
  in
  let agent =
    Agent.create config ~net:(model_net mono model) engine ?fetch_engine ~usage
      ~log:(sink lines) ~clock ~now ()
  in
  { agent; provider; model; lines; usage; mono; local; fallbacks }

(* Answers and failures: the Python suite reads [str(raised.value)]; here the
   [Error] payload is that same sentence. *)
let answered rig ?extra_queries ?depth ?provider ?include_domains ?exclude_domains ?recency ?language
    ?safe_search () =
  match
    Agent.answer rig.agent ~query:"why is the sky blue" ?extra_queries ?depth ?provider
      ?include_domains ?exclude_domains ?recency ?language ?safe_search ()
  with
  | Ok response -> response
  | Error message -> A.failf "the answer failed: %s" message

let failed rig ?extra_queries ?depth ?provider ?include_domains ?exclude_domains ?recency ?language
    ?safe_search () =
  match
    Agent.answer rig.agent ~query:"why is the sky blue" ?extra_queries ?depth ?provider
      ?include_domains ?exclude_domains ?recency ?language ?safe_search ()
  with
  | Error message -> message
  | Ok _ -> A.failf "expected the answer to fail"

(* The journal, read off the in-memory recorder's snapshot: the [recent] deque
   holds the same lines the JSONL file would. *)
let recent rig = items (get "recent" (Usage.snapshot rig.usage))

let lines_of rig tool =
  List.filter (fun line -> str (get "tool" line) = tool) (recent rig)

let one_answer_line rig =
  match lines_of rig "answer" with
  | [ line ] -> line
  | many -> A.failf "expected one answer line, got %d" (List.length many)

let source_urls (r : Model.answer_response) =
  List.map (fun (s : Model.answer_source) -> s.Model.source_url) r.Model.sources

(* {1 TestThePlan} *)

let a_brief_answer_runs_one_search_and_reads_no_pages () =
  let rig = build () in
  let r = answered rig () in
  check_int "one search" 1 !(rig.provider.calls);
  check_int "searches" 1 r.Model.searches;
  check_int "no pages read" 0 r.Model.fetched;
  check_string "depth" "brief" (match r.Model.depth with Model.Brief -> "brief" | Report -> "report");
  check_int "one model call" 1 !(rig.model.calls)

let a_brief_answer_does_not_run_the_extra_queries () =
  (* [brief] is one search by contract: it is the depth's whole promise. *)
  let rig = build () in
  let r =
    answered rig ~extra_queries:[ "rayleigh scattering"; "sky colour physics" ] ()
  in
  check_int "one search" 1 !(rig.provider.calls);
  check_int "searches" 1 r.Model.searches

let a_report_runs_every_query_in_order () =
  let rig = build () in
  let r =
    answered rig ~extra_queries:[ "rayleigh scattering"; "sky colour physics" ]
      ~depth:Model.Report ()
  in
  check_strings "the queries, in order"
    [ "why is the sky blue"; "rayleigh scattering"; "sky colour physics" ]
    (List.map (fun (q : Model.search_query) -> q.Model.query) !(rig.provider.seen));
  check_int "searches" 3 r.Model.searches

let every_query_carries_the_callers_filters_and_the_fixed_width () =
  let rig = build () in
  ignore
    (answered rig ~depth:Model.Report ~include_domains:[ "nasa.gov" ]
       ~exclude_domains:[ "example.com" ] ~recency:Model.Month ~language:"en" ~safe_search:true ());
  let q = List.hd !(rig.provider.seen) in
  check_int "max_results is the fixed width" Agent.results_per_query q.Model.max_results;
  check_int "the fixed width is 5" 5 Agent.results_per_query;
  check_strings "include_domains" [ "nasa.gov" ] q.Model.include_domains;
  check_strings "exclude_domains" [ "example.com" ] q.Model.exclude_domains;
  check_opt_string "recency" (Some "month")
    (match q.Model.recency with Some Model.Month -> Some "month" | _ -> None);
  check_opt_string "language" (Some "en") q.Model.language;
  check_opt_string "safe_search" (Some "true")
    (match q.Model.safe_search with Some true -> Some "true" | _ -> None)

let both_new_filters_reach_every_step_of_a_report () =
  let rig = build () in
  ignore
    (answered rig ~extra_queries:[ "rayleigh scattering" ] ~depth:Model.Report ~language:"de"
       ~safe_search:false ());
  let seen = !(rig.provider.seen) in
  check_int "two steps" 2 (List.length seen);
  check_strings "language on every step" [ "de"; "de" ]
    (List.map (fun (q : Model.search_query) -> Option.value ~default:"" q.Model.language) seen);
  check_strings "safe_search on every step" [ "false"; "false" ]
    (List.map
       (fun (q : Model.search_query) ->
         match q.Model.safe_search with Some b -> string_of_bool b | None -> "unset")
       seen)

let a_report_reads_at_most_three_pages () =
  (* The page count is a constant, not a function of what came back. *)
  let results =
    List.init 5 (fun i ->
      result ~snippet:"s" ~url:(Printf.sprintf "https://example.com/%d" (i + 1))
        (Printf.sprintf "r%d" (i + 1)))
  in
  let local = fetcher_stub () in
  let rig = build ~provider:(stub ~results:(`List results) ()) ~fetcher:local () in
  let r = answered rig ~depth:Model.Report () in
  let local_calls = match rig.local with Some l -> !(l.calls) | None -> 0 in
  check_int "the page count is the constant" Agent.pages_per_report local_calls;
  check_int "the constant is 3" 3 Agent.pages_per_report;
  check_int "fetched" 3 r.Model.fetched

let a_result_that_already_carries_text_is_not_fetched () =
  (* A content backend handed us the extract; refetching bills twice. *)
  let local = fetcher_stub () in
  let rig =
    build
      ~provider:(stub ~results:(`List [ result ~text:"An extract the backend returned." ~url:"https://example.com/1" "About why is the sky blue" ]) ())
      ~fetcher:local ()
  in
  let r = answered rig ~depth:Model.Report () in
  let local_calls = match rig.local with Some l -> !(l.calls) | None -> -1 in
  check_int "no page fetched" 0 local_calls;
  check_int "fetched" 0 r.Model.fetched;
  includes "the material" "An extract the backend returned." (material rig.model)

let a_brief_is_grounded_in_a_content_backends_extract () =
  (* A content backend fills [text] and leaves [snippet] empty; [brief] reads no
     pages, so that extract is the only body it has. *)
  let rig =
    build
      ~provider:(stub ~results:(`List [ result ~text:"An extract the backend returned." ~url:"https://example.com/1" "About why is the sky blue" ]) ())
      ()
  in
  let r = answered rig () in
  check_string "depth" "brief"
    (match r.Model.depth with Model.Brief -> "brief" | Report -> "report");
  includes "the material" "An extract the backend returned." (material rig.model)

let the_extract_is_the_body_when_a_backend_sends_both () =
  (* [text] before [snippet], the order [report] already uses to skip a fetch. *)
  let results =
    [ result ~snippet:"a snippet" ~text:"the fuller extract" ~url:"https://example.com/both" "both" ]
  in
  let rig = build ~provider:(stub ~results:(`List results) ()) () in
  ignore (answered rig ());
  includes "the material" "the fuller extract" (material rig.model)

let the_material_is_numbered_and_carries_title_and_url () =
  let rig = build () in
  ignore (answered rig ());
  let m = material rig.model in
  includes "numbered from 1" "[1] About why is the sky blue" m;
  includes "the url" "https://example.com/1" m;
  includes "the snippet" "a snippet" m

let the_material_is_bounded_by_max_material_chars () =
  (* The input side of the model call is a number, not a provider's whim. *)
  let cap = 60 in
  let rig = build ~tweak_agent:(fun a -> { a with Config.max_material_chars = cap }) () in
  ignore (answered rig ());
  let m = material rig.model in
  if String.length m > cap then A.failf "the material was %d chars, over the cap %d" (String.length m) cap;
  let has tag = match find_sub_from m tag with Some _ -> true | None -> false in
  if not (has "[1]") then A.failf "no [1] in %S" m;
  if has "[2]" then A.failf "the numbering did not stop at the cap: %S" m

let a_report_is_served_from_snippets_when_fetch_is_off () =
  let rig = build ~fetch:false () in
  let r = answered rig ~depth:Model.Report () in
  check_int "no pages" 0 r.Model.fetched;
  includes "notice" "fetch tool disabled" (Option.value ~default:"" r.Model.notice);
  check_int "the model was still called once" 1 !(rig.model.calls)

let the_model_call_carries_the_servers_own_settings () =
  (* Prompt, temperature and the output cap are the server's, never a parameter. *)
  let rig = build () in
  ignore (answered rig ());
  let payload = last_payload rig.model in
  check_string "model" "test-model" (str (get "model" payload));
  A.(check (float 1e-12)) "temperature" (float_of (get "temperature" payload)) Agent.temperature;
  check_int "the brief output cap" 500 (int (get "max_tokens" payload));
  check_bool "never streamed" false (bool (get "stream" payload));
  (match get "messages" payload with
  | `List (system :: _ :: _) ->
    includes "the system prompt" "untrusted third-party content" (str (get "content" system))
  | _ -> A.failf "the payload carried no system turn")

let the_report_output_cap_is_the_reports () =
  let rig = build () in
  ignore (answered rig ~depth:Model.Report ());
  check_int "the report output cap" 2500 (int (get "max_tokens" (last_payload rig.model)))

(* {1 TestCitations} *)

let sources_hold_only_what_the_prose_cited () =
  let rig = build ~model:(stub_model ~content:(Some "Scattering does it [1].") ()) () in
  let r = answered rig () in
  check_strings "sources" [ "https://example.com/1" ] (source_urls r);
  let source = List.hd r.Model.sources in
  check_string "provider" "serper" source.Model.source_provider;
  check_string "title" "About why is the sky blue" source.Model.source_title

let an_invented_index_is_dropped_counted_and_named () =
  (* A 200, not a failure: the defect is in the prose, not the retrieval. *)
  let rig =
    build ~model:(stub_model ~content:(Some "Scattering does it [1] and the moon does too [9].") ()) ()
  in
  let r = answered rig () in
  check_strings "sources" [ "https://example.com/1" ] (source_urls r);
  let notice = Option.value ~default:"" r.Model.notice in
  includes "notice" "cites 1 index" notice;
  includes "notice" "dropped" notice

let an_uncited_answer_is_returned_with_a_notice () =
  let rig = build ~model:(stub_model ~content:(Some "Scattering does it, on the whole.") ()) () in
  let r = answered rig () in
  check_string "answer" "Scattering does it, on the whole." r.Model.answer;
  check_strings "no sources" [] (source_urls r);
  includes "notice" "no citations" (Option.value ~default:"" r.Model.notice)

let an_answer_whose_only_markers_are_invented_names_the_count () =
  (* Both citation rows hold at once: nothing valid, and two invented. *)
  let rig =
    build ~model:(stub_model ~content:(Some "The moon does it [7] and also [8].") ()) ()
  in
  let r = answered rig () in
  check_string "answer" "The moon does it [7] and also [8]." r.Model.answer;
  check_strings "no sources" [] (source_urls r);
  let notice = Option.value ~default:"" r.Model.notice in
  includes "notice" "cites 2 indices" notice;
  includes "notice" "no citations" notice;
  let line = one_answer_line rig in
  check_int "cited" 0 (int (get "cited" line));
  check_int "cited_invalid" 2 (int (get "cited_invalid" line))

let a_marker_that_is_not_a_number_counts_as_invalid () =
  let rig =
    build ~model:(stub_model ~content:(Some "See [n] for the detail, and [1] for the claim.") ()) ()
  in
  let r = answered rig () in
  check_strings "sources" [ "https://example.com/1" ] (source_urls r);
  includes "notice" "cites 1 index" (Option.value ~default:"" r.Model.notice)

let markdown_link_text_is_not_a_citation_marker () =
  (* The one false positive worth excluding: [[text](url)] is not an index. *)
  let rig =
    build
      ~model:(stub_model ~content:(Some "Scattering [see the note](https://x.test/n) does it [1].") ())
      ()
  in
  let r = answered rig () in
  check_opt_string "no notice" None r.Model.notice;
  check_strings "sources" [ "https://example.com/1" ] (source_urls r)

let two_indices_for_one_url_collapse_in_sources () =
  (* [cited] deduplicates by index, [sources] by URL — so they can differ. *)
  let results =
    [
      result ~snippet:"s" ~url:"https://example.com/same" "a";
      result ~snippet:"s" ~url:"https://example.com/same" "b";
    ]
  in
  let rig =
    build ~provider:(stub ~results:(`List results) ())
      ~model:(stub_model ~content:(Some "Both say it [1][2].") ()) ()
  in
  let r = answered rig () in
  check_strings "sources" [ "https://example.com/same" ] (source_urls r)

let sources_are_in_first_citation_order () =
  let results =
    [
      result ~snippet:"s" ~url:"https://example.com/a" "a";
      result ~snippet:"s" ~url:"https://example.com/b" "b";
    ]
  in
  let rig =
    build ~provider:(stub ~results:(`List results) ())
      ~model:(stub_model ~content:(Some "Second [2], then first [1].") ()) ()
  in
  let r = answered rig () in
  check_strings "first-citation order" [ "https://example.com/b"; "https://example.com/a" ]
    (source_urls r)

(* {1 TestFailureContract} *)

let no_results_at_all_fails_without_calling_the_model () =
  let m = stub_model () in
  let rig = build ~provider:(stub ~results:(`List []) ()) ~model:m () in
  let message = failed rig () in
  check_int "no model call" 0 !(m.calls);
  includes "error" "Zero results usually means the phrasing" message

let results_with_no_usable_text_fail_without_calling_the_model () =
  let m = stub_model () in
  let rig =
    build
      ~provider:(stub ~results:(`List [ result ~url:"https://example.com/a" "t" ]) ())
      ~model:m ()
  in
  let message = failed rig () in
  check_int "no model call" 0 !(m.calls);
  includes "error" "nothing usable" message

let every_step_failing_fails_without_calling_the_model () =
  let m = stub_model () in
  let rig =
    build
      ~provider:(stub ~fail:(Provider.provider_error ~provider:"serper" "upstream 503") ())
      ~model:m ()
  in
  let message = failed rig () in
  check_int "no model call" 0 !(m.calls);
  includes "error" "upstream 503" message

let a_partial_walk_continues_and_says_which_steps_came_back_empty () =
  (* One empty step is a notice, not a failure: the rest of the walk ran. *)
  let flaky = stub () in
  let inner = !(flaky.behavior) in
  flaky.behavior
  := (fun q ->
       if q.Model.query = "rayleigh scattering" then
         Error (Provider.provider_error ~provider:"serper" "upstream 503")
       else if q.Model.query = "sky colour physics" then begin
         incr flaky.calls;
         flaky.seen := !(flaky.seen) @ [ q ];
         Ok
           {
             Provider.provider = "serper";
             results = [];
             answer = None;
             cost_usd = Some 0.007;
             notice = None;
           }
       end
       else inner q);
  let rig = build ~provider:flaky () in
  let r =
    answered rig ~extra_queries:[ "rayleigh scattering"; "sky colour physics" ]
      ~depth:Model.Report ()
  in
  check_int "the model was called once" 1 !(rig.model.calls);
  check_int "all three steps ran" 3 r.Model.searches;
  let notice = Option.value ~default:"" r.Model.notice in
  includes "notice" "1 of 3 retrieval steps returned results" notice;
  includes "notice" "step 2" notice;
  includes "notice" "step 3" notice

let a_page_that_cannot_be_read_is_a_notice_not_a_failure () =
  let local =
    fetcher_stub ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"fetch" "connection reset")) ()
  in
  let rig = build ~fetcher:local () in
  let r = answered rig ~depth:Model.Report () in
  let local_calls = match rig.local with Some l -> !(l.calls) | None -> -1 in
  check_int "the local reader was tried once" 1 local_calls;
  check_int "the model was called once" 1 !(rig.model.calls);
  check_int "no page read" 0 r.Model.fetched;
  includes "notice" "1 of 1 pages could not be read" (Option.value ~default:"" r.Model.notice)

let the_plan_asks_for_the_walk_a_caller_is_denied () =
  (* [fetch.auto_fallback] is off, and [answer] still walks: between the plan's
     steps there is no caller to act on a list of provider names. *)
  let results = [ result ~snippet:"s" ~url:"https://example.com/1" "r1" ] in
  let local =
    fetcher_stub ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"fetch" "connection reset")) ()
  in
  let fallback = fetcher_stub ~name:"jina" ~text:(String.make 220 'x' ^ " The page a browser could read.") () in
  let rig =
    build ~provider:(stub ~results:(`List results) ()) ~fetcher:local ~fallbacks:[ fallback ] ()
  in
  let r = answered rig ~depth:Model.Report () in
  let local_calls = match rig.local with Some l -> !(l.calls) | None -> -1 in
  let fallback_calls =
    match rig.fallbacks with
    | [ f ] -> !(f.calls)
    | _ -> -1
  in
  check_int "the local reader was tried" 1 local_calls;
  check_int "the fallback walked" 1 fallback_calls;
  check_int "fetched" 1 r.Model.fetched;
  includes "material" "The page a browser could read." (material rig.model)

let a_model_5xx_is_a_clean_error_with_the_status () =
  let m = stub_model ~status:503 () in
  let rig = build ~model:m () in
  let message = failed rig () in
  check_int "the model was called" 1 !(m.calls);
  includes "error" "HTTP 503" message;
  excludes "the upstream body never reaches the caller" "upstream said no" message

let a_model_timeout_names_the_model_and_the_phase () =
  let m = stub_model ~timeout:true () in
  let rig =
    build ~tweak_agent:(fun a -> { a with Config.model_timeout_seconds = 0.05 }) ~model:m ()
  in
  let message = failed rig () in
  includes "error" "test-model" message;
  includes "error" "did not answer within" message;
  excludes "the exception's own text never reaches the caller" "the read timed out" message

let an_empty_completion_is_an_error_not_an_invented_answer () =
  let rig = build ~model:(stub_model ~content:(Some "   ") ()) () in
  let message = failed rig () in
  includes "error" "no prose" message

let a_body_that_is_not_json_is_a_clean_error () =
  let rig = build ~model:(stub_model ~body:(Some "<html>not json</html>") ()) () in
  let message = failed rig () in
  includes "error" "not JSON" message

let the_whole_call_is_bounded_by_timeout_seconds () =
  let m = stub_model ~delay:0.2 () in
  let rig =
    build
      ~tweak_agent:(fun a ->
        { a with Config.timeout_seconds = 0.05; model_timeout_seconds = 30.0 })
      ~model:m ()
  in
  let message = failed rig () in
  includes "error" "exceeded 0.05s" message;
  includes "error" "calling the model" message;
  check_bool "the stubbed model call moved the clock" true (!(rig.mono) > 1768478400.);
  let line = one_answer_line rig in
  check_string "the journal names the timeout class" "TimeoutError" (str (get "error" line))

let a_retrieval_spend_past_the_money_ceiling_aborts_the_call () =
  (* The early exit: it stops the walk, and the model is never called. *)
  let m = stub_model () in
  let rig =
    build
      ~tweak_agent:(fun a ->
        {
          a with
          Config.max_cost_usd = Some 0.001;
          cost_per_1k_in = Some 0.00014;
          cost_per_1k_out = Some 0.00028;
        })
      ~provider:(stub ~cost_usd:(Some 0.007) ())
      ~model:m ()
  in
  let message = failed rig ~depth:Model.Report () in
  check_int "no model call" 0 !(m.calls);
  check_int "one step ran" 1 !(rig.provider.calls);
  includes "error" "per-call ceiling" message

let an_unconfigured_agent_names_what_is_missing () =
  let m = stub_model () in
  let rig =
    build
      ~tweak_agent:(fun a -> { a with Config.base_url = None; model = None })
      ~model:m ()
  in
  (* [build] sets the key the way the autouse fixture does; this case clears it
     after the rig exists, and an empty value reads as absent. *)
  Unix.putenv "SEEKWRIGHT_AGENT_API_KEY" "";
  let message = failed rig () in
  Unix.putenv "SEEKWRIGHT_AGENT_API_KEY" "sk-test-key";
  check_int "no model call" 0 !(m.calls);
  includes "error" "agent.base_url" message;
  includes "error" "agent.model" message;
  includes "error" "SEEKWRIGHT_AGENT_API_KEY" message

(* {1 TestTheAllowList} *)

let an_unpermitted_pin_fails_before_the_model_call () =
  (* Agent mode's retrieval *is* the search path, so a pinned provider the
     permission set excludes fails the retrieval step — before any model call. *)
  let m = stub_model () in
  let rig = build ~permitted:[ "linkup" ] ~model:m () in
  let message = failed rig ~provider:"serper" () in
  check_int "no model call" 0 !(m.calls);
  check_int "the provider was never dialed" 0 !(rig.provider.calls);
  includes "error" "Provider 'serper' is not permitted on this server" message;
  includes "error" "Permitted: linkup" message

(* {1 TestUsageAccounting} *)

let the_endpoints_usage_becomes_the_journal_line () =
  let rig =
    build
      ~tweak_agent:(fun a ->
        { a with Config.cost_per_1k_in = Some 0.00014; cost_per_1k_out = Some 0.00028 })
      ~model:(stub_model ~content:(Some "Cited [1].") ~usage:(Some (1000, 500)) ())
      ()
  in
  ignore (answered rig ());
  let line = one_answer_line rig in
  let keys =
    List.sort String.compare
      (match line with
      | `Assoc kvs -> List.map fst kvs
      | _ -> A.failf "the answer line is not an object")
  in
  check_strings "the answer line's whole field set"
    (List.sort String.compare
       [
         "ts"; "tool"; "run"; "model"; "depth"; "searches"; "results"; "fetched";
         "material_chars"; "prompt_tokens"; "completion_tokens"; "answer_chars"; "cited";
         "cited_invalid"; "sources"; "model_cost_usd"; "ms"; "error";
       ])
    keys;
  check_string "model" "test-model" (str (get "model" line));
  check_int "prompt_tokens" 1000 (int (get "prompt_tokens" line));
  check_int "completion_tokens" 500 (int (get "completion_tokens" line));
  check_int "answer_chars" 10 (int (get "answer_chars" line));
  check_int "cited" 1 (int (get "cited" line));
  check_int "cited_invalid" 0 (int (get "cited_invalid" line));
  check_int "sources" 1 (int (get "sources" line));
  A.(check (float 1e-9)) "model_cost_usd" (float_of (get "model_cost_usd" line))
    (0.00014 +. 0.00028 /. 2.);
  check_bool "error is null" true (is_null (get "error" line));
  (* The run id is a random 16-hex-char id, never a hash of the query. *)
  let run = str (get "run" line) in
  check_int "run id length" 16 (String.length run);
  if
    String.exists (fun c -> not ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) run
  then A.failf "the run id is not hex: %S" run

let an_endpoint_with_no_usage_reports_null_never_zero () =
  let rig =
    build
      ~tweak_agent:(fun a ->
        { a with Config.cost_per_1k_in = Some 0.00014; cost_per_1k_out = Some 0.00028 })
      ~model:(stub_model ~usage:None ())
      ()
  in
  ignore (answered rig ());
  let line = one_answer_line rig in
  check_bool "prompt_tokens is null" true (is_null (get "prompt_tokens" line));
  check_bool "completion_tokens is null" true (is_null (get "completion_tokens" line));
  check_bool "model_cost_usd is null" true (is_null (get "model_cost_usd" line))

let unset_prices_record_the_cost_as_unknown () =
  (* Counted, not priced — an invented figure is worse than an honest null. *)
  let rig = build ~model:(stub_model ~usage:(Some (1000, 500)) ()) () in
  ignore (answered rig ());
  let line = one_answer_line rig in
  check_int "prompt_tokens" 1000 (int (get "prompt_tokens" line));
  check_bool "model_cost_usd is null" true (is_null (get "model_cost_usd" line))

let finish_reason_length_sets_truncated () =
  let rig = build ~model:(stub_model ~finish_reason:"length" ()) () in
  let r = answered rig () in
  check_opt_bool "truncated" (Some true) r.Model.truncated

let a_complete_answer_does_not_serialise_truncated () =
  let rig = build () in
  let r = answered rig () in
  check_opt_bool "truncated is absent" None r.Model.truncated;
  match Model.answer_response_to_yojson r with
  | `Assoc kvs ->
    if List.mem_assoc "truncated" kvs then A.failf "truncated serialised on a complete answer"
  | _ -> A.failf "the response did not encode to an object"

let the_retrieval_lines_carry_the_run_and_the_step () =
  let rig = build () in
  ignore (answered rig ~extra_queries:[ "rayleigh scattering" ] ~depth:Model.Report ());
  let answer = one_answer_line rig in
  (* The [recent] deque is newest-first; the steps read oldest-first. *)
  let searches = List.rev (lines_of rig "search") in
  let fetches = List.rev (lines_of rig "fetch") in
  check_ints "search steps" [ 1; 2 ] (List.map (fun l -> int (get "step" l)) searches);
  check_bool "every search line carries the run" true
    (List.for_all (fun l -> str (get "run" l) = str (get "run" answer)) searches);
  check_ints "fetch steps" [ 1; 2 ] (List.map (fun l -> int (get "step" l)) fetches);
  check_bool "every fetch line carries the run" true
    (List.for_all (fun l -> str (get "run" l) = str (get "run" answer)) fetches);
  check_int "searches" 2 (int (get "searches" answer));
  check_int "fetched" 2 (int (get "fetched" answer))

let the_journal_counts_the_citations_the_prose_made () =
  let rig =
    build ~model:(stub_model ~content:(Some "One [1], an invented [7] and a stray [x].") ()) ()
  in
  ignore (answered rig ());
  let line = one_answer_line rig in
  check_int "cited" 1 (int (get "cited" line));
  check_int "cited_invalid" 2 (int (get "cited_invalid" line));
  check_int "sources is the URL-deduplicated count" 1 (int (get "sources" line))

let a_failed_model_call_still_records_the_retrieval () =
  let rig = build ~model:(stub_model ~status:500 ()) () in
  ignore (failed rig ());
  let searches = lines_of rig "search" in
  check_int "one search line" 1 (List.length searches);
  let line = one_answer_line rig in
  check_string "error class" "AgentFailed" (str (get "error" line));
  check_bool "prompt_tokens is null" true (is_null (get "prompt_tokens" line));
  check_bool "answer.failed is a warning" true
    (List.exists
       (fun (c : captured) -> c.event = "answer.failed" && c.level = Config.Log_warning)
       !(rig.lines))

let the_prose_rides_its_own_event_behind_log_content () =
  (* [answer.ok] keeps a fixed shape; the prose is a separate, opt-in line. *)
  let rig = build ~log_content:true () in
  ignore (answered rig ());
  let ok = event rig.lines "answer.ok" in
  if List.mem_assoc "answer" ok then A.failf "answer.ok carried the prose";
  let prose = event rig.lines "agent.answer" in
  includes "agent.answer" "An answer, cited [1]." (str (field prose "answer"))

(* {1 TestSpecialTokenEscaping} *)

let the_material_the_model_receives_is_already_escaped () =
  (* The retrieval engines escape before the plan assembles the material, so the
     model endpoint gets clean text — and the prose the model writes, echoing
     the token, leaves escaped. *)
  let m = stub_model ~content:(Some "The end marker is <|endoftext|>. [1]") () in
  let provider =
    stub
      ~results:(`List [ result ~snippet:"docs quote <|endoftext|> verbatim" ~url:"https://example.com/tokens" "tokenizer docs" ])
      ()
  in
  let rig = build ~provider ~model:m () in
  let r = answered rig () in
  let mat = material rig.model in
  excludes "raw token in the material" "<|endoftext|>" mat;
  includes "escaped token in the material" ("<" ^ zwsp ^ "|endoftext|>") mat;
  check_string "the prose leaves escaped"
    ("The end marker is <" ^ zwsp ^ "|endoftext|>. [1]") r.Model.answer;
  check_string "the cited source" "tokenizer docs" (List.hd r.Model.sources).Model.source_title

let the_count_rides_answer_ok () =
  let rig =
    build ~model:(stub_model ~content:(Some "echoing <|im_start|> and [INST]") ()) ()
  in
  ignore (answered rig ());
  let ok = event rig.lines "answer.ok" in
  check_int "sanitized" 2 (int (field ok "sanitized"))

let a_clean_call_counts_zero () =
  let rig = build () in
  ignore (answered rig ());
  let ok = event rig.lines "answer.ok" in
  check_int "sanitized" 0 (int (field ok "sanitized"))

(* {1 The suites} *)

let plan_cases =
  [
    A.test_case "a brief answer runs one search and reads no pages" `Quick
      a_brief_answer_runs_one_search_and_reads_no_pages;
    A.test_case "a brief answer does not run the extra queries" `Quick
      a_brief_answer_does_not_run_the_extra_queries;
    A.test_case "a report runs every query in order" `Quick a_report_runs_every_query_in_order;
    A.test_case "every query carries the caller's filters and the fixed width" `Quick
      every_query_carries_the_callers_filters_and_the_fixed_width;
    A.test_case "both new filters reach every step of a report" `Quick
      both_new_filters_reach_every_step_of_a_report;
    A.test_case "a report reads at most three pages" `Quick a_report_reads_at_most_three_pages;
    A.test_case "a result that already carries text is not fetched" `Quick
      a_result_that_already_carries_text_is_not_fetched;
    A.test_case "a brief is grounded in a content backend's extract" `Quick
      a_brief_is_grounded_in_a_content_backends_extract;
    A.test_case "the extract is the body when a backend sends both" `Quick
      the_extract_is_the_body_when_a_backend_sends_both;
    A.test_case "the material is numbered and carries title and url" `Quick
      the_material_is_numbered_and_carries_title_and_url;
    A.test_case "the material is bounded by max_material_chars" `Quick
      the_material_is_bounded_by_max_material_chars;
    A.test_case "a report is served from snippets when fetch is off" `Quick
      a_report_is_served_from_snippets_when_fetch_is_off;
    A.test_case "the model call carries the server's own settings" `Quick
      the_model_call_carries_the_servers_own_settings;
    A.test_case "the report output cap is the report's" `Quick the_report_output_cap_is_the_reports;
  ]

let citation_cases =
  [
    A.test_case "sources hold only what the prose cited" `Quick sources_hold_only_what_the_prose_cited;
    A.test_case "an invented index is dropped, counted and named" `Quick
      an_invented_index_is_dropped_counted_and_named;
    A.test_case "an uncited answer is returned with a notice" `Quick
      an_uncited_answer_is_returned_with_a_notice;
    A.test_case "an answer whose only markers are invented names the count" `Quick
      an_answer_whose_only_markers_are_invented_names_the_count;
    A.test_case "a marker that is not a number counts as invalid" `Quick
      a_marker_that_is_not_a_number_counts_as_invalid;
    A.test_case "markdown link text is not a citation marker" `Quick
      markdown_link_text_is_not_a_citation_marker;
    A.test_case "two indices for one url collapse in sources" `Quick
      two_indices_for_one_url_collapse_in_sources;
    A.test_case "sources are in first-citation order" `Quick sources_are_in_first_citation_order;
  ]

let failure_cases =
  [
    A.test_case "no results at all fails without calling the model" `Quick
      no_results_at_all_fails_without_calling_the_model;
    A.test_case "results with no usable text fail without calling the model" `Quick
      results_with_no_usable_text_fail_without_calling_the_model;
    A.test_case "every step failing fails without calling the model" `Quick
      every_step_failing_fails_without_calling_the_model;
    A.test_case "a partial walk continues and says which steps came back empty" `Quick
      a_partial_walk_continues_and_says_which_steps_came_back_empty;
    A.test_case "a page that cannot be read is a notice, not a failure" `Quick
      a_page_that_cannot_be_read_is_a_notice_not_a_failure;
    A.test_case "the plan asks for the walk a caller is denied" `Quick
      the_plan_asks_for_the_walk_a_caller_is_denied;
    A.test_case "a model 5xx is a clean error with the status" `Quick
      a_model_5xx_is_a_clean_error_with_the_status;
    A.test_case "a model timeout names the model and the phase" `Quick
      a_model_timeout_names_the_model_and_the_phase;
    A.test_case "an empty completion is an error, not an invented answer" `Quick
      an_empty_completion_is_an_error_not_an_invented_answer;
    A.test_case "a body that is not json is a clean error" `Quick
      a_body_that_is_not_json_is_a_clean_error;
    A.test_case "the whole call is bounded by timeout_seconds" `Quick
      the_whole_call_is_bounded_by_timeout_seconds;
    A.test_case "a retrieval spend past the money ceiling aborts the call" `Quick
      a_retrieval_spend_past_the_money_ceiling_aborts_the_call;
    A.test_case "an unconfigured agent names what is missing" `Quick
      an_unconfigured_agent_names_what_is_missing;
  ]

let allow_list_cases =
  [
    A.test_case "an unpermitted pin fails before the model call" `Quick
      an_unpermitted_pin_fails_before_the_model_call;
  ]

let usage_cases =
  [
    A.test_case "the endpoint's usage becomes the journal line" `Quick
      the_endpoints_usage_becomes_the_journal_line;
    A.test_case "an endpoint with no usage reports null, never zero" `Quick
      an_endpoint_with_no_usage_reports_null_never_zero;
    A.test_case "unset prices record the cost as unknown" `Quick
      unset_prices_record_the_cost_as_unknown;
    A.test_case "finish_reason length sets truncated" `Quick finish_reason_length_sets_truncated;
    A.test_case "a complete answer does not serialise truncated" `Quick
      a_complete_answer_does_not_serialise_truncated;
    A.test_case "the retrieval lines carry the run and the step" `Quick
      the_retrieval_lines_carry_the_run_and_the_step;
    A.test_case "the journal counts the citations the prose made" `Quick
      the_journal_counts_the_citations_the_prose_made;
    A.test_case "a failed model call still records the retrieval" `Quick
      a_failed_model_call_still_records_the_retrieval;
    A.test_case "the prose rides its own event behind log_content" `Quick
      the_prose_rides_its_own_event_behind_log_content;
  ]

let escaping_cases =
  [
    A.test_case "the material the model receives is already escaped" `Quick
      the_material_the_model_receives_is_already_escaped;
    A.test_case "the count rides answer.ok" `Quick the_count_rides_answer_ok;
    A.test_case "a clean call counts zero" `Quick a_clean_call_counts_zero;
  ]

let () =
  A.run "agent"
    [
      ("the plan", plan_cases);
      ("citations", citation_cases);
      ("failure contract", failure_cases);
      ("the allow-list", allow_list_cases);
      ("usage accounting", usage_cases);
      ("special token escaping", escaping_cases);
    ]
