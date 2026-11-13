(* The metrics report. Port of [src/seekwright/cli.py]'s [--metrics] path:
   fold the usage journal and print the provider table. The snapshot arrives
   as the JSON [Usage.snapshot] writes, so the report is driven from a value
   in a test — no journal, no clock race: the window's two dates come from an
   injected [now]. *)

let json_field key = function
  | `Assoc fields -> ( match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

let json_string key json = match json_field key json with `String s -> Some s | _ -> None
let json_int key json =
  match json_field key json with
  | `Int n -> Some n
  | `Float f -> Some (int_of_float f)
  | _ -> None

let json_float key json =
  match json_field key json with
  | `Int n -> Some (float_of_int n)
  | `Float f -> Some f
  | _ -> None

let json_bool key json = match json_field key json with `Bool b -> Some b | _ -> None
let json_list key json = match json_field key json with `List items -> Some items | _ -> None

let columns =
  [ "provider"; "calls"; "errors"; "fellback"; "samples"; "p50 ms"; "p95 ms"; "mean ms"; "cost usd"; "$/1k"; "last seen" ]

let milliseconds = function None -> "—" | Some n -> string_of_int n
let per_1k = function None -> "—" | Some v -> Printf.sprintf "%.4f" v

let digit2 s i =
  if i + 2 > String.length s then 0
  else
    let sub = String.sub s i 2 in
    if String.for_all (fun c -> c >= '0' && c <= '9') sub then int_of_string sub else 0

(* Howard Hunt's civil-from-days, the mirror of [usage.ml]'s date arithmetic:
   epoch seconds to a civil date and clock time. The floor split matters the
   same way it does there: a pre-epoch stamp lands in the day before. *)
let civil_of_secs secs =
  let days = if secs >= 0 then secs / 86_400 else (secs - 86_399) / 86_400 in
  let day_of = secs - days * 86_400 in
  let z = days + 719_468 in
  let era = (if z >= 0 then z else z - 146_096) / 146_097 in
  let doe = z - era * 146_097 in
  let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365 in
  let y = yoe + era * 400 in
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100) in
  let mp = (5 * doy + 2) / 153 in
  let d = doy - (153 * mp + 2) / 5 + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let year = if m <= 2 then y + 1 else y in
  Some (year, m, d, day_of / 3600, (day_of / 60) mod 60, day_of mod 60)

(* [days_from_civil] beside [civil_of_secs] is the same pair [usage.ml] keeps,
   and it has to be that exact pair: the two directions have to be inverses, and
   a hand-folded era constant is where the off-by-one-year lives. *)
let days_from_civil (y : int) (m : int) (d : int) : int =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let doy = ((153 * (m + (if m > 2 then -3 else 9))) + 2) / 5 + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let secs_of_utc day time offset_secs =
  (* days since 1970-01-01 (the same civil arithmetic [usage.ml] uses) plus
     the day's seconds, minus the written offset: [fromisoformat().astimezone(UTC)]. *)
  let (y, m, d) =
    let y = int_of_string (String.sub day 0 4) in
    let m = int_of_string (String.sub day 5 2) in
    let d = int_of_string (String.sub day 8 2) in
    (y, m, d)
  in
  days_from_civil y m d * 86_400 + time - offset_secs

(* Port of [cli.py]'s [_seen]: [datetime.fromisoformat(value).astimezone(UTC)]
   rendered as [%Y-%m-%dT%H:%M:%SZ]. The stamp is split into its date, clock
   and offset parts; a stamp written in local time (no offset) is read as UTC,
   which is what [astimezone] does to a naive datetime too. *)
let seen value =
  match value with
  | None -> "—"
  | Some text ->
      match String.index_opt text 'T' with
      | None -> text
      | Some t ->
          let day = String.sub text 0 t in
          let timetext = String.sub text (t + 1) (String.length text - t - 1) in
          let cut =
            match String.index_opt timetext '+' with
            | Some i -> i
            | None -> ( match String.index_opt timetext '-' with Some i when i > 0 -> i | _ -> String.length timetext)
          in
          let clock = String.sub timetext 0 cut in
          let offset_text = String.sub timetext cut (String.length timetext - cut) in
          let hh = digit2 clock 0 in
          let mm = digit2 clock 3 in
          let ss = digit2 clock 6 in
          let offset =
            if offset_text = "" || offset_text = "Z" then 0
            else
              let sign = if offset_text.[0] = '-' then -1 else 1 in
              let body = String.sub offset_text 1 (String.length offset_text - 1) in
              let oh = digit2 body 0 in
              let om = if String.length body >= 4 then digit2 body 2 else digit2 body 1 in
              sign * (oh * 3600 + om * 60)
          in
          let iso =
            match civil_of_secs (secs_of_utc day (hh * 3600 + mm * 60 + ss) offset) with
            | Some (y, m, d, hh, mm, ss) ->
                Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" y m d hh mm ss
            | None -> text
          in
          iso

let row entry =
  [
    Option.value ~default:"" (json_string "provider" entry);
    string_of_int (Option.value ~default:0 (json_int "calls" entry));
    string_of_int (Option.value ~default:0 (json_int "errors" entry));
    string_of_int (Option.value ~default:0 (json_int "fell_back_calls" entry));
    string_of_int (Option.value ~default:0 (json_int "latency_samples" entry));
    milliseconds (json_int "p50_ms" entry);
    milliseconds (json_int "p95_ms" entry);
    milliseconds (json_int "mean_ms" entry);
    Printf.sprintf "%.4f" (Option.value ~default:0.0 (json_float "cost_usd" entry));
    per_1k (json_float "cost_per_1k" entry);
    seen (json_string "last_seen" entry);
  ]

(* The Python's column rule: the first and last columns are left-aligned,
   every column between them is right-aligned, and neighbours are two spaces
   apart. *)
let format_row cells widths =
  let last = List.length cells - 1 in
  String.concat "  "
    (List.mapi
       (fun i cell ->
         if i = 0 || i = last then
           cell ^ String.make (max 0 (List.nth widths i - String.length cell)) ' '
         else
           String.make (max 0 (List.nth widths i - String.length cell)) ' ' ^ cell)
       cells)

let journal_state journal =
  match json_string "path" journal with
  | None -> "off — dashboard.history_path unset"
  | Some path ->
      Printf.sprintf "%s  %s" path
        (match json_bool "failed" journal with Some true -> "failed" | _ -> "ok")

let iso day =
  Printf.sprintf "%04d-%02d-%02d" (day.Unix.tm_year + 1900) (day.Unix.tm_mon + 1) day.Unix.tm_mday

(* [endpoints] and [journal] are the two fields of [Usage.snapshot] this report
   reads; [now] is injected so the window's first and last dates are pinned. *)
let print_report ~emit ~now endpoints journal =
  let today = Unix.gmtime now in
  let window_days = Option.value ~default:14 (json_int "window_days" endpoints) in
  let first = Unix.gmtime (now -. float_of_int (window_days - 1) *. 86_400.0) in
  emit "seekwright metrics";
  emit "==================";
  emit (Printf.sprintf "window      %d days, %s .. %s (UTC)" window_days (iso first) (iso today));
  emit (Printf.sprintf "journal     %s" (journal_state journal));
  emit "";
  match json_list "providers" endpoints with
  | None | Some [] -> emit "no history"
  | Some entries ->
      let rows = List.map row entries in
      let widths =
        List.mapi
          (fun i label ->
            List.fold_left (fun acc row -> max acc (String.length (List.nth row i))) (String.length label) rows)
          columns
      in
      emit (format_row columns widths);
      List.iter (fun row -> emit (format_row row widths)) rows
