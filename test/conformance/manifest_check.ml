(* The live driver's manifest pre-check: the scenarios the pinned runner reports
   for the pinned requirements date must still be exactly the scenarios the
   pinned requirements file names, before either side spends a run.

   It is a program of its own rather than lines of shell because the list
   grammar, the manifest grammar and the set comparison all belong to
   [Compare_common] — the same reader that scores the run afterwards. A shell
   spelling of any one of them could drift from the comparator and the gate
   would stop failing closed instead of failing.

   Every read failure is reported on stderr and exits 1, which is what the shell
   saw from the reader it replaces: a refusal to read the manifest or the
   transcript is a failed pre-check, never an empty expected set. *)

module C = Compare_common

let () =
  let args =
    C.parse_args ~program:"manifest_check" ~spec:[ ("manifest", true); ("list_output", true) ] ()
  in
  let errors = C.errors () in
  (try
     let expected = C.ids (C.opt_exn args "manifest") in
     let actual =
       match C.read_file (C.opt_exn args "list_output") with
       | Ok text -> C.runner_list text
       | Error message ->
           C.add errors ("runner list output unavailable: " ^ message);
           []
     in
     C.exact "official runner manifest" actual expected errors
   with C.Bad message -> C.add errors message);
  if C.any errors then (
    prerr_endline (String.concat "\n" errors.lines);
    exit 1)
