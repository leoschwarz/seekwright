(** The bounds every authority operation reads, whatever kind of grant it is.

    A grant is a confinement decision (which subtree, which endpoints) plus this
    record (how the operation is bounded and reported). Splitting them is what
    makes the decorators in [Authority] / [Policy] generic: [with_log],
    [with_operation_timeout] and [with_operation_budget] change only this
    component, so they work for every kind and a new kind inherits them by
    carrying one (plans/capability-gated-mcp-server.md §3, "a GADT … plus a
    shared controls record. Every operation goes through that controls record",
    and §6 for the two decorators it commits to).

    [run] is that "goes through": it is the one place the budget is spent, the
    timeout is applied and the audit event is written, so no operation can be
    bounded differently from its siblings by forgetting a line of its own. *)

type t = {
  log : (Event.t -> unit) option;
  (** [None] is silent: the application opts in by giving a sink (§6). *)
  operation_timeout : Eio.Time.Timeout.t;
  (** One bound per operation, covering the whole operation, not one per
      attempt. [Eio.Time.Timeout.none] is unbounded; it carries its own clock
      because a timeout belongs on a monotonic clock. *)
  budget : Budget.t option;
  (** A caller-owned counter (§6); [None] counts nothing. *)
}

val none : t
(** silent, unbounded, uncounted — what a grant carries until a decorator is
    applied to it. *)

val with_log : sink:(Event.t -> unit) -> t -> t
val with_operation_timeout : Eio.Time.Timeout.t -> t -> t
val with_operation_budget : Budget.t -> t -> t

val run :
  t ->
  operation:string ->
  ?measure:('a -> int option) ->
  ?notes:('a -> (string * string) list) ->
  (unit -> ('a, Error.t) result) ->
  ('a, Error.t) result
(** [run controls ~operation f] is the shared wrapper every operation body runs
    inside, in this order:

    - spend one [budget] operation, or refuse with [Denied] without running [f]
      at all — a spent budget does no I/O, which is what makes a budget test
      observable at the far end;
    - run [f] under [operation_timeout], turning a cancellation into [Timeout];
    - hand the application one [Event.t] naming [operation] and its outcome,
      sized by [measure] and annotated by [notes].

    The event is bounded and content-free by construction ([Event]), so a
    deployment can log every operation without a page, a body, or a header
    reaching the log. *)
