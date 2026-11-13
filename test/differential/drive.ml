(* The regeneration driver. It prints the OCaml projection of every case in one
   corpus directory, one tab-separated "<case>\t<line>" per projection line, in
   the case-name order the pinning script reads. [ocaml-tools/oracle/README.md]
   is the recipe; nothing here is part of [dune runtest], which consumes the
   goldens through the test stanzas below rather than this driver. *)

let read_file path =
  let channel = open_in_bin path in
  let length = in_channel_length channel in
  let text = really_input_string channel length in
  close_in channel;
  text

let () =
  Seekwright_diff.Canon.reset_key_environment ();
  match Array.to_list Sys.argv with
  | [ _; area; dir ] -> (
      match List.assoc_opt area Seekwright_diff.Projection.areas with
      | None ->
        prerr_endline (Printf.sprintf "no such area: %s" area);
        exit 2
      | Some project ->
          let names =
            Array.to_list (Sys.readdir dir)
            |> List.filter (fun name -> name <> "." && name <> "..")
            |> List.sort String.compare
          in
          List.iter
            (fun name ->
              let path = Filename.concat dir name in
              let stem = Filename.remove_extension name in
              let lines = if area = "config" then project path else project (read_file path) in
              List.iter (fun line -> print_endline (stem ^ "\t" ^ line)) lines)
            names)
  | _ ->
    prerr_endline "usage: drive.exe <area> <corpus-dir>";
    exit 2
