(* Port of [tests/fetch/test_jina_fetcher.py]: the header block, the two
   placeholder bodies, the IP-meter quota arm, and the fact that this
   fallback sends no credential of any kind. *)

module Caps = Mcp_caps
module Fallback = Seekwright_fetch.Fallback
module Jina = Seekwright_fetch.Fallback_jina
module Fix = Fallback_fixtures

let cfg fixture =
  {
    Jina.net = Fix.net fixture;
    target = Fix.remote_target ();
    max_text_chars = 40_000;
    user_agent = "seekwright-test/1.0";
  }

let reader_body =
  "Title: Example Domain\nURL Source: https://public.test/landed\nMarkdown Content:\n# Header\nbody text"

let split_cases () =
  let show (headers, text) =
    (String.concat "," (List.map (fun (k, v) -> k ^ "=" ^ v) headers), text)
  in
  let pair_testable = Alcotest.(pair string string) in
  Alcotest.check pair_testable "the labelled body"
    (show (Jina.split_reader_body reader_body))
    ("title=Example Domain,url source=https://public.test/landed", "# Header\nbody text");
  (* No marker: the whole body is the page. The service answered with
     markdown it did not label, and dropping it would turn a usable read into
     an empty fallback. *)
  Alcotest.check pair_testable "an unlabelled body survives"
    (show (Jina.split_reader_body "just markdown\nsecond line"))
    ("", "just markdown\nsecond line");
  (* Anything after the marker on its own line is the page's first line. *)
  Alcotest.check pair_testable "the marker's tail is page"
    (show (Jina.split_reader_body "Title: T\nMarkdown Content:Inline first\nrest"))
    ("title=T", "Inline first\nrest");
  (* A blank remainder contributes no line. *)
  Alcotest.check pair_testable "marker with no tail"
    (show (Jina.split_reader_body "Foo: bar\nMarkdown Content:")) ("foo=bar", "")

let request_shape () =
  let fixture = Fix.make [ Fix.Response (200, reader_body) ] in
  let page = Fix.ok_page (Jina.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None) "ok" in
  Fix.check_request fixture
    {
      Fix.meth = `GET;
      uri = "https://r.jina.ai/" ^ Fix.public_url;
      (* Keyless: no credential header of any kind rides here. *)
      headers = [ ("Accept", "text/markdown"); ("User-Agent", "seekwright-test/1.0") ];
      body = None;
    };
  Alcotest.(check string) "url source wins" page.Seekwright_wire.Page.url "https://public.test/landed";
  Alcotest.(check (option string)) "title" page.title (Some "Example Domain");
  Alcotest.(check string) "text" page.text "# Header\nbody text";
  Alcotest.(check int) "the reader's own status is all it reports" page.status_code 200

let private_target () =
  let fixture = Fix.make [] in
  Alcotest.(check string) "refused before anything is sent"
    (Fix.show_error
       (Result.get_error (Jina.fetch (cfg fixture) "https://internal.test/x" ~offset:0 ~max_chars:None)))
    (Fix.error_case ~kind:"url_blocked" ~message:"internal.test resolves to a non-public address (127.0.0.1); fetching private, loopback and link-local addresses is disabled");
  Fix.check_no_request fixture "the vendor saw nothing"

let arm status =
  let fixture = Fix.make [ Fix.Response (status, "nope") ] in
  Fix.show_error (Result.get_error (Jina.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None))

let empty_source () =
  (* [source or url]: an empty [URL Source:] from the reader is no value, and
     the target the caller wrote stands in. *)
  let fixture =
    Fix.make [ Fix.Response (200, "Title: Example\nURL Source:\nMarkdown Content:\nbody") ]
  in
  let page = Fix.ok_page (Jina.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None) "ok" in
  Alcotest.(check string) "the target stands in" page.Seekwright_wire.Page.url Fix.public_url

let arms () =
  Alcotest.(check string) "402 is the meter" (arm 402)
    (Fix.error_case ~kind:"quota" ~message:"rate limited");
  Alcotest.(check string) "429 is the meter" (arm 429)
    (Fix.error_case ~kind:"quota" ~message:"rate limited");
  (* 401/403 included, and not read as an auth failure: this fallback sends
     no credential, so a rejection is the service refusing this address. *)
  Alcotest.(check string) "403 is a plain HTTP failure" (arm 403)
    (Fix.error_case ~kind:"failed" ~message:"HTTP 403");
  Alcotest.(check string) "500 is a plain HTTP failure" (arm 500)
    (Fix.error_case ~kind:"failed" ~message:"HTTP 500")

let placeholder body expected_text () =
  let fixture = Fix.make [ Fix.Response (200, body) ] in
  let page = Fix.ok_page (Jina.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None) "ok" in
  Alcotest.(check string) "text" page.text expected_text;
  Alcotest.(check (option string)) "the title survives" page.title (Some "Reader")

let windowing () =
  (* The shared page tail: the caller's [max_chars] windows the extraction,
     [truncated] and [total_chars] describe the whole, and the offsets a caller
     sees index the un-marker'd text. *)
  let body = "Title: T\nMarkdown Content:\n" ^ String.make 300 'a' in
  let fixture = Fix.make [ Fix.Response (200, body) ] in
  let page =
    Fix.ok_page (Jina.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:(Some 100)) "window"
  in
  Alcotest.(check string)
    "the window plus the truncation marker"
    page.Seekwright_wire.Page.text
    (String.make 100 'a' ^ "\n\n[...]");
  Alcotest.(check bool) "truncated" page.truncated true;
  Alcotest.(check int) "the whole extraction" page.total_chars 300;
  (* [max_text_chars] is the fallback's own ceiling when the caller names none;
     the fixture's is 40_000, so this body arrives whole. *)
  let fixture = Fix.make [ Fix.Response (200, body) ] in
  let page = Fix.ok_page (Jina.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None) "whole" in
  Alcotest.(check bool) "not truncated" page.truncated false

let transport kind message () =
  let fixture = Fix.make [ Fix.Transport (Caps.Error.make kind ~message:"grant detail") ] in
  Alcotest.(check string) "the contracted sentence"
    (Fix.show_error
       (Result.get_error (Jina.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None)))
    (Fix.error_case ~kind:"failed" ~message:message);
  (* The grant still saw the reader request; it is the grant's failure that
     produced the sentence. *)
  Fix.check_request fixture
    {
      Fix.meth = `GET;
      uri = "https://r.jina.ai/" ^ Fix.public_url;
      headers = [ ("Accept", "text/markdown"); ("User-Agent", "seekwright-test/1.0") ];
      body = None;
    }

let () =
  Alcotest.run "fallback_jina"
    [
      ( "the reader body",
          [
            Alcotest.test_case "header block, marker and placeholders" `Quick split_cases;
          ] );
      ( "the fetch",
          [
            Alcotest.test_case "request shape and envelope" `Quick request_shape;
            Alcotest.test_case "a private target is refused before the vendor" `Quick private_target;
            Alcotest.test_case "an empty URL Source falls back to the target" `Quick empty_source;
            Alcotest.test_case "status arms" `Quick arms;
            Alcotest.test_case "the window tail and its total" `Quick windowing;
            Alcotest.test_case "Loading... reads as empty" `Quick
              (placeholder "Title: Reader\nMarkdown Content:\nLoading..." "");
            Alcotest.test_case "enable-JS reads as empty" `Quick
              (placeholder "Title: Reader\nMarkdown Content:\nPlease enable JavaScript to view this page." "");
            Alcotest.test_case "timeout" `Quick
              (transport Caps.Error.Timeout "request timed out");
            Alcotest.test_case "network" `Quick
              (transport Caps.Error.Unavailable "network error");
          ] );
    ]
