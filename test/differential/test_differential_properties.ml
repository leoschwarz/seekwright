(** Deterministic property runs over the surfaces the corpus pins.

    The corpus is an enumeration: a human chose each case, and a golden pins the
    answer. Properties are the other half of the same claim. A case list can only
    say what someone thought of; a property says what must hold for every input
    the generator can make, and the generator is what makes a malformed byte, a
    lone CR or a past-the-end offset show up without anyone predicting it.

    Two constraints shape everything here:

    - {b Deterministic.} A property that fails only on the seed the gate happened
      to draw is a flaky gate, so the seed is a constant in this file and each
      property gets its own [Random.State] built from it. [QCHECK_SEED],
      [QCHECK_COUNT] and [QCHECK_LONG] are bypassed by passing [~rand], [~count]
      and [~long] explicitly — the environment a developer happens to have cannot
      change what the gate ran.
    - {b Hermetic.} No fixture file, no Python, no clock, no network. The
      generators build their inputs, the properties call the port, and a failure
      prints the counterexample QCheck shrank to.

    QCheck ([qcheck-core] and [qcheck-alcotest], two packages, about 5 MB
    installed, BSD-2-Clause, no new transitive dependency) is used rather than a
    hand-rolled loop: the only work left for a framework here is generation and
    shrinking, and writing those is how a test suite grows a second, worse one.
    The dependency decision and its cost are recorded in [README.md] and in the
    port plan (F3.3). *)

module Jsondoc = Seekwright_fetch.Jsondoc
module Tabledoc = Seekwright_fetch.Tabledoc
module Fetcher = Seekwright_fetch.Fetcher
module Sanitize = Seekwright.Sanitize
module Utf8 = Seekwright_text.Utf8

let seed = 20261113

(* One property: a fresh state per test, so the stream one property draws does
   not depend on which properties ran before it. [salt] is the only thing that
   differs between them and it is a literal, not a clock. *)
let check ~salt ?(count = 200) name gen prop =
  QCheck_alcotest.to_alcotest ~speed_level:`Quick
    ~rand:(Random.State.make [| seed; salt |])
    (QCheck2.Test.make ~count ~name gen prop)

(* {1 Generators} *)

(* Arbitrary bytes: what a scraped page, a truncated download or a caller's
   hand-encoded token can actually hand the walk. *)
let bytes = QCheck2.Gen.string_size ~gen:QCheck2.Gen.char QCheck2.Gen.(int_range 0 24)

(* Bytes drawn from the shapes the walk treats specially, mixed with ordinary
   text: a lead byte whose continuation never comes, an overlong pair, a
   surrogate encoding, a five-byte lead, and the special-token literal the
   sanitizer exists for. Uniform bytes reach these eventually; this generator
   reaches them every run, which is what makes a regression found by a seed
   repeatable. *)
let awkward_bytes =
  let piece =
    QCheck2.Gen.oneof_list
      [
        "\xe2";
        "\xf0\x9f";
        "\xc0\xaf";
        "\xed\xa0\x80";
        "\x80";
        "\xf8";
        "a";
        "\xc3\xa9";
        "\xf0\x9f\x98\x80";
        "<|endoftext|>";
        "<|im_start|>";
        "\xe2\x80\x8b";
      ]
  in
  QCheck2.Gen.map (String.concat "") (QCheck2.Gen.list_size QCheck2.Gen.(int_range 0 8) piece)

(* A codepoint the UTF-8 encoder emits: surrogates excluded, because Python's
   [utf-8] cannot decode one either and the point is a sequence both trees
   accept. *)
let codepoint =
  QCheck2.Gen.oneof [ QCheck2.Gen.int_range 0x00 0xd7ff; QCheck2.Gen.int_range 0xe000 0x10ffff ]

let valid_text =
  QCheck2.Gen.map
    (fun cps -> Utf8.to_string (Array.of_list cps))
    (QCheck2.Gen.list_size QCheck2.Gen.(int_range 0 12) codepoint)

(* A word with no delimiter, no quote and no newline, so it can be a CSV cell, a
   JSON key or a JSON string without the generator having to quote anything. *)
let word =
  let char = QCheck2.Gen.oneof_list (List.of_seq (String.to_seq "abcXYZ019._-")) in
  QCheck2.Gen.string_size ~gen:char QCheck2.Gen.(int_range 0 4)

(* A key may hold a single space, which is exactly what [child_path]'s quoting is
   for; it never holds two in a row, which is what keeps {!split_label}'s reading
   of a rendered line unambiguous. *)
let key = QCheck2.Gen.map (String.concat " ") (QCheck2.Gen.list_size QCheck2.Gen.(int_range 0 2) word)

let rec json ~depth =
  let leaf =
    QCheck2.Gen.oneof
      [
        QCheck2.Gen.return `Null;
        QCheck2.Gen.map (fun b -> `Bool b) QCheck2.Gen.bool;
        QCheck2.Gen.map (fun i -> `Int i) QCheck2.Gen.(int_range (-1000) 1000);
        QCheck2.Gen.map (fun i -> `Float (float_of_int i /. 4.)) QCheck2.Gen.(int_range (-100) 100);
        QCheck2.Gen.map (fun s -> `String s) word;
      ]
  in
  if depth <= 0 then leaf
  else
    QCheck2.Gen.oneof
      [
        leaf;
        QCheck2.Gen.map
          (fun members -> `Assoc members)
          (QCheck2.Gen.list_size QCheck2.Gen.(int_range 0 3)
             (QCheck2.Gen.pair key (json ~depth:(depth - 1))));
        QCheck2.Gen.map
          (fun items -> `List items)
          (QCheck2.Gen.list_size QCheck2.Gen.(int_range 0 3) (json ~depth:(depth - 1)));
      ]

(* A table with a unique, non-empty column name per position ([c<i>_<word>]), so
   a cell's path names exactly one cell and the round trip below is exact even
   when the words repeat. Rows are generated at the widest header and cut to the
   header's width, which is what [render_table] does on the port side. *)
let table =
  QCheck2.Gen.map
    (fun (width, (header_words, rows)) ->
      let header =
        List.init width (fun i ->
            Printf.sprintf "c%d_%s" i
              (match List.nth_opt header_words i with Some w -> w | None -> ""))
      in
      let rows =
        List.map
          (fun cells ->
            (* A row whose first cell is empty and whose width is one would be an
               empty line, which the CSV reader skips as a record of no cells —
               a shape [render_table] handles but which would break the
               index-equals-row-number reading below. So a row always has a
               non-empty first cell; the rest are free. *)
            let cells = List.mapi (fun i c -> if i = 0 && c = "" then "r" else c) cells in
            let cells = if cells = [] then [ "r" ] else cells in
            List.filteri (fun i _ -> i < width) cells)
          rows
      in
      (header, rows))
    (QCheck2.Gen.pair QCheck2.Gen.(int_range 1 3)
       (QCheck2.Gen.pair
          (QCheck2.Gen.list_size (QCheck2.Gen.int_range 0 3) word)
          (QCheck2.Gen.list_size (QCheck2.Gen.int_range 0 3)
             (QCheck2.Gen.list_size (QCheck2.Gen.int_range 0 3) word))))

(* {1 Reading a rendered line} *)

(* A rendering line is ["<path>  <value>"] with the two spaces as the separator;
   no path this module generates carries two spaces in a row, so the first pair
   is the separator. *)
let split_label line =
  let n = String.length line in
  let rec scan i =
    if i + 1 >= n then (line, "")
    else if line.[i] = ' ' && line.[i + 1] = ' ' then
      (String.sub line 0 i, String.sub line (i + 2) (n - i - 2))
    else scan (i + 1)
  in
  scan 0

let label_parses line =
  let label, _ = split_label line in
  match Jsondoc.parse_path label with
  | _ -> true
  | exception Jsondoc.Path_syntax _ -> false

let every_label_parses rendered = List.for_all label_parses (String.split_on_char '\n' rendered)

let remove_zwsp text =
  let zwsp = Sanitize.zwsp in
  let buffer = Buffer.create (String.length text) in
  let index = ref 0 in
  while !index < String.length text do
    if !index + String.length zwsp <= String.length text
       && String.sub text !index (String.length zwsp) = zwsp
    then index := !index + String.length zwsp
    else begin
      Buffer.add_char buffer text.[!index];
      incr index
    end
  done;
  Buffer.contents buffer

(* {1 Properties} *)

let sanitize_properties =
  let idempotent =
    check ~salt:1 "escaping twice changes nothing" awkward_bytes (fun text ->
        let once, count = Sanitize.sanitize_text text in
        let twice, again = Sanitize.sanitize_text once in
        once = twice && again = 0 && count >= 0)
  in
  let reversible =
    check ~salt:2 "removing the inserted zero-width spaces gives the input back" awkward_bytes
      (fun text ->
        let escaped, _ = Sanitize.sanitize_text text in
        (* [remove_zwsp] cannot tell an inserted zero-width space from one the
           caller wrote, so the statement is the honest one: the pass adds
           nothing that survives the removal. An input that already holds a
           U+200B therefore compares equal on both sides. *)
        remove_zwsp escaped = remove_zwsp text)
  in
  [ idempotent; reversible ]

let utf8_properties =
  let slices_partition =
    check ~salt:3 "the codepoint slices are the input, in order" bytes (fun text ->
        let slices = Utf8.slices text in
        String.concat "" (Array.to_list slices) = text && Utf8.count text = Array.length slices)
  in
  let round_trip =
    check ~salt:4 "decoding then encoding valid text is the identity" valid_text (fun text ->
        Utf8.to_string (Utf8.of_string text) = text
        && Utf8.count text = Array.length (Utf8.of_string text))
  in
  let take_is_a_prefix =
    check ~salt:5 "take keeps a prefix and counts what it kept"
      (QCheck2.Gen.pair valid_text QCheck2.Gen.(int_range 0 13))
      (fun (text, limit) ->
        let total = Utf8.count text in
        let kept = Utf8.take limit text in
        let is_prefix =
          String.length kept <= String.length text
          && String.sub text 0 (String.length kept) = kept
        in
        is_prefix && Utf8.count kept = min limit total)
  in
  let strip_is_idempotent =
    check ~salt:6 "strip reaches a fixed point on any bytes" awkward_bytes (fun text ->
        Utf8.strip (Utf8.strip text) = Utf8.strip text
        && Utf8.split_whitespace (Utf8.strip text) = Utf8.split_whitespace text)
  in
  [ slices_partition; round_trip; take_is_a_prefix; strip_is_idempotent ]

let window_properties =
  let marker = "\n\n[...]" in
  let strip_marker window =
    let n = String.length window and m = String.length marker in
    if n >= m && String.sub window (n - m) m = marker then String.sub window 0 (n - m) else window
  in
  let flags_agree =
    check ~salt:7 "a window is a prefix of the extraction"
      (QCheck2.Gen.pair valid_text
         (QCheck2.Gen.pair QCheck2.Gen.(int_range 0 16) QCheck2.Gen.(int_range 0 12)))
      (fun (text, (offset, max_chars)) ->
        let total = Utf8.count text in
        let offset = offset mod (total + 3) in
        let window, more = Fetcher.window_text text ~offset ~max_chars in
        let rest =
          Utf8.to_string
            (Array.sub (Utf8.of_string text) (min offset total) (total - min offset total))
        in
        let body = strip_marker window in
        let is_prefix =
          String.length body <= String.length rest && String.sub rest 0 (String.length body) = body
        in
        let marker_only_when_more = window = body || more in
        let whole_when_not_more = more || window = rest in
        is_prefix && marker_only_when_more && whole_when_not_more)
  in
  let past_the_end_is_empty =
    check ~salt:8 "an offset past the end is empty text with a truthful flag" valid_text (fun text ->
        let total = Utf8.count text in
        let window, more = Fetcher.window_text text ~offset:(total + 5) ~max_chars:10 in
        window = "" && more)
  in
  let uncapped_is_whole =
    check ~salt:9 "an uncapped window is the extraction itself" valid_text (fun text ->
        Fetcher.window_text text ~offset:0 ~max_chars:Fetcher.uncapped = (text, false))
  in
  [ flags_agree; past_the_end_is_empty; uncapped_is_whole ]

let jsondoc_properties =
  let renders_parse =
    check ~salt:10 "every path a rendering prints is a path the grammar reads" (json ~depth:3)
      (fun value ->
        match Jsondoc.render_json (Yojson.Safe.to_string value) with
        | None -> false
        | Some rendered -> every_label_parses rendered)
  in
  let schemas_parse =
    check ~salt:11 "every path the shape view prints is a path the grammar reads" (json ~depth:3)
      (fun value ->
        match Jsondoc.render_json (Yojson.Safe.to_string value) with
        | None -> false
        | Some rendered -> (
            match Jsondoc.render_schema rendered with
            | None -> false
            | Some schema -> every_label_parses schema))
  in
  let names_round_trip =
    check ~salt:12 "a member's path reads back as that member" key (fun name ->
        let path = Jsondoc.child_path "$.rows" (Jsondoc.Name name) in
        (* The parent is a step of its own, so the member is the last one; the
           point of the property is that the name survives quoting, not that the
           parent vanishes. *)
        match List.rev (Jsondoc.parse_path path) with
        | Jsondoc.Key read :: _ -> read = name
        | _ -> false
        | exception Jsondoc.Path_syntax _ -> false)
  in
  let ordinals_round_trip =
    check ~salt:13 "an element's path reads back as that element"
      QCheck2.Gen.(int_range 0 5000)
      (fun ordinal ->
        let path = Jsondoc.child_path "$.rows" (Jsondoc.Ordinal ordinal) in
        match List.rev (Jsondoc.parse_path path) with
        | Jsondoc.Position read :: _ -> read = ordinal
        | _ -> false
        | exception Jsondoc.Path_syntax _ -> false)
  in
  [ renders_parse; schemas_parse; names_round_trip; ordinals_round_trip ]

let tabledoc_properties =
  let cell_paths_round_trip =
    check ~salt:14 "a cell's path selects exactly that cell's line" table (fun (header, rows) ->
        let body =
          String.concat "," header ^ "\n"
          ^ String.concat "\n" (List.map (fun cells -> String.concat "," cells) rows)
        in
        match Tabledoc.render_table (body ^ "\n") ~delimiter:"," with
        | None -> true (* a table with no row is the documented [None]; nothing to address *)
        | Some rendered ->
            every_label_parses rendered
            && List.mapi
                 (fun row_index cells ->
                   List.mapi
                     (fun column_index cell ->
                       let name = List.nth header column_index in
                       let path =
                         Jsondoc.child_path
                           (Jsondoc.child_path "$.rows" (Jsondoc.Ordinal row_index))
                           (Jsondoc.Name name)
                       in
                       let expected = path ^ "  " ^ Jsondoc.json_string cell in
                       match Jsondoc.select_paths rendered path ~max_chars:1000 with
                       | [ (_, line) ], 0 -> line = expected
                       | _ -> false)
                     cells
                   |> List.for_all Fun.id)
                 rows
            |> List.for_all Fun.id)
  in
  [ cell_paths_round_trip ]

let suite () =
  Alcotest.run "differential-properties"
    [
      ("sanitize", sanitize_properties);
      ("utf8", utf8_properties);
      ("fetch window", window_properties);
      ("jsondoc", jsondoc_properties);
      ("tabledoc", tabledoc_properties);
    ]

let () = suite ()
