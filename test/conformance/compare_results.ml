module C = Compare_common

let causes =
  [ "sdk_protocol_defect"; "fixture_gap"; "runner_issue"; "unsupported_feature"; "unresolved" ]

let py_truthy = function
  | `Null | `Bool false | `Int 0 | `String "" | `List [] | `Assoc [] -> false
  | `Float f -> f <> 0.0
  | _ -> true

let set_field json key value =
  match json with
  | `Assoc pairs -> `Assoc (List.filter (fun (k, _) -> k <> key) pairs @ [ (key, value) ])
  | _ -> `Assoc [ (key, value) ]

let del_field json key =
  match json with `Assoc pairs -> `Assoc (List.filter (fun (k, _) -> k <> key) pairs) | _ -> json

let read_text path =
  match C.read_file path with Ok text -> text | Error message -> raise (C.Bad message)

let contains_text haystack needle =
  let hn = String.length haystack and nn = String.length needle in
  let rec go i =
    if i + nn > hn then false else if String.sub haystack i nn = needle then true else go (i + 1)
  in
  go 0

let invalid_literal text = Printf.sprintf "invalid literal for int() with base 10: '%s'" text

exception Json_syntax of string

let json_position text index =
  let line = ref 1 and line_start = ref 0 in
  for i = 0 to index - 1 do
    if i < String.length text && text.[i] = '\n' then (
      incr line;
      line_start := i + 1)
  done;
  Printf.sprintf "line %d column %d (char %d)" !line (index - !line_start + 1) index

(* A malformed [checks.json] puts the parser's sentence in the report, and the
   retired script put CPython's wording there, not the JSON library's; the
   scanner below answers with the sentence CPython would have raised. *)
let python_json_error text =
  let n = String.length text in
  let fail message index = raise (Json_syntax (message ^ ": " ^ json_position text index)) in
  let is_ws = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false in
  let is_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') in
  let is_digit c = c >= '0' && c <= '9' in
  let rec skip i = if i < n && is_ws text.[i] then skip (i + 1) else i
  and string_end start =
    let rec go j =
      if j >= n then fail "Unterminated string starting at" start
      else
        match text.[j] with
        | '"' -> j + 1
        | '\\' -> (
            if j + 1 >= n then fail "Unterminated string starting at" start
            else
              match text.[j + 1] with
              | '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' -> go (j + 2)
              | 'u' ->
                  if
                    j + 5 < n
                    && is_hex text.[j + 2]
                    && is_hex text.[j + 3]
                    && is_hex text.[j + 4]
                    && is_hex text.[j + 5]
                  then go (j + 6)
                  else fail "Invalid \\uXXXX escape" j
              | _ -> fail "Invalid \\escape" j)
        | c when Char.code c < 0x20 -> fail "Invalid control character at" j
        | _ -> go (j + 1)
    in
    go (start + 1)
  and number_end start =
    let j = ref start in
    if !j < n && text.[!j] = '-' then incr j;
    let digits = !j in
    while !j < n && is_digit text.[!j] do
      incr j
    done;
    if !j = digits then fail "Expecting value" start;
    if !j < n && text.[!j] = '.' then begin
      incr j;
      let digits = !j in
      while !j < n && is_digit text.[!j] do
        incr j
      done;
      if !j = digits then fail "Expecting value" !j
    end;
    if !j < n && (text.[!j] = 'e' || text.[!j] = 'E') then begin
      incr j;
      if !j < n && (text.[!j] = '+' || text.[!j] = '-') then incr j;
      let digits = !j in
      while !j < n && is_digit text.[!j] do
        incr j
      done;
      if !j = digits then fail "Expecting value" !j
    end;
    !j
  and literal start word =
    let len = String.length word in
    if start + len <= n && String.sub text start len = word then start + len
    else fail "Expecting value" start
  and value start =
    let start = skip start in
    if start >= n then fail "Expecting value" start;
    match text.[start] with
    | '{' -> obj (skip (start + 1))
    | '[' -> arr (skip (start + 1))
    | '"' -> string_end start
    | 't' -> literal start "true"
    | 'f' -> literal start "false"
    | 'n' -> literal start "null"
    | '-' | '0' .. '9' -> number_end start
    | _ -> fail "Expecting value" start
  and obj start =
    if start >= n then fail "Expecting property name enclosed in double quotes" start
    else if text.[start] = '}' then start + 1
    else if text.[start] <> '"' then fail "Expecting property name enclosed in double quotes" start
    else
      let colon = skip (string_end start) in
      if colon >= n || text.[colon] <> ':' then fail "Expecting ':' delimiter" colon
      else obj_rest (skip (value (skip (colon + 1))))
  and obj_rest start =
    if start >= n then fail "Expecting ',' delimiter" start
    else
      match text.[start] with
      | '}' -> start + 1
      | ',' ->
          let next = skip (start + 1) in
          if next < n && text.[next] = '}' then
            fail "Illegal trailing comma before end of object" start
          else obj next
      | _ -> fail "Expecting ',' delimiter" start
  and arr start =
    if start >= n then fail "Expecting value" start
    else if text.[start] = ']' then start + 1
    else arr_rest (skip (value start))
  and arr_rest start =
    if start >= n then fail "Expecting ',' delimiter" start
    else
      match text.[start] with
      | ']' -> start + 1
      | ',' ->
          let next = skip (start + 1) in
          if next < n && text.[next] = ']' then
            fail "Illegal trailing comma before end of array" start
          else arr next
      | _ -> fail "Expecting ',' delimiter" start
  in
  try
    let end_of_value = skip (value 0) in
    if end_of_value < n then Some ("Extra data: " ^ json_position text end_of_value) else None
  with Json_syntax message -> Some message

let read_json ?dup_prefix path =
  let text = read_text path in
  try C.read_json ?dup_prefix path
  with C.Bad message -> (
    match python_json_error text with
    | Some python_message -> raise (C.Bad python_message)
    | None -> raise (C.Bad message))

let read_checks path =
  let text = read_text path in
  try C.read_checks path
  with C.Bad message -> (
    match python_json_error text with
    | Some python_message -> raise (C.Bad python_message)
    | None -> raise (C.Bad message))

(* [int(str.strip())] in the retired script refused anything but a decimal integer; the
   [error] sentence names the text it refused. *)
let py_int text =
  let n = String.length text in
  let start = if n > 0 && (text.[0] = '-' || text.[0] = '+') then 1 else 0 in
  if n > start && String.for_all (fun c -> c >= '0' && c <= '9') (String.sub text start (n - start))
  then int_of_string_opt text
  else None

let evidence_map checks failed =
  let table = Hashtbl.create 8 in
  List.iter
    (fun check ->
      if List.mem check.C.id failed then
        Hashtbl.replace table check.C.id (C.observed_evidence check))
    checks;
  table

let read_exit_code path =
  match C.read_stripped path with
  | Error message -> `Error message
  | Ok text -> (
      match py_int text with Some code -> `Code code | None -> `Bad (invalid_literal text))

let entry_json fields = `Assoc fields

let load_baseline path manifest errors =
  match path with
  | None -> []
  | Some path -> (
      try
        let document = read_json ~dup_prefix:"baseline" path in
        let entries =
          match C.assoc_get document "expected_failures" with
          | Some (`Assoc pairs) -> pairs
          | Some _ -> raise (C.Bad "expected_failures must be an object")
          | None -> raise (C.Bad "'expected_failures'")
        in
        List.iter
          (fun (scenario, entry) ->
            if not (List.mem scenario manifest) then
              C.add errors ("baseline unknown scenario: " ^ scenario);
            let checks = match entry with `Assoc _ -> C.assoc_get entry "checks" | _ -> None in
            match checks with
            | Some (`Assoc pairs) when pairs <> [] ->
                List.iter
                  (fun (check_id, classification) ->
                    let label = scenario ^ "/" ^ check_id in
                    if check_id = "" then C.add errors ("baseline invalid check ID: " ^ label);
                    let cause =
                      match classification with
                      | `Assoc _ -> C.get_string classification "cause"
                      | _ -> None
                    in
                    match cause with
                    | Some cause when List.mem cause causes -> (
                        let reason = C.get_string classification "reason" in
                        (match reason with
                        | Some reason when String.trim reason <> "" -> ()
                        | _ -> C.add errors ("baseline missing reason: " ^ label));
                        if cause = "unresolved" then
                          match C.get_string classification "evidence" with
                          | Some evidence when String.trim evidence <> "" -> ()
                          | _ ->
                              C.add errors
                                ("unresolved baseline check needs specific evidence: " ^ label))
                    | _ -> C.add errors ("baseline invalid cause: " ^ label))
                  pairs
            | _ -> C.add errors ("baseline missing checks map: " ^ scenario))
          entries;
        entries
      with C.Bad message ->
        C.add errors ("baseline parser error: " ^ message);
        [])

let compare_pending args =
  let errors = C.errors () in
  let expected = C.ids ~allow_empty:true (C.opt_exn args "manifest") in
  let base = C.opt_exn args "results" in
  let report_path = C.opt_exn args "report" in
  let scenarios = ref [] in
  let classifications = ref [] in
  (match C.opt args "pending_classifications" with
  | None -> ()
  | Some path -> (
      match read_json path with
      | `Assoc pairs -> classifications := pairs
      | _ ->
          C.add errors
            "pending classifications unavailable or malformed: pending classifications must be an \
             object"
      | exception C.Bad message ->
          C.add errors ("pending classifications unavailable or malformed: " ^ message)));
  List.filter (fun scenario -> not (List.mem scenario expected)) (List.map fst !classifications)
  |> List.sort_uniq String.compare
  |> List.iter (fun scenario -> C.add errors ("stale pending classification scenario: " ^ scenario));
  (if not (C.dir_exists base) then C.add errors ("pending result directory missing: " ^ base)
   else
     let names = match C.list_dirs base with Ok names -> names | Error () -> [] in
     C.exact "pending scenario directories" names expected errors);
  List.iter
    (fun scenario ->
      let entry =
        ref
          (entry_json
             [
               ("result", `String "inconclusive");
               ("cause", `String "unresolved");
               ("runner_exit_code", `Null);
               ("checks_path", `Null);
             ])
      in
      scenarios := !scenarios @ [ (scenario, entry) ];
      let runner_ok = ref true in
      (match read_exit_code (Filename.concat base (scenario ^ ".exit-code")) with
      | `Code code ->
          entry := set_field !entry "runner_exit_code" (`Int code);
          if code <> 0 && code <> 1 then (
            C.add errors
              (Printf.sprintf "pending runner crash or timeout: %s: exit %d" scenario code);
            runner_ok := false)
      | `Error message ->
          C.add errors (Printf.sprintf "pending runner exit missing: %s: %s" scenario message);
          runner_ok := false
      | `Bad message ->
          C.add errors (Printf.sprintf "pending runner exit missing: %s: %s" scenario message);
          runner_ok := false);
      (match C.read_file (Filename.concat base (scenario ^ ".stdout")) with
      | Ok text ->
          if not (contains_text text ("Running client scenario '" ^ scenario ^ "'")) then (
            C.add errors ("pending runner output malformed: " ^ scenario);
            runner_ok := false)
      | Error message ->
          C.add errors (Printf.sprintf "pending runner stdout missing: %s: %s" scenario message);
          runner_ok := false);
      let scenario_dir = Filename.concat base scenario in
      let paths =
        if C.dir_exists scenario_dir then
          match C.list_dirs scenario_dir with
          | Ok names -> List.map (Filename.concat scenario_dir) names
          | Error () -> []
        else []
      in
      let matching =
        List.filter
          (fun path ->
            match C.scenario_of_result_dir (Filename.basename path) with
            | Some name -> name = scenario
            | None -> false)
          paths
      in
      if List.length paths <> 1 || List.length matching <> 1 then begin
        entry :=
          set_field !entry "reason" (`String "result directory missing, duplicate, or unexpected");
        C.add errors ("pending result directories missing, duplicate or unexpected: " ^ scenario)
      end
      else begin
        let checks_path = Filename.concat (List.hd matching) "checks.json" in
        entry :=
          set_field !entry "checks_path"
            (`String (C.relative_path ~base:(Filename.dirname base) checks_path));
        (try
           let run = read_checks checks_path in
           entry := set_field !entry "result" (`String run.C.result);
           if run.C.result <> "skipped" then entry := del_field !entry "cause";
           entry :=
             set_field !entry "failed_check_ids"
               (C.member_json (List.map (fun id -> `String id) run.C.failed));
           entry :=
             set_field !entry "check_counts"
               (C.counter_json (C.counter (List.map (fun check -> check.C.status) run.C.checks)));
           let known = List.assoc_opt scenario !classifications in
           (match known with
           | Some (`Assoc pairs) ->
               let observed_ids = List.map (fun check -> check.C.id) run.C.checks in
               List.map fst pairs
               |> List.filter (fun check_id -> not (List.mem check_id observed_ids))
               |> List.sort_uniq String.compare
               |> List.iter (fun check_id ->
                   C.add errors
                     (Printf.sprintf "stale pending classification check: %s/%s" scenario check_id))
           | _ -> ());
           let evidence = evidence_map run.C.checks run.C.failed in
           entry := set_field !entry "failed_checks" (`Assoc []);
           List.iter
             (fun check_id ->
               let reason =
                 match known with
                 | Some (`Assoc _ as known) -> C.get_string known check_id
                 | _ -> None
               in
               let value =
                 match reason with
                 | Some reason when String.trim reason <> "" ->
                     entry_json [ ("cause", `String "fixture_gap"); ("reason", `String reason) ]
                 | _ ->
                     entry_json
                       [
                         ("cause", `String "unresolved");
                         ("reason", `String "New unscored failure has not been triaged");
                         ( "evidence",
                           `String (Option.value ~default:"" (Hashtbl.find_opt evidence check_id))
                         );
                       ]
               in
               let current =
                 match C.assoc_get !entry "failed_checks" with
                 | Some (`Assoc pairs) -> pairs
                 | _ -> []
               in
               entry := set_field !entry "failed_checks" (`Assoc (current @ [ (check_id, value) ])))
             run.C.failed
         with C.Bad message ->
           entry := set_field !entry "reason" (`String message);
           C.add errors
             (Printf.sprintf "pending checks unavailable or malformed: %s: %s" scenario message));
        if not !runner_ok then begin
          entry := set_field !entry "result" (`String "inconclusive");
          entry := set_field !entry "cause" (`String "unresolved");
          entry :=
            set_field !entry "reason"
              (`String "runner execution or output failed; see the scenario stdout and exit code");
          entry :=
            set_field !entry "stdout_path" (`String (Filename.concat base (scenario ^ ".stdout")))
        end
      end)
    expected;
  let gate = if C.any errors then "fail" else "pass" in
  let report =
    entry_json
      [
        ("mode", `String "pending");
        ("scored", `Bool false);
        ("scenarios", `Assoc (List.map (fun (k, v) -> (k, !v)) !scenarios));
        ("errors", `List (List.map (fun line -> `String line) errors.C.lines));
        ("gate", `String gate);
      ]
  in
  C.write_report report_path report;
  Printf.printf "pending (unscored): gate=%s; report=%s\n" gate report_path;
  List.iter (fun line -> prerr_endline ("error: " ^ line)) errors.C.lines;
  if C.any errors then 1 else 0

let compare args =
  let errors = C.errors () in
  let expected = C.ids (C.opt_exn args "manifest") in
  let results = C.opt_exn args "results" in
  let stdout_path = C.opt_exn args "stdout" in
  let report_path = C.opt_exn args "report" in
  let mode = Option.value ~default:"required" (C.opt args "mode") in
  let list_output = C.opt args "list_output" in
  let artifact_root = Filename.dirname results in
  let run_meta = ref [] in
  let meta key value = run_meta := !run_meta @ [ (key, value) ] in
  let metadata_ok = ref true in
  List.iter
    (fun (key, filename) ->
      match C.read_stripped (Filename.concat artifact_root filename) with
      | Ok text -> meta key (`String text)
      | Error message ->
          if list_output <> None then (
            C.add errors (Printf.sprintf "run metadata missing (%s): %s" filename message);
            metadata_ok := false))
    [
      ("date_utc", "run-date-utc.txt");
      ("server_commit", "server-commit.txt");
      ("runner_version", "runner-version.txt");
      ("node_version", "node-version.txt");
      ("npm_version", "npm-version.txt");
      ("command", "required-command.txt");
    ];
  let status_path = Filename.concat artifact_root "working-tree-status.txt" in
  meta "working_tree_status_path" (`String status_path);
  (match C.read_file status_path with
  | Ok text ->
      let lines = C.split_lines text in
      meta "working_tree_clean" (`Bool (lines = []));
      meta "working_tree_status_count" (`Int (List.length lines))
  | Error message ->
      meta "working_tree_clean" `Null;
      meta "working_tree_status_count" `Null;
      if list_output <> None then (
        C.add errors ("run metadata missing (working-tree-status.txt): " ^ message);
        metadata_ok := false));
  let unscored = ref [] in
  let runner_ok = ref !metadata_ok in
  let count_errors () = List.length errors.C.lines in
  (match list_output with
  | None -> ()
  | Some list_path -> (
      try
        let text = read_text list_path in
        let before = count_errors () in
        C.exact "official list" (C.runner_list text) expected errors;
        unscored := C.runner_unscored text;
        if
          List.length !unscored <> List.length (List.sort_uniq String.compare !unscored)
          || List.exists (fun scenario -> List.mem scenario expected) !unscored
        then C.add errors "official unscored list contains duplicate or required IDs";
        if count_errors () <> before then runner_ok := false
      with C.Bad message ->
        C.add errors ("runner list parser error: " ^ message);
        runner_ok := false));
  (try
     let text = read_text stdout_path in
     let before = count_errors () in
     C.exact "executed scenarios" (C.executed_scenarios text) (expected @ !unscored) errors;
     if count_errors () <> before then runner_ok := false;
     if not (contains_text text "=== SUMMARY ===") then (
       C.add errors "runner summary missing";
       runner_ok := false)
   with C.Bad message ->
     C.add errors ("runner stdout missing: " ^ message);
     runner_ok := false);
  let runner_exit_code = ref None in
  (match read_exit_code (C.opt_exn args "exit_code") with
  | `Code code ->
      runner_exit_code := Some code;
      if code <> 0 && code <> 1 then (
        C.add errors (Printf.sprintf "runner crashed or timed out: exit %d" code);
        runner_ok := false)
  | `Error message ->
      C.add errors ("runner exit code missing: " ^ message);
      runner_ok := false
  | `Bad message ->
      C.add errors ("runner exit code missing: " ^ message);
      runner_ok := false);
  let found = Hashtbl.create 16 in
  let found_order = ref [] in
  if not (C.dir_exists results) then C.add errors ("runner result directory missing: " ^ results)
  else begin
    let names = match C.list_dirs results with Ok names -> names | Error () -> [] in
    List.iter
      (fun name ->
        match C.scenario_of_result_dir name with
        | None -> C.add errors ("unrecognized result directory: " ^ name)
        | Some scenario ->
            if not (Hashtbl.mem found scenario) then found_order := !found_order @ [ scenario ];
            let existing = Option.value ~default:[] (Hashtbl.find_opt found scenario) in
            Hashtbl.replace found scenario (existing @ [ Filename.concat results name ]))
      names;
    C.exact "result directories" !found_order (expected @ !unscored) errors;
    List.iter
      (fun scenario ->
        let paths = Option.value ~default:[] (Hashtbl.find_opt found scenario) in
        if List.length paths <> 1 then
          C.add errors
            (Printf.sprintf "duplicate result directory for %s: %d" scenario (List.length paths)))
      !found_order
  end;
  let baseline =
    if mode = "required" then load_baseline (C.opt args "baseline") expected errors else []
  in
  let unscored_entries = ref [] in
  List.iter
    (fun scenario ->
      let paths = Option.value ~default:[] (Hashtbl.find_opt found scenario) in
      let outcome =
        ref (entry_json [ ("result", `String "inconclusive"); ("checks_path", `Null) ])
      in
      unscored_entries := !unscored_entries @ [ (scenario, outcome) ];
      if List.length paths <> 1 then
        C.add errors ("unscored missing or duplicate result directory: " ^ scenario)
      else begin
        let path = Filename.concat (List.hd paths) "checks.json" in
        outcome :=
          set_field !outcome "checks_path"
            (`String (C.relative_path ~base:(Filename.dirname results) path));
        match read_checks path with
        | exception C.Bad message ->
            outcome := set_field !outcome "reason" (`String message);
            C.add errors
              (Printf.sprintf "unscored checks unavailable or malformed: %s: %s" scenario message)
        | run ->
            outcome := set_field !outcome "result" (`String run.C.result);
            outcome :=
              set_field !outcome "failed_check_ids"
                (C.member_json (List.map (fun id -> `String id) run.C.failed));
            outcome :=
              set_field !outcome "check_counts"
                (C.counter_json (C.counter (List.map (fun check -> check.C.status) run.C.checks)))
      end)
    !unscored;
  let scenarios = ref [] in
  List.iter
    (fun scenario ->
      let paths = Option.value ~default:[] (Hashtbl.find_opt found scenario) in
      let entry =
        ref
          (entry_json
             [
               ("result", `String "inconclusive");
               ("cause", `String "unresolved");
               ("checks_path", `Null);
               ("failed_checks", `Assoc []);
             ])
      in
      scenarios := !scenarios @ [ (scenario, entry) ];
      if List.length paths <> 1 then begin
        entry := set_field !entry "reason" (`String "missing or duplicate result directory");
        C.add errors ("inconclusive: " ^ scenario ^ ": missing or duplicate result directory")
      end
      else begin
        let checks_path = Filename.concat (List.hd paths) "checks.json" in
        entry :=
          set_field !entry "checks_path"
            (`String (C.relative_path ~base:(Filename.dirname results) checks_path));
        match read_checks checks_path with
        | exception C.Bad message ->
            let reason = "checks.json unavailable or malformed: " ^ message in
            entry := set_field !entry "reason" (`String reason);
            C.add errors ("inconclusive: " ^ scenario ^ ": " ^ reason)
        | run ->
            entry :=
              set_field !entry "failed_check_ids"
                (C.member_json (List.map (fun id -> `String id) run.C.failed));
            entry :=
              set_field !entry "check_counts"
                (C.counter_json (C.counter (List.map (fun check -> check.C.status) run.C.checks)));
            let evidence = evidence_map run.C.checks run.C.failed in
            entry := set_field !entry "result" (`String run.C.result);
            if run.C.result = "skipped" then begin
              entry := set_field !entry "result" (`String "inconclusive");
              entry := set_field !entry "reason" (`String "all checks skipped");
              C.add errors ("inconclusive: " ^ scenario ^ ": all checks skipped")
            end
            else entry := del_field !entry "cause";
            if mode = "required" then begin
              let prior = List.assoc_opt scenario baseline in
              if run.C.result = "fail" then begin
                (match prior with
                | Some prior when py_truthy prior -> (
                    let prior_checks =
                      match prior with `Assoc _ -> C.assoc_get prior "checks" | _ -> None
                    in
                    match prior_checks with
                    | Some (`Assoc pairs) ->
                        let prior_ids = List.sort_uniq String.compare (List.map fst pairs) in
                        let failed_ids = List.sort_uniq String.compare run.C.failed in
                        if prior_ids <> failed_ids then
                          C.add errors ("baseline failed check IDs changed: " ^ scenario);
                        let selected =
                          List.filter_map
                            (fun check_id ->
                              match List.assoc_opt check_id pairs with
                              | Some value -> Some (check_id, value)
                              | None -> None)
                            run.C.failed
                        in
                        entry := set_field !entry "failed_checks" (`Assoc selected)
                    | _ -> C.add errors ("baseline failed check IDs changed: " ^ scenario))
                | _ -> C.add errors ("unexpected failure: " ^ scenario));
                List.iter
                  (fun check_id ->
                    let current =
                      match C.assoc_get !entry "failed_checks" with
                      | Some (`Assoc pairs) -> pairs
                      | _ -> []
                    in
                    if not (List.mem_assoc check_id current) then
                      entry :=
                        set_field !entry "failed_checks"
                          (`Assoc
                             (current
                             @ [
                                 ( check_id,
                                   entry_json
                                     [
                                       ("cause", `String "unresolved");
                                       ( "reason",
                                         `String "New required failure has not been triaged" );
                                       ( "evidence",
                                         `String
                                           (Option.value ~default:""
                                              (Hashtbl.find_opt evidence check_id)) );
                                     ] );
                               ])))
                  run.C.failed
              end
              else
                match prior with
                | Some prior when py_truthy prior ->
                    C.add errors ("stale baseline entry: " ^ scenario)
                | _ -> ()
            end
      end)
    expected;
  if not !runner_ok then
    List.iter
      (fun (_, entry) ->
        entry := set_field !entry "result" (`String "inconclusive");
        entry := set_field !entry "cause" (`String "unresolved");
        entry :=
          set_field !entry "reason" (`String "required runner execution or output parsing failed");
        entry := set_field !entry "stdout_path" (`String stdout_path))
      !scenarios;
  let results_of_entries =
    List.map (fun (_, entry) -> Option.value ~default:"" (C.get_string !entry "result")) !scenarios
  in
  let counts = C.counter results_of_entries in
  let counts_json =
    `Assoc
      [
        ("pass", `Int (C.counter_get counts "pass"));
        ("fail", `Int (C.counter_get counts "fail"));
        ("inconclusive", `Int (C.counter_get counts "inconclusive"));
      ]
  in
  if !runner_exit_code = Some 1 && C.counter_get counts "fail" = 0 then
    C.add errors "runner exit 1 without required scenario failure";
  let gate = if C.any errors then "fail" else "pass" in
  let report =
    entry_json
      ([
         ("mode", `String mode);
         ("manifest", `String (C.opt_exn args "manifest"));
         ("scenarios", `Assoc (List.map (fun (k, v) -> (k, !v)) !scenarios));
         ("errors", `List (List.map (fun line -> `String line) errors.C.lines));
         ("run", `Assoc !run_meta);
         ("unscored_scenarios", `Assoc (List.map (fun (k, v) -> (k, !v)) !unscored_entries));
         ("counts", counts_json);
         ("required_execution_count", `Int (List.length expected));
         ("unscored_execution_count", `Int (List.length !unscored));
         ("gate", `String gate);
       ]
      @ match !runner_exit_code with Some code -> [ ("runner_exit_code", `Int code) ] | None -> [])
  in
  C.write_report report_path report;
  Printf.printf "%s: {'pass': %d, 'fail': %d, 'inconclusive': %d}; gate=%s; report=%s\n" mode
    (C.counter_get counts "pass") (C.counter_get counts "fail")
    (C.counter_get counts "inconclusive")
    gate report_path;
  List.iter (fun line -> prerr_endline ("error: " ^ line)) errors.C.lines;
  if C.any errors then 1 else 0

let () =
  let program = Filename.basename Sys.argv.(0) in
  let args =
    C.parse_args ~program
      ~spec:
        [
          ("manifest", true);
          ("results", true);
          ("stdout", false);
          ("exit_code", false);
          ("report", true);
          ("list_output", false);
          ("baseline", false);
          ("pending_classifications", false);
          ("mode", false);
        ]
      ()
  in
  let mode = Option.value ~default:"required" (C.opt args "mode") in
  if mode <> "required" && mode <> "pending" then begin
    prerr_endline
      (Printf.sprintf
         "%s: error: argument --mode: invalid choice: '%s' (choose from 'required', 'pending')"
         program mode);
    exit 2
  end;
  if mode <> "pending" && (C.opt args "stdout" = None || C.opt args "exit_code" = None) then begin
    prerr_endline (program ^ ": error: --stdout and --exit-code are required in required mode");
    exit 2
  end;
  let code =
    try if mode = "pending" then compare_pending args else compare args
    with C.Bad message ->
      prerr_endline ("error: " ^ message);
      1
  in
  exit code
