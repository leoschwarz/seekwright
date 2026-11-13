(* The narrow MCP client Exa and Parallel need, ported from the session half of
   src/seekwright/providers/exa_mcp.py. It is deliberately not a generic MCP
   stack: one endpoint, one session, the three messages those adapters send
   (initialize, notifications/initialized, tools/call) and close.

   Streamable HTTP carries each JSON-RPC message in its own POST, so the
   "session" this client owns is the server's `Mcp-Session-Id` value, not a held
   socket. That is the shape the existing endpoint-scoped [Provider.Net.t] grant
   already offers — one bounded request/response exchange per operation — and it
   is why this module adds no socket, no duplex stream and no second trust
   boundary. See [plans/seekwright-ocaml-port.md]'s F4.2 section for the live
   evidence behind that decision. *)

module Caps = Mcp_caps
module Provider = Seekwright.Provider

let accept = "application/json, text/event-stream"
let jsonrpc_version = "2.0"

(* Bounds of this module's own, over the grant's [max_response_bytes]: one SSE
   event (or one JSON body) and the number of events a single POST may carry
   before it is refused rather than scanned. The default frame ceiling is the
   grant's own default body ceiling, so it never refuses a response the grant
   would have delivered whole. *)
let default_max_frame_bytes = 262_144
let default_max_events = 64

let default_protocol_version = "2025-06-18"
let default_client_name = "seekwright"
(* The protocol-visible client identity, not the package version: F9.1 owns the
   one version value that the image label and User-Agent share. *)
let default_client_version = "0.1.0"

(* The fixed vocabulary a failure may carry. Nothing from an upstream body, a
   header or an exception reaches one of these, which is what keeps a provider
   error safe to hand to a model. *)
let handshake_failed = "MCP handshake failed"
let handshake_timed_out = "MCP handshake timed out"
let session_unavailable = "MCP session unavailable"
let malformed_response = "malformed MCP response"
let oversized_response = "MCP response exceeded its frame bound"
let request_rejected = "upstream MCP request was rejected"
let tool_reported_error = "upstream MCP tool reported an error"
let rate_limited = "rate limited"
let closed_message = "MCP client is closed"

type session = {
  id : string option;
      (** Absent when the deployment answers statelessly: Parallel's real
          endpoint assigns one, but the specification makes it optional. *)
  protocol_version : string;  (** The negotiated version, sent on later calls. *)
}

type t = {
  net : Provider.Net.t;
  uri : Uri.t;
  provider : string;
  auth : string option;
  requested_protocol_version : string;
  client_name : string;
  client_version : string;
  max_frame_bytes : int;
  max_events : int;
  mutable session : session option;
  mutable next_id : int;
  mutable closed : bool;
}

type tool_result = { text : string }
(** What a successful tool call answered: the text blocks, joined with a newline
    the way Python's [ClientSession.call_tool] consumer joins them. Non-text
    blocks (images) are not part of either search backend's reply. *)

let create ?(protocol_version = default_protocol_version)
    ?(client_name = default_client_name)
    ?(client_version = default_client_version) ?auth ?(max_frame_bytes = default_max_frame_bytes)
    ?(max_events = default_max_events) ~provider ~net ~uri () =
  {
    net;
    uri;
    provider;
    auth;
    requested_protocol_version = protocol_version;
    client_name;
    client_version;
    max_frame_bytes = max 1 max_frame_bytes;
    max_events = max 1 max_events;
    session = None;
    next_id = 1;
    closed = false;
  }

(* JSON-RPC request ids are sequential and unique per client. The read and the
   write happen before any blocking exchange, so on the single Eio domain this
   library runs on they are one critical section: two fibers can call
   [call_tool] concurrently and still get distinct ids. *)
let next_id t =
  let id = t.next_id in
  t.next_id <- id + 1;
  id

let closed_error t = Provider.provider_error ~provider:t.provider closed_message

let header_value headers name =
  let wanted = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) -> if String.lowercase_ascii key = wanted then Some value else None)
    headers

let media_type headers =
  match header_value headers "content-type" with
  | None -> None
  | Some raw ->
      let base = match String.index_opt raw ';' with Some i -> String.sub raw 0 i | None -> raw in
      Some (String.lowercase_ascii (String.trim base))

(* A JSON-RPC message body. [params] is omitted for the notification whose
   specification shape has none. *)
let request_message ~id ~meth ~params =
  `Assoc
    [
      ("jsonrpc", `String jsonrpc_version);
      ("id", `Int id);
      ("method", `String meth);
      ("params", params);
    ]

let notification_message ~meth =
  `Assoc [ ("jsonrpc", `String jsonrpc_version); ("method", `String meth) ]

let headers t ?session () =
  let base =
    [ ("accept", accept); ("content-type", "application/json") ]
    @
    match t.auth with
    | Some key -> [ ("authorization", "Bearer " ^ key) ]
    | None -> []
  in
  match session with
  | None -> base
  | Some session ->
      let base = base @ [ ("MCP-Protocol-Version", session.protocol_version) ] in
      (match session.id with
      | Some id -> base @ [ ("Mcp-Session-Id", id) ]
      | None -> base)

let post t ~headers ~json =
  let request : Caps.Authority.Net.request =
    {
      meth = `POST;
      uri = t.uri;
      headers;
      body = Some (Yojson.Safe.to_string json);
    }
  in
  t.net.Provider.Net.request request

(* {2 Framing} *)

type parse_failure = Malformed | Oversized

(* The grammar in one place. A JSON body is one frame and is bounded by the same
   ceiling; an SSE body is split into events on blank lines, [data:] lines of one
   event are joined with a newline, and every other field ([event], [id],
   [retry], comments) is ignored. A body that ends without its final blank line
   still dispatches, because refusing a whole answer over a trailing newline
   would be a parser bug wearing a bound's clothes. *)
let sse_frames ~max_frame_bytes ~max_events body =
  let data = Buffer.create 256 in
  let frames = ref [] in
  let count = ref 0 in
  let oversized = ref false in
  let dispatch () =
    if Buffer.length data > 0 then begin
      if Buffer.length data > max_frame_bytes then oversized := true
      else begin
        frames := Buffer.contents data :: !frames;
        incr count
      end;
      Buffer.clear data
    end
  in
  List.iter
    (fun line ->
      let line =
        if String.ends_with ~suffix:"\r" line then String.sub line 0 (String.length line - 1)
        else line
      in
      if line = "" then dispatch ()
      else if String.starts_with ~prefix:":" line then ()
      else if String.starts_with ~prefix:"data:" line then begin
        let rest = String.sub line 5 (String.length line - 5) in
        let payload =
          (* The specification strips exactly one space after the colon. *)
          if String.starts_with ~prefix:" " rest then
            String.sub rest 1 (String.length rest - 1)
          else rest
        in
        if not !oversized then begin
          if Buffer.length data > 0 then Buffer.add_char data '\n';
          Buffer.add_string data payload;
          if Buffer.length data > max_frame_bytes then oversized := true
        end
      end
      else ())
    (String.split_on_char '\n' body);
  dispatch ();
  if !oversized || !count > max_events then Error Oversized
  else Ok (List.rev !frames)

(* The JSON-RPC object that answers [id], or the failure that says why there is
   none. A value without an [id] is a server notification — progress, logging —
   and a value with another id belongs to another call in flight; both are
   skipped rather than refused. *)
let reply_of ~id frames =
  let rec loop = function
    | [] -> None
    | json :: rest ->
        (match json with
        | `Assoc fields -> (
            match List.assoc_opt "id" fields with
            | Some (`Int answered) when answered = id -> (
                match List.assoc_opt "result" fields with
                | Some reply -> Some (`Result reply)
                | None ->
                    if List.mem_assoc "error" fields then Some `Rpc_error
                    else None)
            | _ -> loop rest)
        | _ -> loop rest)
  in
  loop frames

let read_reply t ~id response =
  let json =
    match media_type response.Caps.Authority.Net.headers with
    | None ->
        (* No content type: trust the shape. Both documented endpoints name one,
           so this is tolerance rather than a second grammar. *)
        let body = String.trim response.body in
        body <> "" && (body.[0] = '{' || body.[0] = '[')
    | Some "text/event-stream" -> false
    | Some _ -> true
  in
  let frames : (string list, parse_failure) result =
    if json then
      if String.length response.body > t.max_frame_bytes then Error Oversized
      else if String.trim response.body = "" then Error Malformed
      else Ok [ response.body ]
    else sse_frames ~max_frame_bytes:t.max_frame_bytes ~max_events:t.max_events response.body
  in
  let ( let* ) = Result.bind in
  let* raw = frames in
  let rec parse acc = function
    | [] -> Ok (List.rev acc)
    | raw :: rest -> (
        match Yojson.Safe.from_string raw with
        | json -> parse (json :: acc) rest
        | exception Yojson.Json_error _ -> Error Malformed)
  in
  let* values = parse [] raw in
  let values = List.concat_map (function `List items -> items | value -> [ value ]) values in
  match reply_of ~id values with
  | Some reply -> Ok reply
  | None -> Error Malformed

let contains_substring ~haystack ~needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec from i =
    if i + needle_length > haystack_length then false
    else if String.sub haystack i needle_length = needle then true
    else from (i + 1)
  in
  needle_length = 0 || from 0

let text_of_result result =
  match Provider.Json.field "content" result with
  | `List blocks ->
      blocks
      |> List.filter_map (fun block ->
             match (Provider.Json.string_field "type" block, Provider.Json.string_field "text" block) with
             | Some "text", Some text -> Some text
             | _ -> None)
      |> String.concat "\n"
  | _ -> ""

(* [isError] is a result, not a transport failure — Exa's real endpoint answers an
   invalid key that way — so it is classified here, where the third-party text is
   read once and never echoed: the oracle's rule is the same three words plus
   [429] for the quota row and one fixed sentence for everything else. *)
let tool_result t result =
  if Provider.Json.is_true_field "isError" result then begin
    let text = String.lowercase_ascii (text_of_result result) in
    if
      contains_substring ~haystack:text ~needle:"rate"
      || contains_substring ~haystack:text ~needle:"quota"
      || contains_substring ~haystack:text ~needle:"429"
    then Error (Provider.quota_exhausted ~provider:t.provider ~message:rate_limited ())
    else Error (Provider.provider_error ~provider:t.provider tool_reported_error)
  end
  else Ok { text = text_of_result result }

let status_error t status =
  if status = 401 || status = 403 then Provider.auth_error ~provider:t.provider
  else if status = 402 || status = 429 then
    Provider.quota_exhausted ~provider:t.provider ()
  else Provider.http_status_error ~provider:t.provider status

let is_success status = status >= 200 && status < 300

(* The handshake has its own sentence for a timeout, exactly as the oracle does:
   "MCP handshake timed out" is the one fact a caller can act on, and the grant's
   own message (which may name the peer) never rides along. *)
let handshake_error t ~timed_out =
  if timed_out then Provider.provider_error ~provider:t.provider handshake_timed_out
  else Provider.provider_error ~provider:t.provider handshake_failed

let connect t =
  if t.closed then Error (closed_error t)
  else
    match t.session with
    | Some _ -> Ok ()
    | None ->
        let id = next_id t in
        let params =
          `Assoc
            [
              ("protocolVersion", `String t.requested_protocol_version);
              ("capabilities", `Assoc []);
              ( "clientInfo",
                `Assoc
                  [
                    ("name", `String t.client_name);
                    ("version", `String t.client_version);
                  ] );
            ]
        in
        let message = request_message ~id ~meth:"initialize" ~params in
        (match post t ~headers:(headers t ()) ~json:message with
        | Error failure ->
            Error (handshake_error t ~timed_out:(Caps.Error.kind failure = Caps.Error.Timeout))
        | Ok response ->
            if response.status <> 200 then Error (handshake_error t ~timed_out:false)
            else
              (match read_reply t ~id response with
              | Error _ | Ok `Rpc_error -> Error (handshake_error t ~timed_out:false)
              | Ok (`Result result) ->
                  let negotiated =
                    match Provider.Json.string_field "protocolVersion" result with
                    | Some version when version <> "" -> version
                    | _ -> t.requested_protocol_version
                  in
                  let session_id =
                    match header_value response.headers "mcp-session-id" with
                    | Some id when String.trim id <> "" -> Some (String.trim id)
                    | _ -> None
                  in
                  let session = { id = session_id; protocol_version = negotiated } in
                  (* The notification is the second half of the handshake: a
                     server that refuses it has not opened the session, so the
                     id is not stored. *)
                  match
                    post t ~headers:(headers t ~session ())
                      ~json:(notification_message ~meth:"notifications/initialized")
                  with
                  | Error failure ->
                      Error
                        (handshake_error t
                           ~timed_out:(Caps.Error.kind failure = Caps.Error.Timeout))
                  | Ok acknowledgement ->
                      if is_success acknowledgement.status then begin
                        t.session <- Some session;
                        Ok ()
                      end
                      else Error (handshake_error t ~timed_out:false)))

let ensure_session t = match t.session with Some _ -> Ok () | None -> connect t

type call_failure = Failed of Provider.error | Dead_session

(* One attempt. A call that carries a session id and is answered [404] is the
   specification's "this session is gone" signal; everything else that is not a
   well-formed tool result is a provider answer and is terminal. *)
let call_once t ~name ~arguments =
  match ensure_session t with
  | Error error -> Error (Failed error)
  | Ok () ->
      let id = next_id t in
      let params =
        `Assoc [ ("name", `String name); ("arguments", arguments) ]
      in
      let message = request_message ~id ~meth:"tools/call" ~params in
      let carries_session =
        match t.session with Some { id = Some _; _ } -> true | _ -> false
      in
      (match post t ~headers:(headers t ?session:t.session ()) ~json:message with
      | Error failure ->
          if Caps.Error.kind failure = Caps.Error.Timeout then
            Error (Failed (Provider.timeout_error ~provider:t.provider))
          else Error (Failed (Provider.network_error ~provider:t.provider))
      | Ok response ->
          if carries_session && response.status = 404 then Error Dead_session
          else if not (is_success response.status) then Error (Failed (status_error t response.status))
          else
            match read_reply t ~id response with
            | Error Oversized ->
                Error (Failed (Provider.provider_error ~provider:t.provider oversized_response))
            | Error Malformed ->
                Error (Failed (Provider.provider_error ~provider:t.provider malformed_response))
            | Ok `Rpc_error ->
                Error (Failed (Provider.provider_error ~provider:t.provider request_rejected))
            | Ok (`Result result) -> (
                match tool_result t result with
                | Ok result -> Ok result
                | Error error -> Error (Failed error)))

let call_tool t ~name ~arguments =
  if t.closed then Error (closed_error t)
  else
    match call_once t ~name ~arguments with
    | Ok result -> Ok result
    | Error (Failed error) -> Error error
    | Error Dead_session ->
        (* One reconnect, once per call: the oracle retries a dead long-lived
           session exactly once and reports "MCP session unavailable" if the
           second attempt is dead too. *)
        t.session <- None;
        (match connect t with
        | Error error -> Error error
        | Ok () -> (
            match call_once t ~name ~arguments with
            | Ok result -> Ok result
            | Error (Failed error) -> Error error
            | Error Dead_session ->
                Error (Provider.provider_error ~provider:t.provider session_unavailable)))

let aclose t =
  if not t.closed then begin
    t.closed <- true;
    (* The specification lets a client terminate its session with DELETE, and a
       server that does not support that answers 405. Best effort by design: a
       close that reported the endpoint's answer would put a network failure on
       a path whose caller is already shutting down. *)
    (match t.session with
    | Some ({ id = Some _; _ } as session) -> (
        let request : Caps.Authority.Net.request =
          { meth = `DELETE; uri = t.uri; headers = headers t ~session (); body = None }
        in
        match t.net.Provider.Net.request request with _ -> ())
    | _ -> ());
    t.session <- None
  end
