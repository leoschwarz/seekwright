(* The six embedded oracle strings, printed byte for byte.

   The port has no package-data directory, so [lib/prompts.ml],
   [lib/agent.ml] and [lib/dashboard_html.ml] carry the Python tree's
   [resources/] files as quoted literals. That is a copy, and an unpinned copy
   is a fork with a comment claiming otherwise: the tool descriptions are
   model-facing contract, so the two deployments must not drift silently.
   [dune] diffs this printer's output against the read-only originals for each
   name below, and the alias makes the diff part of [dune runtest]. *)

let source name =
  match name with
  | "server_instructions" -> Ok Seekwright.Prompts.server_instructions
  | "search_description" -> Ok Seekwright.Prompts.search_description
  | "fetch_description" -> Ok Seekwright.Prompts.fetch_description
  | "answer_description" -> Ok Seekwright.Prompts.answer_description
  | "answer_system" -> Ok Seekwright.Agent.answer_system_prompt
  | "dashboard" -> Ok Seekwright.Dashboard_html.dashboard_html
  | other -> Error ("unknown resource " ^ other)

let () =
  match Array.to_list Sys.argv with
  | [ _; name ] -> (
      match source name with
      | Ok text -> print_string text
      | Error message ->
          prerr_endline ("resources: " ^ message);
          exit 2)
  | _ ->
      prerr_endline "usage: resources.exe NAME";
      exit 2
