(* The provider build pass: one loop over the registry's rows that answers, for
   every enabled name, whether this build can dispatch it and what it takes to
   do so. Port of [src/seekwright/factory.py]'s build_providers.

   Each decision a row cannot make is here — enabled on this deployment, built on
   this port, supplied with what its row requires — and each decision a row can
   make is read from the row, which is what keeps a new name a data change. The
   report is [Provider_set.providers]; the grant every built adapter runs on
   comes from [Grants], never from here. *)

module Config = Seekwright.Config
module Policy = Mcp_caps.Policy
module Provider = Seekwright.Provider

(* The records this pass reports in are [Provider_set]'s; opening it is what
   lets the record literal keep its bare field labels. *)
open Provider_set

(* [grant_of_endpoint] is the only grant construction this pass performs, and it
   is [Grants]': a module that could build a grant itself is a module that could
   build one without the audit trail. *)
let grant_of_endpoint = Grants.grant_of_endpoint


(* A row and this deployment's config answer the two questions the builder asks
   before it can build a grant: which endpoint the name's grant may reach, and the
   least time the name gets. Pairing them is what keeps every grant construction
   site naming one endpoint and one bound from one source. *)
type adapter = {
  endpoint : Policy.endpoint;
  uri : Uri.t;
  timeout_seconds : float;
}

let adapter_of_row ~policy_seconds (row : Registry.row) (pc : Config.provider_config) =
  match (Registry.grant_endpoint row pc, Registry.uri row pc) with
  | Ok endpoint, Ok uri ->
      Ok { endpoint; uri; timeout_seconds = Registry.timeout_seconds row ~policy_seconds }
  | (Error message, _) | (_, Error message) -> Error message

(* Building a name is the row's job: what it costs, what it needs, the least time
   it gets, the endpoint its grant may reach, and the probe that re-verifies it.
   The three decisions this function makes for itself are the ones a row cannot
   make — whether the name is enabled, whether it is built on this port, and
   whether this deployment gave it what it needs.

   A name with a row but no adapter in this build is {b unsupported}, which is
   the startup-fatal fact [startup_verdict] refuses; a name whose row can build it
   but whose key or instance the deployment never supplied is simply absent, as in
   the oracle, where the builder returns [None] and [Config.missing_api_keys] is
   the reporting path. Those are different sentences, and conflating them would
   refuse startup over a config the operator can fix by adding a key. *)
let build_providers ~sw ~net ~mono_clock ~now ?audit ?log config =
  let policy_seconds = config.Config.policy.Config.provider_timeout_seconds in
  let snippet_chars = config.Config.policy.Config.max_snippet_chars in
  let text_chars = config.Config.policy.Config.max_result_text_chars in
  let rec go built table endpoints errors unsupported warmups = function
    | [] ->
        {
          built = List.rev built;
          probe_table = List.rev table;
          endpoints = List.rev endpoints;
          grant_errors = List.rev errors;
          (* Sorted, because the startup refusal and [--check] both list these
             names and an operator scanning two renderings of the same set
             should read the same order. *)
          unsupported = List.sort String.compare (List.rev unsupported);
          warmups = List.rev warmups;
        }
    | (name, pc0) :: rest ->
        (* The annotation is load-bearing: [enabled] is a field of more than one
           config record in this module's scope, and an unannotated pattern would
           resolve it by whichever record type the compiler saw last. *)
        let (pc : Config.provider_config) = pc0 in
        if not pc.Config.enabled then go built table endpoints errors unsupported warmups rest
        else
          match Registry.row name with
          | None -> go built table endpoints errors (name :: unsupported) warmups rest
          | Some (row : Registry.row) -> (
              (* The two builder shapes differ only in whether the adapter
                 arrives with a [warmup] beside it: both become one function
                 here — adapter and optional warmup — so the prerequisite,
                 grant and argument plumbing below runs the same for either,
                 and a [Deferred] row falls to the unsupported path with no
                 builder to run. *)
              match
                (match row.build with
                | Registry.Adapter make -> Some (fun (args : Registry.args) -> (make args, None))
                | Registry.Adapter_session make ->
                    Some
                      (fun (args : Registry.args) ->
                        let session = make args in
                        (session.Provider.adapter, Some session.Provider.warmup))
                | Registry.Deferred _wave -> None)
              with
              | None -> go built table endpoints errors (name :: unsupported) warmups rest
              | Some produce -> (
                  match Registry.missing_prerequisite row pc with
                  | Some _reason -> go built table endpoints errors unsupported warmups rest
                  | None -> (
                      match adapter_of_row ~policy_seconds row pc with
                      | Error message ->
                          go built table endpoints ((name, message) :: errors) unsupported
                            warmups rest
                      | Ok adapter -> (
                          match
                            grant_of_endpoint ~sw ~net ~mono_clock
                              ~timeout_seconds:adapter.timeout_seconds
                              ?audit adapter.endpoint
                          with
                          | Error message ->
                              go built table endpoints ((name, message) :: errors)
                                unsupported warmups rest
                          | Ok grant ->
                              let args : Registry.args =
                                {
                                  Registry.net = Provider.Net.of_grant grant;
                                  now;
                                  key = Registry.key_for row;
                                  (* The destination the row resolved, which is the
                                     same reading {!grant_endpoint} confined this
                                     grant to: a config-derived name ([searxng])
                                     dials what its grant allows because both came
                                     from one call. *)
                                  endpoint = adapter.uri;
                                  entry = pc;
                                  cost_per_1k = Registry.price row pc;
                                  snippet_chars;
                                  text_chars;
                                  log;
                                }
                              in
                              match produce args with
                              | adapter', Some warmup ->
                                  go
                                    ((name, adapter') :: built)
                                    ((name, Registry.probe_spec row) :: table)
                                    (adapter.endpoint :: endpoints)
                                    errors unsupported
                                    ((name, warmup) :: warmups)
                                    rest
                              | adapter', None ->
                                  go
                                    ((name, adapter') :: built)
                                    ((name, Registry.probe_spec row) :: table)
                                    (adapter.endpoint :: endpoints)
                                    errors unsupported warmups rest))))
  in
  go [] [] [] [] [] [] config.Config.providers
