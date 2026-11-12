(** Provider, extractor and fetcher construction from config and environment.

    Port of [src/seekwright/factory.py]. Kept out of the server module so the
    CLI diagnostic path ([--check], [--metrics]) can build providers — and
    report the extraction backend — without constructing the MCP server: the
    check path in [bin/main.ml] never calls [Server.registry] or a transport,
    and nothing here names mcp-kit at all, only the capability layer's grants.

    Each adapter is built with its own endpoint-scoped [Net] grant
    ([Policy.with_endpoints] over the adapter's single
    {!Mcp_caps.Policy.endpoint}), so a provider can dial only the vendor it
    was built for; [fetch]'s local reader gets the public-web grant
    ([Policy.with_public_web]). The grant sets are derived from enabled
    provider names — there is no second egress config key. *)

(** What one pass of {!build_providers} produced. *)
type providers = {
  built : (Seekwright.Config.name * Seekwright.Provider.t) list;
  (** The adapters this deployment can dispatch, in config order. A name with
      no adapter in this build (the MCP-backed and keyed adapters deferred past
      P4) is absent — and is listed in [unsupported] rather than silently
      dropped; Python raises for a missing key and never skips. *)
  probe_table : (Seekwright.Config.name * Seekwright.Health.probe_spec) list;
  (** The [--check] probe rows for the built names, built from the adapters'
      own endpoint constants. *)
  endpoints : Mcp_caps.Policy.endpoint list;
  (** The union of the built adapters' endpoints: the allowlist one shared
      [--check] grant is built over. *)
  grant_errors : (Seekwright.Config.name * string) list;
  (** Names whose grant could not be constructed (a missing trust store, say).
      [--check] reports them as problems; {!build_app} refuses to start. *)
  unsupported : Seekwright.Config.name list;
  (** Enabled names this build has no adapter for, in config order. The startup
      line binds them and emits [startup.providers_unsupported], so the silence
      that used to make a config name look served is gone. *)
}

val build_providers :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  now:(unit -> float) ->
  Seekwright.Config.t ->
  providers
(** Instantiate every enabled provider that has the credentials and the
    adapter this build carries. *)

val probe_net :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  Mcp_caps.Policy.endpoint list ->
  Seekwright.Provider.Net.t
(** The shared network seam for the readiness probes: one grant over the union
    of the given endpoints. An empty list answers [Unavailable] to every
    request rather than building a grant that allows nothing. [--check] and the
    serving path's health monitor both read it, so the two probes dial under
    the same policy. *)

val build_extractor : Seekwright.Config.t -> (Seekwright_fetch.Extractor.backend, string) result
(** Instantiate the extraction backend [[fetch] extractor] names. [stdlib] is
    the one this build carries; the name is validated at config load, so an
    unknown one here means a config built around validation. *)

val build_fetch_stack :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  Seekwright.Config.t ->
  ((Seekwright.Engine.Fetch.fetcher * Seekwright.Engine.Fetch.fetcher list), string) result option
(** [None] when [[fetch] enabled = false]. Otherwise the local reader as the
    primary route (behind the public-web grant) plus the fallback ladder —
    empty in v1, where the third-party fallbacks are deferred with P6 — adapted
    to the engine's [fetcher] record. The keyed/self-hosted fallbacks are not
    built: nothing that could bill is left around unfired. *)

val readers : Seekwright.Engine.Fetch.Readers.t
(** The document readers the fetch engine selects with: [jsondoc]'s path
    grammar, schema rendering and path selection, and the shared passage
    selection. *)

val build_app :
  sw:Eio.Switch.t ->
  env:< net : [> [> `Generic ] Eio.Net.ty] Eio.Resource.t;
    fs : Eio.Fs.dir_ty Eio.Path.t;
    mono_clock : [> Eio.Time.Mono.ty] Eio.Resource.t;
    .. > ->
  now:(unit -> float) ->
  log:Seekwright.Engine.log ->
  allowed_hosts:string list ->
  Seekwright.Config.t ->
  (Seekwright.Server.app * providers, string) result
(** Build the process-wide {!Seekwright.Server.app}: the usage recorder (a bad
    [dashboard.history_path] is a config problem and reads as one), the shared
    health board, the search engine over the built providers, the fetch engine
    when enabled, and the agent engine when enabled (its model endpoint gets
    its own endpoint-scoped grant over [[agent] base_url]). The {!providers}
    pass travels back with the app so the startup line can bind the names this
    build could not dispatch. *)
