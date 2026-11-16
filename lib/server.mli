(** The MCP server: three tools, both transports, and the HTTP custom routes.

    The three tools — [search], [fetch] and [answer] — are declared here through the capability
    layer's {!Mcp_caps.Registry} and served by mcp-kit over stdio ([Mcp_kit_stdio.run_channels]) or
    Streamable HTTP ([Mcp_kit_cohttp_eio.handler], mounted at [/mcp] by {!serve_http}).

    {1 The HTTP custom routes}

    One listener serves [/mcp] plus the custom routes, routed by path in {!serve_http}:
    [GET /healthz], dashboard routes ([GET /dashboard], [GET /dashboard/data],
    [GET /dashboard/metrics]) and the REST projection ([POST /api/v1/search], [POST /api/v1/fetch],
    [POST /api/v1/answer]). Everything but [/healthz] sits behind the same Host allowlist as [/mcp]
    ({!is_host_allowed}).

    {1 Concurrent sessions}

    Every request is served on its own Eio fiber:
    - {b Streamable HTTP} is stateless per POST.
    - {b stdio} is one session and one line stream, serialised by construction.

    {1 Error prose}

    The REST routes answer [{error: message}] with 400 for a refusal, 502 for an upstream failure,
    404 for an operation this deployment does not serve, 421 for a refused Host. Over MCP errors
    travel through {!Mcp_caps.Error}. *)

(** {1 The health monitor} *)

type health = {
  board : Health.t;
  built : Config.name list;
  probes : (Config.name * Health.probe_spec) list;
  net : Provider.Net.t;
}
(** What one monitor tick reads: the board the engines record on, the names this build can dispatch,
    their probe rows, and the network seam the probes dial through. *)

val run_health_monitor : health -> config:Config.t -> sleep:(unit -> unit) -> unit
(** Probe forever: [sleep], one {!Health.run_probes} tick, repeat. *)

type app = {
  config : Config.t;
  search : Engine.Search.t;
  usage : Usage.t;
  fetch : Engine.Fetch.t option;
      (** [None] whenever [[fetch] enabled = false]: the tool stays registered and refuses cleanly.
      *)
  agent : Agent.t option;  (** [None] whenever [[agent] enabled = false], the default. *)
  started_at : float;  (** Monotonic seconds when the app was built, for [/healthz]'s [uptime_s]. *)
  mono_now : unit -> float;
  allowed_hosts : string list;
      (** The operator's [--allowed-host] entries; loopback is always allowed. *)
  health : health option;  (** [None] when the app was assembled without a board to tick. *)
}
(** The process-wide context: one per server, shared by every tool call and custom route. *)

val fetch_disabled : string
(** The sentence returned when [[fetch] enabled = false]. *)

val agent_disabled : string
(** The sentence returned when [[agent] enabled = false]. *)

(** {1 The three tools} *)

val search_tool : (app, Model.search_request) Mcp_caps.Tool.t
val fetch_tool : (app, Model.fetch_request) Mcp_caps.Tool.t
val answer_tool : (app, Model.answer_request) Mcp_caps.Tool.t

val registry : app -> (Mcp_caps.Registry.t, Mcp_caps.Registry.add_error) result
(** The three tools, one [Registry.add] per line, each closed over the app. *)

val mcp_server : app -> (Mcp_kit.Server.t, Mcp_caps.Server.build_error) result
(** [Server.of_registry ~name:"seekwright"] over {!registry}. *)

(** {1 The HTTP custom routes} *)

type response = { status : int; headers : (string * string) list; body : string }
(** One HTTP answer from a custom route, before it is written to the socket. *)

val host_allowlist : string list -> string list
(** The Host entries the listener accepts: loopback seed widened with the operator's
    [--allowed-host] entries. *)

val is_host_allowed : string list -> string -> bool
(** Whether a [Host] header value (port included) is in the allowlist. *)

val origin_allowlist : string list -> string list
(** The Origin values the custom routes accept: [http(s)://host] for every loopback name and every
    operator host. *)

val handle_custom :
  ?stopping:(unit -> bool) ->
  app ->
  meth:string ->
  path:string ->
  host:string option ->
  origin:string option ->
  body:string ->
  response
(** Route one custom-route request. [/healthz] is exempt from the Host allowlist. Unknown paths
    answer 404; a known path with the wrong method answers 405. When [stopping] is true, returns 503
    on service endpoints. *)

(** {1 Serving} *)

val max_body_size : int
(** The request-body bound. *)

val request_head_timeout_seconds : float
(** How long a connection may take to deliver a complete request head. *)

val serve_connection :
  ?stopping:(unit -> bool) ->
  clock:_ Eio.Time.Mono.t ->
  log:Log.log ->
  app:app ->
  server:Mcp_kit.Server.t ->
  flow:_ Eio.Flow.two_way ->
  peer:Eio.Net.Sockaddr.stream ->
  unit ->
  unit
(** Drive one accepted connection: read the request head, answer bounded refusals for
    malformed/over-limit heads, and otherwise dispatch to mcp-kit for [/mcp] or {!handle_custom} for
    custom routes. *)

type serve_error =
  | Bind_address_unresolved  (** The bind address could not be parsed or resolved. *)
  | Listener_unavailable
      (** The socket could not be opened, or the listener stopped with an error. *)

val drain_grace_seconds : float
(** How long a stopped listener lets accepted connections finish before cancelling. *)

type lifecycle =
  | Drained  (** The stop was observed and accepted connections finished cleanly. *)
  | Grace_expired  (** The grace expired with work in flight; connections were cancelled. *)

val serve_http :
  env:< net : _ Eio.Net.t ; fs : _ Eio.Path.t ; mono_clock : _ Eio.Time.Mono.t ; .. > ->
  sw:Eio.Switch.t ->
  log:Log.log ->
  app ->
  Mcp_kit.Server.t ->
  host:string ->
  port:int ->
  stop:unit Eio.Promise.t ->
  ?grace_seconds:float ->
  unit ->
  (lifecycle, serve_error) result
(** Serve Streamable HTTP on [host]:[port]. *)

(** {1 Surface data} *)

val tools_surface : (string * string list) list
val rest_routes : (string * string * string * string list) list
val operational_routes : (string * string) list
val cli_verbs : string list
val server_flags : string list

type flag_arity = Boolean | Value

type server_flag = { name : string; arity : flag_arity; repeats : bool; key : string }

val server_flag_table : server_flag list
val flag_spec : string -> server_flag option

val headers_of_lines : string list -> Http.Header.t
val http_text_response : int -> string -> string

val journal_fields : (string * string list) list
