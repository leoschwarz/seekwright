(** What an extraction has to answer, and whether it did.

    The metric definitions of the F6.2 extraction benchmark, in one place because
    two things read them: the recorded table, which an operator produces in
    [ocaml-tools/extract_bench/], and the quality gate, which [dune runtest] runs
    over the same corpus in [test/corpus_html/]. A bar that means something
    slightly different in the two places is a bar nobody can compare, so neither
    place owns the definitions — this module does.

    The metrics are deliberately not exact-string equality. Two renderers that
    break a paragraph at different points can both hand the caller the same page,
    so each case carries the phrases its answer must contain ([essential]) and the
    furniture it must not ([boilerplate]), and a row records recall, leakage,
    title, Unicode fidelity, volume, determinism, and — separately, because it is
    a property of the machine rather than of the tree — the time. *)

type case = {
  id : string;
  file : string;  (** the fixture this row was measured on *)
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

val load_cases : string -> case list
(** Read [cases.json] under a corpus directory and its fixtures beside it. *)

val collapse : string -> string
val contains : haystack:string -> needle:string -> bool
val misses : haystack:string -> needles:string list -> string list
val codepoints : string -> int
val replacement_chars : string -> int
val searchable : string -> string option -> string

type outcome =
  | Text of { text : string; title : string option; chars : int }
  | Refusal of string

val run : case -> outcome
(** The port's stdlib backend over the case's bytes, or its refusal. *)

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

val measure : case -> metrics
(** One pass over a case: the backend runs twice, so [deterministic] is in the
    row as well as the content metrics. *)

val bar_failures : median_ms:float -> case -> metrics -> string list
(** Every bar this row fails, in words a test failure or a table note can carry.
    Empty means the row meets the bar. *)

val outcome_of : metrics -> string
(** [text], [empty] or [refusal] — the three answers a case's [expect] can ask
    for, derived from the row rather than trusted from it. *)
