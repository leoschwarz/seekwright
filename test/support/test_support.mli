(* The private test-support library: the string, file and [Alcotest] helpers
   the suites share. It is a library and not a module inside each suite because
   a helper copied into five files drifts in five directions — which is exactly
   what the argument orders here had done. *)

val find_sub : ?start:int -> haystack:string -> needle:string -> unit -> int option
(** [find_sub ~haystack ~needle ()] is the byte index of the first occurrence of [needle] in
    [haystack] at or after [start] (default [0]), or [None].

    The trailing [()] is what makes [start] erasable: every other argument is labelled, so an
    optional one would be warning 16. A byte index, so a caller that needs a codepoint index is
    reading an ASCII fixture — say so where it does. *)

val contains : haystack:string -> needle:string -> bool
(** [contains ~haystack ~needle] is [true] when {!find_sub} answers [Some _]. The empty needle
    occurs in every haystack. *)

val read_file : string -> string
(** [read_file path] is the whole file, read in binary so no newline is translated. A missing file
    raises [Sys_error], which is what a broken fixture should do. *)

val factory_sources : unit -> (string * string) list
(** [factory_sources ()] is every OCaml source of [lib/factory] — each [.ml] and each [.mli] — as
    [(name, text)] pairs named from the repo root ([lib/factory/factory.ml]) and sorted by name.

    A function, never a top-level value: [test_support] is linked by suites whose sandbox carries no
    factory sources, and a module-load [read_file] would raise [Sys_error] in every one of them.
    Only the pin suites call it, and only where [test/dune] has filled their sandbox with
    [(glob_files ../lib/factory/*.mli)] and [(glob_files ../lib/factory/*.ml)].

    The directory is read with [Sys.readdir] rather than kept as a hand-maintained list, so a new
    factory module joins the scan on its own and a pin can never be left reading a stale file list —
    which is what lets a source pin count a library-wide total instead of one file's. An empty
    directory fails, so a glob that matched nothing cannot pass vacuously; a file the sandbox is
    missing raises [Sys_error]. *)

val replace_all : haystack:string -> needle:string -> with_:string -> string
(** [replace_all ~haystack ~needle ~with_] replaces every non-overlapping occurrence of [needle],
    left to right. An empty needle leaves the haystack unchanged. *)

val count_occurrences : haystack:string -> needle:string -> int
(** [count_occurrences ~haystack ~needle] is the number of non-overlapping occurrences of [needle],
    counted left to right. An empty needle counts zero. *)

val includes : string -> string -> string -> unit
(** [includes label needle haystack] passes when [haystack] contains [needle], and otherwise fails
    with the label, the needle and the text it searched. The order is the failure message's: what
    was asserted, then what was looked for, then where. *)

val excludes : string -> string -> string -> unit
(** [excludes label needle haystack] is the negative of {!includes}. *)

val flatten : string -> string
(** [flatten text] is [text] with every run of whitespace collapsed to one space and leading
    whitespace dropped. *)

val source_includes : string -> string -> string -> unit
(** [source_includes label needle haystack] is {!includes} over {!flatten}-ed inputs, for a needle
    that names code rather than prose: the tree is formatter-pinned, so the line breaks inside the
    code a needle quotes are not the needle's claim. *)

val source_excludes : string -> string -> string -> unit
(** [source_excludes label needle haystack] is {!source_includes}'s negative. *)

val source_count_occurrences : haystack:string -> needle:string -> int
(** [source_count_occurrences] is {!count_occurrences} over {!flatten}-ed inputs. *)

val check_string : string -> string -> string -> unit
val check_int : string -> int -> int -> unit
val check_bool : string -> bool -> bool -> unit
val check_strings : string -> string list -> string list -> unit
val check_ints : string -> int list -> int list -> unit
val check_opt_string : string -> string option -> string option -> unit
val check_opt_int : string -> int option -> int option -> unit

val number : float Alcotest.testable
(** [Alcotest.float 1e-9], the tolerance every suite compared a duration or a price with. *)

val check_number : string -> float -> float -> unit
val check_opt_number : string -> float option -> float option -> unit

val get : string -> Yojson.Safe.t -> Yojson.Safe.t
(** [get key json] is [key]'s value in an object, or [ `Null] for a field that is absent or for a
    json that is not an object. *)

val items : Yojson.Safe.t -> Yojson.Safe.t list
(** [items json] is the elements of an array, and [[]] for anything else. *)

val str : Yojson.Safe.t -> string
(** [str json] is a string field as text: [ `Null] reads as the empty string and any other value
    renders, so a shape-drift case can still name it. *)

val int : Yojson.Safe.t -> int
(** [int json] is a count. A float is accepted because a JSON writer may render [3] as [3.0];
    anything else fails the case with the text it was given. *)

val bool : Yojson.Safe.t -> bool
(** [bool json] is a flag, or a failed case. *)

val is_null : Yojson.Safe.t -> bool
(** [is_null json] is true of [ `Null] — the question a "the field was omitted" assertion asks. *)

val hd : string -> 'a list -> 'a
(** [hd label xs] is the first of [xs], failing with [label] rather than with
    [Stdlib.Failure("hd")]. *)

val nth : string -> int -> 'a list -> 'a
(** [nth label index xs] is the [index]-th of [xs], failing with [label]. *)
