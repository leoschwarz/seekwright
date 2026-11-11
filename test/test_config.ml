(* Configuration, ported case for case from tests/test_config.py.

   The Python suite is the shape of this one: its classes are these suites, its
   [def test_...] are these cases, and its [parametrize] decorators are the case
   lists the runner expands ([typo_cases], [billable_name_cases],
   [priced_ladders]). What a port cannot copy is *how* a refusal reaches the test
   — pydantic raises [ValidationError] from a model constructor and [SystemExit]
   from the loader, while this port returns [Error sentence] from both, so the
   assertions read the sentence instead of the exception type. Three deliberate
   differences are recorded where they show up: [Config.t.providers] keeps the
   TOML table's sorted key order where Python keeps the file's (nothing reads
   either order, and [Config.enabled_providers] is sorted on both sides); the
   [toml] parser types its arrays, so a ladder mixing a string and a number is
   refused as malformed TOML rather than as a bad list; and an integer past
   [Int64.max] is refused where Python carries arbitrary precision. All three
   are refusals on both sides: a 102-file differential run against
   [src/seekwright/config.py] in this checkout — every case dumped field by field
   from both trees — agreed byte for byte on 99 of them and flagged only these. *)

module Config = Seekwright.Config
module A = Alcotest

let strings = A.list A.string
let maybe_string = A.option A.string
(* Floats in this module are counts and ceilings read from TOML, so they are
   compared as magnitudes: an equality test on a decoded scalar would fail on a
   representation detail rather than on a decision. *)
let number = A.float 1e-9
let maybe_number = A.option number
(* The two log vocabularies are frozen value sets, so the suite compares the
   constructor and prints the operator-facing spelling when it differs. *)
let log_level =
  A.testable
    (fun ppf level -> Format.pp_print_string ppf (Config.show_log_level level))
    ( = )

let log_format =
  A.testable
    (fun ppf format -> Format.pp_print_string ppf (Config.show_log_format format))
    ( = )

(* ------------------------------------------------------------------ fixtures *)

(* One config file per case, the way the Python suite writes one into tmp_path. *)
let write_config text =
  let directory = Filename.temp_dir "seekwright-config" "" in
  let path = Filename.concat directory "config.toml" in
  let channel = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
    output_string channel text);
  path

let load text = Config.load (Some (write_config text))

(* An empty value reads as absent: [Config.api_key] treats "" as unset, exactly
   as Python's [os.environ.get(...) or None] does, and OCaml 5.3 has no
   [unsetenv] to reach for instead. *)
let unsetenv name = Unix.putenv name ""
let setenv = Unix.putenv

let cleared_keys =
  [ "SEEKWRIGHT_SERPER_API_KEY"; "SEEKWRIGHT_LINKUP_API_KEY"; "SEEKWRIGHT_EXA_API_KEY"
  ; "SEEKWRIGHT_TAVILY_API_KEY"; "SEEKWRIGHT_AGENT_API_KEY"; "SEEKWRIGHT_CONFIG"
  ; "SEEKWRIGHT_SCRAPPA_API_KEY"; "SEEKWRIGHT_JINA_API_KEY"; "SEEKWRIGHT_QUERIT_API_KEY"
  ; "SEEKWRIGHT_SERPAPI_API_KEY"; "SEEKWRIGHT_SEARCH1API_API_KEY"
  ; "SEEKWRIGHT_DEEPSEEK_API_KEY"; "SEEKWRIGHT_TINYFISH_API_KEY"
  ; "SEEKWRIGHT_ALGOLIA_API_KEY"; "SEEKWRIGHT_ANYSEARCH_API_KEY"
  ; "SEEKWRIGHT_PARALLEL_API_KEY"; "SEEKWRIGHT_SEARXNG_API_KEY"
  ; "SEEKWRIGHT_FREE SERP_API_KEY" ]

(* Every case starts from no keys at all: the Python suite's fixtures are scoped
   by monkeypatch, and these are process-wide. *)
let clear_keys () = List.iter unsetenv cleared_keys

(* A provider the operator enabled and nothing else, which is what most of these
   cases need in order to reach the rule under test. *)
let named providers =
  List.map (fun name -> (name, Config.default_provider_config)) providers

(* Reading a documented file: the sandbox has only what test/dune declares. *)
let read path =
  if not (Sys.file_exists path) then
    A.failf "%s is missing from the test sandbox (test/dune declares it)" path;
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
    really_input_string channel (in_channel_length channel))

let find_index needle haystack =
  let n = String.length needle and m = String.length haystack in
  let rec from i =
    if i + n > m then None
    else if String.sub haystack i n = needle then Some i
    else from (i + 1)
  in
  from 0

let contains needle haystack = find_index needle haystack <> None

let cut_at needle haystack =
  match find_index needle haystack with
  | Some at -> String.sub haystack 0 at
  | None -> haystack

(* A fenced block of a given language following a heading, from the runbook and
   the config reference. *)
let fenced_block path heading language =
  let text = read path in
  let after_heading =
    match find_index heading text with
    | Some at -> String.sub text at (String.length text - at)
    | None -> A.failf "%s has no %S heading" path heading
  in
  let fence = "```" ^ language in
  let after_fence =
    match find_index fence after_heading with
    | Some at ->
        let start = at + String.length fence in
        String.sub after_heading start (String.length after_heading - start)
    | None -> A.failf "%s has no %s block under %S" path language heading
  in
  match find_index "```" after_fence with
  | Some at -> String.sub after_fence 0 at
  | None -> A.failf "%s leaves the %s block under %S unterminated" path language heading

(* -------------------------------------------------------------- the assertions *)

(* The value, or a failure that names the refusal: an unexpected refusal is a
   bug in the port, so the message has to show it. *)
let expect outcome =
  match outcome with
  | Ok value -> value
  | Error fault -> A.failf "expected no fault, got: %s" fault

let refuses_with needle outcome =
  match outcome with
  | Ok _ -> A.failf "expected a fault naming %S" needle
  | Error fault ->
      if not (contains needle fault) then A.failf "fault %S does not name %S" fault needle

let refuses_exactly sentence outcome =
  match outcome with
  | Ok _ -> A.failf "expected the fault %S" sentence
  | Error fault -> if fault <> sentence then A.failf "fault was %S, expected %S" fault sentence

(* Every name in the list has to appear in the fault: the point of the unknown-
   name sentences is the supported set they print, and an assertion that only
   checks one name would pass a truncated list. *)
let refuses_naming needles outcome =
  match outcome with
  | Ok _ -> A.failf "expected a fault naming %s" (String.concat ", " needles)
  | Error fault ->
      List.iter
        (fun needle ->
          if not (contains needle fault) then
            A.failf "fault %S does not name %S" fault needle)
        needles

(* ------------------------------------------------------------------ the suites *)

let known_providers_sentence =
  "algolia, anysearch, deepseek, exa, exa:free, freeserp, linkup, parallel, \
   parallel:free, querit, scrappa, search1api, searxng, serpapi, serper, tavily, \
   tinyfish"

let supported_providers = "supported: " ^ known_providers_sentence

(* A [permitted_providers] list is checked against one set wider than the
   providers: the fetch-only names the deployment has to be able to vouch for are
   printed with them, which is why [jina] appears in that refusal and not in a
   provider-name one. *)
let permitted_supported_sentence =
  "supported: "
  ^ String.concat ", "
      (List.sort String.compare (Config.known_providers @ Config.permitted_fetch_names))

(* What a sentence quotes when it names the free set: the sorted free names, as
   the oracle's [', '.join(sorted(FREE_PROVIDERS))] writes it. *)
let sorted_free_sentence = "exa:free, freeserp, parallel:free, searxng, tinyfish"

let test_provider_opt_in () =
  clear_keys ();
  (* Opt-in stays opt-in; what changed is what the empty set resolves to. *)
  let cfg = expect (load "[policy]\nmax_snippet_chars = 100\n") in
  A.(check strings "enabled" [ "exa:free"; "freeserp"; "parallel:free" ] (Config.enabled_providers cfg));
  A.(check bool "defaulted" true cfg.Config.providers_defaulted)

let test_a_missing_config_file_is_the_keyless_set () =
  clear_keys ();
  let cfg = expect (Config.load (Some "/nonexistent/seekwright-first-run.toml")) in
  A.(check strings "enabled" [ "exa:free"; "freeserp"; "parallel:free" ] (Config.enabled_providers cfg));
  A.(check bool "defaulted" true cfg.Config.providers_defaulted)

let test_a_provider_disabled_leaves_the_keyless_set () =
  clear_keys ();
  let cfg = expect (load "[providers.serper]\nenabled = false\n") in
  A.(check strings "enabled" [ "exa:free"; "freeserp"; "parallel:free" ] (Config.enabled_providers cfg));
  A.(check bool "defaulted" true cfg.Config.providers_defaulted)

let test_the_implicit_set_is_marked_as_implicit () =
  clear_keys ();
  A.(
    check bool "no file" true
      (expect (Config.load (Some "/nonexistent/seekwright-first-run.toml")))
        .Config.providers_defaulted);
  let named = expect (load "[providers.serper]\nenabled = true\n") in
  A.(check bool "a named provider" false named.Config.providers_defaulted)

let test_a_config_naming_something_wrong_still_names_the_file () =
  clear_keys ();
  let path = write_config "[providers.serper]\nenabledd = true\n" in
  refuses_with path (Config.load (Some path))

let test_a_misspelled_provider_is_a_startup_error () =
  (* the sentence names the name at fault *and* the whole supported set, so an
     operator reading a startup failure has the list to correct it from *)
  let outcome = load "[providers.serpr]\nenabled = true\n" in
  refuses_with "unknown provider(s) serpr" outcome;
  refuses_with supported_providers outcome

let test_a_named_provider_is_loaded () =
  A.(
    check strings "enabled" [ "serper" ]
      (Config.enabled_providers (expect (load "[providers.serper]\nenabled = true\n"))))

let test_a_quoted_flavoured_table_loads_and_enables () =
  (* [:] ends a bare TOML key, so the quoting is not optional and the name still
     round-trips: this is the [key_name] decode, not a docs claim. *)
  let cfg = expect (load "[providers.\"exa:free\"]\nenabled = true\n") in
  A.(
    check strings "enabled" [ "exa:free" ] (Config.enabled_providers cfg);
    check maybe_string "default" (Some "exa:free") cfg.Config.default_provider)

let test_an_unquoted_flavoured_table_is_a_toml_error () =
  refuses_with "invalid TOML" (load "[providers.exa:free]\nenabled = true\n")

let test_a_renamed_provider_names_its_replacement () =
  let outcome = load "[providers.exa_free]\nenabled = true\n" in
  refuses_with "unknown provider(s) exa_free" outcome;
  refuses_with "it is now \"exa:free\"" outcome

(* One case per Python function of the same class. A ceiling-of-zero test, not a
   price test: [tinyfish] is free at any balance and is in; [tavily] has a free
   tier and can still bill, so it is out. *)
let free_only_cases =
  [ ( "the keyless default is free-only"
    , fun () ->
        clear_keys ();
        A.(check bool "free only" true (Config.default_route_is_free_only Config.default)) )
  ; ( "free names only"
    , fun () ->
        let cfg = expect (Config.resolve ~providers:(named [ "exa:free"; "tinyfish" ]) ()) in
        A.(check bool "free only" true (Config.default_route_is_free_only cfg)) )
  ; ( "one name that can bill restores the refusal"
    , fun () ->
        let cfg = expect (Config.resolve ~providers:(named [ "exa:free"; "serper" ]) ()) in
        A.(check bool "not free only" false (Config.default_route_is_free_only cfg)) )
  ; ( "a metered free tier can still bill"
    , fun () ->
        let cfg = expect (Config.resolve ~providers:(named [ "exa:free"; "tavily" ]) ()) in
        A.(check bool "not free only" false (Config.default_route_is_free_only cfg)) )
  ; ( "a lone free provider resolves a default and stays free-only"
    , fun () ->
        let lone = expect (Config.resolve ~providers:(named [ "exa:free" ]) ()) in
        A.(
          check maybe_string "a default is picked" (Some "exa:free") lone.Config.default_provider;
          check bool "and is still free-only" true (Config.default_route_is_free_only lone)) )
  ]

let default_provider_cases =
  [ ( "one enabled provider becomes the default"
    , fun () ->
        let single = expect (Config.resolve ~providers:(named [ "serper" ]) ()) in
        A.(check maybe_string "default" (Some "serper") single.Config.default_provider) )
  ; ( "several leave it unset"
    , fun () ->
        let several = expect (Config.resolve ~providers:(named [ "serper"; "linkup" ]) ()) in
        A.(check maybe_string "no default" None several.Config.default_provider) )
  ; ( "an explicit default is kept"
    , fun () ->
        let explicit =
          expect
            (Config.resolve ~providers:(named [ "serper"; "linkup" ]) ~default_provider:"linkup" ())
        in
        A.(check maybe_string "default" (Some "linkup") explicit.Config.default_provider) )
  ; ( "a default outside the enabled set is refused, naming what is enabled"
    , fun () ->
        refuses_with "default_provider 'linkup' is not an enabled provider (enabled: serper)"
          (Config.resolve ~providers:(named [ "serper" ]) ~default_provider:"linkup" ()) )
  ]

let permitted_providers_cases =
  [ ( "unset is permissive"
    , fun () ->
        let unset = expect (Config.resolve ~providers:(named [ "serper" ]) ()) in
        A.(
          check (option strings) "unset" None unset.Config.permitted_providers;
          check bool "any name passes" true (Config.is_permitted unset "linkup");
          check strings "effective" [ "serper" ] (Config.effective_providers unset)) )
  ; ( "a declared set bounds it"
    , fun () ->
        let narrowed =
          expect
            (Config.resolve ~providers:(named [ "serper"; "linkup" ])
               ~permitted_providers:[ "serper" ] ())
        in
        A.(
          check strings "the declared set" [ "serper" ]
            (Option.value ~default:[] narrowed.Config.permitted_providers);
          check bool "a member" true (Config.is_permitted narrowed "serper");
          check bool "a non-member" false (Config.is_permitted narrowed "linkup");
          check strings "effective" [ "serper" ] (Config.effective_providers narrowed)) )
  ; ( "membership never enables"
    , fun () ->
        let intersect =
          expect
            (Config.resolve ~providers:(named [ "serper"; "linkup" ])
               ~permitted_providers:[ "serper"; "tavily" ] ())
        in
        A.(
          check bool "a permitted but disabled name is still permitted" true
            (Config.is_permitted intersect "tavily");
          check strings "effective is the intersection" [ "serper" ]
            (Config.effective_providers intersect)) )
  ; ( "a known but not enabled name loads"
    , fun () ->
        (* a permission set is not a typo list: a name in it that this deployment
           did not enable is the normal state of a narrowed server *)
        let cfg =
          expect
            (load
               "permitted_providers = [\"serper\", \"tavily\"]\n\
                [providers.serper]\nenabled = true\n")
        in
        A.(
          check strings "loads" [ "serper"; "tavily" ]
            (Option.value ~default:[] cfg.Config.permitted_providers);
          check strings "effective" [ "serper" ] (Config.effective_providers cfg)) )
  ; ( "an unknown name is refused naming the supported set"
    , fun () ->
        refuses_naming
          [ "permitted_providers names unknown provider(s) kagi"; permitted_supported_sentence ]
          (load "permitted_providers = [\"kagi\"]\n[providers.serper]\nenabled = true\n") )
  ; ( "the keyless fetch fallback is a name the set may hold"
   , fun () ->
        (* [jina] is not a provider name; it is in [permitted_fetch_names], the set
           a declared permission set has to be able to vouch for. *)
        let fetch_named =
          expect
            (Config.resolve ~providers:(named [ "serper" ])
               ~permitted_providers:[ "serper"; "jina" ] ())
        in
        A.(
          check bool "jina is permitted" true (Config.is_permitted fetch_named "jina");
          check strings "membership never enables" [ "serper" ]
            (Config.effective_providers fetch_named)) )
  ; ( "a set naming one unknown name is refused, and the known half is printed"
    , fun () ->
        refuses_naming [ "unknown provider(s) kagi"; "jina" ]
          (Config.resolve ~providers:(named [ "serper" ])
             ~permitted_providers:[ "serper"; "jina"; "kagi" ] ()) )
  ; ( "a retired spelling names its replacement here too"
    , fun () ->
        refuses_with "it is now \"exa:free\""
          (load "permitted_providers = [\"exa_free\"]\n[providers.serper]\nenabled = true\n") )
  ; ( "a name twice is refused"
    , fun () ->
        refuses_with "more than once"
          (load
             "permitted_providers = [\"serper\", \"serper\"]\n[providers.serper]\nenabled = true\n")
    )
  ; ( "the wildcard reads as unset, and nothing else in the list is validated"
    , fun () ->
        (* ["*"] is not a name, and a list meaning "everything" is the same list as
           no list — which is why nothing else in it is validated. *)
        let wildcard =
          expect
            (Config.resolve ~providers:(named [ "serper" ]) ~permitted_providers:[ "*"; "kagi" ] ())
        in
        A.(
          check (option strings) "wildcard reads as unset" None wildcard.Config.permitted_providers;
          check bool "permissive" true (Config.is_permitted wildcard "linkup");
          check strings "effective" [ "serper" ] (Config.effective_providers wildcard)) )
  ; ( "the absent key and the empty list are different answers"
    , fun () ->
        let empty =
          expect (Config.resolve ~providers:(named [ "serper" ]) ~permitted_providers:[] ())
        in
        A.(
          check (option strings) "declared empty" (Some []) empty.Config.permitted_providers;
          check bool "refuses the enabled name" false (Config.is_permitted empty "serper");
          check strings "effective is empty" [] (Config.effective_providers empty)) )
  ; ( "a name that is not a provider at all is refused"
    , fun () ->
        refuses_with "unknown provider(s) localhost"
          (load "permitted_providers = [\"localhost\"]\n[providers.serper]\nenabled = true\n") )
  ]

let policy_cases =
  [ ( "the caps and the timeout have defaults"
    , fun () ->
        let cfg = expect (Config.resolve ~providers:(named [ "exa" ]) ()) in
        A.(
          check int "snippet cap" 500 cfg.Config.policy.max_snippet_chars;
          check int "text cap" 2000 cfg.Config.policy.max_result_text_chars;
          check number "provider timeout" 10.0 cfg.Config.policy.provider_timeout_seconds;
          check bool "queries off" false cfg.Config.logging.log_queries;
          check bool "content off" false cfg.Config.logging.log_content) )
  ; ( "a cap is configurable"
    , fun () ->
        let raised =
          expect (load "[providers.exa]\nenabled = true\n[policy]\nmax_result_text_chars = 800\n")
        in
        A.(check int "configurable" 800 raised.Config.policy.max_result_text_chars) )
  ]

let fetch_extractor_cases =
  [ ( "the default backend is trafilatura"
    , fun () -> A.(check string "extractor" "trafilatura" Config.default_fetch_config.extractor) )
  ; ( "the second registry member loads"
    , fun () ->
        (* [stdlib] is what keeps [fetch] buildable on a bare install, so it has to
           survive a resolve rather than only a validation *)
        let bare =
          expect
            (Config.resolve
               ~providers:(named [ "serper" ])
               ~fetch:{ Config.default_fetch_config with extractor = "stdlib" }
               ())
        in
        A.(check string "stdlib accepted" "stdlib" bare.Config.fetch.extractor) )
  ; ( "an unknown backend is refused naming the registry"
    , fun () ->
        refuses_exactly
          "fetch.extractor names unknown extractor 'readability'; supported: stdlib, trafilatura"
          (Config.validate_fetch_extractor "readability") )
  ]

(* Every case reads the environment fresh: the Python suite's monkeypatch fixtures
   are function-scoped, [clear_keys] is this suite's way of the same. *)
let api_key_cases =
  [ ( "an enabled provider with no key is reported"
    , fun () ->
        clear_keys ();
        let cfg = expect (Config.resolve ~providers:(named [ "serper" ]) ()) in
        A.(check strings "missing" [ "serper" ] (Config.missing_api_keys cfg)) )
  ; ( "a flavoured name needs no key of its own"
    , fun () ->
        clear_keys ();
        let anonymous = expect (Config.resolve ~providers:(named [ "exa:free" ]) ()) in
        A.(check strings "nothing missing" [] (Config.missing_api_keys anonymous)) )
  ; ( "the key a flavour reads is the backend's"
    , fun () ->
        clear_keys ();
        setenv "SEEKWRIGHT_EXA_API_KEY" "k";
        let flavoured = expect (Config.resolve ~providers:(named [ "exa:free" ]) ()) in
        A.(
          check maybe_string "the key is the backend's" (Some "k") (Config.api_key flavoured "exa:free");
          check strings "nothing missing" [] (Config.missing_api_keys flavoured));
        unsetenv "SEEKWRIGHT_EXA_API_KEY")
  ; ( "the variable is named for the backend segment"
    , fun () ->
        A.(
          check string "bare name" "SEEKWRIGHT_EXA_API_KEY" (Config.api_key_env_var "exa");
          check string "flavoured name" "SEEKWRIGHT_EXA_API_KEY" (Config.api_key_env_var "exa:free");
          check string "parallel flavour" "SEEKWRIGHT_PARALLEL_API_KEY"
            (Config.api_key_env_var "parallel:free")) )
  ; ( "the billed half of a flavoured backend does need a key"
    , fun () ->
        clear_keys ();
        let billed = expect (Config.resolve ~providers:(named [ "exa" ]) ()) in
        A.(check strings "missing" [ "exa" ] (Config.missing_api_keys billed)) )
  ; ( "a provider whose key is present is not reported"
    , fun () ->
        clear_keys ();
        setenv "SEEKWRIGHT_SERPER_API_KEY" "k";
        let keyed = expect (Config.resolve ~providers:(named [ "serper" ]) ()) in
        A.(check strings "nothing missing" [] (Config.missing_api_keys keyed));
        unsetenv "SEEKWRIGHT_SERPER_API_KEY")
  ; ( "a disabled provider needs no key"
    , fun () ->
        clear_keys ();
        setenv "SEEKWRIGHT_SERPER_API_KEY" "k";
        let disabled =
          expect
            (Config.resolve
               ~providers:
                 [ ("serper", Config.default_provider_config)
                 ; ("linkup", { Config.default_provider_config with enabled = false }) ]
               ())
        in
        A.(check strings "nothing missing" [] (Config.missing_api_keys disabled));
        unsetenv "SEEKWRIGHT_SERPER_API_KEY")
  ]

let logging_cases =
  [ ( "the defaults are quiet, and text"
    , fun () ->
        let quiet = Config.default_logging_config in
        A.(
          check log_level "level" Config.Log_info quiet.level;
          check log_format "text, because stdio's reader" Config.Log_text quiet.format;
          check bool "queries" false quiet.log_queries;
          check bool "access log" false quiet.access_log;
          check log_level "library level" Config.Log_warning quiet.library_level) )
  ; ( "a config without the section still gets one"
    , fun () ->
        clear_keys ();
        setenv "SEEKWRIGHT_CONFIG" (write_config "[providers.serper]\nenabled = true\n");
        A.(
          check log_level "level" Config.Log_info
            (expect (Config.load None)).Config.logging.level);
        unsetenv "SEEKWRIGHT_CONFIG")
  ; ( "the section's keys load"
    , fun () ->
        clear_keys ();
        setenv "SEEKWRIGHT_CONFIG"
          (write_config
             "[providers.serper]\nenabled = true\n\n\
              [logging]\nlevel = \"DEBUG\"\nformat = \"json\"\nlog_queries = true\n");
        let section = (expect (Config.load None)).Config.logging in
        A.(
          check log_level "level" Config.Log_debug section.level;
          check log_format "format" Config.Log_json section.format;
          check bool "log_queries" true section.log_queries);
        unsetenv "SEEKWRIGHT_CONFIG")
  ; ( "an unknown level is a startup error naming the file"
    , fun () ->
        clear_keys ();
        let path =
          write_config "[providers.serper]\nenabled = true\n\n[logging]\nlevel = \"LOUD\"\n"
        in
        setenv "SEEKWRIGHT_CONFIG" path;
        refuses_with path (Config.load None);
        unsetenv "SEEKWRIGHT_CONFIG")
  ]

let dashboard_cases =
  [ ( "on by default, with no journal"
    , fun () ->
        A.(
          check bool "on" true Config.default_dashboard_config.enabled;
          check maybe_string "no journal until named" None
            Config.default_dashboard_config.history_path) )
  ; ( "a config without the section still gets one"
    , fun () ->
        clear_keys ();
        setenv "SEEKWRIGHT_CONFIG" (write_config "[providers.serper]\nenabled = true\n");
        A.(
          check bool "on" true (expect (Config.load None)).Config.dashboard.enabled);
        unsetenv "SEEKWRIGHT_CONFIG")
  ; ( "off, and the journal path is opt-in"
    , fun () ->
        clear_keys ();
        setenv "SEEKWRIGHT_CONFIG"
          (write_config
             "[providers.serper]\nenabled = true\n\n\
              [dashboard]\nenabled = false\nhistory_path = \"/tmp/usage.jsonl\"\n");
        let section = (expect (Config.load None)).Config.dashboard in
        A.(
          check bool "off" false section.enabled;
          check maybe_string "journal" (Some "/tmp/usage.jsonl") section.history_path);
        unsetenv "SEEKWRIGHT_CONFIG")
  ]

(* A key this server does not have is an error, not a shrug. *)
let typo_cases =
  [ ("top level", "notakey = 1\n")
  ; ("policy", "[policy]\nmax_snipet_chars = 50\n")
  ; ("fetch", "[fetch]\nmax_text_charts = 100\n")
  ; ("logging", "[logging]\nlevl = \"DEBUG\"\n")
  ; ("dashboard", "[dashboard]\nenabledd = true\n")
  ; ("provider", "[providers.serper]\nenabledd = true\n") ]

let test_a_typo_is_a_startup_error (section, text) =
  clear_keys ();
  let path = write_config ("[providers.serper]\nenabled = true\n\n" ^ text) in
  setenv "SEEKWRIGHT_CONFIG" path;
  (* a setting that parses, loads and does nothing is the failure mode every
     validator here exists to remove, so the fault has to name both the file the
     operator edits and the key they typed *)
  (match Config.load None with
  | Error fault ->
      if not (contains path fault) then A.failf "%s: the fault does not name %s" section path;
      if not (contains "unknown key" fault) then A.failf "%s: %s" section fault
  | Ok _ -> A.failf "%s: the typo loaded silently" section);
  unsetenv "SEEKWRIGHT_CONFIG"

let test_a_removed_key_says_so key =
  clear_keys ();
  let path = write_config (Printf.sprintf "[providers.serper]\nenabled = true\n\n[fetch]\n%s = 1\n" key) in
  setenv "SEEKWRIGHT_CONFIG" path;
  refuses_with key (Config.load None);
  unsetenv "SEEKWRIGHT_CONFIG"

let test_the_removed_knowledge_section_is_rejected () =
  let path = write_config "[providers.serper]\nenabled = true\n\n[knowledge]\nenabled = true\n" in
  refuses_with "knowledge" (Config.load (Some path))

(* ------------------------------------------------------------------ documents *)

let configuration_doc = "../docs/reference/configuration.md"
let deploying_doc = "../docs/reference/deploying.md"

(* The first TOML block of the configuration reference: the example an operator
   copies, so it is parsed and loaded here rather than quoted into this file. *)
let documented_example () =
  let text = read configuration_doc in
  match find_index "```toml" text with
  | None -> A.failf "%s has no TOML example" configuration_doc
  | Some at ->
      let start = at + String.length "```toml" in
      cut_at "```" (String.sub text start (String.length text - start))

let test_the_documented_example_loads () =
  clear_keys ();
  let cfg = expect (load (documented_example ())) in
  let enabled = Config.enabled_providers cfg in
  if enabled = [] then A.failf "the documented example enables nothing";
  (match cfg.Config.default_provider with
  | Some name when List.mem name enabled -> ()
  | other -> A.failf "the default %s is not one of the enabled names"
      (Option.value ~default:"(unset)" other));
  A.(
    check strings "the ladder" [ "linkup"; "exa:free" ]
      (Option.value ~default:[] cfg.Config.search.fallback))

(* A new config section that nobody documented fails here. The sections are
   {!Config.section_names}; the documented keys are the table headers of the
   example, plus the two top-level scalars it documents as comments above the
   value rather than as sections. *)
let test_the_example_documents_every_section () =
  let example = documented_example () in
  List.iter
    (fun section ->
      if not (contains ("[" ^ section) example || contains (section ^ " =") example) then
        A.failf "the example never documents the [%s] section" section)
    Config.section_names;
  List.iter
    (fun scalar ->
      if not (contains (scalar ^ " = ") example) then
        A.failf "the example never documents %s" scalar)
    [ "default_provider"; "permitted_providers" ]

(* Every provider that cannot start without a key is in the Secrets checklist:
   a mandatory key missing from it is a startup failure naming a variable the
   checklist never mentioned, which is how [algolia] was missed. *)
let test_the_secrets_block_names_every_mandatory_key_provider () =
  let block = fenced_block configuration_doc "## Secrets" "bash" in
  let named =
    let names = ref [] in
    List.iter
      (fun line ->
        if contains "export SEEKWRIGHT_" line && contains "_API_KEY=" line then
          match find_index "SEEKWRIGHT_" line with
          | Some at ->
              let rest = String.sub line at (String.length line - at) in
              let name = cut_at "_API_KEY=" rest in
              names := String.lowercase_ascii (String.sub name (String.length "SEEKWRIGHT_") (String.length name - String.length "SEEKWRIGHT_")) :: !names
          | None -> ()
        else ())
      (String.split_on_char '\n' block);
    !names
  in
  if block = "" then A.failf "%s has no Secrets block" configuration_doc;
  List.iter
    (fun provider ->
      let backend =
        match find_index ":" provider with
        | Some at -> String.sub provider 0 at
        | None -> provider
      in
      if not (List.mem backend named) then
        A.failf "the Secrets block omits %s" provider)
    Config.providers_requiring_key

let role block = fenced_block deploying_doc block "toml"

let test_the_search_role_cannot_fetch () =
  clear_keys ();
  let cfg = expect (load (role "### The search role")) in
  let enabled = Config.enabled_providers cfg in
  A.(check bool "fetch off" false cfg.Config.fetch.enabled);
  if enabled = [] then A.failf "the search role enables no provider";
  match cfg.Config.permitted_providers with
  | None -> A.failf "the search role declares no permission set"
  | Some permitted ->
      List.iter
        (fun name ->
          if not (List.mem name enabled) then
            A.failf "the search role permits %s, which it does not enable" name)
        permitted

let test_the_fetch_role_cannot_dispatch_a_provider () =
  clear_keys ();
  let cfg = expect (load (role "### The fetch role")) in
  A.(
    check bool "fetch on" true cfg.Config.fetch.enabled;
    check (option strings) "the empty set is not the unset one" (Some [])
      cfg.Config.permitted_providers;
    check strings "nothing missing" [] (Config.missing_api_keys cfg))

(* ------------------------------------------------------- the fetch fallbacks *)

let fallback_names rows = List.map (fun (row : Config.fetch_fallback) -> row.name) rows

(* A fallback this build has never heard of, which can bill: the tier rule asks
   each row's flag, never a name, so an unknown priced fallback falls under it. *)
let priced_elsewhere : Config.fetch_fallback =
  { Config.name = "pricedelsewhere"; billable = true; endpoint = Some "https://priced-elsewhere.example/"; fetch_key = None }

let registry_with_extra = Config.known_fetch_fallbacks @ [ priced_elsewhere ]

(* The validator refuses a repeated fallback and a paid one that is not last.
   Both are refusals rather than the recommended list's side effect: a duplicated
   line or [scrappa] in the middle would have billed the paid fallback twice, or
   billed it before the free renderer was ever asked. *)
let fetch_fallback_shape_cases =
  let registry = Config.known_fetch_fallbacks in
  (* the ladder is read back off the section, because that is what the fetch stack
     walks *)
  let ladder names =
    (expect (Config.resolve ~fetch:{ Config.default_fetch_config with fallback = Some names } ()))
      .Config.fetch.fallback
  in
  [ ( "the recommended shape passes"
    , fun () -> expect (Config.validate_fetch_fallbacks registry [ "crawl4ai"; "scrappa" ]) )
  ; ( "a single paid fallback passes"
    , fun () -> expect (Config.validate_fetch_fallbacks registry [ "scrappa" ]) )
  ; ( "a single free fallback passes"
    , fun () -> expect (Config.validate_fetch_fallbacks registry [ "crawl4ai" ]) )
  ; ( "a duplicated fallback is rejected"
    , fun () ->
        refuses_with "more than once" (Config.validate_fetch_fallbacks registry [ "scrappa"; "scrappa" ])
    )
  ; ( "a paid fallback that is not last is rejected"
    , fun () ->
        refuses_with "last" (Config.validate_fetch_fallbacks registry [ "scrappa"; "crawl4ai" ]) )
  ; ( "the walk switch cannot move the tier rule"
    , fun () ->
        (* [fetch.auto_fallback] says whether the ladder is walked, and nothing
           else: it cannot reorder one or admit a second priced name *)
        refuses_with "can bill" (Config.validate_fetch_fallbacks registry [ "scrappa"; "crawl4ai" ]) )
  ; ( "two priced fallbacks are refused with the walk on"
    , fun () ->
        refuses_with "can bill" (Config.validate_fetch_fallbacks registry [ "linkup"; "scrappa" ]) )
  ; ( "the walk is opt-in by default"
    , fun () ->
        (* off, because a caller who cannot act on a failure should not be handed
           one: the read fails, or comes back with its page, and the sentence names
           the configured providers as something to choose *)
        A.(check bool "auto_fallback" false Config.default_fetch_config.auto_fallback) )
  ; ( "an unknown fallback is refused with the registry printed"
    , fun () ->
        (* the registry is what a deployment can now be told to choose from; the
           [Literal] this replaces printed nothing of the kind *)
        refuses_exactly
          "fetch.fallback names unknown fallback(s) kagi; supported: crawl4ai, jina, linkup, \
           scrappa, tavily"
          (Config.validate_fetch_fallbacks registry [ "kagi" ]) )
  ; ( "keyed fallbacks are names the ladder takes"
    , fun () ->
        (* the two keyed fallbacks are provider names, and they bill, so both
           halves of the tier rule apply to them with no clause written for either *)
        A.(
          check (option strings) "three names" (Some [ "crawl4ai"; "jina"; "tavily" ])
            (ladder [ "crawl4ai"; "jina"; "tavily" ]);
          check (option strings) "a keyed pair" (Some [ "jina"; "linkup" ]) (ladder [ "jina"; "linkup" ]))
    )
  ; ( "a keyed paid fallback must still be last"
    , fun () ->
        refuses_with "can bill" (Config.validate_fetch_fallbacks registry [ "linkup"; "jina" ]) )
  ; ( "two keyed paid fallbacks are refused as well"
    , fun () ->
        (* three of the five registry rows can now bill, and two priced fallbacks
           cannot both be last: a page is priced by the fallback that served it, so
           a ladder with two of them would bill twice for one fetch *)
        refuses_naming [ "scrappa"; "tavily" ]
          (Config.validate_fetch_fallbacks registry [ "scrappa"; "tavily" ]) )
  ]

let priced_ladders =
  [ ["pricedelsewhere"; "crawl4ai"]; ["crawl4ai"; "pricedelsewhere"; "jina"]; ["pricedelsewhere"; "crawl4ai"; "scrappa"] ]

let test_the_paid_last_rule_asks_the_tier_not_the_name ladder =
  refuses_with "pricedelsewhere" (Config.validate_fetch_fallbacks registry_with_extra ladder)

let test_a_billable_fallback_still_belongs_at_the_end () =
  (* the rule is an ordering, not a ban: the new name is accepted where scrappa
     was. It cannot ride a resolve, because the resolve validates against this
     build's registry, not the one the case widened. *)
  expect
    (Config.validate_fetch_fallbacks registry_with_extra [ "crawl4ai"; "pricedelsewhere" ])

(* [fetch.primary] names the route an unnamed fetch leads with, and only that.
   What the validator refuses is a name outside the fallback registry, never a
   tier: a billable primary is the operator paying a named price for every
   unnamed fetch, the same decision [default_provider] allows. *)
let fetch_primary_cases =
  [ ( "the default is the local reader"
    , fun () ->
        A.(check string "primary" "http" Config.default_fetch_config.primary);
        expect (Config.validate_fetch_primary Config.known_fetch_fallbacks "http") )
  ; ( "the local reader can be named explicitly"
    , fun () ->
        let cfg =
          expect
            (Config.resolve
               ~fetch:{ Config.default_fetch_config with primary = "http" }
               ())
        in
        A.(check string "primary" "http" cfg.Config.fetch.primary) )
  ; ( "every registry name is admissible as a primary"
    , fun () ->
        (* the registry, not a hand-written list, is what the key accepts — and no
           name in it is refused for its tier *)
        List.iter
          (fun name -> expect (Config.validate_fetch_primary Config.known_fetch_fallbacks name))
          (fallback_names Config.known_fetch_fallbacks) )
  ; ( "a billable primary sits behind an ordinary ladder"
    , fun () ->
        (* the tier rule governs the walk, not the route that leads it: [scrappa]
           is refused mid-ladder and accepted as the primary, with the same name
           still last in the ladder behind it *)
        let cfg =
          expect
            (Config.resolve
               ~fetch:
                 { Config.default_fetch_config with
                   primary = "scrappa"
                 ; fallback = Some [ "crawl4ai"; "scrappa" ]
                 }
               ())
        in
        A.(
          check string "primary" "scrappa" cfg.Config.fetch.primary;
          check strings "the ladder behind it" [ "crawl4ai"; "scrappa" ]
            (Option.value ~default:[] cfg.Config.fetch.fallback)) )
  ; ( "an unknown route is refused with the supported names printed"
    , fun () ->
        (* a typo must not silently become the local reader *)
        refuses_exactly
          "fetch.primary names unknown route 'kagi'; supported: http, crawl4ai, jina, linkup, \
           scrappa, tavily"
          (Config.validate_fetch_primary Config.known_fetch_fallbacks "kagi") )
  ]

(* --------------------------------------------------------- the search ladders *)

(* [search.fallback] is the default route's ladder, and its shape is startup
   policy rather than a serving-path surprise: unlike fetch's fallbacks, one
   that cannot run is a config error, because the whole point is serving through
   an outage. *)
let search_section_cases =
  [ ( "the defaults are the quiet ones"
    , fun () ->
        let cfg = expect (Config.resolve ~providers:(named [ "serper" ]) ()) in
        A.(
          check (option strings) "no ladder by default" None cfg.Config.search.fallback;
          check number "health interval" 60.0 cfg.Config.search.health_interval_seconds;
          check int "health threshold" 3 cfg.Config.search.health_failure_threshold;
          check number "health cooldown" 120.0 cfg.Config.search.health_cooldown_seconds) )
  ; ( "a valid ladder loads"
    , fun () ->
        let ladder =
          expect
            (Config.resolve
               ~providers:(named [ "serper"; "linkup" ])
               ~default_provider:"serper"
               ~search:{ Config.default_search_config with fallback = Some [ "linkup" ] }
               ())
        in
        A.(
          check strings "the ladder" [ "linkup" ]
            (Option.value ~default:[] ladder.Config.search.fallback)) )
  ; ( "the default may appear in the ladder"
    , fun () ->
        (* it is skipped as already tried at walk time, not a config error *)
        let with_default =
          expect
            (Config.resolve
               ~providers:(named [ "serper"; "linkup" ])
               ~default_provider:"serper"
               ~search:{ Config.default_search_config with fallback = Some [ "serper"; "linkup" ] }
               ())
        in
        A.(
          check strings "the ladder keeps both" [ "serper"; "linkup" ]
            (Option.value ~default:[] with_default.Config.search.fallback)) )
  ; ( "a duplicated fallback is refused"
    , fun () ->
        refuses_with "more than once" (Config.validate_search_fallbacks [ "linkup"; "linkup" ]) )
  ; ( "an unknown name is refused"
    , fun () -> refuses_with "unknown provider" (Config.validate_search_fallbacks [ "kagi" ]) )
  ; ( "a known but disabled name is refused"
    , fun () ->
        (* the fallback has to be able to run: a disabled provider behind the
           default is ladder theatre, and fetch's inert-fallback allowance is
           deliberately not inherited here *)
        refuses_with "not an enabled provider"
          (Config.resolve
             ~providers:(named [ "serper" ])
             ~default_provider:"serper"
             ~search:{ Config.default_search_config with fallback = Some [ "linkup" ] }
             ()) )
  ; ( "the rejection is a startup error through the loader"
    , fun () ->
        refuses_with "not an enabled provider"
          (load "[providers.serper]\nenabled = true\n\n[search]\nfallback = [\"linkup\"]\n") )
  ]

(* The free set is a fact about the adapters, not about a pricing page: a name
   added here is a promise that the call cannot bill, and a name left out is a
   claim that it can. *)
let free_set_cases =
  [ ( "it is the five that cannot bill"
    , fun () ->
        A.(
          check strings "the free set"
            [ "exa:free"; "freeserp"; "parallel:free"; "searxng"; "tinyfish" ]
            (List.sort String.compare Config.free_providers)) )
  ; ( "the walk puts the keyless fallbacks first"
    , fun () ->
        A.(
          check strings "the free walk order"
            [ "exa:free"; "parallel:free"; "freeserp"; "searxng"; "tinyfish" ]
            Config.free_provider_order) )
  ; ( "the walk is a permutation of the set"
    , fun () ->
        (* the two are one fact and have to agree: a name in the order but not the
           set would be dropped by the walk silently *)
        A.(
          check strings "same names"
            (List.sort String.compare Config.free_providers)
            (List.sort String.compare Config.free_provider_order);
          check int "no name twice" (List.length Config.free_provider_order)
            (List.length (List.sort String.compare Config.free_provider_order))) )
  ; ( "every free name is a provider the package implements"
    , fun () ->
        List.iter
          (fun name ->
            if not (List.mem name Config.known_providers) then
              A.failf "%s is free but not a provider this package implements" name)
          Config.free_providers )
  ; ( "the metered allowances are not in it"
    , fun () ->
        (* each has a free *tier*; none of them *cannot bill* *)
        List.iter
          (fun name ->
            if List.mem name Config.free_providers then A.failf "%s can bill and is in the free set"
              name)
          [ "scrappa"; "tavily"; "algolia" ] )
  ; ( "tinyfish is free at any balance, and still keyed"
    , fun () ->
        A.(
          check bool "free" true (List.mem "tinyfish" Config.free_providers);
          check bool "keyed" true (List.mem "tinyfish" Config.providers_requiring_key)) )
  ]

(* The metered-allowance names: keyed, a free *tier*, and therefore billable, so
   out of every walk that routes without the caller naming them. *)
let billable_name_cases name =
  [ ( Printf.sprintf "%s is known" name
    , (fun () ->
        if not (List.mem name Config.known_providers) then A.failf "%s is not a known provider" name) )
  ; ( Printf.sprintf "%s requires a key" name
    , (fun () ->
        if not (List.mem name Config.providers_requiring_key) then A.failf "%s needs no key" name;
        A.(check string "the variable" (Printf.sprintf "SEEKWRIGHT_%s_API_KEY" (String.uppercase_ascii name))
          (Config.api_key_env_var name))) )
  ; ( Printf.sprintf "%s is not in the free set" name
    , (fun () -> if List.mem name Config.free_providers then A.failf "%s is free" name) )
  ; ( Printf.sprintf "%s is not in the free walk order" name
    , (fun () -> if List.mem name Config.free_provider_order then A.failf "%s is walked" name) )
  ; ( Printf.sprintf "%s is not a keyless default" name
    , (fun () ->
        if List.mem name Config.keyless_providers then A.failf "%s is an install default" name;
        if List.mem_assoc name Config.default.Config.providers then A.failf "%s is in the default config" name) )
  ; ( Printf.sprintf "an enabled %s makes the default route billable" name
    , (fun () ->
        let cfg = expect (Config.resolve ~providers:(named [ name ]) ()) in
        A.(
          check strings "enabled" [ name ] (Config.enabled_providers cfg);
          check maybe_string "the default resolves to it" (Some name) cfg.Config.default_provider;
          check bool "the free set no longer covers it" false (Config.default_route_is_free_only cfg))) )
  ; ( Printf.sprintf "a free ladder naming %s is rejected" name
    , (fun () -> refuses_with "can bill" (Config.validate_search_free_fallbacks [ name ])) )
  ; ( Printf.sprintf "%s is announced as untested" name
    , (fun () ->
        if not (List.mem name Config.untested_providers) then A.failf "%s is not announced untested" name;
        List.iter
          (fun untested ->
            if List.mem untested Config.known_providers |> not then
              A.failf "%s is announced but not implemented" untested)
          Config.untested_providers;
        List.iter
          (fun untested ->
            if List.mem untested Config.free_providers || List.mem untested Config.keyless_providers then
              A.failf "%s is announced untested and routed for free" untested)
          Config.untested_providers) ) ]

(* Keyless, and still in none of the sets that route without the caller naming it:
   the stance is the maintainer's — a named provider, never an auto-routed one —
   and these cases are what keep a future "it's free, so put it in" from
   reversing it silently. *)
let anysearch_cases =
  [ ( "anysearch is known"
    , fun () ->
        if not (List.mem "anysearch" Config.known_providers) then A.failf "anysearch is not known" )
  ; ( "it is keyless"
    , fun () ->
        (* no account exists to name, so no key guards it *)
        if List.mem "anysearch" Config.providers_requiring_key then
          A.failf "anysearch is guarded by a key" )
  ; ( "it is not in the free set"
    , fun () ->
        (* being unable to bill does not admit it to the walk *)
        if List.mem "anysearch" Config.free_providers then A.failf "anysearch is in the free set" )
  ; ( "it is not in the free walk order"
    , fun () -> if List.mem "anysearch" Config.free_provider_order then A.failf "anysearch is walked" )
  ; ( "it is not a keyless default"
    , fun () ->
        if List.mem "anysearch" Config.keyless_providers then A.failf "anysearch is an install default";
        if List.mem_assoc "anysearch" Config.default.Config.providers then
          A.failf "anysearch is in the default config" )
  ; ( "an enabled anysearch is reached by naming, not walking"
    , fun () ->
        let cfg = expect (Config.resolve ~providers:(named [ "anysearch" ]) ()) in
        A.(
          check strings "enabled" [ "anysearch" ] (Config.enabled_providers cfg);
          check maybe_string "naming is how it is reached" (Some "anysearch")
            cfg.Config.default_provider;
          check bool "a free-mode search has nothing to walk" false
            (Config.default_route_is_free_only cfg)) )
  ; ( "a free ladder naming it is rejected"
    , fun () -> refuses_with "can bill" (Config.validate_search_free_fallbacks [ "anysearch" ]) )
  ; ( "it is not in the untested set"
    , fun () ->
        (* the live test has run, so the name left the announced set *)
        if List.mem "anysearch" Config.untested_providers then
          A.failf "anysearch's live test has run, so it must not be announced untested" )
  ]

(* A name is what the operator writes in a config table and in an environment
   variable, so both forms of every name are checked. *)
let name_scheme_cases =
  [ ( "every name is a bare key or a known backend's flavour"
    , fun () ->
        (* Two names need a config value before they can be enabled at all, so the
           table carries it: the point here is the key form, not the missing-value
           rule. *)
        let required name =
          match name with
          | "searxng" -> "url = \"http://searx.internal:8080\"\n"
          | "algolia" -> "app_id = \"APP\"\nindex = \"idx\"\n"
          | _ -> ""
        in
        List.iter
          (fun name ->
            match find_index ":" name with
            | None ->
                let cfg =
                  expect
                    (load (Printf.sprintf "[providers.%s]\nenabled = true\n%s" name (required name)))
                in
                if not (List.mem name (Config.enabled_providers cfg)) then
                  A.failf "%s is not a bare TOML key" name
            | Some at ->
                let backend = String.sub name 0 at in
                if not (List.mem backend Config.known_providers) then
                  A.failf "%s qualifies %s, which is not a provider" name backend;
                if at + 1 >= String.length name then A.failf "%s carries an empty flavour" name;
                let cfg =
                  expect
                    (load (Printf.sprintf "[providers.\"%s\"]\nenabled = true\n%s" name (required name)))
                in
                if not (List.mem name (Config.enabled_providers cfg)) then
                  A.failf "%s does not round-trip quoted" name)
          Config.known_providers )
  ; ( "no name derives an illegal environment variable"
    , fun () ->
        clear_keys ();
        let providers =
          List.map
            (fun name ->
              let base = Config.default_provider_config in
              ( name,
                {
                  base with
                  url = (if name = "searxng" then Some "http://searx.internal:8080" else base.url);
                  app_id = (if name = "algolia" then Some "APP" else base.app_id);
                  index = (if name = "algolia" then Some "idx" else base.index);
                } ))
            Config.known_providers
        in
        let cfg = expect (Config.resolve ~providers ()) in
        (* What an [export] accepts. The name taken whole is the illegal spelling
           whenever it is flavoured -- that is why the split exists at all -- and
           the variable a name does derive has to sit inside this set. *)
        let legal_identifier text =
          text <> ""
          && List.for_all
               (fun c -> (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_')
               (List.init (String.length text) (String.get text))
        in
        List.iter
          (fun name ->
            let whole = "SEEKWRIGHT_" ^ String.uppercase_ascii name ^ "_API_KEY" in
            if contains ":" name && legal_identifier whole then
              A.failf "%s taken whole should not be an exportable variable: %s" name whole;
            let backend =
              match find_index ":" name with Some at -> String.sub name 0 at | None -> name
            in
            let variable = "SEEKWRIGHT_" ^ String.uppercase_ascii backend ^ "_API_KEY" in
            A.(check string (name ^ " derives its variable") variable (Config.api_key_env_var name));
            if not (legal_identifier variable) then
              A.failf "%s derives the unexportable %s" name variable;
            setenv variable "k";
            A.(
              check maybe_string (name ^ " reads the right variable") (Some "k")
                (Config.api_key cfg name));
            unsetenv variable)
          Config.known_providers )
  ]

(* [search.free_fallback] is the free-only mode's ladder: [search.fallback]'s
   shape plus the rule that makes the mode honest — no fallback that can bill.
   The mode's promise is a ceiling of zero, so a paid name is a startup error
   rather than a fallback the walk quietly declines to take. *)
let search_free_fallback_cases =
  [ ( "it is unset by default"
    , fun () ->
        let cfg = expect (Config.resolve ~providers:(named [ "serper" ]) ()) in
        A.(check (option strings) "unset" None cfg.Config.search.free_fallback) )
  ; ( "a valid free ladder loads, in the order it was written"
    , fun () ->
        let ladder =
          expect
            (Config.resolve
               ~providers:(named [ "exa:free"; "parallel:free" ])
               ~search:
                 { Config.default_search_config with free_fallback = Some [ "parallel:free"; "exa:free" ] }
               ())
        in
        A.(
          check strings "the ladder" [ "parallel:free"; "exa:free" ]
            (Option.value ~default:[] ladder.Config.search.free_fallback)) )
  ; ( "a provider that can bill is rejected, naming it"
    , fun () ->
        (* a free tier is an allowance that runs out — a price with a delay on it *)
        List.iter
          (fun name ->
            let outcome = Config.validate_search_free_fallbacks [ name ] in
            refuses_with "can bill" outcome;
            refuses_with name outcome)
          [ "scrappa"; "tavily"; "algolia" ] )
  ; ( "a duplicated free fallback is rejected"
    , fun () ->
        refuses_with "more than once"
          (Config.validate_search_free_fallbacks [ "exa:free"; "exa:free" ]) )
  ; ( "an unknown name is rejected"
    , fun () ->
        refuses_with "unknown provider" (Config.validate_search_free_fallbacks [ "kagi" ]) )
  ; ( "a known but disabled name is rejected"
    , fun () ->
        refuses_with "not an enabled provider"
          (Config.resolve
             ~providers:
               [ ("serper", Config.default_provider_config)
               ; ("exa:free", { Config.default_provider_config with enabled = false }) ]
             ~search:{ Config.default_search_config with free_fallback = Some [ "exa:free" ] }
             ()) )
  ; ( "the rejection is a startup error through the loader"
    , fun () ->
        let outcome =
          load "[providers.serper]\nenabled = true\n\n[search]\nfree_fallback = [\"tavily\"]\n"
        in
        refuses_with "tavily" outcome;
        refuses_with "can bill" outcome )
  ; ( "the sentence names the free set it is refusing against"
    , fun () ->
        refuses_exactly
          (Printf.sprintf "search.free_fallback names tavily, which can bill; a free-only search \
                           walks only %s" sorted_free_sentence)
          (Config.validate_search_free_fallbacks [ "tavily" ]) )
  ]

(* Agent mode's section: off by default, and incomplete-on is *reportable*. The
   three missing pieces are reported rather than raised, because two callers need
   the same fact at different temperatures — [server.main] refuses to start on it,
   [--check] prints it and keeps going — and both read [missing_agent_settings],
   so they cannot disagree about what "configured" means. *)
let agent_cases =
  [ ( "the defaults are off, and the plan's shape"
    , fun () ->
        let defaults = Config.default_agent_config in
        A.(
          check bool "off by default" false defaults.enabled;
          check maybe_string "no base url" None defaults.base_url;
          check maybe_string "no model" None defaults.model;
          check number "whole call" 90.0 defaults.timeout_seconds;
          check number "model request" 30.0 defaults.model_timeout_seconds;
          check int "material" 24000 defaults.max_material_chars;
          check int "brief" 500 defaults.max_output_tokens_brief;
          check int "report" 2500 defaults.max_output_tokens_report;
          check maybe_number "the early exit is on" (Some 0.25) defaults.max_cost_usd;
          check maybe_number "cost in unknown" None defaults.cost_per_1k_in;
          check maybe_number "cost out unknown" None defaults.cost_per_1k_out) )
  ; ( "a config without the section still gets one"
    , fun () ->
        clear_keys ();
        let without = expect (Config.resolve ~providers:(named [ "serper" ]) ()) in
        A.(
          check bool "off" false without.Config.agent.enabled;
          check strings "and reports nothing missing" [] (Config.missing_agent_settings without)) )
  ; ( "an unknown key in the section is a startup error"
    , fun () ->
        refuses_with "unknown key"
          (load "[providers.serper]\nenabled = true\n\n[agent]\nmodell = \"x\"\n") )
  ; ( "disabled needs nothing"
    , fun () ->
        clear_keys ();
        let without = expect (Config.resolve ~providers:(named [ "serper" ]) ()) in
        A.(check strings "nothing missing" [] (Config.missing_agent_settings without)) )
  ; ( "an enabled section missing everything names all three"
    , fun () ->
        clear_keys ();
        let bare =
          expect
            (Config.resolve
               ~providers:(named [ "serper" ])
               ~agent:{ Config.default_agent_config with enabled = true }
               ())
        in
        A.(
          check strings "all three"
            [ "agent.base_url"; "agent.model"; "SEEKWRIGHT_AGENT_API_KEY" ]
            (Config.missing_agent_settings bare)) )
  ; ( "the key comes from the environment only"
    , fun () ->
        (* never the config file — files get committed, like every provider key *)
        clear_keys ();
        setenv "SEEKWRIGHT_AGENT_API_KEY" "sk-from-env";
        let cfg =
          expect
            (load
               "[providers.serper]\nenabled = true\n\n[agent]\nenabled = true\n\
                base_url = \"https://model.test/v1\"\nmodel = \"m\"\n")
        in
        A.(
          check strings "nothing missing" [] (Config.missing_agent_settings cfg);
          check maybe_string "and reads it" (Some "sk-from-env") (Config.agent_api_key ()));
        unsetenv "SEEKWRIGHT_AGENT_API_KEY")
  ; ( "a complete section reports nothing"
    , fun () ->
        clear_keys ();
        setenv "SEEKWRIGHT_AGENT_API_KEY" "sk";
        let complete =
          expect
            (Config.resolve
               ~providers:(named [ "serper" ])
               ~agent:
                 { Config.default_agent_config with
                   enabled = true
                 ; base_url = Some "https://model.test/v1"
                 ; model = Some "m"
                 }
               ())
        in
        A.(check strings "nothing missing" [] (Config.missing_agent_settings complete));
        unsetenv "SEEKWRIGHT_AGENT_API_KEY")
  ]

(* ---------------------------------------------------------------- lax scalars *)

(* pydantic's lax scalar reading, ported because a quoted number is the commonest
   typo in a config file and the Python deployment has always taken it. The
   accepted and refused spellings were read off pydantic 2.14 and are pinned
   here, which is the stronger side of the pair. *)

let policy_with value =
  Config.load (Some (write_config (Printf.sprintf "[policy]\nmax_snippet_chars = %s\n" value)))

let fetch_with value =
  Config.load (Some (write_config (Printf.sprintf "[fetch]\ntimeout_seconds = %s\n" value)))

let logging_with value =
  Config.load (Some (write_config (Printf.sprintf "[logging]\nlog_content = %s\n" value)))

let snippet value =
  match policy_with value with
  | Ok cfg -> Some cfg.Config.policy.max_snippet_chars
  | Error _ -> None

let seconds value =
  match fetch_with value with
  | Ok cfg -> Some cfg.Config.fetch.timeout_seconds
  | Error _ -> None

let flag value =
  match logging_with value with
  | Ok cfg -> Some cfg.Config.logging.log_content
  | Error _ -> None

let test_an_integer_takes_a_whole_float () =
  A.(check (option int) "500.0" (Some 500) (snippet "500.0"));
  A.(check (option int) "1.000 is a whole number" (Some 1) (snippet "\"1.000\""));
  A.(check (option int) "500.5 has a fractional part" None (snippet "500.5"))

let test_an_integer_takes_a_quoted_number () =
  A.(
    check (option int) "quoted" (Some 500) (snippet "\"500\"");
    check (option int) "quoted float of zeros" (Some 500) (snippet "\"500.0\"");
    check (option int) "padded" (Some 400) (snippet "\" 400 \"");
    check (option int) "signed" (Some 7) (snippet "\"+7\"");
    check (option int) "digit separators" (Some 1000) (snippet "\"1_000\""))

let test_an_integer_refuses_what_is_not_one () =
  A.(
    check (option int) "not a number" None (snippet "\"abc\"");
    check (option int) "hexadecimal" None (snippet "\"0x10\"");
    check (option int) "an exponent" None (snippet "\"1e2\"");
    check (option int) "a trailing point" None (snippet "\"1.\"");
    check (option int) "a non-ASCII digit" None (snippet "\"١٢\"");
    check (option int) "past this build's int" None (snippet "\"99999999999999999999\""))

let test_a_number_takes_a_whole_number () =
  A.(
    check maybe_number "an integer for a duration" (Some 10.0) (seconds "10");
    check maybe_number "a quoted number" (Some 15.5) (seconds "\"15.5\"");
    check maybe_number "an exponent" (Some 100.0) (seconds "\"1e2\"");
    check maybe_number "separators" (Some 10.5) (seconds "\"1_0.5\""))

let test_a_number_takes_the_infinities () =
  (* pydantic reads the two infinities and a NaN from a string, so a duration
     written "inf" starts rather than refusing; the value's shape is what matters
     here, not its magnitude. *)
  let infinite value =
    match seconds value with
    | Some v -> Float.equal v Float.infinity || Float.equal v Float.neg_infinity
    | None -> false
  in
  let nan value =
    match seconds value with Some v -> Float.is_nan v | None -> false
  in
  A.(
    check bool "inf" true (infinite "\"inf\"");
    check bool "+infinity" true (infinite "\"+Infinity\"");
    check bool "-inf" true (infinite "\"-inf\"");
    check bool "nan" true (nan "\"nan\"");
    check bool "NAN" true (nan "\"NAN\""))

let test_a_number_refuses_what_is_not_one () =
  A.(
    check maybe_number "a word" None (seconds "\"abc\"");
    check maybe_number "hexadecimal" None (seconds "\"0x1p3\"");
    check maybe_number "a doubled separator" None (seconds "\"1__0\""))

let test_a_boolean_takes_its_twelve_spellings () =
  List.iter
    (fun spelling -> A.(check (option bool) spelling (Some true) (flag spelling)))
    [ "true"; "\"true\""; "\"TRUE\""; "\"yes\""; "\"y\""; "\"on\""; "\"t\""; "\"1\""; "1"; "1.0" ];
  List.iter
    (fun spelling -> A.(check (option bool) spelling (Some false) (flag spelling)))
    [ "false"; "\"false\""; "\"off\""; "\"no\""; "\"n\""; "\"f\""; "\"0\""; "0"; "0.0" ]

let test_a_boolean_refuses_everything_else () =
  A.(
    check (option bool) "a padded word" None (flag "\" tRuE \"");
    check (option bool) "another number" None (flag "2");
    check (option bool) "a fractional number" None (flag "2.5"))

(* ----------------------------------------------------------- the vocabularies *)

(* The frozen names, written out rather than recomputed: this is the row of
   tools/value_sets.json the port has to agree with, and a name that moves in the
   Python tree fails here before it can pass as a silent config change. *)
let test_the_frozen_vocabularies () =
  A.(
    check strings "known providers"
      [ "algolia"; "anysearch"; "deepseek"; "exa"; "exa:free"; "freeserp"; "linkup"
      ; "parallel"; "parallel:free"; "querit"; "scrappa"; "search1api"; "searxng"
      ; "serpapi"; "serper"; "tavily"; "tinyfish" ]
      Config.known_providers;
    check strings "the fetch-only permitted name" [ "jina" ] Config.permitted_fetch_names;
    check strings "extractors" [ "stdlib"; "trafilatura" ] Config.known_extractors;
    check strings "keyless" [ "exa:free"; "parallel:free"; "freeserp" ] Config.keyless_providers;
    check (list (pair string string)) "retired spellings"
      [ ("exa_free", "exa:free"); ("parallel_free", "parallel:free") ]
      (List.map (fun (a, b) -> (a, b)) Config.renamed_providers);
    check strings "untested" [ "deepseek"; "querit"; "search1api"; "serpapi" ]
      (List.sort String.compare Config.untested_providers);
    check strings "the fetch registry" [ "crawl4ai"; "jina"; "linkup"; "scrappa"; "tavily" ]
      (fallback_names Config.known_fetch_fallbacks);
    check strings "which of them bill" [ "linkup"; "scrappa"; "tavily" ]
      (fallback_names
         (List.filter (fun (row : Config.fetch_fallback) -> row.billable) Config.known_fetch_fallbacks));
    check string "the install's user agent"
      "seekwright/0.1.1 (+https://github.com/leoschwarz/seekwright)"
      Config.default_user_agent)

(* The keyless set is what the loader writes in when the file enabled nothing,
   so the two sites that report it — the startup line and [--check] — have one
   fact to read. *)
let test_the_keyless_default_reaches_every_route () =
  clear_keys ();
  let cfg = Config.default in
  A.(
    check strings "enabled" [ "exa:free"; "freeserp"; "parallel:free" ] (Config.enabled_providers cfg);
    check strings "effective" [ "exa:free"; "freeserp"; "parallel:free" ] (Config.effective_providers cfg);
    check bool "free only" true (Config.default_route_is_free_only cfg);
    check (option string) "no default is picked" None cfg.Config.default_provider);
  refuses_with "A config that needs no API key"
    (Config.load (Some (write_config "[providers.exa_free]\nenabled = true\n")))

(* A path is decided by the argument, then the environment, then the install
   default, and [~] expands either way. *)
(* A path is decided by the argument, then the environment, then the install
   default, and [~] expands either way. It is what [--check] and the startup line
   name, so it is a rule rather than a detail. *)
let config_path_cases =
  let home = Sys.getenv "HOME" in
  let installed = Filename.concat home ".config/seekwright/config.toml" in
  [ ( "an argument wins"
    , fun () ->
        clear_keys ();
        A.(check string "the argument" "/tmp/one.toml" (Config.config_path (Some "/tmp/one.toml"))) )
  ; ( "an empty argument is unset"
    , fun () ->
        clear_keys ();
        A.(check string "the install default" installed (Config.config_path (Some ""))) )
  ; ( "the install default is the user's config directory"
    , fun () ->
        clear_keys ();
        A.(check string "the install default" installed (Config.config_path None)) )
  ; ( "the environment is next"
    , fun () ->
        clear_keys ();
        setenv "SEEKWRIGHT_CONFIG" "/tmp/two.toml";
        A.(check string "the environment" "/tmp/two.toml" (Config.config_path None));
        clear_keys ())
  ; ( "and [~] expands there too"
    , fun () ->
        clear_keys ();
        setenv "SEEKWRIGHT_CONFIG" "~/.config/other.toml";
        A.(check string "expanded" (Filename.concat home ".config/other.toml") (Config.config_path None));
        clear_keys ())
  ]

(* The runner mirrors the Python file's classes: one suite each, and inside it one
   case per [def test_...]. The parameterised families ([typo_cases],
   [billable_name_cases], [priced_ladders]) are the Python [parametrize] decorators,
   so a name that moves fails the same way in both trees. *)
let cases name pairs =
  (name, List.map (fun (label, run) -> A.test_case label `Quick run) pairs)

let () =
  A.run "config"
    ([ ( "provider opt-in"
      , [ A.test_case "the keyless set" `Quick test_provider_opt_in
        ; A.test_case "a missing file is the keyless set" `Quick
            test_a_missing_config_file_is_the_keyless_set
        ; A.test_case "a disabled provider leaves the keyless set" `Quick
            test_a_provider_disabled_leaves_the_keyless_set
        ; A.test_case "the implicit set is marked implicit" `Quick
            test_the_implicit_set_is_marked_as_implicit
        ; A.test_case "a config naming something wrong names the file" `Quick
            test_a_config_naming_something_wrong_still_names_the_file
        ; A.test_case "a misspelled provider is a startup error" `Quick
            test_a_misspelled_provider_is_a_startup_error
        ; A.test_case "a named provider is loaded" `Quick test_a_named_provider_is_loaded
        ; A.test_case "a quoted flavoured table loads" `Quick
            test_a_quoted_flavoured_table_loads_and_enables
        ; A.test_case "an unquoted flavoured table is a TOML error" `Quick
            test_an_unquoted_flavoured_table_is_a_toml_error
        ; A.test_case "a renamed provider names its replacement" `Quick
            test_a_renamed_provider_names_its_replacement
        ] )
     ; cases "the free-only default route" free_only_cases
     ; cases "default provider" default_provider_cases
     ; cases "permitted providers" permitted_providers_cases
     ; cases "policy" policy_cases
     ; cases "fetch extractor" fetch_extractor_cases
     ; cases "api keys" api_key_cases
     ; cases "logging" logging_cases
     ; cases "dashboard" dashboard_cases
     ; cases
         "unknown keys"
         (List.map
            (fun (section, text) ->
              ( Printf.sprintf "a typo in the %s is a startup error" section
              , fun () -> test_a_typo_is_a_startup_error (section, text) ))
            typo_cases
         @ [ ( "max_age_seconds says so", fun () -> test_a_removed_key_says_so "max_age_seconds" )
           ; ( "refresh_token says so", fun () -> test_a_removed_key_says_so "refresh_token" )
           ; ( "the knowledge section is rejected"
             , fun () -> test_the_removed_knowledge_section_is_rejected () )
           ])
     ; ( "the documented example"
      , [ A.test_case "it loads" `Quick test_the_documented_example_loads
        ; A.test_case "every section is documented" `Quick
            test_the_example_documents_every_section
        ; A.test_case "the secrets block names every keyed provider" `Quick
            test_the_secrets_block_names_every_mandatory_key_provider
        ] )
     ; ( "the documented roles"
      , [ A.test_case "the search role cannot fetch" `Quick
            test_the_search_role_cannot_fetch
        ; A.test_case "the fetch role cannot dispatch" `Quick
            test_the_fetch_role_cannot_dispatch_a_provider
        ] )
     ]
    @ [ cases "fetch fallback shape" fetch_fallback_shape_cases
      ; cases
          "the paid-last rule asks the tier, not the name"
          (List.map
             (fun ladder ->
               ( Printf.sprintf "%s is refused by the tier of pricedelsewhere"
                   (String.concat " " ladder)
               , fun () -> test_the_paid_last_rule_asks_the_tier_not_the_name ladder ))
             priced_ladders
          @ [ ( "a billable fallback still belongs at the end"
              , fun () -> test_a_billable_fallback_still_belongs_at_the_end () ) ] )
      ; cases "fetch primary shape" fetch_primary_cases
      ; cases "search section" search_section_cases
      ; cases "the free set" free_set_cases
      ]
    @ List.map (fun name -> cases (Printf.sprintf "%s routing" name) (billable_name_cases name))
        [ "search1api"; "serpapi"; "querit"; "deepseek" ]
    @ [ cases "anysearch routing" anysearch_cases
      ; cases "provider name scheme" name_scheme_cases
      ; cases "search free fallback" search_free_fallback_cases
      ; cases "agent config" agent_cases
      ; ( "lax scalars"
        , [ A.test_case "an integer takes a whole float" `Quick
              test_an_integer_takes_a_whole_float
          ; A.test_case "an integer takes a quoted number" `Quick
              test_an_integer_takes_a_quoted_number
          ; A.test_case "an integer refuses what is not one" `Quick
              test_an_integer_refuses_what_is_not_one
          ; A.test_case "a number takes a whole number" `Quick
              test_a_number_takes_a_whole_number
          ; A.test_case "a number takes the infinities" `Quick
              test_a_number_takes_the_infinities
          ; A.test_case "a number refuses what is not one" `Quick
              test_a_number_refuses_what_is_not_one
          ; A.test_case "a boolean takes its twelve spellings" `Quick
              test_a_boolean_takes_its_twelve_spellings
          ; A.test_case "a boolean refuses everything else" `Quick
              test_a_boolean_refuses_everything_else
          ] )
      ; ( "the frozen vocabularies"
        , [ A.test_case "the names this build ships" `Quick test_the_frozen_vocabularies ] )
      ; ( "the keyless default"
        , [ A.test_case "it reaches every route" `Quick
              test_the_keyless_default_reaches_every_route
          ] )
      ; cases "config path" config_path_cases
      ])
