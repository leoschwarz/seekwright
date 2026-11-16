(** CPU-bound extraction, isolated on a fixed-size pool of worker domains.

    A pool of {!workers_default} (by default) worker domains owned by the
    application, one job at a time per worker, fed over an AF_UNIX socket.

    - The number of worker domains is fixed at {!make} time and never grows.
    - At most [workers + queue_limit] jobs may be in flight or queued at once.
    - Request and response bodies cross the socket under byte ceilings
      ([~max_body_bytes], [~max_result_bytes]).
    - {!extract} with [~timeout_seconds] answers {!Timed_out} when the budget
      expires, closing the connection.
    - {!close} refuses all later {!extract} calls with {!Pool_closed}, tells
      each worker to stop, and waits for running jobs to finish. *)

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
