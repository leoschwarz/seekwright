(* Construction from config and environment. Port of
   [src/seekwright/factory.py]; see [factory.mli] for the shape.

   A configured name with no adapter in this build is a construction-time
   fact, and it is acted on at construction: {!startup_verdict} refuses to
   start a server on an explicitly enabled name this port does not carry,
   naming every offender at once, because a running server holding such a
   config answers the named route with one refusal and the default route with
   a dispatch failure — and the honest choice is to refuse the half-configured
   deployment before it serves. The only exception is the implicit keyless
   default (no [providers] table at all), which may start over its built free
   remainder with the skipped names logged by name; when even that remainder
   is empty, it refuses too. [--check] reports the same facts through
   {!classify} without refusing anything, because a diagnosis of a deployment
   exits nowhere. Every routing decision then reads one built, permitted set,
   and the engine's runtime no-adapter branch is a guard, never a route. *)

module Caps = Mcp_caps
module Policy = Caps.Policy
module Config = Seekwright.Config
module Health = Seekwright.Health
module Provider = Seekwright.Provider

type providers = Provider_set.providers = {
  built : (Config.name * Provider.t) list;
  probe_table : (Config.name * Health.probe_spec) list;
  endpoints : Policy.endpoint list;
  grant_errors : (Config.name * string) list;
  unsupported : Config.name list;
  warmups : (Config.name * (unit -> bool)) list;
}

let audit_sink = Grants.audit_sink
let grant_of_endpoint = Grants.grant_of_endpoint

let build_providers = Providers_build.build_providers

type set_report = Provider_set.set_report = {
  enabled : Config.name list;
  effective : Config.name list;
  built : Config.name list;
  unsupported : Config.name list;
  skipped : Config.name list;
  untested : Config.name list;
}

let classify = Verdict.classify
let startup_verdict = Verdict.startup_verdict

let probe_net = Grants.probe_net

let build_extractor = Fetch_stack.build_extractor
let readers = Fetch_stack.readers
let build_fetch_stack = Fetch_stack.build_fetch_stack

let build_app = App.build_app
