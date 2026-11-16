module Config = Seekwright.Config
module Health = Seekwright.Health
module Policy = Mcp_caps.Policy
module Provider = Seekwright.Provider

type providers = {
  built : (Config.name * Provider.t) list;
  probe_table : (Config.name * Health.probe_spec) list;
  endpoints : Policy.endpoint list;
  grant_errors : (Config.name * string) list;
  unsupported : Config.name list;
  warmups : (Config.name * (unit -> bool)) list;
}

type set_report = {
  enabled : Config.name list;
  effective : Config.name list;
  built : Config.name list;
  unsupported : Config.name list;
  skipped : Config.name list;
  untested : Config.name list;
}
