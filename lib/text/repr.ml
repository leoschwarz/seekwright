(* One escape pass; see repr.mli for the quoting rule and why the fetch path's
   ASCII-only JSON escape is not a second policy of this module. *)

let py_repr (value : string) : string =
  (* Python's [repr] of a str: single quotes unless the text holds a single quote
     and no double quote, in which case double quotes. Printable non-ASCII is
     left as the bytes it is: a log line is read by a machine that keeps UTF-8,
     and rewriting it would hide what the page said. The same pass quotes a path
     token back at the caller, because Python's own refusal messages use
     [repr] there too (F1.5). *)
  let quote =
    if String.contains value '\'' && not (String.contains value '"') then '"'
    else '\''
  in
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
      | c -> Buffer.add_char buffer c)
    value;
  Buffer.add_char buffer quote;
  Buffer.contents buffer
