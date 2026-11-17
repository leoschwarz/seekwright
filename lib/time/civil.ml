(* Howard Hinnant's civil-date arithmetic: the day count and the calendar date,
   with no timezone library and no clock — the decision recorded in
   plans/seekwright-ocaml-port.md. *)

let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let doy = (((153 * (m + if m > 2 then -3 else 9)) + 2) / 5) + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let civil_from_days z0 =
  let z = z0 + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let y = if m <= 2 then y + 1 else y in
  (y, m, d)

(* The instant floored to a whole second: [int_of_float] alone truncates toward
   zero, which reads a pre-epoch fraction as the epoch. *)
let whole_seconds instant = int_of_float (Float.floor instant)

(* Floor division, not the toward-zero truncation integer [/] does: a pre-epoch
   instant lands in the day {i before} the epoch, and [seconds_of_day] stays
   non-negative. *)
let days_of_secs secs = if secs >= 0 then secs / 86_400 else (secs - 86_399) / 86_400
let seconds_of_day secs = secs - (days_of_secs secs * 86_400)

(* The same bucket as [seconds_of_day], fraction kept: [whole_seconds] floors, so
   [frac] is in [[0, 1)] for every instant, pre-epoch included. The microsecond
   stamp is the only thing that needs it, which is why [seconds_of_day] stays an
   [int -> int]. *)
let clock_of_instant instant =
  let secs = whole_seconds instant in
  let sod = seconds_of_day secs in
  (sod / 3600, sod / 60 mod 60, sod mod 60, instant -. Float.of_int secs)

let date_of_days days =
  let y, m, d = civil_from_days days in
  Printf.sprintf "%04d-%02d-%02d" y m d

(* [YYYY-MM-DD] is the form the journal keys its day buckets on, and the prune
   compares that key as a string — a form check first, then the day count. *)
let date_of_string date =
  let digit i = match date.[i] with '0' .. '9' -> true | _ -> false in
  if
    String.length date <> 10
    || (not (digit 0 && digit 1 && digit 2 && digit 3))
    || date.[4] <> '-'
    || (not (digit 5 && digit 6))
    || date.[7] <> '-'
    || not (digit 8 && digit 9)
  then None
  else
    Some
      (days_from_civil
         (int_of_string (String.sub date 0 4))
         (int_of_string (String.sub date 5 2))
         (int_of_string (String.sub date 8 2)))

let iso_utc_seconds instant =
  let y, m, d = civil_from_days (days_of_secs (whole_seconds instant)) in
  let hh, mm, ss, _ = clock_of_instant instant in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" y m d hh mm ss
