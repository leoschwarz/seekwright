(* Port of tests/test_models.py: the wire shapes and the absent-field rule.

   The Python oracle is pydantic; the cases here assert the same observable
   JSON. An OCaml record's arity is the field-list guard, so the Python
   [model_fields] checks become key-set assertions on the encoder's output. *)

module M = Seekwright.Model

let member name = function
  | `Assoc kvs -> List.assoc_opt name kvs
  | _ -> None

let member_exn name json =
  match member name json with
  | Some value -> value
  | None -> Alcotest.fail (Printf.sprintf "missing member %S" name)

let string_member name json =
  match member_exn name json with
  | `String s -> s
  | _ -> Alcotest.fail (Printf.sprintf "member %S is not a string" name)

let object_keys json =
  match json with
  | `Assoc kvs -> List.map fst kvs
  | _ -> Alcotest.fail "expected an object"

let check_keys label expected json =
  Alcotest.(check (list string)) label (List.sort compare expected)
    (List.sort compare (object_keys json))

let check_bool_member label expected json =
  match member_exn label json with
  | `Bool b -> Alcotest.(check bool) label expected b
  | _ -> Alcotest.fail (Printf.sprintf "member %S is not a boolean" label)

let check_int_member label expected json =
  match member_exn label json with
  | `Int i -> Alcotest.(check int) label expected i
  | _ -> Alcotest.fail (Printf.sprintf "member %S is not an integer" label)

let check_absent name json =
  Alcotest.(check bool) ("no " ^ name) true (member name json = None)

let mk_result ?snippet ?text ?text_truncated ?published_date ?score ~title ~url ()
    : M.result =
  { M.title; url; snippet; text; text_truncated; published_date; score }

let mk_search_response ?answer ?retrieved_at ?notice ~query ~provider ~results ()
    : M.search_response =
  { M.query; provider; results; answer; retrieved_at; notice }

let mk_fetch_response ?title ?text ?content_type ?status_code ?retrieved_at
    ?(truncated = false) ?total_chars ?offset ?matches ?image ?notice ~url
    ~requested_url () : M.fetch_response =
  {
    M.url;
    requested_url;
    title;
    text;
    content_type;
    status_code;
    retrieved_at;
    truncated;
    total_chars;
    offset;
    matches;
    image;
    notice;
  }

let test_a_body_that_would_need_escaping_is_left_whole () =
  let base64 = "PHxlbmRvZnRleHR8Pg==" in
  let response =
    mk_fetch_response ~url:"https://e.com/a.png"
      ~requested_url:"https://e.com/a.png" ~content_type:"image/png"
      ~image:{ M.byte_count = 13; base64 }
      ()
  in
  let json = M.fetch_response_to_yojson response in
  let image = member_exn "image" json in
  Alcotest.(check (list string)) "image fields" [ "base64"; "byte_count" ]
    (List.sort compare (object_keys image));
  check_int_member "byte_count" 13 image;
  Alcotest.(check string) "base64 untouched" base64 (string_member "base64" image)

let test_the_image_carries_no_media_type_of_its_own () =
  let json = M.fetch_image_to_yojson { M.byte_count = 1; base64 = "AA==" } in
  check_keys "image carries exactly its two fields" [ "byte_count"; "base64" ]
    json

let test_a_result_omits_what_it_has_no_value_for () =
  let json = M.result_to_yojson (mk_result ~title:"t" ~url:"https://e.com" ~text:"x" ()) in
  check_keys "result fields" [ "title"; "url"; "text" ] json;
  Alcotest.(check string) "title" "t" (string_member "title" json);
  Alcotest.(check string) "url" "https://e.com" (string_member "url" json);
  Alcotest.(check string) "text" "x" (string_member "text" json)

let test_a_set_field_survives () =
  let json =
    M.result_to_yojson
      (mk_result ~title:"t" ~url:"https://e.com" ~text:"x" ~text_truncated:true ())
  in
  check_bool_member "text_truncated" true json

let test_false_is_not_absent () =
  let json =
    M.fetch_response_to_yojson
      (mk_fetch_response ~url:"https://e.com" ~requested_url:"https://e.com"
         ~text:"t" ())
  in
  check_bool_member "truncated" false json

let test_a_plain_fetch_serialises_exactly_as_it_did () =
  let json =
    M.fetch_response_to_yojson
      (mk_fetch_response ~url:"https://e.com" ~requested_url:"https://e.com"
         ~text:"t" ())
  in
  check_absent "offset" json;
  check_absent "matches" json

let test_an_image_is_absent_until_there_is_one () =
  let json =
    M.fetch_response_to_yojson
      (mk_fetch_response ~url:"https://e.com" ~requested_url:"https://e.com"
         ~text:"t" ())
  in
  check_absent "image" json

let test_matches_carry_the_content_without_text () =
  let json =
    M.fetch_response_to_yojson
      (mk_fetch_response ~url:"https://e.com" ~requested_url:"https://e.com"
         ~matches:[ { M.offset = 300; text = "the matching passage" } ]
         ~total_chars:40_000 ())
  in
  check_absent "text" json;
  let matches = match member_exn "matches" json with `List l -> l | _ -> [] in
  Alcotest.(check int) "one match" 1 (List.length matches);
  let match_ = List.hd matches in
  check_int_member "offset" 300 match_;
  Alcotest.(check string) "text" "the matching passage" (string_member "text" match_)

let test_a_non_zero_offset_is_echoed () =
  let json =
    M.fetch_response_to_yojson
      (mk_fetch_response ~url:"https://e.com" ~requested_url:"https://e.com"
         ~text:"t" ~offset:40_000 ())
  in
  check_int_member "offset" 40_000 json

let test_the_rule_reaches_nested_results () =
  let response =
    mk_search_response ~query:"q" ~provider:"exa"
      ~results:[ mk_result ~title:"t" ~url:"https://e.com" () ]
      ()
  in
  let json = M.search_response_to_yojson response in
  check_absent "answer" json;
  let results = match member_exn "results" json with `List l -> l | _ -> [] in
  check_keys "nested result" [ "title"; "url" ] (List.hd results)

let test_the_constraint_set_is_exactly_these_eight_fields () =
  let json =
    match M.search_query_of_yojson (`Assoc [ ("query", `String "q") ]) with
    | Ok query -> M.search_query_to_yojson query
    | Error e -> Alcotest.fail ("decode failed: " ^ e)
  in
  check_keys "search_query fields"
    [
      "query";
      "max_results";
      "include_domains";
      "exclude_domains";
      "country";
      "language";
      "recency";
      "safe_search";
    ]
    json

let test_locale_is_gone_rather_than_kept_beside_language () =
  (* A plain pydantic model ignores an extra key; what matters is that the
     record has no second field for the same wire parameter and that the
     encoder cannot emit one. *)
  let query =
    match
      M.search_query_of_yojson
        (`Assoc [ ("query", `String "q"); ("locale", `String "de-DE") ])
    with
    | Ok query -> query
    | Error e -> Alcotest.fail ("decode failed: " ^ e)
  in
  let json = M.search_query_to_yojson query in
  Alcotest.(check bool) "no locale" false (List.mem "locale" (object_keys json));
  Alcotest.(check (option string)) "language still None" None query.language

let test_language_defaults_to_none () =
  match M.search_query_of_yojson (`Assoc [ ("query", `String "q") ]) with
  | Ok query -> Alcotest.(check (option string)) "language" None query.language
  | Error e -> Alcotest.fail ("decode failed: " ^ e)

let test_safe_search_carries_all_three_states () =
  List.iter
    (fun (json, expected) ->
      let query =
        match
          M.search_query_of_yojson (`Assoc (("query", `String "q") :: json))
        with
        | Ok query -> query
        | Error e -> Alcotest.fail ("decode failed: " ^ e)
      in
      Alcotest.(check (option bool)) "safe_search" expected query.safe_search;
      let encoded = M.search_query_to_yojson query in
      match (expected, member_exn "safe_search" encoded) with
      | None, `Null -> ()
      | Some value, `Bool b -> Alcotest.(check bool) "encoded" value b
      | _ -> Alcotest.fail "safe_search encoded wrongly")
    [
      ([ ("safe_search", `Bool true) ], Some true);
      ([ ("safe_search", `Bool false) ], Some false);
      ([], None);
    ]

let test_safe_search_defaults_to_none_not_false () =
  match M.search_query_of_yojson (`Assoc [ ("query", `String "q") ]) with
  | Ok query ->
      Alcotest.(check (option bool)) "safe_search" None query.safe_search
  | Error e -> Alcotest.fail ("decode failed: " ^ e)

let test_a_name_the_tree_has_never_heard_of_survives_the_body () =
  match
    M.fetch_request_of_yojson
      (`Assoc [ ("url", `String "https://e.com/a"); ("provider", `String "scraper") ])
  with
  | Ok request ->
      Alcotest.(check (option string)) "provider" (Some "scraper")
        request.provider
  | Error e -> Alcotest.fail ("decode failed: " ^ e)

let test_the_provider_field_is_a_string () =
  match
    M.fetch_request_of_yojson
      (`Assoc [ ("url", `String "https://e.com/a"); ("provider", `Int 5) ])
  with
  | Ok _ -> Alcotest.fail "a non-string provider was accepted"
  | Error _ -> ()

let test_an_omitted_provider_stays_out_of_the_body () =
  match
    M.fetch_request_of_yojson (`Assoc [ ("url", `String "https://e.com/a") ])
  with
  | Ok request ->
      Alcotest.(check (option string)) "provider" None request.provider;
      let json = M.fetch_request_to_yojson request in
      check_absent "provider" json
  | Error e -> Alcotest.fail ("decode failed: " ^ e)

let test_a_wire_model_refuses_an_unknown_key () =
  match
    M.result_of_yojson
      (`Assoc [ ("title", `String "t"); ("url", `String "u"); ("extra", `Null) ])
  with
  | Ok _ -> Alcotest.fail "an extra key was accepted"
  | Error _ -> ()

let round_trip label decode encode value =
  let first = encode value in
  match decode first with
  | Error e -> Alcotest.fail (label ^ ": decode failed: " ^ e)
  | Ok decoded ->
      let second = encode decoded in
      Alcotest.(check bool) (label ^ ": round trip") true
        (Yojson.Safe.equal first second)

let test_request_round_trips () =
  round_trip "search_request" M.search_request_of_yojson
    M.search_request_to_yojson
    {
      M.query = "wire models";
      provider = Some "exa:free";
      mode = Some M.Free;
      max_results = 7;
      include_domains = Some [ "example.com" ];
      exclude_domains = Some [ "spam.example" ];
      recency = Some M.Week;
      language = Some "en";
      safe_search = Some false;
    };
  round_trip "fetch_request" M.fetch_request_of_yojson M.fetch_request_to_yojson
    {
      M.url = "https://e.com/a";
      offset = Some 10;
      query = Some "passage";
      path = Some "$.items[0]";
      structure = true;
      provider = Some "crawl4ai";
    };
  round_trip "answer_request" M.answer_request_of_yojson
    M.answer_request_to_yojson
    {
      M.query = "wire models";
      extra_queries = Some [ "sanitize pass"; "pydantic rules" ];
      depth = Some M.Report;
      provider = Some "exa";
      include_domains = Some [ "example.com" ];
      exclude_domains = None;
      recency = Some M.Day;
      language = Some "en";
      safe_search = None;
    }

let test_response_round_trips () =
  round_trip "fetch_response" M.fetch_response_of_yojson
    M.fetch_response_to_yojson
    (mk_fetch_response ~url:"https://e.com" ~requested_url:"https://e.com/a"
       ~title:"t" ~text:"body" ~content_type:"text/html" ~status_code:200
       ~retrieved_at:"2026-11-11T00:00:00Z" ~truncated:true ~total_chars:1000
       ~offset:10
       ~matches:[ { M.offset = 1; text = "match" } ]
       ~image:{ M.byte_count = 3; base64 = "AA==" }
       ~notice:"n" ());
  round_trip "answer_response" M.answer_response_of_yojson
    M.answer_response_to_yojson
    {
      M.query = "q";
      answer = "a";
      sources =
        [
          { M.source_title = "t"; source_url = "https://e.com"; source_provider = "p" };
        ];
      model = "m";
      depth = M.Brief;
      searches = 2;
      fetched = 1;
      retrieved_at = Some "2026-11-11T00:00:00Z";
      truncated = Some false;
      notice = Some "n";
    };
  round_trip "provider_result" M.provider_result_of_yojson
    M.provider_result_to_yojson
    {
      M.provider = "exa";
      results = [ mk_result ~title:"t" ~url:"https://e.com" ~score:0.5 () ];
      answer = Some "a";
      cost_usd = Some 0.002;
      notice = None;
    }

let test_a_minimal_body_drops_unset_fields () =
  let request =
    match M.search_request_of_yojson (`Assoc [ ("query", `String "ab") ]) with
    | Ok value -> value
    | Error e -> Alcotest.fail ("decode failed: " ^ e)
  in
  Alcotest.(check int) "default max_results" 5 request.max_results;
  check_keys "only the default and the query" [ "query"; "max_results" ]
    (M.search_request_to_yojson request)

let test_a_too_short_query_is_refused () =
  match M.search_request_of_yojson (`Assoc [ ("query", `String "a") ]) with
  | Ok _ -> Alcotest.fail "a one-character query was accepted"
  | Error _ -> ()

let test_an_explicit_null_is_not_a_default () =
  (* pydantic's non-optional defaults: absent means the default, null is an
     error. Treating null as absent would silently accept a body pydantic
     refuses. *)
  (match
     M.fetch_request_of_yojson
       (`Assoc [ ("url", `String "https://e.com/a"); ("structure", `Null) ])
   with
  | Ok _ -> Alcotest.fail "null structure was accepted"
  | Error _ -> ());
  match
    M.search_query_of_yojson
      (`Assoc [ ("query", `String "q"); ("max_results", `Null) ])
  with
  | Ok _ -> Alcotest.fail "null max_results was accepted"
  | Error _ -> ()

let () =
  Alcotest.run "model"
    [
      ( "FetchImage",
        [
          Alcotest.test_case "a body that would need escaping is left whole"
            `Quick test_a_body_that_would_need_escaping_is_left_whole;
          Alcotest.test_case "the image carries no media type of its own" `Quick
            test_the_image_carries_no_media_type_of_its_own;
        ] );
      ( "AbsentFieldsAreDropped",
        [
          Alcotest.test_case "a result omits what it has no value for" `Quick
            test_a_result_omits_what_it_has_no_value_for;
          Alcotest.test_case "a set field survives" `Quick
            test_a_set_field_survives;
          Alcotest.test_case "false is not absent" `Quick test_false_is_not_absent;
          Alcotest.test_case "a plain fetch serialises exactly as it did" `Quick
            test_a_plain_fetch_serialises_exactly_as_it_did;
          Alcotest.test_case "an image is absent until there is one" `Quick
            test_an_image_is_absent_until_there_is_one;
          Alcotest.test_case "matches carry the content without text" `Quick
            test_matches_carry_the_content_without_text;
          Alcotest.test_case "a non-zero offset is echoed" `Quick
            test_a_non_zero_offset_is_echoed;
          Alcotest.test_case "the rule reaches nested results" `Quick
            test_the_rule_reaches_nested_results;
          Alcotest.test_case "a wire model refuses an unknown key" `Quick
            test_a_wire_model_refuses_an_unknown_key;
        ] );
      ( "SearchQuery",
        [
          Alcotest.test_case "the constraint set is exactly these eight fields"
            `Quick test_the_constraint_set_is_exactly_these_eight_fields;
          Alcotest.test_case "locale is gone rather than kept beside language"
            `Quick test_locale_is_gone_rather_than_kept_beside_language;
          Alcotest.test_case "language defaults to None" `Quick
            test_language_defaults_to_none;
          Alcotest.test_case "safe_search carries all three states" `Quick
            test_safe_search_carries_all_three_states;
          Alcotest.test_case "safe_search defaults to None, not false" `Quick
            test_safe_search_defaults_to_none_not_false;
        ] );
      ( "FetchRequestProvider",
        [
          Alcotest.test_case "a name the tree has never heard of survives" `Quick
            test_a_name_the_tree_has_never_heard_of_survives_the_body;
          Alcotest.test_case "the provider field is a string" `Quick
            test_the_provider_field_is_a_string;
          Alcotest.test_case "an omitted provider stays out of the body" `Quick
            test_an_omitted_provider_stays_out_of_the_body;
        ] );
      ( "RoundTrip",
        [
          Alcotest.test_case "request bodies round trip" `Quick
            test_request_round_trips;
          Alcotest.test_case "response bodies round trip" `Quick
            test_response_round_trips;
          Alcotest.test_case "a minimal body drops unset fields" `Quick
            test_a_minimal_body_drops_unset_fields;
          Alcotest.test_case "a too-short query is refused" `Quick
            test_a_too_short_query_is_refused;
          Alcotest.test_case "an explicit null is not a default" `Quick
            test_an_explicit_null_is_not_a_default;
        ] );
    ]
