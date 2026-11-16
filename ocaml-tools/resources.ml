(* Embedded resource string printer for verification against oracle files. *)

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
