(* The server-flag scanner and the startup refusals — port of [tests/test_cli.py]'s
    [TestDispatch] and [TestTransportDispatch]: every valid and invalid flag
    combination reads as its exact sentence here, and the executable rules in
    [bin/] pin what the binary does with it (print on stderr, exit 2). *)

module Flags = Cli_flags

let parse argv =
  match Flags.parse argv with
  | Ok opts -> Ok opts
  | Error message -> Error message

let usage argv =
  match Flags.parse argv with
  | Error message -> message
  | Ok _ -> Alcotest.fail "a malformed command parsed"

(* {1 The valid shapes} *)

let test_bare_server () =
  match parse [] with
  | Ok opts ->
      Alcotest.(check bool) "not check" false opts.Flags.check;
      Alcotest.(check bool) "not http" false opts.Flags.http
  | Error m -> Alcotest.failf "bare parsed to an error: %s" m

let test_check () =
  match parse [ "--check" ] with
  | Ok opts -> Alcotest.(check bool) "check" true opts.Flags.check
  | Error m -> Alcotest.failf "--check: %s" m

let test_check_live () =
  match parse [ "--check"; "--live" ] with
  | Ok opts -> Alcotest.(check bool) "live" true opts.Flags.live
  | Error m -> Alcotest.failf "--check --live: %s" m

let test_http_with_bind_flags () =
  match parse [ "--http"; "--host"; "0.0.0.0"; "--port"; "8080"; "--allowed-host"; "kb.example" ] with
  | Ok opts ->
      Alcotest.(check (option string)) "host" (Some "0.0.0.0") opts.Flags.host;
      Alcotest.(check (option int)) "port" (Some 8080) opts.Flags.port;
      Alcotest.(check (list string)) "allowed_hosts" [ "kb.example" ] opts.Flags.allowed_hosts
  | Error m -> Alcotest.failf "--http with binds: %s" m

let test_allowed_host_repeats () =
  match parse [ "--http"; "--allowed-host"; "a.example"; "--allowed-host"; "b.example" ] with
  | Ok opts ->
      Alcotest.(check (list string)) "both kept" [ "a.example"; "b.example" ] opts.Flags.allowed_hosts
  | Error m -> Alcotest.failf "repeated --allowed-host: %s" m

let test_log_overrides () =
  match parse [ "--log-level"; "DEBUG"; "--log-format"; "json" ] with
  | Ok opts ->
      Alcotest.(check bool) "level set" true (opts.Flags.log_level <> None);
      Alcotest.(check bool) "format set" true (opts.Flags.log_format <> None)
  | Error m -> Alcotest.failf "log overrides: %s" m

let test_metrics_alone () =
  match parse [ "--metrics" ] with
  | Ok opts -> Alcotest.(check bool) "metrics" true opts.Flags.metrics
  | Error m -> Alcotest.failf "--metrics: %s" m

let test_metrics_json () =
  match parse [ "--metrics"; "--json" ] with
  | Ok opts -> Alcotest.(check bool) "json" true opts.Flags.json
  | Error m -> Alcotest.failf "--metrics --json: %s" m

(* {1 The combination guards — the parser.error sentences} *)

let test_metrics_combinations () =
  List.iter
    (fun argv ->
      Alcotest.(check string)
        (String.concat " " argv)
        "--metrics reports and exits; it cannot be combined with --check, --live, --http, --host, --port or --allowed-host"
        (usage argv))
    [
      [ "--metrics"; "--check" ];
      [ "--metrics"; "--live"; "--check" ];
      [ "--metrics"; "--http" ];
      [ "--metrics"; "--host"; "h" ];
      [ "--metrics"; "--port"; "1" ];
      [ "--metrics"; "--allowed-host"; "x" ];
    ]

let test_json_needs_metrics () =
  Alcotest.(check string) "--json alone"
    "--json only makes sense together with --metrics"
    (usage [ "--json" ])

let test_live_needs_check () =
  Alcotest.(check string) "--live alone"
    "--live only makes sense together with --check"
    (usage [ "--live" ])

let test_bind_flags_need_http () =
  List.iter
    (fun argv ->
      Alcotest.(check string) (String.concat " " argv)
        "--host, --port and --allowed-host only make sense together with --http"
        (usage argv))
    [ [ "--host"; "h" ]; [ "--port"; "8080" ]; [ "--allowed-host"; "x" ] ]

(* {1 Unknown and malformed flags} *)

let test_unknown_flag () =
  Alcotest.(check string) "unknown long flag" "unknown flag --nonsense" (usage [ "--nonsense" ])

let test_unexpected_positional () =
  Alcotest.(check string) "positional to the server verb" "unexpected argument search"
    (usage [ "search" ])

let test_flag_needs_value () =
  List.iter
    (fun flag -> Alcotest.(check string) flag (flag ^ " needs a value") (usage [ flag ]))
    [ "--host"; "--port"; "--allowed-host"; "--log-level"; "--log-format" ]

let test_port_must_be_a_port () =
  Alcotest.(check string) "not a number" "--port needs a port number"
    (usage [ "--http"; "--port"; "eighty" ]);
  Alcotest.(check string) "out of range" "--port needs a port number"
    (usage [ "--http"; "--port"; "70000" ])

let test_log_values () =
  Alcotest.(check string) "log level" "--log-level needs TRACE..CRITICAL"
    (usage [ "--log-level"; "LOUD" ]);
  Alcotest.(check string) "log format" "--log-format needs text or json"
    (usage [ "--log-format"; "yaml" ])

(* {1 The startup refusals} *)

(* A config built in memory: [Config.load] reads a file, and the refusals are
   facts about the config, so the suite writes one to the test's own directory
   and reads it back through the same loader the binary uses. *)
let with_config text f =
  let path = "test_startup_refusal.toml" in
  let ch = open_out path in
  output_string ch text;
  close_out ch;
  Unix.putenv "SEEKWRIGHT_CONFIG" path;
  match Seekwright.Config.load None with
  | Ok config ->
      let result = f config in
      Unix.putenv "SEEKWRIGHT_CONFIG" "";
      Sys.remove path;
      result
  | Error message ->
      Unix.putenv "SEEKWRIGHT_CONFIG" "";
      Sys.remove path;
      Alcotest.failf "the fixture config did not load: %s" message

let opts = Cli_flags.
  {
    check = false;
    live = false;
    metrics = false;
    json = false;
    http = false;
    host = None;
    port = None;
    allowed_hosts = [];
    log_level = None;
    log_format = None;
  }

let test_missing_api_key_names_the_variable () =
  with_config
    {|
[providers]
[providers.exa]
enabled = true
|}
    (fun config ->
      match Cli_flags.startup_refusal config opts with
      | Error message ->
          Alcotest.(check bool) "names the provider and its variable" true
            (try
               ignore (Str.search_forward (Str.regexp_string "exa (SEEKWRIGHT_EXA_API_KEY)") message 0);
               true
             with Not_found -> false)
      | Ok () -> Alcotest.fail "startup was allowed without the key")

let test_unbuildable_fetch_primary_refused () =
  with_config
    {|
[fetch]
enabled = true
primary = "tavily"
|}
    (fun config ->
      match Cli_flags.startup_refusal config opts with
      | Error message ->
          Alcotest.(check bool) "names the route and the way out" true
            (try
               ignore (Str.search_forward (Str.regexp_string "seekwright --check") message 0);
               true
             with Not_found -> false)
      | Ok () -> Alcotest.fail "startup was allowed on an unbuildable primary")

let test_incomplete_agent_refused () =
  with_config
    {|
[agent]
enabled = true
|}
    (fun config ->
      match Cli_flags.startup_refusal config opts with
      | Error message ->
          Alcotest.(check bool) "names what is missing" true
            (try
               ignore (Str.search_forward (Str.regexp_string "agent mode is enabled but missing") message 0);
               true
             with Not_found -> false)
      | Ok () -> Alcotest.fail "startup was allowed with agent mode half-configured")

let () =
  Alcotest.run "cli flags"
    [
      ( "valid shapes",
        [
          Alcotest.test_case "bare server" `Quick test_bare_server;
          Alcotest.test_case "--check" `Quick test_check;
          Alcotest.test_case "--check --live" `Quick test_check_live;
          Alcotest.test_case "--http with bind flags" `Quick test_http_with_bind_flags;
          Alcotest.test_case "--allowed-host repeats" `Quick test_allowed_host_repeats;
          Alcotest.test_case "log overrides" `Quick test_log_overrides;
          Alcotest.test_case "--metrics alone" `Quick test_metrics_alone;
          Alcotest.test_case "--metrics --json" `Quick test_metrics_json;
        ] );
      ( "combination guards",
        [
          Alcotest.test_case "--metrics stands alone" `Quick test_metrics_combinations;
          Alcotest.test_case "--json needs --metrics" `Quick test_json_needs_metrics;
          Alcotest.test_case "--live needs --check" `Quick test_live_needs_check;
          Alcotest.test_case "bind flags need --http" `Quick test_bind_flags_need_http;
        ] );
      ( "unknown and malformed",
        [
          Alcotest.test_case "unknown flag" `Quick test_unknown_flag;
          Alcotest.test_case "unexpected positional" `Quick test_unexpected_positional;
          Alcotest.test_case "flag needs a value" `Quick test_flag_needs_value;
          Alcotest.test_case "port must be a port" `Quick test_port_must_be_a_port;
          Alcotest.test_case "log level and format values" `Quick test_log_values;
        ] );
      ( "startup refusals",
        [
          Alcotest.test_case "missing key names its variable" `Quick test_missing_api_key_names_the_variable;
          Alcotest.test_case "unbuildable fetch.primary" `Quick test_unbuildable_fetch_primary_refused;
          Alcotest.test_case "incomplete agent mode" `Quick test_incomplete_agent_refused;
        ] );
    ]
