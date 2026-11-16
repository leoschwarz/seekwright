(* The shared vendor-suite fixture. Everything here exists so a test can say
   what a fallback would have sent and what the vendor answered, with no
   socket, no clock, and no third party. *)

module Caps = Mcp_caps
module Fallback = Seekwright_fetch.Fallback
module Remote_target = Seekwright_fetch.Remote_target

type outcome = Response of int * string | Transport of Caps.Error.t

type recorded = {
  meth : Caps.Policy_net.method_;
  uri : string;
  headers : (string * string) list;
  body : string option;
}

(* The suites are single-threaded, so plain cells: what matters is what was
   recorded and what the script answers, not safe publication. *)
type t = { mutable requests : recorded list; mutable script : outcome list }

let make script = { requests = []; script }

(* [Atomic.modify] keeps popping in one step; two requests on one fixture
   would otherwise race — the suites issue one at a time, and the fixture
   should still not answer the second request with the first answer if a
   vendor ever retried internally. *)
let pop_answer t =
  match t.script with
  | [] -> Response (200, "{}")
  | first :: rest ->
      t.script <- rest;
      first

(* Newest first; [requests] reverses, so a case that issues two sees them in
   the order they were sent. *)
let record t request =
  t.requests <-
    {
      meth = request.Caps.Authority.Net.meth;
      uri = Uri.to_string request.Caps.Authority.Net.uri;
      headers = request.headers;
      body = request.body;
    }
    :: t.requests

let net t =
  {
    Fallback.request =
      (fun ~max_response_bytes:_ request ->
        record t request;
        match pop_answer t with
        | Response (status, body) -> Ok { Caps.Authority.Net.status; headers = []; body }
        | Transport error -> Error error);
  }

let requests t = List.rev t.requests

(* The scripted resolver, same shape as [test_authority_net]'s: no socket,
   answers from a table. *)
module Scripted_resolver = struct
  type t = unit
  type tag = [ `Generic ]

  let unusable () = raise (Eio.Net.err Eio.Net.Invalid_option)
  let listen _t ~reuse_addr:_ ~reuse_port:_ ~backlog:_ ~sw:_ _address = unusable ()

  (* The fake hands out no socket, and the target check never asks for one —
     [connect] raising is the guard that stays true. *)
  let connect _t ~bind_to:_ ~options:_ ~sw:_ _address = unusable ()

  let datagram_socket _t ~reuse_addr:_ ~reuse_port:_ ~sw:_ _address = unusable ()

  let getaddrinfo _t ~service host =
    let port = int_of_string service in
    let answer address =
      [ `Tcp (Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets (Ipaddr.of_string_exn address)), port) ]
    in
    match host with
    | "public.test" -> answer "93.184.216.34"
    | "internal.test" -> answer "127.0.0.1"
    | _ -> []

  let getnameinfo _t _address = ("scripted.test", "0")
end

let remote_target () =
  Remote_target.make (Eio.Resource.T ((), Eio.Net.Pi.network (module Scripted_resolver)))

let public_url = "https://public.test/page"

let show_error = function
  | Fallback.Url_blocked message -> "url_blocked: " ^ message
  | Fallback.Rejected message -> "rejected: " ^ message
  | Fallback.Quota message -> "quota: " ^ message
  | Fallback.Failed message -> "failed: " ^ message

let error_case ~kind ~message = kind ^ ": " ^ message

let ok_page outcome label =
  match outcome with
  | Ok page -> page
  | Error error -> Alcotest.failf "%s: got Error (%s), expected a page" label (show_error error)

let show_recorded r =
  Printf.sprintf "{ meth=%s; uri=%S; headers=%s; body=%s }"
    (match r.meth with
    | `GET -> "GET"
    | `POST -> "POST"
    | `PUT -> "PUT"
    | `PATCH -> "PATCH"
    | `DELETE -> "DELETE")
    r.uri
    (String.concat "," (List.map (fun (k, v) -> k ^ "=" ^ v) r.headers))
    (match r.body with None -> "None" | Some b -> "Some " ^ b)

let testable_string = Alcotest.string

let check_request t expected =
  match requests t with
  | [ got ] ->
      Alcotest.(check string)
        "method"
        (show_recorded { got with headers = []; body = None; uri = "" })
        (show_recorded { expected with headers = []; body = None; uri = "" });
      Alcotest.(check string) "uri" got.uri expected.uri;
      Alcotest.(check (list (pair testable_string testable_string)))
        "headers" got.headers expected.headers;
      Alcotest.(check (option testable_string)) "body" got.body expected.body
  | [] -> Alcotest.fail "no request was sent"
  | many ->
      Alcotest.failf "%d requests were sent; expected exactly one: %s" (List.length many)
        (String.concat " | " (List.map show_recorded many))

let check_no_request t label = Alcotest.(check int) label 0 (List.length (requests t))
