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

val date_of_days : int -> string
(** [date_of_days days] is [YYYY-MM-DD], the form the journal keys its day buckets on. *)

val date_of_string : string -> int option
(** [date_of_string date] reads [YYYY-MM-DD] and nothing else: [None] is a string in no such form,
    not day 0. *)

val iso_utc_seconds : float -> string
(** [iso_utc_seconds instant] is [YYYY-MM-DDThh:mm:ssZ] at whole seconds; a fractional [instant]
    floors, it does not round. *)
