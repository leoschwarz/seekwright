(** UTF-8 over bytes — the one codepoint walk in the port.

    Python counts [len] in codepoints and indexes strings by them, so every
    length and offset this project carries — [total_chars], a window's [offset],
    a policy cap, a [min_length] on a config field — is a character offset.
    OCaml strings are bytes, so the port needs a walk, and it had six copies of
    one that disagreed. This module is the walk; the fetch path's char-indexed
    work happens on {!t}, the codepoint array, and the boundaries convert with
    {!of_string} / {!to_string}.

    The decoder is deliberately as lenient as Python's [utf-8] with
    [errors="replace"]: a byte the encoder would not emit is one character, so a
    hostile payload can neither loop here nor move a cut, and a slice boundary
    never raises.

    The two constraints on the lead-byte test are worth more than the function:

    - A lead byte of a sequence the encoder would not emit — a continuation
      byte, or a five-byte lead in [0xF8..0xFF] — advances {b one} byte. The port
      previously had a range form that said four and a mask form that said one,
      and they disagreed exactly there. Four is not free: the sanitize pass walks
      the content of a [<|...|>] literal a codepoint at a time looking for the
      closing bar, so a step of four jumps the bar and leaves the token
      unescaped; and one is what a replacement character costs in Python.
    - The step is {b clamped} to the bytes that are present. [String.sub] counts
      bytes and raises past the end, so a walk that steps by a sequence's nominal
      width runs off the end of a truncated trailing sequence — [Engine.take] did
      exactly that on ["a\xe2\x80"], from a log-field builder on the refusal
      path with no config flag in front of it.

    Stdlib only, because this library sits under the fetch path too: the stdlib
    HTML reader that keeps [fetch] buildable on a bare install must not acquire a
    big-integer library. *)

(** {2 Bytes} *)

type codepoint = { idx : int; width : int }
(** One codepoint's byte index in its string and the width of its lead byte. *)

val lead_width : string -> int -> int
(** [lead_width s i] is the width of the codepoint at byte [i]: 1, 2, 3 or 4 for
    a lead byte whose continuation bytes a UTF-8 decoder may accept, and 1 for
    anything else. Reads nothing past the end of [s]; see the module docs for why
    a bad lead byte is always one. *)

val next_index : string -> int -> int
(** [next_index s i] is the index of the next codepoint after [i] — the clamped
    step, which is what a scan loop advances by. *)

val codepoints : string -> codepoint list
(** [codepoints s] is every codepoint of [s] with its byte index, in order: what
    a scan needs when it has to know {b where} a codepoint starts as well as how
    many there are. *)

val count : string -> int
(** [count s] is Python's [len(s)]: the codepoint count, not the byte count. *)

val take : int -> string -> string
(** [take n s] is Python's [s[:n]]: the first [n] codepoints, clamped to what [s]
    holds. The clamp is part of the contract, not a convenience — see the module
    docs. *)

val slices : string -> string array
(** [slices s] is [s] cut into one entry per codepoint, so a caller can compare
    adjacent characters and re-join a prefix without redoing the walk. *)

(** {2 Codepoint arrays} *)

type t = int array
(** The characters of a string, one codepoint per entry. *)

val of_string : string -> t

val to_string : t -> string

val encode : int -> string
(** [encode cp] is the UTF-8 bytes of one codepoint — the inverse of {!of_string}
    one element at a time, and the spelling a character reference or a codec
    table writes. *)

(** {2 Whitespace} *)

val is_python_space : int -> bool
(** Whether a codepoint is whitespace to Python: the ASCII blanks, the four
    file/group/record separators, NEL, and the Unicode spaces. This is
    {e str.isspace()}, which is also what {e str.splitlines()} breaks on and what
    the fetch path's blanks, strips and word runs have to agree about. *)

val is_ascii_space : char -> bool
(** The narrower set the search path strips and collapses on: space, tab, VT, FF,
    CR and LF. Python's {e str.split()} also splits on the Unicode spaces, and
    this deliberately does not — every provider payload in the oracle's fixtures
    separates on ASCII blanks, and a non-ASCII space inside a snippet only costs
    the collapse. Both sets live here so the next reader sees that they are two
    different decisions rather than one rule typed twice. *)

val is_line_boundary : int -> bool
(** Whether a codepoint ends a line for {e str.splitlines()}: LF, VT, FF, the four
    file/group/record separators, NEL, and the two Unicode line/paragraph
    separators. A lone CR is {b not} a break here, where Python's {e splitlines}
    does break on it: the fetch path's CSV reader reads [\r] itself and refuses a
    bare one, which is only reachable because the line split leaves it in, so the
    walk keeps the behaviour the tree has. *)

val splitlines : t -> t list
(** {e str.splitlines()} over a codepoint array. A trailing break ends a
    (possibly empty) last line, exactly as Python's does. *)

(** {2 Case} *)

val ascii_lower : t -> t
(** ASCII-only lowercasing. Python's [casefold] also folds non-ASCII ([ß] into
    [ss]); the fetch-path fixtures are ASCII and the term-overlap scorer only
    needs a stable normal form, so the rest passes through unchanged — and a
    byte-wise fold would corrupt the sequence it sits in. *)
