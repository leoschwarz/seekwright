(* The [--metrics] report — port of [tests/test_cli.py]'s [TestMetrics]:
   the default table from a snapshot, the "no history" sentence, the journal
   states, and the column alignment. The snapshot is the JSON
   [Usage.snapshot] writes, fed in by hand; [now] is the window's right
   edge, so the dates are pinned. *)

let endpoints ?(window_days = 14) providers =
  `Assoc
    [
      ("window_days", `Int window_days);
      ("providers", `List providers);
    ]

let provider ?(calls = 1) ?(errors = 0) ?(fell_back_calls = 0) ?(latency_samples = 0)
      ?(p50_ms = None) ?(p95_ms = None) ?(mean_ms = None) ?(cost_usd = 0.0) ?(cost_per_1k = None)
      ?(last_seen = None) name =
  `Assoc
    ([
       ("provider", `String name);
       ("calls", `Int calls);
       ("errors", `Int errors);
       ("fell_back_calls", `Int fell_back_calls);
       ("latency_samples", `Int latency_samples);
     ]
    @ (match p50_ms with Some n -> [ ("p50_ms", `Int n) ] | None -> [])
    @ (match p95_ms with Some n -> [ ("p95_ms", `Int n) ] | None -> [])
    @ (match mean_ms with Some n -> [ ("mean_ms", `Int n) ] | None -> [])
    @ [ ("cost_usd", `Float cost_usd) ]
    @ (match cost_per_1k with Some v -> [ ("cost_per_1k", `Float v) ] | None -> [])
    @ (match last_seen with Some s -> [ ("last_seen", `String s) ] | None -> []))

let report ~now endpoints journal =
  let out = ref [] in
  Cli_metrics.print_report ~emit:(fun line -> out := !out @ [ line ]) ~now endpoints journal;
  !out

(* 2026-11-13 12:00 UTC — a fixed instant, so the window sentence is a fact
   of the test rather than of the machine's clock. *)
let now = 1794571200.0

(* {1 The default report} *)

let test_header_and_window () =
  let out = report ~now (endpoints []) (`Assoc [ ("path", `Null) ]) in
  Alcotest.(check string) "title" "seekwright metrics" (List.nth out 0);
  Alcotest.(check string) "window" "window      14 days, 2026-10-31 .. 2026-11-13 (UTC)"
    (List.nth out 2);
  Alcotest.(check string) "journal off" "journal     off — dashboard.history_path unset"
    (List.nth out 3);
  Alcotest.(check string) "no history" "no history" (List.nth out 5)

let test_window_days_from_snapshot () =
  let out = report ~now (endpoints ~window_days:7 []) (`Assoc [ ("path", `Null) ]) in
  Alcotest.(check string) "seven days" "window      7 days, 2026-11-07 .. 2026-11-13 (UTC)"
    (List.nth out 2)

let test_journal_states () =
  Alcotest.(check string) "ok" "/var/log/seekwright.jsonl  ok"
    (Cli_metrics.journal_state ( `Assoc [ ("path", `String "/var/log/seekwright.jsonl"); ("failed", `Bool false) ]));
  Alcotest.(check string) "failed" "/var/log/seekwright.jsonl  failed"
    (Cli_metrics.journal_state ( `Assoc [ ("path", `String "/var/log/seekwright.jsonl"); ("failed", `Bool true) ]))

(* {1 The table} *)

let test_row_cells () =
  let row =
    Cli_metrics.row
      (provider "exa" ~calls:12 ~errors:2 ~fell_back_calls:1 ~latency_samples:10 ~p50_ms:(Some 340)
         ~p95_ms:(Some 900) ~mean_ms:(Some 420) ~cost_usd:0.0123 ~cost_per_1k:(Some 1.0)
         ~last_seen:(Some "2026-11-13T11:59:59.123456+00:00"))
  in
  Alcotest.(check (list string))
    "every column"
    [ "exa"; "12"; "2"; "1"; "10"; "340"; "900"; "420"; "0.0123"; "1.0000"; "2026-11-13T11:59:59Z" ]
    row

let test_missing_values_are_em_dashes () =
  let row = Cli_metrics.row (provider "freeserp") in
  Alcotest.(check (list string))
    "unset optional fields render as —"
    [ "freeserp"; "1"; "0"; "0"; "0"; "—"; "—"; "—"; "0.0000"; "—"; "—" ]
    row

let test_last_seen_drops_subsecond_precision () =
  (* the journal writes microsecond precision; the column wants seconds, and
     the Python prints the UTC cut with a trailing Z. *)
  List.iter
    (fun stamp ->
      let row = Cli_metrics.row (provider "exa" ~last_seen:(Some stamp)) in
      Alcotest.(check string) stamp "2026-11-13T11:59:59Z" (List.nth row 10))
    [
      "2026-11-13T11:59:59.123456+00:00";
      "2026-11-13T11:59:59Z";
    ]

let test_table_alignment () =
  let out =
    report ~now
      (endpoints
         [
           provider "exa" ~calls:1;
           provider "parallel:free" ~calls:120 ~mean_ms:(Some 7);
         ])
      (`Assoc [ ("path", `Null) ])
  in
  (* the header and both rows share the provider-column width, and numeric
     columns are right-aligned inside it. *)
  let header = List.nth out 5 in
  let row1 = List.nth out 6 in
  let row2 = List.nth out 7 in
  Alcotest.(check int) "same width" (String.length header) (String.length row1);
  Alcotest.(check int) "same width" (String.length header) (String.length row2);
  Alcotest.(check bool) "provider column left-aligned" true
    (String.length header > 8 && String.sub header 0 8 = "provider");
  Alcotest.(check bool) "first row starts with its name" true
    (String.length row1 >= 3 && String.sub row1 0 3 = "exa");
  Alcotest.(check bool) "the calls column right-aligns" true
    (try
       ignore (Str.search_forward (Str.regexp_string "  1  ") row1 0);
       true
     with Not_found -> false)

let () =
  Alcotest.run "cli metrics"
    [
      ( "default report",
        [
          Alcotest.test_case "header, window and no history" `Quick test_header_and_window;
          Alcotest.test_case "window_days rides the snapshot" `Quick test_window_days_from_snapshot;
          Alcotest.test_case "journal off, ok and failed" `Quick test_journal_states;
        ] );
      ( "the table",
        [
          Alcotest.test_case "every column" `Quick test_row_cells;
          Alcotest.test_case "missing values are em dashes" `Quick test_missing_values_are_em_dashes;
          Alcotest.test_case "last_seen drops subsecond precision" `Quick test_last_seen_drops_subsecond_precision;
          Alcotest.test_case "column alignment" `Quick test_table_alignment;
        ] );
    ]
