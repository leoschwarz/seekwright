(* The extract cases: the request body with its clamped vendor timeout, the 429
   {i and} 432 quota arms, and the empty-[results] reading that keeps the ladder
   walking. *)

module Caps = Mcp_caps
module Tavily = Seekwright_fetch.Fallback_tavily
module Fix = Fallback_fixtures

let cfg ?(timeout_seconds = 30.) fixture =
  {
    Tavily.net = Fix.net fixture;
    check = Fix.check ();
    max_text_chars = 40_000;
    api_key = "tv-test";
    timeout_seconds;
  }

let run ?(timeout_seconds = 30.) ?(status = 200) body =
  let fixture = Fix.make [ Fix.Response (status, body) ] in
  (fixture, Tavily.fetch (cfg ~timeout_seconds fixture) Fix.public_url ~offset:0 ~max_chars:None)

let request_shape () =
  let fixture, result =
    run {|{"results":[{"raw_content":"page text","url":"https://public.test/landed"}]}|}
  in
  let page = Fix.ok_page result "ok" in
  Fix.check_request fixture
    {
      Fix.meth = `POST;
      uri = "https://api.tavily.com/extract";
      headers = [ ("Authorization", "Bearer tv-test") ];
      (* One URL, markdown, [basic] depth — the dearer depth doubles the
         credit — and the vendor's own bound at 30. s. *)
      body =
        Some
          {|{"urls":["https://public.test/page"],"format":"markdown","extract_depth":"basic","timeout":30.0}|};
    };
  Alcotest.(check string) "text" page.Seekwright_wire.Page.text "page text";
  Alcotest.(check string) "entry url" page.url "https://public.test/landed";
  Alcotest.(check (option string)) "extract reports no title" page.title None

let timeout_clamp () =
  let body_of seconds =
    let fixture, _ = run ~timeout_seconds:seconds "{}" in
    match Fix.requests fixture with [ only ] -> Option.value ~default:"" only.body | _ -> ""
  in
  (* The vendor accepts 1–60 s; the operator's knob may sit outside it. *)
  Alcotest.(check string)
    "clamped to 60" (body_of 120.)
    {|{"urls":["https://public.test/page"],"format":"markdown","extract_depth":"basic","timeout":60.0}|};
  Alcotest.(check string)
    "floored at 1" (body_of 0.5)
    {|{"urls":["https://public.test/page"],"format":"markdown","extract_depth":"basic","timeout":1.0}|}

let arms () =
  let one status = Fix.show_error (Result.get_error (snd (run ~status "{}"))) in
  Alcotest.(check string)
    "401 is the key" (one 401)
    (Fix.error_case ~kind:"rejected" ~message:"authentication rejected (check API key)");
  Alcotest.(check string)
    "403 is the key" (one 403)
    (Fix.error_case ~kind:"rejected" ~message:"authentication rejected (check API key)");
  (* 432 is this vendor's monthly-credits-exhausted code, the same reading
     the search adapter on this key takes. *)
  Alcotest.(check string)
    "429" (one 429)
    (Fix.error_case ~kind:"quota" ~message:"rate limited or out of credits");
  Alcotest.(check string)
    "432" (one 432)
    (Fix.error_case ~kind:"quota" ~message:"rate limited or out of credits");
  Alcotest.(check string) "500" (one 500) (Fix.error_case ~kind:"failed" ~message:"HTTP 500");
  let fixture = Fix.make [] in
  Alcotest.(check string)
    "private target"
    (Fix.show_error
       (Result.get_error
          (Tavily.fetch (cfg fixture) "https://internal.test/x" ~offset:0 ~max_chars:None)))
    (Fix.error_case ~kind:"url_blocked"
       ~message:
         "internal.test resolves to a non-public address (127.0.0.1); fetching private, loopback \
          and link-local addresses is disabled");
  Fix.check_no_request fixture "the vendor saw nothing"

let envelope_cases () =
  Alcotest.(check string)
    "not JSON"
    (Fix.show_error (Result.get_error (snd (run "not json"))))
    (Fix.error_case ~kind:"failed" ~message:"malformed JSON response");
  Alcotest.(check string)
    "not an object"
    (Fix.show_error (Result.get_error (snd (run "\"hello\""))))
    (Fix.error_case ~kind:"failed" ~message:"malformed JSON response");
  (* HTTP 200 with an empty [results] array is the vendor's way of saying
     every URL failed — *found nothing*, an empty page, so the walk
     continues to the next fallback rather than this one failing. *)
  let page = Fix.ok_page (snd (run {|{"results":[]}|})) "empty results" in
  Alcotest.(check string) "empty page, still a page" page.Seekwright_wire.Page.text "";
  Alcotest.(check int) "status" page.status_code 200;
  Alcotest.(check string) "the target stands in" page.url Fix.public_url;
  (* A non-object first entry is read as no entry at all, the [isinstance]
     rule. *)
  let page = Fix.ok_page (snd (run {|{"results":["x"]}|})) "bad entry" in
  Alcotest.(check string) "empty page" page.text ""

let timeout_row () =
  let fixture = Fix.make [ Fix.Transport (Caps.Error.make Caps.Error.Timeout ~message:"x") ] in
  Alcotest.(check string)
    "timed out"
    (Fix.show_error
       (Result.get_error (Tavily.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None)))
    (Fix.error_case ~kind:"failed" ~message:"request timed out")

let () =
  Alcotest.run "fallback_tavily"
    [
      ( "tavily",
        [
          Alcotest.test_case "request shape" `Quick request_shape;
          Alcotest.test_case "vendor timeout clamp" `Quick timeout_clamp;
          Alcotest.test_case "status arms and the private target" `Quick arms;
          Alcotest.test_case "envelope mappings" `Quick envelope_cases;
          Alcotest.test_case "transport timeout" `Quick timeout_row;
        ] );
    ]
