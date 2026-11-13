(** The deterministic property suite.

    One callable unit, because the module is the test executable's entry point:
    running it is the same as being linked, and [suite] exists so the grouping is
    nameable and an [.mli] can state the module's purpose without exporting a
    generator that is only an implementation detail. Every property in it is
    deterministic — the seed is a literal in the implementation, never
    [QCHECK_SEED] — and hermetic: no fixture file, no Python, no clock. *)
val suite : unit -> unit
