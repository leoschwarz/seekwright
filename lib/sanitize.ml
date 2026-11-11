(* Escaping model special-token literals out of text that leaves the proxy.

   The Python oracle is [src/seekwright/sanitize.py]. The rule is content
   hygiene at the boundary: insert one U+200B after the opening delimiter of
   every token literal, so a tokenizer no longer parses it as structure while
   a reader still sees the text as written.

   The escape is reversible (dropping every U+200B restores the source),
   idempotent (escaped text no longer matches) and deterministic.

   The match set is deliberately tight: the two [<|...|>] shapes cover the
   ChatML / Qwen / GLM / Mistral / Phi / GPT-OSS / Llama-3 family (DeepSeek
   spells the same shape with U+FF5C FULLWIDTH VERTICAL LINE), and a short
   literal list covers the rest. [<s>]/[</s>], [<think>], comparisons and math
   (the spaces keep them out of the [<|] shape) and unterminated fragments like
   [<|endoftext] stay untouched. *)

let zwsp = "\xe2\x80\x8b"
(* U+200B ZERO WIDTH SPACE: the escape, and the only character escaping adds. *)

let text_fields = [ "title"; "snippet"; "text"; "answer" ]
(* The wire-model fields carrying provider-originated text. The caller's own
   strings ([query], [url]) stay out: escaping what the caller wrote would be a
   surprise. *)

let is_text_field name = List.mem name text_fields

let literal_tokens =
  [
    "<start_of_turn>";
    "<end_of_turn>";
    "[INST]";
    "[/INST]";
    "<<SYS>>";
    "<</SYS>>";
  ]

let escaped_literal marker =
  String.make 1 marker.[0] ^ zwsp
  ^ String.sub marker 1 (String.length marker - 1)

let escaped_literals = List.map escaped_literal literal_tokens

(* The next codepoint boundary. A malformed lead byte advances one byte, which
   keeps the scan total; valid UTF-8 never takes that branch. *)
let next_index s i =
  let len = String.length s in
  let c = Char.code s.[i] in
  if c < 0x80 then i + 1
  else if c land 0xe0 = 0xc0 then min len (i + 2)
  else if c land 0xf0 = 0xe0 then min len (i + 3)
  else if c land 0xf8 = 0xf0 then min len (i + 4)
  else i + 1

(* U+FF5C FULLWIDTH VERTICAL LINE in UTF-8. *)
let is_fullwidth_bar s j =
  j + 2 < String.length s
  && Char.code s.[j] = 0xef
  && Char.code s.[j + 1] = 0xbd
  && Char.code s.[j + 2] = 0x9c

(* [<\|[^<>|\n]{1,64}\|>], subn'd with one U+200B after the opening [<].

   The character class excludes ASCII delimiters only, so a fullwidth bar is
   ordinary content here -- exactly the Python pattern. Content is counted in
   codepoints, not bytes, so a multibyte token name has the same 64-ceiling. *)
let escape_angle_ascii s =
  let len = String.length s in
  let buf = Buffer.create (len + 16) in
  let count = ref 0 in
  let i = ref 0 in
  while !i < len do
    if s.[!i] = '<' && !i + 1 < len && s.[!i + 1] = '|' then begin
      let j = ref (!i + 2) in
      let points = ref 0 in
      let scanning = ref true in
      while !scanning && !j < len && !points < 64 do
        let c = s.[!j] in
        if c = '<' || c = '>' || c = '|' || c = '\n' then scanning := false
        else begin
          incr points;
          j := next_index s !j
        end
      done;
      if !points >= 1 && !j + 1 < len && s.[!j] = '|' && s.[!j + 1] = '>' then begin
        Buffer.add_char buf '<';
        Buffer.add_string buf zwsp;
        Buffer.add_substring buf s (!i + 1) (!j + 2 - (!i + 1));
        incr count;
        i := !j + 2
      end
      else begin
        Buffer.add_char buf s.[!i];
        incr i
      end
    end
    else begin
      Buffer.add_char buf s.[!i];
      incr i
    end
  done;
  (Buffer.contents buf, !count)

(* [<｜[^<>|｜\n]{1,64}｜>], the fullwidth spelling, same insertion rule. Both
   bars are excluded from the content class so the two shapes never overlap. *)
let escape_angle_fullwidth s =
  let len = String.length s in
  let buf = Buffer.create (len + 16) in
  let count = ref 0 in
  let i = ref 0 in
  while !i < len do
    if s.[!i] = '<' && is_fullwidth_bar s (!i + 1) then begin
      let j = ref (!i + 4) in
      let points = ref 0 in
      let scanning = ref true in
      while !scanning && !j < len && !points < 64 do
        let c = s.[!j] in
        if c = '<' || c = '>' || c = '|' || c = '\n' || is_fullwidth_bar s !j
        then scanning := false
        else begin
          incr points;
          j := next_index s !j
        end
      done;
      if !points >= 1 && is_fullwidth_bar s !j && !j + 3 < len && s.[!j + 3] = '>'
      then begin
        Buffer.add_char buf '<';
        Buffer.add_string buf zwsp;
        Buffer.add_substring buf s (!i + 1) (!j + 4 - (!i + 1));
        incr count;
        i := !j + 4
      end
      else begin
        Buffer.add_char buf s.[!i];
        incr i
      end
    end
    else begin
      Buffer.add_char buf s.[!i];
      incr i
    end
  done;
  (Buffer.contents buf, !count)

(* [str.replace]'s semantics: left to right, non-overlapping. *)
let replace_all ~pattern ~with_ text =
  let plen = String.length pattern in
  let len = String.length text in
  if plen = 0 then (text, 0)
  else begin
    let buf = Buffer.create (len + 16) in
    let count = ref 0 in
    let i = ref 0 in
    while !i <= len - plen do
      if String.sub text !i plen = pattern then begin
        Buffer.add_string buf with_;
        i := !i + plen;
        incr count
      end
      else begin
        Buffer.add_char buf text.[!i];
        incr i
      end
    done;
    if !i < len then Buffer.add_substring buf text !i (len - !i);
    (Buffer.contents buf, !count)
  end

let sanitize_text text =
  if (not (String.contains text '<')) && not (String.contains text '[') then
    (text, 0)
  else begin
    let text, ascii_count = escape_angle_ascii text in
    let text, fullwidth_count = escape_angle_fullwidth text in
    let text, literal_count =
      List.fold_left2
        (fun (text, total) marker escaped ->
          let text, n = replace_all ~pattern:marker ~with_:escaped text in
          (text, total + n))
        (text, 0) literal_tokens escaped_literals
    in
    (text, ascii_count + fullwidth_count + literal_count)
  end
