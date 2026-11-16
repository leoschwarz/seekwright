(** The metrics report behind [--metrics]. Formats usage snapshot JSON into tabular console output.
*)

val columns : string list

val row : Yojson.Safe.t -> string list

val format_row : string list -> int list -> string

val journal_state : Yojson.Safe.t -> string

val print_report : emit:(string -> unit) -> now:float -> Yojson.Safe.t -> Yojson.Safe.t -> unit
(** [print_report ~emit ~now endpoints journal] writes the metrics report. [now] is epoch seconds
    for the upper window bound. *)
