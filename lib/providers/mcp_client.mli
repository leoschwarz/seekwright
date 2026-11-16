(** Narrow MCP client for Streamable HTTP providers (Exa and Parallel).

    Implements the minimal client needed for MCP-backed web search adapters:
    initialize, notifications/initialized, tools/call, and session close over
    discrete HTTP POST requests using the endpoint-scoped network grant.

    Framing supports JSON and SSE bodies with configurable limits. Fixed failure
    messages are used for safety. *)

type t

type tool_result = { text : string }
(** Text content returned by a successful tool call. *)

val create :
  ?protocol_version:string ->
  ?client_name:string ->
  ?client_version:string ->
  ?auth:string ->
  ?max_frame_bytes:int ->
  ?max_events:int ->
  provider:string ->
  net:Seekwright.Provider.Net.t ->
  uri:Uri.t ->
  unit ->
  t
(** Creates an unconnected client. [auth] is sent as a Bearer token when present. *)

val connect : t -> (unit, Seekwright.Provider.error) result
(** Performs the initialization handshake. Idempotent on active sessions. *)

val call_tool :
  t -> name:string -> arguments:Yojson.Safe.t -> (tool_result, Seekwright.Provider.error) result
(** Executes a tool call, establishing a session first if needed. Retries once
    on 404 (session expired). *)

val aclose : t -> unit
(** Closes the client, issuing a best-effort DELETE request to terminate the session. *)
