(* The page records have one owner; this suite is the fact that they do.

   Style review M5: [Fetcher.fetched_page] and [Engine.Fetch.page] were two
   records with the same nine fields, and [Factory.page_of] copied one into the
   other by hand — nine qualified fields plus a nested image copy — so a field
   added on one side and not the other compiled happily while the copier dropped
   it. Both interfaces now {i equate} their name with [Seekwright_wire.Page]'s
   record, and the fetch path hands the engine the page the fetcher read.

   The pin is the compile. OCaml records are nominal: two records declared
   separately do not unify even when their fields match, so the identities below
   are well-typed only while the three names denote {b one} record — and if
   either interface goes back to spelling its own, this file stops building. The
   runtime cases then read real fields through each name, so a field missing on
   one side is a build error and not a silently empty option. *)

module Wire = Seekwright_wire.Page
module Fetch = Seekwright.Engine.Fetch
module F = Seekwright_fetch.Fetcher
module A = Alcotest

(* One type, four names. Each direction is written out because each is the fact
   one half of the fetch path depends on. *)
let wire_page_is_the_engines : Wire.page -> Fetch.page = Fun.id
let the_engines_page_is_the_fetchers : Fetch.page -> F.fetched_page = Fun.id
let the_fetchers_page_is_the_wire : F.fetched_page -> Wire.page = Fun.id
let wire_image_is_the_engines : Wire.image -> Fetch.image = Fun.id
let the_engines_image_is_the_fetchers : Fetch.image -> F.fetched_image = Fun.id

(* [Factory]'s reader closure is where the copier sat: it received a
   [Fetcher] page and owed the engine a page. With one record there is nothing
   to write there but the page. *)
let a_fetcher_page_is_an_engine_page : F.fetched_page -> Fetch.page = Fun.id

let sample_image = { Wire.media_type = "image/png"; body = "\x89PNG" }

let sample_page =
  {
    Wire.url = "https://example.com/a";
    title = Some "A";
    text = "body";
    content_type = Some "text/html";
    status_code = 200;
    truncated = false;
    total_chars = 4;
    path_addressable = false;
    image = Some sample_image;
  }

let test_the_identities_are_well_typed () =
  (* Nothing runs: the fact is that this module compiles. Naming the identities
     in a case is what keeps one of them from being quietly deleted. *)
  ignore wire_page_is_the_engines;
  ignore the_engines_page_is_the_fetchers;
  ignore the_fetchers_page_is_the_wire;
  ignore wire_image_is_the_engines;
  ignore the_engines_image_is_the_fetchers;
  ignore a_fetcher_page_is_an_engine_page

let test_a_page_travels_from_the_fetcher_to_the_engine () =
  let via_engine : Fetch.page = a_fetcher_page_is_an_engine_page sample_page in
  A.(check string) "url" sample_page.Wire.url via_engine.Fetch.url;
  A.(check (option string)) "title" sample_page.Wire.title via_engine.Fetch.title;
  A.(check string) "text" sample_page.Wire.text via_engine.Fetch.text;
  A.(check (option string)) "content type" sample_page.Wire.content_type
    via_engine.Fetch.content_type;
  A.(check int) "status" sample_page.Wire.status_code via_engine.Fetch.status_code;
  A.(check bool) "truncated" sample_page.Wire.truncated via_engine.Fetch.truncated;
  A.(check int) "total chars" sample_page.Wire.total_chars via_engine.Fetch.total_chars;
  A.(check bool) "path addressable" sample_page.Wire.path_addressable
    via_engine.Fetch.path_addressable;
  (* The nested record travelled too. This is the field the copier's second copy
     existed for, and the one whose loss would have looked like a page that
     simply had no picture. *)
  match via_engine.Fetch.image with
  | None -> A.fail "the image did not survive the trip"
  | Some image ->
      A.(check string) "image media type" sample_image.Wire.media_type image.Fetch.media_type;
      A.(check string) "image body" sample_image.Wire.body image.Fetch.body

let test_a_page_with_no_image_stays_empty () =
  match (wire_page_is_the_engines { sample_page with Wire.image = None }).Fetch.image with
  | None -> ()
  | Some _ -> A.fail "an absent image became present"

let () =
  A.run "wire"
    [
      ( "one page record",
          [
            A.test_case "the record identities are well typed" `Quick
              test_the_identities_are_well_typed;
            A.test_case "a page travels from the fetcher to the engine" `Quick
              test_a_page_travels_from_the_fetcher_to_the_engine;
            A.test_case "a page with no image stays empty" `Quick
              test_a_page_with_no_image_stays_empty;
          ] );
    ]
