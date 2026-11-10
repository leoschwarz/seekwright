(* The plan keeps the registry, policy and authority core free of mcp-kit so the
   capability layer stays separable from the protocol (§2). A build dependency
   would not catch the drift — one import in the wrong module is enough — so the
   rule is checked against the source text instead.

   The list comes from the directory (test/dune puts the library sources in the
   sandbox), with only server.ml exempt, so a new sibling cannot pass by not
   being named. The checks below fail if the directory is empty or the adapter
   is missing, which is what stops a glob that matched nothing from passing
   vacuously. *)

let library_dir = "../lib/caps"
let adapter = "server.ml"

let library_modules () =
  let names =
    Sys.readdir library_dir |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".ml")
    |> List.sort String.compare
  in
  if names = [] then Alcotest.failf "no modules found under %s" library_dir;
  if not (List.mem adapter names) then
    Alcotest.failf "%s is missing under %s (test/dune declares it)" adapter library_dir;
  names

let core_modules () = List.filter (fun name -> name <> adapter) (library_modules ())

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
      let path = Filename.concat library_dir module_name in
      Alcotest.(check bool)
        (path ^ " names no Mcp_kit module")
        false
        (contains (read path) "Mcp_kit"))
    (core_modules ())

let the_adapter_is_still_there () =
  let source = read (Filename.concat library_dir adapter) in
  Alcotest.(check bool) "server.ml is the mcp-kit adapter" true (contains source "Mcp_kit");
  Alcotest.(check bool) "and it is the only one" true
    (List.for_all
       (fun module_name -> not (contains (read (Filename.concat library_dir module_name)) "Mcp_kit"))
       (core_modules ()))

let () =
  Alcotest.run "mcp-caps/imports"
    [
      ( "core-stays-mcp-kit-free",
        [
          Alcotest.test_case "no core module mentions mcp-kit" `Quick no_module_imports_mcp_kit;
          Alcotest.test_case "server.ml remains the only adapter" `Quick the_adapter_is_still_there;
        ] );
    ]
