(** Jina Reader — keyless hosted fallback. *)

type 'tag config = {
  net : Fallback.net;
  target : 'tag Remote_target.t;
  max_text_chars : int;
  user_agent : string;
}

val jina_reader_endpoint : string

val split_reader_body : string -> (string * string) list * string

val fetch :
  'tag config ->
  string ->
  offset:int ->
  max_chars:int option ->
  (Fallback.page, Fallback.error) result
