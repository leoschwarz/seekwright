(* Port of [tests/fetch/test_crawl4ai_fetcher.py]'s cases: the POST shape on
   the pinned API, the per-request bearer, the operator-token sentence on
   401/403, the missing quota arm (a self-hosted service does not meter
   this deployment), and the two-layer envelope. *)

module Caps = Mcp_caps
module Crawl = Seekwright_fetch.Fallback_crawl4ai
module Fix = Fallback_fixtures

let cfg ?(token = None) fixture =
  {
    Crawl.net = Fix.net fixture;
    target = Fix.remote_target ();
    max_text_chars = 40_000;
    base_url = "http://renderer.test:11235/";
    token;
  }

let run ?(token = None) ?(status = 200) body =
  let fixture = Fix.make [ Fix.Response (status, body) ] in
  ( fixture,
    Crawl.fetch (cfg ~token fixture) Fix.public_url ~offset:0 ~max_chars:None )

(* {1 Request shape} *)

let request_shape () =
  let fixture, result = run {|{"results":[{"success":true,"markdown":"body one"}]}|} in
  ignore (Fix.ok_page result "ok");
  Fix.check_request fixture
    {
      Fix.meth = `POST;
      (* The trailing slash in [base_url] does not double up: the oracle's
         [__init__] right-strips it. *)
      uri = "http://renderer.test:11235/crawl";
      headers = [];
      body =
        Some
          {|{"urls":["https://public.test/page"],"browser_config":{},"crawler_config":{}}|};
    };
  Alcotest.(check string) "markdown string still reads"
    (Fix.ok_page result "ok").Seekwright_wire.Page.text "body one"

let bearer_header () =
  let fixture, result = run ~token:(Some "op-token") {|{"results":[{"success":true,"markdown":"m"}]}|} in
  ignore (Fix.ok_page result "ok");
  Fix.check_request fixture
    {
      Fix.meth = `POST;
      uri = "http://renderer.test:11235/crawl";
      headers = [ ("Authorization", "Bearer op-token") ];
      body =
        Some
          {|{"urls":["https://public.test/page"],"browser_config":{},"crawler_config":{}}|};
    };
  (* An empty token is no token, exactly as the oracle's [if self._token:]. *)
  let fixture, result = run ~token:(Some "") {|{"results":[{"success":true,"markdown":"m"}]}|} in
  ignore (Fix.ok_page result "ok");
  Fix.check_request fixture
    {
      Fix.meth = `POST;
      uri = "http://renderer.test:11235/crawl";
      headers = [];
      body =
        Some
          {|{"urls":["https://public.test/page"],"browser_config":{},"crawler_config":{}}|};
    }

(* {1 Status arms} *)

let arms () =
  let one status = Fix.show_error (Result.get_error (snd (run ~status "{}"))) in
  (* The operator's own service refused the token this deployment configured
     — a different fix than a vendor key, and the sentence says so. *)
  Alcotest.(check string) "401 names the config key" (one 401)
    (Fix.error_case ~kind:"rejected" ~message:"authentication rejected (check fetch.crawl4ai_token)");
  Alcotest.(check string) "403 names the config key" (one 403)
    (Fix.error_case ~kind:"rejected" ~message:"authentication rejected (check fetch.crawl4ai_token)");
  (* No quota arm: even 429 is a plain failure here, because a self-hosted
     service does not meter this deployment. *)
  Alcotest.(check string) "429 is not a meter" (one 429)
    (Fix.error_case ~kind:"failed" ~message:"HTTP 429");
  Alcotest.(check string) "500" (one 500) (Fix.error_case ~kind:"failed" ~message:"HTTP 500");
  let fixture = Fix.make [] in
  Alcotest.(check string) "private target"
    (Fix.show_error
       (Result.get_error
          (Crawl.fetch (cfg fixture) "https://internal.test/x" ~offset:0 ~max_chars:None)))
    (Fix.error_case ~kind:"url_blocked" ~message:"internal.test resolves to a non-public address (127.0.0.1); fetching private, loopback and link-local addresses is disabled");
  Fix.check_no_request fixture "the renderer saw nothing"

(* {1 The two-layer envelope} *)

let envelope body = Fix.show_error (Result.get_error (snd (run body)))

let envelope_cases () =
  Alcotest.(check string) "envelope success false" (envelope {|{"success":false}|})
    (Fix.error_case ~kind:"failed" ~message:"crawler reported failure");
  Alcotest.(check string) "no results" (envelope {|{"success":true,"results":[]}|})
    (Fix.error_case ~kind:"failed" ~message:"malformed JSON response");
  Alcotest.(check string) "missing results" (envelope {|{"success":true}|})
    (Fix.error_case ~kind:"failed" ~message:"malformed JSON response");
  Alcotest.(check string) "non-object result" (envelope {|{"results":["x"]}|})
    (Fix.error_case ~kind:"failed" ~message:"malformed JSON response");
  (* The crawl's own failure, with the renderer's reason when it gives one. *)
  Alcotest.(check string) "result success false with reason"
    (envelope {|{"results":[{"success":false,"error_message":"navigation failed"}]}|})
    (Fix.error_case ~kind:"failed" ~message:"navigation failed");
  Alcotest.(check string) "result success false bare"
    (envelope {|{"results":[{"success":false}]}|})
    (Fix.error_case ~kind:"failed" ~message:"crawl failed");
  (* The origin's [status_code], on the Scrappa rule. *)
  Alcotest.(check string) "origin 404 is a failed fetch"
    (envelope {|{"results":[{"success":true,"status_code":404,"markdown":"sorry"}]}|})
    (Fix.error_case ~kind:"failed" ~message:"HTTP 404");
  (* 207 is not an error status, and a multi-status crawl still answers. *)
  let page = Fix.ok_page (snd (run {|{"results":[{"success":true,"status_code":207,"markdown":"m"}]}|})) "207" in
  Alcotest.(check string) "207 serves" page.Seekwright_wire.Page.text "m";
  (* Newer server lines send [markdown] as a dict: prefer [raw_markdown],
     since [fit_markdown] trades content for tidiness. *)
  let page =
    Fix.ok_page
      (snd (run {|{"results":[{"success":true,"markdown":{"raw_markdown":"raw","markdown_body":"fit"}}]}|}))
      "dict markdown"
  in
  Alcotest.(check string) "raw_markdown wins" page.text "raw";
  (* A markdown field of neither shape is an empty read, not an error. *)
  let page = Fix.ok_page (snd (run {|{"results":[{"success":true,"markdown":null}]}|})) "no markdown" in
  Alcotest.(check string) "empty text" page.text "";
  (* Title from [metadata], landing URL from [redirected_url] then [url]. *)
  let page =
    Fix.ok_page
      (snd
         (run
            ({|{"results":[{"success":true,"markdown":"m","metadata":{"title":"Page"},|}
             ^ {|"redirected_url":"https://public.test/landed","url":"https://public.test/x"}]}|})))
      "metadata"
  in
  Alcotest.(check (option string)) "title" page.title (Some "Page");
  Alcotest.(check string) "redirected_url wins" page.url "https://public.test/landed";
  let page =
    Fix.ok_page
      (snd (run {|{"results":[{"success":true,"markdown":"m","url":"https://public.test/x"}]}|})) "url"
  in
  Alcotest.(check string) "url fallback" page.url "https://public.test/x";
  (* An empty [url] from the renderer is no value: the target the caller wrote
     stands in, because [or] skips the empty string. *)
  let page =
    Fix.ok_page (snd (run {|{"results":[{"success":true,"markdown":"m","url":""}]}|})) "empty url"
  in
  Alcotest.(check string) "empty url falls back to the target" page.url Fix.public_url

(* {1 Transport rows} *)

let timeout_row () =
  let fixture = Fix.make [ Fix.Transport (Caps.Error.make Caps.Error.Timeout ~message:"x") ] in
  Alcotest.(check string) "timed out"
    (Fix.show_error
       (Result.get_error (Crawl.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None)))
    (Fix.error_case ~kind:"failed" ~message:"request timed out")

let () =
  Alcotest.run "fallback_crawl4ai"
    [
      ( "crawl4ai",
          [
            Alcotest.test_case "POST shape" `Quick request_shape;
            Alcotest.test_case "bearer built per request" `Quick bearer_header;
            Alcotest.test_case "status arms and the private target" `Quick arms;
            Alcotest.test_case "two-layer envelope" `Quick envelope_cases;
            Alcotest.test_case "transport timeout" `Quick timeout_row;
          ] );
    ]
