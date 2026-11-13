(* What one pass of the construction layer reports, and what a config and that
   report say about the sets a process may route. Two records and no functions:
   they are the vocabulary the builders report in.

   They live in their own module because [Factory]'s public interface re-exports
   them as equated aliases — callers qualify the field labels through [Factory]
   ([x.Factory.built], [{ Factory.built = … }]), and a record can only be
   re-exported with its labels by re-declaring it, which puts the owning module
   in a public signature. Keeping that module to two types is what keeps the
   public surface honest: no function appears there twice. *)

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
