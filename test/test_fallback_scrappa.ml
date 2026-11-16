(* The Scrappa cases: the query shape, the credential header, the three status
   arms, and the two-layer envelope — Scrappa's own success and the origin's
   [site_status_code]. *)

module Caps = Mcp_caps
module Scrappa = Seekwright_fetch.Fallback_scrappa
module Fix = Fallback_fixtures

let cfg fixture =
  {
    Scrappa.net = Fix.net fixture;
    target = Fix.remote_target ();
    max_text_chars = 40_000;
    api_key = "sk-test";
  }

let fetch fixture url = Scrappa.fetch (cfg fixture) url ~offset:0 ~max_chars:None

let string_of_meth = function
  | `GET -> "GET"
  | `POST -> "POST"
  | `PUT -> "PUT"
  | `PATCH -> "PATCH"
  | `DELETE -> "DELETE"

let request_shape () =
  let fixture = Fix.make [ Fix.Response (200, {|{"data":{"title":"T","body_text":"hello"}}|}) ] in
  let page = Fix.ok_page (fetch fixture Fix.public_url) "ok" in
  let got =
    match Fix.requests fixture with
    | [ only ] -> only
    | _ -> Alcotest.fail "exactly one request expected"
  in
  Alcotest.(check string) "method" (string_of_meth got.meth) "GET";
  let uri = Uri.of_string got.uri in
  Alcotest.(check string) "endpoint" (Uri.path uri) "/api/web-scraper";
  Alcotest.(check string) "host" (Option.value ~default:"" (Uri.host uri)) "scrappa.co";
  (* The target rides in the [url] parameter — the scraper dials it, not us —
     and the two knobs say "render, and I do not want the HTML back". *)
  Alcotest.(check (list (pair string (list string))))
    "params" (Uri.query uri)
    [ ("url", [ Fix.public_url ]); ("javascript", [ "1" ]); ("include_html", [ "0" ]) ];
  Alcotest.(check (list (pair string string))) "credential" got.headers [ ("x-api-key", "sk-test") ];
  Alcotest.(check (option string)) "no body" got.body None;
  Alcotest.(check string) "text" page.Seekwright_wire.Page.text "hello";
  Alcotest.(check (option string)) "title" page.title (Some "T");
  Alcotest.(check int) "status" page.status_code 200

let arms () =
  let one status =
    let fixture = Fix.make [ Fix.Response (status, "{}") ] in
    Fix.show_error
      (Result.get_error (Scrappa.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None))
  in
  Alcotest.(check string)
    "401 is the key" (one 401)
    (Fix.error_case ~kind:"rejected" ~message:"authentication rejected (check API key)");
  Alcotest.(check string)
    "403 is the key" (one 403)
    (Fix.error_case ~kind:"rejected" ~message:"authentication rejected (check API key)");
  Alcotest.(check string)
    "402 is the credit meter" (one 402)
    (Fix.error_case ~kind:"quota" ~message:"rate limited or out of credits");
  Alcotest.(check string)
    "429 is the credit meter" (one 429)
    (Fix.error_case ~kind:"quota" ~message:"rate limited or out of credits");
  Alcotest.(check string)
    "500 is a failure" (one 500)
    (Fix.error_case ~kind:"failed" ~message:"HTTP 500");
  (* A refused target never reaches the vendor at all. *)
  let fixture = Fix.make [] in
  Alcotest.(check string)
    "private target"
    (Fix.show_error
       (Result.get_error
          (Scrappa.fetch (cfg fixture) "https://internal.test/x" ~offset:0 ~max_chars:None)))
    (Fix.error_case ~kind:"url_blocked"
       ~message:
         "internal.test resolves to a non-public address (127.0.0.1); fetching private, loopback \
          and link-local addresses is disabled");
  Fix.check_no_request fixture "the vendor saw nothing"

let envelope body =
  let fixture = Fix.make [ Fix.Response (200, body) ] in
  Scrappa.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None

let envelope_cases () =
  Alcotest.(check string)
    "success false"
    (Fix.show_error (Result.get_error (envelope {|{"success":false}|})))
    (Fix.error_case ~kind:"failed" ~message:"scraper reported failure");
  (* [site_status_code] is the {i origin's}: a 404 page scraped
     successfully is a successful API call and a failed fetch. *)
  Alcotest.(check string)
    "origin 404"
    (Fix.show_error (Result.get_error (envelope {|{"site_status_code":404}|})))
    (Fix.error_case ~kind:"failed" ~message:"HTTP 404");
  (* Not JSON, and JSON that is not an object: the one sentence for both. *)
  Alcotest.(check string)
    "not JSON"
    (Fix.show_error (Result.get_error (envelope "<html>")))
    (Fix.error_case ~kind:"failed" ~message:"malformed JSON response");
  Alcotest.(check string)
    "not an object"
    (Fix.show_error (Result.get_error (envelope "[]")))
    (Fix.error_case ~kind:"failed" ~message:"malformed JSON response");
  (* A missing [data] is an empty read, not an error — emptiness is the
     walk's gate, not this module's. *)
  let page = Fix.ok_page (envelope {|{"success":true}|}) "empty data" in
  Alcotest.(check string) "empty text" page.Seekwright_wire.Page.text "";
  (* [final_url] wins, [url] is the fallback, and the target is the last
     resort. *)
  let landed body = (Fix.ok_page (envelope body) "landed").Seekwright_wire.Page.url in
  Alcotest.(check string)
    "final_url"
    (landed {|{"final_url":"https://public.test/final","url":"https://public.test/u"}|})
    "https://public.test/final";
  Alcotest.(check string)
    "url fallback"
    (landed {|{"url":"https://public.test/u"}|})
    "https://public.test/u";
  Alcotest.(check string) "target stays" (landed {|{"url":""}|}) Fix.public_url

let timeout_row () =
  let fixture = Fix.make [ Fix.Transport (Caps.Error.make Caps.Error.Timeout ~message:"x") ] in
  Alcotest.(check string)
    "timed out"
    (Fix.show_error
       (Result.get_error (Scrappa.fetch (cfg fixture) Fix.public_url ~offset:0 ~max_chars:None)))
    (Fix.error_case ~kind:"failed" ~message:"request timed out")

let () =
  Alcotest.run "fallback_scrappa"
    [
      ( "scrappa",
        [
          Alcotest.test_case "request shape" `Quick request_shape;
          Alcotest.test_case "status arms and the private target" `Quick arms;
          Alcotest.test_case "envelope mappings" `Quick envelope_cases;
          Alcotest.test_case "transport timeout" `Quick timeout_row;
        ] );
    ]
