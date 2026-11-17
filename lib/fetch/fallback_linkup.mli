(** Linkup fetch — keyed rendering fallback. *)

type config = {
  net : Fallback.net;
  check : Remote_target.check;
  max_text_chars : int;
  api_key : string;
}

val linkup_fetch_endpoint : string

val fetch :
  config -> string -> offset:int -> max_chars:int option -> (Fallback.page, Fallback.error) result
