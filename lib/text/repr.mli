(** Python's [repr] of a string, for text that reaches a human or a log.

    The log-field builders ({[safe]}, and so every value on every event) put a
    scraped string into a log line. The rule that has to hold byte for byte is
    that a newline in a scraped title cannot close one record and open a
    fabricated one, so the quoting and the escaping are the contract. The path
    grammar's refusals quote a token the caller wrote back at them, and Python's
    own refusal messages use [repr] there, so both callers take this one pass:
    printable non-ASCII stays the bytes it is (F1.5).

    The ASCII-only escape a {b path rendering} needs — a quoted key inside a
    path, where the path has to be re-readable through JSON — is not a second
    policy here. It lives beside the path grammar that requires it, as
    [Jsondoc.json_string_ascii]. *)

val py_repr : string -> string
(** [py_repr s] is Python's [repr(s)]: single quotes, or double quotes when the
    text holds a single quote and no double quote. The backslash and the chosen
    quote are escaped, [\n], [\r] and [\t] are named, any other control byte and
    DEL are [\xNN], and printable non-ASCII passes through as the bytes it is. *)
