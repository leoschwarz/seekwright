(** String quoting and escaping for text that reaches human readers or logs.

    A newline in scraped text cannot close one log record and open a
    fabricated one, so quoting and escaping are part of the wire contract.
    Printable non-ASCII codepoints are preserved as UTF-8. *)

val py_repr : string -> string
(** [py_repr s] formats [s] with single quotes, or double quotes when the text
    holds a single quote and no double quote. The backslash and the chosen quote
    are escaped, [\n], [\r] and [\t] are named, and codepoints outside the
    printable set are escaped as [\xNN], [\uNNNN] or [\UNNNNNNNN] by width;
    printable non-ASCII passes through unescaped as UTF-8.

    The non-printable set covers [Cc Cf Cs Co Zl Zp Zs] ranges of Unicode 16.0,
    minus U+0020. *)
