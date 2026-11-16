let ( let* ) = Result.bind

module Model = Seekwright.Model

type scanned = {
  positional : string list;
  flags : (string * string list) list;
  bools : string list;
}

let boolean_flags = [ "--json"; "--structure"; "--safe-search"; "--no-safe-search" ]

let is_long_flag token = String.length token > 2 && String.sub token 0 2 = "--"

let scan_args argv =
  let rec go scanned = function
    | [] -> Ok scanned
    | flag :: rest when List.mem flag boolean_flags ->
        let flags =
          match flag with
          | "--no-safe-search" -> ("--safe-search", [ "false" ]) :: scanned.flags
          | "--safe-search" -> ("--safe-search", [ "true" ]) :: scanned.flags
          | _ -> scanned.flags
        in
        go { bools = flag :: scanned.bools; flags; positional = scanned.positional } rest
    | flag :: rest when is_long_flag flag -> (
        if String.contains flag '=' then
          let eq = String.index flag '=' in
          let name = String.sub flag 0 eq in
          let value = String.sub flag (eq + 1) (String.length flag - eq - 1) in
          if List.mem name boolean_flags then Error (name ^ " takes no value")
          else go { scanned with flags = (name, [ value ]) :: scanned.flags } rest
        else
          match rest with
          | value :: rest' when not (String.length value > 2 && String.sub value 0 2 = "--") ->
              go { scanned with flags = (flag, [ value ]) :: scanned.flags } rest'
          | _ -> Error (flag ^ " needs a value"))
    | arg :: rest -> go { scanned with positional = arg :: scanned.positional } rest
  in
  let* scanned = go { positional = []; flags = []; bools = [] } argv in
  Ok { scanned with positional = List.rev scanned.positional; flags = List.rev scanned.flags }

let flag_values scanned name =
  List.concat_map (fun (flag, values) -> if flag = name then values else []) scanned.flags

let flag_one scanned name =
  match flag_values scanned name with value :: _ -> Some value | [] -> None
let flag_bool scanned name = List.mem name scanned.bools

let usage_error message = Error message

let recency_of_string = function
  | "day" -> Some Model.Day
  | "week" -> Some Model.Week
  | "month" -> Some Model.Month
  | "year" -> Some Model.Year
  | _ -> None

let int_flag scanned name ~default =
  match flag_one scanned name with
  | Some text -> (
      match int_of_string_opt text with
      | Some n -> Ok n
      | None -> usage_error (name ^ " needs a number"))
  | None -> Ok default

let bool_flag scanned name =
  match flag_values scanned name with
  | "true" :: _ -> Some true
  | "false" :: _ -> Some false
  | _ -> None

let list_flag scanned name =
  match flag_values scanned name with [] -> None | values -> Some values

let domain_flags scanned =
  (list_flag scanned "--include-domain", list_flag scanned "--exclude-domain")

let validate_request decode json =
  match decode json with
  | Ok _ -> Ok json
  | Error message -> usage_error ("Invalid request: " ^ message ^ ".")

let search_body scanned =
  let query =
    match scanned.positional with
    | [ query ] -> Ok query
    | [] -> usage_error "search needs a QUERY"
    | _ -> usage_error "search takes exactly one QUERY"
  in
  let* query = query in
  let include_domains, exclude_domains = domain_flags scanned in
  let* max_results = int_flag scanned "--max-results" ~default:5 in
  let* recency =
    match flag_one scanned "--recency" with
    | Some text -> (
        match recency_of_string text with
        | Some r -> Ok (Some r)
        | None -> usage_error "--recency needs day, week, month or year")
    | None -> Ok None
  in
  let request : Model.search_request =
    {
      Model.query;
      provider = flag_one scanned "--provider";
      mode = None;
      max_results;
      include_domains;
      exclude_domains;
      recency;
      language = flag_one scanned "--language";
      safe_search = bool_flag scanned "--safe-search";
    }
  in
  validate_request Model.search_request_of_yojson (Model.search_request_to_yojson request)

let fetch_body scanned =
  let* url =
    match scanned.positional with
    | [ url ] -> Ok url
    | [] -> usage_error "fetch needs a URL"
    | _ -> usage_error "fetch takes exactly one URL"
  in
  let* offset =
    match flag_one scanned "--offset" with
    | Some text -> (
        match int_of_string_opt text with
        | Some n -> Ok (Some (`Int n))
        | None -> usage_error "--offset needs a number")
    | None -> Ok None
  in
  let fields =
    [ ("url", `String url) ]
    @ (match flag_one scanned "--query" with Some q -> [ ("query", `String q) ] | None -> [])
    @ (match offset with Some v -> [ ("offset", v) ] | None -> [])
    @ (match flag_one scanned "--path" with Some p -> [ ("path", `String p) ] | None -> [])
    @ (if flag_bool scanned "--structure" then [ ("structure", `Bool true) ] else [])
    @ match flag_one scanned "--provider" with Some p -> [ ("provider", `String p) ] | None -> []
  in
  validate_request Model.fetch_request_of_yojson (`Assoc fields)

let answer_body scanned =
  let* query =
    match scanned.positional with
    | [ query ] -> Ok query
    | [] -> usage_error "answer needs a QUERY"
    | _ -> usage_error "answer takes exactly one QUERY"
  in
  let include_domains, exclude_domains = domain_flags scanned in
  let* depth =
    match flag_one scanned "--depth" with
    | Some "brief" -> Ok (Some Model.Brief)
    | Some "report" -> Ok (Some Model.Report)
    | Some _ -> usage_error "--depth needs brief or report"
    | None -> Ok None
  in
  let* recency =
    match flag_one scanned "--recency" with
    | Some text -> (
        match recency_of_string text with
        | Some r -> Ok (Some r)
        | None -> usage_error "--recency needs day, week, month or year")
    | None -> Ok None
  in
  let request : Model.answer_request =
    {
      Model.query;
      extra_queries = list_flag scanned "--extra-query";
      depth;
      provider = flag_one scanned "--provider";
      include_domains;
      exclude_domains;
      recency;
      language = flag_one scanned "--language";
      safe_search = bool_flag scanned "--safe-search";
    }
  in
  validate_request Model.answer_request_of_yojson (Model.answer_request_to_yojson request)
