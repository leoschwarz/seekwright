(* The extraction runner (F2.2): a parse must cost its own core, never the Eio
   loop's, and it must come back on a deadline rather than hold everyone else's
   request. The oracle's shape is tests/fetch/test_fetch_guardrails.py's
   [_GrindingExtractor] and [TestExtractionTime] — the loop-open case, the
   overrunning parse, the bounded pressure — ported onto the pool directly
   rather than through the fetcher; test_fetch_workers.ml carries the same
   backend through the fetch path. The oracle's real-PDF case (a content
   stream shared by every page) waits with PDF support, not here: this port
   ships no PDF backend.

   Everything is hermetic: loopback AF_UNIX sockets under the temp dir,
   backends that grind on flags the suite releases, and no outcome decided by
   a wall-clock sleep — the assertions are counters and values; the time
   windows are the oracle's, held wide. *)

module K = Seekwright_fetch.Extract_pool
module E = Seekwright_fetch.Extractor
module S = Seekwright_fetch_stdlib.Stdlib

module A = Alcotest

(* The main (loop) domain. A backend that ran on a worker records its own
   domain, and this is the value it must differ from — the oracle's
   [grinder.thread is not threading.current_thread()]. *)
let main_domain = Domain.self ()

(* The grinding backend, port of [_GrindingExtractor]: [busy] burns a core the
   way pypdf does, the default waits on a timer the way a parse that has lost
   the plot does, and [stop] releases a grind the deadline already abandoned so
   [close] never waits out a burn the suite has refused. All its state is
   [Atomic] because the backend's closure is shared into the worker domains —
   a plain [ref] across domains is the race the pool's domain-safety rule
   ([extract_pool.mli]) names. *)
type grinder = {
  stop : bool Atomic.t;
  busy : bool Atomic.t;
  seconds : float Atomic.t;
  inflight : int Atomic.t;
  high : int Atomic.t;
  started : int Atomic.t;
  finished : int Atomic.t;
  last_domain : Domain.id Atomic.t;
}

let make_grinder () =
  {
    stop = Atomic.make false;
    busy = Atomic.make false;
    seconds = Atomic.make 0.5;
    inflight = Atomic.make 0;
    high = Atomic.make 0;
    started = Atomic.make 0;
    finished = Atomic.make 0;
    last_domain = Atomic.make main_domain;
  }

let release (g : grinder) = Atomic.set g.stop true

let grinder_backend (g : grinder) =
  {
    E.name = "grinding";
    supported_types = E.pdf_types;
    extract = (fun _body _content_type ->
      Atomic.set g.last_domain (Domain.self ());
      ignore (Atomic.fetch_and_add g.started 1);
      let now = Atomic.fetch_and_add g.inflight 1 + 1 in
      let rec bump_high () =
        let h = Atomic.get g.high in
        if now <= h || Atomic.compare_and_set g.high h now then () else bump_high ()
      in
      bump_high ();
      let deadline = Unix.gettimeofday () +. Atomic.get g.seconds in
      while Atomic.get g.stop = false && Unix.gettimeofday () < deadline do
        if Atomic.get g.busy then () else Unix.sleepf 0.01
      done;
      ignore (Atomic.fetch_and_add g.inflight (-1));
      ignore (Atomic.fetch_and_add g.finished 1);
      { E.text = "extracted"; title = None; total_chars = 9; path_addressable = false });
  }

(* {1 The harness} *)

(* One pool per case, closed no matter how the case ends. The caller must
   [release] its grinder before returning: [close] waits for running jobs, and
   the point of [stop] is that the suite never waits for a parse it refused. *)
let with_pool ?workers ?queue_limit ?max_result_bytes extractor f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      ignore sw;
      match
        K.make ?workers ?queue_limit ?max_result_bytes
          ~net:env#net
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          ~dir:(Filename.get_temp_dir_name ())
          ~extractor ()
      with
      | Error message -> A.failf "extract pool: %s" message
      | Ok pool ->
          Fun.protect
            ~finally:(fun () -> K.close pool)
            (fun () -> f env pool)))

let html =
  "<!DOCTYPE html><html><head><title>Doc</title></head><body><article><p>"
  ^ String.concat "" (List.init 40 (fun _ -> "Sentences of real body text. "))
  ^ "</p></article></body></html>"

(* Open file descriptors, counted through [/proc]. The pool's sockets are the
   only thing this process opens late and closes on the fly; a case that leaks
   one per abandoned job — the failure mode F2.2 exists to close — reads here
   as growth, and the assertion below is that it does not. *)
let render (e : K.error) =
  match e with
  | K.Timed_out -> "Timed_out"
  | K.Pool_closed -> "Pool_closed"
  | K.Backend m -> "Backend " ^ m
  | K.Worker m -> "Worker " ^ m

let open_fds () = Array.length (Sys.readdir "/proc/self/fd")

(* {1 The cases} *)

(* A real extraction, answered across the socket, is the answer inline gives —
   and the bytes of the page crossed as data, not as a shared value. *)
let test_answer_matches_inline () =
  let inline = E.of_module (module S) in
  with_pool (E.of_module (module S)) (fun _env pool ->
    match K.extract pool ~body:html ~content_type:(Some "text/html") with
    | Error e -> A.failf "extract: %s" (render e)
    | Ok r ->
        let direct = inline.extract html (Some "text/html") in
        A.(check string "text" direct.text r.text);
        A.(check (option string) "title" direct.title r.title);
        A.(check int "total_chars" direct.total_chars r.total_chars);
        A.(check bool "path_addressable" direct.path_addressable r.path_addressable))

(* The oracle's [test_extraction_holds_the_event_loop_open]: 0.5s of another
   domain's arithmetic is ~50 loop ticks, so a loop held by the parse reads
   near zero. The extraction also has to answer, and answer from a different
   domain than the loop's. *)
let test_busy_parse_leaves_the_loop_beating () =
  let g = make_grinder () in
  Atomic.set g.busy true;
  Atomic.set g.seconds 0.5;
  with_pool ~workers:1 (grinder_backend g) (fun env pool ->
    Eio.Switch.run (fun sw ->
      let answer = ref None in
      Eio.Fiber.fork ~sw (fun () ->
        answer := Some (K.extract pool ~body:"x" ~content_type:None));
      let ticks = ref 0 in
      while !answer = None do
        incr ticks;
        Eio.Time.sleep (Eio.Stdenv.clock env) 0.01
      done;
      release g;
      match !answer with
      | Some (Ok r) ->
          A.(check string "text" "extracted" r.text);
          A.(check bool "worker domain differs from the loop's" true
              (Atomic.get g.last_domain <> main_domain));
          if !ticks < 10 then
            A.failf "the loop only ticked %d times during the parse" !ticks
      | Some (Error e) -> A.failf "expected a result, got error: %s" (render e)
      | None -> A.failf "the extracting fiber never answered"))

(* The oracle's [test_an_overrunning_parse_comes_back_as_a_refusal], at the
   pool's own level: the deadline answers [Timed_out] while the worker is
   still grinding, well before the 5s parse finishes — and the pool lives to
   answer the next call. *)
let test_overrunning_parse_times_out () =
  let g = make_grinder () in
  Atomic.set g.seconds 5.0;
  with_pool ~workers:1 (grinder_backend g) (fun _env pool ->
    let started = Unix.gettimeofday () in
    (match K.extract ~timeout_seconds:0.4 pool ~body:"x" ~content_type:None with
    | Error K.Timed_out -> ()
    | Error e -> A.failf "expected Timed_out, got %s" (render e)
    | Ok _ -> A.failf "expected Timed_out, got a result");
    let elapsed = Unix.gettimeofday () -. started in
    if elapsed < 0.35 || elapsed >= 1.9 then
      A.failf "returned in %.2fs: expected the 0.4s deadline" elapsed;
    (* The abandoned grind is still holding its worker. Release it, and the
       pool must serve again — the abandonment was bounded, not terminal. *)
    release g;
    let started = Unix.gettimeofday () in
    (match K.extract ~timeout_seconds:5.0 pool ~body:"x" ~content_type:None with
    | Ok r -> A.(check string "text" "extracted" r.text)
    | Error _ ->
        A.failf "the pool was still unhealthy %.2fs after the timeout"
          (Unix.gettimeofday () -. started)))

(* Repeated timeouts against burners, alongside ordinary work: every caller
   ends, the workers in flight never exceed the fixed pool, the loop keeps
   beating through all of it, and the sockets all come back. The oracle's
   stress case, at the pool seam. *)
let test_pressure_is_bounded_and_the_pool_survives () =
  let g = make_grinder () in
  Atomic.set g.busy true;
  Atomic.set g.seconds 0.3;
  let before = open_fds () in
  with_pool ~workers:2 ~queue_limit:2 (grinder_backend g) (fun env pool ->
    Eio.Switch.run (fun sw ->
      let done_vars =
        List.init 10 (fun _ ->
          let v = ref None in
          Eio.Fiber.fork ~sw (fun () ->
            v := Some (K.extract ~timeout_seconds:0.1 pool ~body:"x"
              ~content_type:None));
          v)
      in
      let ticks = ref 0 in
      while List.exists (fun v -> !v = None) done_vars do
        incr ticks;
        Eio.Time.sleep (Eio.Stdenv.clock env) 0.01
      done;
      release g;
      if !ticks < 10 then
        A.failf "the loop only ticked %d times under pressure" !ticks;
      (* Every caller ended; each of these burns 0.3s against a 0.1s budget,
         so each is a timeout — the oracle's "all callers end". *)
      List.iter
        (fun v ->
          match !v with
          | Some (Error K.Timed_out) -> ()
          | Some (Ok _) -> () (* a grind that beat the budget on a loaded box *)
          | Some (Error e) -> A.failf "a pressured call ended with %s" (render e)
          | None -> A.failf "a pressured call never ended")
        done_vars;
      A.(check bool "workers in flight never exceeded the pool" true
          (Atomic.get g.high <= 2));
      (* Ordinary work still answers afterwards. *)
      match K.extract ~timeout_seconds:5.0 pool ~body:"x" ~content_type:None with
      | Ok r -> A.(check string "text after pressure" "extracted" r.text)
      | Error _ -> A.failf "the pool was unhealthy after pressure"));
  (* The pool is closed by the harness; its sockets are gone and no call
     leaked one. A small constant covers the runtime's own churn. *)
  let after = open_fds () in
  if after > before + 8 then
    A.failf "file descriptors grew from %d to %d" before after

(* A backend that fails says so in its own words, from the worker domain: the
   [Backend] case carries [Extractor.Extraction_failed] the way the inline
   path's [with] clause does. *)
let test_backend_failure_is_a_value () =
  let backend =
    {
      E.name = "failing";
      supported_types = E.supported_types;
      extract =
        (fun _body _content_type ->
          raise (E.Extraction_failed "the body cannot be read"));
    }
  in
  with_pool backend (fun _env pool ->
    match K.extract pool ~body:"x" ~content_type:(Some "text/html") with
    | Error (K.Backend message) -> A.(check string "message" "the body cannot be read" message)
    | Error e -> A.failf "expected Backend, got %s" (render e)
    | Ok _ -> A.failf "expected Backend, got a result")

(* A result frame that declares more than the response ceiling gets the
   connection closed, never the loop's allocator: [Worker], not a stall or a
   [Buf_read] exception escaping the call. *)
let test_oversized_result_is_a_worker_failure () =
  let backend =
    {
      E.name = "voluble";
      supported_types = E.supported_types;
      extract =
        (fun _body _content_type ->
          { E.text = String.make 50_000 'v'; title = None; total_chars = 50_000;
            path_addressable = false });
    }
  in
  with_pool ~max_result_bytes:4096 backend (fun _env pool ->
    match K.extract ~timeout_seconds:2.0 pool ~body:"x" ~content_type:None with
    | Error (K.Worker _) -> ()
    | Error e -> A.failf "expected Worker, got %s" (render e)
    | Ok _ -> A.failf "an oversized result came back as Ok")

(* Shutdown, the whole contract in one case: [close] waits for the running
   job, later calls answer [Pool_closed], and [close] again changes nothing. *)
let test_close_waits_then_refuses () =
  let g = make_grinder () in
  Atomic.set g.seconds 0.3;
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      match
        K.make ~workers:1
          ~net:env#net
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          ~dir:(Filename.get_temp_dir_name ())
          ~extractor:(grinder_backend g) ()
      with
      | Error message -> A.failf "extract pool: %s" message
      | Ok pool ->
          let answer = ref None in
          Eio.Fiber.fork ~sw (fun () ->
            answer := Some (K.extract pool ~body:"x" ~content_type:None));
          while Atomic.get g.started < 1 do
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.01
          done;
          K.close pool;
          (* [close] waits for the running job: [finished] is set by the time
             it returns, and the in-flight call still answers. The fiber
             resumes once the loop does, so give it the beat it needs. *)
          A.(check int "running job finished before close returned" 1
              (Atomic.get g.finished));
          while !answer = None do
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.01
          done;
          (match !answer with
          | Some (Ok r) -> A.(check string "the running job still answered" "extracted" r.text)
          | _ -> A.failf "the in-flight job did not answer");
          (match K.extract pool ~body:"x" ~content_type:None with
          | Error K.Pool_closed -> ()
          | _ -> A.failf "an extract after close was not Pool_closed");
          K.close pool (* idempotent *)))

(* A pool that cannot be built is a value naming the cause, not a fetch stack
   that quietly runs inline: zero workers is refused outright. *)
let test_make_refuses_an_empty_pool () =
  Eio_main.run (fun env ->
    match
      K.make ~workers:0
        ~net:env#net
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~dir:(Filename.get_temp_dir_name ())
        ~extractor:(E.of_module (module S)) ()
    with
    | Error message -> A.(check bool "refusal names the cause" true (String.length message > 0))
    | Ok _ -> A.failf "a zero-worker pool was accepted")

let () =
  A.run "extract_pool"
    [
      ("the runner", [
        A.test_case "a pooled extraction matches the inline answer" `Quick
          test_answer_matches_inline;
        A.test_case "a busy parse leaves the loop beating, off it" `Quick
          test_busy_parse_leaves_the_loop_beating;
      ]);
      ("deadlines and pressure", [
        A.test_case "an overrunning parse comes back Timed_out" `Quick
          test_overrunning_parse_times_out;
        A.test_case "pressure is bounded and the pool survives" `Quick
          test_pressure_is_bounded_and_the_pool_survives;
      ]);
      ("failures are values", [
        A.test_case "a failing backend reports its own message" `Quick
          test_backend_failure_is_a_value;
        A.test_case "an oversized result is a worker failure" `Quick
          test_oversized_result_is_a_worker_failure;
        A.test_case "close waits, then refuses, twice over" `Quick
          test_close_waits_then_refuses;
        A.test_case "an empty pool is refused at make" `Quick
          test_make_refuses_an_empty_pool;
      ]);
    ]
