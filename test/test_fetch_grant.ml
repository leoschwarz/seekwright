(* fetch.allow_private_addresses, end to end: the capability grant the local
   reader is built with, and therefore what a fetch may connect to.

   The switch is the operator's authorisation for the local reader to reach
   private space (plans/ocaml-finalisation.md F1.4), and it selects one of the
   two construction-time web variants of the policy — there is no route that
   widens a grant afterwards. So this suite pins both halves:

   - the public-web grant (the default, and every other route) refuses a
     loopback connect;
   - the private-web grant serves loopback — at the address and port axes,
     not just in the fixture — while a multicast group, a broadcast address
     and the unspecified address stay refused, and every refusal names the
     private-web rule rather than the public one: the widening is one axis
     wide, and the prose follows it;
   - [Factory.build_fetch_stack] picks the variant from
     [fetch.allow_private_addresses], and the served reader answers for a
     loopback page only when the switch is on;
   - the widening is constructed exactly once in the product — the stack
     builder — so no other route can gain it.

   The private-web cases dial 127.0.0.1, which nothing outside a test may do:
   this module is test-only, and the fixture port is bound inside the same
   case, exactly as test_fetch_http.ml does. *)

module Caps = Mcp_caps
module Policy = Caps.Policy
module Authority = Caps.Authority
module Error = Caps.Error
module F = Seekwright_fetch.Fetcher
module E = Seekwright_fetch.Extractor
module S = Seekwright_fetch_stdlib.Stdlib
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Factory = Seekwright_factory.Factory

let extractor = E.of_module (module S)

let marker = "PRIVATE-FIXTURE-MARKER"

let fixture_body =
  "<!DOCTYPE html><html><head><title>Priv</title></head><body><p>" ^ marker ^ "</p></body></html>"

let fixture _conn _request _body =
  Cohttp_eio.Server.respond_string ~headers:(Http.Header.of_list [ ("content-type", "text/html") ])
    ~status:`OK ~body:fixture_body ()

let error_message (error : F.error) : string =
  match error with
  | F.Refusal (F.Url_blocked m) | F.Refusal (F.Redirect_blocked m) | F.Refusal (F.Blocked m) -> m
  | F.Failed m -> m

let engine_error_message (error : Engine.Fetch.fetch_error) : string =
  match error with
  | Engine.Fetch.Provider e -> e.Seekwright.Provider.message
  | Url_blocked m | Redirect_blocked m | Fetch_blocked m -> m

(* One case: the fixture, and the fetcher over a web grant of the case's
   variant. [private_web] is the axis under test; the port policy is the one
   [Factory.build_fetch_stack] builds the served reader with. *)
let with_web_fetcher ~(private_web : bool) f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~backlog:16 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> Alcotest.failf "unix socket fixture: %s" path
  in
  let server = Cohttp_eio.Server.make ~callback:fixture () in
  let stop, fill_stop = Eio.Promise.create () in
  let stopped, fill_stopped = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Promise.resolve fill_stopped ())
      (fun () -> Cohttp_eio.Server.run ~stop ~on_error:(fun _exn -> ()) socket server));
  Fun.protect
    ~finally:(fun () ->
      Eio.Promise.resolve fill_stop ();
      Eio.Promise.await stopped)
    (fun () ->
      let web = if private_web then Policy.with_private_web else Policy.with_public_web in
      match
        web ~sw ~net:env#net ~port_policy:Policy.Any_port
          ~max_response_bytes:Policy.default_max_response_bytes ()
      with
      | Error error -> Alcotest.failf "with_%s_web: %s"
          (if private_web then "private" else "public")
          (Error.render error)
      | Ok decision ->
          let net =
            Authority.Net.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) decision
          in
          let fetcher = F.make ~net ~extractor () in
          f fetcher port)

let refusal_message fetcher url =
  match F.fetch fetcher url ~offset:0 ~max_chars:None with
  | Ok _ -> None
  | Error error -> Some (error_message error)

(* {1 The two web variants, through the fetcher} *)

let public_web_refuses_loopback () =
  with_web_fetcher ~private_web:false (fun fetcher port ->
    match F.fetch fetcher (Printf.sprintf "http://127.0.0.1:%d/" port) ~offset:0 ~max_chars:None with
    | Ok page ->
        Alcotest.failf "the public-web grant served a loopback page (%d chars)"
          (String.length page.F.text)
    | Error error ->
        Test_support.includes "the public-web refusal names the address rule"
          "none of which this grant may connect to" (error_message error))

let private_web_serves_loopback () =
  with_web_fetcher ~private_web:true (fun fetcher port ->
    match F.fetch fetcher (Printf.sprintf "http://127.0.0.1:%d/" port) ~offset:0 ~max_chars:None with
    | Error error -> Alcotest.failf "the private-web grant refused the fixture: %s"
        (error_message error)
    | Ok page ->
        Test_support.includes "the private-web grant served the page" marker page.F.text)

let private_web_does_not_filter_loopback () =
  (* The widening is real at the address and port axes, not just in the
     fixture above: dialing loopback on a port nothing listens on must fail
     in the kernel, not in the policy. (Port 1 answers [ECONNREFUSED]
     instantly on loopback, so this case reaches no network.) *)
  with_web_fetcher ~private_web:true (fun fetcher _port ->
    match refusal_message fetcher "http://127.0.0.1:1/" with
    | None ->
        (* Something really is listening on loopback:1 — not this test's
           doing, and not a policy pass either; treat it as an allowed
           destination, which is what the widening promises. *)
        ()
    | Some message ->
        Test_support.excludes "loopback passed the address rule" "may connect to" message
        ;
        Test_support.excludes "loopback passed the port rule" "usable on port" message)

let private_web_keeps_the_guardrail_addresses () =
  with_web_fetcher ~private_web:true (fun fetcher _port ->
    List.iter
      (fun (label, url) ->
        match refusal_message fetcher url with
        | None -> Alcotest.failf "the private-web grant allowed %s (%s)" label url
        | Some message ->
            Test_support.includes (Printf.sprintf "%s refused" label)
              "none of which this grant may connect to" message
            ;
            (* The sentence names the right policy: an operator who approved
               intranet reads must not be told about a policy they never set. *)
            Test_support.includes "the refusal names the private-web rule" "the private-web policy"
              message)
      [
        ("multicast", "http://224.0.0.1/");
        ("broadcast", "http://255.255.255.255/");
        ("unspecified", "http://0.0.0.0/");
      ])

let private_web_keeps_the_port_axis () =
  (* The port mode is a separate axis from the address rule: the default port
     mode still bites under the private-web variant, so the widening is only
     ever an address widening. *)
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match
    Policy.with_private_web ~sw ~net:env#net ~max_response_bytes:Policy.default_max_response_bytes ()
  with
  | Error error -> Alcotest.failf "with_private_web: %s" (Error.render error)
  | Ok decision -> (
      let net = Authority.Net.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) decision in
      let fetcher = F.make ~net ~extractor () in
      match F.fetch fetcher "http://127.0.0.1:8080/" ~offset:0 ~max_chars:None with
      | Ok _ -> Alcotest.fail "the default port mode served port 8080 under the private-web grant"
      | Error error ->
          (* The refusal is the fetcher's shape check, and it names the right
             mode — the same mode-aware prose the address refusals carry. *)
          Test_support.includes "the port rule refused first" "uses port 80 for http"
            (error_message error))

(* {1 The stack builder selects the variant from the switch} *)

let config_with_switch (switch : bool) : Config.t =
  {
    Config.default with
    Config.fetch = { Config.default.Config.fetch with allow_private_addresses = switch }
  }

let served_reader (switch : bool) env sw =
  match Factory.build_fetch_stack ~sw ~net:(env#net) ~mono_clock:(Eio.Stdenv.mono_clock env)
          (config_with_switch switch) with
  | None -> Alcotest.fail "fetch is enabled by default; the stack must build"
  | Some (Error message) -> Alcotest.failf "build_fetch_stack: %s" message
  | Some (Ok (local, fallbacks)) ->
      Test_support.check_int "no fallbacks in v1" 0 (List.length fallbacks)
      ;
      local

let stack_off_refuses_loopback () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let local = served_reader false env sw in
  (* The switch is off: the reader the stack hands the engine runs on the
     public-web grant, and a loopback connect is refused by the grant. *)
  match local.Engine.Fetch.fetch ~url:"http://127.0.0.1:8080/" ~offset:0
          ~max_chars:Engine.Fetch.Default with
  | Ok page ->
      Alcotest.failf "the default switch let the served reader reach loopback (%d chars)"
        (String.length page.F.text)
  | Error error ->
      Test_support.includes "the served reader refused loopback under the default switch"
        "none of which this grant may connect to" (engine_error_message error)

let stack_on_serves_loopback () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~backlog:16 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> Alcotest.failf "unix socket fixture: %s" path
  in
  let server = Cohttp_eio.Server.make ~callback:fixture () in
  let stop, fill_stop = Eio.Promise.create () in
  let stopped, fill_stopped = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Promise.resolve fill_stopped ())
      (fun () -> Cohttp_eio.Server.run ~stop ~on_error:(fun _exn -> ()) socket server));
  Fun.protect
    ~finally:(fun () ->
      Eio.Promise.resolve fill_stop ();
      Eio.Promise.await stopped)
    (fun () ->
      let local = served_reader true env sw in
      match
        local.Engine.Fetch.fetch ~url:(Printf.sprintf "http://127.0.0.1:%d/" port) ~offset:0
          ~max_chars:Engine.Fetch.Default
      with
      | Error error ->
          Alcotest.failf "the switch let the served reader refuse its own fixture: %s"
            (engine_error_message error)
      | Ok page ->
          Test_support.includes "the switch-on served reader read the loopback page" marker
            page.F.text)

(* {1 Source pins — the widening is constructed once, where the key is read } *)

let factory_src = Test_support.read_file "../lib/factory/factory.ml"

let widening_is_constructed_once () =
  (* the private-web variant appears exactly once in the factory, and only in
     the branch that reads the operator's key *)
  Test_support.check_int "one private-web construction" 1
    (Test_support.count_occurrences ~haystack:factory_src ~needle:"Policy.with_private_web")
  ;
  Test_support.check_int "one public-web construction (the other half of the same branch)" 1
    (Test_support.count_occurrences ~haystack:factory_src ~needle:"Policy.with_public_web")
  ;
  Test_support.includes "the variant is chosen from the config key"
    "if fetch.Config.allow_private_addresses then Policy.with_private_web" factory_src
  ;
  (* every non-web grant in the factory — providers, probes, agent — goes
     through with_endpoints, which has no private-web form to be given *)
  Test_support.includes "endpoint grants still exist" "Policy.with_endpoints" factory_src
  ;
  (* the disclosure the switch has to make in --check output *)
  let check_src = Test_support.read_file "../lib/cli/cli_check.ml" in
  Test_support.includes "--check says when the local reader is built with the private-web grant"
    "private-web grant" check_src

let () =
  Mirage_crypto_rng_unix.use_default ();
  Alcotest.run "fetch-grant"
    [
      ("the two web variants through the fetcher",
       [
         Alcotest.test_case "public-web refuses a loopback connect" `Quick
           public_web_refuses_loopback
       ; Alcotest.test_case "private-web serves a loopback page" `Quick private_web_serves_loopback
       ; Alcotest.test_case "private-web filters no loopback address or port" `Quick
           private_web_does_not_filter_loopback
       ; Alcotest.test_case "private-web keeps the guardrail addresses out" `Quick
           private_web_keeps_the_guardrail_addresses
       ; Alcotest.test_case "private-web keeps the port axis" `Quick private_web_keeps_the_port_axis
       ]);
      ("the stack builder",
       [
         Alcotest.test_case "the default switch keeps the served reader public-only" `Quick
           stack_off_refuses_loopback
       ; Alcotest.test_case "the switch on builds the served reader private-web" `Quick
           stack_on_serves_loopback
       ]);
      ("source pins", [ Alcotest.test_case "the widening is constructed once" `Quick widening_is_constructed_once ]);
    ]
