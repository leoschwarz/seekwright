(** Client verbs behind [search], [fetch] and [answer] via the REST projection. Builds request
    bodies, posts via an injected [post] seam, and returns rendered lines or errors. *)

type post = path:string -> string -> (int * string, string) result
(** [post ~path body] dials [server ^ path] with [body] and answers [(status, text)]. [Error] names
    socket or transport failures. *)

type verb = Search | Fetch | Answer

type rendered =
  | R_search of Seekwright.Model.search_response
  | R_fetch of Seekwright.Model.fetch_response
  | R_answer of Seekwright.Model.answer_response

val verb_of_string : string -> verb option

val strip_trailing_slash : string -> string

val error_message : int -> string -> string

val human_lines : rendered -> string list

val run : post:post -> verb:verb -> argv:string list -> (string option, string * int) result
(** [run ~post ~verb ~argv] parses args, executes request, and returns output. Returns
    [Error (msg, 2)] on argument errors, [Error (msg, 1)] on transport or server errors. *)
