(* The plan keeps the registry, policy and authority core free of mcp-kit so the
   capability layer stays separable from the protocol (§2). A build dependency
   would not catch the drift — one import in the wrong module is enough — so the
   rule is checked against the source text instead.

   The file list is written out rather than read from the directory: a glob that
   matched nothing would pass vacuously, and the last case below fails if the
   adapter module ever moves, which is what keeps this suite honest. *)

let core_modules =
  [ "error"; "event"; "authority"; "tool"; "registry"; "policy"; "policy_net" ]

let contains text needle =
  let n = String.length text and m = String.length needle in
  let rec from i =
    if i + m > n then false
    else if String.sub text i m = needle then true
    else from (i + 1)
  in
  from 0

let read path =
  if not (Sys.file_exists path) then
    Alcotest.failf "%s is missing from the test sandbox (test/dune declares it)" path;
  let channel = open_in path in
  let contents = really_input_string channel (in_channel_length channel) in
  close_in channel; contents

(* Only the module path is checked: prose in a comment may name mcp-kit freely,
   an import may not. *)
let no_module_imports_mcp_kit () =
  List.iter
    (fun module_name ->
      let path = "../lib/caps/" ^ module_name ^ ".ml" in
      Alcotest.(check bool)
        (path ^ " names no Mcp_kit module")
        false
        (contains (read path) "Mcp_kit"))
    core_modules

let the_adapter_is_still_there () =
  let source = read "../lib/caps/server.ml" in
  Alcotest.(check bool) "server.ml is the mcp-kit adapter" true (contains source "Mcp_kit");
  Alcotest.(check bool) "and it is the only one" true
    (List.for_all
       (fun module_name -> not (contains (read ("../lib/caps/" ^ module_name ^ ".ml")) "Mcp_kit"))
       core_modules)

let () =
  Alcotest.run "mcp-caps/imports"
    [
      ( "core-stays-mcp-kit-free",
        [
          Alcotest.test_case "no core module mentions mcp-kit" `Quick no_module_imports_mcp_kit;
          Alcotest.test_case "server.ml remains the only adapter" `Quick the_adapter_is_still_there;
        ] );
    ]
