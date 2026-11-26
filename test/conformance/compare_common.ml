exception Bad of string

let failing_statuses = [ "FAILURE"; "WARNING" ]
let check_statuses = [ "SUCCESS"; "FAILURE"; "WARNING"; "SKIPPED"; "INFO" ]

type check = { id : string; status : string; error_message : string option; json : Yojson.Safe.t }

type run = { checks : check list; failed : string list; result : string }

type errors = { mutable lines : string list }

let errors () = { lines = [] }
let add e line = e.lines <- e.lines @ [ line ]
let any e = e.lines <> []

(* The unreadable-file sentence the retired script wrote came from OSError, and
   the error lists a reader compares across runs quote it verbatim — including
   the [errno]. [Unix] carries the kind, not the number, and this compiler's
   [Unix] has no [errno_of_error], so the codes a missing or unreadable path
   actually produces are named here. *)
let errno_of_error (kind : Unix.error) =
  match kind with
  | Unix.EPERM -> 1
  | Unix.ENOENT -> 2
  | Unix.EIO -> 5
  | Unix.EBADF -> 9
  | Unix.ENOMEM -> 12
  | Unix.EACCES -> 13
  | Unix.EBUSY -> 16
  | Unix.EEXIST -> 17
  | Unix.EXDEV -> 18
  | Unix.ENOTDIR -> 20
  | Unix.EISDIR -> 21
  | Unix.EINVAL -> 22
  | Unix.EMFILE -> 24
  | Unix.ENOSPC -> 28
  | Unix.EROFS -> 30
  | Unix.ENAMETOOLONG -> 36
  | Unix.ENOTEMPTY -> 39
  | Unix.ELOOP -> 62
  | _ -> 0

let io_message path (kind : Unix.error) =
  Printf.sprintf "[Errno %d] %s: '%s'" (errno_of_error kind) (Unix.error_message kind) path

let read_file path =
  let rec open_and_read attempt =
    match Unix.openfile path [ Unix.O_RDONLY ] 0 with
    | exception Unix.Unix_error (Unix.EINTR, _, _) when attempt < 3 -> open_and_read (attempt + 1)
    | exception Unix.Unix_error (err, _, _) -> Error (io_message path err)
    | fd -> (
        let read_all () =
          let buffer = Buffer.create 4096 in
          let chunk = Bytes.create 65536 in
          let rec go () =
            match Unix.read fd chunk 0 (Bytes.length chunk) with
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> go ()
            | 0 -> ()
            | n ->
                Buffer.add_subbytes buffer chunk 0 n;
                go ()
          in
          go ();
          Buffer.contents buffer
        in
        match Fun.protect ~finally:(fun () -> Unix.close fd) read_all with
        | exception Unix.Unix_error (err, _, _) -> Error (io_message path err)
        | text -> Ok text)
  in
  open_and_read 0

let read_stripped path =
  match read_file path with Ok text -> Ok (String.trim text) | Error _ as refused -> refused

(* Python's [str.splitlines], which the manifest and metadata counts were built
   with: an empty file is zero lines, one trailing line ending is not a line, and
   a CR before an LF belongs to the line ending. [String.split_on_char] invents
   both, and an invented line flips [working_tree_clean]. *)
let split_lines text =
  if text = "" then []
  else
    let text =
      if String.ends_with ~suffix:"\n" text then String.sub text 0 (String.length text - 1)
      else text
    in
    List.map
      (fun line ->
        if String.ends_with ~suffix:"\r" line then String.sub line 0 (String.length line - 1)
        else line)
      (String.split_on_char '\n' text)

let contains_text haystack needle =
  let hn = String.length haystack in
  let nn = String.length needle in
  let rec go i =
    if i + nn > hn then false else if String.sub haystack i nn = needle then true else go (i + 1)
  in
  go 0

let array_index predicate lines =
  let n = Array.length lines in
  let rec go i = if i >= n then None else if predicate lines.(i) then Some i else go (i + 1) in
  go 0

let ids ?(allow_empty = false) path =
  let text = match read_file path with Ok text -> text | Error message -> raise (Bad message) in
  (* The comment test runs against the raw line, so an indented hash line is an
     ID here, not a comment. A stricter reading would drop a manifest entry. *)
  let values =
    List.filter_map
      (fun line ->
        let stripped = String.trim line in
        if stripped = "" || String.starts_with ~prefix:"#" line then None else Some stripped)
      (split_lines text)
  in
  if
    List.length (List.sort_uniq String.compare values) <> List.length values
    || (values = [] && not allow_empty)
  then raise (Bad (Printf.sprintf "manifest has duplicate IDs or is empty: %s" path));
  values

let is_space c = c = ' ' || c = '\t'

let only_spaces s =
  let rec go i =
    i = String.length s || ((s.[i] = ' ' || s.[i] = '\t' || s.[i] = '\r') && go (i + 1))
  in
  go 0

(* The runner pads a bullet to its own column, so a marker match ignores the
   trailing run of spaces the way the retired regex's [\s*$] did. *)
let trim_tail s =
  let rec go len =
    if len > 0 && (s.[len - 1] = ' ' || s.[len - 1] = '\t' || s.[len - 1] = '\r') then go (len - 1)
    else len
  in
  String.sub s 0 (go (String.length s))

(* One bullet out of a runner list section: leading whitespace (at least one), a
   dash, a space, one token, then the marker this caller expects. [rest] is what
   followed the token, spaces included, so the [ [server] ] marker keeps its
   single required space. *)
let entry line =
  let n = String.length line in
  let rec skip_ws i = if i < n && is_space line.[i] then skip_ws (i + 1) else i in
  let dash = skip_ws 0 in
  if dash = 0 || dash + 2 > n || line.[dash] <> '-' || line.[dash + 1] <> ' ' then None
  else
    let start = dash + 2 in
    let rec token_end i = if i < n && not (is_space line.[i]) then token_end (i + 1) else i in
    let stop = token_end start in
    if stop = start || start > n then None
    else Some (String.sub line start (stop - start), String.sub line stop (n - stop))

(* [section_lines] answers three questions at once: is the header there, where
   does the section end, and did it end at a header of its own or at the end of
   the transcript. The third is what makes a truncated transcript a failure
   rather than a short list: a runner that stops printing mid-section would
   otherwise hand the gate a smaller expected set than it ran. *)
let section_lines text header stops =
  let lines = Array.of_list (split_lines text) in
  match array_index (fun line -> contains_text line header) lines with
  | None -> None
  | Some index ->
      let rec collect i acc =
        if i >= Array.length lines then (List.rev acc, false)
        else
          let trimmed = String.trim lines.(i) in
          if List.exists (fun stop -> String.starts_with ~prefix:stop trimmed) stops then
            (List.rev acc, true)
          else collect (i + 1) (lines.(i) :: acc)
      in
      Some (collect (index + 1) [])

let bullets lines =
  List.filter_map
    (fun line ->
      match entry line with Some (id, rest) when only_spaces rest -> Some id | _ -> None)
    lines

let runner_list text =
  (* The two section terminators are what make a runner that renames its own
     list a parse failure rather than an empty expected set, and a section that
     runs to the end of the transcript is the same failure: the runner printed
     fewer scenarios than it has. *)
  match
    section_lines text "Server scenarios (test against a server):"
      [ "Client scenarios"; "Run and reported" ]
  with
  | None -> raise (Bad "cannot parse official runner server list")
  | Some (_, false) -> raise (Bad "cannot parse official runner server list")
  | Some (lines, true) -> bullets lines

let runner_unscored text =
  (* That section is the last one the runner prints, so its end is the end of
     the transcript and the terminator the scored section needs is not asked
     for. *)
  match section_lines text "Run and reported, but never scored:" [] with
  | None -> raise (Bad "cannot parse official runner unscored list")
  | Some (lines, _) ->
      List.filter_map
        (fun line ->
          (* Only the [server] half of that section is ours; the runner prints the
             client scenarios beside it. *)
          match entry line with
          | Some (id, rest) when trim_tail rest = " [server]" -> Some id
          | _ -> None)
        lines

let is_digit c = c >= '0' && c <= '9'

(* [server-<scenario>-<YYYY-MM-DDThh-mm-ss-<n>Z]: the runner dashes its clock the
   way it dashes its date, and the fractional part is a variable number of
   digits, so the shape is checked by position rather than by length. *)
let stamp_shape rest =
  let at i c = rest.[i] = c in
  let dg i = is_digit rest.[i] in
  dg 0 && dg 1 && dg 2 && dg 3 && at 4 '-' && dg 5 && dg 6 && at 7 '-' && dg 8 && dg 9 && at 10 'T'
  && dg 11 && dg 12 && at 13 '-' && dg 14 && dg 15 && at 16 '-' && dg 17 && dg 18

let matches_stamp rest =
  let len = String.length rest in
  (* 19 for the date-time, the dash, at least one fractional digit, and [Z]. *)
  len >= 22 && stamp_shape rest
  && rest.[19] = '-'
  && rest.[len - 1] = 'Z'
  &&
  let rec go i = i = len - 1 || (is_digit rest.[i] && go (i + 1)) in
  go 20

let scenario_of_result_dir name =
  let n = String.length name in
  let prefix = String.length "server-" in
  if not (String.starts_with ~prefix:"server-" name) then None
  else
    (* The scenario name may itself contain a dash, and the stamp is matched
       greedily: the split is therefore the rightmost suffix that is a stamp. *)
    let rec go i =
      if i < prefix + 1 then None
      else if name.[i] <> '-' || not (matches_stamp (String.sub name (i + 1) (n - i - 1))) then
        go (i - 1)
      else Some (String.sub name prefix (i - prefix))
    in
    if n - 23 < prefix + 1 then None else go (n - 23)

let executed_scenarios text =
  let prefix = "=== Running scenario: " in
  let suffix = " ===" in
  List.filter_map
    (fun line ->
      let ln = String.length line in
      let pl = String.length prefix in
      let sl = String.length suffix in
      if ln <= pl + sl then None
      else if not (String.starts_with ~prefix line && String.ends_with ~suffix line) then None
      else
        let token = String.sub line pl (ln - pl - sl) in
        if token = "" || String.exists is_space token then None else Some token)
    (split_lines text)

(* A list of names inside an error sentence, spelled the way the retired script
   spelled it, so a reader comparing two runs of the same failure reads the same
   text twice. *)
let py_quote s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '\'';
  String.iter
    (fun c ->
      if c = '\'' || c = '\\' then Buffer.add_char buffer '\\';
      Buffer.add_char buffer c)
    s;
  Buffer.add_char buffer '\'';
  Buffer.contents buffer

let py_list xs = "[" ^ String.concat ", " (List.map py_quote xs) ^ "]"

let set_diff a b = List.filter (fun x -> not (List.mem x b)) a

let counter xs =
  let table = Hashtbl.create 16 in
  List.iter
    (fun key -> Hashtbl.replace table key (try Hashtbl.find table key + 1 with Not_found -> 1))
    xs;
  table

let counter_get table key = try Hashtbl.find table key with Not_found -> 0
let counter_add table key amount = Hashtbl.replace table key (counter_get table key + amount)

let counter_alist table =
  List.of_seq (Hashtbl.to_seq table) |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let counter_total table = List.fold_left (fun acc (_, n) -> acc + n) 0 (counter_alist table)
let counter_json table = `Assoc (List.map (fun (key, n) -> (key, `Int n)) (counter_alist table))

let exact label actual expected errs =
  let counts = counter actual in
  let set_actual = List.sort_uniq String.compare actual in
  let set_expected = List.sort_uniq String.compare expected in
  let missing = set_diff set_expected set_actual in
  let extra = set_diff set_actual set_expected in
  let duplicates =
    counter_alist counts |> List.filter_map (fun (key, n) -> if n <> 1 then Some key else None)
  in
  if missing <> [] || extra <> [] || duplicates <> [] then
    add errs
      (Printf.sprintf "%s: missing=%s, extra=%s, duplicates=%s" label (py_list missing)
         (py_list extra) (py_list duplicates))

(* The runner reuses one check ID for the same assertion driven through different
   inputs, so this compares occurrences rather than the ID set. *)
let multiset_diff label actual expected errs =
  let actual_counts = counter actual in
  let expected_counts = counter expected in
  let flatten table other sign =
    counter_alist table
    |> List.filter_map (fun (key, n) ->
        let delta = n - counter_get other key in
        if (sign > 0 && delta > 0) || (sign < 0 && delta < 0) then
          Some (List.init (abs delta) (fun _ -> key))
        else None)
    |> List.concat
  in
  let missing = flatten expected_counts actual_counts 1 in
  let extra = flatten actual_counts expected_counts 1 in
  if missing <> [] || extra <> [] then
    add errs
      (Printf.sprintf "%s: missing=%s, extra=%s" label
         (py_list (List.sort String.compare missing))
         (py_list (List.sort String.compare extra)))

let assoc_get json key = match json with `Assoc pairs -> List.assoc_opt key pairs | _ -> None

let get_string json key = match assoc_get json key with Some (`String s) -> Some s | _ -> None

(* [Yojson.Raw] is the one parser here that does not fold duplicate object keys
   into one another, which is what lets a baseline spelling the same scenario
   twice fail instead of being scored by whichever copy survived. *)
let rec of_raw dup_prefix : Yojson.Raw.t -> Yojson.Safe.t = function
  | `Null -> `Null
  | `Bool b -> `Bool b
  | `Intlit s -> ( match int_of_string_opt s with Some i -> `Int i | None -> `Intlit s)
  | `Floatlit s -> ( match float_of_string_opt s with Some f -> `Float f | None -> `String s)
  | `Stringlit s -> (
      match Yojson.Safe.from_string s with
      | `String v -> `String v
      | _ -> raise (Bad "invalid JSON string literal"))
  | `List items -> `List (List.map (of_raw dup_prefix) items)
  | `Assoc pairs ->
      let seen = Hashtbl.create 8 in
      `Assoc
        (List.map
           (fun (key, value) ->
             if Hashtbl.mem seen key then
               raise (Bad (Printf.sprintf "duplicate %s key: %s" dup_prefix key));
             Hashtbl.replace seen key ();
             (key, of_raw dup_prefix value))
           pairs)

(* [Yojson] re-exports [Basic], [Safe] and [Raw] but not the module its parse
   failure lives in, so the exception is named through the wrapped alias. The
   parser's own wording is kept: it names a document that is not JSON at all,
   which no reader compares across runs. *)
let read_json ?(dup_prefix = "document") path =
  let text = match read_file path with Ok text -> text | Error message -> raise (Bad message) in
  match Yojson.Raw.from_string text with
  | raw -> of_raw dup_prefix raw
  | exception Yojson__.Common.Json_error message -> raise (Bad message)
  | exception _ -> raise (Bad "invalid JSON")

let read_checks path =
  let json = read_json ~dup_prefix:"check" path in
  match json with
  | `List [] -> raise (Bad "checks.json is empty or not an array")
  | `List items ->
      let checks =
        List.map
          (fun item ->
            match item with
            | `Assoc _ as object_json -> (
                let status = get_string object_json "status" in
                let id = get_string object_json "id" in
                match (status, id) with
                | Some status, Some id when List.mem status check_statuses && id <> "" ->
                    {
                      id;
                      status;
                      error_message = get_string object_json "errorMessage";
                      json = object_json;
                    }
                | _ -> raise (Bad "unknown check status or invalid check object"))
            | _ -> raise (Bad "unknown check status or invalid check object"))
          items
      in
      let failed =
        List.filter_map
          (fun c -> if List.mem c.status failing_statuses then Some c.id else None)
          checks
      in
      if List.exists (fun (_, n) -> n <> 1) (counter_alist (counter failed)) then
        raise (Bad "duplicate failed check IDs");
      let result =
        if failed <> [] then "fail"
        else if List.exists (fun c -> c.status = "SUCCESS") checks then "pass"
        else "skipped"
      in
      { checks; failed; result }
  | _ -> raise (Bad "checks.json is empty or not an array")

(* Python's [json.dumps] default, which the retired comparator used for one
   thing: rendering an untriaged failure's whole check as its evidence. That
   string lands in the report and in the triage a reader does from it, so the
   escaping is reproduced rather than approximated: ASCII-only output, [", "]
   and [": "] separators, sorted keys. *)
let py_escape buffer s =
  Buffer.add_char buffer '"';
  let add_code code = Printf.bprintf buffer "\\u%04x" code in
  let len = String.length s in
  let decode i =
    let byte i = Char.code s.[i] in
    let b0 = byte i in
    if b0 < 0x80 then Some (b0, 1)
    else if b0 >= 0xC0 && b0 < 0xE0 && i + 1 < len then
      Some (((b0 land 0x1F) lsl 6) lor (byte (i + 1) land 0x3F), 2)
    else if b0 >= 0xE0 && b0 < 0xF0 && i + 2 < len then
      Some
        ( ((b0 land 0x0F) lsl 12) lor ((byte (i + 1) land 0x3F) lsl 6) lor (byte (i + 2) land 0x3F),
          3 )
    else if b0 >= 0xF0 && b0 < 0xF8 && i + 3 < len then
      Some
        ( ((b0 land 0x07) lsl 18)
          lor ((byte (i + 1) land 0x3F) lsl 12)
          lor ((byte (i + 2) land 0x3F) lsl 6)
          lor (byte (i + 3) land 0x3F),
          4 )
    else None
  in
  let rec go i =
    if i >= len then ()
    else
      match s.[i] with
      | '"' ->
          Buffer.add_string buffer "\\\"";
          go (i + 1)
      | '\\' ->
          Buffer.add_string buffer "\\\\";
          go (i + 1)
      | '\b' ->
          Buffer.add_string buffer "\\b";
          go (i + 1)
      | '\012' ->
          Buffer.add_string buffer "\\f";
          go (i + 1)
      | '\n' ->
          Buffer.add_string buffer "\\n";
          go (i + 1)
      | '\r' ->
          Buffer.add_string buffer "\\r";
          go (i + 1)
      | '\t' ->
          Buffer.add_string buffer "\\t";
          go (i + 1)
      | c when Char.code c < 0x20 ->
          add_code (Char.code c);
          go (i + 1)
      | _ -> (
          match decode i with
          | Some (code, width) when code >= 0x80 ->
              if code <= 0xFFFF then add_code code
              else begin
                let pair = code - 0x10000 in
                add_code (0xD800 + (pair lsr 10));
                add_code (0xDC00 + (pair land 0x3FF))
              end;
              go (i + width)
          | _ ->
              Buffer.add_char buffer s.[i];
              go (i + 1))
  in
  go 0;
  Buffer.add_char buffer '"'

let py_float f =
  if Float.is_integer f && Float.abs f < 1e15 then Printf.sprintf "%.1f" f
  else Printf.sprintf "%.17g" f

let rec py_write buffer = function
  | `Null -> Buffer.add_string buffer "null"
  | `Bool b -> Buffer.add_string buffer (if b then "true" else "false")
  | `Int i -> Buffer.add_string buffer (string_of_int i)
  | `Intlit s -> Buffer.add_string buffer s
  | `Float f -> Buffer.add_string buffer (py_float f)
  | `String s -> py_escape buffer s
  | `List items ->
      Buffer.add_char buffer '[';
      List.iteri
        (fun i item ->
          if i > 0 then Buffer.add_string buffer ", ";
          py_write buffer item)
        items;
      Buffer.add_char buffer ']'
  | `Assoc pairs ->
      Buffer.add_char buffer '{';
      pairs
      |> List.sort (fun (a, _) (b, _) -> String.compare a b)
      |> List.iteri (fun i (key, value) ->
          if i > 0 then Buffer.add_string buffer ", ";
          py_escape buffer key;
          Buffer.add_string buffer ": ";
          py_write buffer value);
      Buffer.add_char buffer '}'
  | `Stringlit s -> Buffer.add_string buffer s
  | `Block (_, items) -> py_write buffer (`List items)

let py_compact json =
  let buffer = Buffer.create 128 in
  py_write buffer json;
  Buffer.contents buffer

let observed_evidence check =
  match check.error_message with
  | Some message when message <> "" -> check.status ^ ": " ^ message
  | _ -> py_compact check.json

let member_json items = `List items
let assoc_json pairs = `Assoc pairs

let rec sort_json = function
  | `Assoc pairs ->
      `Assoc
        (List.sort
           (fun (a, _) (b, _) -> String.compare a b)
           (List.map (fun (k, v) -> (k, sort_json v)) pairs))
  | `List items -> `List (List.map sort_json items)
  | json -> json

let rec mkdir_p dir =
  if dir <> "" && dir <> "/" && not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    match Unix.mkdir dir 0o777 with () | (exception Unix.Unix_error (Unix.EEXIST, _, _)) -> ()
  end

let write_report path json =
  mkdir_p (Filename.dirname path);
  let text = Yojson.Safe.pretty_to_string (sort_json json) ^ "\n" in
  match Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 with
  | exception Unix.Unix_error (err, _, _) -> raise (Bad (io_message path err))
  | fd ->
      let rec write_all offset =
        if offset >= String.length text then ()
        else
          match Unix.write_substring fd text offset (String.length text - offset) with
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> write_all offset
          | n -> write_all (offset + n)
      in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> write_all 0)

let relative_path ~base path =
  let bn = String.length base in
  if bn > 0 && String.length path > bn + 1 && String.sub path 0 bn = base && path.[bn] = '/' then
    String.sub path (bn + 1) (String.length path - bn - 1)
  else path

(* Total, as the interface promises: a path that is not there, or that a
   permission problem hides, answers [false] rather than raising. The gates ask
   about result directories that a runner may simply not have written, and a
   raised [Unix.Unix_error] there would end a run before the error list could
   name the missing directory. *)
let dir_exists path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> true
  | _ -> false
  | exception Unix.Unix_error _ -> false

let list_dirs path =
  try
    Ok
      (Array.to_list (Sys.readdir path)
      |> List.filter (fun name -> dir_exists (Filename.concat path name)))
  with _ -> Error ()

let flag_name key = "--" ^ String.map (fun c -> if c = '_' then '-' else c) key
let flag_key flag = String.map (fun c -> if c = '-' then '_' else c) flag

let usage_error program message =
  prerr_endline (program ^ ": error: " ^ message);
  exit 2

let parse_args ~program ~spec () =
  let argv =
    let raw = Sys.argv in
    List.init (Array.length raw - 1) (fun i -> raw.(i + 1))
  in
  let table = Hashtbl.create 16 in
  let known = List.map (fun (key, _) -> key) spec in
  let rec go = function
    | [] -> ()
    | flag :: rest -> (
        if not (String.starts_with ~prefix:"--" flag) then
          usage_error program ("unrecognized arguments: " ^ flag)
        else
          let key = flag_key (String.sub flag 2 (String.length flag - 2)) in
          if not (List.mem key known) then usage_error program ("unrecognized arguments: " ^ flag)
          else
            match rest with
            | value :: rest' ->
                Hashtbl.replace table key value;
                go rest'
            | [] -> usage_error program ("argument " ^ flag ^ ": expected one argument"))
  in
  go argv;
  let missing =
    List.filter_map
      (fun (key, required) ->
        if required && not (Hashtbl.mem table key) then Some (flag_name key) else None)
      spec
  in
  if missing <> [] then
    usage_error program ("the following arguments are required: " ^ String.concat ", " missing);
  table

let opt table key = Hashtbl.find_opt table key
let opt_exn table key = Hashtbl.find table key
