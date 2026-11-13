(* One routable provider set (F1.1): the factory classifies what a config asks
   for against what this build can dispatch, and that classification is the
   single source both the server's startup verdict and [--check]'s provider
   section read. The cases below pin the startup-fatal half — which
   configurations may exist as a running server, and what the refusal says —
   and the reporting half: the five sets [--check] distinguishes, and the
   built set [/healthz] advertises.

   No case here opens a provider socket: [build_providers] constructs grants
   and never dials them, [build_app] does the same, and the probe-free routes
   are the ones asserted. The engine-side routing half of the invariant lives
   in [test_engine.ml], "one routable set". *)

module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Factory = Seekwright_factory.Factory
module Provider = Seekwright.Provider
module Server = Seekwright.Server
module Usage = Seekwright.Usage
module A = Alcotest
open Test_support

let no_log _level _event _fields = ()
let now () = 1768478400.
let clock () = 1768478400.

let with_env f = Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw -> f ~env ~sw

(* An explicit [providers] table — [providers_defaulted] is false for every
   config built here unless noted — with the given names enabled. *)
let config ?default ?permitted names =
  let entry name = (name, { Config.default_provider_config with Config.enabled = true }) in
  match
    Config.resolve ~providers:(List.map entry names) ?default_provider:default
      ?permitted_providers:permitted ()
  with
  | Error message -> A.failf "the fixture config was refused: %s" message
  | Ok config -> config

let build ~env ~sw config =
  Factory.build_providers ~sw ~net:(env#net) ~mono_clock:(env#mono_clock) ~now config

let refusal = function
  | Ok () -> A.fail "the verdict was expected to refuse"
  | Error message -> message

(* {1 The shipped default: the transition's one exception} *)

let the_default_config_starts_over_its_built_remainder () =
  with_env (fun ~env ~sw ->
    let built = build ~env ~sw Config.default in
    let sets = Factory.classify Config.default built in
    A.(check (list string) "the implicit default dispatches the one free adapter it carries"
         [ "freeserp" ] sets.Factory.built);
    (* The skipped keyless names are disclosed by name — that is what keeps
       the exception honest — and land in [skipped], never in [unsupported],
       because no [providers] table asked for them. *)
    A.(check (list string) "the unported keyless defaults are the skipped set"
         [ "exa:free"; "parallel:free" ] sets.Factory.skipped);
    A.(check (list string) "nothing is startup-fatal under an implicit config"
         [] sets.Factory.unsupported);
    A.(check (list string) "the build pass still discloses them beside the startup line"
         [ "exa:free"; "parallel:free" ] built.Factory.unsupported);
    A.(check bool "and the default config may start" true
         (Result.is_ok (Factory.startup_verdict Config.default built))))

let the_built_free_remainder_is_ocaml_untested () =
  (* OCaml-untested is this port's own status: Python's four untested names
     plus everything this build dispatches, until the OCaml live runner
     records a run of its own. A reachability probe never moves a name —
     [freeserp] is live-green in Python and still untested here. *)
  with_env (fun ~env ~sw ->
    let built = build ~env ~sw Config.default in
    let sets = Factory.classify Config.default built in
    A.(check (list string) "the one dispatched name is untested on this port"
         [ "freeserp" ] sets.Factory.untested))

let no_keyless_adapter_left_refuses_the_implicit_config () =
  (* The transition exception stops applying when it would serve nothing: a
     build that carries none of the keyless set has to say so and exit, not
     boot an engine that refuses every search. The pair is hand-built because
     no current build is in that state — the point is that the verdict
     decides it before a server exists. *)
  let empty =
    {
      Factory.built = [];
      probe_table = [];
      endpoints = [];
      grant_errors = [];
      unsupported = [ "exa:free"; "freeserp"; "parallel:free" ];
    }
  in
  let text = refusal (Factory.startup_verdict Config.default empty) in
  includes "the fact is the same one" "not built on this port" text;
  includes "and it names keylessness as the reason" "keyless" text;
  includes "every skipped name is listed" "freeserp" text

(* {1 Explicitly enabled names with no adapter: startup-fatal, listed whole} *)

let only_exa_free_is_startup_fatal () =
  (* [exa:free] is a keyless name, so an *explicit* table enabling it is the
     operator asking for a route this port does not carry — and that is fatal,
     not a skip: the skip lane belongs to the implicit default alone. *)
  with_env (fun ~env ~sw ->
    let cfg = config [ "exa:free" ] in
    let built = build ~env ~sw cfg in
    let sets = Factory.classify cfg built in
    A.(check (list string) "built: nothing" [] sets.Factory.built);
    A.(check (list string) "unsupported: the explicit name" [ "exa:free" ]
         sets.Factory.unsupported);
    A.(check (list string) "skipped: the skip lane is not for explicit names"
         [] sets.Factory.skipped);
    let text = refusal (Factory.startup_verdict cfg built) in
    includes "the phrase the operator searches for" "not built on this port" text;
    includes "the offending name" "exa:free" text)

let an_explicit_mix_names_every_offender_sorted_in_one_line () =
  (* Enabled: a built name, and two unbuilt ones written out of order. The
     refusal carries both, sorted, in one message — fixing a config should
     take one restart, not one per offender — and the built name's presence
     does not rescue the pairing. *)
  with_env (fun ~env ~sw ->
    let cfg = config ~default:"freeserp" [ "exa:free"; "freeserp"; "exa" ] in
    let built = build ~env ~sw cfg in
    A.(check (list string) "the offenders are sorted by the build pass itself"
         [ "exa"; "exa:free" ] built.Factory.unsupported);
    let text = refusal (Factory.startup_verdict cfg built) in
    includes "both in one line, sorted" "exa, exa:free" text;
    includes "the phrase" "not built on this port" text;
    includes "and what can be dispatched instead" "freeserp" text;
    (* End to end: [build_app] refuses the same config with the same words,
       before any engine exists to serve it. *)
    match
      Factory.build_app ~sw ~env ~now ~log:no_log ~allowed_hosts:[] cfg
    with
    | Ok _ -> A.fail "build_app served an explicitly unbuilt provider"
    | Error message ->
        includes "the app refusal is the verdict's own" "not built on this port"
          message)

let a_default_outside_the_built_set_is_refused_wherever_it_came_from () =
  (* Config validation already refuses a default outside [enabled]; this is
     the enabled⇒built step, pinned over a hand-built pair so the invariant
     is stated even where validation cannot reach. *)
  let lying =
    {
      Factory.built = [];
      probe_table = [];
      endpoints = [];
      grant_errors = [];
      unsupported = [];
    }
  in
  let text = refusal (Factory.startup_verdict (config ~default:"freeserp" [ "freeserp" ]) lying) in
  includes "the default is named" "default provider 'freeserp'" text;
  includes "with the same phrase" "not built on this port" text

(* {1 Permission narrowing} *)

let permission_narrowing_narrows_the_sets_not_the_startup () =
  (* Both names are built, so the permission set is a runtime narrowing, not a
     startup fact: the verdict passes, [enabled] still lists both, and
     [effective] is where the narrowing shows. *)
  with_env (fun ~env ~sw ->
    let cfg = config ~permitted:[ "freeserp" ] [ "freeserp"; "anysearch" ] in
    let built = build ~env ~sw cfg in
    let sets = Factory.classify cfg built in
    A.(check (list string) "enabled is what the file asks" [ "anysearch"; "freeserp" ]
         sets.Factory.enabled);
    A.(check (list string) "built is what this process has" [ "anysearch"; "freeserp" ]
         sets.Factory.built);
    A.(check (list string) "effective is where permitted bites" [ "freeserp" ]
         sets.Factory.effective);
    A.(check bool "and the server starts" true
         (Result.is_ok (Factory.startup_verdict cfg built))))

(* {1 [--check]'s five-way distinction} *)

let the_five_sets_are_reported_apart () =
  (* One config that touches all five categories at once: [exa] is enabled,
     unsupported and startup-fatal; [search1api] is enabled, permitted,
     unsupported and one of Python's untested four; [freeserp] is enabled,
     permitted, built — and still untested on this port, because OCaml has
     recorded no live run. No category collapses into another, and none of
     them says "ready": the ready count is the probe's, printed elsewhere. *)
  with_env (fun ~env ~sw ->
    let cfg =
      config ~permitted:[ "freeserp"; "search1api" ] [ "freeserp"; "exa"; "search1api" ]
    in
    let sets = Factory.classify cfg (build ~env ~sw cfg) in
    A.(check (list string) "enabled" [ "exa"; "freeserp"; "search1api" ]
         sets.Factory.enabled);
    A.(check (list string) "effective" [ "freeserp"; "search1api" ] sets.Factory.effective);
    A.(check (list string) "built" [ "freeserp" ] sets.Factory.built);
    A.(check (list string) "unsupported" [ "exa"; "search1api" ] sets.Factory.unsupported);
    A.(check (list string) "OCaml-untested, built names included"
         [ "freeserp"; "search1api" ] sets.Factory.untested);
    A.(check bool "and the verdict is the startup-fatal reading" false
         (Result.is_ok (Factory.startup_verdict cfg (build ~env ~sw cfg)))))

(* {1 [/healthz] reports the built set} *)

let stub (n : string) : Provider.t =
  (module struct
     let name = n
     let cost_per_1k = 0.001
     let cost_for n = float_of_int n /. 1000.
     let search _q = Error (Provider.provider_error ~provider:n "this test never dispatches")
     let aclose () = ()
   end)

let make_app ~(enabled : string list) ?default ?permitted (built : string list) =
  let cfg = config ?default ?permitted enabled in
  let registry = List.map (fun name -> (name, stub name)) built in
  let search = Engine.Search.create cfg registry ~clock ~now () in
  let usage =
    match Usage.create ~now () with
    | Ok usage -> usage
    | Error message -> A.failf "an in-memory recorder cannot fail: %s" message
  in
  {
    Server.config = cfg;
    search;
    usage;
    fetch = None;
    agent = None;
    started_at = clock () -. 2.;
    mono_now = clock;
    allowed_hosts = [];
    health = None;
  }

let healthz_body app =
  let response =
    Server.handle_custom app ~meth:"GET" ~path:"/healthz" ~host:None ~origin:None ~body:""
  in
  A.(check int "the probe answers" 200 response.Server.status);
  Yojson.Safe.from_string response.Server.body

let field json name =
  match json with
  | `Assoc fields -> (try List.assoc name fields with Not_found -> `Null)
  | _ -> `Null

let names = function
  | `List xs -> List.map (function `String s -> s | _ -> A.fail "a provider is not a string") xs
  | `Null -> []
  | _ -> A.fail "the providers field is not a list"

let healthz_advertises_only_the_built_registry () =
  (* The config [enables] a name this app's registry has no adapter for — the
     shape a served process can no longer hold (the verdict refuses it), and
     exactly the shape [/healthz] must never advertise even when handed it. *)
  let app = make_app ~enabled:[ "exa:free"; "freeserp" ] ~default:"freeserp" [ "freeserp" ] in
  let body = healthz_body app in
  A.(check (list string) "the built set only" [ "freeserp" ] (names (field body "providers")));
  match field body "default_provider" with
  | `String name -> A.(check string "the default is the built one" "freeserp" name)
  | _ -> A.fail "default_provider must name the built default"

let healthz_drops_a_default_with_no_adapter_behind_it () =
  (* The defensive arm: a config default outside the registry — refused at app
     construction, so only a hand-built app can show it — is reported absent
     rather than advertised as a route. *)
  let app = make_app ~enabled:[ "exa:free"; "freeserp" ] ~default:"exa:free" [ "freeserp" ] in
  let body = healthz_body app in
  A.(check (list string) "the registry is still the whole answer" [ "freeserp" ]
       (names (field body "providers")));
  A.(check bool "and the unreachable default is not advertised" true
       (field body "default_provider" = `Null))

let () =
  Mirage_crypto_rng_unix.use_default ();
  A.run "routing sets"
    [
      ( "the implicit default",
          [
            A.test_case "the default config starts over its built remainder" `Quick
              the_default_config_starts_over_its_built_remainder;
            A.test_case "the built free remainder is OCaml-untested" `Quick
              the_built_free_remainder_is_ocaml_untested;
            A.test_case "no keyless adapter left refuses the implicit config" `Quick
              no_keyless_adapter_left_refuses_the_implicit_config;
          ] );
      ( "explicitly unbuilt names",
          [
            A.test_case "only-exa:free is startup-fatal" `Quick only_exa_free_is_startup_fatal;
            A.test_case "an explicit mix names every offender sorted in one line" `Quick
              an_explicit_mix_names_every_offender_sorted_in_one_line;
            A.test_case "a default outside the built set is refused" `Quick
              a_default_outside_the_built_set_is_refused_wherever_it_came_from;
          ] );
      ( "permission narrowing",
          [
            A.test_case "narrowing narrows the sets, not the startup" `Quick
              permission_narrowing_narrows_the_sets_not_the_startup;
          ] );
      ( "the check's five-way distinction",
          [
            A.test_case "enabled, effective, built, unsupported and untested are apart" `Quick
              the_five_sets_are_reported_apart;
          ] );
      ( "the built set in reports",
          [
            A.test_case "healthz advertises only the built registry" `Quick
              healthz_advertises_only_the_built_registry;
            A.test_case "healthz drops a default with no adapter behind it" `Quick
              healthz_drops_a_default_with_no_adapter_behind_it;
          ] );
    ]
