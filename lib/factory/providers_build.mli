(** The provider build pass, and the two records the construction layer reports in. The records live
    here rather than in [Factory] because [Providers_build] fills them and [Verdict] reads one, and
    [Factory]'s signature is derived from this one by [include module type of] — which needs this
    module to stay nameable, out of [dune]'s [private_modules]. The equation that keeps the field
    labels usable through [Factory] is load-bearing, not stylistic:
    [plans/factory-split-proposal.md] §2.2 records the probe. *)

type providers = {
  built : (Seekwright.Config.name * Seekwright.Provider.t) list;
      (** The adapters this deployment can dispatch, in config order. A name whose registry row
          defers its adapter to a later wave is absent — and is listed in [unsupported] rather than
          silently dropped. A name whose row can build but whose key or instance the config never
          supplied is absent and not reported here: [Config.missing_api_keys] is the path that names
          it. *)
  probe_table : (Seekwright.Config.name * Seekwright.Health.probe_spec) list;
      (** The [--check] probe rows for the built names, taken from each name's registry row — the
          same row that said which endpoint its grant got. *)
  endpoints : Mcp_caps.Policy.endpoint list;
      (** The union of the built adapters' endpoints: the allowlist one shared [--check] grant is
          built over. *)
  grant_errors : (Seekwright.Config.name * string) list;
      (** Names whose grant could not be constructed (a missing trust store, say). [--check] reports
          them as problems; {!App.build_app} refuses to start. *)
  unsupported : Seekwright.Config.name list;
      (** Enabled names this build has no adapter for, sorted. These are a startup failure under
          {!Verdict.startup_verdict} — a served process must never hold a config name with no
          adapter behind it — and under an implicit keyless default they are the skipped keyless
          names, which the startup line names through [startup.providers_unsupported]. *)
  warmups : (Seekwright.Config.name * (unit -> bool)) list;
      (** The session-carrying built names — the MCP-backed ones — with the operation that opens
          each adapter's own session before its first search pays for the handshake ([true] when it
          opened). A name with no entry here owns no session, so the startup path skips it. Built in
          config order, like [built]. *)
}
(** What one pass of {!build_providers} produced. *)

type set_report = {
  enabled : Seekwright.Config.name list;
      (** The names the config enables, sorted — what the file {i asks} for. *)
  effective : Seekwright.Config.name list;
      (** Enabled ∩ permitted — what the permission set {i allows}. *)
  built : Seekwright.Config.name list;
      (** The names this process can dispatch, sorted — what the build {i has}. Routing chooses only
          from this set. *)
  unsupported : Seekwright.Config.name list;
      (** Enabled with no adapter, from an explicitly enabled set: startup-fatal. Empty under an
          implicit keyless default, where the same fact is [skipped]. *)
  skipped : Seekwright.Config.name list;
      (** The implicit keyless defaults this build has no adapter for: skipped, logged by name at
          startup, and out of every routing set. *)
  untested : Seekwright.Config.name list;
      (** Enabled names with no live verification on this build: a disclosure, never a readiness
          verdict. *)
}

val build_providers :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  now:(unit -> float) ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  ?log:Seekwright.Log.log ->
  Seekwright.Config.t ->
  providers
(** Instantiate every enabled provider that has the credentials and the adapter this build carries:
    one pass over the registry rows, where a row answers the endpoint, the bound, the price, the
    credential and the probe, and this function answers only whether the name is enabled, built on
    this port, and supplied with what its row requires.

    [?audit] is the sink each built adapter's grant is wrapped with; {!App.build_app} supplies it,
    and [--check] does not, because a probe of a deployment is not a served request. *)
