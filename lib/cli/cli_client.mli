(** Client verbs behind [search], [fetch] and [answer] via the REST projection. Builds request
    bodies, asks the caller for the transport to the [--server] origin, and returns rendered lines
    or errors. *)

type post = path:string -> string -> (int * string, string) result
(** [post ~path body] dials [path] with [body] and answers [(status, text)]. [Error] names socket or
    transport failures. *)

type dial = string -> (post, string) result
(** [dial server] answers with the transport that dials the origin [server], or [Error sentence]
    when that origin cannot be dialled at all. It is called once per run, with the origin [server]
    the [--server] flag named (or the default), so the caller — not this module — owns what that
    origin is confined to. *)

type verb = Search | Fetch | Answer

type rendered =
  | R_search of Seekwright.Model.search_response
  | R_fetch of Seekwright.Model.fetch_response
  | R_answer of Seekwright.Model.answer_response

val verb_of_string : string -> verb option

val strip_trailing_slash : string -> string

val error_message : int -> string -> string

val human_lines : rendered -> string list

val run : dial:dial -> verb:verb -> argv:string list -> (string option, string * int) result
(** [run ~dial ~verb ~argv] parses args, executes request, and returns output. Returns
    [Error (msg, 2)] on argument errors, [Error (msg, 1)] on an origin the caller refused to dial,
    on transport failures, and on a server error. *)
