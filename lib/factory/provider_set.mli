(** The two records the construction layer reports in: what a build pass
    produced, and what a config plus that production says about the routable
    sets.

    Port of the reporting half of [src/seekwright/factory.py]'s data shapes. The
    field-level documentation lives on [Seekwright_factory.Factory], which is the
    public interface and re-exports both records with their labels; this module
    exists so that re-export has one owner to name. Nothing here is a function,
    and nothing outside [Seekwright_factory] needs to name this module. *)

(** What one pass of [Factory.build_providers] produced: the adapters, their
    probes, the endpoints they may dial, the names that failed to build a grant,
    the names this build has no adapter for, and the session warmups. The field
    documentation is on [Factory.providers]. *)
type providers = {
  built : (Seekwright.Config.name * Seekwright.Provider.t) list;
  probe_table : (Seekwright.Config.name * Seekwright.Health.probe_spec) list;
  endpoints : Mcp_caps.Policy.endpoint list;
  grant_errors : (Seekwright.Config.name * string) list;
  unsupported : Seekwright.Config.name list;
  warmups : (Seekwright.Config.name * (unit -> bool)) list;
}

(** The sets [--check] prints and [Factory.startup_verdict] refuses on, from one
    config and one build pass. The field documentation is on
    [Factory.set_report]. *)
type set_report = {
  enabled : Seekwright.Config.name list;
  effective : Seekwright.Config.name list;
  built : Seekwright.Config.name list;
  unsupported : Seekwright.Config.name list;
  skipped : Seekwright.Config.name list;
  untested : Seekwright.Config.name list;
}
