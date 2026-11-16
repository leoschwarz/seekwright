(** The two records the construction layer reports in: what a build pass produced, and what a config
    plus that production says about the routable sets. *)

type providers = {
  built : (Seekwright.Config.name * Seekwright.Provider.t) list;
  probe_table : (Seekwright.Config.name * Seekwright.Health.probe_spec) list;
  endpoints : Mcp_caps.Policy.endpoint list;
  grant_errors : (Seekwright.Config.name * string) list;
  unsupported : Seekwright.Config.name list;
  warmups : (Seekwright.Config.name * (unit -> bool)) list;
}

type set_report = {
  enabled : Seekwright.Config.name list;
  effective : Seekwright.Config.name list;
  built : Seekwright.Config.name list;
  unsupported : Seekwright.Config.name list;
  skipped : Seekwright.Config.name list;
  untested : Seekwright.Config.name list;
}
