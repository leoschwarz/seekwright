(** The provider build pass: the loop over the registry's rows that turns an
    enabled name into a dispatchable adapter, and the report of what that pass
    produced.

    Private to [Seekwright_factory]: [Factory] re-exports only {!build_providers}.
    The two helpers here exist to keep the loop honest — {!adapter} pairs the
    endpoint and the bound a row resolved so every grant construction site names
    one of each from one source, and {!adapter_of_row} is the single place that
    pair is read. *)

(** A row and this deployment's config answer the two questions the builder asks
    before it can build a grant: which endpoint the name's grant may reach, and
    the least time the name gets. Pairing them is what keeps every grant
    construction site naming one endpoint and one bound from one source. *)
type adapter = {
  endpoint : Mcp_caps.Policy.endpoint;
  uri : Uri.t;
  timeout_seconds : float;
}

(** [adapter_of_row ~policy_seconds row pc] resolves the row's endpoint and its
    destination together, and fails with the row's own sentence when either
    cannot be resolved — a [searxng] with no url, say. *)
val adapter_of_row :
  policy_seconds:float ->
  Registry.row ->
  Seekwright.Config.provider_config ->
  (adapter, string) result

(** Instantiate every enabled provider that has the credentials and the adapter
    this build carries. The full contract, including what a name without an
    adapter and a name without a key each mean, is on [Factory.build_providers]
    in [factory.mli]. *)
val build_providers :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  now:(unit -> float) ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  ?log:Seekwright.Log.log ->
  Seekwright.Config.t ->
  Provider_set.providers
