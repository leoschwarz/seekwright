(* The helpers every suite was writing for itself.

   [contains] and [find_sub] are labelled because the two argument orders the
   suites had accumulated were indistinguishable at a call site: [contains text
   needle] in most of them, [contains needle haystack] in [test_config], and a
   swapped pair of [string]s typechecks either way. Naming the arguments is what
   makes the reviewer — and the compiler — read the same thing the helper does.

   The [check_*] aliases are the partial applications of [Alcotest.check] that
   were spelled out in seven suites, and that is all they are: the common
   testables, not a registry. A suite that needs another one — a record, a pair,
   its own pretty-printer — still builds it with [A.check]. *)

let find_sub ?(start = 0) ~haystack ~needle () =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec go index =
    if index + needle_length > haystack_length then None
    else if String.equal (String.sub haystack index needle_length) needle then Some index
    else go (index + 1)
  in
  go start

let contains ~haystack ~needle = find_sub ~haystack ~needle () <> None

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* The factory's sources, read as a set: a source pin that names one file counts
   that file, and a library-wide guarantee — one audit funnel, one web-grant
   variant — needs a total over every module in the library. [Sys.readdir] is
   what keeps that total honest when the library gains a module: the scan widens
   by itself, where a hand-written list would silently keep counting the old
   file's text. Named from the repo root because that is the name a failure
   message has to print; the [../] prefix is only what the sandbox needs to
   open the file. *)
let factory_sources () =
  let dir = "../lib/factory" in
  let names =
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun name ->
        Filename.check_suffix name ".ml" || Filename.check_suffix name ".mli")
    |> List.sort String.compare
  in
  if names = [] then Alcotest.failf "no modules found under %s" dir;
  List.map (fun name -> ("lib/factory/" ^ name, read_file (dir ^ "/" ^ name))) names

(* Replaces every non-overlapping occurrence, left to right. An empty needle
   leaves the haystack alone. *)
let replace_all ~haystack ~needle ~with_ =
  if needle = "" then haystack
  else begin
    let buffer = Buffer.create (String.length haystack) in
    let rec go offset =
      match find_sub ~start:offset ~haystack ~needle () with
      | None -> Buffer.add_substring buffer haystack offset (String.length haystack - offset)
      | Some at ->
          Buffer.add_substring buffer haystack offset (at - offset);
          Buffer.add_string buffer with_;
          go (at + String.length needle)
    in
    go 0;
    Buffer.contents buffer
  end

(* [includes] and [excludes] lead with the assertion's label and then name the
   needle before the haystack: they are assertions, so the label is what a
   failure has to print first, and the pair after it reads as "the haystack
   carries the needle". *)
let includes label needle haystack =
  if not (contains ~haystack ~needle) then
    Alcotest.failf "%s: the text did not contain %S\n     it was: %S" label needle haystack

let excludes label needle haystack =
  if contains ~haystack ~needle then
    Alcotest.failf "%s: the text contained %S, and must not\n     it was: %S" label needle haystack

(* Non-overlapping, left to right; an empty needle counts zero. *)
let count_occurrences ~haystack ~needle =
  if needle = "" then 0
  else begin
    let step = String.length needle in
    let rec go offset total =
      match find_sub ~start:offset ~haystack ~needle () with
      | None -> total
      | Some at -> go (at + step) (total + 1)
    in
    go 0 0
  end

(* A source-text needle is matched with every whitespace run collapsed to one
   space. The tree is formatter-pinned (`.ocamlformat`), so a call a needle names
   can be wrapped wherever the formatter chooses; collapsing keeps the claim —
   this call, these arguments, in this order, in this file — and drops the claim
   about where the line breaks fall. *)
let flatten (text : string) : string =
  let buffer = Buffer.create (String.length text) in
  let rec go index pending =
    if index = String.length text then Buffer.contents buffer
    else
      match text.[index] with
      | ' ' | '\t' | '\n' | '\r' -> go (index + 1) true
      | ch ->
          if pending && Buffer.length buffer > 0 then Buffer.add_char buffer ' ';
          Buffer.add_char buffer ch;
          go (index + 1) false
  in
  go 0 false

let source_includes label needle haystack = includes label (flatten needle) (flatten haystack)

let source_excludes label needle haystack = excludes label (flatten needle) (flatten haystack)

let source_count_occurrences ~haystack ~needle =
  count_occurrences ~haystack:(flatten haystack) ~needle:(flatten needle)

let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)
let check_strings = Alcotest.(check (list string))
let check_ints = Alcotest.(check (list int))
let check_opt_string = Alcotest.(check (option string))
let check_opt_int = Alcotest.(check (option int))

(* The shared float testable: every suite that compares a duration or a price
   to a figure the config file spells to two decimals picked the same epsilon. *)
let number = Alcotest.float 1e-9
let check_number = Alcotest.(check number)
let check_opt_number = Alcotest.(check (option number))

(* The fixture readers, shared for the same reason the check helpers are: the
   snapshot, the journal line and the REST body all arrive as a
   [Yojson.Safe.t], and the loose "dict" typing the assertions want is the same
   eight lines in every suite that reads one. A reader that cannot read the
   value fails with the text it was given. *)
let get key = function
  | `Assoc fields -> ( try List.assoc key fields with Not_found -> `Null)
  | _ -> `Null

let items = function `List xs -> xs | _ -> []
let str = function `String s -> s | `Null -> "" | v -> Yojson.Safe.to_string v

let int = function
  | `Int n -> n
  | `Float f -> int_of_float f
  | v -> Alcotest.failf "not a count: %s" (Yojson.Safe.to_string v)

let bool = function `Bool b -> b | v -> Alcotest.failf "not a flag: %s" (Yojson.Safe.to_string v)
let is_null = ( = ) `Null

(* The list accessors, so a missing record fails with its label rather than
   [Stdlib.Failure("hd")]. *)
let hd label = function x :: _ -> x | [] -> Alcotest.failf "%s was empty" label

let nth label index xs =
  match List.nth_opt xs index with
  | Some x -> x
  | None -> Alcotest.failf "%s has no item %d" label index
