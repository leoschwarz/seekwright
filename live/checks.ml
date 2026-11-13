(* The ported live assertions. Each adapter has its own arm because each
   backend documents a different response shape, and the Python live suite is
   what says which shape that is. The shared helpers below only express the
   vocabulary the arms use; the arm is what makes a case "not generic". *)

module Model = Seekwright.Model

type check = { label : string; failure : string option }

let passing label = { label; failure = None }

let expect label condition sentence = { label; failure = if condition then None else Some sentence }

let contains haystack needle =
  let h = String.length haystack and n = String.length needle in
  let rec go i = i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1)) in
  n = 0 || go 0

let starts_with_http url =
  String.starts_with ~prefix:"http://" url || String.starts_with ~prefix:"https://" url

(* {1 Vocabulary shared by the arms} *)

let named ~name (response : Model.search_response) =
  expect "the response names the provider that was asked for"
    (String.equal response.Model.provider name)
    (Printf.sprintf
       "the response names %S, not %S: an unexpected call, or a route that substituted"
       response.Model.provider name)

let nonempty (response : Model.search_response) =
  expect "at least one result came back" (response.Model.results <> [])
    "the provider answered with no results"

let every_result label predicate (response : Model.search_response) =
  let failed = List.filter (fun (result : Model.result) -> not (predicate result)) response.Model.results in
  expect label
    (failed = [])
    (Printf.sprintf "%d of %d results fail this" (List.length failed) (List.length response.Model.results))

let urls_are_http (response : Model.search_response) =
  every_result "every result carries an http(s) URL"
    (fun (result : Model.result) -> starts_with_http result.Model.url)
    response

let titles_are_present (response : Model.search_response) =
  every_result "every result carries a title"
    (fun (result : Model.result) -> String.length result.Model.title > 0)
    response

let any_url_and_snippet (response : Model.search_response) =
  expect "at least one result carries a URL and a snippet"
    (List.exists
       (fun (result : Model.result) ->
         starts_with_http result.Model.url && Option.is_some result.Model.snippet)
       response.Model.results)
    "every result was missing a URL or a snippet"

let snippets_present (response : Model.search_response) =
  every_result "every result carries a snippet"
    (fun (result : Model.result) -> Option.is_some result.Model.snippet)
    response

let no_text (response : Model.search_response) =
  every_result "no result carries text (a SERP backend fills snippet, never text)"
    (fun (result : Model.result) -> Option.is_none result.Model.text)
    response

let no_snippet (response : Model.search_response) =
  every_result "no result carries a snippet (a content backend fills text, not snippet)"
    (fun (result : Model.result) -> Option.is_none result.Model.snippet)
    response

let text_instead_of_snippet (response : Model.search_response) =
  every_result "every result carries text and no snippet"
    (fun (result : Model.result) ->
      match (result.Model.text, result.Model.snippet) with
      | Some text, None -> String.length text > 0
      | _ -> false)
    response

let first_url_is_http (response : Model.search_response) =
  match response.Model.results with
  | first :: _ -> expect "the first result's URL is http(s)" (starts_with_http first.Model.url) "the first result's URL is not http(s)"
  | [] -> passing "the first result's URL is http(s) (no results to check)"

let domains_constrain domain response =
  every_result (Printf.sprintf "every result is from %s" domain)
    (fun (result : Model.result) -> contains result.Model.url domain)
    response

let answer_present (response : Model.search_response) =
  expect "the backend synthesised an answer"
    (match response.Model.answer with Some answer -> String.length (String.trim answer) > 0 | None -> false)
    "the answer field was absent or empty"

let notice_contains needle (response : Model.search_response) =
  expect (Printf.sprintf "the response notice carries %S" needle)
    (match response.Model.notice with Some notice -> contains notice needle | None -> false)
    "the response carried no notice, or one without that constraint"

let notice_lacks needle (response : Model.search_response) =
  expect (Printf.sprintf "the notice does not carry %S" needle)
    (match response.Model.notice with Some notice -> not (contains notice needle) | None -> true)
    "the response carried that notice"

(* {1 Per-adapter arms} *)

let provider_step ~name ~step (response : Model.search_response) =
  let base = [ named ~name response ] in
  match (name, step) with
  | "serper", 0 -> base @ [ nonempty response; urls_are_http response; titles_are_present response ]
  | "serper", 1 -> base @ [ nonempty response; domains_constrain "python.org" response ]
  | "scrappa", 0 -> base @ [ nonempty response; urls_are_http response; titles_are_present response ]
  | "scrappa", 1 -> base @ [ nonempty response; domains_constrain "python.org" response ]
  | "linkup", 0 -> base @ [ nonempty response; answer_present response ]
  | "linkup", 1 -> base @ [ notice_contains "country/language" response ]
  | "exa", 0 ->
      base @ [ nonempty response; first_url_is_http response; notice_lacks "API key" response ]
  | "exa:free", 0 -> base @ [ nonempty response; first_url_is_http response ]
  | "freeserp", 0 ->
      base @ [ nonempty response; any_url_and_snippet response; urls_are_http response; titles_are_present response; no_text response ]
  | "parallel", 0 -> base @ [ nonempty response; urls_are_http response; titles_are_present response; no_snippet response ]
  | "parallel", 1 -> base @ [ nonempty response; domains_constrain "python.org" response ]
  | "parallel:free", 0 -> base @ [ nonempty response; urls_are_http response ]
  | "searxng", 0 -> base @ [ nonempty response; urls_are_http response; titles_are_present response ]
  | "tavily", 0 ->
      base @ [ nonempty response; urls_are_http response; titles_are_present response; text_instead_of_snippet response; answer_present response ]
  | "tavily", 1 -> base @ [ nonempty response; domains_constrain "python.org" response ]
  | "tinyfish", 0 -> base @ [ nonempty response; urls_are_http response; titles_are_present response; snippets_present response; no_text response ]
  | "algolia", 0 -> base @ [ nonempty response; urls_are_http response; titles_are_present response; snippets_present response; no_text response ]
  | "search1api", 0 -> base @ [ nonempty response; urls_are_http response; titles_are_present response; snippets_present response; no_text response ]
  | "anysearch", 0 -> base @ [ nonempty response; any_url_and_snippet response; urls_are_http response; titles_are_present response; no_text response ]
  | "serpapi", 0 -> base @ [ nonempty response; urls_are_http response; titles_are_present response; snippets_present response; no_text response ]
  | "querit", 0 -> base @ [ nonempty response; urls_are_http response; titles_are_present response; snippets_present response; no_text response ]
  | "deepseek", 0 -> base @ [ nonempty response; urls_are_http response; titles_are_present response; snippets_present response ]
  | _ ->
      [
        expect "this case has a ported assertion for the step"
          false
          (Printf.sprintf
             "no assertion is ported for %s step %d: add the adapter's arm rather than a generic check"
             name step);
      ]

(* {1 Fetch} *)

let text_of (page : Model.fetch_response) = Option.value ~default:"" page.Model.text

let verify_fetch case (page : Model.fetch_response) =
  match case with
  | Cases.Local ->
      [
        expect "the page came back with a 200" (page.Model.status_code = Some 200)
          (Printf.sprintf "the response's status was %s"
             (match page.Model.status_code with Some code -> string_of_int code | None -> "absent"));
        expect "the content type is text/html" (page.Model.content_type = Some "text/html")
          (Printf.sprintf "the content type was %s"
             (match page.Model.content_type with Some kind -> kind | None -> "absent"));
        expect "the extracted text carries the page's own word"
          (contains (String.lowercase_ascii (text_of page)) "example")
          "the extraction came back without the page's text";
        expect "the response names the URL the harness asked for"
          (String.equal page.Model.requested_url "https://example.com/")
          (Printf.sprintf "the response was for %S" page.Model.requested_url);
      ]
  | Cases.Metadata | Cases.Jina | Cases.Scrappa | Cases.Tavily | Cases.Linkup ->
      [
        expect "this case has a ported assertion"
          false
          "no page-shape assertion is ported for this case yet: add its arm rather than a generic check";
      ]

(* {1 Agent} *)

let verify_agent ~depth ~model (response : Model.answer_response) =
  let depth_ok =
    match (depth, response.Model.depth) with
    | Model.Brief, Model.Brief | Model.Report, Model.Report -> true
    | _ -> false
  in
  [
    expect "the answer carries prose" (String.length (String.trim response.Model.answer) > 0)
      "the model returned no prose";
    expect "the response names the operator's model" (String.equal response.Model.model model)
      (Printf.sprintf "the response names %S, not %S" response.Model.model model);
    expect "the response reports the depth that was asked for" depth_ok
      "the response's depth differs from the requested one";
    (match depth with
    | Model.Brief ->
        expect "a brief call makes exactly one search" (response.Model.searches = 1)
          (Printf.sprintf "a brief call reported %d searches" response.Model.searches)
    | Model.Report -> passing "a report call is free to search more than once");
    expect "the answer is cited, or says it is uncited"
      (response.Model.sources <> []
      ||
      match response.Model.notice with
      | Some notice -> contains notice "no citations"
      | None -> false)
      "the answer carried neither a validated source nor an uncited notice";
  ]

(* {1 Classification} *)

let quota_limited message = contains message "Do not retry immediately."

let failed_count checks = List.length (List.filter (fun check -> Option.is_some check.failure) checks)

let summary checks =
  let total = List.length checks in
  let failed = failed_count checks in
  if failed = 0 then Printf.sprintf "passed (%d check%s)" total (if total = 1 then "" else "s")
  else Printf.sprintf "FAILED: %d of %d checks failed" failed total
