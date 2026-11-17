(** Escapes model special-token literals from text leaving the proxy. *)

val zwsp : string
(** U+200B ZERO WIDTH SPACE, the single character inserted after opening delimiters. *)

val text_fields : string list
(** The wire-model fields carrying provider-originated text: [title], [snippet], [text] and
    [answer]. *)

val is_text_field : string -> bool
(** [is_text_field name] is [true] when [name] is in {!text_fields}. *)

val sanitize_text : string -> string * int
(** [sanitize_text text] escapes special-token literals in [text] and returns the escaped string
    with the count of escaped occurrences.

    Reversible (stripping U+200B restores source), idempotent, and deterministic. Text with neither
    a less-than sign nor an opening bracket returns unchanged with count 0. *)
