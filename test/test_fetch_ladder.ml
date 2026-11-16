(* The fallback ladder as the factory builds it: which names a deployment gets,
   what each built row carries, the allow-list, the two price cases, and the
   credential and prerequisite gates the oracle's [_build_*] functions state.

   What this suite owns is the {i wiring}, not the vendor protocols: a name
   whose gates this deployment does not satisfy is absent from the ladder
   rather than present and failing, so nothing is left that could fire and
   nothing can be billed. And one case is the round trip — a ladder entry the
   factory built from [fetch.crawl4ai_url], dialling the endpoint that key
   named, over a loopback fixture: the grant, the target vet, and the vendor
   mapping all met in one call. *)

module Caps = Mcp_caps
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Factory = Seekwright_factory.Factory
module A = Alcotest

(* Every vendor endpoint here is https, and a grant that can speak https
   resolves its trust anchors and its random generator at construction. *)
let () = Mirage_crypto_rng_unix.use_default ()

let marker = "RENDERED-BY-FIXTURE"

let crawl_envelope =
  {|{"results":[{"success":true,"status_code":200,"markdown":"|} ^ marker
  ^ {|","metadata":{"title":"Fix"}}]}|}

(* The keyed fallbacks read the environment, and a developer's or CI's real
   keys would decide these cases. Every run clears the three, then sets only
   what the case asks for — an empty value is absent on this compiler. *)
let clear_keys () =
  List.iter
    (fun name -> Unix.putenv (Config.api_key_env_var name) "")
    [ "scrappa"; "tavily"; "linkup" ]

let provider names = List.map (fun name -> (name, Config.default_provider_config)) names

let stack_config ?(providers = provider [ "serper"; "scrappa" ]) ?permitted_providers fetch =
  match Config.resolve ~providers ?permitted_providers ~fetch () with
  | Ok config -> config
  | Error message -> A.failf "the fixture config was refused: %s" message

let ladder names = { Config.default_fetch_config with Config.fallback = Some names }

let engine_error_message (error : Engine.Fetch.fetch_error) : string =
  match error with
  | Engine.Fetch.Provider e -> e.Seekwright.Provider.message
  | Engine.Fetch.Url_blocked m | Engine.Fetch.Redirect_blocked m | Engine.Fetch.Fetch_blocked m -> m

(* The built ladder's names and prices, with the local reader's pool drained:
   each built stack owns an extraction pool, and [aclose] is what shuts it
   down. *)
let built config env sw =
  match
    Factory.build_fetch_stack ~sw ~net:env#net ~mono_clock:(Eio.Stdenv.mono_clock env) config
  with
  | None -> A.fail "fetch is enabled by default; the stack must build"
  | Some (Error message) -> A.failf "build_fetch_stack: %s" message
  | Some (Ok (local, fallbacks)) ->
      Fun.protect
        ~finally:(fun () ->
          local.Engine.Fetch.aclose ();
          List.iter (fun (f : Engine.Fetch.fetcher) -> f.aclose ()) fallbacks)
        (fun () ->
          ( List.map (fun (f : Engine.Fetch.fetcher) -> f.Engine.Fetch.name) fallbacks,
            List.map (fun (f : Engine.Fetch.fetcher) -> f.cost_per_1k) fallbacks ))

let names config env sw = fst (built config env sw)

let unpermitted_is_not_built () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  clear_keys ();
  Unix.putenv (Config.api_key_env_var "scrappa") "k";
  (* The paid fallback keyed and enabled, and the declared set names only
     [serper]: not built, so there is no object left that could fire. *)
  A.(check (list string))
    "an unpermitted fallback is not built"
    (names (stack_config ~permitted_providers:[ "serper" ] (ladder [ "scrappa" ])) env sw)
    [];
  (* The control: the same config with the name in the set builds it, so the
     absence above is the allow-list at work rather than a missing key. *)
  A.(check (list string))
    "a permitted fallback is still built"
    (names
       (stack_config ~permitted_providers:[ "serper"; "scrappa" ] (ladder [ "scrappa" ]))
       env sw)
    [ "scrappa" ]

let keyless_permission_set () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  clear_keys ();
  (* The keyless fallback gets the paid one's treatment, not an exemption: a
     declared set excludes it unless it names [jina], because [jina] is not a
     provider name and [permitted_fetch_names] is what lets a set vouch for it. *)
  A.(check (list string))
    "an unpermitted keyless fallback is not built"
    (names
       (stack_config ~providers:(provider [ "serper" ]) ~permitted_providers:[ "serper" ]
          (ladder [ "jina" ]))
       env sw)
    [];
  A.(check (list string))
    "a declared set that lists jina builds it"
    (names
       (stack_config ~providers:(provider [ "serper" ]) ~permitted_providers:[ "serper"; "jina" ]
          (ladder [ "jina" ]))
       env sw)
    [ "jina" ];
  (* Unset is permissive, so the absence above is the allow-list, not a typo. *)
  A.(check (list string))
    "an unset permission set still builds it"
    (names (stack_config ~providers:(provider [ "serper" ]) (ladder [ "jina" ])) env sw)
    [ "jina" ]

let gates () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  clear_keys ();
  (* [crawl4ai]'s whole prerequisite is the URL of the service the operator
     runs: with no [fetch.crawl4ai_url] there is nothing to build. *)
  A.(check (list string))
    "crawl4ai with no url is not built"
    (names (stack_config (ladder [ "crawl4ai" ])) env sw)
    [];
  (* A keyed fallback with no key in the environment is the same: the vendor
     is permitted, the name is in the ladder, and the row is still absent. *)
  A.(check (list string))
    "a keyed fallback with no key is not built"
    (names (stack_config (ladder [ "scrappa" ])) env sw)
    [];
  (* [tavily] and [linkup] ride keys the search side already uses, so one env
     var builds the search adapter and the fetch fallback. The ladder holds one
     priced name at a time — config refuses a second, so each is its own case. *)
  Unix.putenv (Config.api_key_env_var "tavily") "t";
  A.(check (list string))
    "tavily builds on the search key"
    (names (stack_config ~providers:(provider [ "serper"; "tavily" ]) (ladder [ "tavily" ])) env sw)
    [ "tavily" ];
  Unix.putenv (Config.api_key_env_var "linkup") "l";
  A.(check (list string))
    "linkup builds on its search key"
    (names (stack_config ~providers:(provider [ "serper"; "linkup" ]) (ladder [ "linkup" ])) env sw)
    [ "linkup" ]

let unknown_name_is_a_build_error () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  (* [Config.resolve] refuses a ladder that names an unknown fallback, so this
     is the second guard: the builder refuses rather than dropping the row and
     serving a shorter ladder than the operator wrote. The record is forged
     here precisely because [resolve] would not let it through. *)
  let forged =
    {
      Config.default with
      Config.fetch = { Config.default.Config.fetch with Config.fallback = Some [ "bogus" ] };
    }
  in
  match
    Factory.build_fetch_stack ~sw ~net:env#net ~mono_clock:(Eio.Stdenv.mono_clock env) forged
  with
  | Some (Error message) ->
      Test_support.includes "an unknown name is refused, not dropped" "unknown fetch fallback"
        message;
      Test_support.includes "and the sentence lists what is supported" "scrappa" message
  | Some (Ok _) -> A.fail "a ladder naming an unknown fallback built anyway"
  | None -> A.fail "fetch is enabled by default; the stack must build"

let prices () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  clear_keys ();
  Unix.putenv (Config.api_key_env_var "scrappa") "k";
  let _names, costs = built (stack_config (ladder [ "scrappa" ])) env sw in
  A.(check (list (option (float 1e-9)))) "the price the fallback declares" costs [ Some 0.30 ];
  (* [fetch.cost_per_1k] is the operator's correction of that figure. *)
  let corrected = { (ladder [ "scrappa" ]) with Config.cost_per_1k = Some 0.20 } in
  let _names, costs = built (stack_config corrected) env sw in
  A.(check (list (option (float 1e-9)))) "the correction" costs [ Some 0.20 ];
  (* And it corrects only the priced rows: a free fallback carries no figure,
     so a ladder-wide key cannot put one on it. *)
  let free =
    {
      (ladder [ "crawl4ai"; "jina" ]) with
      Config.cost_per_1k = Some 0.20;
      crawl4ai_url = Some "http://renderer.test:11235";
    }
  in
  let names, costs = built (stack_config ~providers:(provider [ "serper" ]) free) env sw in
  A.(check (list string)) "both free rows build" names [ "crawl4ai"; "jina" ];
  A.(check (list (option (float 1e-9)))) "and neither carries a price" costs [ None; None ]

let fixture _conn _request _body =
  Cohttp_eio.Server.respond_string
    ~headers:(Http.Header.of_list [ ("content-type", "application/json") ])
    ~status:`OK ~body:crawl_envelope ()

let served_ladder () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  clear_keys ();
  let socket = Eio.Net.listen ~backlog:16 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> A.failf "unix socket fixture: %s" path
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
      (* [fetch.crawl4ai_url] is the operator's own service, so it may be an
         internal host — and the grant the factory builds from it dials exactly
         this fixture. The target handed {i to} it is still vetted public. *)
      let config =
        stack_config ~providers:(provider [ "serper" ])
          {
            (ladder [ "crawl4ai" ]) with
            Config.crawl4ai_url = Some (Printf.sprintf "http://127.0.0.1:%d" port);
          }
      in
      match
        Factory.build_fetch_stack ~sw ~net:env#net ~mono_clock:(Eio.Stdenv.mono_clock env) config
      with
      | None | Some (Error _) -> A.fail "the crawl4ai row did not build"
      | Some (Ok (local, [ renderer ])) ->
          Fun.protect
            ~finally:(fun () ->
              local.Engine.Fetch.aclose ();
              renderer.aclose ())
            (fun () ->
              (* The target is an IP literal so the address vet answers it
                 without a lookup: the fixture never dials it, it only travels
                 in the body, and the case stays hermetic. *)
              (match
                 renderer.Engine.Fetch.fetch ~url:"http://93.184.216.34/page" ~offset:0
                   ~max_chars:Engine.Fetch.Default
               with
              | Ok page ->
                  Test_support.includes "the fixture's markdown reached the caller" marker
                    page.Engine.Fetch.text
              | Error error ->
                  A.failf "the built ladder entry failed: %s" (engine_error_message error));
              (* The target guard survives the wiring: a private target is refused
                 before the renderer is asked, even though the {i renderer} here is
                 a loopback service this deployment configured. *)
              match
                renderer.Engine.Fetch.fetch ~url:"http://127.0.0.1:9/x" ~offset:0
                  ~max_chars:Engine.Fetch.Default
              with
              | Ok _ -> A.fail "a private target reached the renderer"
              | Error (Engine.Fetch.Url_blocked message) ->
                  Test_support.includes "the target vet speaks first" "not a public address" message
              | Error error ->
                  A.failf "expected a target refusal, got %s" (engine_error_message error))
      | Some (Ok _) -> A.fail "exactly one fallback row expected")

let () =
  A.run "fetch_ladder"
    [
      ( "the permission set",
        [
          A.test_case "an unpermitted fallback is not built" `Quick unpermitted_is_not_built;
          A.test_case "the keyless fallback is gated the same way" `Quick keyless_permission_set;
        ] );
      ( "the gates",
        [
          A.test_case "prerequisites and credentials" `Quick gates;
          A.test_case "an unknown name is a build error" `Quick unknown_name_is_a_build_error;
        ] );
      ("prices", [ A.test_case "declared, corrected, and none for the free rows" `Quick prices ]);
      ( "the round trip",
        [ A.test_case "a built entry dials its configured endpoint" `Quick served_ladder ] );
    ]
