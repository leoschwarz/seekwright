(* [close] must run before caller's [sw] ends: grants must outlive provider cleanup. *)

module Server = Seekwright.Server

let cleanup ~restore ~read_end ~write_end ~close () =
  restore ();
  (try Unix.close read_end with Unix.Unix_error _ -> ());
  (try Unix.close write_end with Unix.Unix_error _ -> ());
  close ()

let run_http ~env ~sw ~log ~app ~server ~host ~port ~close
    ?(grace_seconds = Server.drain_grace_seconds) ?stop () =
  (* The serve call and its nine labelled arguments, written once; each path
     below wraps this in its own [Fun.protect]. *)
  let serve ~stop () =
    Server.serve_http ~env ~sw ~log app server ~host ~port ~grace_seconds ~stop ()
  in
  let run_with_signals () =
    let stop, resolve_stop = Eio.Promise.create () in
    let read_end, write_end = Unix.pipe ~cloexec:true () in
    (* Non-blocking pipe: prevents signal handler from blocking on a full pipe. *)
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
            (* Must join watcher before [cleanup] closes fds: prevents polling a closed fd. *)
            (match Eio.Promise.await watcher with
            | Ok () | Error (Eio.Cancel.Cancelled _) -> ()
            | Error _ -> ());
            cleanup ~restore ~read_end ~write_end ~close ()))
      (serve ~stop)
  in
  (* [Eio.Cancel.protect] is load-bearing in both [finally]s: under fiber
     cancellation an unprotected finally is itself cancelled, and [close] never
     runs. *)
  let run_with_stop stop =
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> close ())) (serve ~stop)
  in
  match stop with Some stop -> run_with_stop stop | None -> run_with_signals ()
