module Config = Seekwright.Config
module Policy = Mcp_caps.Policy
module Provider = Seekwright.Provider

open Provider_set

let grant_of_endpoint = Grants.grant_of_endpoint

type adapter = { endpoint : Policy.endpoint; uri : Uri.t; timeout_seconds : float }

let adapter_of_row ~policy_seconds (row : Registry.row) (pc : Config.provider_config) =
  match (Registry.grant_endpoint row pc, Registry.uri row pc) with
  | Ok endpoint, Ok uri ->
      Ok { endpoint; uri; timeout_seconds = Registry.timeout_seconds row ~policy_seconds }
  | Error message, _ | _, Error message -> Error message

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
          unsupported = List.sort String.compare (List.rev unsupported);
          warmups = List.rev warmups;
        }
    | (name, pc0) :: rest -> (
        (* The annotation is load-bearing: [enabled] is a field of more than one
           config record in this module's scope, and an unannotated pattern would
           resolve it by whichever record type the compiler saw last. *)
        let (pc : Config.provider_config) = pc0 in
        if not pc.Config.enabled then go built table endpoints errors unsupported warmups rest
        else
          match Registry.row name with
          | None -> go built table endpoints errors (name :: unsupported) warmups rest
          | Some (row : Registry.row) -> (
              match
                match row.build with
                | Registry.Adapter make -> Some (fun (args : Registry.args) -> (make args, None))
                | Registry.Adapter_session make ->
                    Some
                      (fun (args : Registry.args) ->
                        let session = make args in
                        (session.Provider.adapter, Some session.Provider.warmup))
                | Registry.Deferred _wave -> None
              with
              | None -> go built table endpoints errors (name :: unsupported) warmups rest
              | Some produce -> (
                  match Registry.missing_prerequisite row pc with
                  | Some _reason -> go built table endpoints errors unsupported warmups rest
                  | None -> (
                      match adapter_of_row ~policy_seconds row pc with
                      | Error message ->
                          go built table endpoints ((name, message) :: errors) unsupported warmups
                            rest
                      | Ok adapter -> (
                          match
                            grant_of_endpoint ~sw ~net ~mono_clock
                              ~timeout_seconds:adapter.timeout_seconds ?audit adapter.endpoint
                          with
                          | Error message ->
                              go built table endpoints ((name, message) :: errors) unsupported
                                warmups rest
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
                              let adapter', warmup = produce args in
                              go ((name, adapter') :: built)
                                ((name, Registry.probe_spec row) :: table)
                                (adapter.endpoint :: endpoints) errors unsupported
                                (match warmup with
                                | Some warmup -> (name, warmup) :: warmups
                                | None -> warmups)
                                rest)))))
  in
  go [] [] [] [] [] [] config.Config.providers
