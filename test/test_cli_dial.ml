(* The real binary's client verbs: what [seekwright search] puts on the wire, and what
   it does with the answer.

   The dial is not a hand-rolled socket. [bin/main.ml] builds one endpoint-scoped [Net]
   grant for the [--server] origin through [Factory.grant_of_endpoint] — the funnel
   every other outbound call in this build goes through — so three things have to be
   pinned against a real socket, none of them visible from [test_cli_client.ml], whose
   [post] is a fake:

   - the grant accepts the operator's own origin, loopback included: an endpoint list
     pins a name, not an address class, which is exactly what [fetch]'s public-web
     grant refuses;
   - the request that leaves is the one the REST route expects — the route, the JSON
     body the flags built, and the JSON content headers;
   - the exit status and the rendered line are the surface's, and they hold while
     [SEEKWRIGHT_CONFIG] names a file that does not exist, because a client verb reads
     no config, builds no provider and needs no key.

   A refused origin never reaches a socket at all: [Policy_net.endpoint_of_uri] rejects
   the scheme and its sentence is what the operator reads. The third case is the other
   half of that distinction — an origin that is dialable but unreachable is still a
   transport failure, exit 1, with no policy sentence anywhere.

   Every address here is 127.0.0.1 and the responder is this file's own; nothing dials a
   billed endpoint. *)

module A = Alcotest
open Binary_harness
open Test_support

let served_body =
  {|{"query":"open data","provider":"exa:free","results":[{"title":"First result","url":"http://a.example/one","snippet":"the snippet"}]}|}

let listen port =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind socket (sockaddr port);
  Unix.listen socket 8;
  socket

(* One request, read as the client writes it: the head up to the blank line, then the
   body its [content-length] promised. Every read is select-bounded, so a client that
   sends nothing fails the case instead of hanging the suite. *)
let read_request ~deadline fd =
  let buffer = Buffer.create 1024 in
  let chunk = Bytes.create 4096 in
  let head_end text =
    match find_sub ~haystack:text ~needle:"\r\n\r\n" () with None -> -1 | Some index -> index + 4
  in
  (* The declared length, read from the lowered copy so the header's case does not
     matter, and stopped at the first non-digit so a later header's digits cannot join
     the number. *)
  let declared_length text =
    match find_sub ~haystack:(String.lowercase_ascii text) ~needle:"content-length:" () with
    | None -> 0
    | Some index -> (
        let start = ref (index + String.length "content-length:") in
        while !start < String.length text && text.[!start] = ' ' do
          incr start
        done;
        let stop = ref !start in
        while !stop < String.length text && text.[!stop] >= '0' && text.[!stop] <= '9' do
          incr stop
        done;
        match int_of_string_opt (String.sub text !start (!stop - !start)) with
        | Some length -> length
        | None -> 0)
  in
  let rec go () =
    if Unix.gettimeofday () > deadline then A.fail "the client never sent a request"
    else
      match Unix.select [ fd ] [] [] 1.0 with
      | [], _, _ -> go ()
      | _ -> (
          match Unix.read fd chunk 0 (Bytes.length chunk) with
          | 0 -> A.fail "the client closed the connection without a request"
          | read ->
              Buffer.add_subbytes buffer chunk 0 read;
              let text = Buffer.contents buffer in
              let head = head_end text in
              if head < 0 || String.length text < head + declared_length text then go () else text)
  in
  go ()

let respond fd ~body =
  let head =
    Printf.sprintf
      "HTTP/1.1 200 OK\r\n\
       Content-Type: application/json\r\n\
       Content-Length: %d\r\n\
       Connection: close\r\n\
       \r\n"
      (String.length body)
  in
  write_all fd (head ^ body)

(* The deployment side of one dial: accept, read the request, answer, and hand the
   request text back for the assertions to read. *)
let serve_one ~listener ~deadline ~body =
  let connection, _peer = Unix.accept listener in
  Fun.protect
    ~finally:(fun () -> Unix.close connection)
    (fun () ->
      let request = read_request ~deadline connection in
      respond connection ~body;
      request)

let kill_child pid = try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()

let with_child ?config ~argv f =
  let child = spawn_captured ?config ~argv () in
  Fun.protect
    ~finally:(fun () ->
      kill_child child.pid;
      Unix.close child.out;
      Unix.close child.err)
    (fun () -> f child)

(* The child's own three outputs: its exit status, what it printed, what it complained.
   The wait comes first so the pipes reach EOF. *)
let result_of child =
  let status = wait_for_exit ~deadline:(Unix.gettimeofday () +. 10.0) child.pid in
  let code =
    match status with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> A.failf "the CLI died on signal %d" signal
    | Unix.WSTOPPED signal -> A.failf "the CLI stopped on signal %d" signal
  in
  ( code,
    read_all ~deadline:(Unix.gettimeofday () +. 3.0) ~label:"the CLI's stdout" child.out,
    read_all ~deadline:(Unix.gettimeofday () +. 3.0) ~label:"the CLI's stderr" child.err )

let search_dials_its_own_server_through_a_grant () =
  let port = free_port () in
  let listener = listen port in
  Fun.protect
    ~finally:(fun () -> Unix.close listener)
    (fun () ->
      (* [SEEKWRIGHT_CONFIG] names a file that is not there: the verb under test must
         never load it, and a client that did would fail here rather than pass. *)
      with_child ~config:"does-not-exist.toml"
        ~argv:[ "search"; "open data"; "--server"; Printf.sprintf "http://127.0.0.1:%d" port ]
      @@ fun child ->
      let deadline = Unix.gettimeofday () +. 10.0 in
      let request = serve_one ~listener ~deadline ~body:served_body in
      includes "the request is a POST to the search route" "POST /api/v1/search HTTP/1.1" request;
      includes "the grant sends the JSON content type" "content-type: application/json" request;
      includes "and the accept header" "accept: application/json" request;
      includes "the body is the request the flags built" {|"query":"open data"|} request;
      let code, out, err = result_of child in
      A.(check int) "a served CLI call exits 0" 0 code;
      includes "the rendered search names the provider" "provider  exa:free" out;
      includes "and the result it was given" "http://a.example/one" out;
      A.(check string) "a client verb writes nothing to stderr" "" err)

let a_refused_origin_never_reaches_a_socket () =
  (* [qq] is two characters because the request model's own minimum is two: a shorter
     query is a usage error (exit 2) and never reaches the dial under test. *)
  with_child ~argv:[ "search"; "qq"; "--server"; "ftp://127.0.0.1:8000" ] @@ fun child ->
  let code, out, err = result_of child in
  A.(check int) "an origin the policy layer refuses exits 1" 1 code;
  A.(check string) "nothing is printed on stdout" "" out;
  includes "the sentence names the scheme rule" "is not a scheme this grant speaks" err;
  excludes "no transport excuse stands in its place" "connection refused" err

let an_unreachable_origin_is_a_transport_failure () =
  let port = free_port () in
  (* Nothing ever binds this port, so the grant is built, the dial is attempted, and the
     failure is the socket's — not the policy's. *)
  with_child ~argv:[ "search"; "qq"; "--server"; Printf.sprintf "http://127.0.0.1:%d" port ]
  @@ fun child ->
  let code, out, err = result_of child in
  A.(check int) "an undialable origin exits 1" 1 code;
  A.(check string) "nothing is printed on stdout" "" out;
  includes "the operator is told the call failed" "seekwright: " err;
  excludes "and no policy refusal is invented" "not one of the endpoints" err

let () =
  A.run "cli_dial"
    [
      ( "the CLI verbs over a real socket",
        [
          A.test_case "search dials its own server through a grant" `Quick
            search_dials_its_own_server_through_a_grant;
          A.test_case "a refused origin never opens a socket" `Quick
            a_refused_origin_never_reaches_a_socket;
          A.test_case "an unreachable origin is a transport failure" `Quick
            an_unreachable_origin_is_a_transport_failure;
        ] );
    ]
