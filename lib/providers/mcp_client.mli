(** A narrow MCP client for the Exa and Parallel adapters.

    Port of the session half of [src/seekwright/providers/exa_mcp.py], and the
    smallest client the two MCP-backed providers need: one endpoint, one
    session, the three messages those adapters send ([initialize],
    [notifications/initialized], [tools/call]) and close.

    This is deliberately not a second generic MCP stack. [mcp-caps] is the
    capability layer over [mcp-kit] and stays the server's; a provider adapter
    is a client, and the two share no code path, no transport and no type. What
    this module owns is exactly the session half the provider contract needs.

    {2 Why discrete POSTs, not a duplex stream}

    Streamable HTTP carries each JSON-RPC message in its own POST, so the
    "session" a client owns is the server's [Mcp-Session-Id] value — a header
    held across requests — and not a socket held open. That is the shape the
    existing endpoint-scoped {!Seekwright.Provider.Net.t} grant already offers:
    one bounded request/response exchange per operation, with its own byte
    ceiling and its own whole-operation timeout. The live endpoints were probed
    before this module was written (plans/seekwright-ocaml-port.md, F4.2):
    Exa answers [text/event-stream] and Parallel [application/json], both assign
    a session id on [initialize], and both answer a bodyless [202] to the
    notification. No persistent stream is required, so the grant was not
    widened, and this module adds no socket and no second trust boundary.

    {2 Framing}

    A JSON body is one frame, bounded by [max_frame_bytes]. An SSE body
    is split into events on blank lines; the [data:] lines of one event are
    joined with a newline, and every other field ([event], [id], [retry],
    comments) is ignored. The number of events one POST may carry is bounded by
    [max_events], and a frame over the byte bound is refused rather than
    truncated. Both bounds are this module's own, over the grant's
    response ceiling, because the grant bounds the whole body while a single
    event is what gets parsed. A body that ends without its final blank line
    still dispatches: refusing a whole answer over a trailing newline would be
    a parser bug wearing a bound's clothes.

    {2 Failures}

    A failure is a {!Seekwright.Provider.error} carrying one sentence from a
    fixed vocabulary — [MCP handshake failed], [MCP handshake timed out],
    [MCP session unavailable], [malformed MCP response], [MCP response exceeded
    its frame bound], [upstream MCP request was rejected], [upstream MCP tool
    reported an error], [rate limited], [MCP client is closed] — or one of the
    provider contract's shared rows (authentication, HTTP status, timeout,
    network, quota). {b Nothing from an upstream body, header or exception
    reaches one of them}: the request those responses echo carries this
    deployment's credentials, so the text of an [isError] result is read once
    to classify it and never echoed.

    {2 Lifecycle}

    {!call_tool} handshakes on demand and {!connect} does it eagerly, so a
    caller that reuses a client never handshakes twice. A call answered [404]
    while it carried a session id is the specification's "this session is gone"
    signal, and is retried exactly once after a fresh handshake. Every other
    answer — a timeout, a malformed frame, an oversized frame, a valid provider
    error — is terminal for that call. {!aclose} marks the client closed and
    attempts the specification's best-effort [DELETE]; it never reports the
    endpoint's answer. *)

type t
(** One endpoint and its session. Not thread-safe in the sense of being usable
    across Eio domains: the session, the id counter and the closed flag are
    plain references, which is safe on the single domain a provider adapter
    runs on, and an id is assigned before any blocking exchange. A caller that
    fans calls out to several fibers hands them the client after one
    {!connect}: there is no lock, so two concurrent {i first} calls would each
    handshake. *)

type tool_result = { text : string }
(** What a successful tool call answered: the text blocks, joined with a
    newline the way Python's [ClientSession.call_tool] consumer joins them.
    Non-text blocks (images) are not part of either search backend's reply. *)

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
(** [create ~provider ~net ~uri ()] is an unconnected client. [provider] is the
    adapter name every failure names; [net] is the endpoint-scoped grant;
    [uri] is the one destination. [auth], when given, is sent as a [Bearer]
    token — Exa's keyed tiers use it, the anonymous ones do not.

    [protocol_version] defaults to [2025-06-18], the version the live probes
    negotiated. [max_frame_bytes] and [max_events] default to 262 144 and 64;
    both are clamped to at least 1, so a caller cannot make an unbounded read
    by passing zero. [client_name] and [client_version] are the protocol-visible
    identity ([seekwright], [0.1.0]); F9.1 owns the one package version. *)

val connect : t -> (unit, Seekwright.Provider.error) result
(** [connect t] performs the handshake and stores the session. [Ok ()] on a
    session that already exists — the notification is not re-sent. Any
    non-[200] answer to [initialize], a reply that is not an
    [initialize] result, a notification the server refuses, and a transport
    timeout each fail with the handshake vocabulary, and a refused handshake
    stores no session. *)

val call_tool :
  t -> name:string -> arguments:Yojson.Safe.t -> (tool_result, Seekwright.Provider.error) result
(** [call_tool t ~name ~arguments] handshakes if needed and sends one
    [tools/call]. [arguments] is the JSON object the tool's schema describes,
    sent verbatim.

    A [404] answering a call that carried a session id drops the session,
    handshakes again and retries the call {b once}; a second [404] is
    [MCP session unavailable]. An [isError] result is a provider failure, not a
    transport one: its text is classified by the oracle's rule (a mention of
    [rate], [quota] or [429] is the quota row; anything else is
    [upstream MCP tool reported an error]) and is never included in the
    message. A status of 401/403 is the authentication row, 402/429 the quota
    row, any other non-2xx the HTTP-status row. *)

val aclose : t -> unit
(** [aclose t] marks [t] closed, so any later {!call_tool} fails with
    [MCP client is closed], and sends the session-terminating [DELETE] when a
    session id exists. Best effort: the answer is discarded, and a client with
    no session sends nothing. Idempotent. *)
