(* F2.4: shared state under concurrent serving.

   The port serves every MCP and REST call on its own Eio fiber, so the two
   pieces of mutable state the dashboard is built from — [Usage]'s aggregates
   plus its journal, and [Health]'s board — are reached by several operations at
   once. This suite drives that on purpose, over real loopback connections:

   - the REST projection of one [Server.app] is served on a listener built the
     way [serve_http] builds it ([Server.serve_connection] per accepted socket),
     and fake providers, a fake fetcher and a fake model endpoint answer on a
     second loopback listener through audited [Factory] grants;
   - [search], [fetch], [answer] and the health monitor's ticks all run in the
     same window, each request carrying its own marker so a response that
     answers someone else's call is a failure;
   - the assertions are order-independent and exact: the aggregate counts and
     money, one complete JSON line per terminal call, an audit event per
     low-level operation, and a dashboard read that never sees a half-applied
     record.

   This is a determinism test, not a benchmark: both clocks are constants, no
   case sleeps, and the only scheduling choice is that the health fiber is
   forked before the clients so its ticks overlap them. Every expected number is
   arithmetic over the fixture, so a different interleaving cannot change an
   answer — that is what "safe under concurrent HTTP calls" means here. *)

module Agent = Seekwright.Agent
module Caps = Mcp_caps
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Factory = Seekwright_factory.Factory
module Health = Seekwright.Health
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Server = Seekwright.Server
module Usage = Seekwright.Usage
module A = Alcotest
open Test_support

(* Both clocks are the one fixed instant, so [retrieved_at] and every [ms] are
   facts of the fixture and the day buckets are calendar-independent. *)
let clock () = 1768478400.
let now () = 1768478400.

(* {1 Reads}

   [Usage.snapshot] and the REST bodies are [Yojson.Safe.t]; these are the loose
   reads the Python suite gets from dicts. *)
let get key = function
  | `Assoc fields -> (try List.assoc key fields with Not_found -> `Null)
  | _ -> `Null

let items = function `List xs -> xs | _ -> []
let str = function `String s -> s | `Null -> "" | v -> Yojson.Safe.to_string v

let int = function
  | `Int n -> n
  | `Float f -> int_of_float f
  | v -> A.failf "not a count: %s" (Yojson.Safe.to_string v)

let money = function
  | `Int n -> float_of_int n
  | `Float f -> f
  | v -> A.failf "not a money figure: %s" (Yojson.Safe.to_string v)

(* {1 The storm's width}

   Each kind gets its own count, so a mixed response has a neighbour to be
   confused with. Six is enough to interleave without making the dashboard's
   hundred-entry recent deque the binding constraint — the consistency case
   below reads [recent] length, so staying under the cap is deliberate. *)
let searches = 6
let fetches = 6
let answers = 6
let ticks = 8

(* Markers are zero-padded so no marker is a prefix of another: a response that
   answered someone else is then a substring test that cannot misfire. *)
let marker kind i = Printf.sprintf "%s-%02d" kind i
let search_query i = marker "search" i
let fetch_url i = Printf.sprintf "https://example.test/%s" (marker "fetch" i)
let answer_query i = marker "answer" i

(* {1 The fake provider endpoint}

   One Cohttp-Eio listener answers every outbound call the fixture makes, so the
   provider, fetcher, model and health probe all travel a real loopback socket
   through their audited grants. The bodies are shaped like the contracts the
   stubs read, not like a vendor's: the stubs are the fake adapters, and this is
   the endpoint they dial. *)

type fixture = {
  port : int;
  stop : unit Eio.Promise.u;
  stopped : unit Eio.Promise.t;
}

let json_headers = Http.Header.of_list [ ("content-type", "application/json") ]

let user_turn body =
  (* The model request's user turn is the last message; the fixture echoes the
     question out of it so an answer that crossed wires is visibly another
     caller's. *)
  match Yojson.Safe.from_string body with
  | `Assoc fields -> (
    match List.assoc_opt "messages" fields with
    | Some (`List messages) -> (
      match List.rev messages with
      | `Assoc message :: _ -> (
        match List.assoc_opt "content" message with Some (`String s) -> s | _ -> "")
      | _ -> "")
    | _ -> "")
  | _ -> ""

let question_of_turn turn =
  match find_sub ~haystack:turn ~needle:"\n\nQuestion: " () with
  | None -> "unknown"
  | Some at ->
    let start = at + String.length "\n\nQuestion: " in
    let rest = String.sub turn start (String.length turn - start) in
    (match find_sub ~haystack:rest ~needle:"\n" () with
    | None -> rest
    | Some stop -> String.sub rest 0 stop)

let completion_body question =
  let content = Printf.sprintf "An answer for %s, citing [1]." question in
  `Assoc
    [
      ( "choices",
        `List
          [
            `Assoc
              [
                ("message", `Assoc [ ("content", `String content) ]);
                ("finish_reason", `String "stop");
              ];
          ] );
      ( "usage",
        `Assoc [ ("prompt_tokens", `Int 11); ("completion_tokens", `Int 7) ] );
    ]

let fixture_callback _conn request body =
  let line = Http.Request.resource request in
  let path = Uri.path (Uri.of_string line) in
  if String.ends_with ~suffix:"/chat/completions" path then begin
    let raw = Eio.Buf_read.(take_all (of_flow body ~max_size:1_000_000)) in
    let payload = completion_body (question_of_turn (user_turn raw)) in
    Cohttp_eio.Server.respond_string ~headers:json_headers ~status:`OK
      ~body:(Yojson.Safe.to_string payload) ()
  end
  else
    Cohttp_eio.Server.respond_string ~headers:json_headers ~status:`OK
      ~body:(if String.ends_with ~suffix:"/probe" path then "ok" else "") ()

let start_fixture ~env ~sw =
  let socket =
    Eio.Net.listen ~backlog:128 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> A.failf "the fixture endpoint is not a TCP socket: %s" path
  in
  let stop, fill_stop = Eio.Promise.create () in
  let stopped, fill_stopped = Eio.Promise.create () in
  let server = Cohttp_eio.Server.make ~callback:fixture_callback () in
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Promise.resolve fill_stopped ())
      (fun () ->
        Cohttp_eio.Server.run ~stop ~on_error:(fun _exn -> ()) socket server));
  { port; stop = fill_stop; stopped }

let stop_fixture fixture =
  Eio.Promise.resolve fixture.stop ();
  Eio.Promise.await fixture.stopped

(* {1 The fake adapters}

   The stub provider is the adapter stand-in, and the one thing it must do for
   this suite is reach the network: each call asks its audited grant for one
   request, so "one audit event per low-level operation" is a real property of
   the run rather than a log line this file invented. *)

type search_stub = {
  name : string;
  net : Provider.Net.t;
  port : int;
  calls : int Atomic.t;
}

let search_stub ~name ~net ~port = { name; net; port; calls = Atomic.make 0 }

let result_of_query (q : Model.search_query) : Provider.hit =
  {
    Provider.result =
      {
        Model.title = "About " ^ q.Model.query;
        url = "https://example.test/" ^ Uri.pct_encode q.Model.query;
        snippet = Some ("A snippet for " ^ q.Model.query);
        text = None;
        text_truncated = None;
        published_date = None;
        score = None;
      };
    uncapped_chars = None;
  }

let provider_of_search_stub (s : search_stub) : Provider.t =
  (module struct
    let name = s.name
    let cost_per_1k = 1.0
    let cost_for n = float_of_int n /. 1000.

    let search (q : Model.search_query) =
      ignore (Atomic.fetch_and_add s.calls 1);
      let request : Caps.Authority.Net.request =
        {
          meth = `POST;
          uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/search" s.port);
          headers = [ ("content-type", "application/json") ];
          body = Some (Yojson.Safe.to_string (`Assoc [ ("q", `String q.Model.query) ]));
        }
      in
      match s.net.Provider.Net.request request with
      | Error _ -> Error (Provider.provider_error ~provider:s.name "the fake endpoint refused")
      | Ok response when response.Caps.Authority.Net.status = 200 ->
        Ok
          {
            Provider.provider = s.name;
            results = [ result_of_query q ];
            answer = None;
            (* One thousandth of a dollar per call: the aggregate case's money
               is then exact arithmetic over the call count. *)
            cost_usd = Some 0.001;
            notice = None;
          }
      | Ok _ -> Error (Provider.provider_error ~provider:s.name "the fake endpoint answered oddly")

    let aclose () = ()
  end : Provider.S)

(* The fake fetcher: one audited read per call, then a page long enough to clear
   [fetch.min_text_chars]. The title and body carry the URL's marker so a
   response that served another request is visible in the body. *)

let page_padding =
  "Every fetch test that means to exercise a successful extraction uses a string"
  ^ " long enough that the engine does not mistake it for the nav stub left behind"
  ^ " by a JavaScript-rendered page. Anything shorter is the empty case, which has"
  ^ " its own tests, and this paragraph exists only to clear the minimum."

type fetch_stub = { name : string; net : Provider.Net.t; port : int; calls : int Atomic.t }

let fetch_stub ~name ~net ~port = { name; net; port; calls = Atomic.make 0 }

let fetcher_of_stub (s : fetch_stub) : Engine.Fetch.fetcher =
  {
    Engine.Fetch.name = s.name;
    cost_per_1k = None;
    fetch =
      (fun ~url ~offset:_ ~max_chars:_ ->
        ignore (Atomic.fetch_and_add s.calls 1);
        let tag = Filename.basename (Uri.path (Uri.of_string url)) in
        let request : Caps.Authority.Net.request =
          {
            meth = `GET;
            uri =
              Uri.of_string
                (Printf.sprintf "http://127.0.0.1:%d/page?tag=%s" s.port
                   (Uri.pct_encode tag));
            headers = [];
            body = None;
          }
        in
        match s.net.Provider.Net.request request with
        | Error _ -> Error (Engine.Fetch.Provider (Provider.provider_error ~provider:s.name "refused"))
        | Ok response when response.Caps.Authority.Net.status = 200 ->
          let text = Printf.sprintf "Page body for %s. %s" tag page_padding in
          Ok
            {
              Engine.Fetch.url = url;
              title = Some ("Title for " ^ tag);
              text;
              content_type = Some "text/html";
              status_code = 200;
              truncated = false;
              total_chars = String.length text;
              path_addressable = false;
              image = None;
            }
        | Ok _ ->
          Error (Engine.Fetch.Provider (Provider.provider_error ~provider:s.name "answered oddly")));
    aclose = (fun () -> ());
  }

(* {1 The app}

   Built by hand rather than through [Factory.build_app] because every dependency
   this suite wants to observe — the provider, the fetcher, the model endpoint —
   is a fake, and the audit trail is the fixture's own sink. *)

let endpoint port : Caps.Policy.endpoint =
  { Caps.Policy.scheme = `Http; host = "127.0.0.1"; port = Some port }

let config ~provider_port =
  let agent =
    {
      Config.default_agent_config with
      Config.enabled = true;
      base_url = Some (Printf.sprintf "http://127.0.0.1:%d/v1" provider_port);
      model = Some "fixture-model";
    }
  in
  let dashboard = { Config.default_dashboard_config with Config.enabled = true } in
  match
    Config.resolve
      ~providers:
        [ ("serper", { Config.default_provider_config with Config.enabled = true }) ]
      ~default_provider:"serper" ~agent ~dashboard ()
  with
  | Ok config -> config
  | Error message -> A.failf "the fixture config was refused: %s" message

type captured = {
  level : Config.log_level;
  event : string;
  fields : (string * Yojson.Safe.t) list;
}

(* The one sink every layer shares, as production shares it: the engines, the
   agents and [Factory.audit_sink] all render into this list. Cooperative
   fibers do not switch inside [::], so the read-modify-write needs no lock. *)
let capture () =
  let events = ref [] in
  let log level event fields = events := { level; event; fields } :: !events in
  (log, fun () -> List.rev !events)

let readers : Engine.Fetch.Readers.t =
  {
    Engine.Fetch.Readers.parse_path = (fun _ -> Error "no path grammar in this fixture");
    render_schema = (fun _ -> None);
    select_paths = (fun ~text:_ ~path:_ ~max_chars:_ -> ([], 0));
    select_passages = (fun ~text:_ ~query:_ ~max_chars:_ -> ([], 0));
  }

type rig = {
  app : Server.app;
  usage : Usage.t;
  board : Health.t;
  searches_seen : int Atomic.t;
  fetches_seen : int Atomic.t;
  events : unit -> captured list;
}

let build_rig ~env ~sw ~provider_port ~journal =
  let config = config ~provider_port in
  let log, events = capture () in
  let usage =
    match Usage.create ~now ~log ~history_path:journal () with
    | Ok usage -> usage
    | Error message -> A.failf "the fixture journal did not open: %s" message
  in
  let audit = Factory.audit_sink log in
  let audited ?(timeout_seconds = 5.0) port =
    match
      Factory.grant_of_endpoint ~sw ~net:env#net ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~timeout_seconds ~audit (endpoint port)
    with
    | Ok grant -> grant
    | Error message -> A.failf "the fixture grant was refused: %s" message
  in
  let search_stub =
    search_stub ~name:"serper" ~net:(Provider.Net.of_grant (audited provider_port))
      ~port:provider_port
  in
  let board = Health.create ~now:clock ~log () in
  let search =
    Engine.Search.create config ~health:board ~usage ~log
      [ ("serper", provider_of_search_stub search_stub) ]
      ~clock ~now ()
  in
  let fetch_stub =
    fetch_stub ~name:"http" ~net:(Provider.Net.of_grant (audited provider_port))
      ~port:provider_port
  in
  let fetch =
    match
      Engine.Fetch.create config (fetcher_of_stub fetch_stub) ~readers ~usage ~log ~clock ~now ()
    with
    | Ok engine -> engine
    | Error message -> A.failf "the fixture fetch engine was refused: %s" message
  in
  let agent =
    Agent.create config
      ~net:(Provider.Net.of_grant (audited ~timeout_seconds:10.0 provider_port))
      search ~fetch_engine:fetch ~usage ~log ~clock ~now ()
  in
  let health =
    {
      Server.board;
      built = [ "serper" ];
      probes =
        [
          ( "serper",
            {
              Health.endpoint =
                Health.probe_endpoint_const
                  (Printf.sprintf "http://127.0.0.1:%d/probe" provider_port);
              headers = (fun _config _key -> []);
            } );
        ];
      net = Factory.probe_net ~sw ~net:env#net ~mono_clock:(Eio.Stdenv.mono_clock env)
              ~timeout_seconds:5.0 ~audit [ endpoint provider_port ];
    }
  in
  let app =
    {
      Server.config;
      search;
      usage;
      fetch = Some fetch;
      agent = Some agent;
      started_at = 0.0;
      mono_now = clock;
      allowed_hosts = [];
      health = Some health;
    }
  in
  {
    app;
    usage;
    board;
    searches_seen = search_stub.calls;
    fetches_seen = fetch_stub.calls;
    events;
  }

(* {1 The served listener}

   [serve_http] binds its own port, and the suite needs the number, so this is
   its accept loop: one accepted socket enters the same [serve_connection] the
   production listener hands to [run_server], which is where the custom routes,
   the Host allowlist and the REST projection live. *)

type served = {
  port : int;
  stop : unit Eio.Promise.u;
  stopped : unit Eio.Promise.t;
  active : int Atomic.t;
}

let serve ~env ~sw ~log ~app ~server =
  let socket =
    Eio.Net.listen ~backlog:128 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> A.failf "the served listener is not a TCP socket: %s" path
  in
  let stop, fill_stop = Eio.Promise.create () in
  let stopped, fill_stopped = Eio.Promise.create () in
  let active = Atomic.make 0 in
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Promise.resolve fill_stopped ())
      (fun () ->
        Eio.Net.run_server socket ~stop
          ~on_error:(fun _exn -> ())
          (fun flow peer ->
            ignore (Atomic.fetch_and_add active 1);
            Fun.protect
              ~finally:(fun () -> ignore (Atomic.fetch_and_add active (-1)))
              (fun () ->
                Server.serve_connection ~clock:(Eio.Stdenv.mono_clock env) ~log ~app ~server
                  ~flow ~peer))));
  { port; stop = fill_stop; stopped; active }

let stop_served served =
  Eio.Promise.resolve served.stop ();
  Eio.Promise.await served.stopped

(* {1 Clients}

   Each request runs in its own switch with its own connection, which is what
   makes them simultaneous: a shared client would serialise them on one socket's
   keep-alive stream. *)

let request ~env ~port ~meth ~path ~body =
  Eio.Switch.run (fun sw ->
    let client = Cohttp_eio.Client.make ~https:None env#net in
    let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path) in
    let headers =
      Http.Header.of_list
        [ ("content-type", "application/json"); ("accept", "application/json") ]
    in
    let response, response_body =
      match meth with
      | `POST ->
        Cohttp_eio.Client.post client ~sw ~headers
          ~body:(Cohttp_eio.Body.of_string body) uri
      | _ -> Cohttp_eio.Client.get client ~sw ~headers uri
    in
    let status = Http.Status.to_int (Http.Response.status response) in
    let text = Eio.Buf_read.(take_all (of_flow ~max_size:1_000_000 response_body)) in
    (status, text))

let query_json key value = Yojson.Safe.to_string (`Assoc [ (key, `String value) ])

(* {1 Consistency of a dashboard read}

   The snapshot is one read of many counters. These identities hold for every
   complete snapshot and fail for a read that saw half a fold: the lifetime
   search count is the provider rows' sum and the window's sum, and the recent
   deque holds one entry per terminal line. *)
let consistent_snapshot json =
  let totals = get "totals" json in
  let lifetime = int (get "searches" totals) in
  let fetches = int (get "fetches" totals) in
  let answer_calls = int (get "calls" (get "answers" json)) in
  let provider_calls =
    List.fold_left
      (fun sum row -> sum + int (get "calls" row))
      0 (items (get "providers" json))
  in
  let window_searches =
    List.fold_left
      (fun sum day -> sum + int (get "searches" day))
      0 (items (get "days" json))
  in
  let window_errors =
    List.fold_left
      (fun sum day -> sum + int (get "errors" day))
      0 (items (get "days" json))
  in
  let recent = List.length (items (get "recent" json)) in
  A.(check int) "lifetime searches are the provider rows' sum" lifetime provider_calls;
  A.(check int) "lifetime searches are the window's sum" lifetime window_searches;
  A.(check int) "lifetime errors are the window's errors" (int (get "errors" totals)) window_errors;
  A.(check int)
    "the recent deque holds one entry per terminal line" recent
    (lifetime + fetches + answer_calls)

(* {1 The case} *)

let concurrent_operations_share_one_record () =
  Mirage_crypto_rng_unix.use_default ();
  (* Agent mode refuses to run without a key even when the endpoint is a fixture;
     the key never leaves the process and the injected grant is what dials. The
     provider's key matters for the health probe's shape: a mandatory-key name
     with no key answers [Key_required] before it dials, which is right for
     readiness and wrong for this suite's per-tick audit count. *)
  Unix.putenv "SEEKWRIGHT_AGENT_API_KEY" "sk-fixture";
  Unix.putenv "SEEKWRIGHT_SERPER_API_KEY" "sk-fixture-serper";
  let root = Filename.concat (Filename.get_temp_dir_name ()) "seekwright-f2-4" in
  (try Unix.mkdir root 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let journal_native = Filename.concat root (Printf.sprintf "usage-%d.jsonl" (Unix.getpid ())) in
  (try Sys.remove journal_native with Sys_error _ -> ());
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let journal = Eio.Path.(env#fs / root / Filename.basename journal_native) in
  let fixture = start_fixture ~env ~sw in
  let rig = build_rig ~env ~sw ~provider_port:fixture.port ~journal in
  let server =
    match Server.mcp_server rig.app with
    | Ok server -> server
    | Error _ -> A.fail "the fixture registry was refused"
  in
  let served = serve ~env ~sw ~log:(fun _ _ _ -> ()) ~app:rig.app ~server in
  let port = served.port in
  (* One health-monitor fiber, ticking while the requests run. The sleep is the
     monitor's own seam: it yields here instead of waiting on the clock, and the
     run ends after a known number of ticks so the probe count is arithmetic
     rather than a measurement. *)
  let health_done, resolve_health_done = Eio.Promise.create () in
  let ticked = ref 0 in
  Eio.Fiber.fork ~sw (fun () ->
    let sleep () =
      if !ticked >= ticks then raise Exit;
      incr ticked;
      Eio.Fiber.yield ()
    in
    try Server.run_health_monitor (Option.get rig.app.Server.health) ~config:rig.app.Server.config ~sleep
    with Exit -> Eio.Promise.resolve resolve_health_done ());
  (* The requests. Every array slot is written by exactly one fiber and read
     after [Fiber.all] joins them, so the array needs no lock. *)
  let search_results = Array.make searches (0, "") in
  let fetch_results = Array.make fetches (0, "") in
  let answer_results = Array.make answers (0, "") in
  let dashboard_results = Array.make 3 (0, "") in
  let run_all () =
    let work =
      List.init searches (fun i () ->
          search_results.(i) <-
            request ~env ~port ~meth:`POST ~path:"/api/v1/search"
              ~body:(query_json "query" (search_query i)))
      @ List.init fetches (fun i () ->
            fetch_results.(i) <-
              request ~env ~port ~meth:`POST ~path:"/api/v1/fetch"
                ~body:(query_json "url" (fetch_url i)))
      @ List.init answers (fun i () ->
            answer_results.(i) <-
              request ~env ~port ~meth:`POST ~path:"/api/v1/answer"
                ~body:(query_json "query" (answer_query i)))
      @ List.init 3 (fun i () ->
            dashboard_results.(i) <-
              request ~env ~port ~meth:`GET ~path:"/dashboard/data" ~body:"")
    in
    Eio.Fiber.all work
  in
  run_all ();
  Eio.Promise.await health_done;
  (* The switch's children are all done; stopping the listener then waits for
     the accept loop, which waits for its connections. *)
  stop_served served;
  stop_fixture fixture;
  A.(check int) "no connection outlives the switch" 0 (Atomic.get served.active);

  (* {2 Every response is its own}

     A status and the JSON's own echo of the request are checked per call, so a
     body handed to the wrong caller fails here even though the aggregate counts
     below would still add up. *)
  List.iteri
    (fun i (status, body) ->
      A.(check int) (Printf.sprintf "search %d status" i) 200 status;
      let json = Yojson.Safe.from_string body in
      A.(check string) (Printf.sprintf "search %d answers its own query" i)
        (search_query i) (str (get "query" json));
      A.(check string) (Printf.sprintf "search %d names the provider" i)
        "serper" (str (get "provider" json));
      match items (get "results" json) with
      | first :: _ ->
        A.(check string) (Printf.sprintf "search %d carries its own result" i)
          ("About " ^ search_query i) (str (get "title" first))
      | [] -> A.failf "search %d returned no results" i)
    (Array.to_list search_results);
  List.iteri
    (fun i (status, body) ->
      A.(check int) (Printf.sprintf "fetch %d status" i) 200 status;
      let json = Yojson.Safe.from_string body in
      A.(check string) (Printf.sprintf "fetch %d answers its own url" i)
        (fetch_url i) (str (get "requested_url" json));
      A.(check string) (Printf.sprintf "fetch %d names what landed" i)
        (fetch_url i) (str (get "url" json));
      A.(check bool)
        (Printf.sprintf "fetch %d carries its own marker in the page" i)
        true
        (contains ~haystack:(str (get "text" json)) ~needle:(marker "fetch" i)))
    (Array.to_list fetch_results);
  List.iteri
    (fun i (status, body) ->
      A.(check int) (Printf.sprintf "answer %d status: %s" i body) 200 status;
      let json = Yojson.Safe.from_string body in
      A.(check string) (Printf.sprintf "answer %d answers its own question" i)
        (answer_query i) (str (get "query" json));
      A.(check bool)
        (Printf.sprintf "answer %d carries its own question into the prose" i)
        true
        (contains ~haystack:(str (get "answer" json)) ~needle:(answer_query i)))
    (Array.to_list answer_results);
  Array.iteri
    (fun i (status, body) ->
      A.(check int) (Printf.sprintf "dashboard read %d status" i) 200 status;
      (* Archived only after the storm; the concurrent readers asserted the same
         identities below, at the moment the snapshot was taken. *)
      consistent_snapshot (Yojson.Safe.from_string body))
    dashboard_results;

  (* {2 The aggregates, exactly}

     Each search line adds one search and one provider call; each answer call
     adds one [answer] line and one retrieval search; each fetch adds one. *)
  let expected_searches = searches + answers in
  let expected_lines = searches + fetches + (2 * answers) in
  let snapshot = Usage.snapshot rig.usage in
  let totals = get "totals" snapshot in
  A.(check int) "every search, including the answers' retrieval steps"
    expected_searches (int (get "searches" totals));
  A.(check int) "every fetch" fetches (int (get "fetches" totals));
  A.(check int) "no errors" 0 (int (get "errors" totals));
  A.(check int) "one answer line per answer call" answers
    (int (get "calls" (get "answers" snapshot)));
  A.(check (float 1e-9) "the search spend is the call count at the stub's price"
     (0.001 *. float_of_int expected_searches)
     (money (get "search_cost_usd" totals)));
  let serper =
    List.find_opt (fun row -> str (get "provider" row) = "serper")
      (items (get "providers" snapshot))
  in
  (match serper with
  | Some row ->
    A.(check int) "the provider row counts every dispatch" expected_searches
      (int (get "calls" row))
  | None -> A.fail "the provider row is missing");
  A.(check int) "the fake provider was dispatched once per search" expected_searches
    (Atomic.get rig.searches_seen);
  A.(check int) "the fake fetcher was dispatched once per fetch" fetches
    (Atomic.get rig.fetches_seen);
  A.(check bool) "the board gates nobody after only successes" false
    (Health.is_open rig.board "serper");
  consistent_snapshot snapshot;

  (* {2 The journal, one complete object per line}

     The file is read back after the listener drained, so every append has
     finished. A line is complete when it parses as an object of one of the
     three declared shapes; an interleaved pair fails to parse or arrives with
     the wrong tool count. *)
  let raw = read_file journal_native in
  A.(check bool) "the journal ends its last line" true
    (String.length raw > 0 && raw.[String.length raw - 1] = '\n');
  let lines =
    String.split_on_char '\n' raw |> List.filter (fun line -> line <> "")
  in
  A.(check int) "one line per terminal call" expected_lines (List.length lines);
  let line_of line =
    match Yojson.Safe.from_string line with
    | `Assoc _ as json -> json
    | _ -> A.failf "a journal line is not an object: %s" line
  in
  let tools = List.map (fun line -> str (get "tool" (line_of line))) lines in
  let count_tool name = List.fold_left (fun n tool -> if tool = name then n + 1 else n) 0 tools in
  A.(check int) "search lines" expected_searches (count_tool "search");
  A.(check int) "fetch lines" fetches (count_tool "fetch");
  A.(check int) "answer lines" answers (count_tool "answer");
  A.(check (list string)) "no line declares an unknown tool"
    []
    (List.filter (fun tool -> not (List.mem tool [ "search"; "fetch"; "answer" ])) tools);
  (* Every search line carries its provider, so the file's count and the
     snapshot's provider row cannot disagree. *)
  A.(check int) "every search line is attributable" expected_searches
    (List.fold_left
       (fun n line ->
         match get "provider" (line_of line) with `String _ -> n + 1 | _ -> n)
       0 lines);

  (* {2 One audit event per low-level operation}

     [Factory.audit_sink] is the production sink, so every request the audited
     grants carried is one [caps.operation] line: the searches (the answers'
     retrieval steps included), the fetches, the model calls and the probe
     ticks. *)
  let audit_events =
    rig.events ()
    |> List.filter (fun (event : captured) -> event.event = "caps.operation")
  in
  A.(check int)
    "one audit event per provider, fetch, model and probe request"
    (expected_searches + fetches + answers + ticks)
    (List.length audit_events);
  List.iter
    (fun (event : captured) ->
      A.(check bool) "an audit line names its operation" true
        (List.mem_assoc "operation" event.fields);
      A.(check bool) "an audit line names its outcome" true
        (List.mem_assoc "outcome" event.fields);
      match event.level with
      | Config.Log_info -> ()
      | _ -> A.fail "an audit line was not written at INFO")
    audit_events;
  A.(check int) "every health tick ran" ticks !ticked;
  let probe_events =
    rig.events ()
    |> List.filter (fun (event : captured) -> event.event = "health.probe")
  in
  A.(check int) "one probe event per tick" ticks (List.length probe_events)

let () =
  A.run "concurrency"
    [
      ( "serving shared state",
        [
          A.test_case "search, fetch, answer and health ticks share one record"
            `Quick concurrent_operations_share_one_record;
        ] );
    ]
