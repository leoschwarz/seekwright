(** CPU-bound extraction, isolated on a fixed-size pool of worker domains.

    The download cap bounds the {b input}; it does not bound the {b time} the
    backend then spends on it. A page under the cap can still send a parser
    into a long loop — the Python oracle's shape is a small PDF whose content
    stream is shared by every page, where parse work scales with the page
    count rather than with the bytes — and an extraction that runs inline on
    the Eio loop holds {i everyone else's} request: OCaml code that never
    yields on the loop's domain cannot be preempted by a timeout. So the fetch
    path runs extraction here instead: a pool of {!workers_default} (by
    default) ordinary {!Domain}t owned by the application, one job at a time
    per worker, fed over an AF_UNIX socket so the loop-side half stays a fully
    normal cancellable Eio exchange (see plans/ocaml-finalisation.md, F2.2).

    {1 Bounds, by construction}

    - The number of worker domains (and therefore OS threads) is fixed at
      {!make} time and never grows: a call {b cannot} create more, however
      many fetches arrive. {!workers_default} caps at four and leaves the
      machine's last core to the loop.
    - At most [workers + queue_limit] jobs may be in flight or queued at once;
      every further {!extract} fiber waits on that semaphore rather than
      opening another socket or domain.
    - Request and response bodies cross the socket under byte ceilings
      ([~max_body_bytes], [~max_result_bytes]); a frame whose declared length
      exceeds them closes the connection instead of allocating.

    {1 Cancellation, late results, and abandonment}

    A running OCaml domain cannot be cancelled safely, so the pool abandons
    rather than kills, and the abandonment is bounded:

    - {!extract} with [~timeout_seconds] answers {!Timed_out} when the budget
      expires, having closed the connection. The worker keeps running the
      extraction it was given, and when it finishes its {!extract_result}
      arrives on a closed socket and is {b discarded} — that write failure is
      how the worker observes the cancellation, cooperatively, at the next
      point its own code reaches. The abandoned job occupies one of the pool's
      fixed workers, never a new one.
    - An {!extract} whose {b caller's} fiber is cancelled (the chain budget
      firing around a whole fetch, a client going away) propagates
      [Eio.Cancel.Cancelled] — cancellation is control flow, not a failure —
      and the same socket-close-and-discard sequence applies.
    - A caller that abandons a job before the request was fully written leaves
      the worker reading EOF; it discards the half-arrived job and returns to
      the accept loop.

    {1 Shutdown}

    {!close} refuses all later {!extract} calls with {!Pool_closed}, tells
    each worker to stop, and {b waits for the running jobs to finish} before
    returning — the same "waited on, not stopped" rule the Python fetcher
    states about its worker threads, bounded here because the workers are
    finite and each takes one job at a time. A backend that never returns
    pins its worker (and {!close}) forever; that is the oracle's accepted
    divergence taken literally, and the pool's bound is what keeps it to
    [workers] pinned threads. After {!close} the socket paths are unlinked and
    every worker domain has been joined, so nothing outlives the call except
    an unreturnable backend.

    OCaml also terminates the process when its main domain exits, so a pool
    that is never closed cannot keep a dying process alive — {!close} is for
    orderly drain (F2.3), not for exit.

    {1 The backend, and what sharing it means}

    The backend passed to {!make} is captured by the worker domains at
    spawn time: its closure and any immutable data it captures are shared
    across domains, so a backend must be {b domain-safe} — pure over its
    arguments, or holding any mutable state behind its own synchronisation.
    Page bodies and results never cross as shared values: they are copied
    through the socket, which is also what keeps this whole module sound
    without a formal immutable-sharing argument about strings.

    {1 The socket}

    Workers bind [AF_UNIX] stream sockets under [~dir], named for the process
    and a pool sequence, created [0600] and unlinked on {!close}. A local
    process other than the server cannot connect to them; the paths carry no
    secrets and no page content. [~dir] must keep the full path within the
    kernel's 107-byte socket-name limit ({!make} refuses a longer one rather
    than failing at bind). *)

(** Why a job could not be answered. None of these is an exception, and the
    fetcher turns each into a caller-facing sentence at its own boundary. *)
type error =
  | Timed_out
      (** [~timeout_seconds] expired during the exchange. The deadline starts
          when the job takes its permit, not when it queues: the queue itself
          is bounded by [workers + queue_limit], and a wait for a permit is a
          wait on a bounded resource, not an unbounded one. (An [asyncio]
          [wait_for] around [Queue.get] measures both together only because
          the item is already off the queue when the deadline fires — the
          permit is likewise in hand before the deadline governs here.) Not
          retryable with the same bytes; the fetcher renders the oracle's
          "did not finish within N seconds; raise fetch.timeout_seconds"
          refusal. *)

  | Pool_closed
      (** {!close} has been called (or is underway). Transient in kind: it
          means this process is draining. *)

  | Backend of string
      (** The backend raised [Extractor.Extraction_failed] on the worker
          domain; the message is the backend's own, carried back across the
          socket — the same value the inline path gets from its [with] clause. *)

  | Worker of string
      (** The exchange around the worker failed: unreachable, truncated, or
          over a frame ceiling. A constant sentence naming the failure, never
          a rendered exception payload. *)

type t
(** A pool: fixed-size worker domains, bounded queue, round-robin dispatch. *)

val workers_default : int
(** The default pool size: one domain per detected core, leaving one for the
    Eio loop, capped at four — extraction isolation exists to keep the loop
    beating, not to parallelise a batch. *)

val make :
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  dir:string ->
  extractor:Extractor.backend ->
  ?workers:int ->
  ?queue_limit:int ->
  ?max_body_bytes:int ->
  ?max_result_bytes:int ->
  unit ->
  (t, string) result
(** [make ~net ~mono_clock ~dir ~extractor ()] spawns the workers and returns
    once every one of them is listening. [net] and [mono_clock] come from the
    application's env — this is the app-owned seam, built once under the
    server's switch and closed through the reader's [aclose] — and neither is
    touched by the worker domains: they speak plain [Unix] syscalls.

    [~workers] (default {!workers_default}, minimum 1) is the pool size;
    [~queue_limit] (default [workers]) how many further jobs may queue behind
    it. [~max_body_bytes] (default 8 MiB, and the factory passes
    [fetch.max_download_bytes]) bounds what a request frame may declare, and
    [~max_result_bytes] (default four times that) what a response frame may.

    Failure is a value: a worker that cannot bind its socket, or a [~dir]
    whose paths exceed the socket-name limit, is an [Error] naming the cause —
    a fetch stack built on a pool that does not exist would silently run
    inline again, and that is the failure mode this constructor exists to
    make loud.

    [make] blocks its {b fiber} on the workers' readiness pipes — a bounded
    startup wait (bind and listen do not block), meant to happen once during
    construction, not per request. *)

val extract :
  ?timeout_seconds:float ->
  t ->
  body:string ->
  content_type:string option ->
  (Extractor.extract_result, error) result
(** Run [extractor.extract body content_type] on a worker. The call suspends
    the calling fiber only: the loop domain keeps running while the parse
    burns its own core. [~timeout_seconds] bounds the exchange, counted from
    the moment the job is admitted (see the header); without it a job runs to
    completion.

    Every failure is a value ({!error}); only a cancellation from {b outside}
    this call — the caller's own budget, its switch closing — unwinds, and it
    unwinds as [Eio.Cancel.Cancelled], unchanged. *)

val close : t -> unit
(** Refuse later {!extract}s, tell every worker to stop, and join the domains
    once their running jobs finish (see the header's shutdown section).
    Idempotent. Not for use while traffic is still arriving: it blocks the
    calling fiber until the last running extraction returns. *)
