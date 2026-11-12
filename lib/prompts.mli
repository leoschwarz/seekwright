(** The model-facing prose, ported from [src/seekwright/prompts.py] and its
    [resources/] files: the server instructions and the three tool
    descriptions, embedded verbatim, plus agent mode's system prompt (whose
    single home is {!Agent.answer_system_prompt}). Prose only, no logic. *)

val server_instructions : string
(** The MCP server's instructions, verbatim from [server_instructions.txt]. *)

val search_description : string
val fetch_description : string
val answer_description : string
(** The three tool descriptions, verbatim, no trailing newline. *)

val answer_system_prompt : string
(** Agent mode's system prompt, verbatim from [answer_system.txt] (trailing
    newline included), via {!Agent.answer_system_prompt}. *)
