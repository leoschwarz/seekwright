(* One escape pass behind two quoting policies; see repr.mli for why the policies
   stay two named functions rather than one with a flag. *)

let escape (quote : char) (keep_non_ascii : bool) (value : string) : string =
  let buffer = Buffer.create (String.length value + 8) in
  Buffer.add_char buffer quote;
  String.iter
    (fun c ->
      match c with
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '"' when quote = '"' -> Buffer.add_string buffer "\\\""
      | '\'' when quote = '\'' -> Buffer.add_string buffer "\\'"
      | c when Char.code c < 0x20 || Char.code c = 0x7f ->
        Buffer.add_string buffer (Printf.sprintf "\\x%02x" (Char.code c))
      | c when Char.code c > 0x7f && not keep_non_ascii ->
        Buffer.add_string buffer (Printf.sprintf "\\x%02x" (Char.code c))
      | c -> Buffer.add_char buffer c)
    value;
  Buffer.add_char buffer quote;
  Buffer.contents buffer

let py_repr (value : string) : string =
  (* Python's [repr] of a str, which is what [safe] renders through: single quotes
     unless the text holds a single quote and no double quote, in which case double
     quotes. Printable non-ASCII is left as the bytes it is: a log line is read by
     a machine that keeps UTF-8, and rewriting it would hide what the page said. *)
  let quote =
    if String.contains value '\'' && not (String.contains value '"') then '"' else '\''
  in
  escape quote true value

let py_repr_ascii (value : string) : string =
  (* The quote is fixed because the text is a token the caller wrote and is being
     quoted back at them, and every byte at or above DEL is escaped — including a
     UTF-8 continuation byte — so the token arrives readable whatever the
     transport does with the bytes in it. *)
  escape '\'' false value
