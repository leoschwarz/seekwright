(** A counted ceiling on authority operations, owned by the code that spends it.

    Why this is a separate value and not a number inside a grant
    (plans/capability-gated-mcp-server.md §6 refuses "a generic operation budget"
    precisely because "a counter stored in a server-lifetime grant is a
    server-lifetime budget, not a per-request one"): a [t] is a mutable cell the
    *caller* creates — per request, per tool call, per plan — and hands to
    [Authority.with_operation_budget]. The grant stays a server-lifetime value; the
    thing that runs out is the caller's, which is the only scope this layer can
    actually name without an mcp-kit request hook (§7). Seekwright's server
    construction therefore attaches no budget at all: a counter reached at startup
    would be a server-lifetime budget wearing a request's name. What bounds a
    served request is its own operation timeout, and a caller that wants a ceiling
    on the operations it causes wraps the grant it holds — the two cases
    [test/test_caps_budget.ml] pins.

    [take] is atomic, because a grant may be shared by concurrent fibers (§1) and
    an unsynchronised counter would let N fibers all pass the same check. What the
    budget bounds is the *count* of operations, never their cost: a 1-byte read
    and a 1 MiB read each spend one. *)

type t

val make : int -> t
(** [make n] is a budget of [n] operations. [n <= 0] is a budget that spends
    nothing: every operation through it is refused. *)

val limit : t -> int
(** what [make] was given *)

val remaining : t -> int
(** the count still available; a snapshot, not a reservation *)

val take : t -> bool
(** [take t] spends one operation, [false] when the budget is already spent. *)
