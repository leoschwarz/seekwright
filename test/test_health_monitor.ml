(* The server-side health monitor: the tick loop the quality review found with
   no caller. Two facts are pinned here — that the loop sleeps before its first
   probe and repeats (an injected sleep, so no wall-clock wait), and that
   [serve_http] starts it on the listener's switch and stops it when that switch
   ends. The probe's network seam is a fake [Provider.Net.t], so no request
   leaves the process. *)

module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Health = Seekwright.Health
module Provider = Seekwright.Provider
module Server = Seekwright.Server
module Usage = Seekwright.Usage
module A = Alcotest

exception Stop_monitor

let clock () = 1.0
let now () = 1_700_000_000.0

let config ?(interval = 60.0) () =
  let search = { Config.default_search_config with Config.health_interval_seconds = interval } in
  match
    Config.resolve
      ~providers:
        [ ( "freeserp",
            { Config.default_provider_config with Config.enabled = true } ) ]
      ~search ()
  with
  | Ok config -> config
  | Error message -> A.failf "the fixture config was refused: %s" message

(* The probe row for the one enabled name: a loopback endpoint the fake seam
   never dials, so only the row's shape matters. *)
let probes =
  [ ( "freeserp",
      {
        Health.endpoint = Health.probe_endpoint_const "http://127.0.0.1:9/probe";
        headers = (fun _config _key -> []);
      } ) ]

let fake_net on_request =
  {
    Provider.Net.request =
      (fun request ->
        on_request request;
        Ok { Mcp_caps.Authority.Net.status = 200; headers = []; body = "" });
  }

let health ?(net = fake_net (fun _ -> ())) board =
  { Server.board; built = [ "freeserp" ]; probes; net }

let dummy_board () = Health.create ~now:clock ()

let app ?(health = None) config =
  let usage =
    match Usage.create ~now () with
    | Ok recorder -> recorder
    | Error message -> A.failf "the fixture recorder was refused: %s" message
  in
  let search = Engine.Search.create config [] ~clock ~now () in
  {
    Server.config;
    search;
    usage;
    fetch = None;
    agent = None;
    started_at = 0.0;
    mono_now = clock;
    allowed_hosts = [ "localhost" ];
    health;
  }

let test_the_monitor_sleeps_first_and_repeats () =
  let events = ref [] in
  let sleep () =
    events := "sleep" :: !events;
    if List.length !events >= 5 then raise Stop_monitor
  in
  let net =
    fake_net (fun _ -> events := "probe" :: !events)
  in
  let board = dummy_board () in
  (try
     Server.run_health_monitor (health ~net board) ~config:(config ()) ~sleep
   with Stop_monitor -> ());
  A.(check (list string) "sleep, probe, repeat with no probe at t=0"
       [ "sleep"; "probe"; "sleep"; "probe"; "sleep" ]
       (List.rev !events))

let test_the_listener_starts_and_stops_the_monitor () =
  Eio_main.run @@ fun env ->
  let probes_seen = ref 0 in
  let first_probe, resolve_first = Eio.Promise.create () in
  let net =
    fake_net (fun _ ->
        incr probes_seen;
        (try Eio.Promise.resolve resolve_first () with Invalid_argument _ -> ()))
  in
  let config = config ~interval:0.01 () in
  let app = app ~health:(Some (health ~net (dummy_board ()))) config in
  let server =
    match Server.mcp_server app with
    | Ok server -> server
    | Error _ -> A.fail "the fixture registry was refused"
  in
  (try
     Eio.Switch.run (fun sw ->
       Eio.Fiber.fork ~sw (fun () ->
           Server.serve_http ~env ~sw app server ~host:"127.0.0.1" ~port:0);
       Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2.0 (fun () ->
           Eio.Promise.await first_probe);
       (* End the switch the way a shutdown does: an exception cancels every
          child, the listener and the monitor fiber among them. *)
       raise Stop_monitor)
   with Stop_monitor -> ());
  (* Both children have been cancelled and joined by now. *)
  let after_cancel = !probes_seen in
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.1;
  A.(check int "no probe after the listener's switch ended" after_cancel
       !probes_seen)

let () =
  Mirage_crypto_rng_unix.use_default ();
  A.run "health-monitor"
    [
      ( "the loop",
        [
          A.test_case "sleeps first, then repeats" `Quick
            test_the_monitor_sleeps_first_and_repeats;
          A.test_case "starts and stops with the listener" `Quick
            test_the_listener_starts_and_stops_the_monitor;
        ] );
    ]
