(* Extraction benchmark harness for the stdlib backend over test/corpus_html/. *)

module M = Extract_metrics

let monotonic_ms () = Unix.gettimeofday () *. 1000.0

(* Median of [n] timed runs. The median rather than the mean: a page measured
   once in a while pays a cold allocator, and that is not the number a reader
   compares across backends. *)
let time_extract (c : M.case) ~runs =
  let samples =
    List.init runs (fun _ ->
        let start = monotonic_ms () in
        (* A refusal is a measured outcome like any other: the shared-stream
           grinder is worth timing precisely because its answer is "no", quickly. *)
        (match M.run c with
        | _ -> ()
        | exception _ -> ());
        monotonic_ms () -. start)
  in
  let sorted = List.sort Float.compare samples in
  List.nth sorted (List.length sorted / 2)

(* Words allocated across one call — minor, promoted, and major. A word count
   rather than a byte count because it is what the runtime counts, and the thing
   worth comparing between backends is the multiplier between the bytes in and
   the working set out, not a byte figure the collector would dispute. *)
let alloc_words f =
  let words c = c.Gc.minor_words +. c.Gc.promoted_words +. c.Gc.major_words in
  let before = words (Gc.quick_stat ()) in
  (match f () with
  | _ -> ()
  | exception _ -> ());
  let after = words (Gc.quick_stat ()) in
  after -. before

type row = {
  case : M.case;
  m : M.metrics;
  median_ms : float;
  alloc_words : float;
  bar_failures : string list;
}

let row_of (c : M.case) =
  let m = M.measure c in
  let median_ms = time_extract c ~runs:5 in
  {
    case = c;
    m;
    median_ms;
    alloc_words = alloc_words (fun () -> M.run c);
    bar_failures = M.bar_failures ~median_ms c m;
  }

let to_json (r : row) : Yojson.Safe.t =
  let b = ref [] in
  let add k v = b := (k, v) :: !b in
  let strs l = `List (List.map (fun s -> `String s) l) in
  add "backend" (`String "ocaml-stdlib");
  add "id" (`String r.case.M.id);
  add "fixture" (`String r.case.M.file);
  add "category" (`String r.case.M.category);
  add "kind" (`String r.case.M.kind);
  add "expect" (`String r.case.M.expect);
  add "outcome" (`String r.m.M.outcome);
  add "outcome_matches_expect"
    (`Bool (r.case.M.expect = M.outcome_of r.m));
  add "essential_hit" (`Int r.m.M.essential_hit);
  add "essential_total" (`Int r.m.M.essential_total);
  add "boiler_hit" (`Int r.m.M.boiler_hit);
  add "boiler_total" (`Int r.m.M.boiler_total);
  add "title_ok" (`Bool r.m.M.title_ok);
  add "unicode_ok" (`Bool r.m.M.unicode_ok);
  add "unicode_total" (`Int r.m.M.unicode_total);
  add "deterministic" (`Bool r.m.M.deterministic);
  add "essential_missed" (strs r.m.M.essential_missed);
  add "boiler_missed" (strs r.m.M.boiler_missed);
  add "codepoints" (`Int r.m.M.codepoints);
  add "bytes" (`Int (String.length r.case.M.body));
  add "replacements" (`Int r.m.M.replacements);
  add "median_ms"
    (`Float (Float.of_int (int_of_float (r.median_ms *. 1000.)) /. 1000.));
  add "alloc_words" (`Float r.alloc_words);
  add "bar_failures" (strs r.bar_failures);
  `Assoc (List.rev !b)

let dump_case cases wanted =
  match List.filter (fun (c : M.case) -> c.M.id = wanted) cases with
  | [] ->
      prerr_endline ("bench: no case " ^ wanted);
      exit 1
  | [ c ] -> (
      match M.run c with
      | M.Text t ->
          Printf.eprintf "--- title ---\n%s\n--- text ---\n%s\n"
            (Option.value ~default:"(none)" t.title) t.text
      | M.Refusal m -> Printf.eprintf "--- refusal ---\n%s\n" m)
  | _ :: _ ->
      prerr_endline ("bench: duplicate case id " ^ wanted);
      exit 1

let cell w s =
  let pad = String.make (max 0 (w - String.length s)) ' ' in
  s ^ pad

(* The verdict column is the bar, not the metric: a row that meets every bar it
   carries needs no reading, and a row that fails one names the failure. *)
let verdict_mark r =
  match r.bar_failures with
  | [] -> "bar met"
  | fails -> "BAR FAIL: " ^ String.concat "; " fails

let print_table rows =
  Printf.printf "%s %s %10s %8s %5s %7s %4s %8s %8s %5s %7s  %s\n"
    (cell 26 "id") (cell 18 "category") "essential" "boiler" "title" "unicode"
    "det" "chars" "bytes" "repl" "ms" "verdict";
  List.iter
    (fun r ->
      Printf.printf
        "%s %s %10s %8s %5s %7s %4s %8d %8d %5d %7.2f  %s\n"
        (cell 26 r.case.M.id) (cell 18 r.case.M.category)
        (Printf.sprintf "%d/%d" r.m.M.essential_hit r.m.M.essential_total)
        (Printf.sprintf "%d/%d" r.m.M.boiler_hit r.m.M.boiler_total)
        (if r.m.M.title_ok then "ok" else "MISS")
        (if r.m.M.unicode_total = 0 then "-"
         else if r.m.M.unicode_ok then "ok"
         else "MISS")
        (if r.m.M.deterministic then "yes" else "NO")
        r.m.M.codepoints
        (String.length r.case.M.body) r.m.M.replacements r.median_ms
        (verdict_mark r))
    rows;
  let sum f = List.fold_left (fun acc r -> acc + f r) 0 rows in
  Printf.printf "\n%s\n"
    (Printf.sprintf
       "cases=%d  essential=%d/%d  boiler_leaked=%d/%d  title_ok=%d  \
        unicode_ok=%d  deterministic=%d  refusals=%d  bars_failed=%d"
       (List.length rows) (sum (fun r -> r.m.M.essential_hit))
       (sum (fun r -> r.m.M.essential_total)) (sum (fun r -> r.m.M.boiler_hit))
       (sum (fun r -> r.m.M.boiler_total))
       (List.length (List.filter (fun r -> r.m.M.title_ok) rows))
       (List.length
          (List.filter (fun r -> r.m.M.unicode_ok || r.m.M.unicode_total = 0)
            rows))
       (List.length (List.filter (fun r -> r.m.M.deterministic) rows))
       (List.length (List.filter (fun r -> r.m.M.outcome <> "text") rows))
       (sum (fun r -> List.length r.bar_failures)))

let check_dir dir =
  let cases = M.load_cases dir in
  if cases = [] then (
    prerr_endline "bench: the corpus manifest named no cases";
    exit 1);
  if List.length cases < 30 then
    prerr_endline
      (Printf.sprintf
         "bench: the corpus has %d cases; quality bar needs the ordinary, \
          malformed, encoding, hostile and PDF families, not a toy set"
         (List.length cases));
  let failures, measured =
    List.fold_left
      (fun (fails, n) (c : M.case) ->
        let m = M.measure c in
        let fails_for_c = M.bar_failures ~median_ms:(time_extract c ~runs:3) c m in
        match fails_for_c with
        | [] -> (fails, n + 1)
        | fs -> ((c.M.id, fs) :: fails, n))
      ([], 0) cases
  in
  let rows = List.length cases in
  if failures = [] then (
    Printf.printf "%d/%d corpus cases meet their recorded bar\n" measured rows;
    0)
  else (
    List.iter
      (fun (id, fs) ->
        prerr_endline (Printf.sprintf "%s: %s" id (String.concat "; " fs)))
      (List.rev failures);
    prerr_endline
      (Printf.sprintf "%d of %d corpus cases miss their recorded bar"
         (List.length failures) rows);
    1)

let () =
  let args = Array.to_list (Array.sub Sys.argv 1 (Array.length Sys.argv - 1)) in
  let json = ref false and dump = ref None and dirs = ref [] in
  let check = ref false in
  let usage () =
    prerr_endline
      "usage: bench <corpus-dir> [--json] [--case <id>] [--check]";
    exit 2
  in
  let rec go = function
    | [] -> ()
    | "--json" :: rest ->
        json := true;
        go rest
    | "--check" :: rest ->
        check := true;
        go rest
    | "--case" :: id :: rest ->
        dump := Some id;
        go rest
    | "--case" :: [] -> usage ()
    | d :: rest ->
        dirs := d :: !dirs;
        go rest
  in
  go args;
  let dir = match !dirs with [ d ] -> d | _ -> usage () in
  if !check then exit (check_dir dir);
  let cases = M.load_cases dir in
  if cases = [] then (
    prerr_endline "bench: the corpus manifest named no cases";
    exit 1);
  match !dump with
  | Some id -> dump_case cases id
  | None ->
      let rows = List.map row_of cases in
      if !json then
        List.iter (fun r -> print_endline (Yojson.Safe.to_string (to_json r))) rows
      else (
        print_table rows;
        List.iter
          (fun r ->
            match r.bar_failures with
            | [] -> ()
            | fails ->
                prerr_endline
                  (Printf.sprintf "%s: %s" r.case.M.id
                     (String.concat "; " fails)))
          rows)
