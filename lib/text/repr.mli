(** Python's [repr] of a string, for text that reaches a human or a log.

    Two callers need this and they need it for different reasons, which is why
    there are two names rather than one function with a flag in it:

    - The log-field builders ({[safe]}, and so every value on every event) put a
      scraped string into a log line. The rule that has to hold byte for byte is
      that a newline in a scraped title cannot close one record and open a
      fabricated one, so the quoting and the escaping are the contract.
    - The path-grammar refusals quote back a token the caller wrote, in a message
      that goes to the model. There the quote is fixed, and what the reader
      expects is to see the bytes that made the token.

    Both leave a printable ASCII string alone, and neither rewrites a UTF-8
    sequence into something else — the fetch path's {!py_repr_ascii} escapes
    every byte above ASCII, so a non-ASCII token arrives as the bytes that made
    it rather than as the character. *)

val py_repr : string -> string
(** [py_repr s] is Python's [repr(s)] as the log uses it: single quotes, or double
    quotes when the text holds a single quote and no double quote. The backslash
    and the chosen quote are escaped, [\n], [\r] and [\t] are named, any other
    control byte and DEL are [\xNN], and printable non-ASCII passes through as the
    bytes it is. *)

val py_repr_ascii : string -> string
(** [py_repr_ascii s] is the same escape pass with the quote fixed to ['] and
    every byte above ASCII written as [\xNN], which is what a refusal message
    quoting back a caller's own token wants: the token comes back readable whether
    or not the transport survives the bytes in it. *)
