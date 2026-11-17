module E = Seekwright_fetch.Extractor
let extract = Seekwright_fetch.Extract_stdlib.backend.E.extract

type case = {
  id : string;
  file : string;
  content_type : string option;
  kind : string;
  category : string;
  essential : string list;
  boilerplate : string list;
  title : string option;
  title_rule : string;
  unicode : string list;
  expect : string;
  bar_essential_min : int;
  bar_boiler_max : int;
  bar_title_ok : bool;
  bar_unicode_ok : bool;
  bar_max_ms : int;
  body : string;
}

let read_whole path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let load_cases dir =
  let manifest = Yojson.Safe.from_file (Filename.concat dir "cases.json") in
  let dir_of = Filename.concat dir "fixtures" in
  match manifest with
  | `Assoc fields -> (
      match List.assoc_opt "cases" fields with
      | Some (`List rows) ->
          List.filter_map
            (fun (row : Yojson.Safe.t) ->
              match row with
              | `Assoc f -> (
                  let str key =
                    match List.assoc_opt key f with Some (`String s) -> Some s | _ -> None
                  in
                  let str_list key =
                    match List.assoc_opt key f with
                    | Some (`List xs) ->
                        List.filter_map (fun x -> match x with `String s -> Some s | _ -> None) xs
                    | _ -> []
                  in
                  let int key dflt =
                    match List.assoc_opt key f with Some (`Int n) -> n | _ -> dflt
                  in
                  let bool key dflt =
                    match List.assoc_opt key f with Some (`Bool b) -> b | _ -> dflt
                  in
                  match str "id" with
                  | Some id ->
                      let file = Option.value ~default:id (str "file") in
                      Some
                        {
                          id;
                          file;
                          content_type = str "content_type";
                          kind = Option.value ~default:"html" (str "kind");
                          category = Option.value ~default:"" (str "category");
                          essential = str_list "essential";
                          boilerplate = str_list "boilerplate";
                          title = str "title";
                          title_rule = Option.value ~default:"exact" (str "title_rule");
                          unicode = str_list "unicode";
                          expect = Option.value ~default:"text" (str "expect");
                          bar_essential_min = int "bar_essential_min" 0;
                          bar_boiler_max = int "bar_boiler_max" 0;
                          bar_title_ok = bool "bar_title_ok" false;
                          bar_unicode_ok = bool "bar_unicode_ok" false;
                          bar_max_ms = int "bar_max_ms" 400;
                          body = read_whole (Filename.concat dir_of file);
                        }
                  | None -> None)
              | _ -> None)
            rows
      | _ -> [])
  | _ -> []

let collapse s =
  let buf = Buffer.create (String.length s) in
  let prev_space = ref false in
  String.iter
    (fun ch ->
      match ch with
      | ' ' | '\t' | '\n' | '\r' | '\012' ->
          if not !prev_space then (
            Buffer.add_char buf ' ';
            prev_space := true)
      | _ ->
          Buffer.add_char buf ch;
          prev_space := false)
    s;
  String.trim (Buffer.contents buf)

let contains ~haystack ~needle =
  let h = collapse haystack and n = collapse needle in
  n = ""
  || String.length h >= String.length n
     &&
     let rec go i =
       i + String.length n > String.length h || String.sub h i (String.length n) = n || go (i + 1)
     in
     go 0

let misses ~haystack ~needles = List.filter (fun n -> not (contains ~haystack ~needle:n)) needles

let codepoints s =
  let n = ref 0 in
  let i = ref 0 in
  while !i < String.length s do
    let c = Char.code s.[!i] in
    i :=
      !i
      +
      if c < 0x80 then 1
      else if c < 0xC0 then 1
      else if c < 0xE0 then 2
      else if c < 0xF0 then 3
      else 4;
    incr n
  done;
  !n

let replacement_chars s =
  let n = ref 0 in
  let i = ref 0 in
  while !i < String.length s do
    if s.[!i] = '\xef' && !i + 2 < String.length s && s.[!i + 1] = '\xbf' && s.[!i + 2] = '\xbd'
    then (
      incr n;
      i := !i + 3)
    else incr i
  done;
  !n

let searchable text title = text ^ "\n" ^ Option.value ~default:"" title

type outcome = Text of { text : string; title : string option; chars : int } | Refusal of string

let run (c : case) =
  match extract c.body c.content_type with
  | r -> Text { text = r.E.text; title = r.E.title; chars = r.E.total_chars }
  | exception E.Extraction_failed msg -> Refusal msg

type metrics = {
  outcome : string;
  essential_hit : int;
  essential_total : int;
  boiler_hit : int;
  boiler_total : int;
  title_ok : bool;
  unicode_ok : bool;
  unicode_total : int;
  deterministic : bool;
  essential_missed : string list;
  boiler_missed : string list;
  boiler_leaked : string list;
  codepoints : int;
  replacements : int;
}

let count_hits ~haystack ~needles =
  List.length (List.filter (fun n -> contains ~haystack ~needle:n) needles)

let measure (c : case) =
  let first = run c in
  let second = run c in
  let deterministic =
    match (first, second) with
    | Text a, Text b -> a.text = b.text && a.title = b.title
    | Refusal x, Refusal y -> x = y
    | _ -> false
  in
  let outcome, text, title, cp =
    match first with
    | Text t -> ("text", t.text, t.title, codepoints t.text)
    | Refusal m -> ("refusal:" ^ m, "", None, 0)
  in
  let both = searchable text title in
  (* The title rule is what the case says about titles, and it is applied to
     whatever the backend answered — including no answer at all, which is how a
     refusal passes a case that expects no title and fails one that expects the
     document's own. [none] means the fixture has no <title> to find, so reporting
     none is the honest answer; [any] means any title will do; anything else
     compares the case's title over collapsed whitespace. *)
  let title_ok =
    match c.title_rule with
    | "none" -> title = None
    | "any" -> title <> None
    | _ -> ( match (title, c.title) with Some a, Some b -> collapse a = collapse b | _ -> false)
  in
  let refused = outcome <> "text" in
  let unicode_ok =
    if refused then c.unicode = []
    else List.for_all (fun u -> contains ~haystack:both ~needle:u) c.unicode
  in
  {
    outcome;
    essential_hit = count_hits ~haystack:both ~needles:c.essential;
    essential_total = List.length c.essential;
    boiler_hit = count_hits ~haystack:both ~needles:c.boilerplate;
    boiler_total = List.length c.boilerplate;
    title_ok;
    unicode_ok;
    unicode_total = List.length c.unicode;
    deterministic;
    essential_missed = misses ~haystack:both ~needles:c.essential;
    boiler_missed = misses ~haystack:both ~needles:c.boilerplate;
    boiler_leaked = List.filter (fun n -> contains ~haystack:both ~needle:n) c.boilerplate;
    codepoints = cp;
    replacements = replacement_chars text;
  }

let outcome_of m =
  if m.outcome <> "text" then "refusal" else if m.codepoints = 0 then "empty" else "text"

let bar_failures ~median_ms (c : case) (m : metrics) =
  let fails = ref [] in
  let add fmt = Printf.ksprintf (fun s -> fails := s :: !fails) fmt in
  if m.essential_hit < c.bar_essential_min then
    add "essential %d/%d under the bar of %d (missed: %s)" m.essential_hit m.essential_total
      c.bar_essential_min
      (String.concat " | " m.essential_missed);
  if m.boiler_hit > c.bar_boiler_max then
    add "boilerplate %d/%d over the bar of %d (leaked: %s)" m.boiler_hit m.boiler_total
      c.bar_boiler_max
      (String.concat " | " m.boiler_leaked);
  if m.title_ok <> c.bar_title_ok then add "title_ok %b, bar asks for %b" m.title_ok c.bar_title_ok;
  if m.unicode_total > 0 && m.unicode_ok <> c.bar_unicode_ok then
    add "unicode_ok %b, bar asks for %b" m.unicode_ok c.bar_unicode_ok;
  if not m.deterministic then add "the backend answered the same bytes twice";
  if median_ms > float_of_int c.bar_max_ms then
    add "median %.1fms over the ceiling of %dms" median_ms c.bar_max_ms;
  let got = outcome_of m in
  if got <> c.expect then add "outcome %s, bar asks for %s" got c.expect;
  List.rev !fails
