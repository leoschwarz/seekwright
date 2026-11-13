(** The client verbs — the REST-projection client behind [search], [fetch]
    and [answer]. A client call carries no config, no provider and no key:
    it builds a request body ({!Seekwright.Cli_extract}), posts it, and
    renders or echoes the response.

    The network is an injected [post] seam, so the status handling, the
    error sentence and the exit code are testable without a socket;
    [bin/main.ml] supplies the real HTTPS/HTTP poster. Like every module in
    this library, nothing here writes a stream or calls [exit]: the result
    says what happened and the caller renders it. *)

type post = path:string -> string -> (int * string, string) result
(** [post ~path body] is the seam: dial [server ^ path] with [body] and
    answer [(status, text)]. An [Error] names why the socket never answered. *)

type verb =
  | Search
  | Fetch
  | Answer

type rendered =
  | R_search of Seekwright.Model.search_response
  | R_fetch of Seekwright.Model.fetch_response
  | R_answer of Seekwright.Model.answer_response
(** A decoded response, tagged by the verb that asked for it. The tags are
    not the verb constructors' names so both fit in one source file. *)

val verb_of_string : string -> verb option
(** [verb_of_string word] names the client verb, [None] for anything else. *)

val strip_trailing_slash : string -> string
(** [strip_trailing_slash url] drops one trailing [/], as the Python does
    when it joins the server URL to the route: [--server http://host:8000/]
    and [http://host:8000] post to the same path. *)

val error_message : int -> string -> string
(** [error_message status text] is the sentence for a non-200 answer: a JSON
    body's [error] field when it carries one, the trimmed body when it is
    not JSON, and nothing when it is empty. *)

val human_lines : rendered -> string list
(** [human_lines response] is the human rendering — the same layout the
    Python client prints, one list element per line. [--json] skips it and
    echoes the response text verbatim, which the caller does. *)

val run :
  post:post ->
  verb:verb ->
  argv:string list ->
  (string option, string * int) result
(** [run ~post ~verb ~argv] scans [argv] — [--json] and [--server] included,
    so the caller spells none of the verb's flags — builds and validates the
    request body, posts it and renders the answer. [Ok (json_line_or_none)]
    is success — the caller prints the line when the command asked for
    [--json]. [Error (sentence, exit_code)] is the caller's to print on
    stderr: exit 2 for a malformed command, exit 1 for a transport, status
    or decoding failure. *)
