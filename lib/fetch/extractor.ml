(* The extraction-backend contract and the plumbing every backend shares.

   Port of [src/seekwright/extractors/base.py]. [fetch] pulls bytes off the
   network; turning them into text a model can read is the part most likely to
   be replaced. So it sits behind a named backend, picked by [fetch.extractor]
   and looked up in {!known_extractors} — swapping the engine is a config
   change, not a code change.

   A backend implements {!S}: a [name], the media types it can read, and an
   [extract] returning an {!extract_result}. Python states the contract as a
   [runtime_checkable] Protocol and OCaml states it as a module type, so a
   backend missing a member is a compile error rather than a runtime surprise;
   {!backend} is the first-class form the fetcher holds.

   Two backends are deliberate absences on this port. [trafilatura] and [pypdf]
   stay behind: no PDF reader ships in the OCaml tree, so a PDF is refused by
   the type set rather than parsed, which is the same honesty the Python
   contract demands of a bare install — a backend lists only what its [extract]
   can read. *)

type extract_result = {
  text : string;
  title : string option;
  total_chars : int;
      (** Length of the full normalised extraction, in codepoints — the same
          coordinate system Python's [len] counts, so [offset] and the
          [[...]] marker keep their meaning across the port. *)

  path_addressable : bool;
      (** Whether [text] is a structure rendering whose lines [fetch]'s [path]
          selects. Only the extraction can say it, so it says it: the engine
          must not infer "this is a structure this server read" from a
          character of page text. A Makefile whose first line is [$ make all]
          starts with the root character of a path and is not one, and a body
          that reached the caller as text because the renderer declined it is
          not one either. Set by the backend that walked the structure — a
          JSON document or a CSV table; every other page leaves it [false]. *)

}

exception Extraction_failed of string
(** The bytes could not be turned into text at all. The fetcher turns it into
    the "cannot extract text: …" refusal; an empty extraction is a reportable
    outcome, not an error. *)

module type S = sig
  val name : string
  val supported_types : string list
      (** What the fetcher checks a response's media type against *before*
          using the body, so it must be honest: an unreadable type listed here
          spends a download on a page that can never be read. *)

  val extract : string -> string option -> extract_result
      (** [extract body content_type] extracts readable text from a fetched
          body, uncut. Sizing it for a caller is the fetcher's job
          ([Fetcher.window_text]): where to cut depends on who is asking.
          Raises [Extraction_failed] when the body cannot be read. *)

end

(** The first-class form the fetcher holds, one field per {!S} member. *)

type backend = {
  name : string;
  supported_types : string list;
  extract : string -> string option -> extract_result;
}

let of_module (module E : S) : backend =
  { name = E.name; supported_types = E.supported_types; extract = E.extract }

(* {1 Media-type plumbing} *)

let ascii_lower (s : string) : string =
  String.map (fun c -> if c >= 'A' && c <= 'Z' then Char.chr (Char.code c + 32) else c) s

let html_types = [ "text/html"; "application/xhtml+xml" ]

let pdf_types = [ "application/pdf"; "application/x-pdf" ]

let text_types = [ "text/plain"; "text/markdown"; "text/xml"; "application/xml" ]

let json_types = Jsondoc.json_document_types @ Jsondoc.jsonl_types

let table_types = Tabledoc.table_types

let supported_types = html_types @ pdf_types @ text_types @ json_types @ table_types

let known_extractors = [ "stdlib" ]
(** Every fetch extraction backend this build knows how to construct, by name.
    Config validation rejects a [fetch.extractor] outside this set, exactly as
    it rejects a provider name outside [Router]'s registry — a name that parses
    and does nothing is the failure mode both exist to remove. [trafilatura]
    stays a Python-only member: its absence here is a port decision recorded in
    the test suite, not a gap. *)

let member kind types = List.mem kind types

let media_type content_type =
  match content_type with
  | None -> ""
  | Some ct ->
    let bare =
      match String.index_opt ct ';' with
      | Some i -> String.sub ct 0 i
      | None -> ct
    in
    String.trim (ascii_lower bare)

let is_supported types kind =
  member kind types
  ||
  let n = String.length kind in
  n >= 5
  && String.sub kind (n - 5) 5 = "+json"
  && List.mem "application/json" types
  (** The one place the RFC 6839 rule sits: a [+json] type *is* a JSON document
      whatever its prefix registers. A backend reading [application/json] reads
      [application/geo+json] with it; enumerating suffixes would make each new
      one a refusal the operator has to patch. The fetcher runs this before
      spending the body, so the claim stays the backend's. *)

let charset_of content_type =
  let unquote value =
    (* Python's [strip('"')]: every leading and trailing quote goes. *)
    let rec strip v =
      let n = String.length v in
      let lead = if n > 0 && v.[0] = '"' then 1 else 0 in
      let trail = if n - lead > 0 && v.[n - 1] = '"' then 1 else 0 in
      if lead + trail > 0 then strip (String.sub v lead (n - lead - trail)) else v
    in
    strip value
  in
  match content_type with
  | None -> None
  | Some ct ->
    match String.split_on_char ';' ct with
    | _ :: params ->
      let rec go = function
        | [] -> None
        | p :: tl -> (
            match String.index_opt p '=' with
            | Some eq ->
                let name =
                  String.trim (ascii_lower (String.sub p 0 eq))
                in
                if name = "charset" then
                  let value =
                    String.trim
                      (String.sub p (eq + 1) (String.length p - eq - 1))
                  in
                  let value = unquote value in
                  if value = "" then go tl else Some value
                else go tl
            | None -> go tl)
      in
      go params
    | [] -> None

(* {1 Decoding} *)

(* The declared charset is honoured for the encodings this port implements;
   anything else is a header problem, not a lost page, and falls through to
   UTF-8 the way an unknown codec does in Python. cp1252's five undefined
   bytes decode to U+FFFD rather than failing the strict pass: the Python
   codec raises where the HTML numeric-reference table substitutes, and this
   port carries one table for both. *)

let windows_1252_special (b : int) : int =
  match b with
  | 0x80 -> 0x20AC (* € *)

  | 0x81 -> 0xFFFD
  | 0x82 -> 0x201A (* ‚ *)

  | 0x83 -> 0x0192 (* ƒ *)

  | 0x84 -> 0x201E (* „ *)

  | 0x85 -> 0x2026 (* … *)

  | 0x86 -> 0x2020 (* † *)

  | 0x87 -> 0x2021 (* ‡ *)

  | 0x88 -> 0x02C6 (* ˆ *)

  | 0x89 -> 0x2030 (* ‰ *)

  | 0x8A -> 0x0160 (* Š *)

  | 0x8B -> 0x2039 (* ‹ *)

  | 0x8C -> 0x0152 (* Œ *)

  | 0x8D -> 0xFFFD
  | 0x8E -> 0x017D (* Ž *)

  | 0x8F | 0x90 -> 0xFFFD
  | 0x91 -> 0x2018 (* ' *)

  | 0x92 -> 0x2019 (* ' *)

  | 0x93 -> 0x201C (* " *)

  | 0x94 -> 0x201D (* " *)

  | 0x95 -> 0x2022 (* • *)

  | 0x96 -> 0x2013 (* – *)

  | 0x97 -> 0x2014 (* — *)

  | 0x98 -> 0x02DC (* ˜ *)

  | 0x99 -> 0x2122 (* ™ *)

  | 0x9A -> 0x0161 (* š *)

  | 0x9B -> 0x203A (* › *)

  | 0x9C -> 0x0153 (* œ *)

  | 0x9D -> 0xFFFD
  | 0x9E -> 0x017E (* ž *)

  | 0x9F -> 0x0178 (* Ÿ *)

  | _ -> b

let utf8_encode (cp : int) : string =
  if cp < 0x80 then String.make 1 (Char.chr cp)
  else if cp < 0x800 then
    String.init 2 (fun i ->
        if i = 0 then Char.chr (0xC0 lor (cp lsr 6))
        else Char.chr (0x80 lor (cp land 0x3F)))
  else if cp < 0x10000 then
    String.init 3 (fun i ->
        match i with
        | 0 -> Char.chr (0xE0 lor (cp lsr 12))
        | 1 -> Char.chr (0x80 lor ((cp lsr 6) land 0x3F))
        | _ -> Char.chr (0x80 lor (cp land 0x3F)))
  else
    String.init 4 (fun i ->
        match i with
        | 0 -> Char.chr (0xF0 lor (cp lsr 18))
        | 1 -> Char.chr (0x80 lor ((cp lsr 12) land 0x3F))
        | 2 -> Char.chr (0x80 lor ((cp lsr 6) land 0x3F))
        | _ -> Char.chr (0x80 lor (cp land 0x3F)))

let replacement_char = "\xEF\xBF\xBD"

(* Strict UTF-8: the same grammar the encoder emits, overlong forms and
   surrogates refused, so a failure here is a real encoding mismatch. *)

let valid_utf8 (s : string) : bool =
  let n = String.length s in
  let rec go i =
    if i >= n then true
    else
      let b = Char.code s.[i] in
      if b < 0x80 then go (i + 1)
      else if b < 0xC0 then false
      else if b < 0xE0 then
        b >= 0xC2 && i + 1 < n
        && Char.code s.[i + 1] >= 0x80 && Char.code s.[i + 1] < 0xC0
        && go (i + 2)
      else if b < 0xF0 then
        i + 2 < n
        && (match Char.code s.[i + 1] with
            | c when b = 0xE0 -> c >= 0xA0 && c < 0xC0
            | c when b = 0xED -> c >= 0x80 && c < 0xA0
            | c -> c >= 0x80 && c < 0xC0)
        && Char.code s.[i + 2] >= 0x80 && Char.code s.[i + 2] < 0xC0
        && go (i + 3)
      else if b < 0xF5 then
        i + 3 < n
        && (match Char.code s.[i + 1] with
            | c when b = 0xF0 -> c >= 0x90 && c < 0xC0
            | c when b = 0xF4 -> c >= 0x80 && c < 0x90
            | c -> c >= 0x80 && c < 0xC0)
        && Char.code s.[i + 2] >= 0x80 && Char.code s.[i + 2] < 0xC0
        && Char.code s.[i + 3] >= 0x80 && Char.code s.[i + 3] < 0xC0
        && go (i + 4)
      else false
  in
  go 0

(* The errors="replace" pass. One U+FFFD per un-decodable byte; Python replaces
   once per maximal bad subpart, so a truncated multi-byte sequence costs this
   port one extra U+FFFD — a difference no test in the suite pins, and the
   decoded text only ever feeds readers that do not care. *)

let replace_utf8 (s : string) : string =
  let n = String.length s in
  let buf = Buffer.create n in
  let rec go i =
    if i >= n then ()
    else
      let b = Char.code s.[i] in
      let seq_len, ok =
        if b < 0x80 then (1, true)
        else if b < 0xC2 then (1, false)
        else if b < 0xE0 then (2, i + 1 < n && Char.code s.[i + 1] >= 0x80 && Char.code s.[i + 1] < 0xC0)
        else if b < 0xF0 then
          ( 3,
            i + 2 < n
            && (match Char.code s.[i + 1] with
                | c when b = 0xE0 -> c >= 0xA0 && c < 0xC0
                | c when b = 0xED -> c >= 0x80 && c < 0xA0
                | c -> c >= 0x80 && c < 0xC0)
            && Char.code s.[i + 2] >= 0x80 && Char.code s.[i + 2] < 0xC0 )
        else if b < 0xF5 then
          ( 4,
            i + 3 < n
            && (match Char.code s.[i + 1] with
                | c when b = 0xF0 -> c >= 0x90 && c < 0xC0
                | c when b = 0xF4 -> c >= 0x80 && c < 0x90
                | c -> c >= 0x80 && c < 0xC0)
            && Char.code s.[i + 2] >= 0x80 && Char.code s.[i + 2] < 0xC0
            && Char.code s.[i + 3] >= 0x80 && Char.code s.[i + 3] < 0xC0 )
        else (1, false)
      in
      if ok && seq_len = 1 then (Buffer.add_char buf s.[i]; go (i + 1))
      else if ok then (
        Buffer.add_substring buf s i seq_len;
        go (i + seq_len))
      else (
        Buffer.add_string buf replacement_char;
        go (i + 1))
  in
  go 0;
  Buffer.contents buf

let decode_with (f : int -> int) (s : string) : string option =
  let n = String.length s in
  let buf = Buffer.create n in
  String.iteri
    (fun i b ->
      Buffer.add_string buf (utf8_encode (f (Char.code b)));
      ignore i)
    s;
  Some (Buffer.contents buf)

let decode (body : string) (content_type : string option) : string =
  let utf8 () = if valid_utf8 body then body else replace_utf8 body in
  match charset_of content_type with
  | Some cs -> (
      match String.lowercase_ascii cs with
      | "utf-8" | "utf8" | "utf_8" | "ascii" | "us-ascii" -> utf8 ()
      | "iso-8859-1" | "latin-1" | "latin1" | "l1" -> (
          match decode_with (fun b -> b) body with Some s -> s | None -> utf8 ())
      | "windows-1252" | "cp1252" | "windows_1252" -> (
          match decode_with windows_1252_special body with
          | Some s -> s
          | None -> utf8 ())
      | _ -> utf8 ())
  | None -> utf8 ()
  (** Decode a response body to text, preferring the server's declared charset.
      Never raises: a page with a few mojibake characters is still useful,
      whereas an exception loses the whole page over one bad byte. *)

let sniffs_html (body : string) : bool =
  let head_bytes = min (String.length body) 512 in
  let head = String.sub body 0 head_bytes in
  let stripped =
    let n = String.length head in
    let rec start i =
      if i < n
         && (match head.[i] with ' ' | '\t' | '\n' | '\r' | '\011' | '\012' -> true | _ -> false)
      then start (i + 1)
      else i
    in
    let s0 = start 0 in
    String.sub head s0 (n - s0)
  in
  let lower = ascii_lower stripped in
  let starts prefix =
    String.length lower >= String.length prefix
    && String.sub lower 0 (String.length prefix) = prefix
  in
  starts "<!doctype html" || starts "<html"
  (** Treat a missing Content-Type as HTML only if the bytes look like it. The
      rule belongs to the absent header, not to any one engine. *)

(* {1 The one place the wire shape of an extraction is decided} *)

(* [ \t]+ → " " on the codepoint array, then "\n{3,}" → "\n\n", then a Python
   [str.strip]. [normalise] runs on text any backend produced, so the two
   collapsing passes and the strip live here and nowhere else. *)

let normalise (text : string) (title : string option) : extract_result =
  let t = Utf8.of_string text in
  let collapsed =
    let ws =
      let out = ref [] in
      let n = Array.length t in
      let i = ref 0 in
      while !i < n do
        let c = t.(!i) in
        if c = 0x20 || c = 0x09 then (
          out := 0x20 :: !out;
          let j = ref (!i + 1) in
          while !j < n && (t.(!j) = 0x20 || t.(!j) = 0x09) do
            incr j
          done;
          i := !j)
        else (
          out := c :: !out;
          incr i)
      done;
      Array.of_list (List.rev !out)
    in
    let blanks =
      let out = ref [] in
      let n = Array.length ws in
      let i = ref 0 in
      while !i < n do
        if ws.(!i) = 0x0A then (
          let j = ref !i in
          while !j < n && ws.(!j) = 0x0A do
            incr j
          done;
          let run = !j - !i in
          out := (if run >= 3 then [ 0x0A; 0x0A ] else Array.to_list (Array.sub ws !i run)) @ !out;
          i := !j)
        else (
          out := ws.(!i) :: !out;
          incr i)
      done;
      Array.of_list (List.rev !out)
    in
    let n = Array.length blanks in
    let rec lead i = if i < n && Utf8.is_python_space blanks.(i) then lead (i + 1) else i in
    let rec trail i = if i >= 0 && Utf8.is_python_space blanks.(i) then trail (i - 1) else i in
    let a = lead 0 and b = trail (n - 1) in
    if a > b then [||] else Array.sub blanks a (b - a + 1)
  in
  let text = Utf8.to_string collapsed in
  {
    text;
    title = (match title with Some t when t <> "" -> Some t | _ -> None);
    total_chars = Utf8.count text;
    path_addressable = false;
  }

let json_extraction (text : string) : extract_result =
  (* A JSON body as the structure it is, or as its own text when it is not one.
     An endpoint answering [application/json] with an HTML error page, or with
     JSON Lines rather than one document, has not failed to be fetched: its
     bytes are the answer, so they come back as text rather than as an
     [Extraction_failed]. [normalise] never runs here — its whitespace rules
     are for prose, and in a JSON value the spaces are the data. *)

  match Jsondoc.render_json text with
  | None -> { text; title = None; total_chars = Utf8.count text; path_addressable = false }
  | Some rendered ->
      {
        text = rendered;
        title = None;
        total_chars = Utf8.count rendered;
        path_addressable = true;
      }

let table_extraction (text : string) (kind : string) : extract_result =
  (* A delimited body as the table it is, or as its own text when it is not
     one. A [text/csv] body the reader cannot walk at all has not failed to be
     fetched: its bytes are the answer, so the bytes come back. A body that
     walked partway keeps the rows it read, and the rendering names where the
     reader stopped. [normalise] never runs here either; in a quoted cell the
     whitespace is the data. *)

  match Tabledoc.render_table text ~delimiter:(Tabledoc.table_delimiter kind text) with
  | None -> { text; title = None; total_chars = Utf8.count text; path_addressable = false }
  | Some rendered ->
      {
        text = rendered;
        title = None;
        total_chars = Utf8.count rendered;
        path_addressable = true;
      }

(* {1 The phrase the refusal is built from} *)

let describe_types (types : string list) : string =
  let families =
    [
      ("HTML", html_types);
      (* The XML media types ride with plain text: a backend reads them decoded
         and passed through, not walked as a structure. *)

      ("plain text", text_types);
      (* JSON is a family of its own because it is read as a structure, not as
         text; the [+json] suffix types ride with it, through [is_supported]. *)

      ("JSON", json_types);
      (* CSV is a family of its own because it is read as rows, not as text:
         the types are claimed only when the header names them, never sniffed. *)

      ("CSV", table_types);
      ("PDF", pdf_types);
    ]
  in
  let claimed = List.concat_map snd families in
  let labels =
    List.filter_map
      (fun (label, members) ->
        if List.exists (fun k -> List.mem k members) types then Some label else None)
      families
  in
  let extras =
    List.sort compare (List.filter (fun k -> not (List.mem k claimed)) types)
  in
  let labels = labels @ extras in
  let rec join = function
    | [] -> ""
    | [ last ] -> last
    | next :: rest -> next ^ ", " ^ join rest
  in
  match labels with
  | [] -> "nothing"
  | [ one ] -> one
  | _ -> join (List.rev (List.tl (List.rev labels))) ^ " and " ^ List.hd (List.rev labels)
  (** A human phrase naming the media types a backend can read. Derived rather
      than hardcoded, because the phrase is model-facing: it appears in the
      refusal for a URL the backend cannot read, and a backend swap must not
      leave that message claiming a type the new one lacks. Families render in
      a fixed order, so a given set always reads the same way; a type no family
      claims is appended verbatim and sorted. *)

(* {1 Passage selection} *)

let chunk_chars = 1500
(** Granularity of passage selection: roughly one to three paragraphs. *)

let is_word_char (c : int) : bool =
  (c >= 0x30 && c <= 0x39)
  || (c >= 0x41 && c <= 0x5A)
  || (c >= 0x61 && c <= 0x7A)
  || c = 0x5F
  || c >= 0x80
  (** Python's [\w] is Unicode-wide; this port carries the ASCII members plus
      every non-ASCII codepoint, the approximation {!Utf8.ascii_lower} already
      records for [casefold] — queries and pages are matched under the same
      normal form, which is what the scorer needs. *)

let contains (needle : Utf8.t) (hay : Utf8.t) : bool =
  let m = Array.length needle and n = Array.length hay in
  if m = 0 then true
  else if m > n then false
  else
    let first = needle.(0) in
    let rec go i =
      if i > n - m then false
      else
        let rec cmp j = j = m || (hay.(i + j) = needle.(j) && cmp (j + 1)) in
        if hay.(i) = first && cmp 0 then true else go (i + 1)
    in
    go 0

let select_passages (text : string) (query : string) ~max_chars :
    (int * string) list * int =
  (* Pick the passages of a full extraction that answer [query].

     Deterministic term overlap — not an embedding or a provider call, so it
     adds no dependency and works on text any fallback produced. Returns
     [(spans, dropped)]: [(offset, text)] pairs in document order, each offset
     indexing the *full* extraction, and the count of matching chunks the
     budget cut.

     Tokens are word runs of the casefolded query, length >= 2, deduplicated.
     Chunks are consecutive paragraphs packed to {!chunk_chars}, a lone
     paragraph over the mark hard-split. A chunk scores by distinct query
     tokens; zero scores are never candidates. Candidates are taken best-first
     (score, then position) while the budget lasts, and the first that does not
     fit ends selection rather than letting a smaller one queue-jump. Selected
     chunks are re-sorted by offset and adjacent ones merged. *)

  let q = Utf8.ascii_lower (Utf8.of_string query) in
  let tokens =
    let n = Array.length q in
    let rec runs i acc =
      if i >= n then List.rev acc
      else if is_word_char q.(i) then (
        let j = ref i in
        while !j < n && is_word_char q.(!j) do
          incr j
        done;
        runs !j (Array.sub q i (!j - i) :: acc))
      else runs (i + 1) acc
    in
    let all = runs 0 [] in
    let dedup (seen, acc) tok =
      if List.exists (fun s -> s = tok) seen then (seen, acc)
      else (tok :: seen, tok :: acc)
    in
    List.filter (fun t -> Array.length t >= 2) (snd (List.fold_left dedup ([], []) all))
  in
  if tokens = [] then ([], 0)
  else
    let t = Utf8.of_string text in
    (* Split on "\n\n" (the only breaks normalisation leaves), carrying
       absolute offsets, then hard-split any paragraph over the mark. An empty
       paragraph contributes no piece, exactly as Python's [range] skips it. *)

    let pieces =
      let n = Array.length t in
      let out = ref [] in
      let pos = ref 0 and start = ref 0 in
      let flush upto =
        let para = Array.sub t !start (upto - !start) in
        if upto > !start then (
          let plen = upto - !start in
          let k = ref 0 in
          while !k < plen do
            let stop = min (!k + chunk_chars) plen in
            out := (!pos + !k, Array.sub para !k (stop - !k)) :: !out;
            k := !k + chunk_chars
          done);
        pos := !pos + (upto - !start) + 2;
        start := upto + 2
      in
      let i = ref 0 in
      while !i < n do
        if t.(!i) = 0x0A && !i + 1 < n && t.(!i + 1) = 0x0A then (
          flush !i;
          i := !i + 2)
        else incr i
      done;
      flush n;
      List.rev !out
    in
    (* Greedy pack: consecutive pieces up to the mark. A hard-split piece is
       exactly the mark long, so it never shares a chunk. *)

    let pieces_a = Array.of_list pieces in
    let join_pieces from_i upto_i =
      let buf = Buffer.create 64 in
      for k = from_i to upto_i - 1 do
        if k > from_i then Buffer.add_string buf "\n\n";
        Buffer.add_string buf (Utf8.to_string (snd pieces_a.(k)))
      done;
      Buffer.contents buf
    in
    let chunk_of from_i upto_i = (fst pieces_a.(from_i), join_pieces from_i upto_i) in
    let chunks =
      let out = ref [] in
      let start_i = ref 0 and buf_chars = ref 0 in
      let count = Array.length pieces_a in
      for i = 0 to count - 1 do
        let plen = Array.length (snd pieces_a.(i)) in
        if i > !start_i && !buf_chars + plen + 2 > chunk_chars then (
          out := chunk_of !start_i i :: !out;
          start_i := i;
          buf_chars := 0);
        buf_chars := !buf_chars + plen + (if i > !start_i then 2 else 0)
      done;
      if !start_i < count then out := chunk_of !start_i count :: !out;
      List.rev !out
    in
    let scored =
      List.map
        (fun (offset, body) ->
          let folded = Utf8.ascii_lower (Utf8.of_string body) in
          let score =
            List.fold_left
              (fun acc tok -> if contains tok folded then acc + 1 else acc)
              0 tokens
          in
          (score, offset, body))
        chunks
    in
    let ranked =
      List.filter (fun (s, _, _) -> s > 0) scored
      |> List.sort (fun (s1, o1, _) (s2, o2, _) ->
             if s1 <> s2 then compare s2 s1 else compare o1 o2)
    in
    let selected =
      (* The first candidate that does not fit ends selection: no smaller one
         queue-jumps ahead of it. *)

      let rec take acc used = function
        | [] -> List.rev acc
        | (_, offset, body) :: rest ->
            if used + Utf8.count body + 2 > max_chars then List.rev acc
            else take ((offset, body) :: acc) (used + Utf8.count body + 2) rest
      in
      take [] 0 ranked
      (* Selected chunks are re-sorted by offset before merging, so the spans
         come back in document order. *)
      |> List.sort (fun (a, _) (b, _) -> compare a b)
    in
    if selected = [] then ([], List.length ranked)
    else
      let spans =
        let rec merge acc = function
          | [] -> List.rev acc
          | (offset, body) :: rest -> (
              match acc with
              | (poff, pbody) :: tl
                when offset = poff + Utf8.count pbody + 2 ->
                  (* Adjacent chunks sit exactly one "\n\n" apart; merging them
                     yields a contiguous span at the earlier offset, joiner
                     included. *)

                  merge ((poff, pbody ^ "\n\n" ^ body) :: tl) rest
              | _ -> merge ((offset, body) :: acc) rest)
        in
        merge [] selected
      in
      (spans, List.length ranked - List.length selected)
