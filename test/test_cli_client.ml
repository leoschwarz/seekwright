(* The client verbs around the wire: status handling, the error sentence, the
   rendering, and the exit codes. Everything here runs against an injected
   [post] — the executable suite ([bin/]) covers the real socket; this one
   covers every branch around it, including the response that is not a
   [SearchResponse] and the [--json] echo. *)

module Client = Cli_client
module Model = Seekwright.Model

let result_t =
  Alcotest.testable
    (fun fmt v ->
      Format.pp_print_string fmt
        (match v with
        | Ok None -> "ok, no output"
        | Ok (Some line) -> "ok: " ^ line
        | Error (sentence, code) -> Printf.sprintf "error %d: %s" code sentence))
    ( = )


(* A fake transport: it records what it was asked to post and answers with a
   canned [(status, text)]. *)
type tape = { mutable calls : (string * string) list; answer : (int * string, string) result }

let post_of tape ~path body =
  tape.calls <- (path, body) :: tape.calls;
  tape.answer

let run ?(answer = Ok (200, "{}")) ~json ~argv verb =
  (* [--json] is the verb's flag, so it rides in [argv]: [Cli_client.run] reads
     it from the scan, exactly as the binary's caller does. *)
  let argv = if json then argv @ [ "--json" ] else argv in
  let tape = { calls = []; answer } in
  let result = Client.run ~post:(post_of tape) ~verb ~argv in
  (result, List.rev tape.calls)

(* {1 The request goes to the right route} *)

let body_for route =
  match route with
  | "search" -> {j|{"query":"q","provider":"p","results":[]}|j}
  | "fetch" -> {j|{"url":"http://x.example","requested_url":"http://x.example"}|j}
  | _ -> {j|{"query":"q","model":"m","depth":"brief","searches":1,"fetched":0,"answer":"a","sources":[]}|j}

let test_routes () =
  let cases =
    [
      (Client.Search, "search", body_for "search");
      (Client.Fetch, "fetch", body_for "fetch");
      (Client.Answer, "answer", body_for "answer");
    ]
  in
  List.iter
    (fun (verb, route, body) ->
      (* The argv has to be a body this verb's request model accepts: the
         client validates before it posts, and a refusal would never reach the
         route under test. *)
      let argv =
        match verb with
        | Client.Fetch -> [ "http://x.example/a" ]
        | _ -> [ "qq" ]
      in
      let tape = { calls = []; answer = Ok (200, body) } in
      let result = Client.run ~post:(post_of tape) ~verb ~argv:(argv @ [ "--json" ]) in
      Alcotest.(check result_t) ("verb " ^ route) (Ok (Some body)) result;
      match tape.calls with
      | [ (path, _) ] ->
          Alcotest.(check string) "route" ("http://127.0.0.1:8000/api/v1/" ^ route) path
      | _ -> Alcotest.fail "expected exactly one call")
    cases

let test_server_flag_sets_origin () =
  List.iteri
    (fun _i (server, want) ->
      let tape = { calls = []; answer = Ok (200, body_for "search") } in
      let _ =
        Client.run ~post:(post_of tape) ~verb:Client.Search
          ~argv:[ "qq"; "--server"; server ]
      in
      match tape.calls with
      | [ (path, _) ] -> Alcotest.(check string) server (want ^ "/api/v1/search") path
      | _ -> Alcotest.fail "expected exactly one call")
    [
      ("http://box:9000", "http://box:9000");
      ("http://box:9000/", "http://box:9000");
      ("http://box:9000//", "http://box:9000/");
    ]

(* {1 Status handling — TestClientExitCodes} *)

let test_http_error_becomes_sentence_exit_1 () =
  let answer = Ok (400, {j|{"error":"provider exa is not enabled on this deployment"}|j}) in
  let result, _ = run ~answer ~json:false ~argv:[ "qq"; "--provider"; "exa" ] Client.Search in
  Alcotest.(check result_t)
    "the server's error sentence travels"
    (Error ("HTTP 400: provider exa is not enabled on this deployment", 1))
    result

let test_non_json_error_body () =
  let answer = Ok (502, "bad gateway") in
  let result, _ = run ~answer ~json:false ~argv:[ "qq" ] Client.Search in
  Alcotest.(check result_t) "trimmed body" (Error ("HTTP 502: bad gateway", 1)) result

let test_empty_error_body () =
  let answer = Ok (500, "") in
  let result, _ = run ~answer ~json:false ~argv:[ "qq" ] Client.Search in
  Alcotest.(check result_t) "just the status" (Error ("HTTP 500", 1)) result

let test_transport_failure_exit_1 () =
  let answer = Error "connection refused" in
  let result, _ = run ~answer ~json:false ~argv:[ "qq" ] Client.Search in
  Alcotest.(check result_t) "connection refused" (Error ("connection refused", 1)) result

let test_usage_error_exits_2 () =
  (* a malformed command never reaches the socket: exit 2, and no call. *)
  let result, calls = run ~json:false ~argv:[ "q"; "extra" ] Client.Search in
  Alcotest.(check result_t) "usage error" (Error ("search takes exactly one QUERY", 2)) result;
  Alcotest.(check int) "no request was sent" 0 (List.length calls)

(* {1 Rendering — TestClientSearch/Fetch/Answer's human output} *)

let search_json =
  {|{"query":"open data","provider":"exa:free","results":[{"title":"First","url":"http://a.example","snippet":"line one\nline two"},{"title":"Second","url":"http://b.example","text":"body text"}],"notice":"exa fell back to its free tier"}|}

let test_human_search () =
  let answer = Ok (200, search_json) in
  let result, _ = run ~answer ~json:false ~argv:[ "open data" ] Client.Search in
  match result with
  | Ok (Some text) ->
      let lines = String.split_on_char '\n' text in
      Alcotest.(check (list string))
        "the human layout"
        [
          "seekwright search";
          "=================";
          "query     open data";
          "provider  exa:free";
          "results   2";
          "";
          "1. First";
          "   http://a.example";
          "   line one";
          "   line two";
          "";
          "2. Second";
          "   http://b.example";
          "   body text";
          "";
          "notice: exa fell back to its free tier";
        ]
        lines
  | _ -> Alcotest.fail "expected a rendered search"

let test_json_echo_verbatim () =
  (* [--json] echoes the response text byte for byte, not a re-serialisation. *)
  let answer = Ok (200, search_json) in
  let result, _ = run ~answer ~json:true ~argv:[ "qq" ] Client.Search in
  Alcotest.(check result_t) "verbatim" (Ok (Some search_json)) result

let test_unparsable_success_exit_1 () =
  let answer = Ok (200, {j|{"surprise":true}|j}) in
  let result, _ = run ~answer ~json:false ~argv:[ "qq" ] Client.Search in
  Alcotest.(check result_t) "not a SearchResponse"
    (Error ("the response is not a SearchResponse", 1)) result

let test_human_fetch_with_matches () =
  let body =
    {|{"url":"http://x.example","requested_url":"http://x.example","title":"T","text":"the page","total_chars":7,"truncated":true,"matches":[{"offset":2,"text":"he"}],"notice":"fallback jina"}|}
  in
  let answer = Ok (200, body) in
  let result, _ = run ~answer ~json:false ~argv:[ "http://x.example" ] Client.Fetch in
  match result with
  | Ok (Some text) ->
      List.iter
        (fun needle ->
          Alcotest.(check bool) (needle ^ " rendered") true
            (try
               ignore (Str.search_forward (Str.regexp_string needle) text 0);
               true
             with Not_found -> false))
        [ "seekwright fetch"; "chars     7, truncated"; "match at 2:"; "notice: fallback jina" ]
  | _ -> Alcotest.fail "expected a rendered fetch"

let test_human_answer_sources () =
  let body =
    {|{"query":"why","model":"m","depth":"report","searches":3,"fetched":2,"answer":"because.","truncated":true,"sources":[{"title":"S","url":"http://s","provider":"exa"}]}|}
  in
  let answer = Ok (200, body) in
  let result, _ = run ~answer ~json:false ~argv:[ "why" ] Client.Answer in
  match result with
  | Ok (Some text) ->
      Alcotest.(check bool) "truncation sentence" true
        (try
           ignore (Str.search_forward (Str.regexp_string "stopped at the model's output cap") text 0);
           true
         with Not_found -> false);
      Alcotest.(check bool) "sources rendered" true
        (try
           ignore (Str.search_forward (Str.regexp_string "1. S") text 0);
           true
         with Not_found -> false)
  | _ -> Alcotest.fail "expected a rendered answer"

(* {1 No config, no provider, no key — TestClientHoldsNoSecrets} *)

let test_client_names_no_config_or_keys () =
  (* the client library's own source: it dials a URL and nothing else. It
     never reads a provider key or a config file. *)
  let source = Test_support.read_file "../lib/cli/cli_client.ml" in
  List.iter
    (fun forbidden ->
      Alcotest.(check bool) ("the client never touches " ^ forbidden) false
        (try
           ignore (Str.search_forward (Str.regexp_string forbidden) source 0);
           true
         with Not_found -> false))
    [ "SEEKWRIGHT_"; "Config.load"; "api_key"; "history_path" ]

let () =
  Alcotest.run "cli client"
    [
      ( "routing",
        [
          Alcotest.test_case "each verb posts to its route" `Quick test_routes;
          Alcotest.test_case "--server sets the origin, trailing slash dropped" `Quick test_server_flag_sets_origin;
        ] );
      ( "status handling",
        [
          Alcotest.test_case "400 carries the server's sentence" `Quick test_http_error_becomes_sentence_exit_1;
          Alcotest.test_case "non-JSON error body" `Quick test_non_json_error_body;
          Alcotest.test_case "empty error body" `Quick test_empty_error_body;
          Alcotest.test_case "transport failure exits 1" `Quick test_transport_failure_exit_1;
          Alcotest.test_case "usage error exits 2 without dialling" `Quick test_usage_error_exits_2;
        ] );
      ( "rendering",
        [
          Alcotest.test_case "human search layout" `Quick test_human_search;
          Alcotest.test_case "--json echoes verbatim" `Quick test_json_echo_verbatim;
          Alcotest.test_case "unparsable success exits 1" `Quick test_unparsable_success_exit_1;
          Alcotest.test_case "human fetch with matches" `Quick test_human_fetch_with_matches;
          Alcotest.test_case "human answer with sources" `Quick test_human_answer_sources;
        ] );
      ( "holds no secrets",
        [ Alcotest.test_case "no config, keys or journal in the client" `Quick test_client_names_no_config_or_keys ] );
    ]
