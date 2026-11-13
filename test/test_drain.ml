(* F2.3: stop, drain and close in one owner.

   [Server.serve_http] now takes the stop input it used to discard and answers
   with a lifecycle value; [Cli_serve.run_http] turns SIGINT/SIGTERM into that
   input through a self-pipe. This suite drives the shutdown without sending a
   process a signal: a stop promise it fills itself is the same input a signal
   fills, so the drain, the cancellation and the close order are all reachable
   in-process.

   Three properties are asserted here, and the real binary's SIGTERM case
   ([test_binary_drain.ml]) covers the fourth — that the process signal path
   reaches this same code:

   - a call already in flight finishes inside the grace, and [serve_http]
     answers [Drained]; the caller's [close] runs once, after the call and not
     before it;
   - a call that never finishes is cancelled at the grace ceiling and
     [serve_http] answers [Grace_expired] promptly instead of hanging;
   - while stopping, the operational GETs answer 503 [{"status": "stopping"}]
     and the three REST projections answer the oracle's 503 sentence, while
     [/dashboard] itself stays the static 200 it is.

   No provider endpoint is reached: the "provider" is an [Provider.S] module
   closing over two promises, so the request that would have gone out is a
   fiber this suite controls. *)

module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Server = Seekwright.Server
module Usage = Seekwright.Usage
module A = Alcotest
open Test_support

(* {1 Fixtures} *)

let clock () = 1_700_000_000.
let now () = clock ()
let no_log _level _event _fields = ()

(* A slow call resolves [started] as it enters the adapter and waits on
   [release]; a hung one waits forever on a promise nobody fills. Both return
   the same shaped outcome, so the graceful case's answer is the ordinary
   200. *)
type scenario =
  | Slow of { started : unit Eio.Promise.u; release : unit Eio.Promise.t }
  | Hung of { started : unit Eio.Promise.u; never : unit Eio.Promise.t }

let provider scenario : Provider.t =
  (module struct
    let name = "serper"
    let cost_per_1k = 1.0
    let cost_for n = float_of_int n /. 1000.

    let search (q : Model.search_query) =
      (match scenario with
      | Slow { started; release } ->
          Eio.Promise.resolve started ();
          Eio.Promise.await release
      | Hung { started; never } ->
          Eio.Promise.resolve started ();
          Eio.Promise.await never);
      Ok
        {
          Provider.provider = name;
          results =
            [
              {
                Provider.result =
                  {
                    Model.title = "Result for " ^ q.Model.query;
                    url = "https://example.test/" ^ q.Model.query;
                    snippet = Some "a snippet";
                    text = None;
                    text_truncated = None;
                    published_date = None;
                    score = None;
                  };
                uncapped_chars = None;
              };
            ];
          answer = None;
          cost_usd = Some 0.001;
          notice = None;
        }

    let aclose () = ()
  end : Provider.S)

let config ?(dashboard = false) () =
  match
    Config.resolve
      ~providers:
        [
          ( "serper",
            { Config.default_provider_config with Config.enabled = true } );
        ]
      ~dashboard:{ Config.default_dashboard_config with Config.enabled = dashboard }
      ()
  with
  | Ok config -> config
  | Error message -> A.failf "the fixture config was refused: %s" message

let usage () =
  match Usage.create ~now:clock () with
  | Ok usage -> usage
  | Error message -> A.failf "%s" message

let make_app ?(dashboard = false) scenario : Server.app =
  let config = config ~dashboard () in
  let search =
    Engine.Search.create config [ ("serper", provider scenario) ] ~clock ~now ()
  in
  {
    Server.config;
    search;
    usage = usage ();
    fetch = None;
    agent = None;
    started_at = 0.0;
    mono_now = clock;
    allowed_hosts = [];
    health = None;
  }

let server app =
  match Server.mcp_server app with
  | Ok server -> server
  | Error (Mcp_caps.Server.Duplicate_tool name) -> A.failf "duplicate tool: %s" name
  | Error (Mcp_caps.Server.Invalid_declaration message) ->
      A.failf "invalid declaration: %s" message

(* {1 The wire helpers} *)

(* [serve_http] owns its port, so the suite picks one first: bind port 0,
   read the number the kernel chose, close. Nothing ever listened on it, so
   there is no TIME_WAIT for the server's own bind to trip over. *)
let free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX _ -> A.fail "the scratch socket is not TCP")

let post ~env ~port ~body =
  Eio.Switch.run (fun sw ->
      let client = Cohttp_eio.Client.make ~https:None env#net in
      let uri =
        Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/api/v1/search" port)
      in
      let headers = Http.Header.of_list [ ("content-type", "application/json") ] in
      let response, response_body =
        Cohttp_eio.Client.post client ~sw ~headers
          ~body:(Cohttp_eio.Body.of_string body) uri
      in
      let status = Http.Status.to_int (Http.Response.status response) in
      let text =
        Eio.Buf_read.(take_all (of_flow response_body ~max_size:1_000_000))
      in
      (status, text))

(* The caller's close in [Cli_serve.run_http] is assembled by [bin] from the
   built providers; here it is a counter, which is what makes "exactly once"
   observable. *)
let serve ~env ~sw ~app ~close ~stop ?grace_seconds port =
  let server = server app in
  Cli_serve.run_http ~env ~sw ~log:no_log ~app ~server ~host:"127.0.0.1" ~port
    ~close ?grace_seconds ~stop ()

(* {1 A graceful stop drains the call in flight} *)

let a_graceful_stop_drains_the_in_flight_call () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let started, resolve_started = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let app = make_app (Slow { started = resolve_started; release }) in
  let stop, resolve_stop = Eio.Promise.create () in
  let closes = ref 0 in
  let close () = incr closes in
  let port = free_port () in
  let served, resolve_served = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolve_served
        (serve ~env ~sw ~app ~close ~stop port));
  let answered, resolve_answered = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      let answer =
        try Ok (post ~env ~port ~body:{|{"query":"slow query","provider":"serper"}|})
        with exn -> Error exn
      in
      Eio.Promise.resolve resolve_answered answer);
  (* The call is in flight, and it is the one that decides when the drain
     ends: nothing has closed yet. *)
  Eio.Promise.await started;
  A.(check int) "nothing is closed while a call is in flight" 0 !closes;
  Eio.Promise.resolve resolve_stop ();
  Eio.Fiber.yield ();
  A.(check int) "a requested stop does not close before the call finishes" 0 !closes;
  Eio.Promise.resolve resolve_release ();
  let answer =
    Eio.Time.with_timeout_exn env#clock 2.0 (fun () ->
        Eio.Promise.await answered)
  in
  let lifecycle =
    Eio.Time.with_timeout_exn env#clock 2.0 (fun () -> Eio.Promise.await served)
  in
  (match answer with
  | Ok (200, text) ->
      includes "the drained call answered its own query" "Result for slow query" text
  | Ok (status, _) -> A.failf "the drained call answered %d, not 200" status
  | Error exn -> A.failf "the drained call failed: %s" (Printexc.to_string exn));
  A.(check bool) "the listener reports a completed drain" true
    (lifecycle = Ok Server.Drained);
  A.(check int) "close ran once, after the drain" 1 !closes

(* {1 The grace ceiling ends a drain that cannot finish} *)

let the_grace_ceiling_forces_a_hung_call () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let started, resolve_started = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  let app = make_app (Hung { started = resolve_started; never }) in
  let stop, resolve_stop = Eio.Promise.create () in
  let closes = ref 0 in
  let close () = incr closes in
  let port = free_port () in
  let served, resolve_served = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolve_served
        (serve ~env ~sw ~app ~close ~stop ~grace_seconds:0.2 port));
  let answered, resolve_answered = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      let answer =
        try Ok (post ~env ~port ~body:{|{"query":"hung query","provider":"serper"}|})
        with exn -> Error exn
      in
      Eio.Promise.resolve resolve_answered answer);
  Eio.Promise.await started;
  let began = Unix.gettimeofday () in
  Eio.Promise.resolve resolve_stop ();
  (* The ceiling, not the request, ends this: a second of wall time is an
     order of magnitude over the grace, so a hang is a visible failure rather
     than a slow test. *)
  let lifecycle =
    Eio.Time.with_timeout_exn env#clock 2.0 (fun () -> Eio.Promise.await served)
  in
  let elapsed = Unix.gettimeofday () -. began in
  A.(check bool) "the ceiling answers Grace_expired" true
    (lifecycle = Ok Server.Grace_expired);
  A.(check bool) "the ceiling exits promptly instead of hanging" true (elapsed < 1.0);
  A.(check int) "close still ran exactly once" 1 !closes;
  (* The client's own fiber ends when the connection is cancelled; it is
     allowed to fail, and joining it keeps its exception out of the switch. *)
  match
    Eio.Time.with_timeout_exn env#clock 2.0 (fun () ->
        Eio.Promise.await answered)
  with
  | Ok _ | Error _ -> ()

(* {1 The stopping state on the custom routes} *)

let call ?stopping app ~meth ~path ~body =
  Server.handle_custom ?stopping app ~meth ~path ~host:(Some "localhost")
    ~origin:None ~body

let a_stopping_server_refuses_fresh_work () =
  let _started, resolve_started = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  let app = make_app ~dashboard:true (Hung { started = resolve_started; never }) in
  let stopping = (fun () -> true) in
  let status response = response.Server.status in
  let body response = response.Server.body in
  (* The operational GETs answer the oracle's stopping sentinel. *)
  List.iter
    (fun path ->
      let response = call ~stopping app ~meth:"GET" ~path ~body:"" in
      A.(check int) (path ^ " is 503") 503 (status response);
      A.(check string) (path ^ " carries the stopping sentinel")
        {|{"status":"stopping"}|} (body response))
    [ "/healthz"; "/dashboard/data"; "/dashboard/metrics" ];
  (* The three projections refuse in the REST surface's error shape, and they
     refuse before any route examines its engine (fetch and agent are off). *)
  List.iter
    (fun path ->
      let response = call ~stopping app ~meth:"POST" ~path ~body:"{}" in
      A.(check int) (path ^ " is 503") 503 (status response);
      A.(check string) (path ^ " carries the retry sentence")
        {|{"error":"The server is stopping; retry shortly."}|} (body response))
    [ "/api/v1/search"; "/api/v1/fetch"; "/api/v1/answer" ];
  (* The static dashboard is still served: it accepts no work. *)
  let dashboard = call ~stopping app ~meth:"GET" ~path:"/dashboard" ~body:"" in
  A.(check int) "/dashboard stays 200" 200 (status dashboard);
  (* And the default is "not stopping", so the sentinel is not a route-wide
     change. *)
  let healthz = call app ~meth:"GET" ~path:"/healthz" ~body:"" in
  A.(check int) "/healthz is 200 when not stopping" 200 (status healthz);
  A.(check bool) "the running healthz says ok" true
    (contains ~haystack:(body healthz) ~needle:{|"status":"ok"|})

let () =
  A.run "drain"
    [
      ( "stop and drain",
        [
          A.test_case "a graceful stop drains the call in flight" `Quick
            a_graceful_stop_drains_the_in_flight_call;
          A.test_case "the grace ceiling forces a hung call" `Quick
            the_grace_ceiling_forces_a_hung_call;
        ] );
      ( "stopping state",
        [
          A.test_case "a stopping server refuses fresh work" `Quick
            a_stopping_server_refuses_fresh_work;
        ] );
    ]
