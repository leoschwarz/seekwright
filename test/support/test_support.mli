(* The private test-support library: the string, file and [Alcotest] helpers
   the suites share. It is a library and not a module inside each suite because
   a helper copied into five files drifts in five directions — which is exactly
   what the argument orders here had done. *)

(** [find_sub ~haystack ~needle ()] is the byte index of the first occurrence
    of [needle] in [haystack] at or after [start] (default [0]), or [None].

    The trailing [()] is what makes [start] erasable: every other argument is
    labelled, so an optional one would be warning 16. A byte index, so a caller
    that needs a codepoint index is reading an ASCII fixture — say so where it
    does. *)
val find_sub : ?start:int -> haystack:string -> needle:string -> unit -> int option

(** [contains ~haystack ~needle] is [true] when {!find_sub} answers [Some _].
    The empty needle occurs in every haystack, as Python's ["" in s] says. *)
val contains : haystack:string -> needle:string -> bool

(** [read_file path] is the whole file, read in binary so no newline is
    translated. A missing file raises [Sys_error], which is what a broken
    fixture should do. *)
val read_file : string -> string

(** [replace_all ~haystack ~needle ~with_] is Python's [str.replace]: every
    non-overlapping occurrence of [needle], left to right. An empty needle
    leaves the haystack unchanged, as Python does. *)
val replace_all : haystack:string -> needle:string -> with_:string -> string

(** [count_occurrences ~haystack ~needle] is Python's [str.count]: the number of
    non-overlapping occurrences of [needle], counted left to right. An empty
    needle counts zero. *)
val count_occurrences : haystack:string -> needle:string -> int

(** [includes label needle haystack] passes when [haystack] contains [needle],
    and otherwise fails with the label, the needle and the text it searched.
    The order is the failure message's: what was asserted, then what was looked
    for, then where. *)
val includes : string -> string -> string -> unit

(** [excludes label needle haystack] is the negative of {!includes}. *)
val excludes : string -> string -> string -> unit

val check_string : string -> string -> string -> unit
val check_int : string -> int -> int -> unit
val check_bool : string -> bool -> bool -> unit
val check_strings : string -> string list -> string list -> unit
val check_ints : string -> int list -> int list -> unit
val check_opt_string : string -> string option -> string option -> unit
val check_opt_int : string -> int option -> int option -> unit

(** [Alcotest.float 1e-9], the tolerance every suite compared a duration or a
    price with. *)
val number : float Alcotest.testable

val check_number : string -> float -> float -> unit
val check_opt_number : string -> float option -> float option -> unit
