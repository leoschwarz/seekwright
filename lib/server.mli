(** The MCP server: three tools, both transports, and the HTTP custom routes.

    Port of [src/seekwright/server.py]. The three tools — [search], [fetch] and
    [answer] — are declared here through the capability layer's
    {!Mcp_caps.Registry} and served by mcp-kit over stdio
    ([Mcp_kit_stdio.run_channels]) or Streamable HTTP
    ([Mcp_kit_cohttp_eio.handler], mounted at [/mcp] by {!serve_http}).
    Providers never become MCP tools: each adapter receives its own
    endpoint-scoped [Net] grant when the factory builds it, and the tool's
    grant is the {!app} value that carries the engines holding those grants —
    so the one [Registry.add] line per tool names the power it runs with.

    {1 The HTTP custom routes}

    One listener serves [/mcp] plus the custom routes, routed by path in
    {!serve_http}: [GET /healthz] (outside the Host allowlist, secret-free:
    the providers this build can dispatch and uptime only — a configured name
    with no adapter is not listed, and the startup warning names it), the
    dashboard routes ([GET /dashboard],
    [GET /dashboard/data], [GET /dashboard/metrics], registered only when
    [[dashboard] enabled = true]) and the REST projection
    ([POST /api/v1/search], [POST /api/v1/fetch], [POST /api/v1/answer]) —
    the last two answered 404 while [[fetch] enabled = false] and
    [[agent] enabled = false] respectively. Everything but [/healthz] sits
    behind the same Host allowlist as [/mcp] ({!is_host_allowed}); the
    allowlist is applied in the surrounding route because mcp-kit 0.2.0's
    adapter owns Origin but not Host
    (plans/capability-gated-mcp-server.md §7). {!handle_custom} is the
    testable core of those routes: a pure function from method, path, headers
    and body to {!response}, which {!serve_http} adapts onto cohttp.

    {1 Error prose}

    The REST routes answer the exact sentences the Python tree carries:
    [{error: message}] with 400 for a refusal (nothing billed), 502 for an
    upstream failure, 404 for an operation this deployment does not serve,
    421 for a refused Host. Over MCP the same sentences travel through
    {!Mcp_caps.Error}, whose [render] prefixes the stable kind — the layer's
    error channel, not Python's bare [ToolError] text. *)

(** {1 The health monitor} *)

type health = {
  board : Health.t;
  built : Config.name list;
  probes : (Config.name * Health.probe_spec) list;
  net : Provider.Net.t;
}
(** What one monitor tick reads: the board the engines record on, the names this
    build can dispatch, their probe rows, and the network seam the probes dial
    through. Built by the factory beside the app so the monitor and the search
    engine share one board. *)

val run_health_monitor :
  health -> config:Config.t -> sleep:(unit -> unit) -> unit
(** Probe forever: [sleep], one {!Health.run_probes} tick, repeat. The sleep is
    the caller's because the interval comes from config and the clock belongs
    to the transport; [serve_http] hands in the listener's monotonic clock.
    Python sleeps first, so a start does not spend a probe before the first
    interval. The fiber is a child of the listener's switch, and cancelling
    that switch — how the process ends — is the stop. *)

(** The process-wide context: one per server, built once by the factory (P8's
    [seekwright.factory]) and shared by every tool call and custom route.
    Grants are server-lifetime values, so the [Eio.Switch.t] that built them
    encloses the transport loop. *)
type app = {
  config : Config.t;
  search : Engine.Search.t;
  usage : Usage.t;
  fetch : Engine.Fetch.t option;
  (** [None] whenever [[fetch] enabled = false]: the tool stays registered and
      refuses cleanly. *)
  agent : Agent.t option;
  (** [None] whenever [[agent] enabled = false], the default. *)
  started_at : float;
  (** Monotonic seconds when the app was built, for [/healthz]'s [uptime_s]. *)
  mono_now : unit -> float;
  allowed_hosts : string list;
  (** The operator's [--allowed-host] entries; loopback is always allowed. *)
  health : health option;
  (** [None] when the app was assembled without a board to tick — the route and
      tool suites build their own engines — and [Some] from
      {!Seekwright_factory.Factory.build_app}, which shares the engine's board. *)
}

val fetch_disabled : string
(** The one sentence both encodings give when [[fetch] enabled = false]. *)

val agent_disabled : string
(** The one sentence both encodings give when [[agent] enabled = false]. *)

(** {1 The three tools} *)

val search_tool : (app, Model.search_request) Mcp_caps.Tool.t
val fetch_tool : (app, Model.fetch_request) Mcp_caps.Tool.t
val answer_tool : (app, Model.answer_request) Mcp_caps.Tool.t

val registry : app -> (Mcp_caps.Registry.t, Mcp_caps.Registry.add_error) result
(** The three tools, one [Registry.add] per line, each closed over the app. *)

val mcp_server : app -> (Mcp_kit.Server.t, Mcp_caps.Server.build_error) result
(** [Server.of_registry ~name:"seekwright"] over {!registry}. *)

(** {1 The HTTP custom routes} *)

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}
(** One HTTP answer from a custom route, before it is written to the socket. *)

val host_allowlist : string list -> string list
(** The Host entries the listener accepts: the loopback seed (bare names and
    [:*] patterns) widened with the operator's [--allowed-host] entries —
    widening, never narrowing, because the seed is the DNS-rebinding
    protection. *)

val is_host_allowed : string list -> string -> bool
(** Whether a [Host] header value (port included) is in the allowlist: an
    exact entry, or a [name:*] entry matching any port. *)

val origin_allowlist : string list -> string list
(** The Origin values the custom routes accept: [http(s)://host] for every
    loopback name and every operator host. *)

val handle_custom :
  app ->
  meth:string ->
  path:string ->
  host:string option ->
  origin:string option ->
  body:string ->
  response
(** Route one custom-route request. [/healthz] is exempt from the Host
    allowlist (a kubelet probes with the pod IP in [Host]); every other path
    is guarded, and an [Origin] header that is present but not allowed is
    refused. Unknown paths answer 404; a known path with the wrong method
    answers 405. *)

(** {1 Serving} *)

val max_body_size : int
(** The request-body bound, pinned so an upstream default change is a visible
    diff (the mcp-kit adapter's own default is 1 MiB). *)

val serve_http :
  env:< net : _ Eio.Net.t; fs : _ Eio.Path.t; mono_clock : _ Eio.Time.Mono.t; .. > ->
  sw:Eio.Switch.t ->
  app ->
  Mcp_kit.Server.t ->
  host:string ->
  port:int ->
  unit
(** Serve Streamable HTTP on [host]:[port]: [/mcp] is delegated to the mcp-kit
    adapter's handler (which owns body bound, routing headers and Origin), and
    every other path goes through {!handle_custom} under the same Host
    allowlist. [app.health] runs as a fiber on the same switch — so a cancelled
    listener takes its monitor with it — when
    [[search] health_interval_seconds] is positive. Runs until the enclosing
    switch ends; the listener is registered on [sw], which owns the grants. *)

(** {1 The frozen surface, as data}

    Read by [ocaml-tools/surface.ml], which prints the manifest
    [tools/surface.py] prints from the Python tree; the two must diff clean.
    Each list is the single source the corresponding declaration is built
    from, so a drift here is a drift in the wire. *)

val tools_surface : (string * string list) list
(** [(tool name, parameter names in declaration order)], sorted by name. *)

val rest_routes : (string * string * string * string list) list
(** [(method, path, request model, sorted body keys)] for the three
    [/api/v1/…] routes, sorted by (method, path). *)

val operational_routes : (string * string) list
(** [(method, path)] for the four routes outside the projection, sorted. *)

val cli_verbs : string list
(** The three client verbs, sorted: ["answer"; "fetch"; "search"]. *)

val server_flags : string list
(** The ten server flags, in the order the CLI declares them. *)

val journal_fields : (string * string list) list
(** The usage-journal field sets per line kind ([search], [fetch], [answer]),
    sorted, as [Usage] writes them. Printed by [ocaml-tools/surface.ml] and
    pinned against a real journal by [test/test_p8_surface.ml], so a field
    renamed in [usage.ml] fails a test. *)
