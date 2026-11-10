type kind =
  | Denied
  | Invalid
  | Unavailable
  | Timeout
  | Failed

(* A tool result is one line of prose handed to a model, so the ceiling is a
   protocol concern, not a display one: an uncapped provider body would decide
   how large our own response is. *)
let max_message_bytes = 512

let is_control char =
  let code = Char.code char in
  code < 32 || code = 127

(* Cutting at a byte boundary can split a UTF-8 sequence and put an invalid
   string into JSON; back off to the start of the sequence being cut. *)
let utf8_start text limit =
  let rec back off =
    if off <= 0 || (Char.code text.[off - 1] land 0xC0) <> 0x80 then off
    else back (off - 1)
  in
  back (min limit (String.length text))

let sanitize message =
  let buffer = Buffer.create (String.length message) in
  String.iter
    (fun char ->
      if is_control char then Buffer.add_char buffer ' ' else Buffer.add_char buffer char)
    message;
  let text = String.trim (Buffer.contents buffer) in
  if String.length text <= max_message_bytes then text
  else String.sub text 0 (utf8_start text max_message_bytes) ^ "..."

type t = { kind : kind; message : string }

let make kind ~message = { kind; message = sanitize message }

let kind t = t.kind
let message t = t.message

let kind_to_string = function
  | Denied -> "denied"
  | Invalid -> "invalid"
  | Unavailable -> "unavailable"
  | Timeout -> "timeout"
  | Failed -> "failed"

let render t = kind_to_string t.kind ^ ": " ^ t.message
