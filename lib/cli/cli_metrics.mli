(** The metrics report — the fold behind [--metrics]. The snapshot arrives as
    the JSON {!Seekwright.Usage.snapshot} writes, so a suite can drive the
    report from a value: no journal, and no clock race, because the window's
    two dates come from an injected [now]. *)

val columns : string list
(** The table's column labels, in order: the provider's own numbers first,
    then latency, cost and freshness. *)

val row : Yojson.Safe.t -> string list
(** [row entry] renders one provider entry of the snapshot's [providers]
    list into the table's cells. *)

val format_row : string list -> int list -> string
(** [format_row cells widths] joins a row: the first and last columns are
    left-aligned, every column between them is right-aligned, neighbours are
    two spaces apart — the Python's column rule. *)

val journal_state : Yojson.Safe.t -> string
(** [journal_state journal] renders the snapshot's [journal] field: off, or
    the path with its write status. *)

val print_report :
  emit:(string -> unit) -> now:float -> Yojson.Safe.t -> Yojson.Safe.t -> unit
(** [print_report ~emit ~now endpoints journal] writes the whole report.
    [endpoints] and [journal] are the two fields of the snapshot this report
    reads; [now] is the window's right edge. *)
