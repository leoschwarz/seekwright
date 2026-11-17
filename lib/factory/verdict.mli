(** Provider set classification and startup validation: what one config and one
    {!Providers_build.build_providers} pass together say about the routable sets. *)

val classify : Seekwright.Config.t -> Providers_build.providers -> Providers_build.set_report
(** The five sets [--check] prints, from one config and one build pass. The categories partition
    {i nothing}: a name can be enabled, effective, untested and unsupported at once (Python's four
    untested names have no adapter here), and [classify] reports each fact once rather than
    collapsing them into one word. *)

val startup_verdict : Seekwright.Config.t -> Providers_build.providers -> (unit, string) result
(** Whether {!App.build_app} may construct an engine over this pair:

    - an explicitly enabled name with no adapter is refused, naming {i all} the offending names
      sorted with "not built on this port" — one row per offender would make an operator fix a
      config one restart at a time;
    - an implicit keyless default that leaves no keyless adapter built is refused too: the
      skipped-names disclosure is honest only while the built remainder can route;
    - a [default_provider] outside the built set is refused wherever it came from (config validation
      already refuses one outside [enabled]; the enabled⇒built step is this verdict's).

    A permitted-but-not-enabled name, and a fallback ladder naming an enabled name the implicit
    default skipped, keep the oracle's runtime sentences — a refusal, or an inert rung — because
    neither is a server holding a name it cannot dispatch. *)
