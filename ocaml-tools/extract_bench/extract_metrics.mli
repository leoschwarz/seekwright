(** Metrics definition for HTML extraction benchmark and verification. *)

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

val bar_failures : median_ms:float -> case -> metrics -> string list

val outcome_of : metrics -> string
