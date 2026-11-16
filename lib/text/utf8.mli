(** UTF-8 operations over bytes and codepoint arrays.

    All lengths and offsets in seekwright (such as [total_chars], passage window
    offsets, policy caps) count Unicode codepoints rather than bytes.

    The decoder follows the maximal subpart division: ill-formed or interrupted
    byte sequences decode to U+FFFD per maximal subpart, and slice boundaries do
    not raise.

    Lead-byte stepping constraints:
    - Continuation bytes, overlong leads ([0xC0..0xC1]), and five-byte leads
      ([0xF8..0xFF]) advance by one byte.
    - Steps are clamped to the bytes present in the string. *)

type codepoint = { idx : int; width : int }
(** One codepoint's byte index in its string and the width of its lead byte. *)

val lead_width : string -> int -> int
(** [lead_width s i] is the byte width of the maximal subpart at byte [i]: the
    lead byte plus the continuation bytes a UTF-8 decoder may accept, or the
    bytes present when the sequence is truncated, and 1 for anything else. *)

val next_index : string -> int -> int
(** [next_index s i] is the byte index of the next codepoint after [i], clamped
    to [String.length s]. *)

val codepoints : string -> codepoint list
(** [codepoints s] lists every codepoint in [s] with its byte index, in order.
    The entries partition [s] byte for byte even on ill-formed input. *)

val count : string -> int
(** [count s] is the number of codepoints (maximal subparts) in [s]. *)

val take : int -> string -> string
(** [take n s] is the prefix of at most [n] codepoints from [s]. *)

val slices : string -> string array
(** [slices s] is [s] cut into one string entry per maximal subpart. The
    entries concatenate to [s], ill-formed bytes included. *)

type t = int array
(** The characters of a string, one codepoint per entry. *)

val of_string : string -> t
(** Decode one entry per maximal subpart. Well-formed sequences yield their
    codepoints; ill-formed subparts yield U+FFFD. *)

val to_string : t -> string

val encode : int -> string
(** [encode cp] is the UTF-8 bytes of one codepoint. *)

val is_python_space : int -> bool
(** Whether a codepoint is whitespace: ASCII whitespace, file/group/record
    separators, NEL, and Unicode space separator categories. *)

val lstrip : string -> string
(** [lstrip s] removes leading {!is_python_space} characters from [s]. *)

val rstrip : string -> string
(** [rstrip s] removes trailing {!is_python_space} characters from [s]. *)

val strip : string -> string
(** [strip s] removes leading and trailing {!is_python_space} characters. *)

val split_whitespace : string -> string list
(** [split_whitespace s] splits [s] across runs of {!is_python_space}. Leading
    and trailing whitespace yields no empty words. *)

val is_line_boundary : int -> bool
(** Whether a codepoint ends a line: LF, CR, VT, FF, file/group/record
    separators, NEL, and Unicode line/paragraph separators. *)

val splitlines : t -> t list
(** Split lines over a codepoint array. A trailing break ends the last line
    without adding a trailing empty line. CRLF is treated as a single line break.
    The empty input has no lines. *)

val ascii_lower : t -> t
(** ASCII-only lowercase conversion over a codepoint array. *)
