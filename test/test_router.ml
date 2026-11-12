(* The routing core, tested as the pure functions it is.

   No engine and no config object: a routing table is the whole input, which is
   the point of the seam — what a rewrite in another language has to reproduce
   is these answers, not the machinery that reads TOML to build a table. The
   same sentences are pinned from the caller's side by the engine suites; in
   Python those are tests/test_engine.py and tests/fetch/, and the two files
   agree because both copy one router.

   The port of tests/test_router.py has one case fewer in this file: "the
   module imports nothing of seekwright" is not a value to check but a
   dependency fact, so it lives in the build instead — lib/dune declares no
   [libraries], which is what refuses a reference outside this library, and
   test/dune pins what ocamldep resolves inside it. Both are the tools' own
   answer, which a grep of the source text cannot match. *)

module Router = Seekwright.Router
module A = Alcotest
open Test_support

(* The frozen free vocabulary: the oracle's FREE_PROVIDERS and FREE_PROVIDER_ORDER
   in src/seekwright/config.py. The Python suite imports those two symbols, so
   the free-vocabulary half of its sentences is recomputed; this suite carries
   the values and pins the sentences literally, which is the stronger of the two
   — a name that moves in config.py breaks here until the sentence moves with
   it, in the pull request that re-prints the frozen surface. P3 gives Config
   these constants, and the table fields below then read them while the pinned
   sentences stay. *)
let free_providers = [ "exa:free"; "parallel:free"; "freeserp"; "searxng"; "tinyfish" ]
let free_order = [ "exa:free"; "parallel:free"; "freeserp"; "searxng"; "tinyfish" ]

(* What a sentence quotes when it names the free set: [sorted(free)] there. *)
let sorted_free = "exa:free, freeserp, parallel:free, searxng, tinyfish"

(* A search table with the boring facts filled in. *)
let table ?(providers = [ "serper"; "linkup" ]) ?(default = Some "serper") ?permitted
    ?(fallback = []) ?(free_fallback = []) ?effective () =
  {
    Router.providers;
    default;
    permitted;
    fallback;
    free_fallback;
    free = free_providers;
    free_order;
    effective = (match effective with Some names -> names | None -> providers);
  }

let fetch_table ?(built = [ "crawl4ai"; "scrappa" ]) ?primary () = { Router.built; primary }

let rung_status =
  A.testable
    (fun fmt (status : Router.rung_status) ->
      Format.pp_print_string fmt (Router.show_rung_status status))
    ( = )

let show_rung fmt (rung : Router.rung) =
  Format.fprintf fmt "%s:%s" rung.name (Router.show_rung_status rung.status)

let rung = A.testable show_rung ( = )
let rungs = A.list rung

(* The sentence a refused call raises; a call that answers instead is the
   failure. Python spells the same assertion with pytest.raises. *)
let refused call =
  match call () with
  | _ -> A.fail "expected the router to refuse, and it answered"
  | exception Router.Route_refused sentence -> sentence

let check_refused what expected call = A.(check string) what expected (refused call)
let check_rungs what expected got = A.(check rungs) what expected got

let the_seam =
  [
    A.test_case "a table is a value and equal tables interchange" `Quick
      (fun () ->
        let one = table ~fallback:[ "linkup" ] () in
        let two = table ~fallback:[ "linkup" ] () in
        check_bool "equal tables carry the same facts" true (one = two);
        check_string "one answer"
          (Router.resolve_search one None)
          (Router.resolve_search two None);
        check_rungs "one plan"
          (Router.fallback_rungs one ~ladder:one.fallback ~tried:"serper" ~gated:[])
          (Router.fallback_rungs two ~ladder:two.fallback ~tried:"serper" ~gated:[]));
  ]

let resolve_search_cases =
  [
    A.test_case "a named provider is answered verbatim" `Quick (fun () ->
      check_string "named" "linkup" (Router.resolve_search (table ()) (Some "linkup")));
    A.test_case "an unnamed search takes the default" `Quick (fun () ->
      check_string "default" "serper" (Router.resolve_search (table ()) None));
    A.test_case "no default with a paid name enabled is the no default refusal" `Quick
      (fun () ->
        (* The refusal in full: it lists what is built and tells the caller to
           choose. *)
        let paid_and_free = table ~providers:[ "exa:free"; "serper" ] ~default:None () in
        check_refused "no default"
          "No default provider is configured; pass `provider`. Available: exa:free, serper."
          (fun () -> Router.resolve_search paid_and_free None));
    A.test_case "no default with an unbuilt paid name effective still refuses" `Quick
      (fun () ->
        (* "Every *enabled* name is free" is the rule, so an enabled-but-unbuilt
           paid name keeps the refusal: the walk is not a bet on what failed to
           build. Python matched only the sentence's opening; the whole sentence
           is pinned here because a built list that leaked the unbuilt name
           would pass the prefix match. *)
        let unbuilt =
          table ~providers:[ "exa:free" ] ~default:None
            ~effective:[ "exa:free"; "serper" ] ()
        in
        check_refused "effective, not built"
          "No default provider is configured; pass `provider`. Available: exa:free."
          (fun () -> Router.resolve_search unbuilt None));
    A.test_case "the unknown name refusal offers the default only when there is one" `Quick
      (fun () ->
        let built = [ "serper"; "tavily" ] in
        check_refused "with a default"
          "Provider 'linkup' is not enabled on this server. Available: serper, \
           tavily. Retry with one of those, or omit `provider` to use the default."
          (fun () ->
            Router.resolve_search
              (table ~providers:built ~default:(Some "serper") ())
              (Some "linkup"));
        check_refused "without one"
          "Provider 'linkup' is not enabled on this server. Available: serper, \
           tavily. Retry with one of those."
          (fun () ->
            Router.resolve_search (table ~providers:built ~default:None ()) (Some "linkup")));
    A.test_case "an unnamed search on an all free deployment walks the free set" `Quick
      (fun () ->
        (* No default and nothing that can bill: the refusal is replaced by the
           free walk's head, the same ending mode="free" reaches from the other
           direction. *)
        let all_free = table ~providers:[ "freeserp"; "exa:free" ] ~default:None () in
        check_string "the free walk's head" "exa:free" (Router.resolve_search all_free None));
    A.test_case "an unknown name on an empty deployment says none" `Quick (fun () ->
      check_refused "none"
        "Provider 'serper' is not enabled on this server. Available: none. \
         Retry with one of those."
        (fun () -> Router.resolve_search (table ~providers:[] ~default:None ()) (Some "serper")));
    A.test_case "an unpermitted name is refused with the permitted set" `Quick (fun () ->
      check_refused "permitted set"
        "Provider 'serper' is not permitted on this server. Permitted: linkup. \
         Retry with one of those, or omit `provider` to use the default."
        (fun () ->
          Router.resolve_search
            (table ~default:(Some "linkup") ~permitted:[ "linkup" ] ())
            (Some "serper")));
    A.test_case "an unpermitted name does not offer a default it would refuse again" `Quick
      (fun () ->
        (* The recovery clause is only worth saying when the retry would work. *)
        check_refused "no hollow recovery"
          "Provider 'serper' is not permitted on this server. Permitted: linkup. \
           Retry with one of those."
          (fun () ->
            Router.resolve_search
              (table ~default:(Some "serper") ~permitted:[ "linkup" ] ())
              (Some "serper")));
    A.test_case "an unpermitted default is refused rather than walked behind" `Quick
      (fun () ->
        check_refused "the default is refused"
          "The default provider 'serper' is not permitted on this server. \
           Permitted: linkup. Pass `provider` with one of those."
          (fun () ->
            Router.resolve_search
              (table ~default:(Some "serper") ~permitted:[ "linkup" ]
                 ~fallback:[ "linkup" ] ())
              None));
    A.test_case "mode free never consults the default" `Quick (fun () ->
      (* A paid default must not leak into a mode whose ceiling is zero. *)
      let paid_default =
        table ~providers:[ "serper"; "exa:free"; "parallel:free" ] ~default:(Some "serper") ()
      in
      check_string "free head" "exa:free"
        (Router.resolve_search paid_default ~mode:Router.Free None));
    A.test_case "the two reasons a free walk is empty do not read alike" `Quick (fun () ->
      (* The permission set is the key an operator has to fix; nothing free
         enabled is a different deployment entirely. *)
      let permitted_away =
        table ~providers:[ "exa:free"; "serper" ] ~default:None ~permitted:[ "serper" ] ()
      in
      check_refused "permitted away"
        ("No permitted free provider is enabled on this server, so a mode=\"free\" \
          search has nothing to try. Permitted: serper. The free providers are: "
        ^ sorted_free
        ^ ".")
        (fun () -> Router.resolve_search permitted_away ~mode:Router.Free None);
      let nothing_free = table ~providers:[ "serper" ] ~default:None () in
      let sentence = refused (fun () -> Router.resolve_search nothing_free ~mode:Router.Free None) in
      check_string "nothing free enabled"
        ("No free provider is enabled on this server, so a mode=\"free\" search \
          has nothing to try. The free providers are: "
        ^ sorted_free
        ^ ".")
        sentence;
      check_bool "and it does not name the permission set" false
        (contains ~haystack:sentence ~needle:"No permitted free provider"));
  ]

let free_route =
  [
    A.test_case "the operators order wins when they set one" `Quick (fun () ->
      let ordered =
        table ~providers:[ "parallel:free"; "exa:free" ] ~default:(Some "parallel:free")
          ~free_fallback:[ "parallel:free"; "exa:free" ] ()
      in
      check_strings "candidates" [ "parallel:free"; "exa:free" ] (Router.free_candidates ordered);
      check_strings "walk" [ "parallel:free"; "exa:free" ] (Router.free_walk ordered));
    A.test_case "an empty free fallback reads as unset" `Quick (fun () ->
      check_strings "the frozen order" free_order
        (Router.free_candidates (table ~free_fallback:[] ())));
    A.test_case "the walk drops the unbuilt the paid and the unpermitted" `Quick (fun () ->
      let narrowed =
        table ~providers:[ "exa:free"; "serper"; "freeserp" ] ~permitted:[ "exa:free"; "serper" ] ()
      in
      check_strings "one name left" [ "exa:free" ] (Router.free_walk narrowed));
    A.test_case "unnamed walks free is a truth table" `Quick (fun () ->
      let all_free = [ "exa:free"; "parallel:free"; "freeserp" ] in
      check_bool "no default, all free" true
        (Router.unnamed_walks_free (table ~providers:all_free ~default:None ()));
      check_bool "a default answers instead" false
        (Router.unnamed_walks_free
           (table ~providers:all_free ~default:(Some "exa:free") ()));
      check_bool "one paid name is enough to refuse" false
        (Router.unnamed_walks_free (table ~providers:[ "exa:free"; "serper" ] ~default:None ()));
      check_bool "nothing enabled is not an all-free deployment" false
        (Router.unnamed_walks_free (table ~providers:[] ~default:None ())));
    A.test_case "the permission set narrows the walk it feeds" `Quick (fun () ->
      (* effective is enabled ∩ permitted, so a set that removes every free name
         leaves the free route nothing to serve rather than something to refuse. *)
      let paid_only =
        table ~providers:[ "exa:free"; "serper" ] ~default:None ~permitted:[ "serper" ]
          ~effective:[ "serper" ] ()
      in
      check_bool "narrowed" false (Router.unnamed_walks_free paid_only));
  ]

let fallback_rungs_cases =
  [
    A.test_case "one rung per ladder entry in ladder order" `Quick (fun () ->
      let open Router in
      check_rungs "statuses"
        [
          { name = "a"; status = Candidate };
          { name = "tried"; status = Skip };
          { name = "ghost"; status = Skip };
          { name = "b"; status = Open };
        ]
        (Router.fallback_rungs (table ~providers:[ "a"; "b"; "tried" ] ())
           ~ladder:[ "a"; "tried"; "ghost"; "b" ]
           ~tried:"tried"
           ~gated:[ "b" ]));
    A.test_case "the permission check outranks the open breaker" `Quick (fun () ->
      (* An unpermitted rung is dead config the engine logs as a warning; a gated
         one is an ordinary skip. Reporting the breaker instead hides the config
         bug. *)
      match
        Router.fallback_rungs (table ~providers:[ "linkup" ] ~permitted:[] ())
          ~ladder:[ "linkup" ]
          ~tried:"serper"
          ~gated:[ "linkup" ]
      with
      | [ only ] -> A.(check rung_status) "unpermitted wins" Router.Unpermitted only.status
      | many -> A.failf "expected one rung, got %d" (List.length many));
    A.test_case "a route may hand the walk its own ladder" `Quick (fun () ->
      (* mode="free" passes its own list; the table's fallback is not consulted. *)
      let open Router in
      check_rungs "the caller's ladder" [ { name = "exa:free"; status = Candidate } ]
        (Router.fallback_rungs (table ~providers:[ "exa:free" ] ~fallback:[ "serper" ] ())
           ~ladder:[ "exa:free" ]
           ~tried:"parallel:free"
           ~gated:[]));
  ]

let fallback_sentences =
  [
    A.test_case "the served notice carries the adapters own notice beside it" `Quick (fun () ->
      check_string "no notice" "serper failed (503); served by linkup instead"
        (Router.fallback_served_notice ~tried:"serper" ~original_reason:"503" ~fallback:"linkup"
           ~notice:None);
      check_string "with one"
        "serper failed (503); served by linkup instead; site filters ignored"
        (Router.fallback_served_notice ~tried:"serper" ~original_reason:"503" ~fallback:"linkup"
           ~notice:(Some "site filters ignored"));
      (* Not in the Python suite: its condition is truthiness, so an adapter that
         sets notice to the empty string gets the same sentence as one that
         leaves it unset. Found by running the OCaml answers against the oracle. *)
      check_string "an empty notice is no notice"
        "serper failed (503); served by linkup instead"
        (Router.fallback_served_notice ~tried:"serper" ~original_reason:"503" ~fallback:"linkup"
           ~notice:(Some "")));
    A.test_case "exhaustion names the failed names and the mode promise" `Quick (fun () ->
      check_string "the names" " Fallbacks also failed: linkup, tavily."
        (Router.fallback_exhausted_note ~failed:[ "linkup"; "tavily" ] ~mode:None);
      check_string "the promise"
        " The server was asked for a free-only search, so no paid provider was tried."
        (Router.fallback_exhausted_note ~failed:[] ~mode:(Some Router.Free));
      check_string "both"
        " Fallbacks also failed: tinyfish. The server was asked for a free-only \
         search, so no paid provider was tried."
        (Router.fallback_exhausted_note ~failed:[ "tinyfish" ] ~mode:(Some Router.Free));
      check_string "neither" "" (Router.fallback_exhausted_note ~failed:[] ~mode:None));
    A.test_case "retry advice splits on quota" `Quick (fun () ->
      check_string "quota" " Do not retry immediately." (Router.retry_advice ~quota:true);
      check_string "not quota" " Retry shortly or try a different phrasing."
        (Router.retry_advice ~quota:false));
  ]

let fetch_route =
  [
    A.test_case "nothing named is the local read" `Quick (fun () ->
      A.(check (option string)) "local" None (Router.resolve_fetch (fetch_table ()) None));
    A.test_case "a built name is answered" `Quick (fun () ->
      A.(check (option string)) "built" (Some "scrappa")
        (Router.resolve_fetch (fetch_table ()) (Some "scrappa")));
    A.test_case "a name this deployment did not build is refused with the names it has" `Quick
      (fun () ->
        check_refused "available names"
          "Fetch provider 'scrappa' is not enabled on this server. Available: jina. \
           Retry with one of those, or omit `provider` to read the page locally."
          (fun () -> Router.resolve_fetch (fetch_table ~built:[ "jina" ] ()) (Some "scrappa")));
    A.test_case "the refusal names the operators route when a primary leads" `Quick (fun () ->
      check_refused "the operator's route"
        "Fetch provider 'crawl4ai' is not enabled on this server. Available: scrappa. \
         Retry with one of those, or omit `provider` to use this server's default route."
        (fun () ->
          Router.resolve_fetch (fetch_table ~built:[ "scrappa" ] ~primary:"scrappa" ())
            (Some "crawl4ai")));
    A.test_case "the refusal says nothing is configured rather than print an empty list" `Quick
      (fun () ->
        check_refused "nothing configured"
          "Fetch provider 'scrappa' is not enabled on this server. No other fetch provider \
           is configured on this server. Retry with one of those, or omit `provider` to \
           read the page locally."
          (fun () -> Router.resolve_fetch (fetch_table ~built:[] ()) (Some "scrappa")));
    A.test_case "the walk excludes the primary because the route already paid for it" `Quick
      (fun () ->
        check_strings "both" [ "crawl4ai"; "scrappa" ] (Router.fetch_walk (fetch_table ()));
        check_strings "minus the primary" [ "scrappa" ]
          (Router.fetch_walk (fetch_table ~primary:"crawl4ai" ())));
    A.test_case "the menu is the walk never the primary" `Quick (fun () ->
      let leading = fetch_table ~primary:"crawl4ai" () in
      check_string "built" "crawl4ai, scrappa" (Router.provider_names leading);
      check_string "the walk" "scrappa" (Router.choose_names leading);
      check_string "the offer"
        " Other configured fetch providers: scrappa. Retry once with `provider` set \
         to one of those before concluding the page cannot be read."
        (Router.choose_instead leading));
    A.test_case "a choice with no names in it is not a choice" `Quick (fun () ->
      (* Only the primary is built, so there is nothing left to offer. *)
      check_string "no menu" ""
        (Router.choose_instead (fetch_table ~built:[ "scrappa" ] ~primary:"scrappa" ())));
    A.test_case "the origin is the local reader or the operators primary" `Quick (fun () ->
      check_string "local" "local fetch" (Router.origin (fetch_table ()));
      check_string "named" "scrappa"
        (Router.origin (fetch_table ~built:[ "scrappa" ] ~primary:"scrappa" ())));
    A.test_case "the empty page notice offers the menu only when the walk is withheld" `Quick
      (fun () ->
        let short =
          "almost no readable text could be extracted (the page may be \
           JavaScript-rendered); try `search` for its content instead"
        in
        check_string "walked" short (Router.empty_notice (fetch_table ()) ~walked:true);
        check_string "nothing to walk" short
          (Router.empty_notice (fetch_table ~built:[] ()) ~walked:false);
        check_string "withheld"
          "Almost no readable text came back from the local fetcher. Other configured \
           fetch providers: crawl4ai, scrappa. A page that extracts to nothing usually \
           needs a browser, not a second try at the same reader: retry once with \
           `provider` set to one of those before concluding the page has no text."
          (Router.empty_notice (fetch_table ()) ~walked:false));
    A.test_case "a named primary is named back in the notice" `Quick (fun () ->
      (* Python checked the opening only; the whole sentence is pinned here, so
         both the quoted name and the menu that follows it are fixed. *)
      check_string "named source"
        "Almost no readable text came back from `scrappa`. Other configured fetch \
         providers: jina. A page that extracts to nothing usually needs a browser, \
         not a second try at the same reader: retry once with `provider` set to one \
         of those before concluding the page has no text."
        (Router.empty_notice (fetch_table ~built:[ "scrappa"; "jina" ] ~primary:"scrappa" ())
           ~walked:false));
    A.test_case "the refetch notice names the route that failed first" `Quick (fun () ->
      check_string "local first" "local fetch failed (HTTP 403); refetched via crawl4ai"
        (Router.refetched_notice (fetch_table ()) ~reason:"HTTP 403" ~fallback:"crawl4ai");
      check_string "the same name twice" "scrappa failed (rate limited); refetched via scrappa"
        (Router.refetched_notice
           (fetch_table ~built:[ "scrappa" ] ~primary:"scrappa" ())
           ~reason:"rate limited"
           ~fallback:"scrappa"));
  ]

let () =
  Alcotest.run "seekwright/router"
    [
      ( "the-seam", the_seam );
      ( "resolve-search", resolve_search_cases );
      ( "free-route", free_route );
      ( "fallback-rungs", fallback_rungs_cases );
      ( "fallback-sentences", fallback_sentences );
      ( "fetch-route", fetch_route );
    ]
