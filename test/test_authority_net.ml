(* M3: the network grant — what it lets through, what it refuses, and where each
   guarantee is actually enforced (plans/capability-gated-mcp-server.md §5; the
   claims themselves are in policy_net.mli).

   Two fixtures, and which facts each can prove matters:

   - a {b real} HTTP server on loopback, served by [Cohttp_eio.Server] and
     reached through the grant's own client stack. This is where a round trip, the
     response-byte ceiling, a 3xx, a request body, an owned header and the
     operation timeout are observable — with one exception the second fixture
     exists for: on loopback, "we connected to the address we vetted" and "the
     HTTP client resolved the name itself" look identical, so no loopback test can
     prove the DNS-to-connect binding.
   - a {b scripted} [Eio.Net.t] built with [Eio.Net.Pi.network]: DNS answers come
     from a table, and every query and every requested connect address is
     recorded. [connect] raises [Simulated] instead of opening anything, which is
     what keeps a test of "the metadata service at 169.254.169.254 is refused"
     from being a test that could reach out. So for that fixture a returned
     [Error] means the policy refused, and [Simulated] carrying an address means
     the policy allowed {e and named the address it used} — which is also the
     evidence that a refusal does no I/O at all.

   Nothing here talks to a real provider, and no case depends on the machine's
   resolver or on public internet (§5: "Public-web tests must not depend on the
   machine's actual resolver or the public internet"). *)

(* TLS needs a process-global random generator, and [Policy_net] refuses to build
   an https grant without one. Installing it here is what the application does at
   startup; the cases below that speak https depend on it. *)
let () = Mirage_crypto_rng_unix.use_default ()

module Authority = Mcp_caps.Authority
module Budget = Mcp_caps.Budget
module Error = Mcp_caps.Error
module Event = Mcp_caps.Event
module Policy = Mcp_caps.Policy
module Policy_net = Mcp_caps.Policy_net

let kind_testable =
  Alcotest.testable
    (fun ppf kind -> Format.pp_print_string ppf (Error.kind_to_string kind))
    ( = )

let contains text needle =
  let n = String.length text and m = String.length needle in
  let rec from i =
    if i + m > n then false else if String.sub text i m = needle then true else from (i + 1)
  in
  from 0

(* [Alcotest.fail]'s optional [~here] means it cannot be passed to [kasprintf]
   directly: the wrapper is what keeps a failure message one [failf] call away. *)
let failf format = Format.kasprintf (fun message -> Alcotest.fail message) format

(* Several operations through one {e grant} is what a per-operation bound and a
   caller's budget are about; [repeat n f] says the count instead of hiding it in
   a unit list. *)
let repeat n f = for _ = 1 to n do f () done

let show_address address = Format.asprintf "%a" Eio.Net.Sockaddr.pp (address :> [< Eio.Net.Sockaddr.stream ])

let address_testable =
  Alcotest.testable (fun ppf address -> Format.pp_print_string ppf (show_address address)) ( = )

(* {1 The loopback fixture server}

   One path per fact, and every request is recorded so a case can insist that a
   refusal sent {e no} request. *)

type served = { method_ : string; path : string; host : string; body_bytes : int }

let seen = Atomic.make []

(* [Atomic.modify] is 5.5 and this switch is 5.3; the append is a compare-and-set
   loop anyway, because the fixture's fiber and the test's fiber both push. *)
let push cell value =
  let rec retry () =
    let current = Atomic.get cell in
    if Atomic.compare_and_set cell current (value :: current) then () else retry ()
  in
  retry ()

let record entry = push seen entry

(* The log is process-wide and newest-first, so a case that means "this operation
   sent one request and nothing else" measures what appeared since it started —
   otherwise a green run would depend on the order the cases happen to run in. *)
let take n xs =
  let rec go acc n xs =
    match (n, xs) with
    | 0, _ | _, [] -> List.rev acc
    | _, first :: rest -> go (first :: acc) (n - 1) rest
  in
  go [] n xs

let requests () = List.length (Atomic.get seen)

let paths_since mark =
  let current = Atomic.get seen in
  List.map (fun entry -> entry.path) (take (List.length current - mark) current)

(* A flow source that produces [limit] bytes and then ends. cohttp cannot put a
   [Content-Length] on it, so the response is chunked — the shape a missing or
   lying [Content-Length] is tested against, because the ceiling then has to come
   from the bytes actually read (§5). *)
module Pump = struct
  type t = { chunk : string; limit : int; mutable sent : int }

  let read_methods = []

  let single_read t buf =
    if t.sent >= t.limit then raise End_of_file
    else
      let take = min (Cstruct.length buf) (min (String.length t.chunk) (t.limit - t.sent)) in
      Cstruct.blit_from_string t.chunk 0 buf 0 take;
      t.sent <- t.sent + take;
      take
end

let pumped ~limit =
  Eio.Resource.T
    (({ chunk = "0123456789abcdef"; limit; sent = 0 } : Pump.t), Eio.Flow.Pi.source (module Pump))

(* Long enough that a tenth-of-a-second bound expires while the fixture is
  parked, and short enough that a test which expects the answer waits little. *)
let slow_seconds = 2.0

(* [Http.Request.t] is the wire-level request: [resource] is the path and query
   the client sent, and the host it was addressed to is the [Host] header. There
   is no assembled URI on the server side, which is why the redirect routes
   below build their [Location] from those two. *)
let fixture env (_switch, _peer) request body =
  let headers = Http.Request.headers request in
  let resource = Http.Request.resource request in
  let path =
    match String.index_opt resource '?' with
    | Some i -> String.sub resource 0 i
    | None -> resource
  in
  let host = Option.value ~default:"" (Http.Header.get headers "host") in
  (* The body is drained whatever the route is, so [body_bytes] says what the
     authority sent rather than what the route wanted. *)
  let body_text =
    try Eio.Buf_read.(take_all (of_flow ~max_size:65_536 body)) with End_of_file -> ""
  in
  record
    {
      method_ = Http.Method.to_string (Http.Request.meth request);
      path;
      host;
      body_bytes = String.length body_text;
    };
  let redirect target =
    Cohttp_eio.Server.respond_string
      ~headers:(Http.Header.of_list [ ("location", target) ])
      ~status:`Found ~body:"redirected\n" ()
  in
  let host_port =
    match String.index_from_opt host 0 ':' with
    | Some i -> String.sub host (i + 1) (String.length host - i - 1)
    | None -> "80"
  in
  match path with
  | "/ok" -> Cohttp_eio.Server.respond_string ~status:`OK ~body:"the answer is 42\n" ()
  | "/echo" ->
      Cohttp_eio.Server.respond_string ~status:`OK ~body:body_text ()
  | "/headers" ->
      let echoed =
        List.map
          (fun name -> name ^ "=" ^ Option.value ~default:"" (Http.Header.get headers name))
          [ "host"; "x-tool" ]
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~body:(String.concat "\n" echoed) ()
  | "/redirect-elsewhere" -> redirect "http://elsewhere.test/x"
  | "/redirect-here" ->
      (* Same host and port as the request: a redirect this grant {e could}
         legally follow, and still must not. *)
      redirect ("http://" ^ host ^ "/ok")
  | "/redirect-alias" ->
      (* Same machine, different {e name}: [localhost] is not the [127.0.0.1] the
         allowlist names, which is what the name half of the policy is for. *)
      redirect (Printf.sprintf "http://localhost:%s/ok" host_port)
  | "/redirect-relative" -> redirect "/ok"
  | "/big" -> Cohttp_eio.Server.respond ~status:`OK ~body:(pumped ~limit:65_536) ()
  | "/slow" ->
      (* The sleep is the point: the bound has to cancel a request that is
         {e waiting}, not only one whose bytes are moving. *)
      Eio.Time.sleep (Eio.Stdenv.clock env) slow_seconds;
      Cohttp_eio.Server.respond_string ~status:`OK ~body:"late\n" ()
  | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"nothing here\n" ()

(* The faults a case is expected to cause in the fixture: a grant that stops
   reading — the ceiling, or a cancelled operation — leaves the fixture writing to
   a closed socket. Anything else is a bug in the fixture or the grant. *)
let expected_fault = function
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) | End_of_file -> true
  | _ -> false

(* Runs [f] against the fixture, then drains the listener and fails on any fault
   the cases below did not ask for. *)
let with_fixture f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Atomic.set seen [];
  let server = Cohttp_eio.Server.make ~callback:(fixture env) () in
  let socket =
    Eio.Net.listen ~backlog:16 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> failf "the fixture listens on a unix socket: %s" path
  in
  let faults = Atomic.make [] in
  let stop, fill_stop = Eio.Promise.create () in
  let stopped, fill_stopped = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Promise.resolve fill_stopped ())
      (fun () ->
        Cohttp_eio.Server.run ~stop
          ~on_error:(fun exn -> push faults exn)
          socket server));
  Fun.protect
    ~finally:(fun () ->
      Eio.Promise.resolve fill_stop ();
      Eio.Promise.await stopped)
    (fun () -> f env sw port);
  match List.filter (fun exn -> not (expected_fault exn)) (Atomic.get faults) with
  | [] -> ()
  | exns ->
    failf "the fixture reported faults no case asked for: %s"
      (String.concat "; " (List.map Printexc.to_string exns))

(* {1 The scripted network} *)

(* Raised instead of connecting, carrying the address the grant asked for. *)
exception Simulated of Eio.Net.Sockaddr.stream

module Scripted_net = struct
  type t = {
    answers : (string * string list) list;
    queries : (string * string) list Atomic.t;
    connects : Eio.Net.Sockaddr.stream list Atomic.t;
  }

  (* The fake hands out no socket, so its tag is the generic one the mock net in
     [Eio] itself uses: [connect] raises instead of returning a value that would
     have to be typed. *)
  type tag = [ `Generic ]

  let unusable () = raise (Eio.Net.err Eio.Net.Invalid_option)

  let listen _t ~reuse_addr:_ ~reuse_port:_ ~backlog:_ ~sw:_ _address = unusable ()

  let connect t ~bind_to:_ ~options:_ ~sw:_ address =
    push t.connects address;
    raise (Simulated address)

  let datagram_socket _t ~reuse_addr:_ ~reuse_port:_ ~sw:_ _address = unusable ()

  (* [service] is the port the grant asked for and the answers are addresses, so
     the fixture cannot quietly invent a port of its own. An unlisted name answers
     nothing, which [Policy_net.resolve] reports as [Unavailable] — the
     resolver-error rows below are about the {e grant}, not about this stub. *)
  let getaddrinfo t ~service host =
    push t.queries (host, service);
    let port = int_of_string service in
    match List.assoc_opt host t.answers with
    | Some addresses ->
        List.map
          (fun address ->
            (`Tcp (Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets (Ipaddr.of_string_exn address)), port)))
          addresses
    | None -> []

  let getnameinfo _t _address = ("scripted.test", "0")
end

let scripted_net ?(answers = []) () =
  let state =
    { Scripted_net.answers; queries = Atomic.make []; connects = Atomic.make [] }
  in
  (state, Eio.Resource.T (state, Eio.Net.Pi.network (module Scripted_net)))

(* The same address in [Eio.Net]'s form, which is what the grant passes to
   [connect]. *)
let eio_address address = Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets (Ipaddr.of_string_exn address))

(* {1 Grants, and one way to make a request} *)

let endpoint ?(scheme = `Http) ?port host = { Policy.scheme; host; port }

let grant_of ?controls ~env decision =
  Authority.Net.of_confinement ?controls ~mono_clock:(Eio.Stdenv.mono_clock env) decision

let with_endpoints ~net ~sw ?(max_response_bytes = Policy.default_max_response_bytes) endpoints f =
  match Policy.with_endpoints ~sw ~net ~max_response_bytes endpoints with
  | Error error -> failf "with_endpoints: %s" (Error.render error)
  | Ok decision -> f decision

let with_public_web ~net ~sw ?(max_response_bytes = Policy.default_max_response_bytes) f =
  match Policy.with_public_web ~sw ~net ~max_response_bytes () with
  | Error error -> failf "with_public_web: %s" (Error.render error)
  | Ok decision -> f decision

let request ?max_response_bytes ?(headers = []) ?body ?(meth = `GET) grant uri =
  Authority.Net.request ?max_response_bytes grant
    { Policy_net.meth; uri = Uri.of_string uri; headers; body }

let check_kind expected error =
  Alcotest.(check kind_testable) (Error.render error) expected (Error.kind error)

let check_one_line error =
  Alcotest.(check bool) ("the message is one line: " ^ Error.render error) true
    (String.for_all (fun char -> Char.code char <> 10 && Char.code char <> 13) (Error.render error))

(* {1 The endpoint allowlist}

   Scheme, host and {e effective} port are pinned (§5), and the "allowed" rows
   are completed round trips against the live fixture, so the table also proves
   the request path works. *)

type expectation = Allowed | Denied | Invalid

type row = {
  name : string;
  entry : Policy.endpoint;
  target : int -> string;
  expect : expectation;
}

let http_to host path port = Printf.sprintf "http://%s:%d%s" host port path

let allowlist_rows : row list =
  [
    { name = "the listed endpoint"; entry = endpoint "127.0.0.1";
      target = http_to "127.0.0.1" "/ok"; expect = Allowed };
    { name = "another name for the same machine"; entry = endpoint "127.0.0.1";
      target = http_to "localhost" "/ok"; expect = Denied };
    { name = "the other scheme"; entry = endpoint ~scheme:`Https "127.0.0.1";
      target = http_to "127.0.0.1" "/ok"; expect = Denied };
    { name = "a port the list does not name"; entry = endpoint "127.0.0.1";
      target = http_to "127.0.0.1" "/ok"; expect = Denied } (* the caller's port is
        the one the {e entry} names, changed below by [check_row] *);
    { name = "a name nobody listed"; entry = endpoint "127.0.0.1";
      target = http_to "elsewhere.test" "/ok"; expect = Denied };
    { name = "userinfo in the URI"; entry = endpoint "127.0.0.1";
      target = (fun port -> Printf.sprintf "http://user:pw@127.0.0.1:%d/ok" port); expect = Invalid };
    { name = "a scheme that is not http"; entry = endpoint "127.0.0.1";
      target = (fun _port -> "file:///etc/passwd"); expect = Invalid };
    { name = "no host at all"; entry = endpoint "127.0.0.1";
      target = (fun _port -> "http:///ok"); expect = Invalid };
  ]

(* One row, with the entry's port set to the fixture's: the row that asks for a
   port the list does not name gets a request two ports away instead. *)
let check_row env sw port row =
  let entry_port =
    match row.name with
    | "a port the list does not name" -> port + 1
    | _ -> port
  in
  let entry = { row.entry with port = Some entry_port } in
  with_endpoints ~net:env#net ~sw [ entry ] (fun decision ->
    let grant = grant_of ~env decision in
    match request grant (row.target port) with
    | Ok response ->
        if row.expect <> Allowed then
          failf "%s: allowed (status %d), expected %s" row.name response.status
            (match row.expect with Denied -> "denied" | Invalid -> "invalid" | Allowed -> "allowed")
        else begin
          Alcotest.(check int) (row.name ^ ": status") 200 response.status;
          Alcotest.(check string) (row.name ^ ": body") "the answer is 42\n" response.body
        end
    | Error error ->
        (match row.expect with
        | Allowed -> failf "%s: refused: %s" row.name (Error.render error)
        | Denied -> check_kind Error.Denied error
        | Invalid -> check_kind Error.Invalid error);
        check_one_line error)

let allowlist_table () = with_fixture (fun env sw port ->
  List.iter (fun row -> check_row env sw port row) allowlist_rows)

(* The same endpoint written two ways is one endpoint; a duplicate is a startup
   mistake an operator wants told about, not a first-match rule. *)
let construction_refusals () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let check name ?(max_response_bytes = Policy.default_max_response_bytes) endpoints expected =
    match Policy.with_endpoints ~sw ~net:env#net ~max_response_bytes endpoints with
    | Ok _ -> failf "%s was accepted" name
    | Error error ->
        check_kind expected error;
        check_one_line error
  in
  check "an empty endpoint list" [] Error.Invalid;
  check "the same host twice, in two cases" [ endpoint "api.test"; endpoint "API.test" ] Error.Invalid;
  check "the default port spelled out beside the shorthand"
    [ endpoint ~scheme:`Https "api.test"; endpoint ~scheme:`Https ~port:443 "api.test" ]
    Error.Invalid;
  check "port zero" [ endpoint ~port:0 "api.test" ] Error.Invalid;
  check "a port past the end of the range" [ endpoint ~port:65_536 "api.test" ] Error.Invalid;
  check "a host that is neither a name nor an address" [ endpoint "not a host" ] Error.Invalid;
  check "a non-positive response ceiling" ~max_response_bytes:0 [ endpoint "api.test" ] Error.Invalid;
  check "an absurd response ceiling" ~max_response_bytes:max_int [ endpoint "api.test" ] Error.Invalid

(* An http-only grant speaks no https, and the scheme half of the pinned endpoint
   is what says so — before anything is looked up. *)
let scheme_is_pinned () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let state, net = scripted_net ~answers:[ ("api.test", [ "93.184.216.34" ]) ] () in
  with_endpoints ~net ~sw [ endpoint ~scheme:`Https "api.test" ] (fun decision ->
    let grant = grant_of ~env decision in
    (match request grant "http://api.test/search" with
     | Error error ->
         check_kind Error.Denied error;
         (* The scheme is part of the pinned endpoint, so the refusal lands
            before the name is looked up. *)
         Alcotest.(check (list (pair string string))) "no resolver query" []
           (Atomic.get state.queries);
         Alcotest.(check (list address_testable)) "no connection" []
           (Atomic.get state.connects)
     | Ok _ -> failf "an http request answered an https endpoint"
     | exception Simulated address ->
         failf "an http request reached an https endpoint at %s" (show_address address)))

(* {1 No resolver traffic for a name the grant does not allow} *)

let unlisted_name_asks_nothing () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let state, net = scripted_net ~answers:[ ("api.test", [ "93.184.216.34" ]) ] () in
  with_endpoints ~net ~sw [ endpoint "api.test" ] (fun decision ->
    let grant = grant_of ~env decision in
    match request grant "http://elsewhere.test/x" with
    | Error error ->
        check_kind Error.Denied error;
        check_one_line error;
        (* The refusal is worth what it costs: nothing. No query, no socket. *)
        Alcotest.(check (list (pair string string))) "no resolver query" [] (Atomic.get state.queries);
        Alcotest.(check (list address_testable)) "no connection" [] (Atomic.get state.connects)
    | Ok _ -> failf "an unlisted name was served"
    | exception Simulated address -> failf "an unlisted name reached %s" (show_address address))

(* {1 The address binding, and the public-web address policy} *)

type address_case = { answer : string; may_connect : bool }

let address_rows : (string * address_case) list =
  let allows answer = (answer, { answer; may_connect = true }) in
  let refuses answer = (answer, { answer; may_connect = false }) in
  [
    allows "93.184.216.34";
    allows "8.8.8.8";
    allows "2001:4860:4860::8888";
    (* The edges of loopback: the policy refuses the block, not a magic address. *)
    allows "126.255.255.255";
    refuses "127.0.0.1";
    refuses "127.1.2.3";
    refuses "127.255.255.255";
    (* [128.0.0.0/16] is the IETF future-use block (RFC 6890), and [Ipaddr]'s
       own [is_global] calls it global — one of the reasons the policy in
       [Policy_net] keeps its own table. *)
    refuses "128.0.0.0";
    refuses "::1";
    refuses "10.0.0.1";
    refuses "192.168.1.1";
    refuses "172.16.5.5";
    refuses "169.254.169.254";
    refuses "100.64.0.1";
    refuses "192.0.2.1";
    refuses "198.51.100.7";
    refuses "203.0.113.9";
    refuses "198.18.0.1";
    refuses "192.0.0.1";
    refuses "0.1.2.3";
    refuses "240.0.0.1";
    refuses "224.0.0.1";
    refuses "255.255.255.255";
    refuses "0.0.0.0";
    refuses "fe80::1";
    refuses "fc00::1";
    refuses "fd12:3456::1";
    refuses "2001:db8::1";
    refuses "2002:7f00:1::";
    refuses "2001:0::1";
    refuses "::ffff:127.0.0.1";
    allows "::ffff:93.184.216.34";
  ]

let public_web_address_table () =
  List.iter
    (fun (name, testCase) ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let state, net = scripted_net ~answers:[ ("api.test", [ testCase.answer ]) ] () in
      with_public_web ~net ~sw (fun decision ->
        let grant = grant_of ~env decision in
        match request grant "http://api.test/x" with
        | exception Simulated address ->
            if not testCase.may_connect then
              failf "%s: %s was allowed, to %s" name testCase.answer (show_address address);
            Alcotest.(check (list address_testable)) name
              [ `Tcp (eio_address testCase.answer, 80) ]
              (Atomic.get state.connects)
        | Error error ->
            if testCase.may_connect then
              failf "%s: %s was refused: %s" name testCase.answer (Error.render error);
            check_kind Error.Denied error;
            check_one_line error;
            Alcotest.(check (list address_testable)) (name ^ ": no connection") []
              (Atomic.get state.connects)
        | Ok response ->
            failf "%s: %s was served a response (status %d)" name testCase.answer response.status))
    address_rows

(* The port policy of [with_public_web] is one rule: the scheme's default port,
   and an explicit port is [with_endpoints]' business. *)
let public_web_refuses_other_ports () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let state, net = scripted_net ~answers:[ ("api.test", [ "93.184.216.34" ]) ] () in
  with_public_web ~net ~sw (fun decision ->
    let grant = grant_of ~env decision in
    match request grant "http://api.test:8080/x" with
    | Error error ->
        check_kind Error.Denied error;
        (* Refused on the port, so the name was never looked up. *)
        Alcotest.(check (list (pair string string))) "no resolver query" [] (Atomic.get state.queries)
    | Ok _ -> failf "a non-default port was served"
    | exception Simulated address -> failf "connected to %s" (show_address address))

(* The rebinding case §5 names: the vetted answer is the address that is
   connected to, and the HTTP client is handed a connector that cannot look the
   name up again. *)
let connect_uses_the_vetted_answer () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let state, net =
    scripted_net ~answers:[ ("api.test", [ "93.184.216.34"; "127.0.0.1" ]) ] ()
  in
  with_endpoints ~net ~sw [ endpoint "api.test" ] (fun decision ->
    let grant = grant_of ~env decision in
    (match request grant "http://api.test/search?q=x" with
    | exception Simulated address ->
        Alcotest.(check address_testable) "the address the grant asked to connect to"
          (`Tcp (eio_address "93.184.216.34", 80)) address;
        Alcotest.(check (list address_testable)) "and that is the only connection it tried"
          [ `Tcp (eio_address "93.184.216.34", 80) ]
          (Atomic.get state.connects)
    | Ok response -> failf "reached a peer (status %d)" response.status
    | Error error -> failf "refused: %s" (Error.render error));
    (* One lookup for one request: the connector cohttp is given ignores the URI,
       so there is no second lookup to race with the first. *)
    Alcotest.(check (list (pair string string))) "one resolver query" [ ("api.test", "80") ]
      (Atomic.get state.queries))

(* The asymmetry the two constructors exist for: [with_endpoints] pins {e names},
   so a listed name that resolves to a private address is reachable — which is how
   a self-hosted provider on an internal network works at all. [with_public_web]
   decides {e addresses}, and the same answer there is a refusal. *)
let listed_names_may_reach_private_addresses () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let state, net = scripted_net ~answers:[ ("searxng.internal", [ "10.0.0.7" ]) ] () in
  with_endpoints ~net ~sw [ endpoint ~port:8080 "searxng.internal" ] (fun decision ->
    let grant = grant_of ~env decision in
    (match request grant "http://searxng.internal:8080/" with
    | exception Simulated _ -> ()
    | Error error -> failf "a listed private endpoint was refused: %s" (Error.render error)
    | Ok response -> failf "reached a peer (status %d)" response.status);
    Alcotest.(check (list address_testable)) "the listed private address"
      [ `Tcp (eio_address "10.0.0.7", 8080) ]
      (Atomic.get state.connects))

(* A listed name whose {e every} answer is refused by nothing: an endpoint list
   vetoes nothing about addresses, so all answers are connectable. This is the
   rebinding risk the operator accepts when they name a host, stated plainly. *)
let every_answer_of_a_listed_name_is_connectable () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let state, net = scripted_net ~answers:[ ("api.test", [ "169.254.169.254" ]) ] () in
  with_endpoints ~net ~sw [ endpoint "api.test" ] (fun decision ->
    let grant = grant_of ~env decision in
    match request grant "http://api.test/" with
    | exception Simulated _ -> ()
    | Error error -> failf "a listed name's answer was refused: %s" (Error.render error)
    | Ok response -> failf "reached a peer (status %d)" response.status);
  Alcotest.(check (list address_testable)) "the metadata address, because the operator named the host"
    [ `Tcp (eio_address "169.254.169.254", 80) ]
    (Atomic.get state.connects)

(* {1 The response ceiling} *)

let response_ceiling () =
  with_fixture (fun env sw port ->
    let uri path = Printf.sprintf "http://127.0.0.1:%d%s" port path in
    with_endpoints ~net:env#net ~sw ~max_response_bytes:4096 [ endpoint ~port "127.0.0.1" ]
    @@ (fun decision ->
      let grant = grant_of ~env decision in
      (* The grant's own ceiling, on a chunked body with no [Content-Length] to
         trust (§5). *)
      (match request grant (uri "/big") with
      | Ok response -> failf "served %d bytes through a 4096-byte ceiling" (String.length response.body)
      | Error error ->
          check_kind Error.Denied error;
          check_one_line error;
          Alcotest.(check bool) "the sentence names the ceiling, not the page" true
            (contains (Error.message error) "4096"));
      (* A caller may lower it. *)
      (match request ~max_response_bytes:256 grant (uri "/big") with
      | Ok response -> failf "a 256-byte caller ceiling served %d bytes" (String.length response.body)
      | Error error -> check_kind Error.Denied error);
      (* A caller may not raise it: asking for a megabyte still meets 4096. *)
      (match request ~max_response_bytes:1_048_576 grant (uri "/big") with
      | Ok response -> failf "a caller raised the ceiling to %d bytes" (String.length response.body)
      | Error error -> check_kind Error.Denied error);
      (* And a ceiling that fits the body reads the whole chunked stream. *)
      with_endpoints ~net:env#net ~sw ~max_response_bytes:65_536 [ endpoint ~port "127.0.0.1" ]
      @@ (fun wide ->
        let wide_grant = grant_of ~env wide in
        match request wide_grant (uri "/big") with
        | Ok response ->
            Alcotest.(check int) "the whole chunked stream" 65_536 (String.length response.body)
        | Error error -> failf "a fitting ceiling refused: %s" (Error.render error))))

(* {1 Redirects: never followed, and an off-list target is a refusal} *)

let redirects () =
  with_fixture (fun env sw port ->
    let uri path = Printf.sprintf "http://127.0.0.1:%d%s" port path in
    with_endpoints ~net:env#net ~sw [ endpoint ~port "127.0.0.1" ] (fun decision ->
      let grant = grant_of ~env decision in
      (match request grant (uri "/redirect-elsewhere") with
      | Error error ->
          check_kind Error.Denied error;
          check_one_line error;
          Alcotest.(check bool) "the sentence names the target's host" true
            (contains (Error.message error) "elsewhere.test")
      | Ok response -> failf "an off-list Location was returned as status %d" response.status
      | exception Simulated address -> failf "an off-list Location was connected to: %s"
          (show_address address));
      (let mark = requests () in
       match request grant (uri "/redirect-here") with
      | Ok response ->
          Alcotest.(check int) "a listed redirect stays a 302" 302 response.status;
          (* Nothing was followed: the fixture saw the one request only. *)
          Alcotest.(check (list string)) "and nothing was followed" [ "/redirect-here" ]
            (paths_since mark)
      | Error error -> failf "a listed redirect was refused: %s" (Error.render error)
      | exception Simulated address -> failf "a redirect was connected to: %s" (show_address address));
      (match request grant (uri "/redirect-alias") with
      | Error error -> check_kind Error.Denied error
      | Ok response -> failf "a redirect to an unlisted name was allowed (status %d)" response.status
      | exception Simulated _ -> failf "a redirect was connected to");
      match request grant (uri "/redirect-relative") with
      | Ok response -> Alcotest.(check int) "a relative Location stays a 302" 302 response.status
      | Error error -> failf "a relative Location was refused: %s" (Error.render error)
      | exception Simulated _ -> failf "a relative Location was connected to"))

(* {1 Request validation} *)

let request_headers () =
  with_fixture (fun env sw port ->
    let uri path = Printf.sprintf "http://127.0.0.1:%d%s" port path in
    with_endpoints ~net:env#net ~sw [ endpoint ~port "127.0.0.1" ] (fun decision ->
      let grant = grant_of ~env decision in
      (* The headers that decide which virtual host is served, where one request
         ends, and what happens to the connection are the authority's (§5). *)
      List.iter
        (fun name ->
          match request ~headers:[ (name, "anything") ] grant (uri "/ok") with
          | Ok _ -> failf "a caller set the %s header and it was sent" name
          | Error error -> check_kind Error.Invalid error)
        [ "host"; "Host"; "content-length"; "transfer-encoding"; "connection"; "upgrade" ];
      (* A name or value that could split a request is refused, and the refusal
         does not quote the value. *)
      (match request ~headers:[ ("x-tool", "a\r\nX: b") ] grant (uri "/ok") with
      | Ok _ -> failf "a header value with CRLF was sent"
      | Error error ->
          check_kind Error.Invalid error;
          Alcotest.(check bool) "the message does not quote the value" false
            (contains (Error.message error) "X: b"));
      (match request ~headers:[ ("bad name", "x") ] grant (uri "/ok") with
      | Ok _ -> failf "a header name with a space was sent"
      | Error error -> check_kind Error.Invalid error);
      (* The Host the fixture sees is the authority's, not the caller's. *)
      (match request ~headers:[ ("x-tool", "seekwright-test") ] grant (uri "/headers") with
      | Ok response ->
          Alcotest.(check string) "the Host header the fixture received"
            (Printf.sprintf "host=127.0.0.1:%d" port)
            (List.nth (String.split_on_char '\n' response.body) 0);
          Alcotest.(check string) "and the caller's own header arrived" "x-tool=seekwright-test"
            (List.nth (String.split_on_char '\n' response.body) 1)
      | Error error -> failf "the header echo failed: %s" (Error.render error));
      (* A method and a body the caller chose, delivered. *)
      let mark = requests () in
      match request ~meth:`POST ~body:(Bytes.to_string (Bytes.make 4096 'x')) grant (uri "/echo") with
      | Ok response ->
          Alcotest.(check string) "the body round-tripped" (Bytes.to_string (Bytes.make 4096 'x'))
            response.body;
          Alcotest.(check (list string)) "with the path the caller named" [ "/echo" ]
            (paths_since mark);
          (* What the fixture {e saw} is the other half of the round trip: the
             method and body the caller chose, and the [Host] the authority wrote
             rather than one the caller supplied. *)
          (match Atomic.get seen with
          | entry :: _ ->
              Alcotest.(check string) "the method the fixture saw" "POST" entry.method_;
              Alcotest.(check int) "the request body the fixture saw" 4096 entry.body_bytes;
              Alcotest.(check string) "the Host the authority sent"
                (Printf.sprintf "127.0.0.1:%d" port) entry.host
          | [] -> failf "the fixture recorded no request")
      | Error error -> failf "the POST echo failed: %s" (Error.render error)))

(* A request body over the authority's own bound is refused before it is sent. *)
let request_body_bound () =
  with_fixture (fun env sw port ->
    with_endpoints ~net:env#net ~sw [ endpoint ~port "127.0.0.1" ] (fun decision ->
      let grant = grant_of ~env decision in
      match request ~meth:`POST ~body:(Bytes.to_string (Bytes.make 1_000_000 'x'))
              grant (Printf.sprintf "http://127.0.0.1:%d/echo" port)
      with
      | Ok _ -> failf "a megabyte request body was sent"
      | Error error ->
          check_kind Error.Invalid error;
          (* Refused before the socket, so the fixture saw nothing. *)
          Alcotest.(check int) "the fixture was not called" 0 (List.length (Atomic.get seen))))

(* {1 Time bounds and operation budgets} *)

let timeout_trip () =
  with_fixture (fun env sw port ->
    with_endpoints ~net:env#net ~sw [ endpoint ~port "127.0.0.1" ] (fun decision ->
      let clock = Eio.Stdenv.mono_clock env in
      let grant =
        Authority.with_operation_timeout
          (Eio.Time.Timeout.seconds clock (slow_seconds /. 10.0))
          (grant_of ~env decision)
      in
      match request grant (Printf.sprintf "http://127.0.0.1:%d/slow" port) with
      | Ok response -> failf "a %f second operation finished with status %d" slow_seconds response.status
      | Error error ->
          check_kind Error.Timeout error;
          check_one_line error))

(* §6's claim that the bound is per {e operation}: several calls through one grant
   each get their own, so a fast sequence is not cut short by a shared deadline. *)
let timeout_is_per_operation () =
  with_fixture (fun env sw port ->
    with_endpoints ~net:env#net ~sw [ endpoint ~port "127.0.0.1" ] (fun decision ->
      let clock = Eio.Stdenv.mono_clock env in
      let grant =
        Authority.with_operation_timeout
          (Eio.Time.Timeout.seconds clock 0.5)
          (grant_of ~env decision)
      in
      repeat 3 (fun () ->
        match request grant (Printf.sprintf "http://127.0.0.1:%d/ok" port) with
        | Ok response -> Alcotest.(check int) "served" 200 response.status
        | Error error -> failf "a repeated operation failed: %s" (Error.render error))))

(* A caller-owned counter, spent once per operation; the refusal does no I/O,
   which is what makes the budget observable at the far end (§6). *)
let operation_budget () =
  with_fixture (fun env sw port ->
    with_endpoints ~net:env#net ~sw [ endpoint ~port "127.0.0.1" ] (fun decision ->
      let budget = Budget.make 2 in
      let grant = Authority.with_operation_budget budget (grant_of ~env decision) in
      let served = ref 0 in
      let refused = ref 0 in
      repeat 4 (fun () ->
        match request grant (Printf.sprintf "http://127.0.0.1:%d/ok" port) with
        | Ok _ -> incr served
        | Error error ->
            check_kind Error.Denied error;
            incr refused);
      Alcotest.(check int) "two operations were served" 2 !served;
      Alcotest.(check int) "two were refused by the budget" 2 !refused;
      Alcotest.(check int) "the counter does not go below zero" 0 (Budget.remaining budget);
      Alcotest.(check int) "the fixture was called exactly twice" 2 (List.length (Atomic.get seen))))

(* A grant shared by two fibers spends one budget atomically: N fibers cannot all
   pass the same check. *)
let budget_is_atomic () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let state, net = scripted_net ~answers:[ ("api.test", [ "93.184.216.34" ]) ] () in
  with_endpoints ~net ~sw [ endpoint "api.test" ] (fun decision ->
    let budget = Budget.make 3 in
    let grant = Authority.with_operation_budget budget (grant_of ~env decision) in
    let taken = Atomic.make 0 in
    let attempt () =
      match request grant "http://api.test/" with
      | exception Simulated _ -> Atomic.incr taken
      | Ok _ -> failf "the scripted network handed out a socket"
      | Error _ -> ()
    in
    Eio.Fiber.both (fun () -> repeat 4 attempt) (fun () -> repeat 4 attempt);
    Alcotest.(check int) "eight calls, three operations' worth of budget" 3 (Atomic.get taken);
    ignore state)

(* {1 The audit event}

   §6's claim is that a deployment can log {e every} authority operation without
   a page, a body or a header reaching the log, so the assertions worth making are
   about what the line does not contain. *)

let audit_events () =
  with_fixture (fun env sw port ->
    let events = Atomic.make [] in
    let uri path = Printf.sprintf "http://127.0.0.1:%d%s" port path in
    with_endpoints ~net:env#net ~sw [ endpoint ~port "127.0.0.1" ] (fun decision ->
      let grant =
        Authority.with_log ~sink:(fun event -> push events event)
          (grant_of ~env decision)
      in
      ignore (request grant (uri "/ok") : (_, _) result);
      ignore (request ~max_response_bytes:64 grant (uri "/big") : (_, _) result);
      ignore (request grant "http://elsewhere.test/" : (_, _) result);
      let logged = List.rev (Atomic.get events) in
      Alcotest.(check int) "one event per operation" 3 (List.length logged);
      List.iter
        (fun event ->
          Alcotest.(check string) "the operation is a constant name, not the URL" "net.request"
            (Event.operation event);
          let line = Event.render event in
          Alcotest.(check bool) ("the line is one line: " ^ line) true
            (String.for_all (fun char -> Char.code char <> 10 && Char.code char <> 13) line);
          List.iter
            (fun needle ->
              Alcotest.(check bool) (Printf.sprintf "%S is not in the audit line: %s" needle line)
                false (contains line needle))
            [ "/ok"; "/big"; "127.0.0.1"; "localhost"; "elsewhere"; "answer"; "http"; "42" ])
        logged;
      match logged with
      | [ served; capped; refused ] ->
          Alcotest.(check bool) "a served request reports Ok" true
            (Event.outcome served = Event.Ok);
          Alcotest.(check (option int)) "with the size of what moved, not what moved"
            (Some 17) (Event.bytes served);
          Alcotest.(check bool) "and the status as an operator-chosen note" true
            (List.exists (fun note -> note = ("status", "200")) (Event.notes served));
          Alcotest.(check bool) "a refused body reports the denial" true
            (Event.outcome capped = Event.Failed Error.Denied);
          Alcotest.(check bool) "an unlisted host reports Denied too" true
            (Event.outcome refused = Event.Failed Error.Denied)
      | _ -> failf "expected three events"))

(* An https endpoint against a cleartext server: the handshake fails rather than
   the connection being downgraded, and no request reaches the server. The
   downgrade is the failure §5 refuses, and this is the shape that proves TLS is
   really on the wire. *)
let https_is_not_downgraded () =
  with_fixture (fun env sw port ->
    with_endpoints ~net:env#net ~sw [ endpoint ~scheme:`Https ~port "127.0.0.1" ]
    @@ (fun decision ->
      (* A short bound of its own: the fixture is an HTTP server, so it waits
         for a request line that a TLS client will never send, and the handshake
         stalls rather than being refused. Both shapes are the guarantee this
         case is about — the conversation was TLS or it was nothing — and the
         bound is what keeps the case from sitting at the grant's default. *)
      let grant =
        Authority.with_operation_timeout
          (Eio.Time.Timeout.seconds (Eio.Stdenv.mono_clock env) 2.0)
          (grant_of ~env decision)
      in
      match request grant (Printf.sprintf "https://127.0.0.1:%d/ok" port) with
      | Ok response -> failf "a cleartext server answered an https grant (status %d)" response.status
      | Error error ->
          (match Error.kind error with
          | Error.Failed | Error.Timeout -> ()
          | kind ->
              failf "the handshake failed as %s: %s" (Error.kind_to_string kind) (Error.render error));
          check_one_line error;
          (* The point of the case: no HTTP request was ever sent, so a grant
             that speaks https cannot be talked down to cleartext. *)
          Alcotest.(check int) "the cleartext server saw no request" 0 (List.length (Atomic.get seen))
      | exception Simulated address -> failf "the https grant never connected: %s"
          (show_address address)))

(* A grant that speaks https has to {e get} a trust store, and if the application
   never installed a random generator, construction fails with the sentence that
   names what to call (§5: "fail construction loudly"). This case is the {e other}
   half: with an RNG installed, an https grant is built. *)
let https_grants_are_built_with_tls () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Policy.with_endpoints ~sw ~net:env#net ~max_response_bytes:1024
          [ endpoint ~scheme:`Https "api.test" ] with
  | Ok _ -> ()
  | Error error -> failf "an https grant failed to build: %s" (Error.render error)

(* {1 The suite} *)

let () =
  Alcotest.run "mcp-caps-authority-net"
    [
      ( "endpoint allowlist",
          [
            Alcotest.test_case "the scheme/host/port table" `Quick allowlist_table;
            Alcotest.test_case "construction refusals" `Quick construction_refusals;
            Alcotest.test_case "an http grant speaks no https" `Quick scheme_is_pinned;
          ] );
      ( "resolver and address policy",
          [
            Alcotest.test_case "an unlisted name asks no DNS question" `Quick unlisted_name_asks_nothing;
            Alcotest.test_case "the public-web address table" `Quick public_web_address_table;
            Alcotest.test_case "the public-web grant uses the scheme's port" `Quick
              public_web_refuses_other_ports;
            Alcotest.test_case "connect uses the vetted answer" `Quick connect_uses_the_vetted_answer;
            Alcotest.test_case "a listed name may reach a private address" `Quick
              listed_names_may_reach_private_addresses;
            Alcotest.test_case "every answer of a listed name is connectable" `Quick
              every_answer_of_a_listed_name_is_connectable;
          ] );
      ( "response bounds",
          [
            Alcotest.test_case "the response ceiling, on a chunked body" `Quick response_ceiling;
          ] );
      ( "redirects",
          [ Alcotest.test_case "never followed, off-list refused" `Quick redirects ] );
      ( "request validation",
          [
            Alcotest.test_case "owned headers, injection, method and body" `Quick request_headers;
            Alcotest.test_case "a request body over the bound is refused" `Quick request_body_bound;
          ] );
      ( "bounds and audit",
          [
            Alcotest.test_case "a waiting operation hits its time bound" `Quick timeout_trip;
            Alcotest.test_case "the bound is per operation" `Quick timeout_is_per_operation;
            Alcotest.test_case "a caller's operation budget" `Quick operation_budget;
            Alcotest.test_case "the budget is atomic across fibers" `Quick budget_is_atomic;
            Alcotest.test_case "one bounded audit line per operation" `Quick audit_events;
          ] );
      ( "https",
          [
            Alcotest.test_case "an https grant is not answered in cleartext" `Quick
              https_is_not_downgraded;
            Alcotest.test_case "an https grant builds with a trust store" `Quick
              https_grants_are_built_with_tls;
          ] );
    ]
