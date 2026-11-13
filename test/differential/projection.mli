(** The projection interface: one function per corpus area.

    Each function takes one corpus case — the file's text, except {!config},
    which takes the case file's {b path} because the config area drives the file
    loader and its path handling — and answers with the projection lines the
    golden pins. The line grammar is the corpus format's, written down in
    [README.md] beside this interface; {!areas} is the pairing of area name to
    function that both the driver and the golden runner walk, so an area that
    nothing runs is an area that fails the suite rather than one that quietly
    stops being checked. *)

val config : string -> string list
val sanitize : string -> string list
val fetch : string -> string list
val jsondoc : string -> string list
val tabledoc : string -> string list
val router : string -> string list
val model : string -> string list
val engine : string -> string list

(** [areas] pairs each area name with its projection function, in the order the
    runner walks them. The name is the corpus and golden subdirectory. *)
val areas : (string * (string -> string list)) list
