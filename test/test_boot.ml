(* Boots the shipped default configuration through the real construction path.
   This is the regression test the CRITICAL quality finding asks for: a stock
   install — no config file, or a file that says nothing about [fetch] — must
   build its extractor, its fetch stack and the whole app. The suite constructs
   grants but never uses one, so it opens no socket and reaches no provider. *)

module Config = Seekwright.Config
module Factory = Seekwright_factory.Factory
module Extractor = Seekwright_fetch.Extractor
module A = Alcotest

let no_log _level _event _fields = ()

let with_env f = Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw -> f ~env ~sw

let test_config_and_extractor_registries_agree () =
  A.(check (list string) "one buildable registry" Config.known_extractors
       Extractor.known_extractors)

let test_the_default_backend_validates_and_builds () =
  A.(check bool "the default validates" true
       (Result.is_ok
          (Config.validate_fetch_extractor
             Config.default.Config.fetch.Config.extractor)));
  A.(check bool "and builds" true (Result.is_ok (Factory.build_extractor Config.default)))

let test_the_default_fetch_stack_builds () =
  with_env @@ fun ~env ~sw ->
  match
    Factory.build_fetch_stack ~sw ~net:(env#net)
      ~mono_clock:(env#mono_clock) Config.default
  with
  | None -> A.fail "the default enables fetch, so a stack has to be built"
  | Some (Ok _) -> ()
  | Some (Error message) ->
      A.failf "the default fetch stack was refused: %s" message

let test_the_default_config_builds_the_app () =
  with_env @@ fun ~env ~sw ->
  match
    Factory.build_app ~sw ~env ~now:Unix.gettimeofday ~log:no_log ~allowed_hosts:[]
      Config.default
  with
  | Error message -> A.failf "the default app was refused: %s" message
  | Ok (_app, _built) -> ()

let test_the_names_this_build_cannot_dispatch_are_reported () =
  with_env @@ fun ~env ~sw ->
  let built =
    Factory.build_providers ~sw ~net:(env#net) ~mono_clock:(env#mono_clock)
      ~now:Unix.gettimeofday Config.default
  in
  (* The keyless default is fully buildable on this port: with [exa:free] and
     [parallel:free] built, the default config carries no name it cannot
     dispatch, and [unsupported] stays the sentence it is — a name enabled by
     the operator that no row on this port serves. *)
  A.(check (list string) "no keyless name is left without an adapter" []
       built.Factory.unsupported);
  A.(check (list string) "the keyless default is what this build carries"
       [ "exa:free"; "parallel:free"; "freeserp" ]
       (List.map fst built.Factory.built));
  (* And the two MCP-backed names come with the [warmup] their rows carry;
     [freeserp] owns no session and contributes nothing to that list. *)
  A.(check (list string) "the session-carrying names" [ "exa:free"; "parallel:free" ]
       (List.map fst built.Factory.warmups))

let () =
  Mirage_crypto_rng_unix.use_default ();
  A.run "boot"
    [
      ( "defaults",
        [
          A.test_case "the registries agree" `Quick
            test_config_and_extractor_registries_agree;
          A.test_case "the default backend builds" `Quick
            test_the_default_backend_validates_and_builds;
          A.test_case "the default fetch stack builds" `Quick
            test_the_default_fetch_stack_builds;
          A.test_case "the default app builds" `Quick
            test_the_default_config_builds_the_app;
          A.test_case "unbuildable names are disclosed" `Quick
            test_the_names_this_build_cannot_dispatch_are_reported;
        ] );
    ]
