type outcome = Ok | Failed of Error.kind

type t = {
  operation : string;
  outcome : outcome;
  bytes : int option;
  notes : (string * string) list;
}

let max_notes = 8

let make ~operation outcome =
  { operation = Error.sanitize operation; outcome; bytes = None; notes = [] }

let with_bytes bytes t = { t with bytes = Some bytes }

let add_note ~key ~value t =
  if List.length t.notes >= max_notes then t
  else { t with notes = (Error.sanitize key, Error.sanitize value) :: t.notes }

let operation t = t.operation
let outcome t = t.outcome
let bytes t = t.bytes
let notes t = t.notes

let outcome_to_string = function Ok -> "ok" | Failed kind -> "failed:" ^ Error.kind_to_string kind

let render t =
  let bytes = match t.bytes with None -> "" | Some bytes -> " bytes=" ^ string_of_int bytes in
  let notes =
    List.fold_left (fun acc (key, value) -> acc ^ " " ^ key ^ "=" ^ value) "" (List.rev t.notes)
  in
  "caps." ^ t.operation ^ " " ^ outcome_to_string t.outcome ^ bytes ^ notes
