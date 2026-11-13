(* The [--check] report's pure parts — port of [tests/test_cli.py]'s
   [TestCheckStreams] and the inert/unsupported-feature reporting: what the
   report says about a config, without dialling anything. The full report
   needs a network, so this suite drives the pieces the report is built
   from — the default-route line, the transitional-feature list, and the
   fetch and agent blocks through the [emit] callback. *)

module Config = Seekwright.Config

let load text =
  let path = "test_cli_check_fixture.toml" in
  let ch = open_out path in
  output_string ch text;
  close_out ch;
  Unix.putenv "SEEKWRIGHT_CONFIG" path;
  let result =
    match Config.load None with
    | Ok config -> `Config config
    | Error message -> `Error message
  in
  Unix.putenv "SEEKWRIGHT_CONFIG" "";
  (match Sys.file_exists path with true -> Sys.remove path | false -> ());
  result

let lines config =
  let out = ref [] in
  let n1 = Cli_check.report_fetch (fun line -> out := !out @ [ line ]) config 0 in
  let n2 = Cli_check.report_agent (fun line -> out := !out @ [ line ]) config n1 in
  (n2, !out)

(* {1 The default route line} *)

let test_default_named () =
  match load {|
default_provider = "exa"

[providers.exa]
enabled = true
|} with
  | `Config config ->
      Alcotest.(check string) "named" "exa" (Cli_check.default_route_line config)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_no_default_billed () =
  (* Two enabled names and no [default_provider]: the config refuses to pick,
     because picking for the caller is cost-guessing. One name alone would not
     test this — the config resolves a lone enabled name into the default. *)
  match load {|
[providers]
[providers.exa]
enabled = true
[providers.parallel]
enabled = true
|} with
  | `Config config ->
      Alcotest.(check string) "must name a provider" "none (callers must pass provider)"
        (Cli_check.default_route_line config)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_no_default_all_free () =
  (* the empty set is the keyless set, and a keyless-only deployment walks
     the free set instead of demanding a provider — the same route decision
     [router.py]'s guard pins, seen from the report's side. *)
  match load {|
[providers]
[providers."exa:free"]
enabled = true
[providers."parallel:free"]
enabled = true
[providers.freeserp]
enabled = true
|} with
  | `Config config ->
      Alcotest.(check string) "free walk" "none (a bare search walks the free set)"
        (Cli_check.default_route_line config)
  | `Error m -> Alcotest.failf "fixture: %s" m

(* {1 Transitional features — the inert-key report} *)

let transitional text =
  match load text with
  | `Config config -> Cli_check.transitional_features config
  | `Error m -> Alcotest.failf "fixture: %s" m

let feature_names rows = List.map fst rows

let test_cache_dir_inert () =
  let rows =
    transitional
      {|
[fetch]
enabled = true
cache_dir = "/var/cache/seekwright"
|}
  in
  Alcotest.(check (list string)) "cache is named" [ "cache" ] (feature_names rows);
  match rows with
  | [ (_, detail) ] ->
      Alcotest.(check bool) "the detail names the key and the phase" true
        (try
           ignore (Str.search_forward (Str.regexp_string "no page cache is built on this port") detail 0);
           true
         with Not_found -> false)
  | _ -> Alcotest.fail "one row expected"

let test_requested_fallback_routes_aggregated () =
  let rows =
    transitional
      {|
[fetch]
enabled = true
primary = "jina"
fallback = ["crawl4ai", "jina"]
|}
  in
  Alcotest.(check (list string)) "fallback is named" [ "fallback" ] (feature_names rows);
  match rows with
  | [ (_, detail) ] ->
      (* the ladder and the primary are named once each, sorted, deduped *)
      Alcotest.(check bool) "the routes are spelled out" true
        (try
           ignore (Str.search_forward (Str.regexp_string "crawl4ai, jina") detail 0);
           true
         with Not_found -> false)
  | _ -> Alcotest.fail "one row expected"

let test_crawl4ai_url_alone_asks_for_a_route () =
  let rows =
    transitional
      {|
[fetch]
enabled = true
crawl4ai_url = "http://renderer:11235"
|}
  in
  match rows with
  | [ ("fallback", detail) ] ->
      Alcotest.(check bool) "the configured endpoint is itself a route" true
        (try
           ignore (Str.search_forward (Str.regexp_string "fetch.crawl4ai_url") detail 0);
           true
         with Not_found -> false)
  | other -> Alcotest.failf "expected one fallback row, got %d" (List.length other)

let test_disabled_fetch_reports_nothing () =
  let rows =
    transitional
      {|
[fetch]
enabled = false
cache_dir = "/var/cache/seekwright"
|}
  in
  Alcotest.(check int) "a disabled fetch configures nothing" 0 (List.length rows)

(* {1 The fetch and agent blocks} *)

let test_fetch_block_states_the_private_address_stance () =
  match load {|
[fetch]
enabled = true
|} with
  | `Config config ->
      let problems, out = lines config in
      Alcotest.(check int) "no problems on the default fetch config" 0 problems;
      Alcotest.(check bool) "the reader is stated" true
        (List.mem "  primary   http (the local reader)" out);
      Alcotest.(check bool) "blocked by default" true
        (try
           ignore
             (List.find
                (fun line ->
                  try
                    ignore (Str.search_forward (Str.regexp_string "private addresses blocked") line 0);
                    true
                  with Not_found -> false)
                out);
           true
         with Not_found -> false)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_unbuildable_primary_counts_a_problem () =
  match load {|
[fetch]
enabled = true
primary = "tavily"
|} with
  | `Config config ->
      let problems, out = lines config in
      Alcotest.(check int) "the row counts" 1 problems;
      Alcotest.(check bool) "and says what it is" true
        (try
           ignore
             (List.find
                (fun line ->
                  try
                    ignore (Str.search_forward (Str.regexp_string "primary   tavily unsupported on this port") line 0);
                    true
                  with Not_found -> false)
                out);
           true
         with Not_found -> false)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_agent_incomplete_counts_a_problem () =
  match load {|
[agent]
enabled = true
model = "m"
|} with
  | `Config config ->
      let problems, out = lines config in
      Alcotest.(check int) "one problem" 1 problems;
      Alcotest.(check bool) "names what is missing" true
        (try
           ignore
             (List.find
                (fun line ->
                  try
                    ignore (Str.search_forward (Str.regexp_string "enabled but incomplete") line 0);
                    true
                  with Not_found -> false)
                out);
           true
         with Not_found -> false)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_agent_off_is_quiet () =
  match load {||} with
  | `Config config ->
      let problems, out = lines config in
      Alcotest.(check int) "nothing to report" 0 problems;
      Alcotest.(check bool) "disabled in config" true (List.mem "  disabled in config" out)
  | `Error m -> Alcotest.failf "fixture: %s" m

let () =
  Alcotest.run "cli check"
    [
      ( "default route",
        [
          Alcotest.test_case "a configured default" `Quick test_default_named;
          Alcotest.test_case "no default, a billed name enabled" `Quick test_no_default_billed;
          Alcotest.test_case "no default, all free" `Quick test_no_default_all_free;
        ] );
      ( "inert features",
        [
          Alcotest.test_case "cache_dir is inert on this port" `Quick test_cache_dir_inert;
          Alcotest.test_case "the requested routes are aggregated" `Quick test_requested_fallback_routes_aggregated;
          Alcotest.test_case "a configured crawl4ai url is a route" `Quick test_crawl4ai_url_alone_asks_for_a_route;
          Alcotest.test_case "a disabled fetch reports nothing" `Quick test_disabled_fetch_reports_nothing;
        ] );
      ( "report blocks",
        [
          Alcotest.test_case "the fetch block states the SSRF stance" `Quick test_fetch_block_states_the_private_address_stance;
          Alcotest.test_case "an unbuildable primary counts a problem" `Quick test_unbuildable_primary_counts_a_problem;
          Alcotest.test_case "half-configured agent mode counts a problem" `Quick test_agent_incomplete_counts_a_problem;
          Alcotest.test_case "agent off is quiet" `Quick test_agent_off_is_quiet;
        ] );
    ]
