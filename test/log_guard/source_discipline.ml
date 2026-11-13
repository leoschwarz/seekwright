(* F1.3's source guard: some log rules are not expressible as a type.

   [Printexc.to_string] is the wrong tool on a serving path even when it looks
   sanitised — an [Eio.Io] payload names the path or endpoint that failed, and an
   adapter's frames can hold the header the credential rode in. The rule is
   therefore "no raw exception rendering in the library", not "render it
   carefully". The one exemption is [bin/main.ml], the thin CLI boundary, which
   owns operator-facing stderr; no library module may write there at all, because
   under stdio an accidental stderr write is tolerated while an accidental stdout
   write corrupts the protocol.

   The scan is over whole text, not import lines. A module reference in a
   comment would not compile, but a type reference in an interface would, and the
   capability core's separation from mcp-kit is exactly an interface property —
   [server.mli] is the one file allowed to name it, and the positive control
   below proves the scan can see [Mcp_kit] when it is there.

   Non-vacuity is a case, not a hope: the tree must be substantial, the modules
   this guard is about must be present, and both positive controls must fire. A
   copied empty sandbox fails instead of passing silently. *)

module A = Alcotest
open Test_support

let read path =
  if not (Sys.file_exists path) then
    A.failf "%s is missing from the test sandbox (test/log_guard/dune declares it)" path;
  read_file path

let rec walk dir =
  Sys.readdir dir |> Array.to_list |> List.sort String.compare
  |> List.concat_map (fun name ->
         let path = Filename.concat dir name in
         match (try Some (Sys.is_directory path) with _ -> None) with
         | Some true -> walk path
         | Some false -> [ path ]
         | None -> [])

let is_source path =
  Filename.check_suffix path ".ml" || Filename.check_suffix path ".mli"

let scan roots = List.concat_map walk roots |> List.filter is_source

let count path = count_occurrences ~haystack:(read path) ~needle:"Mcp_kit"

let files = scan [ "../../lib"; "../../bin" ]

(* {1 The scan is a real scan} *)

let test_the_scan_is_not_vacuous () =
  A.(check bool) "the scan found a substantial tree" true (List.length files >= 40);
  List.iter
    (fun path ->
      A.(check bool) (path ^ " is an input to this suite") true
        (List.mem path files))
    [
      "../../lib/log.ml";
      "../../lib/server.ml";
      "../../lib/server.mli";
      "../../lib/usage.ml";
      "../../lib/caps/server.ml";
      "../../lib/caps/server.mli";
      "../../bin/main.ml";
    ]

(* {1 Raw exception rendering} *)

let cli_boundary = "../../bin/main.ml"

let test_no_exception_is_rendered_outside_the_cli () =
  List.iter
    (fun path ->
      if path <> cli_boundary then
        A.(check int)
          (path ^ " renders no exception")
          0
          (count_occurrences ~haystack:(read path) ~needle:"Printexc."))
    files

let test_the_cli_boundary_is_the_declared_exception () =
  (* The exemption is a file, not a mood: if this path moves, the allowlist
     above moves with it, and the case names it. The positive control is the
     stderr write that makes the exemption necessary in the first place. *)
  A.(check bool) "the thin CLI is where the exemption points" true
    (List.mem cli_boundary files);
  A.(check bool) "and it is the stderr boundary the allowlist exists for" true
    (contains ~haystack:(read cli_boundary) ~needle:"prerr_endline")

(* {1 Direct stderr writes} *)

let stderr_writers = [ "../../lib/log.ml"; cli_boundary ]

let stderr_tokens =
  [
    "prerr_endline";
    "prerr_string";
    "prerr_char";
    "Printf.eprintf";
    "Printf.keprintf";
    "output_string stderr";
    "flush stderr";
    "Sys.stderr";
  ]

let test_only_the_sink_and_the_cli_write_stderr () =
  List.iter
    (fun path ->
      if not (List.mem path stderr_writers) then
        List.iter
          (fun token ->
            A.(check int)
              (Printf.sprintf "%s writes no stderr (%s)" path token)
              0
              (count_occurrences ~haystack:(read path) ~needle:token))
          stderr_tokens)
    files

(* {1 The serving path's escape hatches} *)

let serving_path = [ "../../lib/log.ml"; "../../lib/server.ml"; "../../lib/usage.ml" ]

let test_the_serving_path_has_no_untyped_escape () =
  (* [failwith] and [invalid_arg] are the two ways a library turns a caller's
     input into an unclassified exception after the boundary promised values.
     F1.3's modules carry neither; a [raise] that remains is cancellation
     re-raised, which must not be swallowed. *)
  List.iter
    (fun path ->
      List.iter
        (fun token ->
          A.(check int)
            (Printf.sprintf "%s has no %s" path token)
            0
            (count_occurrences ~haystack:(read path) ~needle:token))
        [ "failwith"; "invalid_arg"; "Printexc." ])
    serving_path

(* {1 The capability core's dependency direction} *)

let caps_sources = scan [ "../../lib/caps" ]

let test_mcp_kit_stays_behind_the_adapter_interfaces () =
  A.(check bool) "the capability core was found" true
    (List.length caps_sources >= 10);
  let adapters = [ "../../lib/caps/server.ml"; "../../lib/caps/server.mli" ] in
  List.iter
    (fun path ->
      A.(check bool) (path ^ " is the adapter interface or implementation") true
        (List.mem path caps_sources);
      (* Positive control: both the implementation and the interface really do
         name the transport, so the negative scan below can fail. *)
      A.(check bool) (path ^ " names Mcp_kit") true (count path > 0))
    adapters;
  List.iter
    (fun path ->
      if not (List.mem path adapters) then
        A.(check int) (path ^ " names no Mcp_kit module") 0 (count path))
    caps_sources

let test_the_core_dune_stanza_names_only_the_core_transport () =
  let dune = read "../../lib/caps/dune" in
  match find_sub ~haystack:dune ~needle:"(libraries" () with
  | None -> A.fail "lib/caps/dune has no (libraries stanza"
  | Some at ->
      let rest = String.sub dune at (String.length dune - at) in
      let stanza =
        match find_sub ~haystack:rest ~needle:"))" () with
        | Some stop -> String.sub rest 0 stop
        | None -> rest
      in
      A.(check bool) "the core links mcp-kit, which server.ml uses" true
        (contains ~haystack:stanza ~needle:"mcp-kit");
      List.iter
        (fun transport ->
          A.(check bool)
            (Printf.sprintf "the core does not link %s" transport)
            false
            (contains ~haystack:stanza ~needle:transport))
        [ "mcp-kit.stdio"; "mcp-kit-eio"; "mcp-kit-cohttp-eio"; "mcp-kit-ppx" ]

let () =
  A.run "log-source-discipline"
    [
      ( "the scan",
        [ A.test_case "is not vacuous" `Quick test_the_scan_is_not_vacuous ] );
      ( "exceptions",
        [
          A.test_case "no exception is rendered outside the CLI" `Quick
            test_no_exception_is_rendered_outside_the_cli;
          A.test_case "the CLI boundary is the declared exemption" `Quick
            test_the_cli_boundary_is_the_declared_exception;
        ] );
      ( "stderr",
        [
          A.test_case "only the sink and the CLI write stderr" `Quick
            test_only_the_sink_and_the_cli_write_stderr;
        ] );
      ( "the serving path",
        [
          A.test_case "has no untyped escape" `Quick
            test_the_serving_path_has_no_untyped_escape;
        ] );
      ( "the capability core",
        [
          A.test_case "mcp-kit stays behind the adapter interfaces" `Quick
            test_mcp_kit_stays_behind_the_adapter_interfaces;
          A.test_case "the dune stanza links only the core transport" `Quick
            test_the_core_dune_stanza_names_only_the_core_transport;
        ] );
    ]
