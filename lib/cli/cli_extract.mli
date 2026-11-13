(** Argument scanning and request-body building for the three client verbs —
    the port of [tests/test_cli.py]'s [_extract] helper: which flag becomes
    which field of which request, and the usage errors a malformed command
    gets. Pure: [usage_error] names what went wrong and returns it as an
    [Error]; the caller owns the stream and the exit code.

    The rules the tests pin, all inherited from the Python client:

    - dotted flag names match the underscored request field, so no table of
      aliases is needed;
    - [--no-safe-search] means [safe_search=False];
    - a repeated flag is a list field only where the request says the field is
      a list — [extra_queries], [include_domains], [exclude_domains] — and
      otherwise the first value wins;
    - [json.loads] of the serialised body is what a field actually carries: a
      [None] never reaches the body, and the serialiser is what decides that. *)

type scanned = {
  positional : string list;
  flags : (string * string list) list;
  bools : string list;
}
(** A scanned command line: positional arguments in order, flags mapped to
    their values in order, and the bare boolean flags seen. *)

val scan_args : string list -> (scanned, string) result
(** [scan_args argv] splits flags from positionals: a [--flag=value] carries
    its value inline, a [--flag value] takes the next token unless that token
    is itself a long flag, and a bare long flag is a boolean. An [Error] is
    the usage sentence for a flag left without its value. *)

val flag_values : scanned -> string -> string list
(** [flag_values scanned name] is every value passed under [name], in order. *)

val flag_one : scanned -> string -> string option
(** [flag_one scanned name] is the first value passed under [name]. *)

val flag_bool : scanned -> string -> bool
(** [flag_bool scanned name] is whether the bare flag [name] was seen. *)

val usage_error : string -> ('a, string) result
(** [usage_error message] is [Error message] — the constructor a test can
    read, where the CLI process prints and exits. *)

val search_body : scanned -> (Yojson.Safe.t, string) result
(** [search_body scanned] builds and validates the [POST /api/v1/search] body. *)

val fetch_body : scanned -> (Yojson.Safe.t, string) result
(** [fetch_body scanned] builds the [POST /api/v1/fetch] body; unset fields are
    absent, and [structure] only when true. *)

val answer_body : scanned -> (Yojson.Safe.t, string) result
(** [answer_body scanned] builds and validates the [POST /api/v1/answer] body. *)
