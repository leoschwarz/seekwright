(* The fetcher over a real Net grant: the redirect chain, the download cap's
   per-type refusals, the type gate and the image agreement, all driven against
   a loopback HTTP fixture through a [Policy.with_endpoints] grant — the same
   fixture shape test_authority_net.ml uses, because the grant's own policy is
   pinned there and what is pinned here is what the fetcher adds on top.

   Port of the networked cases of tests/fetch/test_fetch_guardrails.py
   (TestRedirects, TestBodyHandling, TestImages, TestExtractionTime's refusal
   shape) and test_fetcher.py (TestJsonIsFetchable, TestCsvIsFetchable,
   TestTheBackendDecidesWhatIsReadable). The DNS-level address blocking is the
   grant's, covered by test_authority_net.ml; what lands here as a refusal is
   the grant's [Denied] mapped onto the fetcher's provenance tags. *)

module F = Seekwright_fetch.Fetcher
module E = Seekwright_fetch.Extractor
module S = Seekwright_fetch_stdlib.Stdlib
module Caps = Mcp_caps

module Policy = Caps.Policy
module Authority = Caps.Authority
module Policy_net = Caps.Policy_net
module Error = Caps.Error

module A = Alcotest

let extractor = E.of_module (module S)

let html_body =
  "<!DOCTYPE html><html><head><title>Doc</title></head><body><article><p>"
  ^ String.concat "" (List.init 40 (fun _ -> "Sentences of real body text. "))
  ^ "</p></article></body></html>"

let json_body = "{\"total\": 1, \"item\": {\"name\": \"a document worth fetching\"}}"
let csv_body = "id,name\n1,Ada\n2,Grace\n"
let big_csv = "id,name\n" ^ String.concat "" (List.init 4000 (fun _ -> "1,Ada\n"))
let big_json = "{\"items\": [" ^ String.concat "," (List.init 60_000 (fun _ -> "1")) ^ "]}"
let big_html = "<html><body><p>" ^ String.make 3_000_000 'x' ^ "</p></body></html>"
let png_body = "\x89PNG\r\n\x1a\n" ^ String.make 100 'p'

(* The fixture's [/stall] sleep and the budgets the cases set against it: the
   sleep is longer than every budget that expects to be cut and shorter than the
   one that expects to arrive. *)
let slow_seconds = 2.0
let tight_budget_seconds = 0.4
let generous_budget_seconds = 10.0

(* The fixture: one route table, keyed by path. *)
let fixture ~port ~clock _conn request _body =
  let path = Http.Request.resource request in
  let respond ?(headers = []) ~status body =
    Cohttp_eio.Server.respond_string ~headers:(Http.Header.of_list headers) ~status
      ~body ()
  in
  let redirect target = respond ~headers: [ ("location", target) ] ~status:`Found "redirected\n" in
  let base = Printf.sprintf "http://127.0.0.1:%d" port in
  match path with
  | "/page" -> respond ~headers: [ ("content-type", "text/html") ] ~status:`OK html_body
  | "/stall" ->
      (* Answers, but late: the route the chain budget is measured against, and
         the one the outer-cancellation case cancels. *)
      Eio.Time.sleep clock slow_seconds;
      respond ~headers: [ ("content-type", "text/html") ] ~status:`OK html_body
  | "/json" -> respond ~headers: [ ("content-type", "application/json") ] ~status:`OK json_body
  | "/csv" -> respond ~headers: [ ("content-type", "text/csv") ] ~status:`OK csv_body
  | "/redirect" -> redirect "/page"
  | "/redirect-abs" -> redirect (base ^ "/page")
  | "/loop" -> redirect "/loop"
  | "/no-location" -> respond ~status:`Found "no location\n"
  | "/to-file" -> redirect "file:///etc/passwd"
  | "/to-elsewhere" -> redirect (Printf.sprintf "http://localhost:%d/page" port)
  | "/missing" -> respond ~status:`Not_found "nothing here\n"
  | "/octet" ->
      respond ~headers: [ ("content-type", "application/octet-stream") ] ~status:`OK "raw bytes"
  | "/big-json" ->
      respond ~headers: [ ("content-type", "application/json") ] ~status:`OK big_json
  | "/big-csv" -> respond ~headers: [ ("content-type", "text/csv") ] ~status:`OK big_csv
  | "/big-html" ->
      respond ~headers: [ ("content-type", "text/html") ] ~status:`OK big_html
  | "/png" -> respond ~headers: [ ("content-type", "image/png") ] ~status:`OK png_body
  | "/fake-png" ->
      respond ~headers: [ ("content-type", "image/png") ] ~status:`OK "not a png at all"
  | _ -> respond ~status:`Not_found "nothing here\n"

(* One case: the fixture, a grant pinned to it, and the fetcher built with the
   case's knobs. The clocked form also hands over the monotonic clock, which is
   what a chain budget is measured against and what the fixture's [/stall]
   route sleeps on. *)
let with_fetcher_clocked ?(max_download_bytes = 8_388_608) ?(allow_images = false) f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~backlog:16 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> Alcotest.failf "unix socket fixture: %s" path
  in
  let server =
    Cohttp_eio.Server.make ~callback:(fixture ~port ~clock:(Eio.Stdenv.clock env)) ()
  in
  let stop, fill_stop = Eio.Promise.create () in
  let stopped, fill_stopped = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Promise.resolve fill_stopped ())
      (fun () -> Cohttp_eio.Server.run ~stop ~on_error:(fun _exn -> ()) socket server));
  Fun.protect
    ~finally:(fun () ->
      Eio.Promise.resolve fill_stop ();
      Eio.Promise.await stopped)
    (fun () ->
      let endpoint : Policy.endpoint =
        { Policy.scheme = `Http; host = "127.0.0.1"; port = Some port }
      in
      match
        Policy.with_endpoints ~sw ~net:env#net ~max_response_bytes:16_000_000 [ endpoint ]
      with
      | Error error -> Alcotest.failf "with_endpoints: %s" (Error.render error)
      | Ok decision ->
          let net =
            Authority.Net.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) decision
          in
          let fetcher =
            F.make ~net ~extractor ~max_download_bytes ~allow_images ()
          in
          f fetcher port (Eio.Stdenv.mono_clock env))

(* The form every non-timing case uses: the clock is there for the fixture, and
   a case that sets no budget has no use for it. *)
let with_fetcher ?(max_download_bytes = 8_388_608) ?(allow_images = false) f =
  with_fetcher_clocked ~max_download_bytes ~allow_images (fun fetcher port _clock ->
    f fetcher port)

let base fetcher port path =
  F.fetch fetcher (Printf.sprintf "http://127.0.0.1:%d%s" port path) ~offset:0
    ~max_chars:None

let expect_ok page = match page with Ok p -> p | Error e -> Alcotest.failf "expected Ok, got error: %s" (match e with F.Refusal r -> (match r with F.Url_blocked m | F.Redirect_blocked m | F.Blocked m -> m) | F.Failed m -> m)

let contains_substring hay needle =
  let n = String.length hay and m = String.length needle in
  let rec go i =
    if i + m > n then false
    else String.sub hay i m = needle || go (i + 1)
  in
  m = 0 || go 0

let expect_refusal_with needle page =
  match page with
  | Error (F.Refusal refusal) ->
      let msg =
        match refusal with
        | F.Url_blocked m | F.Redirect_blocked m | F.Blocked m -> m
      in
      if not (contains_substring msg needle) then
        Alcotest.failf "refusal %S lacks %S" msg needle
  | Ok _ -> Alcotest.fail "expected a refusal"
  | Error (F.Failed m) -> Alcotest.failf "expected a refusal, got Failed %S" m

let test_a_page_is_fetched_and_extracted () =
  with_fetcher (fun fetcher port ->
    let page = expect_ok (base fetcher port "/page") in
    A.check A.int "status" 200 page.F.status_code;
    A.check A.bool "content" true (contains_substring page.F.text "Sentences of real body text.");
    A.check (A.option A.string) "title" (Some "Doc") page.F.title;
    A.check (A.option A.string) "content type" (Some "text/html") page.F.content_type;
    A.check A.bool "not addressable" false page.F.path_addressable;
    A.check A.bool "no image" true (page.F.image = None))

let test_a_redirect_is_followed_and_the_final_url_reported () =
  with_fetcher (fun fetcher port ->
    let page = expect_ok (base fetcher port "/redirect") in
    A.check A.bool "landed" true (String.ends_with ~suffix:"/page" page.F.url);
    A.check A.bool "content" true (contains_substring page.F.text "Sentences of real body text."));
  with_fetcher (fun fetcher port ->
    let page = expect_ok (base fetcher port "/redirect-abs") in
    A.check A.bool "landed" true (String.ends_with ~suffix:"/page" page.F.url))

let test_too_many_redirects_is_blocked () =
  with_fetcher (fun fetcher port ->
    expect_refusal_with "more than 3 redirects" (base fetcher port "/loop"))

let test_a_redirect_without_a_usable_location_is_refused () =
  with_fetcher (fun fetcher port ->
    match base fetcher port "/no-location" with
    | Error (F.Failed msg) ->
        A.check A.bool "location named" true (contains_substring msg "without a Location header")
    | other -> Alcotest.failf "expected Failed, got %s"
        (match other with
        | Ok _ -> "Ok"
        | Error (F.Refusal r) -> (match r with F.Url_blocked m | F.Redirect_blocked m | F.Blocked m -> m)
        | Error (F.Failed m) -> m))

let test_a_redirect_to_a_blocked_scheme_is_refused_as_post_dispatch () =
  with_fetcher (fun fetcher port ->
    (* The grant refuses the off-list Location itself (its pinned "with a
       redirect to a host this grant does not allow" denial), and the fetcher
       tags that mid-flight refusal [Redirect_blocked], not [Url_blocked] —
       the provenance the REST 400/502 split reads. *)
    match base fetcher port "/to-file" with
    | Error (F.Refusal (F.Redirect_blocked msg)) ->
        A.check A.bool "the grant's redirect denial" true
          (contains_substring msg "redirect")
    | other ->
        Alcotest.failf "expected Redirect_blocked, got %s"
          (match other with
          | Ok _ -> "Ok"
          | Error (F.Refusal r) -> (match r with F.Url_blocked m | F.Redirect_blocked m | F.Blocked m -> m)
          | Error (F.Failed m) -> m))

let test_a_redirect_to_an_unlisted_host_is_refused_mid_flight () =
  with_fetcher (fun fetcher port ->
    match base fetcher port "/to-elsewhere" with
    | Error (F.Refusal (F.Redirect_blocked _)) -> ()
    | other ->
        Alcotest.failf "expected Redirect_blocked, got %s"
          (match other with
          | Ok _ -> "Ok"
          | Error (F.Refusal r) -> (match r with F.Url_blocked m | F.Redirect_blocked m | F.Blocked m -> m)
          | Error (F.Failed m) -> m))

let test_a_refusal_of_the_written_url_is_url_blocked () =
  with_fetcher (fun fetcher _port ->
    match F.fetch fetcher "file:///etc/passwd" ~offset:0 ~max_chars:None with
    | Error (F.Refusal (F.Url_blocked msg)) ->
        A.check A.bool "not fetchable named" true (contains_substring msg "not fetchable")
    | other ->
        Alcotest.failf "expected Url_blocked, got %s"
          (match other with
          | Ok _ -> "Ok"
          | Error (F.Refusal r) -> (match r with F.Url_blocked m | F.Redirect_blocked m | F.Blocked m -> m)
          | Error (F.Failed m) -> m))

let test_an_error_status_is_a_failure_not_content () =
  with_fetcher (fun fetcher port ->
    match base fetcher port "/missing" with
    | Error (F.Failed msg) -> A.check A.string "HTTP 404" "HTTP 404" msg
    | other -> Alcotest.failf "expected Failed, got %s"
        (match other with
        | Ok _ -> "Ok"
        | Error (F.Refusal r) -> (match r with F.Url_blocked m | F.Redirect_blocked m | F.Blocked m -> m)
        | Error (F.Failed m) -> m))

let test_json_is_fetchable_and_addressable () =
  with_fetcher (fun fetcher port ->
    let page = expect_ok (base fetcher port "/json") in
    A.check A.bool "addressable" true page.F.path_addressable;
    A.check A.bool "path printed" true (contains_substring page.F.text "$.item.name");
    A.check (A.option A.string) "content type" (Some "application/json") page.F.content_type)

let test_csv_is_fetchable_and_addressable () =
  with_fetcher (fun fetcher port ->
    let page = expect_ok (base fetcher port "/csv") in
    A.check A.bool "addressable" true page.F.path_addressable;
    A.check A.bool "row path" true (contains_substring page.F.text "$.rows[0].name"))

let test_an_unsupported_type_is_refused_by_name () =
  with_fetcher (fun fetcher port ->
    expect_refusal_with "cannot extract text from application/octet-stream" (base fetcher port "/octet"))

let test_a_truncated_json_document_names_the_limit () =
  with_fetcher ~max_download_bytes:10_000 (fun fetcher port ->
    expect_refusal_with "JSON document exceeds the 9 KiB download limit" (base fetcher port "/big-json"))

let test_a_truncated_csv_keeps_the_rows_above_the_cut () =
  with_fetcher ~max_download_bytes:10_000 (fun fetcher port ->
    let page = expect_ok (base fetcher port "/big-csv") in
    A.check A.bool "still addressable" true page.F.path_addressable;
    A.check A.bool "head rows whole" true (contains_substring page.F.text "$.rows[0].name  \"Ada\""))

let test_an_oversized_html_page_is_capped () =
  with_fetcher ~max_download_bytes:50_000 (fun fetcher port ->
    let page = expect_ok (base fetcher port "/big-html") in
    A.check A.bool "bounded" true (page.F.total_chars <= 60_000))

let test_an_admitted_image_is_returned_when_its_bytes_agree () =
  with_fetcher ~allow_images:true (fun fetcher port ->
    let page = expect_ok (base fetcher port "/png") in
    A.check A.string "no text" "" page.F.text;
    A.check A.int "no chars" 0 page.F.total_chars;
    match page.F.image with
    | Some image -> A.check A.string "media type" "image/png" image.F.media_type
    | None -> Alcotest.fail "expected an image")

let test_an_image_whose_bytes_disagree_with_its_header_is_refused () =
  with_fetcher ~allow_images:true (fun fetcher port ->
    expect_refusal_with "its first bytes are not that image type" (base fetcher port "/fake-png"))

let test_an_image_without_the_switch_names_the_switch () =
  with_fetcher ~allow_images:false (fun fetcher port ->
    expect_refusal_with "fetch.allow_images = true" (base fetcher port "/png"))

(* {2 The chain budget} *)

(* One bound over the whole redirect chain, not one per hop: the grant's
   operation timeout restarts at every hop, so without this a page behind
   [max_redirects] redirects can spend [max_redirects + 1] timeouts on one URL.
   The cases use the harness's monotonic clock — the same clock
   [Authority.Net.of_confinement] was built with, so the bound and the I/O agree
   about what "elapsed" means. *)

let describe outcome =
  match outcome with
  | Ok _ -> "a page"
  | Error (F.Refusal r) ->
      (match r with F.Url_blocked m | F.Redirect_blocked m | F.Blocked m -> "refusal: " ^ m)
  | Error (F.Failed m) -> "failed: " ^ m

let test_a_chain_budget_cuts_a_page_that_takes_too_long () =
  with_fetcher_clocked (fun fetcher port clock ->
    match
      F.fetch
        ~chain_timeout:(Eio.Time.Timeout.seconds clock tight_budget_seconds)
        fetcher (Printf.sprintf "http://127.0.0.1:%d/stall" port) ~offset:0 ~max_chars:None
    with
    | Error (F.Failed msg) ->
        (* The sentence the per-hop grant timeout already returns: a caller
           cannot tell which bound expired and never needs to. *)
        A.check A.string "the budget's sentence" "request timed out" msg
    | other -> Alcotest.failf "expected the budget to answer, got %s" (describe other))

let test_a_chain_budget_wider_than_the_page_answers_normally () =
  with_fetcher_clocked (fun fetcher port clock ->
    let page =
      expect_ok
        (F.fetch
           ~chain_timeout:(Eio.Time.Timeout.seconds clock generous_budget_seconds)
           fetcher (Printf.sprintf "http://127.0.0.1:%d/page" port) ~offset:0
           ~max_chars:None)
    in
    A.check A.int "status" 200 page.F.status_code)

let test_without_a_chain_budget_the_page_still_arrives () =
  (* [none] is the default, and the default is what every call site that does
     not pass a budget gets: no ceiling of this module's own, so the fetch
     takes as long as the grant allows it to. *)
  with_fetcher (fun fetcher port ->
    let page = expect_ok (base fetcher port "/stall") in
    A.check A.int "status" 200 page.F.status_code)

let test_an_outer_budget_still_cancels_a_fetch () =
  (* The other half of the budget rule: this module's [try] names only
     [Eio.Time.Timeout], so a caller whose own bound expires still gets its own
     exception. The difference between a fetch that is late and a fetch that
     cannot be stopped is exactly this clause. *)
  with_fetcher_clocked (fun fetcher port clock ->
    let outcome =
      try
        `Answered
          (Eio.Time.Timeout.run_exn
             (Eio.Time.Timeout.seconds clock tight_budget_seconds)
             (fun () -> base fetcher port "/stall"))
      with Eio.Time.Timeout -> `Cancelled
    in
    match outcome with
    | `Cancelled -> ()
    | `Answered result ->
        Alcotest.failf "the caller's budget expired and the fetch returned %s instead"
          (describe result))

let () =
  Alcotest.run "fetch_http"
    [
      ( "fetching",
        [ A.test_case "a page is fetched and extracted" `Quick test_a_page_is_fetched_and_extracted ] );
      ( "redirects",
        [
          A.test_case "a redirect is followed and the final url reported" `Quick
            test_a_redirect_is_followed_and_the_final_url_reported;
          A.test_case "too many redirects is blocked" `Quick test_too_many_redirects_is_blocked;
          A.test_case "a redirect without a location is refused" `Quick
            test_a_redirect_without_a_usable_location_is_refused;
          A.test_case "a redirect to a blocked scheme is post-dispatch" `Quick
            test_a_redirect_to_a_blocked_scheme_is_refused_as_post_dispatch;
          A.test_case "a redirect to an unlisted host is mid-flight" `Quick
            test_a_redirect_to_an_unlisted_host_is_refused_mid_flight;
          A.test_case "the written url's refusal is url-blocked" `Quick
            test_a_refusal_of_the_written_url_is_url_blocked;
        ] );
      ( "status and types",
        [
          A.test_case "an error status is a failure" `Quick test_an_error_status_is_a_failure_not_content;
          A.test_case "json is fetchable and addressable" `Quick test_json_is_fetchable_and_addressable;
          A.test_case "csv is fetchable and addressable" `Quick test_csv_is_fetchable_and_addressable;
          A.test_case "an unsupported type is refused by name" `Quick
            test_an_unsupported_type_is_refused_by_name;
        ] );
      ( "the download cap",
        [
          A.test_case "a truncated json document names the limit" `Quick
            test_a_truncated_json_document_names_the_limit;
          A.test_case "a truncated csv keeps its head rows" `Quick
            test_a_truncated_csv_keeps_the_rows_above_the_cut;
          A.test_case "an oversized html page is capped" `Quick test_an_oversized_html_page_is_capped;
        ] );
      ( "images",
        [
          A.test_case "an admitted image is returned whole" `Quick
            test_an_admitted_image_is_returned_when_its_bytes_agree;
          A.test_case "disagreeing bytes are refused" `Quick
            test_an_image_whose_bytes_disagree_with_its_header_is_refused;
          A.test_case "without the switch the refusal names it" `Quick
            test_an_image_without_the_switch_names_the_switch;
        ] );
      ( "the chain budget",
        [
          A.test_case "a chain budget cuts a page that takes too long" `Quick
            test_a_chain_budget_cuts_a_page_that_takes_too_long;
          A.test_case "a chain budget wider than the page answers normally" `Quick
            test_a_chain_budget_wider_than_the_page_answers_normally;
          A.test_case "without a chain budget the page still arrives" `Quick
            test_without_a_chain_budget_the_page_still_arrives;
          A.test_case "an outer budget still cancels a fetch" `Quick
            test_an_outer_budget_still_cancels_a_fetch;
        ] );
    ]
