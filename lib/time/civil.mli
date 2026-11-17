(** Civil-date arithmetic: the day count from 1970-01-01 and the calendar date, with no clock and no
    timezone. Day counts {i floor} toward earlier dates — a pre-epoch instant names the day before
    the epoch, never the epoch. *)

val days_from_civil : int -> int -> int -> int
(** [days_from_civil y m d] is the day number of a calendar date. *)

val civil_from_days : int -> int * int * int
(** [civil_from_days days] is [(year, month, day)]: the inverse. *)

val whole_seconds : float -> int
(** [whole_seconds instant] is [instant] floored to a whole second: a negative or fractional instant
    never rounds toward the epoch. *)

val days_of_secs : int -> int
(** [days_of_secs secs] is the whole-day bucket [secs] falls in, floored, so a negative [secs] lands
    below zero rather than in day 0. *)

val seconds_of_day : int -> int
(** [seconds_of_day secs] is [secs]'s whole-second offset into its day: never negative, where
    [secs mod 86_400] is for a negative [secs]. *)

val clock_of_instant : float -> int * int * int * float
(** [clock_of_instant instant] is [instant]'s hour, minute, whole second and the fraction left over,
    in the same day bucket [days_of_secs] names. The fraction is at least zero and strictly below
    one for every instant, pre-epoch included — [whole_seconds] floors before the split, so no
    caller has to do its own floored division to render a sub-second stamp. *)

val date_of_days : int -> string
(** [date_of_days days] is [YYYY-MM-DD], the form the journal keys its day buckets on. *)

val date_of_string : string -> int option
(** [date_of_string date] reads [YYYY-MM-DD] and nothing else: [None] is a string in no such form,
    not day 0. *)

val iso_utc_seconds : float -> string
(** [iso_utc_seconds instant] is [YYYY-MM-DDThh:mm:ssZ] at whole seconds; a fractional [instant]
    floors, it does not round.

    Two spellings of the same instant are deliberate, and both are live. This [Z] form is the
    model-facing and operator-facing one — the adapters' [format_utc] and [Cli_metrics]'s report.
    [Seekwright.Usage.iso_utc_seconds] renders the identical calendar moment as [...+00:00], because
    that string is the usage journal's [ts] key: it is compared and pruned as written, and a
    deployed journal already holds that spelling. [Usage.iso_utc_full] is the same key with the
    microsecond field. Not one function can serve both, and they must render the same moment —
    [test_usage] pins the agreement. *)
