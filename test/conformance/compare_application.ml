module C = Compare_common

let scenario_classes = [ "applicable"; "mixed"; "fixture-declaration"; "absent-feature" ]

let check_classes =
  [ "applicable"; "fixture-declaration"; "absent-feature"; "oracle-parity"; "port-divergence" ]

let assoc = function `Assoc pairs -> pairs | _ -> []
let field json key = List.assoc_opt key (assoc json)

let float_repr f =
  if Float.is_integer f && Float.abs f < 1e15 then Printf.sprintf "%.1f" f
  else Printf.sprintf "%.17g" f

let py_repr_string s =
  let quote = if String.contains s '\'' && not (String.contains s '"') then '"' else '\'' in
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer quote;
  String.iter
    (fun c ->
      match c with
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | c when c = quote ->
          Buffer.add_char buffer '\\';
          Buffer.add_char buffer c
      | c when Char.code c < 0x20 || Char.code c = 0x7f ->
          Printf.bprintf buffer "\\x%02x" (Char.code c)
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.add_char buffer quote;
  Buffer.contents buffer

let rec py_repr = function
  | `Null -> "None"
  | `Bool true -> "True"
  | `Bool false -> "False"
  | `Int n -> string_of_int n
  | `Intlit s -> s
  | `Float f -> float_repr f
  | `String s -> py_repr_string s
  | `List items -> "[" ^ String.concat ", " (List.map py_repr items) ^ "]"
  | `Assoc pairs ->
      "{"
      ^ String.concat ", "
          (List.map (fun (key, value) -> py_repr_string key ^ ": " ^ py_repr value) pairs)
      ^ "}"

let py_str = function `String s -> s | json -> py_repr json

(* Python's json.dumps turns a non-string object key into its str form; only the
   null key can reach a tally here, and it lands under "null". *)
let py_key = function `Null -> "null" | `String s -> s | json -> py_str json

let json_int = function `Int n -> Some n | `Intlit s -> int_of_string_opt s | _ -> None

let python_int text =
  let n = String.length text in
  let start = if n > 0 && (text.[0] = '+' || text.[0] = '-') then 1 else 0 in
  let rec digits i = i = n || (text.[i] >= '0' && text.[i] <= '9' && digits (i + 1)) in
  if start = n || not (digits start) then None else int_of_string_opt text

let python_int_error text = "invalid literal for int() with base 10: " ^ py_repr (`String text)

let error_count errs = List.length errs.C.lines

let error_json errs = `List (List.map (fun line -> `String line) errs.C.lines)

let contains_substring haystack needle =
  let hn = String.length haystack and nn = String.length needle in
  let rec go i = i + nn <= hn && (String.sub haystack i nn = needle || go (i + 1)) in
  go 0

let validate_check errs label check =
  match check with
  | `Assoc _ -> (
      (match field check "class" with
      | Some (`String name) when List.mem name check_classes -> ()
      | value ->
          C.add errs
            (Printf.sprintf "%s: invalid check class %s" label
               (py_repr (Option.value value ~default:`Null))));
      (match field check "expect" with
      | Some (`String status) when List.mem status C.check_statuses -> ()
      | value ->
          C.add errs
            (Printf.sprintf "%s: invalid expectation %s" label
               (py_repr (Option.value value ~default:`Null))));
      (match field check "count" with
      | None -> ()
      | Some value -> (
          match json_int value with
          | Some n when n >= 1 -> ()
          | _ -> C.add errs (label ^ ": count must be a positive integer")));
      (match field check "class" with
      | Some (`String "applicable") -> (
          match field check "expect" with
          | Some (`String ("SUCCESS" | "INFO")) -> ()
          | value ->
              C.add errs
                (Printf.sprintf "%s: an applicable check cannot be expected to %s" label
                   (py_str (Option.value value ~default:`Null))))
      | _ -> ());
      match field check "class" with
      | Some (`String "applicable") -> ()
      | _ -> (
          match field check "reason" with
          | Some (`String _) -> ()
          | _ -> C.add errs (label ^ ": an excluded check needs a reason")))
  | _ -> C.add errs (label ^ ": entry must be an object")

let check_class check =
  match field check "class" with Some (`String name) -> Some name | _ -> None

let scenario_exclusions errs label entry checks =
  match field entry "class" with
  | Some (`String "applicable") ->
      let excluded =
        List.filter_map
          (fun (check_id, check) ->
            match check with
            | `Assoc _ when check_class check <> Some "applicable" -> Some check_id
            | _ -> None)
          checks
        |> List.sort String.compare
      in
      if excluded <> [] then
        C.add errs
          (Printf.sprintf "%s: applicable scenario contains excluded checks: %s" label
             (C.py_list excluded))
  | Some (`String ("fixture-declaration" | "absent-feature")) ->
      let stray =
        List.filter_map
          (fun (check_id, check) ->
            match check with
            | `Assoc _ when check_class check = Some "applicable" && check_id <> "wire-schema-valid"
              ->
                Some check_id
            | _ -> None)
          checks
        |> List.sort String.compare
      in
      if stray <> [] then
        C.add errs
          (Printf.sprintf "%s: non-applicable scenario claims applicable checks: %s" label
             (C.py_list stray))
  | _ -> ()

let validate_group errs group_name pairs =
  List.iter
    (fun (scenario, entry) ->
      let label = group_name ^ "/" ^ scenario in
      match entry with
      | `Assoc _ -> (
          (match field entry "class" with
          | Some (`String name) when List.mem name scenario_classes -> ()
          | value ->
              C.add errs
                (Printf.sprintf "%s: invalid scenario class %s" label
                   (py_repr (Option.value value ~default:`Null))));
          (match field entry "reason" with
          | Some (`String reason) when String.trim reason <> "" -> ()
          | _ -> C.add errs (label ^ ": missing reason"));
          match field entry "checks" with
          | Some (`Assoc (_ :: _ as checks)) ->
              List.iter
                (fun (check_id, check) -> validate_check errs (label ^ "/" ^ check_id) check)
                checks;
              scenario_exclusions errs label entry checks
          | _ -> C.add errs (label ^ ": missing checks map"))
      | _ -> C.add errs (label ^ ": entry must be an object"))
    pairs

let load_classification path errs =
  match C.read_json ~dup_prefix:"classification" path with
  | exception C.Bad message ->
      C.add errs ("classification unavailable or malformed: " ^ message);
      None
  | `Assoc _ as document -> (
      (match field document "runner" with
      | Some runner -> (
          match field runner "version" with
          | Some (`String _) -> ()
          | _ -> C.add errs "classification.runner.version is required")
      | None -> C.add errs "classification.runner.version is required");
      List.iter
        (fun group ->
          match field document group with
          | Some (`Assoc (_ :: _)) -> ()
          | _ -> C.add errs (Printf.sprintf "classification.%s must be a non-empty object" group))
        [ "scenarios"; "unscored"; "classes" ];
      match (field document "scenarios", field document "unscored") with
      | Some (`Assoc scenarios), Some (`Assoc unscored) ->
          List.iter
            (fun (group_name, pairs) -> validate_group errs group_name pairs)
            [ ("scenarios", scenarios); ("unscored", unscored) ];
          Some document
      | _ -> None)
  | _ ->
      C.add errs "classification must be an object";
      None

let run_summary checks =
  if List.exists (fun check -> List.mem check.C.status C.failing_statuses) checks then "fail"
  else if List.exists (fun check -> check.C.status = "SUCCESS") checks then "pass"
  else "inconclusive"

let status_map checks =
  List.fold_left
    (fun acc check ->
      (check.C.id, `String check.C.status) :: List.filter (fun (id, _) -> id <> check.C.id) acc)
    [] checks

type outcome = {
  cls : Yojson.Safe.t;
  mutable checks_path : string option;
  mutable status_map : (string * Yojson.Safe.t) list option;
  mutable check_counts : (string, int) Hashtbl.t option;
  mutable failed_check_ids : string list;
  mutable raw : string option;
  mutable result : string option;
}

let outcome_json outcome =
  `Assoc
    ([ ("class", outcome.cls) ]
    @ (match outcome.checks_path with Some path -> [ ("checks_path", `String path) ] | None -> [])
    @ (match outcome.status_map with Some map -> [ ("checks", `Assoc map) ] | None -> [])
    @ (match outcome.check_counts with
      | Some counts -> [ ("check_counts", C.counter_json counts) ]
      | None -> [])
    @ (match outcome.failed_check_ids with
      | [] -> []
      | ids -> [ ("failed_check_ids", `List (List.map (fun id -> `String id) ids)) ])
    @ (match outcome.raw with Some raw -> [ ("raw", `String raw) ] | None -> [])
    @ match outcome.result with Some result -> [ ("result", `String result) ] | None -> [])

let report errs ~manifest ~classification ~scenarios ~run ~extra =
  `Assoc
    ([
       ("mode", `String "application");
       ("manifest", `String manifest);
       ("classification", `String classification);
       ("errors", error_json errs);
       ("scenarios", scenarios);
       ("run", run);
     ]
    @ extra)

let compare args =
  let manifest = C.opt_exn args "manifest" in
  let classification_path = C.opt_exn args "classification" in
  let results_path = C.opt_exn args "results" in
  let stdout_path = C.opt_exn args "stdout" in
  let exit_code_path = C.opt_exn args "exit_code" in
  let list_output = C.opt_exn args "list_output" in
  let report_path = C.opt_exn args "report" in
  let errs = C.errors () in
  let classification = load_classification classification_path errs in
  let expected =
    match C.ids manifest with
    | ids -> ids
    | exception C.Bad message ->
        C.add errs ("manifest unavailable or malformed: " ^ message);
        []
  in
  match classification with
  | None ->
      let json =
        report errs ~manifest ~classification:classification_path ~scenarios:(`Assoc [])
          ~run:(`Assoc [])
          ~extra:[ ("gate", `String "fail") ]
      in
      C.write_report report_path json;
      List.iter (fun error -> prerr_endline ("error: " ^ error)) errs.C.lines;
      1
  | Some classification ->
      let artifact_root = Filename.dirname results_path in
      let metadata_ok = ref true in
      let run_entries = ref [] in
      let read_metadata key filename read =
        match read (Filename.concat artifact_root filename) with
        | Ok text -> run_entries := (key, text) :: !run_entries
        | Error message ->
            C.add errs (Printf.sprintf "run metadata missing (%s): %s" filename message);
            metadata_ok := false
      in
      let run_file key filename =
        read_metadata key filename (fun path ->
            match C.read_stripped path with Ok text -> Ok (`String text) | Error m -> Error m)
      in
      List.iter
        (fun (key, filename) -> run_file key filename)
        [
          ("date_utc", "run-date-utc.txt");
          ("server_commit", "server-commit.txt");
          ("runner_version", "runner-version.txt");
          ("node_version", "node-version.txt");
          ("npm_version", "npm-version.txt");
          ("command", "runner-command.txt");
          ("server_identity", "server-identity.txt");
        ];
      read_metadata "working_tree_status_count" "working-tree-status.txt" (fun path ->
          match C.read_file path with
          | Ok text -> Ok (`Int (List.length (C.split_lines text)))
          | Error m -> Error m);
      let expected_version =
        match field classification "runner" with
        | Some runner -> (
            match field runner "version" with Some (`String version) -> version | _ -> "")
        | None -> ""
      in
      let observed_version =
        match List.assoc_opt "runner_version" !run_entries with
        | Some (`String version) -> Some version
        | _ -> None
      in
      if observed_version <> Some expected_version then begin
        C.add errs
          (Printf.sprintf "runner version changed: expected %s, observed %s"
             (py_repr (`String expected_version))
             (py_repr
                (match observed_version with Some version -> `String version | None -> `Null)));
        metadata_ok := false
      end;
      let scored = expected in
      let unscored = ref [] in
      let runner_ok = ref !metadata_ok in
      (match C.read_file list_output with
      | Error message ->
          C.add errs ("runner list parser error: " ^ message);
          runner_ok := false
      | Ok list_text -> (
          try
            let before = error_count errs in
            C.exact "official scored list" (C.runner_list list_text) scored errs;
            let parsed = C.runner_unscored list_text in
            unscored := parsed;
            if
              List.length (List.sort_uniq String.compare parsed) <> List.length parsed
              || List.exists (fun id -> List.mem id scored) parsed
            then C.add errs "official unscored list contains duplicates or scored IDs";
            let classified =
              List.map fst (assoc (Option.value (field classification "unscored") ~default:`Null))
              |> List.sort String.compare
            in
            C.exact "classified unscored list" (List.sort String.compare parsed) classified errs;
            if error_count errs <> before then runner_ok := false
          with C.Bad message ->
            C.add errs ("runner list parser error: " ^ message);
            runner_ok := false));
      let scenario_entries =
        assoc (Option.value (field classification "scenarios") ~default:`Null)
      in
      let unscored_entries =
        assoc (Option.value (field classification "unscored") ~default:`Null)
      in
      C.exact "classification scored scenarios"
        (List.map fst scenario_entries |> List.sort String.compare)
        (List.sort String.compare scored) errs;
      (match C.read_file stdout_path with
      | Error message ->
          C.add errs ("runner stdout missing: " ^ message);
          runner_ok := false
      | Ok stdout ->
          let before = error_count errs in
          C.exact "executed scenarios" (C.executed_scenarios stdout) (scored @ !unscored) errs;
          if not (contains_substring stdout "=== SUMMARY ===") then
            C.add errs "runner summary missing";
          if error_count errs <> before then runner_ok := false);
      let runner_exit_code =
        match C.read_stripped exit_code_path with
        | Error message ->
            C.add errs ("runner exit code missing: " ^ message);
            runner_ok := false;
            None
        | Ok text -> (
            match python_int text with
            | Some code ->
                if code <> 0 && code <> 1 then begin
                  C.add errs (Printf.sprintf "runner crashed or timed out: exit %d" code);
                  runner_ok := false
                end;
                Some code
            | None ->
                C.add errs ("runner exit code missing: " ^ python_int_error text);
                runner_ok := false;
                None)
      in
      let found = Hashtbl.create 64 in
      if not (C.dir_exists results_path) then
        C.add errs ("runner result directory missing: " ^ results_path)
      else begin
        (match C.list_dirs results_path with
        | Error () -> ()
        | Ok names ->
            List.iter
              (fun name ->
                match C.scenario_of_result_dir name with
                | None -> C.add errs ("unrecognized result directory: " ^ name)
                | Some scenario ->
                    if not (List.mem scenario scored || List.mem scenario !unscored) then
                      C.add errs ("result directory for unknown scenario: " ^ name)
                    else
                      let path = Filename.concat results_path name in
                      let paths =
                        match Hashtbl.find_opt found scenario with
                        | Some paths -> path :: paths
                        | None -> [ path ]
                      in
                      Hashtbl.replace found scenario paths)
              names);
        C.exact "result directories"
          (Hashtbl.to_seq_keys found |> List.of_seq)
          (scored @ !unscored) errs;
        Hashtbl.to_seq found |> List.of_seq
        |> List.sort (fun (a, _) (b, _) -> String.compare a b)
        |> List.iter (fun (scenario, paths) ->
            if List.length paths <> 1 then
              C.add errs
                (Printf.sprintf "duplicate result directory for %s: %d" scenario (List.length paths)))
      end;
      let observed = Hashtbl.create 64 in
      let raw = Hashtbl.create 64 in
      let outcomes = Hashtbl.create 64 in
      let class_for scenario =
        match List.assoc_opt scenario scenario_entries with
        | Some entry -> field entry "class"
        | None -> (
            match List.assoc_opt scenario unscored_entries with
            | Some entry -> field entry "class"
            | None -> None)
      in
      List.iter
        (fun scenario ->
          let entry =
            {
              cls = Option.value (class_for scenario) ~default:`Null;
              checks_path = None;
              status_map = None;
              check_counts = None;
              failed_check_ids = [];
              raw = None;
              result = None;
            }
          in
          Hashtbl.replace outcomes scenario entry;
          let paths =
            match Hashtbl.find_opt found scenario with Some paths -> paths | None -> []
          in
          if List.length paths <> 1 then begin
            C.add errs ("missing or duplicate result directory: " ^ scenario);
            entry.result <- Some "inconclusive";
            Hashtbl.replace raw scenario "inconclusive"
          end
          else
            let checks_path = Filename.concat (List.hd paths) "checks.json" in
            match C.read_checks checks_path with
            | exception C.Bad message ->
                C.add errs
                  (Printf.sprintf "checks unavailable or malformed: %s: %s" scenario message);
                entry.result <- Some "inconclusive";
                Hashtbl.replace raw scenario "inconclusive"
            | checks ->
                let summary = run_summary checks.C.checks in
                Hashtbl.replace observed scenario checks.C.checks;
                Hashtbl.replace raw scenario summary;
                entry.checks_path <-
                  Some (C.relative_path ~base:(Filename.dirname results_path) checks_path);
                entry.status_map <- Some (status_map checks.C.checks);
                entry.check_counts <-
                  Some (C.counter (List.map (fun c -> c.C.status) checks.C.checks));
                entry.failed_check_ids <- checks.C.failed)
        (scored @ !unscored);
      let check_classes = C.counter [] in
      let check_statuses = C.counter [] in
      let applicable = C.counter [] in
      let excluded_but_runner_passes = ref [] in
      List.iter
        (fun (group_name, entries) ->
          List.iter
            (fun (scenario, classified) ->
              match Hashtbl.find_opt observed scenario with
              | None -> ()
              | Some checks -> (
                  let expected_checks =
                    assoc (Option.value (field classified "checks") ~default:`Null)
                  in
                  let expected_ids =
                    List.concat
                      (List.map
                         (fun (check_id, spec) ->
                           let count =
                             match field spec "count" with
                             | None -> 1
                             | Some value -> (
                                 match json_int value with Some n -> max n 0 | None -> 1)
                           in
                           List.init count (fun _ -> check_id))
                         expected_checks)
                  in
                  C.multiset_diff
                    (Printf.sprintf "%s/%s check IDs" group_name scenario)
                    (List.map (fun check -> check.C.id) checks |> List.sort String.compare)
                    (List.sort String.compare expected_ids)
                    errs;
                  let applicable_failed = ref [] in
                  List.iter
                    (fun (check_id, spec) ->
                      let occurrences = List.filter (fun check -> check.C.id = check_id) checks in
                      let klass = Option.value (field spec "class") ~default:`Null in
                      List.iter
                        (fun check ->
                          let status = check.C.status in
                          C.counter_add check_classes (py_key klass) 1;
                          C.counter_add check_statuses status 1;
                          if py_key klass = "applicable" then begin
                            C.counter_add applicable status 1;
                            if List.mem status C.failing_statuses then
                              applicable_failed := !applicable_failed @ [ check_id ]
                          end;
                          let expected_status = Option.value (field spec "expect") ~default:`Null in
                          if expected_status <> `String status then
                            C.add errs
                              (Printf.sprintf "%s/%s/%s: expected %s, observed %s" group_name
                                 scenario check_id (py_str expected_status) status))
                        occurrences)
                    expected_checks;
                  if !applicable_failed <> [] then
                    C.add errs
                      (Printf.sprintf "%s/%s: applicable checks failed: %s" group_name scenario
                         (C.py_list !applicable_failed));
                  let scenario_class = field classified "class" in
                  if scenario_class = Some (`String "applicable") && !applicable_failed <> [] then
                    C.add errs
                      (Printf.sprintf "%s/%s: an applicable scenario must pass every check"
                         group_name scenario);
                  match Hashtbl.find_opt outcomes scenario with
                  | None -> ()
                  | Some entry ->
                      let summary =
                        match Hashtbl.find_opt raw scenario with
                        | Some summary -> summary
                        | None -> "inconclusive"
                      in
                      entry.raw <- Some summary;
                      let excluded =
                        match scenario_class with
                        | Some (`String ("fixture-declaration" | "absent-feature")) -> true
                        | _ -> false
                      in
                      entry.result <-
                        Some
                          (if excluded then "excluded"
                           else if !applicable_failed <> [] then "fail"
                           else "pass");
                      if entry.result = Some "excluded" && summary = "pass" then
                        excluded_but_runner_passes := !excluded_but_runner_passes @ [ scenario ]))
            entries)
        [ ("scenarios", scenario_entries); ("unscored", unscored_entries) ];
      if not !runner_ok then
        Hashtbl.iter (fun _ entry -> entry.result <- Some "inconclusive") outcomes;
      let scenarios_by_class =
        C.counter
          (Hashtbl.to_seq outcomes |> List.of_seq |> List.map (fun (_, entry) -> py_key entry.cls))
      in
      let raw_of scenario =
        match Hashtbl.find_opt raw scenario with Some summary -> summary | None -> "inconclusive"
      in
      let counted universe =
        let counts = C.counter (List.map raw_of universe) in
        `Assoc
          [
            ("pass", `Int (C.counter_get counts "pass"));
            ("fail", `Int (C.counter_get counts "fail"));
            ("inconclusive", `Int (C.counter_get counts "inconclusive"));
          ]
      in
      let gate = if C.any errs then "fail" else "pass" in
      let scenarios =
        `Assoc
          (Hashtbl.to_seq outcomes |> List.of_seq
          |> List.map (fun (scenario, entry) -> (scenario, outcome_json entry)))
      in
      let extra =
        (match runner_exit_code with
          | Some code -> [ ("runner_exit_code", `Int code) ]
          | None -> [])
        @ [
            ( "tallies",
              `Assoc
                [
                  ("scenarios_by_class", C.counter_json scenarios_by_class);
                  ("checks_by_class", C.counter_json check_classes);
                  ("check_statuses", C.counter_json check_statuses);
                  ("applicable_checks", C.counter_json applicable);
                  ("scored_scenarios", counted scored);
                  ("unscored_scenarios", counted !unscored);
                  ("scored_total", `Int (List.length scored));
                  ("unscored_total", `Int (List.length !unscored));
                  ( "excluded_scenarios_that_the_runner_passes",
                    `List
                      (List.sort String.compare !excluded_but_runner_passes
                      |> List.map (fun scenario -> `String scenario)) );
                ] );
            ("applicable_check_total", `Int (C.counter_total applicable));
            ("gate", `String gate);
          ]
      in
      C.write_report report_path
        (report errs ~manifest ~classification:classification_path ~scenarios
           ~run:(`Assoc !run_entries) ~extra);
      Printf.printf
        "application: %d applicable checks (%d passed), %d checks classified; gate=%s; report=%s\n"
        (C.counter_total applicable)
        (C.counter_get applicable "SUCCESS" + C.counter_get applicable "INFO")
        (C.counter_total check_classes) gate report_path;
      List.iter (fun error -> prerr_endline ("error: " ^ error)) errs.C.lines;
      if C.any errs then 1 else 0

let () =
  let args =
    C.parse_args ~program:"compare_application"
      ~spec:
        [
          ("manifest", true);
          ("classification", true);
          ("results", true);
          ("stdout", true);
          ("exit_code", true);
          ("list_output", true);
          ("report", true);
        ]
      ()
  in
  exit (compare args)
