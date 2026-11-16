(** Model-facing prose: server instructions, tool descriptions, and agent mode system prompt. *)

val server_instructions : string
(** MCP server instructions. *)

val search_description : string
val fetch_description : string

val answer_description : string
(** Tool descriptions. *)

val answer_system_prompt : string
(** Agent mode system prompt. *)
