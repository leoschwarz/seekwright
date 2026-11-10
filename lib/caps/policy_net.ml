(* The network confinement: an endpoint policy, the DNS-to-connect binding that
   makes it mean something, and the bounds around one operation. policy_net.mli
   states the guarantees; this file is where each one is implemented, and
   test/test_authority_net.ml is the evidence.

   The order of the code is the order of a request: decide the destination from
   the policy, resolve it, vet every answer, bind the connection to one vetted
   address, speak HTTP over that socket, and bound what comes back. *)

type method_ = [ `GET | `POST | `PUT | `PATCH | `DELETE ]

type request = {
  meth : method_;
  uri : Uri.t;
  headers : (string * string) list;
  body : string option;
}

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

type endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
}

(* A normalised endpoint: the scheme, host and {b effective} port a request has
   to match exactly. [peer_name] is what TLS puts in SNI and checks in the
   certificate — the {b endpoint's} hostname, never the address we happened to
   connect to — which is what keeps certificate verification meaningful while
   the connection itself is made by IP. [peer_ip] is the same idea for a host
   that is an IP literal. *)
type destination = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int;
  peer_name : [ `host ] Domain_name.t option;
  peer_ip : Ipaddr.t option;
}

type policy =
  | Endpoints of destination list
  | Public_web

(* [Eio.Net.t] is parameterised by the backend's resource tag ([ `Posix ],
   [ `Linux ], …), and a record type cannot carry an existential tag — [_] is not
   allowed in a type declaration. So the record is parameterised and [t] hides
   the tag: the application's own network value keeps its real type, and nothing
   in this module or its interface needs to name it. *)
type 'tag confinement = {
  net : 'tag Eio.Net.t;
  max_response_bytes : int;
  policy : policy;
  (* [None] only when no entry of the policy can be reached over https: the
     trust anchor store is read at construction, so a grant that {b can} speak
     https either has a working configuration or was never built (§5 — an
     http-only path must not be able to pass as a finished M3). *)
  tls : Tls.Config.client option;
}

type t = T : 'tag confinement -> t

(* A page or a provider JSON body lives well inside this, and an uncapped body
   lets the calling model decide how large our own response is — the same reason
   [Policy_fs.default_max_read_bytes] is modest. *)
let default_max_response_bytes = 262_144

(* The operator's ceiling has to be finite for a second, arithmetic reason: the
   streaming ceiling is [limit + 1] bytes, and [max_int + 1] wraps. *)
let max_configurable_response_bytes = 16_777_216

(* Covers DNS, connect, TLS, headers and body: one bound around the whole
   operation, because a bound per phase would let a peer that is merely slow in
   each phase add up to an unbounded call (§5). *)
let default_operation_timeout_seconds = 15.

(* Provider request bodies are query JSON. Bounding the request is the same
   shape as bounding the response, and it keeps a tool's own bug from turning
   into an outbound flood. *)
let max_request_bytes = 65_536

let max_request_headers = 64
let max_request_header_bytes = 8_192

let http_port = 80
let https_port = 443

let ( >>= ) = Result.bind

(* Raised inside the connector, whose type is a flow rather than a result, and
   turned back into an [Error.t] by the one [try] in [send]. It never escapes
   this module. *)
exception Refusal of Error.t

let refuse error = raise (Refusal error)

(** {1 Endpoint normalisation and the destination decision} *)

let scheme_port = function `Http -> http_port | `Https -> https_port
let scheme_name = function `Http -> "http" | `Https -> "https"

(* A host is either an IP literal (TLS then verifies the certificate against the
   address) or a domain name (TLS verifies the name). Trying the address first
   matters: [Domain_name.of_string] accepts "127.0.0.1" as a name, which would
   ask for a certificate issued to a name no CA issues for an address. *)
let host_rejected host =
  Error
    (Error.make Error.Invalid
       ~message:
         (Printf.sprintf "%s is neither a domain name nor an IP address, so it cannot be an \
                          endpoint or a request target"
            (Error.sanitize host)))

let classify_host host =
  match Ipaddr.of_string host with
  | Ok ip -> Ok (None, Some ip)
  | Error _ -> (
      match Domain_name.of_string host with
      | Error _ -> host_rejected host
      | Ok raw -> (
          match Domain_name.host raw with
          | Ok name -> Ok (Some name, None)
          | Error _ -> host_rejected host))

let normalise_host raw =
  let trimmed = String.trim raw in
  let lower = String.lowercase_ascii trimmed in
  (* A trailing dot is the root label written out; it names the same host and
     would otherwise fail to match an entry written without it. *)
  let length = String.length lower in
  let host =
    if length > 1 && lower.[length - 1] = '.' then String.sub lower 0 (length - 1) else lower
  in
  if host = "" then Error (Error.make Error.Invalid ~message:"a host is required")
  else if String.length host > 253 then
    Error (Error.make Error.Invalid ~message:"a host is longer than 253 characters")
  else if
    String.contains host '/'
    || String.contains host '@'
    || String.contains host '\\'
    || String.contains host ' '
  then
    (* [Uri.host] should not hand these over, so this is defence in depth
       against a URI that parses a path or userinfo into the host. *)
    Error (Error.make Error.Invalid ~message:"a host contains a character that is not in a host")
  else Ok host

(* The annotations are not noise: [endpoint] and [destination] share the field
   names [scheme], [host] and [port], and without them the compiler resolves
   [x.host] to the {e later} record type and infers the argument's type from the
   use — which turns [port : int option] into [port : int] three lines later. *)
let normalise_endpoint (entry : endpoint) =
  let ( let* ) = Result.bind in
  let* host = normalise_host entry.host in
  let* port =
    match entry.port with
    | None -> Ok (scheme_port entry.scheme)
    | Some port when port <= 0 || port > 65_535 ->
        Error (Error.make Error.Invalid ~message:"an endpoint port is between 1 and 65535")
    | Some port -> Ok port
  in
  let* peer_name, peer_ip = classify_host host in
  Ok ({ scheme = entry.scheme; host; port; peer_name; peer_ip } : destination)

(* The host is what an auditor greps for, so a duplicate entry — one written
   [Api.test], one [api.test] — is a startup mistake worth refusing rather than
   a first-match rule a reader has to remember. *)
let same_destination a b =
  String.equal a.host b.host && a.port = b.port && a.scheme = b.scheme

let normalise_endpoints endpoints =
  if endpoints = [] then
    Error
      (Error.make Error.Invalid
         ~message:
           "with_endpoints needs at least one endpoint; an empty list is a grant that can reach \
            nothing, which is a configuration mistake rather than a policy")
  else
    let rec walk seen = function
      | [] -> Ok (List.rev seen)
      | endpoint :: rest -> (
          match normalise_endpoint endpoint with
          | Error _ as failure -> failure
          | Ok destination ->
              if List.exists (fun existing -> same_destination existing destination) seen then
                Error
                  (Error.make Error.Invalid
                     ~message:
                       (Printf.sprintf "%s:%d is listed twice as an endpoint"
                          (Error.sanitize destination.host) destination.port))
              else walk (destination :: seen) rest)
    in
    walk [] endpoints

let scheme_of_uri uri =
  match Uri.scheme uri with
  | Some "http" -> Ok `Http
  | Some "https" -> Ok `Https
  | Some other ->
      Error
        (Error.make Error.Invalid
           ~message:
             (Printf.sprintf "%s is not a scheme this grant speaks; only http and https"
                (Error.sanitize other)))
  | None -> Error (Error.make Error.Invalid ~message:"an absolute http or https URI is required")

let port_of_uri uri scheme =
  match Uri.port uri with
  | None -> Ok (scheme_port scheme)
  | Some port when port <= 0 || port > 65_535 ->
      Error (Error.make Error.Invalid ~message:"the URI names a port outside 1..65535")
  | Some port -> Ok port

(* Where a request is allowed to go, as a decision about {b this} grant. Nothing
   here touches DNS: an unlisted host is refused before a single query leaves, so
   a grant cannot be probed by resolver traffic and a denial costs nothing. *)
let decide_destination (t : 'tag confinement) uri =
  let ( let* ) = Result.bind in
  let* scheme = scheme_of_uri uri in
  let* host =
    match Uri.host uri with
    | None | Some "" -> Error (Error.make Error.Invalid ~message:"the URI names no host")
    | Some host -> normalise_host host
  in
  (* [Uri.user]/[Uri.password] are refused rather than stripped: userinfo in an
     http URI is a credential, and either forwarding it or silently dropping it
     is worse than saying no (§5). *)
  let* () =
    match (Uri.user uri, Uri.password uri) with
    | None, None -> Ok ()
    | _ -> Error (Error.make Error.Invalid ~message:"userinfo in a URI is refused")
  in
  let* port = port_of_uri uri scheme in
  let* peer_name, peer_ip = classify_host host in
  let candidate = { scheme; host; port; peer_name; peer_ip } in
  match t.policy with
  | Endpoints allowed ->
      if List.exists (fun entry -> same_destination entry candidate) allowed then Ok candidate
      else
        Error
          (Error.make Error.Denied
             ~message:
               (Printf.sprintf "%s://%s:%d is not one of the endpoints this grant allows"
                  (scheme_name scheme) (Error.sanitize host) port))
  | Public_web ->
      (* One documented port policy: a public-web read goes to the default port
         of the scheme it names. Any other port is a tunnel to some other
         service, which is what the port half of an SSRF allow-list is for;
         [with_endpoints] is how an operator names a non-default port. *)
      if port <> scheme_port scheme then
        Error
          (Error.make Error.Denied
             ~message:
               (Printf.sprintf
                  "%s://%s:%d is refused: the public-web grant uses port %d for %s, and an \
                   explicit port needs an endpoint list"
                  (scheme_name scheme) (Error.sanitize host) port (scheme_port scheme)
                  (scheme_name scheme)))
      else Ok candidate

(** {1 Address classification for the public-web policy}

    ipaddr's [is_global] covers the classic scopes: loopback, RFC1918,
    link-local, multicast, unspecified, broadcast, and the IPv4-mapped IPv6
    forms (whose scope ipaddr computes from the embedded v4 address, which is
    the IPv4-mapped case §5 names). What it still calls global, and this table
    refuses, is the IANA special-purpose space and the transition mechanisms
    that smuggle an address in from another family. *)

let special_use : (string * int) list =
  [
    (* IANA special-purpose registry, IPv4. *)
    ("0.0.0.0", 8); (* "this host on this network" — ipaddr treats only the
                       exact address as non-global, so the whole block goes here *)
    ("128.0.0.0", 16); (* future use, reserved (RFC 6890) *)
    ("100.64.0.0", 10); (* shared address space (CGNAT) *)
    ("192.0.0.0", 24); (* IETF protocol assignments *)
    ("192.0.2.0", 24); (* documentation (TEST-NET-1) *)
    ("198.18.0.0", 15); (* benchmarking *)
    ("198.51.100.0", 24); (* documentation (TEST-NET-2) *)
    ("203.0.113.0", 24); (* documentation (TEST-NET-3) *)
    ("240.0.0.0", 4); (* reserved for future use *)
    (* IPv6. [fc00::/7] is unique-local, and ipaddr reports its scope as global;
       the rest are the documentation and transition ranges, which name
       addresses that are not publicly routable by construction. [fe80::/10]
       and the multicast ranges are already refused by [is_global] and
       [is_multicast] — they are listed because a second, independent refusal of
       a range this policy cares about is cheap. *)
    ("fc00::", 7);
    ("fe80::", 10);
    ("2001:db8::", 32);
    ("2001::", 32); (* Teredo *)
    ("2002::", 16); (* 6to4 *)
    ("100::", 64); (* discard *)
  ]

(* [mem_network "100.64.0.0" 10 ip] compares the leading [bits] of the two
   addresses' octets. Hand-rolled rather than built on ipaddr's internal
   [Prefix], which is not part of its interface; and the table mixes families,
   which [to_octets] settles: 4 bytes for v4, 16 for v6, so a family mismatch
   is a plain non-match. *)
let mem_network network bits ip =
  match Ipaddr.of_string network with
  | Error _ -> false
  | Ok network ->
      let a = Ipaddr.to_octets ip in
      let b = Ipaddr.to_octets network in
      String.length a = String.length b
      &&
      let whole = bits / 8 and rest = bits mod 8 in
      let rec check index =
        if index < whole then a.[index] = b.[index] && check (index + 1)
        else if rest = 0 then true
        else
          (* A prefix keeps the {e high} [rest] bits of the next octet, so the
             mask is [0xff] shifted left, not right: [fc00::/7] must cover
             [fd12:3456::1] as well as [fc00::1]. *)
          let mask = (0xff lsl (8 - rest)) land 0xff in
          (Char.code a.[index] land mask) = (Char.code b.[index] land mask)
      in
      check 0

let in_special_use ip =
  List.exists (fun (network, bits) -> mem_network network bits ip) special_use

(* The address half of the two policies, and the asymmetry that is the reason
   there are two constructors.

   An endpoint list pins {b names}: an operator who writes [searxng.internal] or
   [127.0.0.1] has decided that destination is allowed, and this layer's job is
   to make the connection really go to whatever that name resolves to, not to
   second-guess the choice. The public-web policy decides {b addresses}: every
   answer must be globally routable unicast, outside the table above.

   That is also why a loopback test server is a normal [with_endpoints] fixture
   while the same address is a refusal under [with_public_web]. *)
let satisfies_address policy ip =
  match policy with
  | Endpoints _ -> true
  | Public_web ->
      Ipaddr.is_global ip && not (Ipaddr.is_multicast ip) && not (in_special_use ip)

(** {1 Resolution, and the binding to one vetted address} *)

(* One classification for every failure at this boundary (§3). No message names
   the peer's bytes: an exception string from a HTTP client can carry what the
   server sent, and that text has no business in a tool result. *)
let classify exn =
  match exn with
  (* Cancellation is Eio's control flow, not a provider failure (§4). *)
  | Eio.Cancel.Cancelled _ | Eio.Exn.Multiple _ -> raise exn
  | Eio.Io (Eio.Net.E (Eio.Net.Address_lookup_failed code), _) ->
      Error
        (Error.make Error.Unavailable
           ~message:
             ("the host could not be resolved ("
             ^ Eio.Net.Getaddrinfo_error.to_tag code ^ ")"))
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_failure Eio.Net.Timeout), _) ->
      Error (Error.make Error.Timeout ~message:"connecting to the vetted address exceeded its bound")
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_failure _), _) ->
      Error (Error.make Error.Unavailable ~message:"the endpoint refused the connection")
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) ->
      Error (Error.make Error.Failed ~message:"the endpoint reset the connection")
  | Eio.Io (Eio.Net.E Eio.Net.Invalid_option, _) ->
      Error (Error.make Error.Failed ~message:"the connection could not be set up")
  | Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ ->
      (* The detail can name what the peer sent, so the sentence is ours: the
         caller needs to know the TLS conversation failed and that the
         certificate was not accepted, not what the peer said about it. *)
      Error
        (Error.make Error.Failed
           ~message:"the TLS handshake failed — the certificate was not trusted for that endpoint")
  (* cohttp-eio's client reports a response it cannot parse with [failwith], and
     the string it builds can come from the peer. Naming it would put
     peer-controlled text in a tool result, which is what [Error] exists to
     stop. *)
  | Failure _ | Invalid_argument _ ->
      Error (Error.make Error.Failed ~message:"the endpoint sent a response this client could not read")
  (* Any other Eio fault is reported by kind, without its payload: the detail of
     an [Eio.Io] names the flow and sometimes the peer, and a tool has no use for
     either. Anything that is not an [Eio.Io] is a bug in this tree or in the
     caller, and propagates rather than being dressed up as a provider failure. *)
  | Eio.Io _ -> Error (Error.make Error.Failed ~message:"the request failed")
  | _ -> raise exn

(* Eio's answer type is its own [Eio.Net.Ipaddr], not [Ipaddr.t], and the policy
   is written in terms of [Ipaddr] (which is where [is_global] and the scope
   computations live). The conversion is the raw octets in both directions, so
   the address the policy vetted and the address handed to [connect] are the same
   bytes with no parse step in between. An answer this conversion cannot classify
   is refused: an address the policy cannot name is an address the policy cannot
   allow. *)
let policy_address policy (ip : Eio.Net.Ipaddr.v4v6) =
  match Ipaddr.of_octets (ip :> string) with
  | Ok address -> satisfies_address policy address
  | Error _ -> false

(* One lookup, every answer vetted, and the address the connection will use.
   The whole list is kept rather than the first answer, so the refusal can say
   how many addresses the name had — without naming any of them. *)
let resolve (t : 'tag confinement) destination =
  let ( let* ) = Result.bind in
  let* answers =
    try
      Ok
        (Eio.Net.getaddrinfo_stream
           ~service:(string_of_int destination.port)
           t.net destination.host)
    with ex -> classify ex
  in
  let on_port =
    List.filter_map
      (function `Tcp (ip, port) when port = destination.port -> Some ip | _ -> None)
      answers
  in
  if on_port = [] then
    Error
      (Error.make Error.Unavailable
         ~message:
           (Printf.sprintf "%s resolved to no address usable on port %d"
              (Error.sanitize destination.host) destination.port))
  else
    let vetted = List.filter (policy_address t.policy) on_port in
    if vetted = [] then
      Error
        (Error.make Error.Denied
           ~message:
             (Printf.sprintf
                "%s resolved to %d address(es), none of which this grant may connect to (the \
                 public-web policy allows only globally routable unicast addresses)"
                (Error.sanitize destination.host) (List.length on_port)))
    else (* The [Eio] form, because that is what [Eio.Net.connect] takes: the
            vetting and the connection name the same address, which is the whole
            point of resolving here rather than letting the HTTP client do it. *)
      Ok (List.hd vetted)

(** {1 Request validation} *)

(* Header names the authority owns. A caller-set [host] would send one virtual
   host while the policy, TLS and the socket all say another; [content-length]
   and [transfer-encoding] decide where one request ends, which is the request
   smuggling primitive; [connection], [upgrade] and [keep-alive] ask for
   behaviour outside this grant's model of one connection per request. *)
let authority_owned_headers =
  ["host"; "content-length"; "transfer-encoding"; "connection"; "upgrade"; "keep-alive"]

(* RFC 7230 tchar, minus the colon that would turn a name into a value. *)
let is_token_character char =
  let code = Char.code char in
  code >= 0x21 && code <= 0x7e && code <> 0x3a

let header_value_is_valid value =
  String.for_all
    (fun char ->
      let code = Char.code char in
      (code >= 0x20 && code <= 0x7e) || code = 0x09 || code >= 0x80)
    value

(* The refusal names which header and why, and never quotes the value: a value
   that fails this check is exactly the kind of thing that must not be echoed
   into a log or a tool result. A CR or LF in a value is header injection; so is
   any other control character. *)
let prepare_headers (request : request) =
  let headers = request.headers in
  let count = List.length headers in
  let bytes =
    List.fold_left (fun acc (name, value) -> acc + String.length name + String.length value) 0 headers
  in
  if count > max_request_headers then
    Error
      (Error.make Error.Invalid
         ~message:(Printf.sprintf "a request carries at most %d headers" max_request_headers))
  else if bytes > max_request_header_bytes then
    Error
      (Error.make Error.Invalid
         ~message:
           (Printf.sprintf "the request headers are more than %d bytes in total"
              max_request_header_bytes))
  else
    let rec walk = function
      | [] -> Ok (Http.Header.of_list headers)
      | (name, value) :: rest ->
          if List.mem (String.lowercase_ascii name) authority_owned_headers then
            Error
              (Error.make Error.Invalid
                 ~message:
                   (Printf.sprintf
                      "%s is set by the authority, not by the caller: this grant fixes the Host \
                       header, the framing of the body, and one connection per request"
                      (Error.sanitize name)))
          else if
            not (String.for_all is_token_character name && header_value_is_valid value)
          then
            Error
              (Error.make Error.Invalid
                 ~message:
                   (Printf.sprintf
                      "the %s header is not a valid HTTP header: a name is token characters and \
                       a value carries no control characters"
                      (Error.sanitize name)))
          else walk rest
    in
    walk headers

let prepare_body (request : request) =
  match request.body with
  | None -> Ok None
  | Some body when String.length body > max_request_bytes ->
      Error
        (Error.make Error.Invalid
           ~message:
             (Printf.sprintf "a request body is at most %d bytes through this grant"
                max_request_bytes))
  | Some body -> Ok (Some (Cohttp_eio.Body.of_string body))

(* The URI the HTTP client is handed. Scheme, host and port are re-written from
   the decision the policy already made, so a URI that differs only in case, in
   a written-out default port, or in a trailing root dot still matches what was
   allowlisted and still produces the same [Host] header; path and query go
   through untouched, because that is the request the caller is making. The
   fragment is dropped: it is never sent over the wire. *)
let canonical_uri uri destination =
  let uri = Uri.with_scheme uri (Some (scheme_name destination.scheme)) in
  let uri = Uri.with_host uri (Some destination.host) in
  let uri = Uri.with_port uri (Some destination.port) in
  Uri.with_fragment uri None

(** {1 The socket, and the operation on it} *)

(* Every path to a socket: connect to the address [resolve] vetted — never the
   hostname, so there is no second lookup to race with — then wrap in TLS with
   the endpoint's own name. The connector cohttp is handed ignores the URI it is
   given, so the client cannot reach an address other than the one that passed
   the policy check. *)
(* What one checked connection is, for both schemes: a bidirectional flow the
   operation's switch can close. This is cohttp-eio's own [connection] shape, and
   both [Eio.Net]'s stream socket and [Tls_eio]'s wrapped flow coerce to it —
   the [Tls] tag a TLS flow adds is not part of what the HTTP client needs, so it
   is dropped here rather than leaking into [send]'s types.

   The row is closed rather than open, and written over [Eio.Resource.t] rather
   than as [Eio.Flow.two_way]: in a type {e declaration} eio's [two_way] alias
   cannot be applied to a row (its own row is bound by an [as] pattern), and a
   resource is contravariant in its tag row, so an open row there is rejected.
   Cohttp-eio spells the same type the same way. *)
type connection = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

(* Every path to a socket: connect to the address [resolve] vetted — never the
   hostname, so there is no second lookup to race with — then wrap in TLS with
   the endpoint's own name. The connector cohttp is handed ignores the URI it is
   given, so the client cannot reach an address other than the one that passed
   the policy check. *)
let open_connection (t : 'tag confinement) ~destination ~vetted sw : connection =
  let socket = Eio.Net.connect ~sw t.net (`Tcp (vetted, destination.port)) in
  match destination.scheme with
  | `Http -> (socket :> connection)
  | `Https -> (
      let config =
        match t.tls with
        | Some config -> config
        | None ->
            refuse
              (Error.make Error.Failed
                 ~message:"this grant was built without a usable TLS configuration")
      in
      (* The peer name is the endpoint's, so SNI and certificate hostname
         verification both speak for the name the operator allowlisted even
         though the socket is addressed by IP. Nothing here turns verification
         off; a name that does not match is a handshake failure, and [classify]
         reports it as one. *)
      match (destination.peer_name, destination.peer_ip) with
      | Some name, _ -> (Tls_eio.client_of_flow config ~host:name socket :> connection)
      | None, Some ip -> (Tls_eio.client_of_flow config ~ip socket :> connection)
      | None, None ->
          refuse
            (Error.make Error.Invalid
               ~message:
                 "an https endpoint needs a hostname or an address to verify the certificate \
                  against"))

(* The redirect rule (§5): never followed, and an off-list [Location] is a
   refusal rather than a hint. A relative [Location] names no other host, so it
   is the same destination and stays a plain 3xx the caller may follow with its
   own [request], where every check runs again. Because nothing is ever followed
   here, there is no hop chain to bound and no hop along which to leak the
   caller's authorization header. *)
let check_redirect (t : 'tag confinement) response =
  let status = Http.Status.to_int (Http.Response.status response) in
  if status < 300 || status >= 400 || status = 304 then Ok ()
  else
    match Http.Header.get (Http.Response.headers response) "location" with
    | None -> Ok ()
    | Some location -> (
        let target = Uri.of_string location in
        if Uri.scheme target = None then Ok ()
        else
          match decide_destination t target with
          | Ok _ -> Ok ()
          | Error _ ->
              (* Only the target's host is named: a [Location] can carry a query
                 string, and query strings never reach a log or a tool result
                 (§5). *)
              Error
                (Error.make Error.Denied
                   ~message:
                     (Printf.sprintf
                        "the endpoint answered %d with a redirect to a host this grant does not \
                         allow (%s); nothing was followed"
                        status (Error.sanitize (Uri.host_with_default ~default:"?" target)))))

(* The body of one request, inside the ceiling the operator and the caller
   agreed on. *)
let send (t : 'tag confinement) ~destination ?max_response_bytes request vetted =
  let ( let* ) = Result.bind in
  let limit =
    match max_response_bytes with
    | None -> t.max_response_bytes
    | Some requested -> min t.max_response_bytes requested
  in
  let* headers = prepare_headers request in
  let* body = prepare_body request in
  let uri = canonical_uri request.uri destination in
  (* One switch per operation, which is what closes the socket on every result
     path — the ceiling and the timeout both unwind out of this body (§5). *)
  Eio.Switch.run (fun sw ->
    let client =
      Cohttp_eio.Client.make_generic (fun ~sw:_ (_uri : Uri.t) ->
        open_connection t ~destination ~vetted sw)
    in
    let response, body_flow =
      Cohttp_eio.Client.call client ~sw ~headers ?body (request.meth :> Http.Method.t) uri
    in
    let status = Http.Status.to_int (Http.Response.status response) in
    let* () = check_redirect t response in
    (* The ceiling is enforced on the bytes actually read. [Content-Length] is
       trusted in neither direction: a server that lies about it, in either
       direction, meets the read limit rather than a comparison (§5). *)
    try
      let content = Eio.Buf_read.(take_all (of_flow body_flow ~max_size:(limit + 1))) in
      Ok ({ status; headers = Http.Header.to_list (Http.Response.headers response); body = content } : response)
    with Eio.Buf_read.Buffer_limit_exceeded ->
      Error
        (Error.make Error.Denied
           ~message:
             (Printf.sprintf
                "the response is larger than the %d-byte ceiling (max_response_bytes may lower \
                 it, never raise it); the body was not read"
                limit)))

let request ~controls ?max_response_bytes (T t) request =
  Controls.run controls ~operation:"net.request"
    ~measure:(fun response -> Some (String.length response.body))
    ~notes:(fun response -> [("status", string_of_int response.status)])
    (fun () ->
      let ( let* ) = Result.bind in
      let* destination = decide_destination t request.uri in
      let* vetted = resolve t destination in
      try send t ~destination ?max_response_bytes request vetted
      with Refusal error -> Error error | ex -> classify ex)

(** {1 Construction} *)

(* TLS needs a process-global RNG (tls-eio's own interface says so). This does
   not install one: an application that has configured an entropy source keeps
   it, and one that has not is told what to call rather than being handed a
   grant whose https path throws in production (§5, "fail construction
   loudly"). *)
let ensure_rng () =
  try (ignore (Mirage_crypto_rng.default_generator ()); Ok ()) with
  | Mirage_crypto_rng.No_default_generator ->
      Error
        (Error.make Error.Failed
           ~message:
             "https needs a random generator: the application must install one (for example \
              Mirage_crypto_rng_unix.use_default ()) before a network grant is built")

let tls_config () =
  let ( let* ) = Result.bind in
  let* () = ensure_rng () in
  match Ca_certs.authenticator () with
  | Error (`Msg message) ->
      Error
        (Error.make Error.Unavailable
           ~message:
             ("the system trust anchors could not be read (" ^ Error.sanitize message
             ^ "); ca-certs looks in the OS store, or at SSL_CERT_FILE when it is set"))
  | Ok authenticator -> (
      (* [~authenticator] is the trust anchor store and nothing else: no
         [accept_any] / no bypass. The validity instant is captured here, once,
         because grants are server-lifetime values (§1). *)
      match Tls.Config.client ~authenticator () with
      | Error (`Msg message) ->
          Error
            (Error.make Error.Failed
               ~message:("the TLS client configuration was rejected (" ^ Error.sanitize message ^ ")"))
      | Ok config -> Ok config)

let response_ceiling max_response_bytes =
  if max_response_bytes <= 0 then
    Error
      (Error.make Error.Invalid
         ~message:"max_response_bytes must be a positive count of bytes")
  else if max_response_bytes > max_configurable_response_bytes then
    Error
      (Error.make Error.Invalid
         ~message:
           (Printf.sprintf "max_response_bytes is at most %d bytes" max_configurable_response_bytes))
  else Ok max_response_bytes

(* [sw] is the switch the grant lives under, and v1 registers nothing on it:
   there is no connection pool and no resolver cache to give a server-lifetime
   home, and adding either is what would use it (§1, §5). Keeping the label
   anyway is what makes [with_endpoints] and [with_root] read the same way at a
   call site, which is the shape an audit is read in. *)
let with_endpoints ~sw:_ ~net ~max_response_bytes endpoints =
  let ( let* ) = Result.bind in
  let* max_response_bytes = response_ceiling max_response_bytes in
  let* allowed = normalise_endpoints endpoints in
  let wants_https = List.exists (fun entry -> entry.scheme = `Https) allowed in
  let* tls =
    if wants_https then tls_config () >>= (fun config -> Ok (Some config)) else Ok None
  in
  Ok (T { net; max_response_bytes; policy = Endpoints allowed; tls })

let with_public_web ~sw:_ ~net ~max_response_bytes () =
  let ( let* ) = Result.bind in
  let* max_response_bytes = response_ceiling max_response_bytes in
  tls_config () >>= (fun tls ->
    Ok (T { net; max_response_bytes; policy = Public_web; tls = Some tls }))
