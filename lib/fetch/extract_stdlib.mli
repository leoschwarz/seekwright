(** The standard library extraction backend. *)

val name : string
val supported_types : string list
val extract : string -> string option -> Extractor.extract_result
