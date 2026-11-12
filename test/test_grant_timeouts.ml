(* The config's timeouts have to reach the grants, or the two frozen keys load
   and do nothing. The bound is observed, not assumed: a loopback listener
   accepts the connection and then never answers, so a grant that carries the
   configured bound gives up in about that time and one that carries the
   capability layer's 15-second default does not. No billed endpoint is
   involved, and the fixture never writes a response. *)

module Caps = Mcp_caps
module Config = Seekwright.Config
module Factory = Seekwright_factory.Factory
module Health = Seekwright.Health
module A = Alcotest
open Test_support

exception Done

let stalling_server env ~sw ~run =
  let socket =
    Eio.Net.listen ~backlog:8 ~sw env#net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  Eio.Fiber.fork ~sw (fun () ->
      let rec accept () =
        let (_flow, _peer) = Eio.Net.accept ~sw socket in
        accept ()
      in
      accept ());
  match Eio.Net.listening_addr socket with
  | `Tcp (_, port) -> run ~port
  | `Unix _ -> A.fail "the fixture listener is not a TCP socket"

let timed f =
  let started = Unix.gettimeofday () in
  let value = f () in
  (value, Unix.gettimeofday () -. started)

let endpoint port : Caps.Policy.endpoint =
  { Caps.Policy.scheme = `Http; host = "127.0.0.1"; port = Some port }

let request port : Caps.Authority.Net.request =
  {
    meth = `GET;
    uri =
      Uri.of_string
        (Printf.sprintf "http://127.0.0.1:%d/stall" port);
    headers = [];
    body = None;
  }

(* The bound is one second, so a grant carrying it answers in ~1s; the old
   15-second default would need fifteen. The upper bound leaves room for a
   slow machine without letting the default pass. *)
let assert_bounded ~what elapsed =
  A.(check bool (what ^ ": gave up inside the configured bound") true
       (elapsed < 5.0));
  A.(check bool (what ^ ": did not give up before it") true (elapsed >= 0.5))

let test_a_provider_grant_honours_its_bound () =
  Eio_main.run @@ fun env ->
  (try
     Eio.Switch.run (fun sw ->
       stalling_server env ~sw ~run:(fun ~port ->
           match
             Factory.grant_of_endpoint ~sw ~net:env#net
               ~mono_clock:env#mono_clock ~timeout_seconds:1.0
               (endpoint port)
           with
           | Error message -> A.failf "the fixture grant was refused: %s" message
           | Ok grant ->
               let outcome, elapsed =
                 timed (fun () ->
                     Caps.Authority.Net.request grant (request port))
               in
               assert_bounded ~what:"a provider grant" elapsed;
               (match outcome with
               | Ok _ -> A.fail "the stalling fixture answered"
               | Error error ->
                   A.(check string "the bound's kind" "timeout"
                        (Caps.Error.kind_to_string (Caps.Error.kind error)))));
       raise Done)
   with Done -> ())

let test_a_probe_net_honours_its_bound () =
  Eio_main.run @@ fun env ->
  (try
     Eio.Switch.run (fun sw ->
       stalling_server env ~sw ~run:(fun ~port ->
           let config =
             match
               Config.resolve
                 ~providers:
                   [
                     ( "freeserp",
                       {
                         Config.default_provider_config with
                         Config.enabled = true;
                       } );
                   ]
                 ()
             with
             | Ok config -> config
             | Error message -> A.failf "the fixture config was refused: %s" message
           in
           let url = Printf.sprintf "http://127.0.0.1:%d/probe" port in
           let table =
             [
               ( "freeserp",
                 {
                   Health.endpoint = Health.probe_endpoint_const url;
                   headers = (fun _config _key -> []);
                 } );
             ]
           in
           let net =
             Factory.probe_net ~sw ~net:env#net
               ~mono_clock:env#mono_clock ~timeout_seconds:1.0
               [ endpoint port ]
           in
           let outcome, elapsed =
             timed (fun () -> Health.probe ~net ~table config "freeserp")
           in
           assert_bounded ~what:"the probe net" elapsed;
           A.(check string "the probe reads the timeout as unreachable" "unreachable"
                (Health.show_outcome outcome)));
       raise Done)
   with Done -> ())

(* The wiring is one expression per key; this guards against the read being
   dropped while the behavioural case above still passes for providers. *)
let factory_source = "../lib/factory/factory.ml"

let test_every_bounded_grant_reads_its_config_key () =
  let source = read_file factory_source in
  List.iter
    (fun (what, expression) ->
      A.(check bool (what ^ " is read where its grant is built") true
           (contains ~haystack:source ~needle:expression)))
    [
      ("policy.provider_timeout_seconds", "policy.Config.provider_timeout_seconds");
      ("fetch.timeout_seconds", "fetch.Config.timeout_seconds");
      ("agent.model_timeout_seconds", "agent.Config.model_timeout_seconds");
    ]

let () =
  Mirage_crypto_rng_unix.use_default ();
  A.run "grant-timeouts"
    [
      ( "timeouts",
        [
          A.test_case "a provider grant honours its configured bound" `Quick
            test_a_provider_grant_honours_its_bound;
          A.test_case "the probe net honours its configured bound" `Quick
            test_a_probe_net_honours_its_bound;
          A.test_case "every bounded grant reads its config key" `Quick
            test_every_bounded_grant_reads_its_config_key;
        ] );
    ]
