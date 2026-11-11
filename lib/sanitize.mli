(** Escaping model special-token literals out of text that leaves the proxy.

    The Python oracle is [src/seekwright/sanitize.py]. Port of the escape pass
    only: the wire-model walk lives in [Model], which applies this rule both at
    its engine pass and at serialisation. *)

val zwsp : string
(** U+200B ZERO WIDTH SPACE, the escape and the only character escaping adds. *)

val text_fields : string list
(** The wire-model fields carrying provider-originated text: [title],
    [snippet], [text] and [answer]. *)

val is_text_field : string -> bool
(** [is_text_field name] is [true] exactly when [name] is in {!text_fields}. *)

val sanitize_text : string -> string * int
(** [sanitize_text text] escapes every special-token literal in [text] and
    returns the escaped text together with the number of literals escaped.

    The pass is reversible (dropping every {!zwsp} restores the source),
    idempotent (escaped text no longer matches) and deterministic. Text without
    a ['<'] or ['['] is returned unchanged and physically equal to the input. *)
