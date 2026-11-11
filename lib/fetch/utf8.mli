(** UTF-8 helpers for the fetch path.

    Python counts [len] in codepoints and indexes strings by them, so every
    offset the fetch stack carries — [total_chars], a window's [offset],
    [select_paths]' span starts — is a character offset. OCaml strings are
    bytes, so the char-indexed work happens on {!t}, the codepoint array, and
    the boundaries convert with {!of_string} / {!to_string}.

    A lead byte of a sequence the encoder would not emit is treated as one
    character, so a hostile payload can neither loop here nor move a cut. *)

type t = int array
(** The characters of a string, one codepoint per entry. *)

val count : string -> int
(** [count s] is [len(s)] in Python: the codepoint count, not the byte count. *)

val of_string : string -> t

val to_string : t -> string

val encode : int -> string
(** [encode cp] is the UTF-8 bytes of one codepoint — the inverse of
{!of_string} one element at a time, and the spelling a character reference
or a codec table writes. *)

val is_python_space : int -> bool
(** Whether a codepoint is whitespace to [str.strip] — the ASCII blanks plus
the Unicode spaces the method also drops. *)

val splitlines : t -> t list
(** [str.splitlines]: the boundaries are LF, VT, FF, CR ([CRLF] as one break),
the four file/group/record separators, NEL, and the two Unicode line/para
separators. A trailing break ends a (possibly empty) last line, exactly as
Python's does. *)

val ascii_lower : t -> t
(** ASCII-only lowercasing. Python's [casefold] also folds non-ASCII ([ß] into
[ss]); the fetch-path fixtures are ASCII and the term-overlap scorer only
needs a stable normal form, so the rest passes through unchanged. *)
