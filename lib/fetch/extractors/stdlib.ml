(* The extraction backend every install can build: the standard library,
   nothing else.

   Port of [src/seekwright/extractors/stdlib.py]. [fetch.enabled] is on by
   default, and a missing extraction backend costs the process, not a tool —
   without a backend whose dependencies this tree already carries, a default
   install would lose the server at startup. This is that backend: HTML through
   a hand-written [html.parser] port, JSON through [Jsondoc], tables through
   [Tabledoc], plain text passed through.

   No parity with a content-extraction library is claimed here either: it drops
   the elements {!skip_tags} names and keeps the rest, so the chrome that
   survives is the chrome outside those elements, and a page whose answer sits
   inside a [<form>] loses it with the element. A JS-rendered shell returns its
   chrome, so [fetch.min_text_chars] turns such a page into a refusal.

   PDF is absent from the type set by rule, not by gap: there is no PDF reader
   in this port, and the contract requires a backend to claim only what it can
   read. The fetcher therefore refuses a PDF by name before spending the body. *)

module E = Seekwright_fetch.Extractor
module J = Seekwright_fetch.Jsondoc
module T = Seekwright_fetch.Tabledoc
module U = Seekwright_fetch.Utf8

(* Never the answer: what a browser executes or draws, and the sectioning
   elements whose job is the furniture around the content. *)

let skip_tags =
  [
    "script"; "style"; "noscript"; "template"; "svg"; "math"; "canvas"; "nav";
    "header"; "footer"; "aside"; "form"; "fieldset"; "select"; "option";
    "button";
  ]

(* A graphic names itself with the same element a document uses, and that name
   is never the page's. Its own counter, not a read of the skip stack: a sprite
   nests [<svg>] inside [<svg>], and the icon labels must stay graphic-internal. *)

let graphic_tags = [ "svg"; "math" ]

(* Elements that break a line the way a paragraph does, so adjacent blocks never
   merge into one sentence. [pre] rides with them: [normalise] collapses space
   runs anyway, so preserving its layout here would promise what the plumbing
   does not deliver. *)

let block_tags =
  [
    "p"; "div"; "section"; "article"; "main"; "figure"; "figcaption";
    "blockquote"; "pre"; "h1"; "h2"; "h3"; "h4"; "h5"; "h6"; "ul"; "ol"; "dl";
    "table"; "thead"; "tbody"; "tfoot"; "tr"; "caption"; "details"; "summary";
    "address"; "hr"; "body";
  ]

(* A table cell needs a word boundary between values; a row does not, since
   [tr] is already in the block set and a row break reads as a new line. *)

let cell_tags = [ "td"; "th"; "dt"; "dd" ]

(* {1 Character references} *)

(* The subset of [html.entities.html5] this backend carries, with the bare
   no-semicolon forms the standard still accepts — the legacy set — marked
   separately from the ones that require the semicolon. A reference outside
   the table stays in the text exactly as written, which is what the original
   does with a name it does not know. *)

let legacy_entities =
  [
    ("amp", 38); ("lt", 60); ("gt", 62); ("quot", 34); ("nbsp", 160);
    ("iexcl", 161); ("cent", 162); ("pound", 163); ("curren", 164); ("yen", 165);
    ("brvbar", 166); ("sect", 167); ("uml", 168); ("copy", 169); ("ordf", 170);
    ("laquo", 171); ("not", 172); ("shy", 173); ("reg", 174); ("macr", 175);
    ("deg", 176); ("plusmn", 177); ("sup2", 178); ("sup3", 179); ("acute", 180);
    ("micro", 181); ("para", 182); ("middot", 183); ("cedil", 184); ("sup1", 185);
    ("ordm", 186); ("raquo", 187); ("frac14", 188); ("frac12", 189);
    ("frac34", 190); ("iquest", 191); ("times", 215); ("divide", 247);
    ("Agrave", 192); ("Aacute", 193); ("Acirc", 194); ("Atilde", 195);
    ("Auml", 196); ("Aring", 197); ("AElig", 198); ("Ccedil", 199);
    ("Egrave", 200); ("Eacute", 201); ("Ecirc", 202); ("Euml", 203);
    ("Igrave", 204); ("Iacute", 205); ("Icirc", 206); ("Iuml", 207);
    ("ETH", 208); ("Ntilde", 209); ("Ograve", 210); ("Oacute", 211);
    ("Ocirc", 212); ("Otilde", 213); ("Ouml", 214); ("Oslash", 216);
    ("Ugrave", 217); ("Uacute", 218); ("Ucirc", 219); ("Uuml", 220);
    ("Yacute", 221); ("THORN", 222); ("szlig", 223); ("agrave", 224);
    ("aacute", 225); ("acirc", 226); ("atilde", 227); ("auml", 228);
    ("aring", 229); ("aelig", 230); ("ccedil", 231); ("egrave", 232);
    ("eacute", 233); ("ecirc", 234); ("euml", 235); ("igrave", 236);
    ("iacute", 237); ("icirc", 238); ("iuml", 239); ("ntilde", 241);
    ("ograve", 242); ("oacute", 243); ("ocirc", 244); ("otilde", 245);
    ("ouml", 246); ("oslash", 248); ("ugrave", 249); ("uacute", 250);
    ("ucirc", 251); ("uuml", 252); ("yacute", 253); ("yuml", 255);
  ]

let extended_entities =
  [
    ("ensp", 8194); ("emsp", 8195); ("thinsp", 8201); ("zwnj", 8204);
    ("zwj", 8205); ("lrm", 8206); ("rlm", 8207); ("ndash", 8211);
    ("mdash", 8212); ("lsquo", 8216); ("rsquo", 8217); ("sbquo", 8218);
    ("ldquo", 8220); ("rdquo", 8221); ("bdquo", 8222); ("dagger", 8224);
    ("Dagger", 8225); ("bull", 8226); ("hellip", 8230); ("permil", 8240);
    ("prime", 8242); ("Prime", 8243); ("lsaquo", 8249); ("rsaquo", 8250);
    ("oline", 8254); ("frasl", 8260); ("euro", 8364); ("trade", 8482);
    ("OElig", 338); ("oelig", 339); ("Scaron", 352); ("scaron", 353);
    ("Yuml", 376); ("fnof", 402); ("minus", 8722); ("lowast", 8727);
    ("radic", 8730); ("prop", 8733); ("infin", 8734); ("ang", 8736);
    ("and", 8743); ("or", 8744); ("cap", 8745); ("cup", 8746); ("int", 8747);
    ("there4", 8756); ("sim", 8764); ("cong", 8773); ("asymp", 8776);
    ("ne", 8800); ("equiv", 8801); ("le", 8804); ("ge", 8805); ("sub", 8834);
    ("sup", 8835); ("nsub", 8836); ("sube", 8838); ("supe", 8839);
    ("oplus", 8853); ("otimes", 8855); ("perp", 8869); ("sdot", 8901);
    ("lceil", 8968); ("rceil", 8969); ("lfloor", 8970); ("rfloor", 8971);
    ("loz", 9674); ("spades", 9824); ("clubs", 9827); ("hearts", 9829);
    ("diams", 9830);
    (* The uppercase forms the table carries — semicolon required, as in
       [html.entities.html5]. *)

    ("AMP", 38); ("LT", 60); ("GT", 62); ("QUOT", 34); ("COPY", 169);
    ("REG", 174); ("TRADE", 8482);
  ]

let entity_table : (string * int) list =
  List.concat_map
    (fun (name, cp) -> [ (name ^ ";", cp); (name, cp) ])
    legacy_entities
  @ List.map (fun (name, cp) -> (name ^ ";", cp)) extended_entities

(* The numeric-reference remap: the defined Windows-1252 specials come through
   that table, the five bytes it leaves undefined stay raw, and [0], a
   surrogate and anything past the range are U+FFFD — the [html.unescape]
   behaviour, pinned against the Python oracle. *)

let windows_1252_special (b : int) : int =
  match b with
  | 0x80 -> 0x20AC (* € *)

  | 0x82 -> 0x201A
  | 0x83 -> 0x0192
  | 0x84 -> 0x201E
  | 0x85 -> 0x2026
  | 0x86 -> 0x2020
  | 0x87 -> 0x2021
  | 0x88 -> 0x02C6
  | 0x89 -> 0x2030
  | 0x8A -> 0x0160
  | 0x8B -> 0x2039
  | 0x8C -> 0x0152
  | 0x8E -> 0x017D
  | 0x91 -> 0x2018
  | 0x92 -> 0x2019
  | 0x93 -> 0x201C
  | 0x94 -> 0x201D
  | 0x95 -> 0x2022
  | 0x96 -> 0x2013
  | 0x97 -> 0x2014
  | 0x98 -> 0x02DC
  | 0x99 -> 0x2122
  | 0x9A -> 0x0161
  | 0x9B -> 0x203A
  | 0x9C -> 0x0153
  | 0x9E -> 0x017E
  | 0x9F -> 0x0178
  | _ -> b

let numeric_ref (n : int) : string =
  if n = 0 || (n >= 0xD800 && n <= 0xDFFF) || n > 0x10FFFF then U.encode 0xFFFD
  else if n >= 0x80 && n <= 0x9F then
    (* The HTML5 rule: the Windows-1252 table, and the five bytes it leaves
       undefined are U+FFFD. *)

    if List.mem n [ 0x81; 0x8D; 0x8F; 0x90; 0x9D ] then U.encode 0xFFFD
    else U.encode (windows_1252_special n)
  else U.encode n

(* One character reference, read from [s] at its [&] and replaced: returns
   [(replacement, end_index)] when the reference is one this backend knows —
   the caller substitutes and continues at [end_index] — and [None] when it is
   not, in which case the [&] stays in the text and the scan moves on by one
   character. The shape is Python's [html.unescape]: a numeric reference is
   read strictly, a named one is looked up whole and then by its longest
   prefix in the table, the search stopping above a single character, and a
   name-run is at most 32 characters long. *)

let charref_at (s : string) (amp : int) : (string * int) option =
  let n = String.length s in
  let is_run_char c =
    not
      (String.contains "\t\n\012 <&#;" c)
  in
  let name_run i =
    let j = ref i in
    while !j < n && !j - i < 32 && is_run_char s.[!j] do
      incr j
    done;
    !j
  in
  if amp + 1 >= n then None
  else if s.[amp + 1] = '#' then
    (* Numeric: [#[0-9]+;?] or [#[xX][0-9a-fA-F]+;?], with [;] consumed when it
       follows. A malformed one leaves the whole text as it was, the [&]
       included, and the scan re-reads the [#] as plain data — the same thing
       the regex's failure to match does. *)

    let digits_from i hex =
      let j = ref i in
      while
        !j < n
        && (match s.[!j] with
           | '0' .. '9' -> true
           | 'a' .. 'f' | 'A' .. 'F' -> hex
           | _ -> false)
      do
        incr j
      done;
      !j
    in
    let value =
      if amp + 2 < n && (s.[amp + 2] = 'x' || s.[amp + 2] = 'X') then
        let stop = digits_from (amp + 3) true in
        let width = stop - (amp + 3) in
        if width = 0 then None
        else
          let v = int_of_string_opt ("0x" ^ String.sub s (amp + 3) width) in
          let semi = stop < n && s.[stop] = ';' in
          Some (v, stop + if semi then 1 else 0)
      else
        let stop = digits_from (amp + 2) false in
        let width = stop - (amp + 2) in
        if width = 0 then None
        else
          let v = int_of_string_opt (String.sub s (amp + 2) width) in
          let semi = stop < n && s.[stop] = ';' in
          Some (v, stop + if semi then 1 else 0)
    in
    match value with
    | Some (Some v, end_i) -> Some (numeric_ref v, end_i)
    | _ -> None
  else
    let stop = name_run (amp + 1) in
    if stop = amp + 1 then None
    else
      let with_semi = stop < n && s.[stop] = ';' in
      let name = String.sub s (amp + 1) (stop - (amp + 1)) in
      let whole = if with_semi then name ^ ";" else name in
      let lookup key = List.assoc_opt key entity_table in
      match lookup whole with
      | Some cp -> Some (U.encode cp, stop + if with_semi then 1 else 0)
      | None -> (
          (* Longest prefix, tried from the length below the whole name down to
             two characters — never the full name twice, never a single
             character. *)

          let len = String.length whole in
          let rec try_prefix x =
            if x < 2 then None
            else
              match lookup (String.sub whole 0 x) with
              | Some cp -> Some (cp, x)
              | None -> try_prefix (x - 1)
          in
          match try_prefix (len - 1) with
          | Some (cp, x) ->
              Some
                ( U.encode cp ^ String.sub whole x (len - x),
                  stop + if with_semi then 1 else 0 )
          | None -> None)

(* [convert_charrefs] over one data run: every reference in the text is
   replaced, and an [&] that starts nothing known stays. *)

let convert (s : string) : string =
  if String.contains s '&' then
    let buf = Buffer.create (String.length s) in
    let n = String.length s in
    let i = ref 0 in
    while !i < n do
      if s.[!i] = '&' then
        match charref_at s !i with
        | Some (value, end_i) ->
            Buffer.add_string buf value;
            i := end_i
        | None ->
            Buffer.add_char buf '&';
            incr i
      else (
        Buffer.add_char buf s.[!i];
        incr i)
    done;
    Buffer.contents buf
  else s

(* {1 The tokenizer} *)

(* A hand-written port of the [html.parser] events this backend consumes:
   start/end/start-end tags and data runs. Tag names are lowercased, attribute
   values are skipped (quoted, so a [>] inside one does not end the tag), and
   a [<] that opens nothing is data — [html.parser] is lenient about unbalanced
   markup, and a page with such markup is normal. [script] and [style] switch
   the tokenizer to raw mode, the way the original's CDATA mode does, so a [<]
   inside a script is not parsed as a tag. *)

type event =
  | Start of string
  | End of string
  | Start_end of string
  | Data of string

let is_tag_start c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

let ascii_lower_char c =
  if c >= 'A' && c <= 'Z' then Char.chr (Char.code c + 32) else c

let tag_name s i =
  (* [a-zA-Z][^\t\n\r\f />]* — the original's tagfind, lowercased. *)

  let n = String.length s in
  let j = ref (i + 1) in
  while
    !j < n
    && (match s.[!j] with
       | '\t' | '\n' | '\r' | '\012' | '\ ' | '/' | '>' -> false
       | _ -> true)
  do
    incr j
  done;
  let raw = String.sub s i (!j - i) in
  (String.map ascii_lower_char raw, !j)

(* Skip an attribute run to the tag's closing [>], honouring quoted values; a
   [/>] immediately before the [>] marks a self-closing tag. *)

let scan_tag_end s i =
  let n = String.length s in
  let j = ref i in
  let quote = ref '\000' in
  let self_closing = ref false in
  (try
     while !j < n do
       let c = s.[!j] in
       if !quote <> '\000' then (
         if c = !quote then quote := '\000';
         incr j)
       else
         match c with
         | '"' | '\'' ->
             quote := c;
             incr j
         | '>' -> j := !j + 1; raise Exit
         | '/' when !j + 1 < n && s.[!j + 1] = '>' ->
             self_closing := true;
             j := !j + 2;
             raise Exit
         | _ -> incr j
     done
   with Exit -> ());
  (!j, !self_closing)

let find_sub_ignore_case s needle from =
  let n = String.length s and m = String.length needle in
  let lower = String.map ascii_lower_char s in
  let rec go i =
    if i + m > n then None
    else if String.sub lower i m = needle then Some i
    else go (i + 1)
  in
  go from

let tokenize (s : string) : event list =
  let n = String.length s in
  let out = ref [] in
  let emit e = out := e :: !out in
  let rec go i =
    if i >= n then ()
    else if s.[i] <> '<' then begin
      (* A data run up to the next [<]. *)

      let j = ref i in
      while !j < n && s.[!j] <> '<' do
        incr j
      done;
      emit (Data (convert (String.sub s i (!j - i))));
      go !j
    end
    else if i + 1 >= n then begin
      emit (Data (convert "<"));
      go (i + 1)
    end
    else
      match s.[i + 1] with
      | '!' -> (
          if String.length s >= i + 4 && String.sub s i 4 = "<!--" then
            (* A comment never reaches [handle_data]. *)

            match find_sub_ignore_case s "-->" (i + 4) with
            | Some e -> go (e + 3)
            | None -> go n
          else
            (* A declaration ([<!DOCTYPE ...>]) or a marked section: skipped
               to its [>]. *)

            let j = ref (i + 2) in
            while !j < n && s.[!j] <> '>' do
              incr j
            done;
            go (if !j < n then !j + 1 else n))
      | '?' ->
          (* A processing instruction. *)

          let j = ref (i + 2) in
          while !j < n && s.[!j] <> '>' do
            incr j
          done;
          go (if !j < n then !j + 1 else n)
      | '/' -> (
          if i + 2 < n && is_tag_start s.[i + 2] then
            let name, j = tag_name s (i + 2) in
            let end_, _ = scan_tag_end s j in
            emit (End name);
            go end_
          else if i + 2 < n && s.[i + 2] = '>' then go (i + 3)
          else begin
            emit (Data (convert "<"));
            go (i + 1)
          end)
      | c when is_tag_start c ->
          let name, j = tag_name s (i + 1) in
          let end_, self_closing = scan_tag_end s j in
          emit (if self_closing then Start_end name else Start name);
          (* [script]/[style] are CDATA elements in the original: their content
             is raw text up to the matching end tag, never parsed for tags. *)

          if (not self_closing) && (name = "script" || name = "style") then
            let close = find_sub_ignore_case s ("</" ^ name) end_ in
            match close with
            | Some cpos ->
                emit (Data (String.sub s end_ (cpos - end_)));
                let _, j' = tag_name s (cpos + 2) in
                let end2, _ = scan_tag_end s j' in
                emit (End name);
                go end2
            | None ->
                emit (Data (String.sub s end_ (n - end_)));
                go n
          else go end_
      | _ ->
          emit (Data (convert "<"));
          go (i + 1)
  in
  go 0;
  List.rev !out

(* {1 The visible-text parser} *)

(* Port of [_VisibleTextParser]: the visible text of a document in document
   order, plus its title. *)

type parser = {
  mutable chunks : string list;
  mutable title : string option;
  mutable skipping : string list;
  mutable graphics : int;
  mutable title_parts : string list;
  mutable in_title : bool;
}

let separator p tag ~closing =
  if tag = "br" then begin
    (* One break for one [<br>]: the XML form arrives as an open and a
       close in a single event, and two breaks read as a paragraph break. *)
    if not closing then p.chunks <- "\n" :: p.chunks
  end
  else if tag = "li" then begin
    (* The marker opens an item, and its end needs nothing: the next item
       opens with a line break of its own, and the list closes with one. *)
    if not closing then p.chunks <- "\n- " :: p.chunks
  end
  else if List.mem tag cell_tags then begin
    (* A word boundary *between* two values: the row's own break already
       ends the line, so the cell that opens a row adds no leading space. *)
    if
      (not closing)
      && p.chunks <> []
      && not (String.ends_with ~suffix:"\n" (List.hd p.chunks))
    then p.chunks <- " " :: p.chunks
  end
  else if List.mem tag block_tags then p.chunks <- "\n\n" :: p.chunks

let handle_starttag p tag =
  if List.mem tag graphic_tags then p.graphics <- p.graphics + 1;
  if tag = "title" then begin
    (* A [<title>] inside skipped markup or a graphic is a tooltip, not the
       document's name. *)

    p.in_title <- (p.skipping = [] && p.graphics = 0);
    if p.in_title then p.title_parts <- []
  end
  else if List.mem tag skip_tags then p.skipping <- tag :: p.skipping
  else if p.skipping = [] then separator p tag ~closing:false

let handle_endtag p tag =
  if List.mem tag graphic_tags && p.graphics > 0 then p.graphics <- p.graphics - 1;
  if tag = "title" then begin
    if p.in_title && p.title_parts <> [] && p.title = None then
      (* A page repeats the element: the first is the document's name, the
         ones an icon sprite adds are graphic labels. *)

      let joined = String.concat "" (List.rev p.title_parts) in
      let stripped = String.trim joined in
      p.title <- (if stripped = "" then None else Some stripped)
    else if p.in_title && p.title_parts = [] then ();
    p.in_title <- false
  end
  else if List.mem tag skip_tags && List.mem tag p.skipping then
    (* An end tag closes the innermost element of that name and everything
       opened inside it: markup ends a [<nav>] without closing its [<div>].
       Innermost, because clearing from the outer [<svg>] of a sprite hands
       every later icon title to the caller as page text. *)

    let rec drop depth =
      if depth < 0 then ()
      else if List.nth p.skipping depth = tag then
        p.skipping <- List.filteri (fun i _ -> i < depth) p.skipping
      else drop (depth - 1)
    in
    drop (List.length p.skipping - 1)
  else if p.skipping = [] then separator p tag ~closing:true

let handle_data p data =
  if p.in_title then p.title_parts <- data :: p.title_parts
  else if p.skipping = [] && data <> "" then p.chunks <- data :: p.chunks

let from_html (html : string) : string * string option =
  (* The document's visible text and its [<title>], or [None] when it has
     none. *)

  let p =
    {
      chunks = [];
      title = None;
      skipping = [];
      graphics = 0;
      title_parts = [];
      in_title = false;
    }
  in
  List.iter
    (fun e ->
      match e with
      | Start tag -> handle_starttag p tag
      | End tag -> handle_endtag p tag
      | Start_end tag ->
          (* [<br/>] asks for a line break with no end tag to follow, so the
             pair is one call rather than two that a self-closing element
             never completes. *)

          handle_starttag p tag;
          handle_endtag p tag
      | Data d -> handle_data p d)
    (tokenize html);
  (* Indented markup leaves lines holding nothing but spaces. [normalise] caps
     blank-line runs but cannot see a line that *holds* whitespace, so those are
     emptied here rather than reaching a caller as a paragraph break. *)

  let chunks = String.concat "" (List.rev p.chunks) in
  let lines = String.split_on_char '\n' chunks in
  (* An empty [<li>] — a spacer, an icon — earns no bullet: it becomes a blank
     line, and [normalise] collapses the run. *)

  let lines =
    List.map
      (fun line ->
        let stripped = String.trim line in
        if stripped <> "" && stripped <> "-" then line else "")
      lines
  in
  (String.concat "\n" lines, p.title)

(* {1 The backend} *)

let name = "stdlib"

(* No PDF, and the contract makes that claim in the type set rather than in
   prose: a backend lists only what its [extract] can read, so the fetcher turns
   a PDF into a named refusal instead of spending a download on it. *)

let supported_types = E.html_types @ E.text_types @ E.json_types @ E.table_types

let extract (body : string) (content_type : string option) : E.extract_result =
  (* The media type decides the reader; a missing one is sniffed as HTML or
     JSON only when the bytes look like one of them, so an unknown binary is
     refused rather than fed to the parser to produce nothing. A table type is
     never guessed at: a delimited line reads as prose. *)

  let kind = E.media_type content_type in
  if J.is_json_media kind || (kind = "" && J.sniffs_json body) then
    E.json_extraction (E.decode body content_type)
  else if T.is_table_media kind then
    E.table_extraction (E.decode body content_type) kind
  else if List.mem kind E.html_types || (kind = "" && E.sniffs_html body) then
    let text, title = from_html (E.decode body content_type) in
    E.normalise text title
  else if List.mem kind E.text_types then E.normalise (E.decode body content_type) None
  else
    (* A PDF included: this backend claims no PDF type, so the fetcher normally
       refuses one before the body is downloaded, and reaching here means a
       caller built the backend by hand. *)

    raise (E.Extraction_failed (if kind = "" then "unknown content type" else kind))
