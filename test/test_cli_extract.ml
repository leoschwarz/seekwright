(* Port of [tests/test_cli.py]'s client-argument classes: which flag becomes
   which field of which request body. The Python drives the client's
   [_extract] and reads the payload dict; this drives {!Cli_extract} and
   reads the JSON body — the one thing the client actually sends. *)

module Extract = Cli_extract

let body_equals ~label body fields =
  let fields = List.map (fun (k, v) -> (k, v)) fields in
  Alcotest.(check string) label
    (Yojson.Safe.pretty_to_string body)
    (Yojson.Safe.pretty_to_string (`Assoc fields))

let scanned ?(extra = []) arg =
  match Extract.scan_args (arg :: extra) with
  | Ok scanned -> scanned
  | Error message -> Alcotest.failf "scan_args: %s" message

let search ?(extra = []) query =
  match Extract.search_body (scanned ~extra query) with
  | Ok body -> body
  | Error message -> Alcotest.failf "search_body %s: %s" query message

let fetch ?(extra = []) url =
  match Extract.fetch_body (scanned ~extra url) with
  | Ok body -> body
  | Error message -> Alcotest.failf "fetch_body %s: %s" url message

let answer ?(extra = []) query =
  match Extract.answer_body (scanned ~extra query) with
  | Ok body -> body
  | Error message -> Alcotest.failf "answer_body %s: %s" query message

let str key body =
  match body with
  | `Assoc fields -> (
      match List.assoc_opt key fields with Some (`String v) -> Some v | _ -> None)
  | _ -> None

let has key body =
  match body with `Assoc fields -> List.mem_assoc key fields | _ -> false

let int_field key body =
  match body with
  | `Assoc f -> ( match List.assoc_opt key f with Some (`Int n) -> Some n | _ -> None)
  | _ -> None

(* {1 Valid commands} *)

let test_search_query_only () =
  body_equals ~label:"query only" (search "open data")
    [ ("query", `String "open data"); ("max_results", `Int 5) ]

let test_search_flag_becomes_field () =
  (* dotted flag names match the underscored request field: [--max-results]
     fills [max_results], [--provider] fills [provider]. *)
  let body =
    search "open data" ~extra:[ "--provider"; "exa"; "--max-results"; "3"; "--language"; "en" ]
  in
  Alcotest.(check int) "max_results" 3 (Option.value ~default:0 (int_field "max_results" body));
  Alcotest.(check string) "provider" "exa" (Option.value ~default:"" (str "provider" body));
  Alcotest.(check string) "language" "en" (Option.value ~default:"" (str "language" body))

let test_search_inline_equals () =
  let via_eq = search "qq" ~extra:[ "--provider=parallel" ] in
  let via_space = search "qq" ~extra:[ "--provider"; "parallel" ] in
  Alcotest.check Alcotest.string
    "--flag=value matches --flag value"
    (Yojson.Safe.pretty_to_string via_eq)
    (Yojson.Safe.pretty_to_string via_space)

let test_search_no_safe_search () =
  let body = search "qq" ~extra:[ "--no-safe-search" ] in
  match body with
  | `Assoc fields ->
      Alcotest.(check bool) "safe_search is false" true
        (match List.assoc_opt "safe_search" fields with Some (`Bool false) -> true | _ -> false)
  | _ -> Alcotest.fail "not an object"

let test_search_safe_search_takes_no_value () =
  (* [argparse] gives [--safe-search] a const action, so it never eats the token
     after it: the stray "true" is a second QUERY, and the verb's own surplus
     sentence is the refusal. The inline spelling is refused outright. *)
  (match Extract.scan_args [ "qq"; "--safe-search"; "true" ] with
  | Ok scanned ->
      Alcotest.(check string) "a stray value is a second QUERY"
        "search takes exactly one QUERY"
        (match Extract.search_body scanned with Error m -> m | Ok _ -> "accepted")
  | Error message ->
      Alcotest.(check string) "a stray value is a second QUERY"
        "search takes exactly one QUERY" message);
  match Extract.scan_args [ "qq"; "--safe-search=true" ] with
  | Error message ->
      Alcotest.(check string) "an inline value is refused" "--safe-search takes no value" message
  | Ok _ -> Alcotest.fail "an explicit value for a boolean flag was accepted"

let test_search_safe_search_bare () =
  let body = search "qq" ~extra:[ "--safe-search" ] in
  match body with
  | `Assoc fields ->
      Alcotest.(check bool) "safe_search is true" true
        (match List.assoc_opt "safe_search" fields with Some (`Bool true) -> true | _ -> false)
  | _ -> Alcotest.fail "not an object"

let test_search_domains_repeat () =
  (* A repeated flag is a list only where the request says the field is a
     list. *)
  let body =
    search "qq" ~extra:[ "--include-domain"; "a.org"; "--include-domain"; "b.org"; "--exclude-domain"; "c.org" ]
  in
  (match body with
  | `Assoc fields ->
      Alcotest.(check (list string)) "include_domains" [ "a.org"; "b.org" ]
        (match List.assoc_opt "include_domains" fields with
        | Some (`List items) -> List.map (fun x -> match x with `String s -> s | _ -> "") items
        | _ -> []);
      Alcotest.(check (list string)) "exclude_domains" [ "c.org" ]
        (match List.assoc_opt "exclude_domains" fields with
        | Some (`List items) -> List.map (fun x -> match x with `String s -> s | _ -> "") items
        | _ -> [])
  | _ -> Alcotest.fail "not an object")

let test_search_unset_fields_absent () =
  (* exclude_none: a field the caller did not pass is absent from the body,
     never present as null. *)
  let body = search "qq" in
  List.iter
    (fun key ->
      Alcotest.(check bool) (key ^ " absent") false (has key body))
    [ "provider"; "include_domains"; "exclude_domains"; "recency"; "language"; "safe_search" ]

let test_search_recency_values () =
  List.iter
    (fun r ->
      let body = search "qq" ~extra:[ "--recency"; r ] in
      Alcotest.(check string) ("recency " ^ r) r (Option.value ~default:"" (str "recency" body)))
    [ "day"; "week"; "month"; "year" ]

let test_fetch_minimal () =
  body_equals ~label:"fetch url only" (fetch "http://x.example/a")
    [ ("url", `String "http://x.example/a") ]

let test_fetch_all_fields () =
  let body =
    fetch "http://x.example/a"
      ~extra:[ "--query"; "budget"; "--offset"; "4000"; "--path"; ".results[]"; "--structure"; "--provider"; "jina" ]
  in
  Alcotest.(check string) "query" "budget" (Option.value ~default:"" (str "query" body));
  Alcotest.(check bool) "offset 4000" true
    (match int_field "offset" body with Some 4000 -> true | _ -> false);
  Alcotest.(check string) "path" ".results[]" (Option.value ~default:"" (str "path" body));
  let structure_true body =
    match body with
    | `Assoc f -> ( match List.assoc_opt "structure" f with Some (`Bool true) -> true | _ -> false)
    | _ -> false
  in
  Alcotest.(check bool) "structure true" true (structure_true body);
  Alcotest.(check string) "provider" "jina" (Option.value ~default:"" (str "provider" body))

let test_fetch_structure_absent_when_unset () =
  Alcotest.(check bool) "structure absent" false (has "structure" (fetch "http://x.example/a"))

let test_answer_extra_queries_repeat () =
  let body =
    answer "why" ~extra:[ "--extra-query"; "because"; "--extra-query"; "since"; "--depth"; "report" ]
  in
  Alcotest.(check string) "depth" "report" (Option.value ~default:"" (str "depth" body));
  Alcotest.(check (list string)) "extra_queries" [ "because"; "since" ]
    (match body with
    | `Assoc fields -> (
        match List.assoc_opt "extra_queries" fields with
        | Some (`List items) -> List.map (fun x -> match x with `String s -> s | _ -> "") items
        | _ -> [])
    | _ -> [])

(* {1 Invalid commands — the usage sentences} *)

let test_needs_a_query () =
  match Extract.scan_args [] with
  | Error message -> Alcotest.(check string) "sentence" "search needs a QUERY" message
  | Ok scanned -> (
      match Extract.search_body scanned with
      | Error message -> Alcotest.(check string) "sentence" "search needs a QUERY" message
      | Ok _ -> Alcotest.fail "an empty search was accepted")

let test_exactly_one_query () =
  match Extract.scan_args [ "one"; "two" ] with
  | Error message ->
      Alcotest.(check string) "sentence" "search takes exactly one QUERY" message
  | Ok scanned -> (
      match Extract.search_body scanned with
      | Error message ->
          Alcotest.(check string) "sentence" "search takes exactly one QUERY" message
      | Ok _ -> Alcotest.fail "two queries were accepted")

let test_bad_recency () =
  match Extract.scan_args [ "qq"; "--recency"; "fortnight" ] with
  | Error message ->
      Alcotest.(check string) "sentence" "--recency needs day, week, month or year" message
  | Ok scanned -> (
      match Extract.search_body scanned with
      | Error message ->
          Alcotest.(check string) "sentence" "--recency needs day, week, month or year" message
      | Ok _ -> Alcotest.fail "a bogus recency was accepted")

let test_bad_max_results () =
  match Extract.scan_args [ "qq"; "--max-results"; "many" ] with
  | Error message -> Alcotest.(check string) "sentence" "--max-results needs a number" message
  | Ok scanned -> (
      match Extract.search_body scanned with
      | Error message ->
          Alcotest.(check string) "sentence" "--max-results needs a number" message
      | Ok _ -> Alcotest.fail "a non-numeric max-results was accepted")

let test_flag_needs_value () =
  match Extract.scan_args [ "--provider" ] with
  | Error message -> Alcotest.(check string) "sentence" "--provider needs a value" message
  | Ok _ -> Alcotest.fail "a flag left without its value was accepted"

let test_bad_depth () =
  match Extract.scan_args [ "qq"; "--depth"; "deep" ] with
  | Error message -> Alcotest.(check string) "sentence" "--depth needs brief or report" message
  | Ok scanned -> (
      match Extract.answer_body scanned with
      | Error message -> Alcotest.(check string) "sentence" "--depth needs brief or report" message
      | Ok _ -> Alcotest.fail "a bogus depth was accepted")

let test_negative_offset_refused () =
  (* the request model is the validator: the CLI never sends a body the REST
     route would refuse. *)
  match Extract.scan_args [ "http://x.example"; "--offset"; "-1" ] with
  | Error message ->
      Alcotest.(check bool) ("refused: " ^ message) true (String.length message > 0)
  | Ok scanned -> (
      match Extract.fetch_body scanned with
      | Error message ->
          Alcotest.(check bool) ("refused: " ^ message) true (String.length message > 0)
      | Ok _ -> Alcotest.fail "a negative offset was accepted")

let () =
  Alcotest.run "cli extract"
    [
      ( "valid commands",
        [
          Alcotest.test_case "search: query only" `Quick test_search_query_only;
          Alcotest.test_case "search: flags become fields" `Quick test_search_flag_becomes_field;
          Alcotest.test_case "search: --flag=value" `Quick test_search_inline_equals;
          Alcotest.test_case "search: --no-safe-search" `Quick test_search_no_safe_search;
          Alcotest.test_case "search: --safe-search fills the field" `Quick test_search_safe_search_bare;
          Alcotest.test_case "search: --safe-search takes no value" `Quick test_search_safe_search_takes_no_value;
          Alcotest.test_case "search: repeated domain flags" `Quick test_search_domains_repeat;
          Alcotest.test_case "search: unset fields absent" `Quick test_search_unset_fields_absent;
          Alcotest.test_case "search: recency values" `Quick test_search_recency_values;
          Alcotest.test_case "fetch: url only" `Quick test_fetch_minimal;
          Alcotest.test_case "fetch: every field" `Quick test_fetch_all_fields;
          Alcotest.test_case "fetch: structure only when true" `Quick test_fetch_structure_absent_when_unset;
          Alcotest.test_case "answer: extra queries and depth" `Quick test_answer_extra_queries_repeat;
        ] );
      ( "usage errors",
        [
          Alcotest.test_case "needs a QUERY" `Quick test_needs_a_query;
          Alcotest.test_case "exactly one QUERY" `Quick test_exactly_one_query;
          Alcotest.test_case "bad recency" `Quick test_bad_recency;
          Alcotest.test_case "bad max-results" `Quick test_bad_max_results;
          Alcotest.test_case "flag needs a value" `Quick test_flag_needs_value;
          Alcotest.test_case "bad depth" `Quick test_bad_depth;
          Alcotest.test_case "model validates the body" `Quick test_negative_offset_refused;
        ] );
    ]
