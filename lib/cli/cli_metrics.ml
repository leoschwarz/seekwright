module Civil = Seekwright_time.Civil

let json_field key = function
  | `Assoc fields -> ( match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

let json_string key json = match json_field key json with `String s -> Some s | _ -> None
let json_int key json =
  match json_field key json with `Int n -> Some n | `Float f -> Some (int_of_float f) | _ -> None

let json_float key json =
  match json_field key json with `Int n -> Some (float_of_int n) | `Float f -> Some f | _ -> None

let json_bool key json = match json_field key json with `Bool b -> Some b | _ -> None
let json_list key json = match json_field key json with `List items -> Some items | _ -> None

let columns =
  [
    "provider";
    "calls";
    "errors";
    "fellback";
    "samples";
    "p50 ms";
    "p95 ms";
    "mean ms";
    "cost usd";
    "$/1k";
    "last seen";
  ]

let milliseconds = function None -> "—" | Some n -> string_of_int n
let per_1k = function None -> "—" | Some v -> Printf.sprintf "%.4f" v

let digit2 s i =
  if i + 2 > String.length s then 0
  else
    let sub = String.sub s i 2 in
    if String.for_all (fun c -> c >= '0' && c <= '9') sub then int_of_string sub else 0

let secs_of_utc day time offset_secs =
  let y, m, d =
    let y = int_of_string (String.sub day 0 4) in
    let m = int_of_string (String.sub day 5 2) in
    let d = int_of_string (String.sub day 8 2) in
    (y, m, d)
  in
  (Civil.days_from_civil y m d * 86_400) + time - offset_secs

let seen value =
  match value with
  | None -> "—"
  | Some text -> (
      match String.index_opt text 'T' with
      | None -> text
      | Some t ->
          let day = String.sub text 0 t in
          let timetext = String.sub text (t + 1) (String.length text - t - 1) in
          let cut =
            match String.index_opt timetext '+' with
            | Some i -> i
            | None -> (
                match String.index_opt timetext '-' with
                | Some i when i > 0 -> i
                | _ -> String.length timetext)
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
              sign * ((oh * 3600) + (om * 60))
          in
          Civil.iso_utc_seconds
            (float_of_int (secs_of_utc day ((hh * 3600) + (mm * 60) + ss) offset)))

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

let format_row cells widths =
  let last = List.length cells - 1 in
  String.concat "  "
    (List.mapi
       (fun i cell ->
         if i = 0 || i = last then
           cell ^ String.make (max 0 (List.nth widths i - String.length cell)) ' '
         else String.make (max 0 (List.nth widths i - String.length cell)) ' ' ^ cell)
       cells)

let journal_state journal =
  match json_string "path" journal with
  | None -> "off — dashboard.history_path unset"
  | Some path ->
      Printf.sprintf "%s  %s" path
        (match json_bool "failed" journal with Some true -> "failed" | _ -> "ok")

let iso day =
  Printf.sprintf "%04d-%02d-%02d" (day.Unix.tm_year + 1900) (day.Unix.tm_mon + 1) day.Unix.tm_mday

let print_report ~emit ~now endpoints journal =
  let today = Unix.gmtime now in
  let window_days = Option.value ~default:14 (json_int "window_days" endpoints) in
  let first = Unix.gmtime (now -. (float_of_int (window_days - 1) *. 86_400.0)) in
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
            List.fold_left
              (fun acc row -> max acc (String.length (List.nth row i)))
              (String.length label) rows)
          columns
      in
      emit (format_row columns widths);
      List.iter (fun row -> emit (format_row row widths)) rows
