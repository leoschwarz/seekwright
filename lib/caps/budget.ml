(* One atomic counter. Atomic rather than a mutable int because the grant that
   carries a budget is shareable across fibers (plans/capability-gated-mcp-server.md
   §1), and a budget whose check and decrement are not one step over-counts under
   exactly the concurrency a tool surface sees. *)

type t = { limit : int; spent : int Atomic.t }

(* A non-positive limit is kept as given so [limit] reports what the operator
   wrote, and [take] refuses it directly: storing it as 0 would report a budget
   of nothing while a caller that reads [limit] back sees a different number. *)
let make limit = { limit; spent = Atomic.make 0 }

let limit t = t.limit

(* A snapshot, not a reservation: what [remaining] reports may already be spent
   by the time the caller acts on it. [take] is the only step that reserves. *)
let remaining t =
  let left = t.limit - Atomic.get t.spent in
  if left < 0 then 0 else left

let take t =
  (* Compare-and-set on the spent count rather than [Atomic.incr] plus a read:
     the read after an increment is not the value this call reserved, so two
     fibers at the boundary could both be told yes. *)
  if t.limit <= 0 then false
  else
    let rec retry () =
      let spent = Atomic.get t.spent in
      if spent >= t.limit then false
      else if Atomic.compare_and_set t.spent spent (spent + 1) then true
      else retry ()
    in
    retry ()
