(* The real binary's SIGTERM drain.

   [test_drain.ml] drives the same drain through an injected stop promise; this
   suite proves the process signal path reaches it. It is deliberately a
   black-box test: it starts [bin/main.exe] on a free loopback port, keeps one
   REST request in flight with its body unfinished, sends SIGTERM, watches a
   second connection attempt be refused, then finishes the first request and
   reads the stopping answer. A successful exit status closes the loop.

   The in-flight search names [serper], a provider this build does not carry,
   so even a missed stop cannot make the run dial a public endpoint: the
   engine refuses an unbuilt name before any provider is constructed. Nothing
   here contacts a billed host, and the only socket is 127.0.0.1. The port, the
   child process and the bounded waits are [Binary_harness]'s, shared with
   [test_cli_dial.ml]; what lives here is the request the drain is built around. *)

module A = Alcotest
open Binary_harness
open Test_support

let body = {|{"query":"slow request","provider":"serper"}|}

(* The config is the keyless default with the one extraction backend this
   build carries, and the periodic probe is off so the only traffic in the
   test is the request the test opened. *)
let drain_config = "drain.toml"

let start_server port =
  spawn ~config:drain_config
    ~argv:[ "--http"; "--host"; "127.0.0.1"; "--port"; string_of_int port ]
    ()

let sigterm_drains_and_exits_zero () =
  let port = free_port () in
  let pid = start_server port in
  let exited = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !exited then try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ())
    (fun () ->
      let deadline = Unix.gettimeofday () +. 5.0 in
      let socket = connect_when_listening ~deadline port in
      Fun.protect
        ~finally:(fun () -> Unix.close socket)
        (fun () ->
          let head =
            Printf.sprintf
              "POST /api/v1/search HTTP/1.1\r\n\
               Host: 127.0.0.1:%d\r\n\
               Content-Type: application/json\r\n\
               Content-Length: %d\r\n\
               Connection: close\r\n\
               \r\n"
              port (String.length body)
          in
          write_all socket head;
          (* Half the body is enough for the server to have read the head and
             be waiting inside the body reader; the request is then
             unmistakably in flight. *)
          let split = String.length body / 2 in
          write_all socket (String.sub body 0 split);
          sleep 0.3;
          Unix.kill pid Sys.sigterm;
          (* The listener must stop accepting, but the process must still be
             alive because the accepted request is unfinished. *)
          wait_until_refused ~deadline:(Unix.gettimeofday () +. 3.0) port;
          write_all socket (String.sub body split (String.length body - split));
          let response = read_all ~label:"the drain response" socket in
          includes "the in-flight call is refused with 503" " 503 " response;
          includes "the refusal is the stopping sentence" "The server is stopping; retry shortly."
            response;
          let status = wait_for_exit ~deadline:(Unix.gettimeofday () +. 5.0) pid in
          exited := true;
          A.(check bool) "a requested stop is exit status 0" true (status = Unix.WEXITED 0)))

let () =
  A.run "binary_drain"
    [
      ( "signals",
        [
          A.test_case "SIGTERM refuses new work, drains the in-flight call and exits 0" `Quick
            sigterm_drains_and_exits_zero;
        ] );
    ]
