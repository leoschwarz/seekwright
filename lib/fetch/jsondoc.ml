(** JSON documents on the fetch path: what counts as one, how one is rendered,
    and how part of one is addressed.

    Port of [src/seekwright/jsondoc.py]. A JSON page is extracted as one line
    per node, each labelled with the path that addresses it, so the document
    arrives as its own map: [total_chars], [offset] and the [[...]] marker keep
    their meaning, [query] still selects by terms, and [path] selects by
    structure. A line's path is the exact string a caller passes back as
    [path], which is why it is absolute and printed on every line rather than
    implied by indentation, and why {!parse_path} reads the same syntax
    {!render_json} writes.

    Nothing here reaches the network: {!render_json} and {!render_schema} are
    bounded by {!max_render_ratio} against the body they were handed, and both
    cuts print the line naming where they fell.

    Every length here is a codepoint count — Python's [len] — so the work runs
    over {!Utf8}, never [String.length]. *)

module Repr = Seekwright_text.Repr

type key =
  | Name of string
      (** A member addressed by name. *)

  | Ordinal of int
      (** A member addressed by position. *)

type step =
  | Key of string
      (** One member of an object: [.name] or [["a b"]]. *)

  | Position of int
      (** One element of an array: [[3]]. *)

  | Every
      (** Every member at this level, whatever it is called: [[*]]. *)

  | Bounds of int option * int option
      (** A slice of an array: [[a:b]], either bound absent meaning the array's
          own end. *)

exception Path_syntax of string
(** A [path] this grammar cannot express. A distinct exception so the engine
    can answer it as a refusal rather than as a fetch failure: the caller wrote
    something unreadable, and that is known before any request goes out. *)

let json_document_types = [ "application/json"; "text/json" ]
(** The media types that name one JSON document, written out because there are
    only two of them and the difference from a stream is a decision, not a
    detail. *)

let jsonl_types = [ "application/jsonl"; "application/x-ndjson" ]
(** The JSON Lines types: JSON, but a stream of records rather than one
    document. They ride with the JSON family so a backend claims them and hands
    the body back as text instead of refusing the download, and they are held
    out of {!is_json_document_media} because a stream cut mid-record still has
    whole records at its head, where a document cut in the middle has nothing. *)

let max_depth = 100
(** How deep {!render_json} expands a document, counting the root as zero.
    Real documents measured in this work sit under ten; past a hundred the path
    each line carries is longer than the value it labels. *)

let max_render_ratio = 4
(** How much larger than the body {!render_json} is allowed to make it. Every
    line carries its whole path, so the cost of a rendering is a function of
    the document's shape, not of its bytes. *)

let min_render_chars = 8000
(** The floor under that budget, so that no small document is ever cut. *)

let is_json_document_media kind =
  List.mem kind json_document_types
  ||
  let len = String.length kind in
  len >= 5 && String.sub kind (len - 5) 5 = "+json"

let is_json_media kind = is_json_document_media kind || List.mem kind jsonl_types

let sniffs_json body =
  (* Only the two shapes a JSON *document* starts with count. A body beginning
     with a digit or a quote is a bare JSON value, and guessing that from
     unlabelled bytes is how a CSV of numbers becomes a document. The window is
     the first 512 bytes, and whitespace that runs past it answers no, the way
     Python's [body[:512].lstrip()] does. *)

  let limit = min (String.length body) 512 in
  let rec skip i =
    if i >= limit then false
    else
      match body.[i] with
      | ' ' | '\t' | '\n' | '\r' | '\011' | '\012' -> skip (i + 1)
      | '{' | '[' -> true
      | _ -> false
  in
  skip 0

(* Compact JSON for a scalar leaf, the spelling Python's
   [json.dumps(..., ensure_ascii=False, separators=(",", ":"))] writes: control
   characters escaped, everything else — Unicode included — raw, so a rendered
   line stays one line. *)

let json_string s =
  let out = Buffer.create (String.length s + 2) in
  Buffer.add_char out '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string out "\\\""
      | '\\' -> Buffer.add_string out "\\\\"
      | '\b' -> Buffer.add_string out "\\b"
      | '\012' -> Buffer.add_string out "\\f"
      | '\n' -> Buffer.add_string out "\\n"
      | '\r' -> Buffer.add_string out "\\r"
      | '\t' -> Buffer.add_string out "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string out (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char out c)
    s;
  Buffer.add_char out '"';
  Buffer.contents out

(* The quoted-key spelling of {!child_path}: Python writes it with
   [json.dumps]'s default [ensure_ascii=True], so every non-ASCII codepoint
   becomes [\uXXXX] — surrogate pairs past the BMP — and a path written by
   [child_path] reads back in {!parse_path}. *)

let json_string_ascii s =
  let out = Buffer.create (String.length s + 2) in
  Buffer.add_char out '"';
  let esc cp =
    if cp = 0x22 then Buffer.add_string out "\\\""
    else if cp = 0x5c then Buffer.add_string out "\\\\"
    else if cp = 0x08 then Buffer.add_string out "\\b"
    else if cp = 0x0c then Buffer.add_string out "\\f"
    else if cp = 0x0a then Buffer.add_string out "\\n"
    else if cp = 0x0d then Buffer.add_string out "\\r"
    else if cp = 0x09 then Buffer.add_string out "\\t"
    else if cp < 0x20 then Buffer.add_string out (Printf.sprintf "\\u%04x" cp)
    else if cp < 0x80 then Buffer.add_char out (Char.chr cp)
    else if cp < 0x10000 then Buffer.add_string out (Printf.sprintf "\\u%04x" cp)
    else begin
      let v = cp - 0x10000 in
      let hi = 0xd800 + (v lsr 10) and lo = 0xdc00 + (v land 0x3ff) in
      Buffer.add_string out (Printf.sprintf "\\u%04x\\u%04x" hi lo)
    end
  in
  Array.iter esc (Utf8.of_string s);
  Buffer.add_char out '"';
  Buffer.contents out

(* Python's [repr] of a float, which is what [json.dumps] writes: the shortest
   digits that read back as the same double, then decimal form while the decimal
   point sits in [-4, 16] and scientific with a signed two-digit exponent
   outside it. An integral value keeps its [".0"], or [2] would render as the
   integer it is not; NaN and the infinities carry their Python spellings
   because [json.loads] admits them by default. *)

let dump_float f =
  if Float.is_nan f then "NaN"
  else if f = Float.infinity then "Infinity"
  else if f = Float.neg_infinity then "-Infinity"
  else
    let neg = f < 0.0 || (f = 0.0 && Float.sign_bit f) in
    let a = Float.abs f in
    (* The shortest digit string whose rounding back through a double gives
       [a], as mantissa digits and the decimal point's position: value ≈
       0.<digits> × 10^decpt. *)

    let digits_of_e s =
      let epos = String.index s 'e' in
      let mant = String.sub s 0 epos in
      let exp = int_of_string (String.sub s (epos + 1) (String.length s - epos - 1)) in
      let mant = String.concat "" (String.split_on_char '.' mant) in
      let rec strip l =
        if l > 1 && mant.[l - 1] = '0' then strip (l - 1) else l
      in
      let digits = String.sub mant 0 (strip (String.length mant)) in
      ((if digits = "" then "0" else digits), exp + 1)
    in
    let digits, decpt =
      let rec try_prec p =
        if p > 17 then digits_of_e (Printf.sprintf "%.16e" a)
        else
          let s = Printf.sprintf "%.*e" (p - 1) a in
          match Float.of_string_opt s with
          | Some g when g = a -> digits_of_e s
          | _ -> try_prec (p + 1)
      in
      try_prec 1
    in
    let format digits decpt =
      if decpt <= -4 || decpt > 16 then
        let exp = decpt - 1 in
        let mant =
          match digits with
          | d when String.length d = 1 -> d
          | d ->
              String.make 1 d.[0] ^ "." ^ String.sub d 1 (String.length d - 1)
        in
        Printf.sprintf "%se%+.2d" mant exp
      else
        let n = String.length digits in
        if decpt <= 0 then "0." ^ String.make (-decpt) '0' ^ digits
        else if decpt >= n then digits ^ String.make (decpt - n) '0' ^ ".0"
        else
          String.sub digits 0 decpt ^ "." ^ String.sub digits decpt (n - decpt)
    in
    let s = format digits decpt in
    if neg then "-" ^ s else s

let dump_leaf (json : Yojson.Safe.t) =
  match json with
  | `Null -> "null"
  | `Bool true -> "true"
  | `Bool false -> "false"
  | `Int i -> string_of_int i
  | `Intlit s -> s
  | `Float f -> dump_float f
  | `String s -> json_string s
  | _ -> assert false
(* Containers never reach here: the walk renders them as headers. *)

let is_name_start c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'

let is_name_char c = is_name_start c || (c >= '0' && c <= '9')

let child_path parent key =
  match key with
  | Ordinal k -> Printf.sprintf "%s[%d]" parent k
  | Name name ->
      let n = String.length name in
      let rec all_name_chars i = i >= n || (is_name_char name.[i] && all_name_chars (i + 1)) in
      if n > 0 && is_name_start name.[0] && all_name_chars 0 then
        Printf.sprintf "%s.%s" parent name
      else
        (* Quoted through JSON so a key holding a dot, a space or a quote
           round-trips; the path is a caller's argument, so it has to be
           re-readable, not pretty. *)

        Printf.sprintf "%s[%s]" parent (json_string_ascii name)

(* One parsed document, with Python's object semantics: duplicate keys keep the
   first position and the last value. *)

let normalize (json : Yojson.Safe.t) =
  let rec walk (json : Yojson.Safe.t) =
    match json with
    | `Assoc kvs -> `Assoc (dedupe (List.map (fun (k, v) -> (k, walk v)) kvs))
    | `List xs -> `List (List.map walk xs)
    | j -> j
  and dedupe kvs =
    (* Python's object semantics: a duplicate key keeps the {b first} position and
       the {b last} value. One pass does that — a table from key to the slot it
       first took, a value array under it, and the slots read out in order.

       The shape of the input is why this is not a [fold_left] with
       [List.mem_assoc] and an append: [max_download_bytes] caps the {b bytes} of
       a body, not its member count, so [{"k":1,}] repeated is a legal document
       with tens of thousands of members, and a per-member scan plus a copy of the
       accumulator makes the parse quadratic before the rendering budget is even
       consulted. The placeholder each slot starts on is never read: only the
       first [n] slots, each written before its index is handed out, are taken. *)
    let slots = Hashtbl.create (List.length kvs) in
    let members = Array.make (List.length kvs) ("", `Null) in
    let used = ref 0 in
    List.iter
      (fun (key, value) ->
        match Hashtbl.find_opt slots key with
        | Some slot -> members.(slot) <- (key, value)
        | None ->
            Hashtbl.replace slots key !used;
            members.(!used) <- (key, value);
            incr used)
      kvs;
    Array.to_list (Array.sub members 0 !used)
  in
  walk json

(* [Yojson.Safe.from_string] stops after the first value and refuses trailing
   junk, exactly as [json.loads] does; a trailing-comma pseudo-document and an
   HTML error page under a JSON type fail it the same way. Python's
   [json.loads] also admits [NaN]/[Infinity] literals — Yojson parses those
   into floats too, and {!dump_float} writes their Python spellings. *)

let parse_one text =
  let trimmed = String.trim text in
  if trimmed = "" then None
  else
    match Yojson.Safe.from_string trimmed with
    | exception Yojson.Json_error _ -> None
    | json -> Some (normalize json)

(* One step of the walk's stack. A container comes back as a [Frame] over its
   unread members rather than as one entry per member, so what the walk holds
   is one entry per level it is inside — the rendering's own budget bounds the
   walk with it. An eager walk of a wide container cost a stack entry and a
   path string per member before any of them were printed — 2.3 GB for one
   8 MB page, measured at the Python tree. *)

type entry =
  | Node of string * int * Yojson.Safe.t
  | Frame of string * int * (key * Yojson.Safe.t) list

let render_json text =
  (* One line per node: [<path>  <value>]. A container renders as its own
     header line naming its size — [$  object(4)] then [$.items  array(120)] —
     before its members, so the shape is legible in the first screenful, and
     [array(120)] tells the caller how far [$.items[0:5]] is from the end. A
     leaf renders as compact JSON. Returns [None] when the body is not one
     document this function can walk — a trailing-comma pseudo-JSON API, an
     HTML error page served under [application/json], or a JSON Lines stream —
     and the caller then answers with the body as text. *)

  match parse_one text with
  | None -> None
  | Some value ->
      let budget = max min_render_chars (max_render_ratio * Utf8.count text) in
      let lines = ref [] in
      let spent = ref 0 in
      let rec loop stack =
        match stack with
        | [] -> ()
        | top :: rest -> (
            if !spent > budget then begin
              let path =
                match top with
                | Node (path, _, _) -> path
                | Frame (path, _, _) -> path
              in
              lines :=
                Printf.sprintf
                  "%s  not rendered: the document expands past the budget of %d \
                   characters, %d times its own size; ask for one part of it with \
                   `path`, as in $.items[0:5]"
                  path budget max_render_ratio
                :: !lines
              (* The cut ends the walk entirely, as Python's [break] does: what
                 is printed above is the answer. *)

            end
            else
              match top with
              | Frame (_, _, []) -> loop rest
              | Frame (path, depth, (step, child) :: tail) ->
                  (* The frame goes back under the child: an array of 200k
                     members is one stack entry read one member at a time, not
                     200k entries. *)

                  loop
                    (Node (child_path path step, depth + 1, child)
                    :: Frame (path, depth, tail)
                    :: rest)
              | Node (path, depth, json) -> (
                  let line, push =
                    match json with
                    | `Assoc members ->
                        if depth >= max_depth then
                          ( Printf.sprintf
                              "%s  object(%d) not expanded: nested past depth %d"
                              path (List.length members) max_depth,
                            None )
                        else
                          ( Printf.sprintf "%s  object(%d)" path (List.length members),
                            Some
                              (Frame
                                 ( path,
                                   depth,
                                   List.map (fun (k, v) -> (Name k, v)) members )) )
                    | `List items ->
                        if depth >= max_depth then
                          ( Printf.sprintf
                              "%s  array(%d) not expanded: nested past depth %d"
                              path (List.length items) max_depth,
                            None )
                        else
                          ( Printf.sprintf "%s  array(%d)" path (List.length items),
                            Some
                              (Frame
                                 ( path,
                                   depth,
                                   List.mapi (fun i v -> (Ordinal i, v)) items )) )
                    | leaf -> (Printf.sprintf "%s  %s" path (dump_leaf leaf), None)
                  in
                  lines := line :: !lines;
                  spent := !spent + Utf8.count line + 1;
                  match push with
                  | None -> loop rest
                  | Some frame -> loop (frame :: rest)))
      in
      loop [ Node ("$", 0, value) ];
      Some (String.concat "\n" (List.rev !lines))

(* [str.strip], [str.lstrip] on codepoints: the ASCII blanks plus the Unicode
   spaces Python also drops. *)

let trim_py s =
  let a = Utf8.of_string s in
  let n = Array.length a in
  let i = ref 0 in
  while !i < n && Utf8.is_python_space a.(!i) do incr i done;
  let j = ref (n - 1) in
  while !j >= !i && Utf8.is_python_space a.(!j) do decr j done;
  if n = 0 || !j < !i then "" else Utf8.to_string (Array.sub a !i (!j - !i + 1))

let trim_left s =
  let a = Utf8.of_string s in
  let n = Array.length a in
  let i = ref 0 in
  while !i < n && Utf8.is_python_space a.(!i) do incr i done;
  Utf8.to_string (Array.sub a !i (n - !i))

(* Python's [repr] of a string in a refusal message: the quote is fixed and every
   byte above ASCII is escaped, so a path token the caller wrote comes back
   readable whatever the transport does with it. One escape pass with the engine's
   [safe] now sits in [Seekwright_text.Repr]; the two quoting policies stay
   separate functions there (style review H2). *)

let py_repr = Repr.py_repr_ascii

(* [int("…")] as Python reads it: an optional sign then digits, and nothing
   else — no [0x] or [1_000] the way [int_of_string] would take. *)

let python_int text =
  let body =
    if String.length text > 0 && (text.[0] = '-' || text.[0] = '+') then
      String.sub text 1 (String.length text - 1)
    else text
  in
  if body = "" then None
  else if String.for_all (fun c -> c >= '0' && c <= '9') body then
    int_of_string_opt text
  else None

(* The path grammar. Scanning is byte-indexed — every structural character is
   ASCII, and a UTF-8 continuation byte is none of them — so the offsets in
   refusal messages are byte offsets where Python's were codepoints. *)

let match_name raw at =
  let n = String.length raw in
  if at < n && is_name_start raw.[at] then begin
    let rec go i = if i < n && is_name_char raw.[i] then go (i + 1) else i in
    let e = go (at + 1) in
    Some (String.sub raw at (e - at), e)
  end
  else None

(* Read a bracketed key: [["a b"]], and [['a b']] with it. [json.loads] reads
   the quoting {!render_json} writes, which is the spelling a caller reads off
   the page; a caller typing a path from memory writes the JSONPath spelling in
   single quotes, so a Python-literal-style reader covers that too. *)

let quoted_key inner =
  match Yojson.Safe.from_string inner with
  | `String s -> Some s
  | _ -> None
  | exception _ ->
      (* Single-quoted literal with the common backslash escapes; an escape
         this reader does not know rides through as backslash plus character,
         the way Python's compiler keeps ["\q"] as two characters. *)

      let n = String.length inner in
      let fail () = None in
      let finish b = Some (Buffer.contents b) in
      let rec go b i =
        if i >= n then fail ()
        else
          match inner.[i] with
          | '\'' when i = n - 1 -> finish b
          | '\\' when i + 1 < n -> (
              match inner.[i + 1] with
              | '\\' -> Buffer.add_char b '\\'; go b (i + 2)
              | '\'' -> Buffer.add_char b '\''; go b (i + 2)
              | '"' -> Buffer.add_char b '"'; go b (i + 2)
              | 'n' -> Buffer.add_char b '\n'; go b (i + 2)
              | 't' -> Buffer.add_char b '\t'; go b (i + 2)
              | 'r' -> Buffer.add_char b '\r'; go b (i + 2)
              | 'b' -> Buffer.add_char b '\b'; go b (i + 2)
              | 'f' -> Buffer.add_char b '\012'; go b (i + 2)
              | '0' -> Buffer.add_char b '\000'; go b (i + 2)
              | _ -> Buffer.add_char b '\\'; go b (i + 1))
          | c -> Buffer.add_char b c; go b (i + 1)
      in
      if n < 2 || inner.[0] <> '\'' then None
      else
        let b = Buffer.create (n - 2) in
        go b 1

let bound text =
  let t = trim_py text in
  if t = "" then None
  else
    match python_int t with
    | Some v when v >= 0 -> Some v
    | Some _ ->
        raise
          (Path_syntax
             "a negative slice bound is not supported; the array's length is on \
              its header line, so name the range you want, as in [0:5]")
    | None ->
        raise (Path_syntax (Printf.sprintf "the slice bound %s is not an index" (py_repr text)))

let scan_bracket raw at =
  let n = String.length raw in
  let rec find_close idx quote =
    if idx >= n then -1
    else
      let c = raw.[idx] in
      if quote <> '\000' then
        if c = '\\' then find_close (idx + 2) quote
        else if c = quote then find_close (idx + 1) '\000'
        else find_close (idx + 1) quote
      else if c = '\'' || c = '"' then find_close (idx + 1) c
      else if c = ']' then idx
      else find_close (idx + 1) quote
  in
  let close = find_close (at + 1) '\000' in
  if close < 0 then raise (Path_syntax "a `[` in the path is never closed");
  let inner = trim_py (String.sub raw (at + 1) (close - at - 1)) in
  let end_ = close + 1 in
  if inner = "*" then (Every, end_)
  else
    let first = if inner = "" then '\000' else inner.[0] in
    if first = '"' || first = '\'' then
      (* A quoted key first, whatever it holds: a colon inside the quotes is
         part of the name, and a slice's bounds are never quoted. Tried in the
         other order, the key ["Price: USD"] — the spelling {!child_path}
         writes for it — would be read as a slice with an unparseable bound. *)

      (match quoted_key inner with
       | None ->
           raise
             (Path_syntax (Printf.sprintf "the quoted key %s is not readable" (py_repr inner)))
       | Some key -> (Key key, end_))
    else if String.contains inner ':' then
      let i = String.index inner ':' in
      let start_text = String.sub inner 0 i in
      let stop_text =
        String.sub inner (i + 1) (String.length inner - i - 1)
      in
      (Bounds (bound start_text, bound stop_text), end_)
    else
      let body =
        if String.length inner > 0 && inner.[0] = '-' then
          String.sub inner 1 (String.length inner - 1)
        else inner
      in
      if body <> "" && String.for_all (fun c -> c >= '0' && c <= '9') body then (
        match int_of_string_opt inner with
        | Some v when v >= 0 -> (Position v, end_)
        | Some _ ->
            raise
              (Path_syntax
                 "a negative index is not supported; the array's length is on \
                  its header line, so ask for the range you want, as in [0:5]")
        | None ->
            raise
              (Path_syntax
                 (Printf.sprintf "cannot read the bracketed step [%s]" (py_repr inner)))
      )
      else
        raise
          (Path_syntax (Printf.sprintf "cannot read the bracketed step [%s]" (py_repr inner)))

let scan_path ~bare_names raw =
  let n = String.length raw in
  let steps = ref [] in
  let at = ref (if n > 0 && raw.[0] = '$' then 1 else 0) in
  let rec loop () =
    if !at >= n then ()
    else
      let c = raw.[!at] in
      if c = '.' then begin
        incr at;
        if !at < n && raw.[!at] = '[' then
          (* [$.["a b"]]: the dot is a separator here, not a member name.
             Refusing it would make a caller re-type a path it read straight
             out of the rendering, and nothing about the answer changes. *)

          loop ()
        else
          match match_name raw !at with
          | None ->
              raise
                (Path_syntax
                   (Printf.sprintf "expected a member name after '.' at offset %d" !at))
          | Some (name, e) ->
              steps := Key name :: !steps;
              at := e;
              loop ()
      end
      else if c = '[' then begin
        let step, e = scan_bracket raw !at in
        steps := step :: !steps;
        at := e;
        loop ()
      end
      else if bare_names then
        match match_name raw !at with
        | None ->
            raise
              (Path_syntax
                 (Printf.sprintf "cannot read %s at offset %d"
                    (py_repr (String.sub raw !at (n - !at)))
                    !at))
        | Some (name, e) ->
            steps := Key name :: !steps;
            at := e;
            loop ()
      else (* A rendered line ends at the first character that cannot
              continue a path; a stray character there is a value, not a
              syntax error. *)

        ()
  in
  loop ();
  (List.rev !steps, !at)

let parse_path spec =
  let raw = trim_py spec in
  let steps, at = scan_path ~bare_names:true raw in
  if at <> String.length raw then
    raise
      (Path_syntax
         (Printf.sprintf "cannot read %s at offset %d"
            (py_repr (String.sub raw at (String.length raw - at)))
            at));
  if steps = [] && raw <> "$" then
    (* A blank or whitespace-only [path] reads as the root, which silently
       turns a caller's typo into a request for the whole document. [$] is the
       spelling that *means* the whole document, and it stays honoured. *)

    raise
      (Path_syntax
         "the path names nothing; ask for a member, as in $.items[0], or `$` \
          for the whole document");
  steps

let matches line_steps spec =
  List.length line_steps >= List.length spec
  &&
  let rec go ls ss =
    match ss with
    | [] -> true
    | wanted :: srest -> (
        match ls with
        | [] -> false
        | step :: lrest -> (
            let ok =
              match (wanted, step) with
              | Every, _ -> true
              | Key want, Key have -> want = have
              | Position want, Position have -> want = have
              | Bounds (start, stop), Position have ->
                  (match start with
                   | Some a when have < a -> false
                   | _ -> (
                       match stop with
                       | Some b when have >= b -> false
                       | _ -> true))
              | _ -> false
            in
            if ok then go lrest srest else false))
  in
  go line_steps spec

let select_paths rendered path ~max_chars =
  let spec = parse_path path in
  let spans = ref [] in
  let buf = ref [] in
  let run_start = ref 0 in
  let run_chars = ref 0 in
  let offset = ref 0 in
  let flush () =
    match !buf with
    | [] -> ()
    | _ ->
        spans := (!run_start, String.concat "\n" (List.rev !buf)) :: !spans;
        buf := []
  in
  List.iter
    (fun line ->
      (* Only the renderer's own lines are candidates: every one of them starts
         at the document root, so a page that reached the caller as raw text
         has no path to match rather than a wrong one. A rendered line is
         always grammatical, so a [Path_syntax] from its head rides out the
         same way Python's did. *)

      let matched =
        if String.length line > 0 && line.[0] = '$' then
          let steps, _ = scan_path ~bare_names:false line in
          matches steps spec
        else false
      in
      let len = Utf8.count line in
      if matched then
        match !buf with
        | [] ->
            run_start := !offset;
            buf := [ line ];
            run_chars := len
        | _ :: _ ->
            if !run_chars + len + 1 > max_chars then begin
              flush ();
              run_start := !offset;
              buf := [ line ];
              run_chars := len
            end
            else begin
              buf := line :: !buf;
              run_chars := !run_chars + len + 1
            end
      else flush ();
      offset := !offset + len + 1)
    (String.split_on_char '\n' rendered);
  flush ();
  let spans = List.rev !spans in
  let total = List.length spans in
  (* Selection stops at the first span that does not fit — the
     [select_passages] rule — so both selectors spend [fetch.max_match_chars]
     the same way. *)

  let rec pick acc used = function
    | [] -> (List.rev acc, total - List.length acc)
    | (start, text) :: rest ->
        let len = Utf8.count text in
        if used + len + 1 > max_chars then (List.rev acc, total - List.length acc)
        else pick ((start, text) :: acc) (used + len + 1) rest
  in
  pick [] 0 spans

(* The shape view. *)

type shape_node = {
  kind : string;
      (** [object]/[array] for a container, [leaf] or [annotation] otherwise. *)

  text : string;
      (** The type word of a leaf, or the marker a rendering printed. *)

  size : int;
      (** A container's declared child count. *)

  mutable children : (key * shape_node) list;
      (* In document order; a repeated key keeps its position and takes the
         newer node, the way Python's dict assignment does. *)

}

let same_key (a : key) (b : key) =
  match (a, b) with Name x, Name y -> x = y | Ordinal x, Ordinal y -> x = y | _ -> false

let set_child node key child =
  let rec repl = function
    | [] -> [ (key, child) ]
    | (k, c) :: rest ->
        if same_key k key then (k, child) :: rest else (k, c) :: repl rest
  in
  node.children <- repl node.children

let find_child node key =
  match List.find_opt (fun (k, _) -> same_key k key) node.children with
  | Some (_, child) -> Some child
  | None -> None

let leaf_type value =
  let first = if value = "" then '\000' else value.[0] in
  if first = '"' then "string"
  else if String.starts_with ~prefix:"true" value || String.starts_with ~prefix:"false" value
  then "bool"
  else if String.starts_with ~prefix:"null" value then "null"
  else "number"

let classify payload =
  (* One line's payload after its path: the node it describes, or [None]. A
     container header is a shape fact even when the rendering cut beneath it:
     [array(20000)] is what makes [$.items[0:5]] addressable, so the size is
     kept, and an annotation rides in the same line as the rendering printed
     it. Leaf values are classified by their first byte alone — reading no
     further is the point, the value being what this view withholds. *)

  let header kind =
    let kl = String.length kind in
    if
      String.length payload > kl
      && String.sub payload 0 kl = kind
      && payload.[kl] = '('
    then
      let rest = String.sub payload (kl + 1) (String.length payload - kl - 1) in
      (* The bound is parsed once and destructured where it appears. The guard
         and the force beside it evaluated [python_int] on the same slice twice
         and re-sliced it a third time (style review M3). *)
      (match String.index_opt rest ')' with
      | Some i -> (
          match python_int (String.sub rest 0 i) with
          | Some size ->
              let after = String.sub rest (i + 1) (String.length rest - i - 1) in
              Some (kind, size, trim_left after)
          | None -> None)
      | None -> None)
    else None
  in
  match header "object" with
  | Some (kind, size, rest) ->
      if rest = "" then Some { kind; text = ""; size; children = [] }
      else
        Some
          { kind = "annotation";
            text = Printf.sprintf "%s(%d) %s" kind size rest;
            size;
            children = [] }
  | None -> (
      match header "array" with
      | Some (kind, size, rest) ->
          if rest = "" then Some { kind; text = ""; size; children = [] }
          else
            Some
              { kind = "annotation";
                text = Printf.sprintf "%s(%d) %s" kind size rest;
                size;
                children = [] }
      | None ->
          if String.starts_with ~prefix:"not " payload then
            Some { kind = "annotation"; text = payload; size = 0; children = [] }
          else if
            (String.length payload > 0 && payload.[0] = '"')
            || (String.length payload > 0
                && (payload.[0] = '-' || (payload.[0] >= '0' && payload.[0] <= '9')))
            || String.starts_with ~prefix:"true" payload
            || String.starts_with ~prefix:"false" payload
            || String.starts_with ~prefix:"null" payload
          then Some { kind = "leaf"; text = leaf_type payload; size = 0; children = [] }
          else None)

let max_schema_depth_cut = "not expanded: nested past depth"

let shape_tree rendered =
  (* The shape tree behind one rendering, or [None] when it is not one. Built
     by reading lines, never by parsing the leaf values — the values are what
     a shape view exists to withhold, so only their first byte is read to
     classify them. Children land in the order their lines arrive, which is
     document order, so the walk below emits in document order without
     sorting. *)

  let root = ref None in
  let bad = ref false in
  let new_node () = { kind = "object"; text = ""; size = 0; children = [] } in
  let get_or_make parent key =
    match find_child parent key with
    | Some child -> child
    | None ->
        let child = new_node () in
        set_child parent key child;
        child
  in
  List.iter
    (fun line ->
      if not !bad then
        if String.length line = 0 || line.[0] <> '$' then bad := true
        else
          match scan_path ~bare_names:false line with
          | exception Path_syntax _ -> bad := true
          | steps, at -> (
              let payload = trim_py (String.sub line at (String.length line - at)) in
              match classify payload with
              | None -> bad := true
              | Some node -> (
                  match steps with
                  | [] -> (
                      match !root with
                      | Some _ -> bad := true
                      | None -> root := Some node)
                  | _ ->
                      let rec split_last acc = function
                        | [] -> None
                        | [ x ] -> Some (List.rev acc, x)
                        | x :: rest -> split_last (x :: acc) rest
                      in
                      match split_last [] steps with
                      | None -> bad := true
                      | Some (before, last) -> (
                          match !root with
                          | None ->
                              (* A member before the root's own line is
                                 impossible from {!render_json}, which prints
                                 the root header first; treating it as
                                 not-a-rendering is safer than inventing the
                                 root's shape. *)

                              bad := true
                          | Some root_node -> (
                              let stop = ref false in
                              let parent =
                                List.fold_left
                                  (fun parent step ->
                                    if !stop then parent
                                    else
                                      match step with
                                      | Key name -> get_or_make parent (Name name)
                                      | Position i -> get_or_make parent (Ordinal i)
                                      | _ ->
                                          stop := true;
                                          parent)
                                  root_node before
                              in
                              if !stop then bad := true
                              else
                                match last with
                                | Key name -> set_child parent (Name name) node
                                | Position i -> set_child parent (Ordinal i) node
                                | _ -> bad := true))))
  )
    (String.split_on_char '\n' rendered);
  if !bad then None else !root

(* Whether two shape subtrees describe the same, recursively. Uniform means
   every *described* member describes the same shape: one leaf type, or one
   container kind and size with recursively the same shape beneath. The
   comparison is by shape alone, so two members with the same keys and types
   but different values — the common case, an array of same-keyed records —
   are uniform. String keys are compared by type only, the quirk Python's
   [isinstance(left_key, type(right_key))] carries. *)

let rec same_shape left right =
  if left.kind <> right.kind || left.size <> right.size then false
  else if left.kind = "leaf" || left.kind = "annotation" then left.text = right.text
  else if List.length left.children <> List.length right.children then false
  else
    let rec go lrest rrest =
      match (lrest, rrest) with
      | [], [] -> true
      | (lk, lch) :: lt, (rk, rch) :: rt -> (
          match (lk, rk) with
          | Name _, Name _ -> same_shape lch rch && go lt rt
          | Ordinal x, Ordinal y -> x = y && same_shape lch rch && go lt rt
          | _ -> false)
      | _ -> false
    in
    go left.children right.children

let rec emit_shape node path depth lines budget =
  if node.kind = "leaf" || node.kind = "annotation" then begin
    let line = Printf.sprintf "%s  %s" path node.text in
    lines := line :: !lines;
    Utf8.count line + 1
  end
  else if depth >= max_depth then begin
    let line =
      Printf.sprintf "%s  %s(%d) %s %d" path node.kind node.size max_schema_depth_cut
        max_depth
    in
    lines := line :: !lines;
    Utf8.count line + 1
  end
  else begin
    let line = Printf.sprintf "%s  %s(%d)" path node.kind node.size in
    lines := line :: !lines;
    let spent = Utf8.count line + 1 in
    if node.children = [] then spent
    else if node.kind = "array" then
      match uniform node.children with
      | None -> spent + emit_children node.children path depth lines (budget - spent)
      | Some (representative, cut) ->
          (* A uniform array prints one [[*]] subtree — its first member's
             shape, addressed with [[*]] in the members' own place — and
             nothing per member, so the cost of a big uniform array is its
             representative's size, not its length. *)

          let spent =
            spent
            + emit_shape representative (Printf.sprintf "%s[*]" path) (depth + 1) lines
                (budget - spent)
          in
          (* The rendering's own cut lines ride at the indices they fell on:
             the shape is the representative's, and these say the page was
             cut, which is the one fact [[*]] must not be allowed to paper
             over. Their paths carry real indices, so a drill below the cut is
             still addressable. *)

          List.fold_left
            (fun spent (k, annotation) ->
              let annotation_path = child_path path k in
              let line = Printf.sprintf "%s  %s" annotation_path annotation.text in
              lines := line :: !lines;
              spent + Utf8.count annotation_path + 3 + Utf8.count annotation.text + 1)
            spent cut
    else spent + emit_children node.children path depth lines (budget - spent)
  end

and emit_children children path depth lines budget =
  let rec go spent = function
    | [] -> spent
    | (k, child) :: rest ->
        if spent > budget then begin
          let line =
            Printf.sprintf
              "%s  not rendered: the structure expands past the budget of %d \
               characters; drill into one part of it with `path`, as in \
               $.items[0:5]"
              (child_path path k) budget
          in
          lines := line :: !lines;
          spent
        end
        else
          go
            (spent + emit_shape child (child_path path k) (depth + 1) lines (budget - spent))
            rest
  in
  go 0 children

and uniform children =
  (* The subtree a uniform array collapses to, and the members it may not
     silence. A rendering cut by its own budget ends in annotation lines
     ([not rendered: the document expands past the budget…]): those say
     nothing about the members' shapes, either way, so they are set aside
     rather than counted against the uniform run or folded under [[*]] — they
     come back as their own lines, at their own indices, so the reader sees
     the page itself was cut rather than a shape that quietly covers it. Two
     described members that differ still refuse the collapse, then as always. *)

  let described =
    List.filter (fun (_, child) -> child.kind <> "annotation") children
  in
  let cut = List.filter (fun (_, child) -> child.kind = "annotation") children in
  match described with
  | [] -> None
  | (_, first) :: rest ->
      if List.for_all (fun (_, child) -> same_shape child first) rest then
        Some (first, cut)
      else None

let render_schema rendered =
  (* The shape of a *rendered* JSON document: paths and types, no values.
     Input is {!render_json}'s one-line-per-node output, which is the only
     form the fetch path carries — the raw JSON is gone by the time the engine
     sees the page, so the shape is derived from the rendering. Output is one
     line per node again, but every leaf prints only its type —
     [$.items  array(20000)], [$.items[*].id  number] — and a uniform array
     collapses to one [[*]] subtree, so a document that renders to millions of
     characters reports its shape in a few kilobytes. Returns [None] when the
     input is not one rendered document — any line that does not start at the
     root, or a line this reader cannot classify — so the caller answers with
     the page as it is rather than a schema of something else. *)

  match shape_tree rendered with
  | None -> None
  | Some root ->
      let budget = max min_render_chars (max_render_ratio * Utf8.count rendered) in
      let lines = ref [] in
      let _spent = emit_shape root "$" 0 lines budget in
      Some (String.concat "\n" (List.rev !lines))
