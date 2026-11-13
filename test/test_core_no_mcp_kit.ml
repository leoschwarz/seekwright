(* The plan keeps the registry, policy and authority core free of mcp-kit so the
   capability layer stays separable from the protocol (§2). A build dependency
   would not catch the drift — one import in the wrong module is enough — so the
   rule is checked against the source text instead.

   The list comes from the directory (test/dune puts the library sources in the
   sandbox), with only server.ml exempt, so a new sibling cannot pass by not
   being named. The checks below fail if the directory is empty or the adapter
   is missing, which is what stops a glob that matched nothing from passing
   vacuously. *)

open Test_support

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

let read path =
  if not (Sys.file_exists path) then
    Alcotest.failf "%s is missing from the test sandbox (test/dune declares it)" path;
  read_file path

(* The check is over the whole file text, not the import lines: prose that
   spells a module path is refused too. This suite's sandbox holds only the
   [.ml] files, so the interface half of the same rule lives in
   [test/log_guard/source_discipline.ml], whose [source_tree] dependency puts
   the [.mli] files in reach. *)
let no_module_imports_mcp_kit () =
  List.iter
    (fun module_name ->
      let path = Filename.concat library_dir module_name in
      Alcotest.(check bool)
        (path ^ " names no Mcp_kit module")
        false
        (contains ~haystack:(read path) ~needle:"Mcp_kit"))
    (core_modules ())

let the_adapter_is_still_there () =
  let source = read (Filename.concat library_dir adapter) in
  Alcotest.(check bool) "server.ml is the mcp-kit adapter" true
    (contains ~haystack:source ~needle:"Mcp_kit");
  Alcotest.(check bool) "and it is the only one" true
    (List.for_all
       (fun module_name ->
         not
           (contains
              ~haystack:(read (Filename.concat library_dir module_name))
              ~needle:"Mcp_kit"))
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
