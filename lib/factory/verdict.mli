(** Which configurations may hold a routable provider set, and the sets a
    diagnosis reports about one.

    Private to [Seekwright_factory]: [Factory] re-exports {!classify} and
    {!startup_verdict}, and nothing else here is reachable from outside the
    library. Both functions read one classification, so [--check]'s provider
    section and a startup refusal name the same sets — that agreement is why
    they live in one module rather than beside the builders that consume them. *)

(** The sets [--check] prints, from one config and one build pass. The full
    contract, including what each field means and how the categories overlap, is
    on [Factory.classify] in [factory.mli]. *)
val classify : Seekwright.Config.t -> Provider_set.providers -> Provider_set.set_report

(** Whether [Factory.build_app] may construct an engine over this pair of
    config and build. The full contract is on [Factory.startup_verdict] in
    [factory.mli]. *)
val startup_verdict :
  Seekwright.Config.t -> Provider_set.providers -> (unit, string) result
