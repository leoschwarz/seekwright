(* F1.3: the two decision lines an operator aggregates on must keep a fixed
   shape whatever the content setting is.

   [search.ok] and [fetch.ok] are the counts-and-flags events. Content rides
   separate events ([search.result], [search.answer], [fetch.content]) behind
   [logging.log_content], so this suite pins both halves of that rule:

   - the key set of the decision line, exactly, in both settings;
   - every sentinel the caller supplied (query text, URL/path, title, snippet
     and page body) is absent from the decision line in both settings — and,
     with content logging on, present in the content event that owns it, which
     is what makes the absence a real assertion rather than a typo in a string.

   The engines are the real ones over a stub provider and a stub fetcher, the
   position [httpx.MockTransport] holds in the Python suites: no socket, no key,
   no provider contact. *)

module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module A = Alcotest
open Test_support

let clock () = 1768478400.
let now () = 1768478400.

(* Every value a caller supplied that must never reach an ordinary log line. *)
let query_sentinel = "SENTINEL_QUERY_TEXT"
let title_sentinel = "SENTINEL_TITLE"
let url_sentinel = "SENTINEL_URL"
let path_sentinel = "SENTINEL_PATH"
let snippet_sentinel = "SENTINEL_SNIPPET"
let body_sentinel = "SENTINEL_BODY"
let answer_sentinel = "SENTINEL_ANSWER"

let sentinels =
  [
    query_sentinel;
    title_sentinel;
    url_sentinel;
    path_sentinel;
    snippet_sentinel;
    body_sentinel;
    answer_sentinel;
  ]

type captured = {
  level : Config.log_level;
  event : string;
  fields : (string * Yojson.Safe.t) list;
}

let sink lines : Engine.log =
 fun level event fields -> lines := { level; event; fields } :: !lines

let events lines name =
  List.filter (fun (line : captured) -> line.event = name) lines

let only lines name =
  match events lines name with
  | [ line ] -> line
  | many ->
      A.failf "expected exactly one %s event, got %d" name (List.length many)

let keys (line : captured) =
  List.map fst line.fields |> List.sort String.compare

let rendered (line : captured) = Yojson.Safe.to_string (`Assoc line.fields)

let check_absent label text =
  List.iter
    (fun sentinel ->
      A.(check bool)
        (Printf.sprintf "%s omits %s" label sentinel)
        false
        (contains ~haystack:text ~needle:sentinel))
    sentinels

let check_present label text sentinel =
  A.(check bool)
    (Printf.sprintf "%s carries %s" label sentinel)
    true
    (contains ~haystack:text ~needle:sentinel)

(* {1 The search fixture} *)

let search_config ~log_content =
  let providers =
    [
      ( "exa"
      , { Config.default_provider_config with Config.enabled = true } );
    ]
  in
  match
    Config.resolve ~providers
      ~logging:{ Config.default_logging_config with Config.log_content }
      ()
  with
  | Ok config -> config
  | Error message -> A.failf "the search fixture config was refused: %s" message

let hit ?snippet ?text title url : Provider.hit =
  {
    Provider.result =
      {
        Model.title;
        url;
        snippet;
        text;
        text_truncated = None;
        published_date = None;
        score = None;
      };
    uncapped_chars = None;
  }

let search_provider () : Provider.t =
  (module struct
    let name = "exa"
    let cost_per_1k = 0.0
    let cost_for _ = 0.0

    let search _query =
      Ok
        {
          Provider.provider = name;
          results =
            [
              hit ~snippet:snippet_sentinel title_sentinel
                ("https://example.test/" ^ url_sentinel);
              hit ~text:body_sentinel ("Second " ^ title_sentinel)
                "https://example.test/second";
            ];
          answer = Some answer_sentinel;
          cost_usd = Some 0.0;
          notice = None;
        }

    let aclose () = ()
  end : Provider.S)

let query text : Model.search_query =
  {
    Model.query = text;
    max_results = 5;
    include_domains = [];
    exclude_domains = [];
    country = None;
    language = None;
    recency = None;
    safe_search = None;
  }

let search_events ~log_content =
  let lines = ref [] in
  let config = search_config ~log_content in
  let engine =
    Engine.Search.create config ~log:(sink lines)
      [ ("exa", search_provider ()) ] ~clock ~now ()
  in
  (match
     Engine.Search.search engine ~provider:"exa" (query query_sentinel)
   with
  | Ok _ -> ()
  | Error _ -> A.fail "the stub search failed");
  !lines

let search_ok_keys =
  [
    "answer";
    "cost_usd";
    "fell_back";
    "max_results";
    "mode";
    "ms";
    "notice";
    "provider";
    "qhash";
    "qlen";
    "results";
    "sanitized";
  ]

let test_search_ok_field_set_with_content_off () =
  let lines = search_events ~log_content:false in
  let ok = only lines "search.ok" in
  A.(check string) "search.ok stays at INFO" "INFO"
    (Config.show_log_level ok.level);
  A.(check (list string)) "search.ok has exactly its fixed fields" search_ok_keys
    (keys ok);
  A.(check int) "no content event is emitted when the setting is off" 0
    (List.length (events lines "search.result")
    + List.length (events lines "search.answer"));
  check_absent "search.ok" (rendered ok)

let test_search_ok_field_set_with_content_on () =
  let lines = search_events ~log_content:true in
  let ok = only lines "search.ok" in
  A.(check (list string)) "search.ok keeps the same fixed fields" search_ok_keys
    (keys ok);
  check_absent "search.ok" (rendered ok);
  (* The other half of the assertion: the sentinels exist, and the content
     events — not the decision line — are where they go. *)
  let content =
    String.concat "\n"
      (List.map rendered
         (events lines "search.result" @ events lines "search.answer"))
  in
  check_present "search.result" content title_sentinel;
  check_present "search.result" content url_sentinel;
  check_present "search.result" content snippet_sentinel;
  check_present "search.result" content body_sentinel;
  check_present "search.answer" content answer_sentinel

(* {1 The fetch fixture} *)

let fetch_config ~log_content =
  match
    Config.resolve
      ~fetch:{ Config.default_fetch_config with Config.enabled = true }
      ~logging:{ Config.default_logging_config with Config.log_content }
      ()
  with
  | Ok config -> config
  | Error message -> A.failf "the fetch fixture config was refused: %s" message

let body = body_sentinel ^ " " ^ String.make 260 'x'

let fetch_fixture : Engine.Fetch.fetcher =
  {
    Engine.Fetch.name = "http";
    cost_per_1k = None;
    fetch =
      (fun ~url ~offset:_ ~max_chars:_ ->
        Ok
          {
            Engine.Fetch.url;
            title = Some title_sentinel;
            text = body;
            content_type = Some "text/html";
            status_code = 200;
            truncated = false;
            total_chars = String.length body;
            path_addressable = false;
            image = None;
          });
    aclose = (fun () -> ());
  }

let readers : Engine.Fetch.Readers.t =
  {
    Engine.Fetch.Readers.parse_path = (fun _ -> Ok ());
    render_schema = (fun _ -> None);
    select_paths = (fun ~text:_ ~path:_ ~max_chars:_ -> ([], 0));
    select_passages = (fun ~text:_ ~query:_ ~max_chars:_ -> ([], 0));
  }

let fetch_url =
  "https://example.test/" ^ url_sentinel ^ "/" ^ path_sentinel
  ^ "?token=" ^ query_sentinel

let fetch_events ~log_content =
  let lines = ref [] in
  let config = fetch_config ~log_content in
  let engine =
    match
      Engine.Fetch.create config fetch_fixture ~readers ~log:(sink lines)
        ~clock ~now ()
    with
    | Ok engine -> engine
    | Error message -> A.failf "the fetch engine refused the fixture: %s" message
  in
  (match Engine.Fetch.fetch engine ~structure:false fetch_url with
  | Ok _ -> ()
  | Error (Engine.Fetch.Refused message) ->
      A.failf "the fixture fetch was refused: %s" message
  | Error (Engine.Fetch.Failed message) ->
      A.failf "the fixture fetch failed: %s" message);
  !lines

let fetch_ok_keys =
  [
    "cached";
    "chars";
    "fell_back";
    "host";
    "ms";
    "sanitized";
    "status";
    "truncated";
  ]

let test_fetch_ok_field_set_with_content_off () =
  let lines = fetch_events ~log_content:false in
  let ok = only lines "fetch.ok" in
  A.(check (list string)) "fetch.ok has exactly its fixed fields" fetch_ok_keys
    (keys ok);
  A.(check int) "no content event is emitted when the setting is off" 0
    (List.length (events lines "fetch.content"));
  check_absent "fetch.ok" (rendered ok)

let test_fetch_ok_field_set_with_content_on () =
  let lines = fetch_events ~log_content:true in
  let ok = only lines "fetch.ok" in
  A.(check (list string)) "fetch.ok keeps the same fixed fields" fetch_ok_keys
    (keys ok);
  check_absent "fetch.ok" (rendered ok);
  let content =
    String.concat "\n" (List.map rendered (events lines "fetch.content"))
  in
  check_present "fetch.content" content title_sentinel;
  check_present "fetch.content" content body_sentinel

let () =
  A.run "log-field-sets"
    [
      ( "search.ok",
        [
          A.test_case "fixed fields, content logging off" `Quick
            test_search_ok_field_set_with_content_off;
          A.test_case "fixed fields, content logging on" `Quick
            test_search_ok_field_set_with_content_on;
        ] );
      ( "fetch.ok",
        [
          A.test_case "fixed fields, content logging off" `Quick
            test_fetch_ok_field_set_with_content_off;
          A.test_case "fixed fields, content logging on" `Quick
            test_fetch_ok_field_set_with_content_on;
        ] );
    ]
