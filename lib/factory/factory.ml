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
let build_page_cache = Fetch_stack.build_page_cache
let page_cache_stats = Fetch_stack.page_cache_stats

let build_app = App.build_app
