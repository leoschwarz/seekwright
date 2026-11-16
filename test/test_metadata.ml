(* Packaging metadata has to agree across four surfaces no compiler
   relates. [dune-project] is the version and licence owner, the two generated
   opam files are what opam reads, [lib/version.ml] is what code reads, and the
   MCP [serverInfo] is a separate protocol identity pinned by a transcript.
   This suite reads the source files from the build sandbox, so a hand-edit of a
   generated manifest or a stale literal fails here rather than at install time.

   The installed artifact has no resource directory to lose: the prompts and the
   dashboard are embedded, so "installed resource availability" is the check
   that those values are present and the dashboard is the page the route serves. *)

module Fetcher = Seekwright_fetch.Fetcher
module Version = Seekwright.Version
module Config = Seekwright.Config
module Prompts = Seekwright.Prompts
module Agent = Seekwright.Agent
module Dashboard_html = Seekwright.Dashboard_html

let read = Test_support.read_file

(* [dune-project] keeps its version and licence on one line each; the parser is
   deliberately the same shape as the file so a malformed owner fails loudly
   instead of matching some unrelated later field. *)
let head_field ~file ~field =
  let prefix = "(" ^ field ^ " " in
  let matches line =
    let line = String.trim line in
    if not (String.starts_with ~prefix line) then None
    else
      let value = String.sub line (String.length prefix) (String.length line - String.length prefix) in
      Some (String.trim (String.concat "" (String.split_on_char ')' value)))
  in
  match List.filter_map matches (String.split_on_char '\n' (read file)) with
  | [ value ] -> value
  | [] -> Alcotest.failf "%s has no (%s …) field" file field
  | _ -> Alcotest.failf "%s has more than one (%s …) field" file field

let dune_project_version () = head_field ~file:"../dune-project" ~field:"version"

let dune_project_license () = head_field ~file:"../dune-project" ~field:"license"

let unquote value =
  let value = String.trim value in
  let n = String.length value in
  if n >= 2 && value.[0] = '"' && value.[n - 1] = '"' then String.sub value 1 (n - 2)
  else value

let dune_project_homepage () =
  unquote (head_field ~file:"../dune-project" ~field:"homepage")

let manifest_value ~file ~field =
  let prefix = field ^ ": " in
  let matches line =
    let line = String.trim line in
    if not (String.starts_with ~prefix line) then None
    else Some (String.trim (String.sub line (String.length prefix) (String.length line - String.length prefix)))
  in
  match List.filter_map matches (String.split_on_char '\n' (read file)) with
  | value :: _ -> value
  | [] -> Alcotest.failf "%s has no %s field" file field

(* The generated opam file quotes its strings; the version and licence fields
   are the two this release claims. *)
let quoted value = "\"" ^ value ^ "\""

let test_the_version_has_one_owner () =
  let version = dune_project_version () in
  Alcotest.(check string) "the generated module reads dune-project" version Version.package;
  let caps = read "../mcp-caps.opam" in
  let seekwright = read "../seekwright.opam" in
  Alcotest.(check string)
    "mcp-caps.opam version" (quoted version)
    (manifest_value ~file:"../mcp-caps.opam" ~field:"version");
  Alcotest.(check string)
    "seekwright.opam version" (quoted version)
    (manifest_value ~file:"../seekwright.opam" ~field:"version");
  Test_support.includes "the seekwright manifest carries the owner" (quoted version) seekwright;
  Test_support.includes "the mcp-caps manifest carries the owner" (quoted version) caps

let test_the_user_agent_reads_the_owner () =
  let expected = "seekwright/" ^ Version.package ^ " (+" ^ Version.project_url ^ ")" in
  Alcotest.(check string) "the module derives the User-Agent" expected Version.user_agent;
  Alcotest.(check string) "the config default is the owner" expected Config.default_user_agent;
  Alcotest.(check string) "the fetcher default mirrors the owner" expected Fetcher.default_user_agent

let test_the_project_url_agrees () =
  let expected = dune_project_homepage () in
  Alcotest.(check string) "the generated module reads the owner" expected Version.project_url;
  Alcotest.(check string)
    "mcp-caps.opam declares it" (quoted expected)
    (manifest_value ~file:"../mcp-caps.opam" ~field:"homepage");
  Alcotest.(check string)
    "seekwright.opam declares it" (quoted expected)
    (manifest_value ~file:"../seekwright.opam" ~field:"homepage")

let test_the_licence_is_apache_2_0 () =
  Alcotest.(check string) "dune-project declares it" "Apache-2.0" (dune_project_license ());
  Alcotest.(check string)
    "mcp-caps.opam declares it" (quoted "Apache-2.0")
    (manifest_value ~file:"../mcp-caps.opam" ~field:"license");
  Alcotest.(check string)
    "seekwright.opam declares it" (quoted "Apache-2.0")
    (manifest_value ~file:"../seekwright.opam" ~field:"license");
  Test_support.includes "LICENSE is the Apache-2.0 text" "Apache License" (read "../LICENSE");
  Test_support.excludes "no MIT declaration survives" "license: \"MIT\"" (read "../mcp-caps.opam");
  Test_support.excludes "no MIT declaration survives" "license: \"MIT\"" (read "../seekwright.opam")

let test_the_dependency_floors_agree () =
  let caps = read "../mcp-caps.opam" in
  let seekwright = read "../seekwright.opam" in
  List.iter
    (fun (name, manifest) ->
      Test_support.includes (name ^ " needs the tested compiler") "\"ocaml\" {>= \"5.3.0\"}" manifest;
      Test_support.includes
        (name ^ " pins mcp-kit")
        "\"mcp-kit\" {= \"0.2.0\"}" manifest;
      Test_support.includes
        (name ^ " pins every mcp-kit component")
        "\"mcp-kit-cohttp-eio\" {= \"0.2.0\"" manifest;
      Test_support.excludes
        (name ^ " leaves no moving mcp-kit floor")
        "\"mcp-kit-cohttp-eio\" {>= " manifest)
    [ ("mcp-caps.opam", caps); ("seekwright.opam", seekwright) ];
  let project = read "../dune-project" in
  Test_support.excludes "the old compiler floor is gone" "(>= 5.1)" project;
  Test_support.includes "the pin is in the owner" "(= 0.2.0)" project

let test_the_mcp_identity_is_separate () =
  Alcotest.(check string) "the protocol value is unchanged" "0.1.0" Version.mcp_server;
  Alcotest.(check bool)
    "it is not the package release" true
    (not (String.equal Version.mcp_server Version.package));
  Test_support.includes
    "the stdio golden pins the same serverInfo"
    ("\"serverInfo\":{\"version\":\"" ^ Version.mcp_server ^ "\",\"name\":\"seekwright\"}")
    (read "../bin/smoke.expected")

let test_the_embedded_resources_are_present () =
  let nonempty name text =
    Alcotest.(check bool) name true (String.length text > 0)
  in
  nonempty "server instructions" Prompts.server_instructions;
  nonempty "search description" Prompts.search_description;
  nonempty "fetch description" Prompts.fetch_description;
  nonempty "answer description" Prompts.answer_description;
  nonempty "answer system prompt" Prompts.answer_system_prompt;
  nonempty "dashboard page" Dashboard_html.dashboard_html;
  Alcotest.(check string)
    "the answer prompt has one owner" Agent.answer_system_prompt
    Prompts.answer_system_prompt;
  Test_support.includes "the dashboard is the served page" "data-testid=\"dashboard\""
    Dashboard_html.dashboard_html

let () =
  Alcotest.run "metadata"
    [
      ( "version",
        [ Alcotest.test_case "one owner" `Quick test_the_version_has_one_owner ] );
      ( "user-agent",
        [
          Alcotest.test_case "reads the owner" `Quick test_the_user_agent_reads_the_owner;
          Alcotest.test_case "project URL agrees" `Quick test_the_project_url_agrees;
        ] );
      ( "licence",
        [ Alcotest.test_case "Apache-2.0" `Quick test_the_licence_is_apache_2_0 ] );
      ( "dependencies",
        [ Alcotest.test_case "floors agree" `Quick test_the_dependency_floors_agree ] );
      ( "mcp",
        [ Alcotest.test_case "serverInfo is separate" `Quick test_the_mcp_identity_is_separate ] );
      ( "resources",
        [ Alcotest.test_case "embedded" `Quick test_the_embedded_resources_are_present ] );
    ]
