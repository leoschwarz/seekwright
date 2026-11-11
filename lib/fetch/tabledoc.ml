(** Record tables on the fetch path: what counts as one, and how one is
    rendered.

    Port of [src/seekwright/tabledoc.py]. A CSV body is the other half of the
    problem [Jsondoc] solved for JSON: the bytes are content, but read as text
    they are a wall of commas that passage selection cannot search and [path]
    cannot address. A table is therefore rendered into [Jsondoc]'s line grammar
    — one line per node, each labelled with the path that addresses it — so
    [fetch]'s [path], [structure] and [offset] need no new machinery and a
    column of every row is one [[*]] step: [$.rows[*].price].

    The row source is the only part that knows about commas: {!emit} takes
    columns and rows, not a body. The next record format feeds the same emitter
    and changes nothing in the engine, the path grammar or the cache.

    The CSV reader here is hand-rolled to Python's [csv] excel dialect, because
    the field cap (131072 characters) and the stop-marker contract ride on its
    exact behaviour: ["\r"] inside an unquoted field is a hard error, an
    unterminated quote takes the rest of the input as its field, and a field
    longer than the cap stops the reader where it stands, leaving the rows
    above it complete. Every length is a codepoint count — Python's [len] —
    though the reader itself walks bytes, since every character the dialect
    acts on is ASCII and UTF-8 continuation bytes are none of them. *)

let table_types = [ "text/csv"; "application/csv"; "text/tab-separated-values" ]
(** The types that name a delimited table by themselves.

    [application/vnd.ms-excel] is deliberately absent: it names a binary
    workbook as often as a CSV export, and a backend must not claim a type it
    reads by guessing. [text/csv] with a [charset] parameter reaches here
    anyway — the extractor's media-type normalisation strips parameters. *)

let tab_types = [ "text/tab-separated-values" ]
(** The types whose own name states the delimiter, so nothing is sniffed. *)

let max_column_name_chars = 128
(** A column name longer than this is cut.

    The name becomes the path label of every cell under it, so one hostile
    header cell of a megabyte makes every row's label longer than the row. The
    cap also keeps a printed path inside [fetch]'s 400-character [path] bound,
    so every column a caller can read off the page is one it can also ask for. *)

let head_chars = 8192
(** The head of the file the delimiter sniff parses. *)

let head_lines = 20
(** The lines of that head, because the file is a stranger's and the sniff
    costs four parses of the sample. *)

let sniff_order = [ ","; ";"; "\t"; "|" ]
(** The order candidates are tried in, and the order ties break in. *)

let field_limit = 131072
(** [csv.field_size_limit]'s process default, pinned here because the stop
    message names it and the value is what a record stream stops on. Never
    raised by config: the Python original keeps it process-global state, and
    this port keeps the same constant. *)

let field_limit_message = Printf.sprintf "field larger than field limit (%d)" field_limit

let cr_message =
  "new-line character seen in unquoted field - do you need to open the file \
   with newline=''?"
(** The reader's hard error on a bare [\r] inside an unquoted field, verbatim
    from [csv]: a [\r] that is not followed by [\n] and is not at end of input
    ends the record where it stands, and the reader refuses the rest. *)

let is_table_media kind = List.mem kind table_types
(** Whether a media type names a table.

    Never consulted on an absent header: unlike JSON's braces, a delimited line
    is indistinguishable from prose, so a body with no Content-Type is text.
    [Jsondoc.sniffs_json] refuses [1,2,3] for the same reason and that guard
    stays green. *)

(* The first [n] codepoints of [s], Python's [s[:n]]. *)

let take_chars s n =
  let cps = Utf8.of_string s in
  let len = Array.length cps in
  if len <= n then s else Utf8.to_string (Array.sub cps 0 n)

let rec take n = function [] -> [] | x :: rest -> if n <= 0 then [] else x :: take (n - 1) rest

(* One record of the reader: parsed cells, or the reason parsing stopped. *)

type row = Cells of string list | Stopped of string

(* Python's [csv.reader] over the excel dialect: the delimiter one character,
   doublequote on, the quote character the ASCII double-quote, no escape
   character, not strict. Reads the text linearly in bytes — every character
   the dialect acts on is ASCII — while the field cap counts codepoints, as
   [len] does. A record ends at LF, at CRLF, or at a CR at end of input; a CR
   followed by anything else is the hard error above. An unterminated quote
   takes the rest of the input as its field — no error — and an empty line is
   a record of no cells, which the emitters skip. Parsing stops at the first
   error, keeping every record before it. *)

let read_records text delim =
  let n = String.length text in
  let records = ref [] in
  let fields = ref [] in
  let buf = Buffer.create 16 in
  let cps = ref 0 in
  let error = ref None in
  let save_field () =
    fields := Buffer.contents buf :: !fields;
    Buffer.clear buf;
    cps := 0
  in
  let save_record () =
    records := List.rev !fields :: !records;
    fields := []
  in
  let finish () = (List.map (fun r -> Cells r) (List.rev !records), !error) in
  let add_byte b =
    if !cps >= field_limit then error := Some field_limit_message
    else begin
      Buffer.add_char buf b;
      (* A byte below 0x80 or at or above 0xC0 starts a codepoint; a
         continuation byte is part of the one before it. *)

      if Char.code b land 0xc0 <> 0x80 then incr cps
    end
  in
  let rec go state i =
    match !error with
    | Some _ -> finish ()
    | None -> (
        if i >= n then begin
          let () =
            match state with
            | `Start_record -> ()
            | _ ->
                (* End of input with a record under way: the field is
                   complete, quote closed or not. *)

                save_field ();
                save_record ()
          in
          finish ()
        end
        else
          let c = text.[i] in
          match state with
          | `Start_record -> (
              if c = '\n' then (records := [] :: !records; go `Start_record (i + 1))
              else if c = '\r' then
                if i + 1 < n && text.[i + 1] = '\n' then
                  (records := [] :: !records; go `Start_record (i + 2))
                else if i + 1 >= n then
                  (records := [] :: !records; go `Start_record (i + 1))
                else begin
                  error := Some cr_message;
                  finish ()
                end
              else if c = '"' then go `Quoted (i + 1)
              else begin
                add_byte c;
                if !error = None then go `In_field (i + 1) else finish ()
              end)
          | `Start_field | `In_field -> (
              let in_field = state = `In_field in
              if c = '\r' then
                if i + 1 < n && text.[i + 1] = '\n' then begin
                  if in_field then save_field ();
                  save_record ();
                  go `Start_record (i + 2)
                end
                else if i + 1 >= n then begin
                  if in_field then save_field ();
                  save_record ();
                  go `Start_record (i + 1)
                end
                else begin
                  error := Some cr_message;
                  finish ()
                end
              else if c = '\n' then begin
                if in_field then save_field ();
                save_record ();
                go `Start_record (i + 1)
              end
              else if c = delim then begin
                save_field ();
                go `Start_field (i + 1)
              end
              else if not in_field && c = '"' then go `Quoted (i + 1)
              else begin
                add_byte c;
                if !error = None then go `In_field (i + 1) else finish ()
              end)
          | `Quoted -> (
              if c = '"' then go `Quote_in_quoted (i + 1)
              else begin
                add_byte c;
                if !error = None then go `Quoted (i + 1) else finish ()
              end)
          | `Quote_in_quoted ->
              if c = '"' then begin
                add_byte '"';
                if !error = None then go `Quoted (i + 1) else finish ()
              end
              else if c = delim then begin
                save_field ();
                go `Start_field (i + 1)
              end
              else if c = '\n' then begin
                save_field ();
                save_record ();
                go `Start_record (i + 1)
              end
              else if c = '\r' then
                if i + 1 < n && text.[i + 1] = '\n' then begin
                  save_field ();
                  save_record ();
                  go `Start_record (i + 2)
                end
                else if i + 1 >= n then begin
                  save_field ();
                  save_record ();
                  go `Start_record (i + 1)
                end
                else begin
                  error := Some cr_message;
                  finish ()
                end
              else begin
                (* Characters after a closing quote ride along as field
                   content: ["a"b] is [ab]. *)

                add_byte c;
                if !error = None then go `In_field (i + 1) else finish ()
              end)
  in
  go `Start_record 0

let choose_delimiter text =
  (* Pick a comma-family delimiter by parsing the head four ways.

     A European export served as [text/csv] really is semicolon-separated, and
     reading it on commas answers one column named after the whole line: a
     wrong answer, not a refusal. Counting characters would be fooled by a
     comma inside a quoted value, so each candidate is parsed under the CSV
     grammar and the one every row agrees on wins — the *narrowest* row it
     produces, not the widest, because a cell merely containing a semicolon
     splits under [;] and would otherwise outbid the real delimiter: an address
     column of ["1 Main St; London; UK"] in a comma file reads as one column
     and loses the city. Ties go to the order in {!sniff_order}, so a file that
     agrees on nothing stays on commas. Not [csv.Sniffer]: its dialect search
     takes a sample of the caller's choosing and is bounded by nothing this
     tree controls. *)

  let sample =
    Utf8.of_string (take_chars text head_chars)
    |> Utf8.splitlines
    |> take head_lines
    |> List.map Utf8.to_string
    |> String.concat "\n"
  in
  let best = ref (",", 1) in
  List.iter
    (fun delimiter ->
      let records, stop = read_records sample delimiter.[0] in
      let width =
        if stop <> None then 1
        else
          match records with
          | [] -> 1
          | _ :: _ ->
              List.fold_left
                (fun acc r ->
                  match r with Cells cells -> min acc (List.length cells) | Stopped _ -> acc)
                max_int records
      in
      if width > snd !best then best := (delimiter, width))
    sniff_order;
  fst !best

let table_delimiter kind text =
  (* The delimiter this type declares, or the one this file's head supports. *)

  if List.mem kind tab_types then "\t" else choose_delimiter text

let column_names header =
  (* The header row as column names: faithful, capped, never empty.

     Names are not trimmed or case-folded: a header cell of [" id"] is a column
     called [" id"], and {!Jsondoc.child_path} writes the quoted spelling that
     round-trips it. Duplicate names are left alone — [path] then answers both,
     which reports the file's defect rather than renaming its data. An empty
     cell gets the positional name, so no path label is blank. *)

  List.mapi
    (fun ordinal raw ->
      match take_chars raw max_column_name_chars with
      | "" -> Printf.sprintf "column%d" (ordinal + 1)
      | name -> name)
    header

exception No_rows
(** The reader stopped before any row printed: all that is known of the file
    is its columns, and the bytes serve the caller better than an empty table
    that claims to be one. *)

(* The format-agnostic half. *)

let emit columns rows body_chars =
  let width = List.length columns in
  let budget = max Jsondoc.min_render_chars (Jsondoc.max_render_ratio * body_chars) in
  let out = ref [] in
  let spent = ref 0 in
  let printed = ref 0 in
  let stop = ref None in
  let rec go = function
    | [] -> ()
    | row :: rest -> (
        match row with
        | Stopped reason ->
            if !printed = 0 then raise No_rows
            else
              stop :=
                Some
                  (Printf.sprintf
                     "not rendered: this file stopped parsing at this row (%s); the \
                      rows above it are complete"
                     reason)
        | Cells [] -> go rest
        | Cells r ->
            if !spent > budget then
              stop :=
                Some
                  (Printf.sprintf
                     "not rendered: the table expands past the budget of %d \
                      characters, %d times the file's own %d; %d rows are printed \
                      above and no further row of the file is addressable in this \
                      page -- fetch with `offset` to page through what is here, or \
                      raise fetch.max_download_bytes, the budget being a ratio of it"
                     budget Jsondoc.max_render_ratio body_chars !printed)
            else begin
              let path = Printf.sprintf "$.rows[%d]" !printed in
              let line = Printf.sprintf "%s  object(%d)" path width in
              out := line :: !out;
              spent := !spent + Utf8.count line + 1;
              (* Rows shorter than the header are padded with empty cells and
                 rows longer than it are cut to it, so every row object has
                 exactly the header's width — which is what lets the shape view
                 collapse the whole array to one [$.rows[*]] subtree. *)

              let pad = max 0 (width - List.length r) in
              let cells = take width r @ List.init pad (fun _ -> "") in
              List.iter2
                (fun name value ->
                  (* Cells stay quoted strings whatever they hold: a CSV has no
                     types, and [007] or [1.50] unquoted would be a different
                     value than the file wrote. *)

                  let leaf =
                    Printf.sprintf "%s  %s"
                      (Jsondoc.child_path path (Jsondoc.Name name))
                      (Jsondoc.json_string value)
                  in
                  out := leaf :: !out;
                  spent := !spent + Utf8.count leaf + 1)
                columns cells;
              printed := !printed + 1;
              go rest
            end)
  in
  try
    go rows;
    let lines =
      [ "$  object(1)"; Printf.sprintf "$.rows  array(%d)" !printed ]
      @ List.rev !out
    in
    let lines =
      match !stop with
      | None -> lines
      | Some reason -> lines @ [ Printf.sprintf "$.rows[%d]  %s" !printed reason ]
    in
    Some (String.concat "\n" lines)
  with No_rows -> None

let render_table text ~delimiter =
  (* A delimited body as one line per row and cell, or [None] when it is not
     one. The first non-blank row names the columns; every row after it becomes
     [$.rows[N]  object(C)] and one line per column under it. [None] is the
     caller's signal to answer with the bytes: a header the reader cannot walk,
     and a reader that stopped before any row printed — columns without one row
     say nothing about the file. *)

  let body =
    (* A leading byte-order mark is transport, not a column name. *)

    if String.length text >= 3 && String.sub text 0 3 = "\xef\xbb\xbf" then
      String.sub text 3 (String.length text - 3)
    else text
  in
  let records, stop = read_records body delimiter.[0] in
  let rec split_header = function
    | [] -> None
    | Cells [] :: rest -> split_header rest
    | Cells h :: rest -> Some (h, rest)
    | Stopped _ :: _ -> None
  in
  match split_header records with
  | None -> None
  | Some (h, tail) ->
      let rows =
        List.filter (function Cells [] -> false | _ -> true) tail
        @ (match stop with Some reason -> [ Stopped reason ] | None -> [])
      in
      emit (column_names h) rows (Utf8.count text)
