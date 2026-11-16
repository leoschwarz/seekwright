(** Provider set classification and startup validation. *)

val classify : Seekwright.Config.t -> Provider_set.providers -> Provider_set.set_report
(** The sets [--check] prints, from one config and one build pass. *)

val startup_verdict : Seekwright.Config.t -> Provider_set.providers -> (unit, string) result
(** Whether [Factory.build_app] may construct an engine over this pair of config and build. *)
