(* The parity-matrix validator.

   [matrix/*.tsv] is the F0.1 inventory: one row per provider, config key,
   behaviour and surface item, each naming the port consumer, the baseline
   evidence behind the claim and the verification that tests it. A table like
   that is evidence only while its shape holds, so this suite re-reads it at
   every [dune runtest] rather than taking the table's word for it:

   - the header and the column count are pinned, so a column cannot be renamed,
     dropped or reordered without a failure naming the table;
   - no cell is blank, and no cell outsources a consumer to a phrase — [unknown
     consumer] and [the code looks equivalent] are the two ways a manifest like
     this goes wrong, and both fail here rather than in review;
   - the state, quota and live-status columns come from closed vocabularies, so
     a row cannot invent a status that no reader would know how to act on;
   - every verification cell names a kind from the plan's vocabulary, or is an
     explicit [pending-F*] on a row whose port side does not exist yet. A ported
     or honoured row resting on [pending] fails, and a not-ported row may not
     quietly claim a verification it does not have;
   - every module or suite a row points at is a file this tree carries — the
     staged deps are the point, so a consumer that was renamed away or never
     written fails the row that credits it;
   - the provider rows are exactly [Config.known_providers], and the corpus
     areas the golden runner pins are exactly the areas the behaviour rows
     claim to cover;
   - the accepted divergences are the record in [divergences.tsv] and the
     [explicit-divergence] goldens are its evidence: every row names a golden
     whose [reason] header repeats the row, and every such golden is either a
     row or a member of one of the two systematic reason families.

   The [baseline] columns are the frozen corpus's counterpart: a cell names the
   corpus area, provider golden set or port suite that carries the evidence, so a
   pointer outside this tree is not one of the forms the check accepts. *)

open Seekwright

type table = {
  file : string; (* the table's path in the test sandbox *)
  header : string list (* the exact header line, so columns cannot drift *);
  state_column : string; (* the column that says how far the port side got *)
  state_allowed : string list (* its closed vocabulary *);
  placeholder_columns : string list;
      (* columns that may hold a [-], [n/a] or [(none ...)] placeholder, and only
     when the row's state says the port side is absent *)
}

(* The plan's verification vocabulary. [pending] is not one of these: it is the
   marker a not-ported row carries so it never claims an unevaluated parity. *)
let verification_kinds =
  [
    "unit";
    "differential-golden";
    "loopback-integration";
    "official-conformance";
    "local-live";
    "keyless-live";
    "keyed-live";
    "explicit-divergence";
  ]

(* A phrase that stands in for an answer. Each one is a row whose consumer or
   parity nobody worked out, which is what the exit criterion refuses. *)
let forbidden_phrases =
  [
    "unknown";
    "tbd";
    "todo";
    "to be determined";
    "looks equivalent";
    "code looks";
    "probably";
    "assume";
    "assumed";
  ]

let placeholder_values = [ "-"; "n/a" ]

let starts prefix text =
  String.length text >= String.length prefix && String.sub text 0 (String.length prefix) = prefix

(* [String.contains] is a character test; the matrix needs the phrase form, and
   the forbidden-phrase check is case-folded by its callers. *)
let contains_text haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec go at =
    if at + needle_length > haystack_length then false
    else if String.sub haystack at needle_length = needle then true
    else go (at + 1)
  in
  go 0

(* A wave token is a capital [F] followed by one or two digits and delimited by
   non-alphanumerics. The boundary matters: a port cell names files such as
   [lib/text/utf8.ml], and a case-folded substring test reads its [f8] as a wave. *)
let names_wave text =
  let is_digit c = c >= '0' && c <= '9' in
  let is_alnum c = is_digit c || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') in
  let length = String.length text in
  let rec digit_run at = if at < length && is_digit text.[at] then digit_run (at + 1) else at in
  let rec go at =
    if at >= length then false
    else if
      text.[at] = 'F'
      && (at = 0 || not (is_alnum text.[at - 1]))
      && at + 1 < length
      && is_digit text.[at + 1]
    then
      let stops = digit_run (at + 1) in
      let digits = stops - at - 1 in
      if digits <= 2 && (stops >= length || not (is_alnum text.[stops])) then true else go stops
    else go (at + 1)
  in
  go 0

let read_lines path =
  if not (Sys.file_exists path) then
    failwith
      (Printf.sprintf
         "the matrix has no %s — the tables under matrix/ are committed data, so a missing one is \
          a deleted file"
         path);
  let channel = open_in_bin path in
  let rec go acc =
    match input_line channel with exception End_of_file -> List.rev acc | line -> go (line :: acc)
  in
  let all = go [] in
  close_in channel;
  List.filter (fun line -> line <> "") all

let index_of name header =
  let rec go at = function
    | [] -> None
    | column :: more -> if column = name then Some at else go (at + 1) more
  in
  match go 0 header with
  | Some at -> at
  | None -> failwith (Printf.sprintf "a matrix table has no %S column" name)

let cell header column row =
  let at = index_of column header in
  if at >= List.length row then
    failwith
      (Printf.sprintf "a row has %d columns, fewer than the header's %d" (List.length row)
         (List.length header));
  List.nth row at

let is_placeholder text = List.mem text placeholder_values || starts "(none" text || text = "-"

(* Cells mix paths with prose ([lib/engine.ml:Search capping]) and with
   verification detail ([unit(test_fetch)]). Splitting on every separator the
   tables use, then keeping the words that end in a source extension, is what
   lets a check say "this consumer exists" about a cell that also explains
   itself. *)
let words_of cell_text =
  let normalized = String.map (fun c -> if String.contains " ;,()\t" c then ' ' else c) cell_text in
  List.filter (fun word -> word <> "") (String.split_on_char ' ' normalized)

let strip_marks word =
  let marks = "[]{}()/*+-'\"`." in
  let rec left text =
    if text <> "" && String.contains marks text.[0] then
      left (String.sub text 1 (String.length text - 1))
    else text
  in
  let rec right text =
    let length = String.length text in
    if length > 0 && String.contains marks text.[length - 1] then
      right (String.sub text 0 (length - 1))
    else text
  in
  right (left word)

let path_token word =
  (* a [module:symbol] pointer is about the module; [engine.mli] is prose about
     an interface, not a file a row credits *)
  let head =
    match String.index_opt word ':' with Some at -> String.sub word 0 at | None -> word
  in
  let candidate = strip_marks head in
  if candidate = "" || Filename.check_suffix candidate ".mli" then None
  else if Filename.check_suffix candidate ".ml" then Some candidate
  else None

let has_no_slash token = not (String.contains token '/')

(* Where a path-like token lives, given how the tables spell their pointers.
   Every pointer names a module this tree owns, so the rules are the port's
   layout: [lib/], [bin/] and [test/] keep their own prefix, [fetch/], [factory/]
   and [providers/] are the [lib/] subtrees the tables name without it,
   [extractors/] is the backend directory under [lib/fetch/], and a bare name is
   a [test_] suite or a [lib/] module. The [../../] is the sandbox's: a
   [dune runtest] runs in the stanza's build directory, so the repository root is
   two levels up. *)
let resolve token =
  if starts "lib/" token || starts "bin/" token || starts "test/" token then Some ("../../" ^ token)
  else if starts "fetch/" token || starts "factory/" token || starts "providers/" token then
    Some ("../../lib/" ^ token)
  else if starts "extractors/" token then Some ("../../lib/fetch/" ^ token)
  else if has_no_slash token then
    if starts "test_" token then Some ("../../test/" ^ token) else Some ("../../lib/" ^ token)
  else None

let check_pointers table_name header row =
  List.iteri
    (fun column cell_text ->
      List.iter
        (fun token ->
          match resolve token with
          | None -> ()
          | Some path ->
              if not (Sys.file_exists path) then
                failwith
                  (Printf.sprintf
                     "%s, column %S: points at %s (%s), which is not in the sandbox the test runs \
                      in"
                     table_name (List.nth header column) token path))
        (List.filter_map path_token (words_of cell_text)))
    row

let check_row table header row =
  let name = Filename.basename table.file in
  if List.length row <> List.length header then
    failwith
      (Printf.sprintf "%s: a row has %d columns, the header has %d" name (List.length row)
         (List.length header));
  List.iter
    (fun (column, text) ->
      let header_name = List.nth header column in
      if String.trim text = "" then
        failwith
          (Printf.sprintf "%s: column %S has an empty cell in a row about %S" name header_name
             (List.hd row));
      List.iter
        (fun phrase ->
          if contains_text (String.lowercase_ascii text) phrase then
            failwith
              (Printf.sprintf
                 "%s: column %S of the row about %S answers with %S; the matrix names a consumer \
                  or a verification, never a shrug"
                 name header_name (List.hd row) phrase))
        forbidden_phrases;
      if is_placeholder text then (
        if not (List.mem header_name table.placeholder_columns) then
          failwith
            (Printf.sprintf "%s: column %S of the row about %S holds the placeholder %S" name
               header_name (List.hd row) text);
        let state = cell header table.state_column row in
        if state <> "not-ported" then
          failwith
            (Printf.sprintf
               "%s: the row about %S claims %s = %S yet %S is %S — only a not-ported row may leave \
                a consumer out"
               name (List.hd row) table.state_column state header_name text)))
    (List.mapi (fun at value -> (at, value)) row);
  (* the state vocabulary *)
  let state = cell header table.state_column row in
  if not (List.mem state table.state_allowed) then
    failwith
      (Printf.sprintf "%s: %S = %S, outside this table's vocabulary (%s)" name table.state_column
         state
         (String.concat ", " table.state_allowed));
  (* the verification vocabulary *)
  let entries =
    String.split_on_char ';' (cell header "verification" row)
    |> List.map String.trim
    |> List.filter (fun entry -> entry <> "")
  in
  if entries = [] then
    failwith (Printf.sprintf "%s: the row about %S names no verification" name (List.hd row));
  List.iter
    (fun entry ->
      let kind =
        match String.index_opt entry '(' with
        | Some at -> String.sub entry 0 at
        | None -> String.trim entry
      in
      let kind = String.trim kind in
      if not (List.mem kind verification_kinds || starts "pending" kind) then
        failwith
          (Printf.sprintf
             "%s: the row about %S verifies with %S, and that kind is not in the plan's vocabulary \
              (%s, or pending-F*)"
             name (List.hd row) kind
             (String.concat ", " verification_kinds)))
    entries;
  let names_a_verification =
    List.exists
      (fun entry ->
        match String.index_opt entry '(' with
        | Some at -> List.mem (String.trim (String.sub entry 0 at)) verification_kinds
        | None -> List.mem (String.trim entry) verification_kinds)
      entries
  in
  if state <> "not-ported" && not names_a_verification then
    failwith
      (Printf.sprintf
         "%s: the row about %S is %S but rests only on %S — a row that exists on both sides names \
          the verification that proved it"
         name (List.hd row) state (cell header "verification" row));
  if
    state = "not-ported"
    && not
         (List.exists
            (fun entry ->
              starts "pending"
                (match String.index_opt entry '(' with
                | Some at -> String.sub entry 0 at
                | None -> entry))
            entries)
  then
    failwith
      (Printf.sprintf
         "%s: the row about %S is not-ported, so it must say which wave will verify it (pending-F*)"
         name (List.hd row));
  (* a row that claims its port side honours a key may not name a future wave as
     its consumer: that is the [transitional] state's job *)
  if state = "honoured" || state = "ported" then
    List.iter
      (fun (column, text) ->
        let header_name = List.nth header column in
        if starts "port" header_name then
          if contains_text (String.lowercase_ascii text) "pending" then
            failwith
              (Printf.sprintf "%s: %S = %S yet %S points at pending work: %S" name
                 table.state_column state header_name text)
          else if names_wave text then
            failwith
              (Printf.sprintf "%s: %S = %S yet %S points at a later wave: %S" name
                 table.state_column state header_name text))
      (List.mapi (fun at value -> (at, value)) row)

let tables =
  [
    {
      file = "matrix/providers.tsv";
      header =
        [
          "provider";
          "baseline";
          "port_adapter";
          "port_state";
          "kind";
          "endpoint";
          "auth";
          "cost_per_1k_default";
          "timeout";
          "constraints";
          "result_field";
          "quota_class";
          "live_status";
          "verification";
        ];
      state_column = "port_state";
      state_allowed = [ "ported"; "not-ported" ];
      placeholder_columns = [ "port_adapter"; "cost_per_1k_default" ];
    };
    {
      file = "matrix/config-fields.tsv";
      header = [ "path"; "port_consumer"; "status"; "verification" ];
      state_column = "status";
      state_allowed = [ "honoured"; "transitional"; "refused"; "declined" ];
      placeholder_columns = [];
    };
    {
      file = "matrix/behaviours.tsv";
      header = [ "behaviour"; "baseline"; "port"; "port_suite"; "status"; "verification" ];
      state_column = "status";
      state_allowed = [ "ported"; "partial"; "not-ported" ];
      placeholder_columns = [ "port"; "port_suite" ];
    };
    {
      file = "matrix/surface.tsv";
      header = [ "item"; "kind"; "port"; "status"; "verification" ];
      state_column = "status";
      state_allowed = [ "honoured"; "partial"; "not-ported"; "transitional"; "declined" ];
      placeholder_columns = [ "port" ];
    };
  ]

(* Columns whose values are a closed set beyond the state column: a provider row
   that invents a quota class or a live status is a row nobody can act on. *)
let closed_columns =
  [
    ( "providers.tsv",
      [
        ("timeout", [ "policy.provider_timeout_seconds" ]);
        ("result_field", [ "snippet"; "text"; "snippet-or-answer" ]);
        ( "quota_class",
          [
            "keyless";
            "keyless-free";
            "keyed-billed";
            "keyed-free-tier";
            "keyed-free-tier-then-metered";
            "keyed-free";
            "keyed-billed-free-first";
            "self-hosted-free";
          ] );
        ( "live_status",
          [
            "keyless-live";
            "keyed-live";
            "keyed-live-free";
            "keyed-live-fixture";
            "local-live-fixture";
            "untested-in-repo";
          ] );
      ] );
  ]

let check_closed table header row =
  let name = Filename.basename table.file in
  match List.assoc_opt name closed_columns with
  | None -> ()
  | Some columns ->
      List.iter
        (fun (column, allowed) ->
          let value = cell header column row in
          if not (List.mem value allowed) then
            failwith
              (Printf.sprintf "%s: %S = %S, outside its closed vocabulary (%s)" name column value
                 (String.concat ", " allowed)))
        columns

let rows_of table =
  let lines = read_lines table.file in
  if lines = [] then failwith (Printf.sprintf "%s is empty" table.file);
  let header = String.split_on_char '\t' (List.hd lines) in
  if header <> table.header then
    failwith
      (Printf.sprintf "%s: the header changed.\n  expected: %s\n  found:    %s" table.file
         (String.concat " | " table.header)
         (String.concat " | " header));
  List.map (String.split_on_char '\t') (List.tl lines)

let check_table table () =
  let rows = rows_of table in
  if rows = [] then failwith (Printf.sprintf "%s has a header and no rows" table.file);
  let seen = ref [] in
  List.iter
    (fun row ->
      check_row table table.header row;
      check_closed table table.header row;
      check_pointers table.file table.header row;
      let key = List.hd row in
      if List.mem key !seen then failwith (Printf.sprintf "%s: two rows describe %S" table.file key);
      seen := key :: !seen)
    rows

(* The provider table is the inventory of the ported provider surface, so it has
   to be exactly the set the port's own validator accepts. A name added to
   [Config.known_providers] without a row, or a row naming a retired spelling,
   fails here. *)
let check_provider_names () =
  let table = List.hd tables in
  let rows = rows_of table in
  let found = List.map (fun row -> cell table.header "provider" row) rows in
  let expected = List.sort String.compare Config.known_providers in
  let found_sorted = List.sort String.compare found in
  if found_sorted <> expected then
    failwith
      (Printf.sprintf
         "providers.tsv does not name the provider set of Config.known_providers.\n\
         \  only in the matrix: %s\n\
         \  only in the config: %s"
         (String.concat ", " (List.filter (fun name -> not (List.mem name expected)) found))
         (String.concat ", " (List.filter (fun name -> not (List.mem name found)) expected)))

(* The behaviour rows that claim corpus coverage must be exactly the areas the
   golden runner pins: a corpus area nobody wrote a row for, or a row pointing at
   an area the harness does not carry, is a manifest that has drifted from the
   suite. *)
let check_corpus_areas () =
  let behaviours = List.nth tables 2 in
  let rows = rows_of behaviours in
  let claimed =
    List.concat_map
      (fun row ->
        List.filter_map
          (fun word ->
            if starts "corpus/" word then Some (String.sub word 7 (String.length word - 7))
            else None)
          (words_of (cell behaviours.header "port_suite" row)
          @ words_of (cell behaviours.header "port" row)))
      rows
  in
  let pinned =
    Array.to_list (Sys.readdir "corpus")
    |> List.filter (fun entry -> Sys.file_exists (Filename.concat "corpus" entry))
    |> List.map (fun entry -> Filename.remove_extension entry)
  in
  let areas = List.sort String.compare pinned in
  let claimed_areas = List.sort String.compare (List.sort_uniq String.compare claimed) in
  if claimed_areas <> areas then
    failwith
      (Printf.sprintf
         "the behaviour rows and the corpus disagree about coverage.\n\
         \  areas with a corpus but no row: %s\n\
         \  areas with a row but no corpus: %s"
         (String.concat ", " (List.filter (fun area -> not (List.mem area claimed_areas)) areas))
         (String.concat ", " (List.filter (fun area -> not (List.mem area areas)) claimed_areas)))

(* The registered-divergence record.

   [divergences.tsv] holds the reason beside every accepted behavioural
   divergence, one row per [DIVERGENCES] entry the golden generator once
   carried. The generator cannot run here — the implementation its projections
   imported is gone — so the reasons are committed data the suite reads. Both
   directions are checked, because either half can drift alone:

   - a row that names no golden, or names one that does not verify as
     [explicit-divergence], or whose reason differs from the golden's [reason]
     header, fails: the record and the pinned evidence are one statement;
   - an [explicit-divergence] golden with no row fails unless a systematic rule
     explains it. Those rules stamp one reason across a whole family of
     goldens, so a family member shares its reason text instead of carrying a
     row; the wording rule and the extractor-default rule are the two families
     the suite accepts, and a one-off reason is nobody's rule. *)
let divergences_file = "divergences.tsv"

let divergences_header = [ "area"; "case"; "reason" ]

(* A golden header is the [key: value] lines above the first [---] section. *)
let golden_header path =
  let rec go acc = function
    | [] -> List.rev acc
    | line :: more -> if starts "--- " line then List.rev acc else go (line :: acc) more
  in
  go [] (read_lines path)

let golden_field header name =
  let prefix = name ^ ": " in
  let rec go = function
    | [] -> None
    | line :: more ->
        if starts prefix line then
          Some (String.sub line (String.length prefix) (String.length line - String.length prefix))
        else go more
  in
  go header

let goldens () =
  Array.to_list (Sys.readdir "golden")
  |> List.filter (fun area -> Sys.is_directory (Filename.concat "golden" area))
  |> List.concat_map (fun area ->
      Array.to_list (Sys.readdir (Filename.concat "golden" area))
      |> List.filter (fun entry -> Filename.check_suffix entry ".golden")
      |> List.map (fun entry ->
          let path = Filename.concat (Filename.concat "golden" area) entry in
          (area, Filename.remove_extension entry, path)))

let read_divergences () =
  if not (Sys.file_exists divergences_file) then
    failwith
      (Printf.sprintf
         "test/differential/%s is the committed record of accepted divergences; a missing file is \
          a deleted record"
         divergences_file);
  match read_lines divergences_file with
  | [] -> failwith (Printf.sprintf "%s is empty" divergences_file)
  | first :: lines ->
      let header = String.split_on_char '\t' first in
      if header <> divergences_header then
        failwith
          (Printf.sprintf "%s: the header changed.\n  expected: %s\n  found:    %s" divergences_file
             (String.concat " | " divergences_header)
             (String.concat " | " header));
      List.map
        (fun line ->
          let row = String.split_on_char '\t' line in
          if List.length row <> List.length header then
            failwith
              (Printf.sprintf "%s: a row has %d columns, the header has %d: %S" divergences_file
                 (List.length row) (List.length header) line);
          if List.exists (fun value -> String.trim value = "") row then
            failwith
              (Printf.sprintf "%s: a cell is blank in the row about %S" divergences_file
                 (List.hd row));
          row)
        lines

let check_divergences () =
  let rows = read_divergences () in
  if rows = [] then failwith (Printf.sprintf "%s has a header and no rows" divergences_file);
  let area_of row = List.nth row 0 in
  let case_of row = List.nth row 1 in
  let reason_of row = List.nth row 2 in
  let keys = List.map (fun row -> (area_of row, case_of row)) rows in
  let unique = List.sort_uniq compare keys in
  let duplicated =
    List.filter (fun key -> List.length (List.filter (fun other -> other = key) keys) > 1) unique
  in
  if duplicated <> [] then
    failwith
      (Printf.sprintf "%s: two rows describe the same divergence: %s" divergences_file
         (String.concat ", " (List.map (fun (area, case) -> area ^ "/" ^ case) duplicated)));
  if keys <> unique then
    failwith
      (Printf.sprintf
         "%s: the rows are not sorted by area then case, so a moved reason is not a visible diff"
         divergences_file);
  (* every row is a golden, and the golden repeats the reason *)
  List.iter
    (fun row ->
      let area = area_of row and case = case_of row and reason = reason_of row in
      let path = Filename.concat (Filename.concat "golden" area) (case ^ ".golden") in
      if not (Sys.file_exists path) then
        failwith
          (Printf.sprintf
             "%s: %s/%s is registered with a reason, but %s does not exist — a row about a golden \
              the tree does not carry outlived its evidence"
             divergences_file area case path);
      let header = golden_header path in
      (match golden_field header "verification" with
      | Some "explicit-divergence" -> ()
      | Some other ->
          failwith
            (Printf.sprintf "%s: %s/%s is registered as a divergence yet its golden verifies as %S"
               divergences_file area case other)
      | None ->
          failwith
            (Printf.sprintf "%s: %s/%s has no [verification] header" divergences_file area case));
      match golden_field header "reason" with
      | Some pinned when pinned = reason -> ()
      | Some pinned ->
          failwith
            (Printf.sprintf
               "%s: %s/%s — the record and the golden disagree about the reason.\n\
               \  record: %s\n\
               \  golden: %s"
               divergences_file area case reason pinned)
      | None ->
          failwith
            (Printf.sprintf "%s: %s/%s carries a reason in the record but none in the golden"
               divergences_file area case))
    rows;
  (* every [explicit-divergence] golden is a row or a systematic family member *)
  let explicit =
    List.filter_map
      (fun (area, case, path) ->
        let header = golden_header path in
        match golden_field header "verification" with
        | Some "explicit-divergence" -> (
            match golden_field header "reason" with
            | Some reason -> Some (area, case, reason)
            | None ->
                failwith
                  (Printf.sprintf
                     "golden/%s/%s.golden is an explicit divergence with no [reason] header" area
                     case))
        | _ -> None)
      (goldens ())
  in
  let unregistered =
    List.filter (fun (area, case, _) -> not (List.mem (area, case) keys)) explicit
  in
  let name (area, case) = area ^ "/" ^ case in
  let families =
    List.fold_left
      (fun acc (area, case, reason) ->
        match List.assoc_opt reason acc with
        | Some members -> (reason, name (area, case) :: members) :: List.remove_assoc reason acc
        | None -> (reason, [ name (area, case) ]) :: acc)
      [] unregistered
  in
  let members_of (_, members) = String.concat ", " (List.sort String.compare members) in
  let singletons = List.filter (fun (_, members) -> List.length members < 2) families in
  if singletons <> [] then
    failwith
      (Printf.sprintf
         "%s: these explicit-divergence goldens name no row and share their reason with no other \
          golden, so no systematic rule explains them: %s"
         divergences_file
         (String.concat "; " (List.map members_of singletons)));
  if List.length families > 2 then
    failwith
      (Printf.sprintf
         "%s and the goldens accept %d reason families with no row each; the wording rule and the \
          extractor-default rule are the two systematic classifications, and anything beyond them \
          is a registered divergence: %s"
         divergences_file (List.length families)
         (String.concat "; " (List.map members_of families)))

let () =
  let groups =
    List.map
      (fun table ->
        (Filename.basename table.file, [ (Filename.basename table.file, `Quick, check_table table) ]))
      tables
  in
  Alcotest.run "differential-matrix"
    (groups
    @ [
        ( "cross-checks",
          [
            ("the provider rows are Config.known_providers", `Quick, check_provider_names);
            ("the behaviour rows are the corpus areas", `Quick, check_corpus_areas);
          ] );
        ( "divergences",
          [ ("the record and the goldens name the same divergences", `Quick, check_divergences) ] );
      ])
