(* CPU-bound extraction, isolated on a fixed-size pool of worker domains.
   See extract_pool.mli for the contract: bounds, abandonment, shutdown.

   The transport between the loop and a worker is an AF_UNIX stream socket,
   not a shared-memory queue, on purpose. The loop-side half of an exchange is
   then an ordinary Eio flow: [Eio.Time.Timeout] can cut it, a cancelled
   caller closes it, and the worker sees EOF exactly when its client is gone —
   which is the cooperative half of "the worker observes the cancellation". A
   mutex-and-cond queue would need a second mechanism (a pipe, a promise) to
   deliver that same wake-up, and promise resolution from another domain is
   exactly the thread-safety trap the type system does not police. The copies
   the sockets force are also what makes cross-domain sharing boring: only the
   immutable backend closure is shared; page bodies and results are bytes. *)

module E = Extractor

type error =
  | Timed_out
  | Pool_closed
  | Backend of string
  | Worker of string

(* {1 The frame grammar}

   Big-endian i64s throughout, no endianness argument to have with a worker
   in the same process. Length-prefixed rather than EOF-delimited on both
   sides: a request is one frame the worker can validate against
   [max_body_bytes] before allocating, and a response is one frame the loop
   can bound the same way. A frame that declares more than its ceiling gets
   the connection closed, never the allocation. *)

let i64_to_string (v : int64) : string =
  let b = Bytes.create 8 in
  for i = 0 to 7 do
    Bytes.set b i
      (Char.unsafe_chr
         (Int64.to_int (Int64.logand (Int64.shift_right_logical v ((7 - i) * 8)) 0xFFL)))
  done;
  Bytes.to_string b

let i64_of_string (s : string) : int64 =
  let n = ref 0L in
  for i = 0 to 7 do
    n := Int64.logor (Int64.shift_left !n 8) (Int64.of_int (Char.code s.[i]))
  done;
  !n

let kind_job = 0L
let kind_quit = 1L
let status_ok = 0L
let status_backend = 1L

(* The one spelling of "this optional value is absent" on the wire: a length
   of -1, where any real length is >= 0. *)
let absent = -1L

(* {1 The worker side (plain Unix; no Eio inside a worker domain)} *)

let write_all fd (s : string) =
  let b = Bytes.of_string s in
  let n = Bytes.length b in
  let rec go off =
    if off >= n then ()
    else go (off + Unix.write fd b off (n - off))
  in
  go 0

let read_exact fd (buf : bytes) off len =
  let rec go off len =
    if len = 0 then ()
    else
      let n = Unix.read fd buf off len in
      if n = 0 then raise End_of_file;
      go (off + n) (len - n)
  in
  go off len

let read_i64 fd =
  let b = Bytes.create 8 in
  read_exact fd b 0 8;
  i64_of_string (Bytes.to_string b)

(* [read_bounded fd limit] reads a length-prefixed string, refusing (raising
   [Exit], which the per-connection handler turns into "drop this client") a
   length outside [0, limit] — an [absent] optional field has already been
   filtered out by the caller that owns it. *)
let read_bounded fd limit =
  let len = read_i64 fd in
  if len < 0L || len > Int64.of_int limit then raise Exit;
  let n = Int64.to_int len in
  let b = Bytes.create n in
  read_exact fd b 0 n;
  Bytes.to_string b

let result_frame (r : E.extract_result) =
  let title_field =
    match r.title with
    | Some t -> i64_to_string (Int64.of_int (String.length t)) ^ t
    | None -> i64_to_string absent
  in
  String.concat ""
    [
      i64_to_string status_ok;
      i64_to_string (Int64.of_int (String.length r.text));
      r.text;
      title_field;
      i64_to_string (Int64.of_int r.total_chars);
      i64_to_string (if r.path_addressable then 1L else 0L);
    ]

let backend_frame (message : string) =
  String.concat ""
    [
      i64_to_string status_backend;
      i64_to_string (Int64.of_int (String.length message));
      message;
    ]

(* One accepted connection: a job frame, the extraction, a response frame —
   or the quit sentinel. [Exit] / [End_of_file] / [Unix_error] mean "the
   client is gone or sent nonsense": the job is discarded and the worker
   returns to the accept loop, which is the abandonment half of the contract.
   The response write is allowed to fail: that failure is the worker
   observing a cancellation the loop already acted on, and the late result is
   discarded. *)
let serve_one conn ~(extractor : E.backend) ~max_body_bytes =
  match read_i64 conn with
  | kind when kind = kind_quit -> `quit
  | kind when kind = kind_job ->
      let body = read_bounded conn max_body_bytes in
      (* One length-prefixed optional: [absent] or [length, bytes]. The length
         is this [match]'s to consume, so the bytes are read against it
         directly — a [read_bounded] here would read a second length the
         writer never sent and desynchronise the frame. *)
      let content_type =
        match read_i64 conn with
        | l when l = absent -> None
        | l ->
            if l < 0L || l > Int64.of_int max_body_bytes then raise Exit;
            let n = Int64.to_int l in
            let b = Bytes.create n in
            read_exact conn b 0 n;
            Some (Bytes.to_string b)
      in
      let frame =
        (try `Ok (extractor.extract body content_type)
         with
         | E.Extraction_failed message -> `Backend message
         | _ ->
             (* The backend broke its own contract (an extract may raise only
                [Extraction_failed]). Keep the worker, report a constant, and
                never render the exception: the source-discipline rule
                against raw exception printers is about what leaves the
                process, and this sentence does leave the process — into the
                caller's refusal. *)
             `Backend "the extraction backend raised an unexpected failure")
      in
      (match frame with
      | `Ok r -> (try write_all conn (result_frame r) with Unix.Unix_error _ -> ())
      | `Backend message -> (try write_all conn (backend_frame message) with Unix.Unix_error _ -> ()));
      `job
  | _ -> `job

let listen path =
  let sock = Unix.(socket PF_UNIX SOCK_STREAM 0) in
  (try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  try
    Unix.bind sock (Unix.ADDR_UNIX path);
    (* The socket carries extraction work; a socket a local attacker can
       connect to spends the pool. [bind]'s mode comes from the umask, so
       say the mode we mean rather than inheriting one. *)
    Unix.chmod path 0o600;
    (* A connected socket needs the listen before it will answer one: bind
       alone leaves [connect] refused and [accept] an error. The backlog is
       [workers + queue_limit]-shaped because the pool itself is the only
       client, and it never opens more than that many connections at once. *)
    Unix.listen sock 16;
    sock
  with
  | Unix.Unix_error _ ->
      Unix.close sock;
      (try Unix.unlink path with Unix.Unix_error _ -> ());
      raise Exit

let accept_loop sock ~(extractor : E.backend) ~max_body_bytes =
  let quit = ref false in
  while not !quit do
    let stop =
      try
        let conn, _addr = Unix.accept sock in
        let stop =
          (try
             match serve_one conn ~extractor ~max_body_bytes with
             | `quit -> true
             | `job -> false
           with End_of_file | Exit | Unix.Unix_error _ | Sys_error _ -> false)
        in
        (try Unix.close conn with Unix.Unix_error _ -> ());
        stop
      with Unix.Unix_error _ ->
        (* A failing [accept] is a broken socket, not a closed one: sleep a
           beat so a dead worker cannot hot-spin, and stay alive to take the
           quit sentinel at [close]. *)
        Unix.sleepf 0.01;
        false
    in
    quit := stop
  done

let worker_main ~path ~(extractor : E.backend) ~max_body_bytes ~ready =
  (* [ready] is this worker's readiness-pipe write-end: the constructor's
     blocking half, so a pool never accepts a job before the socket exists,
     and a worker that could not bind is reported instead of hanging. *)
  let report byte =
    (try ignore (Unix.write ready (Bytes.make 1 byte) 0 1) with Unix.Unix_error _ -> ());
    (try Unix.close ready with Unix.Unix_error _ -> ())
  in
  let sock =
    try Some (listen path) with Exit | Unix.Unix_error _ | Sys_error _ -> None
  in
  match sock with
  | None -> report 'E'
  | Some sock ->
      report 'R';
      accept_loop sock ~extractor ~max_body_bytes;
      (try Unix.close sock with Unix.Unix_error _ -> ());
      (try Unix.unlink path with Unix.Unix_error _ -> ())

(* {1 The pool} *)

(* [Eio.Net.t] and [Eio.Time.Mono.t] are parameterised by the backend's
   resource tag, and a record type cannot carry an existential tag — [_] is
   not allowed in a type declaration. So the record is parameterised and [t]
   hides the tags, exactly as [Policy_net] does: the application's own net and
   clock keep their real types, and nothing here needs to name them. *)
type ('tag, 'clock) pool = {
  net : 'tag Eio.Net.t;
  mono_clock : 'clock Eio.Time.Mono.t;
  paths : string array;
  domains : unit Domain.t array;
  (* Only loop-domain fibers touch these: every [extract] runs as a fiber of
     the loop the pool was built on, so the round-robin counter needs no
     synchronisation beyond evaluation — the same single-Eio-domain
     critical-section invariant [Health] and [Usage] hold (F2.4). [closed] is
     [Atomic] because [close] answers [Pool_closed] to an [extract] racing
     with it, and that check must not interleave mid-construction. *)
  permits : Eio.Semaphore.t;
  next : int ref;
  closed : bool Atomic.t;
  max_result_bytes : int;
}

type t = T : ('tag, 'clock) pool -> t

let workers_default = max 1 (min 4 (Domain.recommended_domain_count () - 1))

(* Unique per process even when one process builds several pools (the suite
   does; one case per scenario is the point): pid, pool sequence, worker
   index. A process-global sequence is another single-domain value — [make]
   runs on the loop. *)
let pool_seq = Atomic.make 0

(* Linux's [sockaddr_un] name is 108 bytes including the NUL; [bind] answers
   a longer path with an error that reads nothing like "your directory is too
   deep", so refuse with the real sentence first. *)
let socket_name_limit = 107

let too_long paths =
  let rec go i =
    if i >= Array.length paths then false
    else String.length paths.(i) > socket_name_limit || go (i + 1)
  in
  go 0

let send_quit path =
  try
    let fd = Unix.(socket PF_UNIX SOCK_STREAM 0) in
    (try
       Unix.connect fd (Unix.ADDR_UNIX path);
       write_all fd (i64_to_string kind_quit)
     with Unix.Unix_error _ -> ());
    Unix.close fd
  with Unix.Unix_error _ -> ()

let make ~net ~mono_clock ~dir ~(extractor : E.backend) ?(workers = workers_default)
    ?queue_limit ?(max_body_bytes = 8_388_608) ?max_result_bytes () =
  if workers < 1 then Error "the extraction pool needs at least one worker"
  else
    let queue_limit =
      match queue_limit with Some n when n >= 0 -> n | Some _ -> 0 | None -> workers
    in
    let max_result_bytes =
      match max_result_bytes with Some n when n > 0 -> n | _ -> 4 * max_body_bytes
    in
    let seq = Atomic.fetch_and_add pool_seq 1 in
    let paths =
      Array.init workers (fun i ->
        Filename.concat dir
          (Printf.sprintf "seekwright-extract-%d-%d-%d.sock" (Unix.getpid ()) seq i))
    in
    if too_long paths then
      Error
        (Printf.sprintf
           "the extraction pool's socket path in %S exceeds the %d-byte limit of a \
            unix socket name; point it at a shorter directory"
           dir socket_name_limit)
    else
      (* Spawn, then wait on each worker's readiness byte. The worker reports
         exactly one byte — ['R] listening, ['E] could not bind — before it can
         die, so the read never needs an EOF to make progress: the parent keeps
         the pipe's write-end open (only the worker ever closes it) and a
         double [close] here would be a use-after-close on a shared fd table —
         domains are threads, [Unix.file_descr]s are process-wide, and a second
         close of a number some other domain just reused silently kills that
         domain's socket. (This was the stall the suite caught: the pool
         construction that follows, [accept] never fed its quit sentinel, and
         [Domain.join] waited forever.) A worker that died before writing its
         byte answers EOF: clean up the ones that did start and refuse the
         whole pool — a fetch stack running with fewer workers than it believes
         (or none) is the silent failure this constructor exists to make loud. *)
      let started = ref ([] : (unit Domain.t * Unix.file_descr) list) in
      let failure = ref None in
      Array.iteri
        (fun i path ->
          let ready_read, ready_write = Unix.pipe () in
          let domain =
            Domain.spawn
              (fun () ->
                worker_main ~path ~extractor ~max_body_bytes ~ready:ready_write)
          in
          started := (domain, ready_read) :: !started;
          let b = Bytes.create 1 in
          (match Unix.read ready_read b 0 1 with
          | 1 when Bytes.get b 0 = 'R' -> ()
          | _ ->
              if !failure = None then
                failure :=
                  Some
                    (Printf.sprintf "extraction worker %d could not listen on %s" i
                       path));
          Unix.close ready_read)
        paths;
      match !failure with
      | Some message ->
          (* Quit first, join second: a worker that reported readiness is
             still in its accept loop and would hold [Domain.join] forever
             otherwise; one that failed to bind has already returned and just
             refuses the connect. *)
          Array.iter send_quit paths;
          List.iter (fun (domain, _ready_read) -> Domain.join domain) !started;
          Error message
      | None ->
         (* [close] has each worker unlink its own path on the way out; this
            is the safety net for a process that exits without one — the path
            sits in a shared temp directory, and a stale file is an unclaimed
            inode a later operator has to hunt. Idempotent: an unlink failure
            is exactly "already gone". *)
         at_exit
           (fun () ->
             Array.iter
               (fun p -> try Unix.unlink p with Unix.Unix_error _ -> ())
               paths);
         Ok
            (T
               {
                 net;
                 mono_clock;
                 paths;
                 domains = Array.of_list (List.map fst (List.rev !started));
                 permits = Eio.Semaphore.make (workers + queue_limit);
                 next = ref 0;
                 closed = Atomic.make false;
                 max_result_bytes;
               })

(* {1 The exchange, loop side (Eio direct style)} *)

let exchange (t : _ pool) flow ~body ~content_type =
  Eio.Buf_write.with_flow flow (fun w ->
    let write_i64 v = Eio.Buf_write.string w (i64_to_string v) in
    write_i64 kind_job;
    write_i64 (Int64.of_int (String.length body));
    Eio.Buf_write.string w body;
    match content_type with
    | None -> write_i64 absent
    | Some c ->
        write_i64 (Int64.of_int (String.length c));
        Eio.Buf_write.string w c);
  (* [+ 1] is the [Buf_read] idiom: the limit is an allocation ceiling, and a
     frame declaring more than [max_result_bytes] still cannot make the loop
     allocate past it. *)
  let r = Eio.Buf_read.of_flow flow ~max_size:(t.max_result_bytes + 1) in
  let read_i64 () = i64_of_string (Eio.Buf_read.take 8 r) in
  let read_field limit =
    let len = read_i64 () in
    if len < 0L || len > Int64.of_int limit then raise Exit;
    Eio.Buf_read.take (Int64.to_int len) r
  in
  match read_i64 () with
  | s when s = status_ok ->
      let text = read_field t.max_result_bytes in
      (* [absent] or [length, bytes] — the same optional grammar as the
         request, and here too the length this arm matches on is the length
         the bytes are read against. *)
      let title =
        match read_i64 () with
        | l when l = absent -> None
        | l ->
            if l < 0L || l > Int64.of_int t.max_result_bytes then raise Exit;
            Some (Eio.Buf_read.take (Int64.to_int l) r)
      in
      let total_chars = Int64.to_int (read_i64 ()) in
      let path_addressable = read_i64 () = 1L in
      Ok { E.text; title; total_chars; path_addressable }
  | s when s = status_backend -> Error (Backend (read_field t.max_result_bytes))
  | _ -> Error (Worker "the extraction worker answered with an unknown status")

(* One mapping from a failed exchange onto a value. Cancellation is notably
   absent: [Eio.Cancel.Cancelled] and [Eio.Exn.Multiple] re-raise through the
   fallthrough, because a caller's cancellation must not become a fetch
   failure (the rule the grant wrappers already hold). *)
let classify exn =
  match exn with
  | Eio.Buf_read.Buffer_limit_exceeded ->
      Error (Worker "the extraction result exceeded the response ceiling")
  | End_of_file | Exit -> Error (Worker "the extraction worker did not answer completely")
  | Eio.Io (_, _) ->
      (* The payload can name our own socket path and an OS detail; the
         caller-facing sentence keeps neither. *)
      Error (Worker "the extraction worker could not be reached")
  | _ -> raise exn

(* Take a permit un-cancellably. [Eio.Semaphore.acquire] loses a permit when a
   fiber parked in it is cancelled in the window between being handed the
   permit and resuming (its cancel hook answers "already resumed" and the
   grant is dropped): a timed-out queue-waiter can therefore shrink the pool's
   budget forever, which is the stall the pressure case reproduces under the
   gate. [Cancel.protect] makes the park uninterruptible — the cancellation
   lands at [Fiber.check] just below, permit in hand — and mirrors [asyncio],
   where [Queue.get] has already taken the item by the time a [wait_for]
   deadline fires around it. *)
let extract ?timeout_seconds (T t) ~body ~content_type =
  if Atomic.get t.closed then Error Pool_closed
  else begin
    Eio.Cancel.protect (fun () -> Eio.Semaphore.acquire t.permits);
    (* Queue wait is bounded by the semaphore's own ceiling, not by
       [timeout_seconds]: the deadline measures the exchange below, from the
       moment this job is admitted. *)
    let exchange_job () =
      (* Round-robin dispatch: only loop-domain fibers run this (every
         [extract] is a fiber of the pool's own loop), so [next] needs no
         synchronisation beyond evaluation. The exchange runs on its own
         switch so cancellation — this call's budget or its caller's — closes
         the socket on the way out. *)
      let i =
        let x = !(t.next) in
        t.next := x + 1;
        x mod Array.length t.paths
      in
      Eio.Switch.run (fun sw ->
        let flow = Eio.Net.connect ~sw t.net (`Unix t.paths.(i)) in
        exchange t flow ~body ~content_type)
    in
    let guarded f = try f () with exn -> classify exn in
    Fun.protect
      ~finally:(fun () -> Eio.Semaphore.release t.permits)
      (fun () ->
        (* A caller cancelled while queued unwinds here — cancellation is
           control flow, not a fetch failure — and [Fun.protect] returns the
           permit it arrived with; that is why this check sits inside the
           guard and not above it. *)
        Eio.Fiber.check ();
        match timeout_seconds with
        | None -> guarded exchange_job
        | Some seconds ->
            (try
               (* [run_exn] rather than [run]: the body's error channel is
                  this sum type, not a row [Timeout.run] would widen — the
                  same pattern the fetcher's chain budget uses. The timeout
                  cancels the body, whose [Eio.Io] on the half-closed socket
                  [classify] would map to [Worker]; [run_exn] attributes the
                  cancelled body to the deadline, so the answer is
                  [Timed_out]. *)
               guarded (fun () ->
                 Eio.Time.Timeout.run_exn
                   (Eio.Time.Timeout.seconds t.mono_clock seconds) exchange_job)
             with Eio.Time.Timeout -> Error Timed_out))

end

let close (T t) =
  if Atomic.get t.closed then ()
  else begin
    Atomic.set t.closed true;
    (* Unblock each accept loop with the quit sentinel. A worker mid-job takes
       it after the job — [close] waits, as the interface says — and a worker
       already gone refuses the connect, which is equally done. The worker
       unlinks its own path on the way out. *)
    Array.iter send_quit t.paths;
    Array.iter Domain.join t.domains
  end
