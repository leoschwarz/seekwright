(** Argument scanning and request-body construction for client verbs [search],
    [fetch] and [answer]. Returns [Error message] on validation or syntax failure. *)

type scanned = {
  positional : string list;
  flags : (string * string list) list;
  bools : string list;
}
(** Scanned command line: positional arguments, valued flags in order, and bare boolean flags. *)

val scan_args : string list -> (scanned, string) result
(** [scan_args argv] splits flags from positionals. Returns [Error msg] on missing flag values or unexpected arguments. *)

val flag_values : scanned -> string -> string list

val flag_one : scanned -> string -> string option

val flag_bool : scanned -> string -> bool

val usage_error : string -> ('a, string) result

val search_body : scanned -> (Yojson.Safe.t, string) result

val fetch_body : scanned -> (Yojson.Safe.t, string) result

val answer_body : scanned -> (Yojson.Safe.t, string) result
