(* The canonical rendering the golden corpus is written in; the interface says
   what each rule is for and which Python call it mirrors. *)

let hex_nibble value =
  if value < 10 then Char.unsafe_chr (value + 48) else Char.unsafe_chr (value - 10 + 97)

let to_hex_byte byte =
  String.make 1 (hex_nibble (byte / 16)) ^ String.make 1 (hex_nibble (byte mod 16))

let to_hex text =
  String.concat "" (List.map to_hex_byte (List.init (String.length text) (String.get_uint8 text)))

let hex_value ch =
  match ch with
  | '0' .. '9' -> Some (Char.code ch - Char.code '0')
  | 'a' .. 'f' -> Some (Char.code ch - Char.code 'a' + 10)
  | 'A' .. 'F' -> Some (Char.code ch - Char.code 'A' + 10)
  | _ -> None

let of_hex text =
  if String.length text mod 2 <> 0
  then invalid_arg "canon.of_hex: an odd number of hex digits";
  let byte at =
    match (hex_value (String.get text at), hex_value (String.get text (at + 1))) with
    | Some high, Some low -> Char.unsafe_chr ((high * 16) + low)
    | _ -> invalid_arg "canon.of_hex: not a hex digit"
  in
  String.init (String.length text / 2) (fun i -> byte (i * 2))

(* {1 The [json.dumps(ensure_ascii=True)] escape} *)

let u_escape buffer code = Buffer.add_string buffer (Printf.sprintf "\\u%04x" code)

(* A codepoint above the BMP reaches JSON as a surrogate pair, which is what
   [json.dumps] writes and what a reader of the golden has to be able to feed
   back to a decoder. *)
let u_escape_wide buffer code =
  let code = code - 0x10000 in
  u_escape buffer (0xd800 + (code lsr 10));
  u_escape buffer (0xdc00 + (code land 0x3ff))

(* [width] is the lead byte's declared width. A sequence whose continuation bytes
   are missing is read as one replacement character rather than raising, so a
   corpus value reaches the golden as the same text a Python
   [errors="replace"] decode would have produced. *)
let decode_codepoint text index width =
  let byte at = String.get_uint8 text at in
  let mask = 0x7f lsr width in
  let rec go position acc =
    if position >= index + width || position >= String.length text
    then Some acc
    else if (byte position land 0xc0) <> 0x80
    then None
    else go (position + 1) ((acc lsl 6) lor (byte position land 0x3f))
  in
  go (index + 1) (byte index land mask)

let lead_width byte =
  if byte < 0x80 then 1 else if byte land 0xe0 = 0xc0 then 2 else if byte land 0xf0 = 0xe0 then 3
  else if byte land 0xf8 = 0xf0 then 4
  else 1

let named_escape = function
  | '\n' -> Some "\\n"
  | '\r' -> Some "\\r"
  | '\t' -> Some "\\t"
  | '\b' -> Some "\\b"
  | '\012' -> Some "\\f"
  | '"' -> Some "\\\""
  | '\\' -> Some "\\\\"
  | _ -> None

let escape_text text =
  let buffer = Buffer.create (String.length text + 8) in
  let index = ref 0 in
  while !index < String.length text do
    let byte = String.get_uint8 text !index in
    if byte < 0x80
    then (
      (match named_escape (Char.unsafe_chr byte) with
      | Some escape -> Buffer.add_string buffer escape
      | None ->
        if byte >= 0x20
        then Buffer.add_char buffer (Char.unsafe_chr byte)
        else u_escape buffer byte);
      incr index)
    else if byte < 0xc0 || byte > 0xf7
    then (
      (* A lone continuation byte or a five-byte lead is one replacement
         character, exactly as a lenient decode reads it. *)
      u_escape buffer 0xfffd;
      incr index)
    else (
      let width = lead_width (String.get_uint8 text !index) in
      match decode_codepoint text !index width with
      | Some code when code <= 0xffff ->
          u_escape buffer code;
          index := !index + width
      | Some code ->
          u_escape_wide buffer code;
          index := !index + width
      | None ->
          u_escape buffer 0xfffd;
          index := !index + 1)
  done;
  Buffer.contents buffer

let float_repr value =
  if Float.is_nan value || Float.is_infinite value
  then invalid_arg "canon.float_repr: the corpus pins no NaN or infinity";
  let digits = Printf.sprintf "%.17g" value in
  let plain = String.for_all (fun ch -> ch <> '.' && ch <> 'e' && ch <> 'E') digits in
  if plain then digits ^ ".0" else digits

let rec canon_json value =
  match value with
  | `Null -> "null"
  | `Bool b -> if b then "true" else "false"
  | `Int n -> string_of_int n
  | `Intlit s -> s
  | `Float f -> float_repr f
  | `String s -> "\"" ^ escape_text s ^ "\""
  | `List items -> "[" ^ String.concat "," (List.map canon_json items) ^ "]"
  | `Assoc members ->
      let sorted =
        List.sort (fun (a, _) (b, _) -> String.compare a b)
          (List.map (fun (key, value) -> (key, canon_json value)) members)
      in
      "{"
      ^ String.concat ","
          (List.map (fun (key, value) -> "\"" ^ escape_text key ^ "\":" ^ value) sorted)
      ^ "}"

let reset_key_environment () =
  let names =
    List.map Seekwright.Config.api_key_env_var Seekwright.Config.known_providers
    @ [ "SEEKWRIGHT_AGENT_API_KEY"; "SEEKWRIGHT_CONFIG" ]
  in
  List.iter (fun name -> Unix.putenv name "") names
