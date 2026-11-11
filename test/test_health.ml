(* The health board, its probe, and one monitor tick — ported case for case from
   tests/test_health.py.

   Two differences are worth stating up front. The board's clock is [asyncio]
   time in Python, and the suite there sleeps 60ms past a 50ms cooldown; this
   port injects the clock, so the half-open cases move it by hand and the
   cooldown is an exact number rather than a race. And the probe's table is a
   parameter here (see health.mli), so the rows Python's module-level [_PROBES]
   supplies are built by hand below, one per name under test.

   One case cannot cross: [test_the_table_covers_every_name_the_monitor_probes]
   asks [build_providers] which names exist and duck-types [warmup] to split
   them. Neither exists in this tree — the factory is P5's other half and the
   MCP-backed adapters are deferred — so the split is pinned instead by naming
   the rows the port builds, and by [built] in the monitor case. *)

module Caps = Mcp_caps
module Config = Seekwright.Config
module Health = Seekwright.Health
module Provider = Seekwright.Provider
module A = Alcotest

let outcome =
  A.testable (fun fmt o -> Format.pp_print_string fmt (Health.show_outcome o)) ( = )

(* {1 The environment}

   Keys come from the environment only, and OCaml 5.3 has no [unsetenv], so "no
   key" is an empty value: [Config.api_key] reads an empty variable as unset. *)
let setenv = Unix.putenv
let unsetenv name = Unix.putenv name ""
let keyed name key = setenv (Config.api_key_env_var name) key
let keyless name = unsetenv (Config.api_key_env_var name)

(* {1 The board} *)

(* The Python suite's [HealthBoard(failure_threshold=2, cooldown_seconds=0.05)]:
   the numbers are per case, and the clock is a reference the case advances. *)
let board ?(threshold = Health.default_failure_threshold)
    ?(cooldown = Health.default_cooldown_seconds) ?(clock = ref 0.) () =
  let lines = ref [] in
  let board =
    Health.create ~now:(fun () -> !clock) ~failure_threshold:threshold
      ~cooldown_seconds:cooldown
      ~log:(fun _level event fields -> lines := (event, fields) :: !lines)
      ()
  in
  (* loguru renders the bound fields plus the call's own; the assertion reads
     them sorted so a case can name the whole set. *)
  let rendered fields =
    fields |> List.map (fun (k, v) -> (k, Yojson.Safe.to_string v)) |> List.sort compare
  in
  let events name =
    !lines |> List.rev |> List.filter_map (fun (event, fields) ->
        if event = name then Some (rendered fields) else None)
  in
  (board, events)

(* {1 The probe seam}

   [Provider.Net.t] is the analogue of [httpx.MockTransport]: it records what was
   dialed and answers with a canned status or a transport failure. *)
let dial ?(status = 200) ?refusal () =
  let sent = ref [] in
  let net =
    {
      Provider.Net.request =
        (fun request ->
          sent := request :: !sent;
          match refusal with
          | Some message -> Error (Caps.Error.make ~message Caps.Error.Unavailable)
          | None -> Ok { Caps.Authority.Net.status; headers = []; body = "" });
    }
  in
  (net, fun () -> List.rev !sent)

(* The net one monitor tick drives: one host unreachable, one rejecting its key,
   every other answering 200. It records the host it dialed, which is how the
   case says which names were probed at all. *)
let selective_net () =
  let hosts = ref [] in
  let net =
    {
      Provider.Net.request =
        (fun request ->
          let host = Uri.host_with_default ~default:"" request.Caps.Authority.Net.uri in
          hosts := host :: !hosts;
          match host with
          | "api.linkup.so" ->
            Error (Caps.Error.make ~message:"no route" Caps.Error.Unavailable)
          | "google.serper.dev" ->
            Ok { Caps.Authority.Net.status = 403; headers = []; body = "" }
          | _ -> Ok { Caps.Authority.Net.status = 200; headers = []; body = "" });
    }
  in
  (net, fun () -> List.rev !hosts)

let header (request : Caps.Authority.Net.request) name =
  List.find_map
    (fun (k, v) -> if String.equal (String.lowercase_ascii k) name then Some v else None)
    request.Caps.Authority.Net.headers

let url (request : Caps.Authority.Net.request) =
  Uri.to_string request.Caps.Authority.Net.uri

let one_request sent =
  match sent () with
  | [ request ] -> request
  | other -> A.failf "expected one request, got %d" (List.length other)

(* The rows Python's [_PROBES] holds as module data. Only the names under test
   appear: the factory builds the full table from the adapters' own endpoint
   constants, and the builders below are the pieces it builds them from. *)
let no_headers _ _ = []
let row ?(headers = no_headers) endpoint = { Health.endpoint; headers }
let const endpoint = Health.probe_endpoint_const endpoint

let table =
  [
    ( "serper",
      row ~headers:(Health.probe_headers_const "X-API-KEY")
        (const "https://google.serper.dev/search") );
    ( "parallel",
      row ~headers:(Health.probe_headers_const "x-api-key")
        (const "https://api.parallel.ai/v1/search") );
    ( "linkup",
      row ~headers:(Health.probe_headers_const ~prefix:"Bearer " "Authorization")
        (const "https://api.linkup.so/v1/search") );
    ("searxng", row Health.searxng_endpoint);
    ("algolia", row ~headers:Health.algolia_headers Health.algolia_endpoint);
  ]

let config_with providers = { Config.default with providers }
let at_url url = { Config.default_provider_config with Config.url = Some url }

let scoped app_id index =
  { Config.default_provider_config with app_id = Some app_id; index = Some index }

let check name f = A.test_case name `Quick f

(* {1 The board's state machine} *)

let below_the_threshold_stays_closed_and_silent () =
  let board, events = board ~threshold:2 ~cooldown:0.05 () in
  Health.record_failure board ~reason:"upstream 503" "serper" ();
  A.(check bool) "closed" false (Health.is_open board "serper");
  A.(check (float 1e-9) "nothing is open for" 0.0 (Health.open_for_s board "serper"));
  A.(check int) "and nothing was logged" 0 (List.length (events "health.open"))

let reaching_the_threshold_opens_once_with_its_fields () =
  let board, events = board ~threshold:2 ~cooldown:0.05 () in
  Health.record_failure board ~reason:"upstream 503" "serper" ();
  Health.record_failure board ~reason:"upstream 503" "serper" ();
  A.(check bool) "open" true (Health.is_open board "serper");
  A.(check A.(list (list (pair string string)))) "one line, with its fields"
    [
      [
        ("consecutive", "2"); ("provider", "\"serper\""); ("reason", "\"upstream 503\"");
      ];
    ]
    (events "health.open")

let a_failure_while_open_extends_the_gate_without_relogging () =
  let board, events = board ~threshold:2 ~cooldown:60. () in
  List.iter (fun reason -> Health.record_failure board ~reason "serper" ()) [ "a"; "b"; "c" ];
  A.(check bool) "open" true (Health.is_open board "serper");
  A.(check (A.list string)) "the second failure opened it; the third only extended it"
    [ "\"b\"" ]
    (List.filter_map (fun fields -> List.assoc_opt "reason" fields) (events "health.open"))

let expiry_is_half_open_and_one_failure_reopens () =
  let clock = ref 0. in
  let board, events = board ~threshold:2 ~cooldown:0.05 ~clock () in
  Health.record_failure board ~reason:"a" "serper" ();
  Health.record_failure board ~reason:"b" "serper" ();
  clock := 0.06;
  A.(check bool) "an expired gate reads closed" false (Health.is_open board "serper");
  Health.record_failure board ~reason:"again" "serper" ();
  A.(check bool) "and one failure re-opens it" true (Health.is_open board "serper");
  A.(check (A.list string)) "two opens, the second named for the new failure"
    [ "\"b\""; "\"again\"" ]
    (List.filter_map (fun fields -> List.assoc_opt "reason" fields) (events "health.open"))

let half_open_reopens_without_the_threshold () =
  (* The re-open branch, isolated from the threshold: the count stays far below
     it the whole time. *)
  let clock = ref 0. in
  let board, events = board ~threshold:10 ~cooldown:0.05 ~clock () in
  Health.record_failure board ~reason:"down" ~force_open:true "serper" ();
  clock := 0.06;
  A.(check bool) "the gate expired" false (Health.is_open board "serper");
  Health.record_failure board ~reason:"still down" "serper" ();
  A.(check bool) "one failure re-opens it, eight short of the threshold" true
    (Health.is_open board "serper");
  A.(check int) "two opens" 2 (List.length (events "health.open"))

let a_success_while_armed_closes_and_resets_the_count () =
  let board, events = board ~threshold:2 ~cooldown:60. () in
  Health.record_failure board ~reason:"a" "serper" ();
  Health.record_failure board ~reason:"b" "serper" ();
  Health.record_success board ~reason:"search succeeded" "serper" ();
  A.(check bool) "closed" false (Health.is_open board "serper");
  A.(check (float 1e-9) "no time left on the gate" 0.0 (Health.open_for_s board "serper"));
  A.(check A.(list (list (pair string string)))) "health.closed names who closed it"
    [ [ ("provider", "\"serper\""); ("reason", "\"search succeeded\"") ] ]
    (events "health.closed");
  (* the count was reset, so the threshold applies from zero again *)
  Health.record_failure board ~reason:"c" "serper" ();
  A.(check bool) "one failure is not a trip" false (Health.is_open board "serper");
  Health.record_failure board ~reason:"d" "serper" ();
  A.(check bool) "two is" true (Health.is_open board "serper")

let a_success_on_a_never_armed_board_logs_nothing () =
  let board, events = board () in
  Health.record_success board ~reason:"search succeeded" "serper" ();
  A.(check int) "no close line" 0 (List.length (events "health.closed"));
  A.(check int) "no open line" 0 (List.length (events "health.open"))

let force_open_opens_from_zero_failures () =
  let board, events = board ~threshold:3 ~cooldown:60. () in
  Health.record_failure board ~reason:"probe key rejected" ~force_open:true "serper" ();
  A.(check bool) "open at once" true (Health.is_open board "serper");
  A.(check A.(list (list (pair string string)))) "on the first failure"
    [
      [
        ("consecutive", "1"); ("provider", "\"serper\""); ("reason", "\"probe key rejected\"");
      ];
    ]
    (events "health.open")

let an_unknown_name_reads_closed () =
  let board, _ = board () in
  A.(check bool) "closed" false (Health.is_open board "serper");
  A.(check (float 1e-9) "nothing open for" 0.0 (Health.open_for_s board "serper"))

(* {1 The probe's outcomes} *)

let a_200_with_a_key_is_reachable () =
  keyed "serper" "k";
  let net, sent = dial () in
  let config = config_with [ ("serper", Config.default_provider_config) ] in
  A.(check outcome) "reachable" Health.Reachable (Health.probe ~net ~table config "serper");
  let request = one_request sent in
  A.(check string) "the adapter's own endpoint" "https://google.serper.dev/search"
    (url request);
  A.(check (A.option string)) "with the key the search would send" (Some "k")
    (header request "x-api-key");
  A.(check bool) "and no body" true (request.Caps.Authority.Net.body = None)

let a_200_without_a_key_is_reachable_no_key () =
  keyless "searxng";
  let net, _ = dial () in
  let config = config_with [ ("searxng", at_url "http://searx.test:8080") ] in
  A.(check outcome) "reachable without a key" Health.Reachable_no_key
    (Health.probe ~net ~table config "searxng")

let an_auth_rejection_is_key_rejected status () =
  keyed "serper" "k";
  let net, _ = dial ~status () in
  let config = config_with [ ("serper", Config.default_provider_config) ] in
  A.(check outcome) "the key was refused" Health.Key_rejected
    (Health.probe ~net ~table config "serper")

let a_transport_error_is_unreachable () =
  keyed "serper" "k";
  let net, _ = dial ~refusal:"no route" () in
  let config = config_with [ ("serper", Config.default_provider_config) ] in
  A.(check outcome) "unreachable" Health.Unreachable (Health.probe ~net ~table config "serper")

let a_name_with_no_row_is_unsupported_and_makes_no_request name () =
  keyed name "k";
  let net, sent = dial () in
  let config = config_with [ (name, Config.default_provider_config) ] in
  A.(check outcome) "no row, no probe" Health.Unsupported (Health.probe ~net ~table config name);
  A.(check int) "and no request" 0 (List.length (sent ()))

let parallel_probes_its_endpoint_with_the_key_header () =
  keyed "parallel" "k";
  let net, sent = dial () in
  let config = config_with [ ("parallel", Config.default_provider_config) ] in
  A.(check outcome) "reachable" Health.Reachable (Health.probe ~net ~table config "parallel");
  let request = one_request sent in
  A.(check string) "its search endpoint" "https://api.parallel.ai/v1/search" (url request);
  A.(check (A.option string)) "authenticated the way the adapter does" (Some "k")
    (header request "x-api-key")

let searxng_builds_its_url_from_config () =
  keyless "searxng";
  let net, sent = dial () in
  let config = config_with [ ("searxng", at_url "http://searx.internal:8080/") ] in
  A.(check outcome) "reachable without a key" Health.Reachable_no_key
    (Health.probe ~net ~table config "searxng");
  A.(check string) "the instance's own search endpoint"
    "http://searx.internal:8080/search?q=probe&format=json" (url (one_request sent))

let algolia_builds_its_endpoint_and_sends_both_headers () =
  keyed "algolia" "k";
  let net, sent = dial ~status:400 () in
  let config = config_with [ ("algolia", scoped "app123" "products") ] in
  (* A malformed hitsPerPage fails parameter validation, so a 400 proves the path
     and spends no quota — and a key went out, so the answer is still reachable. *)
  A.(check outcome) "reachable" Health.Reachable (Health.probe ~net ~table config "algolia");
  let request = one_request sent in
  A.(check string) "the index's own query endpoint"
    "https://app123-dsn.algolia.net/1/indexes/products/query?query=probe&hitsPerPage=notanumber"
    (url request);
  A.(check (A.option string)) "the application id" (Some "app123")
    (header request "x-algolia-application-id");
  A.(check (A.option string)) "and the key" (Some "k") (header request "x-algolia-api-key")

let algolia_without_a_key_is_key_required () =
  keyless "algolia";
  let net, sent = dial () in
  let config = config_with [ ("algolia", scoped "app123" "products") ] in
  A.(check outcome) "its key is mandatory on every tier" Health.Key_required
    (Health.probe ~net ~table config "algolia");
  A.(check int) "and nothing was dialed" 0 (List.length (sent ()))

let every_mandatory_key_provider_without_a_key_is_key_required () =
  (* The algolia shape swept across the set rather than fixed per adapter, and
     the list is derived, so a new mandatory-key name is covered by being added
     to [Config.providers_requiring_key] — and one needing more config than a
     name (algolia's app_id/index) fails here until it is handled too. *)
  Config.providers_requiring_key
  |> List.filter (fun name -> name <> "algolia")
  |> List.sort String.compare
  |> List.iter (fun name ->
         keyless name;
         let net, sent = dial () in
         let config = config_with [ (name, Config.default_provider_config) ] in
         A.(check outcome) (Printf.sprintf "%s is never probed keyless" name) Health.Key_required
           (Health.probe ~net ~table config name);
         A.(check int) (Printf.sprintf "%s made no request" name) 0 (List.length (sent ())))

let algolia_with_a_bad_key_is_key_rejected () =
  keyed "algolia" "bad";
  let net, _ = dial ~status:403 () in
  let config = config_with [ ("algolia", scoped "app123" "products") ] in
  A.(check outcome) "the key was refused" Health.Key_rejected
    (Health.probe ~net ~table config "algolia")

(* {1 The row builders} *)

let a_row_that_cannot_build_a_url_is_no_probe () =
  keyless "searxng";
  let net, sent = dial () in
  let config = config_with [ ("searxng", Config.default_provider_config) ] in
  A.(check (A.option string)) "searxng with no url configured addresses nothing" None
    (Health.searxng_endpoint config None);
  A.(check (A.option string)) "algolia with no app id or index addresses nothing" None
    (Health.algolia_endpoint config (Some "k"));
  A.(check outcome) "and the probe answers like a name with no probe at all"
    Health.Unsupported (Health.probe ~net ~table config "searxng");
  A.(check int) "without a request" 0 (List.length (sent ()))

let rows_are_constants_where_the_endpoint_is () =
  A.(check (A.option string)) "the endpoint builder ignores the config"
    (Some "https://google.serper.dev/search")
    (Health.probe_endpoint_const "https://google.serper.dev/search" Config.default (Some "k"));
  A.(check A.(list (pair string string))) "the header builder takes the prefix the endpoint spells"
    [ ("Authorization", "Bearer k") ]
    (Health.probe_headers_const ~prefix:"Bearer " "Authorization" Config.default (Some "k"));
  A.(check A.(list (pair string string))) "and sends no header when there is no key" []
    (Health.probe_headers_const "X-API-KEY" Config.default None);
  A.(check A.(list (pair string string))) "algolia sends the application id even keyless"
    [ ("x-algolia-application-id", "app123") ]
    (Health.algolia_headers (config_with [ ("algolia", scoped "app123" "products") ]) None);
  A.(check (A.option string)) "serpapi's key rides the query string"
    (Some "https://serpapi.com/search.json?api_key=k")
    (Health.serpapi_endpoint ~base:"https://serpapi.com/search.json" Config.default (Some "k"))

(* {1 One monitor tick} *)

let monitor ?(threshold = 1) ?(cooldown = 60.) () =
  let clock = ref 0. in
  let lines = ref [] in
  let board =
    Health.create ~now:(fun () -> !clock) ~failure_threshold:threshold ~cooldown_seconds:cooldown
      ~log:(fun _level event fields -> lines := (event, fields) :: !lines) ()
  in
  let reason name =
    !lines
    |> List.rev
    |> List.filter_map (fun (event, fields) ->
         if event = "health.open" && List.assoc "provider" fields = `String name
         then Some (Yojson.Safe.to_string (List.assoc "reason" fields))
         else None)
  in
  let events name =
    !lines |> List.rev |> List.filter_map (fun (event, _) -> if event = name then Some event else None)
  in
  (board, reason, events)

let the_monitor_feeds_the_board () =
  let board, reason, events = monitor () in
  keyed "serper" "k";
  (* linkup needs a key too, or the probe answers key_required rather than the
     failure this case is about. *)
  keyed "linkup" "k";
  keyless "searxng";
  keyless "exa:free";
  let config =
    config_with
      [
        ("searxng", at_url "http://searx.test:8080");
        ("serper", Config.default_provider_config);
        ("linkup", Config.default_provider_config);
        ("exa:free", Config.default_provider_config);
      ]
  in
  let net, hosts = selective_net () in
  (* [built] is what the factory handed the monitor. [exa:free] is enabled but
     is not in it here: this port's stand-in for the MCP-backed names Python
     verifies with [warmup] rather than a probe. *)
  Health.run_probes config ~built:[ "searxng"; "serper"; "linkup" ] ~table ~net board;
  A.(check bool) "a rejected key opens at once" true (Health.is_open board "serper");
  A.(check bool) "unreachable trips threshold 1" true (Health.is_open board "linkup");
  A.(check bool) "a reachable name stays closed" false (Health.is_open board "searxng");
  A.(check bool) "a name that was not built is not probed at all" false
    (Health.is_open board "exa:free");
  A.(check (A.list string)) "and it was never dialed"
    (* [Config.enabled_providers] is sorted, which is the order the tick walks. *)
    [ "api.linkup.so"; "searx.test"; "google.serper.dev" ]
    (hosts ());
  A.(check (A.list string)) "each open says why" [ "\"probe key rejected\"" ] (reason "serper");
  A.(check (A.list string)) "" [ "\"probe unreachable\"" ] (reason "linkup");
  A.(check (A.list string)) "nothing closed, because nothing was armed" [] (events "health.closed")

let a_probe_that_works_closes_a_breaker () =
  let board, _reason, events = monitor ~threshold:2 () in
  keyed "serper" "k";
  for _ = 1 to 2 do
    Health.record_failure board ~reason:"upstream 503" "serper" ()
  done;
  A.(check bool) "traffic opened the gate" true (Health.is_open board "serper");
  let config = config_with [ ("serper", Config.default_provider_config) ] in
  Health.run_probes config ~built:[ "serper" ] ~table ~net:(fst (dial ())) board;
  A.(check bool) "the probe closed it" false (Health.is_open board "serper");
  A.(check (A.list string)) "and said so" [ "health.closed" ] (events "health.closed")

let tests =
  [
    ( "board",
      [
        check "failures below the threshold stay closed and silent"
          below_the_threshold_stays_closed_and_silent;
        check "reaching the threshold opens once, with its fields"
          reaching_the_threshold_opens_once_with_its_fields;
        check "a failure while open extends the gate without re-logging"
          a_failure_while_open_extends_the_gate_without_relogging;
        check "expiry is half-open and one failure re-opens"
          expiry_is_half_open_and_one_failure_reopens;
        check "half-open re-opens without reaching the threshold"
          half_open_reopens_without_the_threshold;
        check "a success while armed closes and resets the count"
          a_success_while_armed_closes_and_resets_the_count;
        check "a success on a never-armed board logs nothing"
          a_success_on_a_never_armed_board_logs_nothing;
        check "force_open opens from zero failures" force_open_opens_from_zero_failures;
        check "an unknown name reads closed" an_unknown_name_reads_closed;
      ] );
    ( "probe",
      [
        check "a 200 with a key is reachable, at the row's endpoint" a_200_with_a_key_is_reachable;
        check "a 200 without a key is reachable_no_key" a_200_without_a_key_is_reachable_no_key;
        check "a 401 is key_rejected" (an_auth_rejection_is_key_rejected 401);
        check "a 403 is key_rejected" (an_auth_rejection_is_key_rejected 403);
        check "a transport error is unreachable" a_transport_error_is_unreachable;
        check "exa has no row and makes no request"
          (a_name_with_no_row_is_unsupported_and_makes_no_request "exa");
        check "parallel:free has no row and makes no request"
          (a_name_with_no_row_is_unsupported_and_makes_no_request "parallel:free");
        check "parallel probes its endpoint with the key header"
          parallel_probes_its_endpoint_with_the_key_header;
        check "searxng builds its url from config" searxng_builds_its_url_from_config;
        check "algolia builds its config endpoint and sends both headers"
          algolia_builds_its_endpoint_and_sends_both_headers;
        check "algolia without a key is key_required" algolia_without_a_key_is_key_required;
        check "every mandatory-key provider without a key is key_required"
          every_mandatory_key_provider_without_a_key_is_key_required;
        check "algolia with a bad key is key_rejected" algolia_with_a_bad_key_is_key_rejected;
        check "a row that cannot build a url is no probe" a_row_that_cannot_build_a_url_is_no_probe;
        check "the row builders are constants where the endpoint is"
          rows_are_constants_where_the_endpoint_is;
      ] );
    ( "monitor",
      [
        check "one tick feeds the board, and only the names it built" the_monitor_feeds_the_board;
        check "a probe that works closes a breaker traffic opened"
          a_probe_that_works_closes_a_breaker;
      ] );
  ]

let () = A.run "health" tests
