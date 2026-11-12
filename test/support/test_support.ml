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

(* Python's [str.replace]: every non-overlapping occurrence, left to right, and
   an empty needle leaves the haystack alone. Two suites had written it for
   themselves, one over a [Buffer] and one recursively. *)
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

(* Python's [str.count]: non-overlapping, left to right, and an empty needle
   counts zero. The two local counters this replaces had disagreed about
   overlap, so the rule is stated here rather than left to each caller. *)
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
