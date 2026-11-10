type outcome =
  | Ok
  | Failed of Error.kind

type t = {
  operation : string;
  outcome : outcome;
  bytes : int option;
  notes : (string * string) list;
}

(* Same reasoning as Error.max_message_bytes: a log line's length must come from
   our fixed field set, never from what a caller or a provider happened to send. *)
let max_notes = 8

(* The same one-line rule applies to the operation name and to note keys: they
   are constants chosen by the application, but "constant" is a convention, not
   a type, so [sanitize] makes the invariant hold even for a mistaken caller. *)
let make ~operation outcome =
  { operation = Error.sanitize operation; outcome; bytes = None; notes = [] }

let with_bytes bytes t = { t with bytes = Some bytes }

let add_note key value t =
  if List.length t.notes >= max_notes then t
  else { t with notes = (Error.sanitize key, Error.sanitize value) :: t.notes }

let operation t = t.operation
let outcome t = t.outcome
let bytes t = t.bytes
let notes t = t.notes

let render_outcome = function
  | Ok -> "ok"
  | Failed kind -> "failed:" ^ Error.kind_to_string kind

let render t =
  let bytes =
    match t.bytes with
    | None -> ""
    | Some bytes -> " bytes=" ^ string_of_int bytes
  in
  let notes =
    List.fold_left
      (fun acc (key, value) -> acc ^ " " ^ key ^ "=" ^ value)
      ""
      (List.rev t.notes)
  in
  "caps." ^ t.operation ^ " " ^ render_outcome t.outcome ^ bytes ^ notes
