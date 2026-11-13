(* The HTTP serving loop's shutdown (plans/ocaml-finalisation.md F2.3).

   The signal handlers are deliberately the smallest thing that can be: one
   non-blocking write to a self-pipe, no promise, no log, no allocation. The
   watcher fiber below owns the translation from "a byte is readable" to "the
   stop promise is filled", which is the one safe signal-to-promise path the
   plan asks for. [Server.serve_http] owns everything after that: stop
   accepting, mark the routes stopping, abort the health fiber, drain under the
   grace, cancel what is left.

   This module is the one place that orders close relative to the switch: the
   listener's children are joined by [serve_http], then [close] runs, then the
   caller's [Eio.Switch.run] body returns and the grants it owns are released.
   A close that ran after the switch, or on only the success path, would either
   outlive the grants or leak the providers on a bind failure. *)

module Server = Seekwright.Server

let cleanup ~restore ~read_end ~write_end ~close () =
  restore ();
  (try Unix.close read_end with Unix.Unix_error _ -> ());
  (try Unix.close write_end with Unix.Unix_error _ -> ());
  close ()

let run_with_signals ~env ~sw ~log ~app ~server ~host ~port ~close
    ~grace_seconds =
  let stop, resolve_stop = Eio.Promise.create () in
  let read_end, write_end = Unix.pipe ~cloexec:true () in
  (* Non-blocking on both ends: the handler must never wait on a full pipe, and
     the watcher polls the read end rather than reading it. *)
  Unix.set_nonblock read_end;
  Unix.set_nonblock write_end;
  let byte = Bytes.make 1 '\000' in
  let fired = Atomic.make false in
  let handler _signal =
    if Atomic.compare_and_set fired false true then
      try ignore (Unix.write write_end byte 0 1) with Unix.Unix_error _ -> ()
  in
  let previous =
    [
      (Sys.sigint, Sys.signal Sys.sigint (Sys.Signal_handle handler));
      (Sys.sigterm, Sys.signal Sys.sigterm (Sys.Signal_handle handler));
    ]
  in
  let restore () =
    List.iter (fun (signal, behavior) -> ignore (Sys.signal signal behavior)) previous
  in
  let abort, resolve_abort = Eio.Promise.create () in
  (* One watcher per process: the first byte fills the stop promise, and the
     abort branch is how a run that ends without a signal (a bind failure) lets
     the watcher exit before its file descriptors are closed. *)
  let watcher =
    Eio.Fiber.fork_promise ~sw (fun () ->
        match
          Eio.Fiber.first
            (fun () ->
              Eio_unix.await_readable read_end;
              `Signal)
            (fun () ->
              Eio.Promise.await abort;
              `Abort)
        with
        | `Signal -> ignore (Eio.Promise.try_resolve resolve_stop ())
        | `Abort -> ())
  in
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () ->
          ignore (Eio.Promise.try_resolve resolve_abort ());
          (* Join the watcher before the descriptors it waits on go away, so a
             cancelled run cannot leave a fiber polling a closed fd. *)
          (match Eio.Promise.await watcher with
          | Ok () | Error (Eio.Cancel.Cancelled _) -> ()
          | Error _ -> ());
          cleanup ~restore ~read_end ~write_end ~close ()))
    (fun () ->
      Server.serve_http ~env ~sw ~log app server ~host ~port ~stop
        ~grace_seconds ())

let run_with_stop ~env ~sw ~log ~app ~server ~host ~port ~close ~grace_seconds
    ~stop =
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () -> close ()))
    (fun () ->
      Server.serve_http ~env ~sw ~log app server ~host ~port ~stop
        ~grace_seconds ())

let run_http ~env ~sw ~log ~app ~server ~host ~port ~close
    ?(grace_seconds = Server.drain_grace_seconds) ?stop () =
  match stop with
  | Some stop ->
      run_with_stop ~env ~sw ~log ~app ~server ~host ~port ~close
        ~grace_seconds ~stop
  | None ->
      run_with_signals ~env ~sw ~log ~app ~server ~host ~port ~close
        ~grace_seconds
