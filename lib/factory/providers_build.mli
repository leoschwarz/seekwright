(** The provider build pass: loops over registry rows to instantiate enabled adapters. *)

type adapter = { endpoint : Mcp_caps.Policy.endpoint; uri : Uri.t; timeout_seconds : float }
(** A row and this deployment's config answer the two questions the builder asks before it can build
    a grant: which endpoint the name's grant may reach, and the least time the name gets. Pairing
    them is what keeps every grant construction site naming one endpoint and one bound from one
    source. *)

val adapter_of_row :
  policy_seconds:float ->
  Registry.row ->
  Seekwright.Config.provider_config ->
  (adapter, string) result
(** [adapter_of_row ~policy_seconds row pc] resolves the row's endpoint and its destination
    together, and fails with the row's own sentence when either cannot be resolved — a [searxng]
    with no url, say. *)

val build_providers :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  now:(unit -> float) ->
  ?audit:(Mcp_caps.Event.t -> unit) ->
  ?log:Seekwright.Log.log ->
  Seekwright.Config.t ->
  Provider_set.providers
(** Instantiate every enabled provider that has the credentials and the adapter this build carries.
    The full contract, including what a name without an adapter and a name without a key each mean,
    is on [Factory.build_providers] in [factory.mli]. *)
