(* Port of [tests/fetch/test_linkup_fetcher.py]'s fetch cases: the fixed
   request knobs, the single 429 quota arm — Linkup's 402 belongs to the
   x402 lane this tree never enters — and the [markdown]-only mapping. *)

module Caps = Mcp_caps
module Linkup = Seekwright_fetch.Fallback_linkup
module Fix = Fallback_fixtures

let cfg fixture =
  {
    Linkup.net = Fix.net fixture;
    target = Fix.remote_target ();
    max_text_chars = 40_000;
    api_key = "lk-test";
  }

let run ?(status = 200) body =
  let fixture = Fix.make [ Fix.Response (status, body) ] in
  ( fixture,
    Linkup.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None )

let request_shape () =
  let fixture, result = run {|{"markdown":"page text"}|} in
  let page = Fix.ok_page result "ok" in
  Fix.check_request fixture
    {
      Fix.meth = `POST;
      uri = "https://api.linkup.so/v1/fetch";
      headers = [ ("Authorization", "Bearer lk-test") ];
      (* [renderJs] sent [true], the three byte-buying knobs sent [false],
         and [mode] at the cheap cell of the price table. *)
      body =
        Some
          {|{"url":"https://public.test/page","renderJs":true,"mode":"standard","extractImages":false,"includeRawHtml":false,"includeRawContent":false}|};
    };
  Alcotest.(check string) "text" page.Seekwright_wire.Page.text "page text";
  (* The service follows no links: [url] stays the target the caller wrote. *)
  Alcotest.(check string) "url stays the target" page.url Fix.public_url;
  Alcotest.(check (option string)) "no title in the payload" page.title None

let arms () =
  let one status = Fix.show_error (Result.get_error (snd (run ~status "{}"))) in
  Alcotest.(check string) "401 is the key" (one 401)
    (Fix.error_case ~kind:"rejected" ~message:"authentication rejected (check API key)");
  Alcotest.(check string) "403 is the key" (one 403)
    (Fix.error_case ~kind:"rejected" ~message:"authentication rejected (check API key)");
  Alcotest.(check string) "429 is the account or the burst" (one 429)
    (Fix.error_case ~kind:"quota" ~message:"rate limited or out of credits");
  (* 402 falls to the plain row: it belongs to a lane this tree never
     enters. *)
  Alcotest.(check string) "402 is not a meter here" (one 402)
    (Fix.error_case ~kind:"failed" ~message:"HTTP 402");
  Alcotest.(check string) "500" (one 500) (Fix.error_case ~kind:"failed" ~message:"HTTP 500");
  let fixture = Fix.make [] in
  Alcotest.(check string) "private target"
    (Fix.show_error
       (Result.get_error (Linkup.fetch (cfg fixture) "https://internal.test/x" ~offset:0 ~max_chars:None)))
    (Fix.error_case ~kind:"url_blocked" ~message:"internal.test resolves to a non-public address (127.0.0.1); fetching private, loopback and link-local addresses is disabled");
  Fix.check_no_request fixture "the vendor saw nothing"

let envelope_cases () =
  Alcotest.(check string) "not JSON"
    (Fix.show_error (Result.get_error (snd (run "<html>nope</html>"))))
    (Fix.error_case ~kind:"failed" ~message:"malformed JSON response");
  Alcotest.(check string) "not an object"
    (Fix.show_error (Result.get_error (snd (run "[1,2]"))))
    (Fix.error_case ~kind:"failed" ~message:"malformed JSON response");
  (* An empty [markdown] is a page the service could not read — an empty
     page, so the walk goes on. *)
  let page = Fix.ok_page (snd (run {|{"markdown":""}|})) "empty markdown" in
  Alcotest.(check string) "empty page, still a page" page.Seekwright_wire.Page.text "";
  let page = Fix.ok_page (snd (run {|{}|})) "no markdown field" in
  Alcotest.(check string) "missing field is empty too" page.text ""

let timeout_row () =
  let fixture = Fix.make [ Fix.Transport (Caps.Error.make Caps.Error.Timeout ~message:"x") ] in
  Alcotest.(check string) "timed out"
    (Fix.show_error
       (Result.get_error (Linkup.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None)))
    (Fix.error_case ~kind:"failed" ~message:"request timed out")

let () =
  Alcotest.run "fallback_linkup"
    [
      ( "linkup",
          [
            Alcotest.test_case "request shape" `Quick request_shape;
            Alcotest.test_case "status arms and the private target" `Quick arms;
            Alcotest.test_case "envelope mappings" `Quick envelope_cases;
            Alcotest.test_case "transport timeout" `Quick timeout_row;
          ] );
    ]
