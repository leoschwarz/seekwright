module A = Alcotest

let binary = "../bin/main.exe"
let config_prefix = "SEEKWRIGHT_CONFIG="

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

let sockaddr port = Unix.ADDR_INET (Unix.inet_addr_loopback, port)

let write_all fd text =
  let bytes = Bytes.of_string text in
  let rec go offset =
    if offset < Bytes.length bytes then
      let written = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      go (offset + written)
  in
  go 0

let read_all ?(deadline = Unix.gettimeofday () +. 3.0) ~label fd =
  let buffer = Buffer.create 1024 in
  let chunk = Bytes.create 4096 in
  let rec go () =
    match Unix.select [ fd ] [] [] 3.0 with
    | [], _, _ -> A.failf "timed out reading %s" label
    | _ ->
        let read = Unix.read fd chunk 0 (Bytes.length chunk) in
        if read = 0 then Buffer.contents buffer
        else begin
          (* The deadline is the guard against a peer that trickles forever; a socket
             that stays open without data fails the case instead of hanging it. *)
          if Unix.gettimeofday () > deadline then A.failf "timed out reading %s" label;
          Buffer.add_subbytes buffer chunk 0 read;
          go ()
        end
  in
  go ()

let connect_when_listening ~deadline port =
  let rec go () =
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    match Unix.connect socket (sockaddr port) with
    | () -> socket
    | exception Unix.Unix_error _ ->
        Unix.close socket;
        if Unix.gettimeofday () > deadline then A.fail "the server never started listening"
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
        Unix.close socket;
        if Unix.gettimeofday () > deadline then A.fail "the listener kept accepting"
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
          A.fail "the child did not exit inside the deadline"
        end
        else begin
          sleep 0.02;
          go ()
        end
    | _, status -> status
  in
  go ()

(* The parent's own [SEEKWRIGHT_CONFIG] is stripped so a developer's shell cannot
   choose what a suite asserts; the [?config] the spawns take then states the child's
   value explicitly. It is a plain option here, not an optional argument, so no call
   site has to erase one. *)
let child_env (config : string option) =
  Unix.environment () |> Array.to_list
  |> List.filter (fun entry ->
      String.length entry < String.length config_prefix
      || String.sub entry 0 (String.length config_prefix) <> config_prefix)
  |> (fun entries ->
  match config with Some path -> entries @ [ config_prefix ^ path ] | None -> entries)
  |> Array.of_list

type spawned = { pid : int; out : Unix.file_descr; err : Unix.file_descr }

let spawn ?config ~argv () =
  let env = child_env config in
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close dev_null)
    (fun () ->
      Unix.create_process_env binary (Array.of_list (binary :: argv)) env dev_null dev_null dev_null)

let spawn_captured ?config ~argv () : spawned =
  let env = child_env config in
  let out_read, out_write = Unix.pipe () in
  let err_read, err_write = Unix.pipe () in
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close dev_null)
    (fun () ->
      let pid =
        Unix.create_process_env binary
          (Array.of_list (binary :: argv))
          env dev_null out_write err_write
      in
      (* The parent's copies of the write ends go here, or [read_all] would wait on a
         pipe the suite itself is holding open. *)
      Unix.close out_write;
      Unix.close err_write;
      { pid; out = out_read; err = err_read })
