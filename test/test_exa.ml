(* Exa: the block-format parser, the one tool call behind an MCP session, and
   the free-before-key ladder the billed name runs.

   The parser and the ladder are separate risk surfaces and so are separate
   suites here: the parser is the only thing standing between a caller and
   dropped results, since the endpoint answers in formatted plain text and leaves
   [structuredContent] empty; the ladder is about money, in that one endpoint
   answers both anonymously (free) and authenticated (~$7/1k), so which
   credential served a search {i is} the cost of that search.

   The oracle swaps its two fallbacks on the instance with [monkeypatch] because a
   constructor parameter no production caller passes would be scaffolding. This
   port cannot swap what the builder closed over, and it does not
   need to: {!Seekwright.Provider.Net.t} sits where the MCP client's transport
   does, so the ladder runs end to end over a scripted endpoint that answers the
   handshake and then hands out tool replies per credential — the anonymous caller
   and the keyed one are told apart by the [authorization] header the client adds,
   which is the same fact the real endpoint bills on. The counts these cases
   assert are therefore the calls that would have gone out.

   [~now] is the ladder's monotonic clock, injected: the cooldown deadline is a
   reading plus a duration, and a suite that moved a wall clock would not prove
   the immunity to a clock adjustment that made it monotonic in the first place.

   The upstream-answer rows — [isError], the quota sniff, an HTTP status, a dead
   session's one reconnect — are the client's fixed vocabulary and are pinned once
   for both MCP adapters by test_mcp_client.ml. What stays here is what the adapter
   and the ladder make of those sentences.

   The wiring cases from those suites — which name builds under which config —
   belong to the registry and config suites: an adapter never decides whether it
   is enabled. *)

module Caps = Mcp_caps
module Config = Seekwright.Config
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Exa = Seekwright_providers.Exa
module A = Alcotest
open Test_support

let query ?(text = "write-ahead logging") ?(max_results = 5) ?(include_domains = [])
    ?(exclude_domains = []) ?country ?language ?recency ?safe_search () : Model.search_query =
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

(* Never sent anywhere real: the string a leak would carry. *)
let test_key = "test-key"

(* No real endpoint: this port's grants are built elsewhere and pinned elsewhere,
   and the fixture's net never dials. *)
let fixture_uri = Uri.of_string "https://mcp.exa.invalid/mcp"

let hd label = function
  | x :: _ -> x
  | [] -> A.failf "%s was empty" label

let nth label index xs =
  match List.nth_opt xs index with
  | Some x -> x
  | None -> A.failf "%s has no item %d" label index

(* Copied from the oracle's suite, which captured them from
   [https://mcp.exa.ai/mcp]: plain formatted text, an empty [structuredContent],
   [Title: N/A] for a page it could not name, and [...] elisions between highlight
   sentences. *)
let sample =
  {|Title: Write-Ahead Logging
URL: https://www.sqlite.org/wal.html
Published: 2026-04-13T00:00:00.000Z
Author: N/A
Highlights:
The default method by which SQLite implements atomic commit is a rollback journal.
...
The WAL approach inverts this. The original content is preserved in the database.
Title: SQLite WAL mode explained
URL: https://example.com/wal-explained
Published: N/A
Author: Someone
Highlights:
WAL allows readers and one writer to proceed concurrently.
|}

let untitled =
  {|Title: N/A
URL: https://example.com/no-title
Highlights:
# What is the Model Context Protocol?
|}

let parse ?(text_chars = 2000) ?(limit = 10) text = Exa.parse ~text_chars text ~limit

let the_block_format_becomes_results () =
  let hits = parse sample in
  check_int "two records" 2 (List.length hits);
  check_string "the title" "Write-Ahead Logging" (hd "results" hits).result.title;
  check_string "the url" "https://www.sqlite.org/wal.html" (hd "results" hits).result.url;
  check_string "the second url" "https://example.com/wal-explained"
    (nth "results" 1 hits).result.url

let a_published_stamp_keeps_its_iso_day () =
  let hits = parse sample in
  check_opt_string "the leading ten characters" (Some "2026-04-13")
    (hd "results" hits).result.published_date;
  (* [Published: N/A] is Exa saying it could not read a date, not a date whose
     leading ten characters happen to be [N/A]. *)
  check_opt_string "an unread date stays absent" None (nth "results" 1 hits).result.published_date

let highlights_join_into_text_and_elisions_do_not () =
  let hit = hd "results" (parse sample) in
  let text = Option.get hit.result.text in
  includes "the first highlight sentence" "rollback journal" text;
  includes "the continuation line under it" "original content is preserved" text;
  (* The [...] separators Exa emits are noise, and a bare one belongs to neither
     body field. *)
  excludes "no elision survives" "..." text

let a_content_backend_fills_text_and_never_a_snippet () =
  let hits = parse sample in
  List.iter
    (fun (hit : Provider.hit) ->
      check_bool "text is filled" true (hit.result.text <> None);
      check_opt_string "the snippet is not" None hit.result.snippet)
    hits

let the_cap_bites_flags_and_measures_what_it_dropped () =
  let hit = hd "results" (parse ~text_chars:40 sample) in
  let text = Option.get hit.result.text in
  check_bool "the clipped extract fits the cap and its slack" true (String.length text <= 60);
  A.(check (option bool) "the flag rides" (Some true) hit.result.text_truncated);
  (* [search.cap] reads the pre-cap length; it never reaches the wire. *)
  check_bool "the discarded length is measured" true
    (match hit.uncapped_chars with Some n -> n > String.length text | None -> false)

let a_short_extract_is_neither_cut_nor_flagged () =
  let hit = nth "results" 1 (parse ~text_chars:10_000 sample) in
  let text = "WAL allows readers and one writer to proceed concurrently." in
  check_opt_string "the text verbatim" (Some text) hit.result.text;
  (* Omitted rather than [false]: "nothing was cut" is the uninteresting case, and
     every serialised field costs the caller context. *)
  A.(check (option bool) "no flag" None hit.result.text_truncated);
  check_opt_int "and the denominator is still measured" (Some (String.length text))
    hit.uncapped_chars

let an_untitled_record_is_titled_by_its_url_and_kept () =
  let hits = parse untitled in
  check_int "the record survives" 1 (List.length hits);
  check_string "the url is a worse title than the page's own, but a true one"
    "https://example.com/no-title" (hd "results" hits).result.title;
  includes "and its body is not lost" "Model Context Protocol"
    (Option.get (hd "results" hits).result.text)

let the_limit_stops_the_scan () =
  check_int "one record" 1 (List.length (parse ~limit:1 sample))

let a_record_without_a_url_is_not_a_result () =
  check_int "a title, an author and highlights do not make a result" 0
    (List.length (parse "Title: No URL here\nAuthor: X\nHighlights:\nsomething\n"));
  check_int "empty input" 0 (List.length (parse ""));
  check_int "garbage input does not raise" 0 (List.length (parse "total nonsense\nwith no fields"))

let the_published_price_is_a_subscription_plus_a_rung () =
  check_number "up to ten results" 0.007 (Exa.cost_for ~cost_per_1k:7.00 10);
  check_number "one result" 0.007 (Exa.cost_for ~cost_per_1k:7.00 1);
  check_number "and ~$1/1k for each result past ten" 0.012 (Exa.cost_for ~cost_per_1k:7.00 15);
  check_number "at twenty" 0.017 (Exa.cost_for ~cost_per_1k:7.00 20)

let a_free_session_costs_nothing_at_any_count () =
  (* The per-result surcharge must not invent a price for the tier that cannot
     bill. *)
  check_number "zero at one result" 0.0 (Exa.cost_for ~cost_per_1k:0.0 1);
  check_number "zero at twenty" 0.0 (Exa.cost_for ~cost_per_1k:0.0 20)

let the_endpoint_and_the_tool () =
  check_string "one documented endpoint" "https://mcp.exa.ai/mcp" (Uri.to_string Exa.default_uri);
  check_string "one advertised tool" "web_search_exa" Exa.tool_name

(* Where [httpx.MockTransport] and the oracle's stub session both sit: the request
   is recorded and the reply canned, so nothing is dialed while the session
   lifecycle the client owns still runs for real. [initialize] is answered, the
   acknowledgement accepted, and each [tools/call] takes the next reply the case
   queued for the credential that sent it. Running out of replies fails the case
   rather than inventing one: how many replies a script hands out {i is} the
   billing assertion. *)

type reply =
  | Text of string  (** a tool result with text, [isError] false *)
  | Tool_error of string  (** [isError] true: the client's vocabulary decides *)
  | Http of int  (** an HTTP status with no JSON-RPC answer *)

(* One dial: the JSON-RPC method (or [DELETE] for the close), whether the caller
   presented a credential, and the request. *)
type dial = string * bool * Caps.Authority.Net.request

type endpoint = {
  dials : dial list ref;  (** in send order *)
  net : Provider.Net.t;
}

let is_keyed (request : Caps.Authority.Net.request) =
  List.exists
    (fun (name, _value) -> String.lowercase_ascii name = "authorization")
    request.Caps.Authority.Net.headers

let jsonrpc = Yojson.Safe.to_string

let tool_reply ~id text ~is_error =
  jsonrpc
    (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int id);
          ( "result"
          , `Assoc
              [
                ("content", `List [ `Assoc [ ("type", `String "text"); ("text", `String text) ] ]);
                ("isError", `Bool is_error);
              ] );
        ])

let initialize_reply ~id =
  jsonrpc
    (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int id);
          ( "result"
          , `Assoc
              [
                ("protocolVersion", `String "2025-06-18");
                ("capabilities", `Assoc []);
                ("serverInfo", `Assoc [ ("name", `String "fixture"); ("version", `String "1") ]);
              ] );
        ])

let respond ?(headers = []) ?(body = "") status =
  { Caps.Authority.Net.status; headers; body }

let json_headers = [ ("content-type", "application/json") ]

let endpoint ?(session_id = "fixture-session") ?(free = []) ?(keyed = []) () =
  let free = ref free and keyed = ref keyed in
  let dials = ref [] in
  let take queue who =
    match !queue with
    | [] -> A.failf "the scripted %s tier ran out of replies" who
    | next :: rest ->
        queue := rest;
        next
  in
  let net =
    {
      Provider.Net.request =
        (fun (request : Caps.Authority.Net.request) ->
          match request.Caps.Authority.Net.body with
          | None ->
              (* The close half: the client terminates its session with DELETE and
                 ignores whatever comes back. *)
              dials := ("DELETE", is_keyed request, request) :: !dials;
              Ok (respond 204)
          | Some raw ->
              let message = Yojson.Safe.from_string raw in
              let meth = Option.value ~default:"" (Provider.Json.string_field "method" message) in
              let id = match Provider.Json.field "id" message with `Int id -> id | _ -> 0 in
              let keyed_call = is_keyed request in
              dials := (meth, keyed_call, request) :: !dials;
              match meth with
              | "initialize" ->
                  Ok (respond
                        ~headers:(json_headers @ [ ("mcp-session-id", session_id) ])
                        ~body:(initialize_reply ~id) 200)
              | "notifications/initialized" -> Ok (respond 202)
              | "tools/call" ->
                  (match take (if keyed_call then keyed else free)
                   (if keyed_call then "keyed" else "free") with
                  | Text text ->
                      Ok (respond ~headers:json_headers ~body:(tool_reply ~id text ~is_error:false) 200)
                  | Tool_error text ->
                      Ok (respond ~headers:json_headers ~body:(tool_reply ~id text ~is_error:true) 200)
                  | Http status -> Ok (respond status))
              | other -> A.failf "the scripted endpoint was asked for %S" other);
    }
  in
  { dials; net }

let dials ep ?meth ?keyed () =
  List.filter
    (fun (name, is_keyed, _request) ->
      (match meth with Some want -> name = want | None -> true)
      && match keyed with Some want -> is_keyed = want | None -> true)
    (List.rev !(ep.dials))

let dial_methods ep = List.map (fun (meth, _, _) -> meth) (List.rev !(ep.dials))

let count ?meth ?keyed ep = List.length (dials ep ?meth ?keyed ())

let body_json (request : Caps.Authority.Net.request) =
  match request.Caps.Authority.Net.body with
  | Some text -> Yojson.Safe.from_string text
  | None -> A.failf "the request carried no body"

let header (request : Caps.Authority.Net.request) name =
  List.find_map
    (fun (key, value) -> if String.lowercase_ascii key = name then Some value else None)
    request.Caps.Authority.Net.headers

let mcp_session ?cost_per_1k ?(name = "exa") ?auth ep =
  Exa.make_mcp ?cost_per_1k ~name ?auth ~uri:fixture_uri ~net:ep.net ()

let free_session ep = mcp_session ~name:"exa:free" ep

let succeeded what = function
  | Ok outcome -> outcome
  | Error failure -> A.failf "%s failed: %s" what (Provider.render_error failure)

let failed what = function
  | Error failure -> failure
  | Ok (outcome : Provider.outcome) ->
      A.failf "%s was expected to fail; it returned %d results" what (List.length outcome.results)

let search_what what session q = succeeded what (Provider.search session.Provider.adapter q)
let search session q = search_what "the search" session q

let the_advertised_arguments_only () =
  (* The tool advertises [query] and [numResults] and nothing else
     ([additionalProperties: false]), which is why no caller constraint can reach
     this endpoint and why {!Provider.ignored_constraints} files a notice. *)
  let ep = endpoint ~free:[ Text sample ] () in
  let session = free_session ep in
  ignore (search session (query ~max_results:3 ()));
  let (_meth, _keyed, request) = hd "tools/call" (dials ep ~meth:"tools/call" ()) in
  let message = body_json request in
  let params = Provider.Json.field "params" message in
  check_string "the tool named is the advertised one" Exa.tool_name
    (Option.get (Provider.Json.string_field "name" params));
  let args = Provider.Json.field "arguments" params in
  check_string "the query rides as advertised" "write-ahead logging"
    (Option.get (Provider.Json.string_field "query" args));
  check_int "with the result count" 3
    (match Provider.Json.field "numResults" args with `Int n -> n | _ -> 0);
  check_int "and no filter argument appears" 2
    (List.length (Provider.Json.members args |> Option.value ~default:[]))

let a_search_shakes_hands_then_calls_the_tool () =
  let ep = endpoint ~free:[ Text sample ] () in
  let outcome = search (free_session ep) (query ()) in
  check_strings "handshake, acknowledgement, call"
    [ "initialize"; "notifications/initialized"; "tools/call" ]
    (dial_methods ep);
  let (_meth, _keyed, request) = hd "tools/call" (dials ep ~meth:"tools/call" ()) in
  check_string "the endpoint the grant allows" (Uri.to_string fixture_uri)
    (Uri.to_string request.Caps.Authority.Net.uri);
  check_bool "an anonymous session sends no credential" true
    (header request "authorization" = None);
  check_string "the session reports the name it was built as" "exa:free" outcome.provider;
  check_int "the parser ran over the text block" 2 (List.length outcome.results);
  check_opt_number "a free session prices itself at zero" (Some 0.0) outcome.cost_usd

let a_keyed_session_carries_the_bearer_token () =
  let ep = endpoint ~keyed:[ Text sample ] () in
  ignore (search (mcp_session ~auth:test_key ep) (query ()));
  List.iteri
    (fun i (_meth, _keyed, request) ->
      check_string (Printf.sprintf "every request authenticates (%d)" i)
        (Printf.sprintf "Bearer %s" test_key)
        (Option.get (header request "authorization")))
    (List.rev !(ep.dials));
  check_int "and the keyed half is the one that answered" 1 (count ~meth:"tools/call" ~keyed:true ep)

let a_keyed_session_reports_the_billed_price () =
  let ep = endpoint ~keyed:[ Text sample ] () in
  let outcome = search (mcp_session ~auth:test_key ~cost_per_1k:7.00 ep) (query ~max_results:20 ()) in
  check_opt_number "twenty results at the published shape" (Some 0.017) outcome.cost_usd

let a_dropped_filter_is_named () =
  (* Nothing filters it out before dispatch, so a caller that passed a filter has
     to be told it did not apply: unfiltered results the caller knows about beat
     filtered-looking ones it does not. *)
  let ep = endpoint ~free:[ Text sample ] () in
  let outcome = search (free_session ep) (query ~include_domains:[ "sqlite.org" ] ~country:"de" ()) in
  let notice = Option.get outcome.notice in
  includes "the domain bucket" "domain" notice;
  includes "the geo bucket" "country/language" notice;
  check_bool "and the parsed results are unaffected" true (outcome.results <> [])

let an_unconstrained_query_gets_no_notice () =
  let ep = endpoint ~free:[ Text sample ] () in
  check_opt_string "nothing was dropped, so nothing is said" None
    (search (free_session ep) (query ())).notice

let warmup_opens_the_session_and_calls_nothing () =
  let ep = endpoint () in
  let session = free_session ep in
  check_bool "the handshake completes" true (session.Provider.warmup ());
  check_strings "handshake only"
    [ "initialize"; "notifications/initialized" ]
    (dial_methods ep);
  check_int "no tool call" 0 (count ~meth:"tools/call" ep)

let a_warm_session_gives_its_first_search_one_handshake () =
  let ep = endpoint ~free:[ Text sample ] () in
  let session = free_session ep in
  ignore (session.Provider.warmup ());
  let outcome = search session (query ()) in
  check_int "one handshake for the warmup and the search" 1 (count ~meth:"initialize" ep);
  check_int "and the results are there" 2 (List.length outcome.results)

let close_terminates_the_session_and_refuses_after () =
  let ep = endpoint ~free:[ Text sample ] () in
  let session = free_session ep in
  ignore (search session (query ()));
  Provider.aclose session.Provider.adapter;
  check_int "the DELETE went out" 1 (count ~meth:"DELETE" ep);
  match Provider.search session.Provider.adapter (query ()) with
  | Ok _ -> A.failf "a closed session answered"
  | Error failure -> check_string "the closed row" "MCP client is closed" failure.message

let tiered ?(cooldown = 60.0) ?(now = fun () -> 1_000.0) ?log ?(cost_per_1k = 7.00) ep =
  Exa.make_tiered ~cost_per_1k ~cooldown_seconds:cooldown ~now ?log ~key:test_key ~uri:fixture_uri
    ~net:ep.net ()

let ladder ?asked session =
  Provider.search session.Provider.adapter (Option.value ~default:(query ()) asked)

let a_healthy_free_tier_is_never_billed () =
  let ep = endpoint ~free:[ Text sample ] () in
  let outcome = succeeded "the ladder" (ladder (tiered ep)) in
  check_int "a working free tier never reaches the API key" 0 (count ~meth:"tools/call" ~keyed:true ep);
  check_opt_number "the free tier answers zero" (Some 0.0) outcome.cost_usd;
  check_opt_string "nothing happened worth warning about" None outcome.notice;
  check_string "which fallback ran is a cost detail, not another backend" "exa" outcome.provider

let a_failed_free_tier_is_retried_on_the_key () =
  let ep = endpoint ~free:[ Tool_error "429 rate limited" ] ~keyed:[ Text sample ] () in
  let outcome = succeeded "the ladder" (ladder (tiered ep)) in
  check_int "the key was billed once" 1 (count ~meth:"tools/call" ~keyed:true ep);
  check_int "and the escalation returned something" 2 (List.length outcome.results);
  check_opt_number "the billed figure is what the caller is quoted" (Some 0.007) outcome.cost_usd;
  (* An invoice is a bad way to find out the free tier stopped working. *)
  check_string "the escalation is announced with its reason"
    "free tier unavailable (rate limited), so this call used the API key"
    (Option.get outcome.notice)

let any_free_failure_escalates_not_only_a_classified_quota () =
  (* Exa's wording for exhaustion has never been observed, so the ladder must not
     depend on the sniff being right: a misclassification costs one paid search,
     not the tier. *)
  let ep = endpoint ~free:[ Tool_error "the tool broke sideways" ] ~keyed:[ Text sample ] () in
  ignore (succeeded "the ladder" (ladder (tiered ep)));
  check_int "escalated on an unclassified failure" 1 (count ~meth:"tools/call" ~keyed:true ep)

let a_dropped_filter_warning_survives_the_escalation () =
  (* [ignored_constraints] owns this field too, so overwriting it would leave a
     caller unwarned that its domain filter was never applied. *)
  let ep = endpoint ~free:[ Tool_error "upstream MCP tool reported an error" ] ~keyed:[ Text sample ] () in
  let outcome =
    succeeded "the ladder" (ladder ~asked:(query ~include_domains:[ "sqlite.org" ] ()) (tiered ep))
  in
  let notice = Option.get outcome.notice in
  includes "the adapter's own notice" "cannot filter by domain" notice;
  includes "and the escalation" "so this call used the API key" notice;
  check_string "the two halves are joined, not substituted"
    "cannot filter by domain; that constraint was ignored; free tier unavailable \
     (upstream MCP tool reported an error), so this call used the API key"
    notice

let the_key_is_billed_at_most_once_per_search () =
  let ep = endpoint ~free:[ Tool_error "nope" ] ~keyed:[ Text sample ] () in
  ignore (succeeded "the ladder" (ladder (tiered ep)));
  check_int "one search never buys two" 1 (count ~meth:"tools/call" ~keyed:true ep)

let both_fallbacks_down_reports_the_free_failure_first () =
  let ep =
    endpoint ~free:[ Tool_error "429 rate limited" ] ~keyed:[ Tool_error "the tool broke" ] ()
  in
  let failure = failed "the ladder" (ladder (tiered ep)) in
  (* Appended, never substituted: an operator debugging this needs to know the key
     was tried and what it said, while the failure the caller hit first is the one
     that explains the search. *)
  check_string "both halves, free first"
    "rate limited; the API key also failed (upstream MCP tool reported an error)"
    failure.message;
  (* [QuotaExhausted] is what makes the engine say "do not retry immediately";
     degrading it to a plain failure would invite a retry loop. *)
  check_bool "the free failure's kind is kept" true (failure.kind = Provider.Quota);
  check_bool "and its retry advice" true (not failure.retryable)

let a_keyed_http_failure_reaches_the_caller_as_itself () =
  let ep = endpoint ~free:[ Http 401 ] ~keyed:[ Http 503 ] () in
  let failure = failed "the ladder" (ladder (tiered ep)) in
  includes "the free half's sentence first" "authentication rejected" failure.message;
  includes "then the keyed half's" "HTTP 503" failure.message

let a_burned_free_tier_is_not_retried_on_every_call () =
  (* While the outage lasts, trying free first buys a doomed round trip per search
     and nothing else. *)
  let ep =
    endpoint ~free:[ Tool_error "429 rate limited" ] ~keyed:[ Text sample; Text sample ] ()
  in
  let session = tiered ~cooldown:1000.0 ep in
  ignore (succeeded "the first search" (ladder session));
  ignore (succeeded "the second search" (ladder session));
  check_int "the second call did not re-probe the free tier" 1 (count ~meth:"tools/call" ~keyed:false ep);
  check_int "and both searches were served on the key" 2 (count ~meth:"tools/call" ~keyed:true ep)

let the_cooldown_expires_and_free_is_tried_again () =
  (* Otherwise one blip converts a free deployment into a billed one until the
     process restarts. The clock is the suite's, so the deadline is moved rather
     than waited for. *)
  let now = ref 1_000.0 in
  let ep = endpoint ~free:[ Tool_error "429 rate limited"; Text sample ] ~keyed:[ Text sample ] () in
  let session = tiered ~cooldown:1000.0 ~now:(fun () -> !now) ep in
  ignore (succeeded "the escalation" (ladder session));
  now := 2_001.0;
  let outcome = succeeded "the search after the deadline" (ladder session) in
  check_int "free is back in the path" 2 (count ~meth:"tools/call" ~keyed:false ep);
  check_opt_number "and free served it, unbilled" (Some 0.0) outcome.cost_usd

let a_zero_cooldown_always_tries_free_first () =
  let ep =
    endpoint ~free:[ Tool_error "429 rate limited"; Tool_error "429 rate limited" ]
      ~keyed:[ Text sample; Text sample ]
      ()
  in
  let session = tiered ~cooldown:0.0 ep in
  ignore (succeeded "the first search" (ladder session));
  ignore (succeeded "the second search" (ladder session));
  check_int "no cooldown, no skipping" 2 (count ~meth:"tools/call" ~keyed:false ep)

let a_call_served_on_the_key_during_cooldown_says_so () =
  let now = ref 1_000.0 in
  let ep =
    endpoint ~free:[ Tool_error "429 rate limited" ] ~keyed:[ Text sample; Text sample ] ()
  in
  let session = tiered ~cooldown:1000.0 ~now:(fun () -> !now) ep in
  ignore (succeeded "the escalation" (ladder session));
  now := 1_030.0;
  let outcome = succeeded "the cooldown call" (ladder session) in
  (* Not "was rate-limited": the cooldown is set by any free-fallback failure. *)
  check_string "the cooldown is what is named"
    "free tier failed recently, so this call used the API key" (Option.get outcome.notice);
  check_opt_number "and the caller is quoted the billed figure" (Some 0.007) outcome.cost_usd

let warmup_warms_only_the_free_session () =
  (* The keyed session opens on first escalation instead, and warming it would not
     even validate the key: a rejected key still completes the MCP handshake and
     fails only at the tool call. *)
  let ep = endpoint () in
  let session = tiered ep in
  check_bool "the free session opened" true (session.Provider.warmup ());
  check_int "the free session handshook" 1 (count ~meth:"initialize" ~keyed:false ep);
  check_int "the keyed session did not" 0 (count ~meth:"initialize" ~keyed:true ep);
  check_int "and nothing was searched" 0 (count ~meth:"tools/call" ep)

let close_closes_both_fallbacks () =
  (* A leaked MCP session outlives the server. *)
  let ep = endpoint ~free:[ Tool_error "429 rate limited" ] ~keyed:[ Text sample ] () in
  let session = tiered ep in
  ignore (session.Provider.warmup ());
  ignore (succeeded "the escalation" (ladder session));
  Provider.aclose session.Provider.adapter;
  check_int "the free session closed" 1 (count ~meth:"DELETE" ~keyed:false ep);
  check_int "and the keyed one too" 1 (count ~meth:"DELETE" ~keyed:true ep)

(* The notice goes to the caller, who is not the party billed, so the same fact has
   to reach the log. These capture the sink rather than assert a rendering. *)

let sink events =
  Some
    (fun level event fields ->
      events := (level, event, fields) :: !events;
      ())

let named events name =
  List.filter (fun (_level, event, _fields) -> event = name) (List.rev !events)

let string_field fields name =
  match List.assoc_opt name fields with Some (`String value) -> value | _ -> "<absent>"

let number_field fields name =
  match List.assoc_opt name fields with Some (`Float value) -> value | _ -> nan

let the_moment_it_stops_being_free_is_a_warning () =
  let events = ref [] in
  let ep = endpoint ~free:[ Tool_error "429 rate limited" ] ~keyed:[ Text sample ] () in
  ignore (succeeded "the ladder" (ladder (tiered ?log:(sink events) ~cooldown:1000.0 ep)));
  match named events "exa.escalated" with
  | [ (level, _event, fields) ] ->
      check_bool "a warning, because this is where the deployment stopped being free" true
        (level = Config.Log_warning);
      check_string "the reason the free tier gave" "rate limited" (string_field fields "reason");
      check_number "the cooldown it set" 1000.0 (number_field fields "cooldown_s");
      check_bool "and the cost that starts now" true (number_field fields "cost_usd" > 0.0)
  | found -> A.failf "expected one exa.escalated, got %d" (List.length found)

let every_billed_call_the_cooldown_costs_is_recorded () =
  (* Without this, a burned free tier logs once and then bills in silence for as
     long as the cooldown lasts. *)
  let events = ref [] in
  let ep =
    endpoint ~free:[ Tool_error "429 rate limited" ]
      ~keyed:[ Text sample; Text sample; Text sample ]
      ()
  in
  let session = tiered ?log:(sink events) ~cooldown:1000.0 ep in
  List.iter
    (fun (_ : int) -> ignore (succeeded "a ladder call" (ladder session)))
    [ 1; 2; 3 ];
  let cooldowns = named events "exa.cooldown" in
  check_int "one line per call the cooldown billed for" 2 (List.length cooldowns);
  check_bool "each carrying its cost" true
    (List.for_all (fun (_l, _e, fields) -> number_field fields "cost_usd" > 0.0) cooldowns);
  check_bool "and a remaining time inside the cooldown" true
    (List.for_all
       (fun (_l, _e, fields) ->
         let remaining = number_field fields "remaining_s" in
         remaining > 0.0 && remaining <= 1000.0)
       cooldowns)

let a_healthy_free_tier_logs_nothing () =
  let events = ref [] in
  let ep = endpoint ~free:[ Text sample ] () in
  ignore (succeeded "the ladder" (ladder (tiered ?log:(sink events) ep)));
  check_int "no escalation" 0 (List.length (named events "exa.escalated"));
  check_int "no cooldown" 0 (List.length (named events "exa.cooldown"));
  check_int "no both-failed" 0 (List.length (named events "exa.both_failed"))

let both_fallbacks_failing_is_an_error_line () =
  let events = ref [] in
  let ep =
    endpoint ~free:[ Tool_error "429 rate limited" ] ~keyed:[ Tool_error "the tool broke" ] ()
  in
  ignore (ladder (tiered ?log:(sink events) ep));
  match named events "exa.both_failed" with
  | [ (level, _event, fields) ] ->
      check_bool "at error level" true (level = Config.Log_error);
      check_string "the keyed half" "upstream MCP tool reported an error"
        (string_field fields "reason");
      check_string "and the free half, which explains the search" "rate limited"
        (string_field fields "original_reason")
  | found -> A.failf "expected one exa.both_failed, got %d" (List.length found)

let upstream_error_text_reaches_neither_caller_nor_log () =
  (* Same third-party text, same path that has carried an API key: the log store
     is just a second place it must not land. The client's fixed vocabulary is
     what rides both paths. *)
  let events = ref [] in
  let ep = endpoint ~free:[ Tool_error "boom: Bearer sk-secret-value" ] ~keyed:[ Text sample ] () in
  let outcome = succeeded "the ladder" (ladder (tiered ?log:(sink events) ep)) in
  excludes "not in the notice" "sk-secret-value" (Option.value ~default:"" outcome.notice);
  let rendered =
    String.concat "\n"
      (List.map (fun (_l, event, fields) -> event ^ " " ^ jsonrpc (`Assoc fields)) (List.rev !events))
  in
  excludes "not in the log" "sk-secret-value" rendered;
  includes "the caller still learns which tier served" "API key"
    (Option.value ~default:"" outcome.notice)

let () =
  A.
    (run "seekwright/exa"
       [
         ( "the block-format parser"
         , [
             test_case "the block format becomes results" `Quick the_block_format_becomes_results;
             test_case "a published stamp keeps its ISO day" `Quick
               a_published_stamp_keeps_its_iso_day;
             test_case "highlights join into text, elisions do not" `Quick
               highlights_join_into_text_and_elisions_do_not;
             test_case "a content backend fills text and never a snippet" `Quick
               a_content_backend_fills_text_and_never_a_snippet;
             test_case "the cap bites, flags, and measures what it dropped" `Quick
               the_cap_bites_flags_and_measures_what_it_dropped;
             test_case "a short extract is neither cut nor flagged" `Quick
               a_short_extract_is_neither_cut_nor_flagged;
             test_case "an untitled record is titled by its url and kept" `Quick
               an_untitled_record_is_titled_by_its_url_and_kept;
             test_case "the limit stops the scan" `Quick the_limit_stops_the_scan;
             test_case "a record without a url is not a result" `Quick
               a_record_without_a_url_is_not_a_result;
           ] );
         ( "the price and the endpoint"
         , [
             test_case "the published price is a subscription plus a rung" `Quick
               the_published_price_is_a_subscription_plus_a_rung;
             test_case "a free session costs nothing at any count" `Quick
               a_free_session_costs_nothing_at_any_count;
             test_case "the endpoint and the tool" `Quick the_endpoint_and_the_tool;
           ] );
         ( "one session on one credential"
         , [
             test_case "the advertised arguments and nothing else" `Quick
               the_advertised_arguments_only;
             test_case "a search shakes hands, then calls the tool" `Quick
               a_search_shakes_hands_then_calls_the_tool;
             test_case "a keyed session carries the bearer token" `Quick
               a_keyed_session_carries_the_bearer_token;
             test_case "a keyed session reports the billed price" `Quick
               a_keyed_session_reports_the_billed_price;
             test_case "a dropped filter is named" `Quick a_dropped_filter_is_named;
             test_case "an unconstrained query gets no notice" `Quick
               an_unconstrained_query_gets_no_notice;
             test_case "warmup opens the session and calls nothing" `Quick
               warmup_opens_the_session_and_calls_nothing;
             test_case "a warm session gives its first search one handshake" `Quick
               a_warm_session_gives_its_first_search_one_handshake;
             test_case "close terminates the session and refuses after" `Quick
               close_terminates_the_session_and_refuses_after;
           ] );
         ( "the free-before-key ladder"
         , [
             test_case "a healthy free tier is never billed" `Quick
               a_healthy_free_tier_is_never_billed;
             test_case "a failed free tier is retried on the key" `Quick
               a_failed_free_tier_is_retried_on_the_key;
             test_case "any free failure escalates, not only a classified quota" `Quick
               any_free_failure_escalates_not_only_a_classified_quota;
             test_case "a dropped-filter warning survives the escalation" `Quick
               a_dropped_filter_warning_survives_the_escalation;
             test_case "the key is billed at most once per search" `Quick
               the_key_is_billed_at_most_once_per_search;
             test_case "both fallbacks down reports the free failure first" `Quick
               both_fallbacks_down_reports_the_free_failure_first;
             test_case "a keyed HTTP failure reaches the caller as itself" `Quick
               a_keyed_http_failure_reaches_the_caller_as_itself;
             test_case "a burned free tier is not retried on every call" `Quick
               a_burned_free_tier_is_not_retried_on_every_call;
             test_case "the cooldown expires and free is tried again" `Quick
               the_cooldown_expires_and_free_is_tried_again;
             test_case "a zero cooldown always tries free first" `Quick
               a_zero_cooldown_always_tries_free_first;
             test_case "a call served on the key during cooldown says so" `Quick
               a_call_served_on_the_key_during_cooldown_says_so;
             test_case "warmup warms only the free session" `Quick
               warmup_warms_only_the_free_session;
             test_case "close closes both fallbacks" `Quick close_closes_both_fallbacks;
           ] );
         ( "what the ladder logs"
         , [
             test_case "the moment it stops being free is a warning" `Quick
               the_moment_it_stops_being_free_is_a_warning;
             test_case "every billed call the cooldown costs is recorded" `Quick
               every_billed_call_the_cooldown_costs_is_recorded;
             test_case "a healthy free tier logs nothing" `Quick a_healthy_free_tier_logs_nothing;
             test_case "both fallbacks failing is an error line" `Quick
               both_fallbacks_failing_is_an_error_line;
             test_case "upstream error text reaches neither caller nor log" `Quick
               upstream_error_text_reaches_neither_caller_nor_log;
           ] );
       ])
