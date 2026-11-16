type t = {
  log : (Event.t -> unit) option;
  operation_timeout : Eio.Time.Timeout.t;
  budget : Budget.t option;
}

let none = { log = None; operation_timeout = Eio.Time.Timeout.none; budget = None }

let with_log ~sink t = { t with log = Some sink }
let with_operation_timeout timeout t = { t with operation_timeout = timeout }
let with_operation_budget budget t = { t with budget = Some budget }

let emit t event = match t.log with None -> () | Some sink -> sink event

(* Refusal sentence names budget count, never arguments: content leak prevention. *)
let spent_message operation budget =
  Printf.sprintf
    "%s: refused — the operation budget of %d is spent (a budget is spent by the code that created \
     it, so this is the caller's ceiling, not the grant's)"
    operation (Budget.limit budget)

let outcome = function Ok _ -> Event.Ok | Error error -> Event.Failed (Error.kind error)

let run t ~operation ?measure ?notes body =
  let guarded =
    match t.budget with
    | None -> Ok ()
    | Some budget ->
        if Budget.take budget then Ok ()
        else Error (Error.make Error.Denied ~message:(spent_message operation budget))
  in
  let result =
    match guarded with
    | Error _ as refusal -> refusal
    | Ok () -> (
        (* [run_exn] catches only [Eio.Time.Timeout]; [Cancelled] propagates. *)
        try Eio.Time.Timeout.run_exn t.operation_timeout body
        with Eio.Time.Timeout ->
          Error
            (Error.make Error.Timeout
               ~message:
                 (Printf.sprintf "%s: the operation exceeded its time bound and was cancelled"
                    operation)))
  in
  let event = Event.make ~operation (outcome result) in
  let event =
    match (result, measure) with
    | Ok value, Some measure -> (
        match measure value with None -> event | Some bytes -> Event.with_bytes bytes event)
    | _ -> event
  in
  let event =
    match (result, notes) with
    | Ok value, Some notes ->
        List.fold_left (fun acc (key, value) -> Event.add_note ~key ~value acc) event (notes value)
    | _ -> event
  in
  emit t event;
  result
