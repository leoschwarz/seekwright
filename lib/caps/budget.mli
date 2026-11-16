(** Counted ceiling on authority operations, owned by the caller.
    [t] is an atomic counter shared across concurrent fibers, bounding operation
    count rather than data size. *)

type t

val make : int -> t
(** [make n] is a budget of [n] operations. [n <= 0] refuses all operations. *)

val limit : t -> int
(** Initial operation ceiling passed to [make]. *)

val remaining : t -> int
(** Count still available; a snapshot, not a reservation. *)

val take : t -> bool
(** [take t] atomically spends one operation; returns [false] when spent. *)
