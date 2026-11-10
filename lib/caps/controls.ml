(* The shared controls record and the one wrapper that applies it. See
   controls.mli for why the bounds live beside the confinement decision rather
   than inside each kind's own operations: it is what lets a decorator apply to
   every grant kind, and what stops one operation from being bounded differently
   from its siblings by a forgotten line. *)

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

(* The refusal sentence for a spent budget names the count, which the caller set,
   and never the operation's argument — an over-long or content-carrying message
   is the failure mode [Error.sanitize] exists for, and here there is nothing
   worth naming but the number. *)
let spent_message operation budget =
  Printf.sprintf
    "%s: refused — the operation budget of %d is spent (a budget is spent by the code that \
     created it, so this is the caller's ceiling, not the grant's)"
    operation (Budget.limit budget)

let outcome = function Ok _ -> Event.Ok | Error error -> Event.Failed (Error.kind error)

let run t ~operation ?measure ?notes body =
  let guarded =
    match t.budget with
    | None -> Ok ()
    | Some budget ->
        if Budget.take budget then Ok () else Error (Error.make Error.Denied ~message:(spent_message operation budget))
  in
  let result =
    match guarded with
    | Error _ as refusal -> refusal
    | Ok () -> (
        (* [Timeout.run_exn] cancels the body's fiber when the bound expires,
           which is also what closes the per-operation [Eio.Switch.t] a network
           operation opens: the bound covers DNS, connect, TLS, headers and body
           because it sits outside all of them (§5).

           [run_exn] rather than [Timeout.run]: the non-raising form widens the
           body's own error channel with a [`Timeout] case, and this layer's
           error channel is the abstract [Error.t], so the two cannot unify. The
           exception is turned straight back into a classified [Error.t], and an
           [Eio.Cancel.Cancelled] is not this exception — it keeps propagating,
           which is what the plan's "cancellation must not become a provider
           failure" rule needs. *)
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
        match measure value with
        | None -> event
        | Some bytes -> Event.with_bytes bytes event)
    | _ -> event
  in
  let event =
    match (result, notes) with
    | Ok value, Some notes -> List.fold_left (fun acc (key, value) -> Event.add_note key value acc) event (notes value)
    | _ -> event
  in
  emit t event;
  result
