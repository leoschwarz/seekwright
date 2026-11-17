(** Jina Reader — keyless hosted fallback. *)

type config = {
  net : Fallback.net;
  check : Remote_target.check;
  max_text_chars : int;
  user_agent : string;
}

val jina_reader_endpoint : string

val split_reader_body : string -> (string * string) list * string

val fetch :
  config -> string -> offset:int -> max_chars:int option -> (Fallback.page, Fallback.error) result
