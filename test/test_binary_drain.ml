(* F2.3: the real binary's SIGTERM drain.

   [test_drain.ml] drives the same drain through an injected stop promise; this
   suite proves the process signal path reaches it. It is deliberately a
   black-box test: it starts [bin/main.exe] on a free loopback port, keeps one
   REST request in flight with its body unfinished, sends SIGTERM, watches a
   second connection attempt be refused, then finishes the first request and
   reads the stopping answer. A successful exit status closes the loop.

   The in-flight search names [serper], a provider this build does not carry,
   so even a missed stop cannot make the run dial a public endpoint: the
   engine refuses an unbuilt name before any provider is constructed. Nothing
   here contacts a billed host, and the only socket is 127.0.0.1. *)

module A = Alcotest
open Test_support

let body = {|{"query":"slow request","provider":"serper"}|}

let sleep seconds = ignore (Unix.select [] [] [] seconds)

let free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX _ -> A.fail "the scratch socket is not TCP")

let sockaddr port =
  Unix.ADDR_INET (Unix.inet_addr_loopback, port)

let write_all fd text =
  let bytes = Bytes.of_string text in
  let rec go offset =
    if offset < Bytes.length bytes then
      let written = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      go (offset + written)
  in
  go 0

let read_all fd =
  let buffer = Buffer.create 1024 in
  let chunk = Bytes.create 4096 in
  let rec go () =
    match Unix.select [ fd ] [] [] 3.0 with
    | [], _, _ -> A.fail "timed out reading the drain response"
    | _ ->
        let read = Unix.read fd chunk 0 (Bytes.length chunk) in
        if read = 0 then Buffer.contents buffer
        else begin
          Buffer.add_subbytes buffer chunk 0 read;
          go ()
        end
  in
  go ()

(* The config is the keyless default with the one extraction backend this
   build carries, and the periodic probe is off so the only traffic in the
   test is the request the test opened. *)
let drain_config = "drain.toml"

let spawn port =
  let env =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry ->
           not (String.length entry >= 18
               && String.sub entry 0 18 = "SEEKWRIGHT_CONFIG="))
    |> Array.of_list
  in
  let env = Array.append env [| "SEEKWRIGHT_CONFIG=" ^ drain_config |] in
  let argv =
    [|
      "../bin/main.exe";
      "--http";
      "--host";
      "127.0.0.1";
      "--port";
      string_of_int port;
    |]
  in
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close dev_null)
    (fun () ->
      Unix.create_process_env "../bin/main.exe" argv env dev_null dev_null
        dev_null)

let connect_when_listening ~deadline port =
  let rec go () =
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    match Unix.connect socket (sockaddr port) with
    | () -> socket
    | exception Unix.Unix_error _ ->
        Unix.close socket;
        if Unix.gettimeofday () > deadline then
          A.fail "the server never started listening"
        else begin
          sleep 0.02;
          go ()
        end
  in
  go ()

let wait_until_refused ~deadline port =
  let rec go () =
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    match Unix.connect socket (sockaddr port) with
    | () ->
        (* A connection accepted before the stop is closed immediately: the
           head reader sees EOF and answers nothing, so this probe never
           becomes work the drain has to wait for. *)
        Unix.close socket;
        if Unix.gettimeofday () > deadline then
          A.fail "the listener kept accepting after SIGTERM"
        else begin
          sleep 0.02;
          go ()
        end
    | exception Unix.Unix_error _ ->
        Unix.close socket;
        ()
  in
  go ()

let wait_for_exit ~deadline pid =
  let rec go () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
        if Unix.gettimeofday () > deadline then begin
          (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
          A.fail "the server did not exit after a completed drain"
        end
        else begin
          sleep 0.02;
          go ()
        end
    | _, status -> status
  in
  go ()

let sigterm_drains_and_exits_zero () =
  let port = free_port () in
  let pid = spawn port in
  let exited = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !exited then
        try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ())
    (fun () ->
      let deadline = Unix.gettimeofday () +. 5.0 in
      let socket = connect_when_listening ~deadline port in
      Fun.protect
        ~finally:(fun () -> Unix.close socket)
        (fun () ->
          let head =
            Printf.sprintf
              "POST /api/v1/search HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\
               Content-Type: application/json\r\nContent-Length: %d\r\n\
               Connection: close\r\n\r\n"
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
          let response = read_all socket in
          includes "the in-flight call is refused with 503" " 503 " response;
          includes "the refusal is the stopping sentence"
            "The server is stopping; retry shortly." response;
          let status = wait_for_exit ~deadline:(Unix.gettimeofday () +. 5.0) pid in
          exited := true;
          A.(check bool) "a requested stop is exit status 0" true
            (status = Unix.WEXITED 0)))

let () =
  A.run "binary_drain"
    [
      ( "signals",
        [
          A.test_case "SIGTERM refuses new work, drains the in-flight call and exits 0"
            `Quick sigterm_drains_and_exits_zero;
        ] );
    ]
