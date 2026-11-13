(* The HTTP heads at the listener's two trust boundaries. See [http_head.mli]
   for why the ceilings are these numbers and why failure is a value. *)

let request_head_limit = 16 * 1024
let response_head_limit = 8 * 1024

type request_head = {
  request_line : string;
  header_lines : string list;
}

type read_error =
  | Client_closed
  | Request_head_too_large
  | Malformed_request_head

type head_error = Response_head_too_large

let reason_phrase status =
  let phrase = Http.Status.reason_phrase_of_code status in
  if phrase <> string_of_int status then phrase
  else match status with 421 -> "Misdirected Request" | _ -> phrase

(* A line with its terminator removed, either CRLF or the bare LF a
   non-conforming client may send. *)
let line_of_raw raw =
  let n = String.length raw in
  if n >= 2 && raw.[n - 2] = '\r' && raw.[n - 1] = '\n' then String.sub raw 0 (n - 2)
  else if n >= 1 && raw.[n - 1] = '\n' then String.sub raw 0 (n - 1)
  else raw

(* One line, read a byte at a time.

   [consumed] is the head's byte count before this line. [limit] is the head
   ceiling, so the check is on the head's total and not on this line alone: a
   thousand short lines are as refused as one long one. Reading one byte at a
   time is what makes that count exact — [Buf_read.line] would tell us the size
   of a line only after it had already buffered all of it, and the ceiling has
   to be enforced before the allocation, not after. *)
let read_line ~limit ~consumed ic =
  let line = Buffer.create 64 in
  let rec loop bytes =
    if consumed + bytes >= limit then Error Request_head_too_large
    else
      match Eio.Buf_read.any_char ic with
      | exception End_of_file ->
          if consumed = 0 && bytes = 0 then Error Client_closed
          else Error Malformed_request_head
      | exception Eio.Buf_read.Buffer_limit_exceeded -> Error Request_head_too_large
      | c -> (
          Buffer.add_char line c;
          if c = '\n' then
            let raw = Buffer.contents line in
            Ok (line_of_raw raw, raw, consumed + bytes + 1)
          else loop (bytes + 1))
  in
  loop 0

let request_reader ?(limit = request_head_limit) flow =
  Eio.Buf_read.of_flow ~max_size:(limit + 1) flow

let read_request_head ?(limit = request_head_limit) ic =
  let raw = Buffer.create 256 in
  let rec headers acc consumed =
    match read_line ~limit ~consumed ic with
    | Error error -> Error error
    | Ok (line, bytes, consumed) ->
        Buffer.add_string raw bytes;
        if line = "" then Ok (List.rev acc, consumed)
        else headers (line :: acc) consumed
  in
  match read_line ~limit ~consumed:0 ic with
  | Error error -> Error error
  | Ok (request_line, bytes, consumed) ->
      Buffer.add_string raw bytes;
      match headers [] consumed with
      | Error error -> Error error
      | Ok (header_lines, _consumed) ->
          Ok ({ request_line; header_lines }, Buffer.contents raw)

let status_line status =
  Printf.sprintf "HTTP/1.1 %d %s\r\n" status (reason_phrase status)

let content_length_line body_length =
  Printf.sprintf "content-length: %d\r\n" body_length

let connection_line = "connection: close\r\n"

(* [name ": " value CRLF]. *)
let header_bytes (name, value) = String.length name + String.length value + 4

let response_head_is_bounded ~limit ~status ~headers ~body_length =
  List.fold_left
    (fun total header -> total + header_bytes header)
    (String.length (status_line status))
    headers
  + String.length (content_length_line body_length)
  + String.length connection_line
  + 2
  <= limit

let response_head ?(limit = response_head_limit) ~status ~headers ~body_length () =
  if not (response_head_is_bounded ~limit ~status ~headers ~body_length) then
    Error Response_head_too_large
  else begin
    let buffer = Buffer.create 128 in
    Buffer.add_string buffer (status_line status);
    List.iter
      (fun (name, value) ->
        Buffer.add_string buffer name;
        Buffer.add_string buffer ": ";
        Buffer.add_string buffer value;
        Buffer.add_string buffer "\r\n")
      headers;
    Buffer.add_string buffer (content_length_line body_length);
    Buffer.add_string buffer connection_line;
    Buffer.add_string buffer "\r\n";
    Ok (Buffer.contents buffer)
  end
