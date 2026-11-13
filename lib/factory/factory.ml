(* The public face of [seekwright.factory]: the two records a build reports in,
   and the ten values a caller outside this library names — each one a line
   pointing at the module that does the work. Port of [src/seekwright/factory.py];
   [factory.mli] is the contract, and it is unchanged by how the work is arranged
   behind it.

   Four rules the arrangement exists to keep, and where each one lives now:

   One funnel. [Grants.grant_of_decision] is the only place a confinement decision
   becomes a grant that runs, with the config's per-operation bound and one audit
   sink. The two layer calls that do the wrapping and the construction appear once
   across this library — counted as a total over [lib/factory] by
   [test/test_caps_audit.ml], which also names the file that holds them. (That
   count is why this file does not spell those calls out.)

   The verdict before the engine. [Verdict.startup_verdict] answers whether a
   config may hold a routable provider set, and [App.build_app] runs it before a
   single engine exists: an engine over a config this build cannot route is what
   the verdict refuses, so a served process never holds a config name with no
   adapter behind it. [test_caps_audit] pins that order by source order in
   [app.ml].

   The diagnosis never builds an engine. [--check] and [--metrics] read config,
   build providers for probing, and report the extraction backend — through
   [build_providers], [build_extractor] and [probe_net], never through [build_app]
   or [App]. [App] is the only module here that can construct an engine, and
   [lib/cli] names neither it nor [build_app]; [test_caps_audit] pins that too.

   What a caller may name. This interface, and nothing else: [dune] keeps
   [grants], [verdict], [providers_build], [fetch_stack] and [app] private to the
   library. [Provider_set] is public only because [providers] and [set_report]
   are re-exported here with their field labels, which is what lets callers write
   [x.Factory.built]. *)

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
