(* The differential golden runner.

   This is the part of the harness [dune runtest] actually pays for: it walks
   [golden/], re-runs the OCaml projection of each corpus input, and requires it
   to equal the section the Python oracle pinned. No Python, no network, no
   provider endpoint sits in the gate — the oracle's answers are pinned in the
   tree, and the format that pins them is specified in [README.md].

   The checks deliberately fail on the harness's own bookkeeping, not just on
   the port:

   - every golden needs its corpus input (delete an input and its golden stops
     being evidence and becomes a failure);
   - every corpus input needs a golden (an input nobody pinned is a case the
     gate does not run);
   - each area must carry at least [min_cases] cases, so quietly emptying a
     directory cannot thin the suite to nothing;
   - an [explicit-divergence] golden passes only while the port still disagrees
     with the oracle *and* still answers as its pinned [--- port] section says —
     a divergence that closes on its own flips the suite the same as a
     regression. *)

open Seekwright_diff

(* The golden file's shape: a key/value header, then [--- oracle] (always) and
   [--- port] (only for an explicit divergence). One parse shared with nothing
   else, so a malformed golden cannot pass by being unread. *)
type golden =
  {
    area : string;
    case : string;
    verification : string;
    oracle : string;
    projection : string;
    reason : string option;
    oracle_lines : string list;
    port_lines : string list option;
  }

let lines_of file =
  let channel = open_in_bin file in
  let rec go acc =
    match input_line channel with
    | exception End_of_file -> List.rev acc
    | line -> go (line :: acc)
  in
  let all = go [] in
  close_in channel;
  all

let parse path =
  let all = lines_of path in
  let is_marker line = String.length line >= 4 && String.sub line 0 4 = "--- " in
  let header_end = ref 0 in
  while !header_end < List.length all && not (is_marker (List.nth all !header_end)) do
    incr header_end
  done;
  let header =
    List.map
      (fun line ->
        match String.index_opt line ':' with
        | Some at -> (String.sub line 0 at, String.sub line (at + 2) (String.length line - at - 2))
        | None -> failwith (Printf.sprintf "%s: header line without `key: value`: %S" path line))
      (List.filter (( <> ) "") (List.filteri (fun i _ -> i < !header_end) all))
  in
  let sections =
    let rec go done_sections acc name rest =
      match rest with
      | [] -> List.rev ((name, List.rev acc) :: done_sections)
      | line :: more ->
          if is_marker line
          then go ((name, List.rev acc) :: done_sections) [] (String.sub line 4 (String.length line - 4)) more
          else go done_sections (line :: acc) name more
    in
    List.filter (fun (name, _) -> name <> "") (go [] [] "" (List.tl all))
  in
  let section name =
    match List.assoc_opt name sections with
    | Some body when body <> [] -> body
    | _ -> failwith (Printf.sprintf "%s: no --- %s section" path name)
  in
  let field name =
    match List.assoc_opt name header with
    | Some v -> v
    | None -> failwith (Printf.sprintf "%s: golden header has no %S" path name)
  in
  {
    area = field "area";
    case = field "case";
    verification = field "verification";
    oracle = field "oracle";
    projection = field "projection";
    reason = List.assoc_opt "reason" header;
    oracle_lines = section "oracle";
    port_lines = (match List.assoc_opt "port" sections with Some [] | None -> None | Some body -> Some body);
  }

(* Extensions by area: config inputs are TOML, sanitize inputs are raw text,
   everything else is a JSON spec. *)
let extension_of = function
  | "config" -> "toml"
  | "sanitize" -> "txt"
  | _ -> "json"

let corpus_path area case =
  Filename.concat (Filename.concat "corpus" area) (case ^ "." ^ extension_of area)

let read_text path =
  let channel = open_in_bin path in
  let length = in_channel_length channel in
  let text = really_input_string channel length in
  close_in channel;
  text

(* The floor per area. The counts here are floors, not exact expectations: the
   suite is meant to gain cases, but a directory emptied out or a whole area
   dropped fails rather than shrinking the gate in silence. *)
let min_cases =
  [
    ("config", 80);
    ("sanitize", 20);
    ("fetch", 40);
    ("jsondoc", 45);
    ("tabledoc", 16);
    ("text", 42);
    ("router", 7);
    ("model", 7);
    ("engine", 10);
    ("provider", 30);
  ]

let projection area =
  match List.assoc_opt area Projection.areas with
  | Some project -> project
  | None -> failwith (Printf.sprintf "golden names area %S, and no projection owns it" area)

let check (golden : golden) () =
  let input = corpus_path golden.area golden.case in
  if not (Sys.file_exists input)
  then failwith (Printf.sprintf "%s/%s: the golden has no corpus input at %s" golden.area golden.case input);
  let project = projection golden.area in
  let port = if golden.area = "config" then project input else project (read_text input) in
  match golden.verification with
  | "differential-golden" ->
    if golden.port_lines <> None then failwith (Printf.sprintf "%s/%s: a agreeing golden carries a --- port section" golden.area golden.case);
    if golden.oracle <> "python" then failwith (Printf.sprintf "%s/%s: unknown oracle %S" golden.area golden.case golden.oracle);
    if golden.projection <> golden.area then failwith (Printf.sprintf "%s/%s: projection %S names no area" golden.area golden.case golden.projection);
    if port <> golden.oracle_lines
    then
      failwith
        (Printf.sprintf
           "%s/%s: the port diverged from its golden.\n  pinned:\n    %s\n  port now:\n    %s"
           golden.area golden.case (String.concat "\n    " golden.oracle_lines) (String.concat "\n    " port))
  | "explicit-divergence" ->
    let pinned =
      match golden.port_lines with
      | Some body -> body
      | None -> failwith (Printf.sprintf "%s/%s: an explicit divergence pins no --- port section" golden.area golden.case)
    in
    if golden.reason = None
    then failwith (Printf.sprintf "%s/%s: an explicit divergence carries no reason" golden.area golden.case);
    if port <> pinned
    then
      failwith
        (Printf.sprintf
           "%s/%s: the port no longer answers as its divergence was pinned.\n  pinned:\n    %s\n  port now:\n    %s"
           golden.area golden.case (String.concat "\n    " pinned) (String.concat "\n    " port));
    if port = golden.oracle_lines
    then
      failwith
        (Printf.sprintf
           "%s/%s: the port now agrees with the oracle — this divergence has closed, so the golden must become differential-golden (and the reason in gen_goldens.py retired)"
           golden.area golden.case)
  | other -> failwith (Printf.sprintf "%s/%s: unknown verification %S" golden.area golden.case other)

(* A missing directory is reported as empty here and turned into a named failure
   by [area_coverage], so a suite that loses an area says which area and why
   instead of dying where it walks the filesystem. *)
let listed directory =
  if not (Sys.file_exists directory)
  then []
  else Array.to_list (Sys.readdir directory) |> List.filter (fun name -> name <> "." && name <> "..") |> List.sort String.compare

let goldens_of area =
  listed (Filename.concat "golden" area)
  |> List.filter (fun name -> Filename.check_suffix name ".golden")
  |> List.map (fun name -> Filename.concat (Filename.concat "golden" area) name)

let corpus_of area = listed (Filename.concat "corpus" area)

(* one test case per golden, so a failure names the case *)
let area_tests area =
  goldens_of area
  |> List.map (fun path ->
         let golden = parse path in
         if golden.area <> area || Filename.remove_extension (Filename.basename path) <> golden.case
         then failwith (Printf.sprintf "%s: the golden header disagrees with where the file sits" path);
         (golden.case, `Quick, check golden))

(* the reverse direction and the floor, once per area *)
let area_coverage area =
  ( "coverage:" ^ area,
    `Quick,
    fun () ->
      let expected =
        match List.assoc_opt area min_cases with
        | Some n -> n
        | None -> failwith (Printf.sprintf "no minimum case count is declared for area %s" area)
      in
      List.iter
        (fun directory ->
          if not (Sys.file_exists directory)
          then
            failwith
              (Printf.sprintf "area %s has no %s directory — an area is added to the floor, the stanza deps, and the tree together"
                 area directory))
        [ Filename.concat "golden" area; Filename.concat "corpus" area ];
      let goldens = goldens_of area |> List.length in
      if goldens < expected
      then failwith (Printf.sprintf "area %s pins %d goldens, below the floor of %d" area goldens expected);
      List.iter
        (fun input ->
          let case = Filename.remove_extension input in
          let golden = Filename.concat (Filename.concat "golden" area) (case ^ ".golden") in
          if not (Sys.file_exists golden)
          then failwith (Printf.sprintf "corpus input %s/%s has no golden — regenerate, or delete the input" area input))
        (corpus_of area) )

let () =
  Canon.reset_key_environment ();
  let harness =
    ( "harness",
      [
        ( "the floor lists exactly the areas the projections own",
          `Quick,
          fun () ->
            List.iter
              (fun (area, _) ->
                if not (List.mem_assoc area Projection.areas)
                then failwith (Printf.sprintf "the floor lists area %s, and no projection owns it" area))
              min_cases;
            List.iter
              (fun (area, _) ->
                if not (List.mem_assoc area min_cases)
                then failwith (Printf.sprintf "a projection owns area %s, and the floor does not count it" area))
              Projection.areas );
      ] )
  in
  let groups =
    List.map
      (fun area -> (area, area_tests area @ [ area_coverage area ]))
      (List.map fst min_cases)
  in
  Alcotest.run "differential-golden" (harness :: groups)
