type t = { limit : int; spent : int Atomic.t }

let make limit = { limit; spent = Atomic.make 0 }

let limit t = t.limit

let remaining t =
  let left = t.limit - Atomic.get t.spent in
  if left < 0 then 0 else left

let take t =
  (* CAS loop preserves strict limit without overshooting under concurrent calls. *)
  if t.limit <= 0 then false
  else
    let rec retry () =
      let spent = Atomic.get t.spent in
      if spent >= t.limit then false
      else if Atomic.compare_and_set t.spent spent (spent + 1) then true
      else retry ()
    in
    retry ()
