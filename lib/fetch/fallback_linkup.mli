(** Linkup fetch — keyed rendering fallback. *)

type 'tag config = {
  net : Fallback.net;
  target : 'tag Remote_target.t;
  max_text_chars : int;
  api_key : string;
}

val linkup_fetch_endpoint : string

val fetch :
  'tag config ->
  string ->
  offset:int ->
  max_chars:int option ->
  (Fallback.page, Fallback.error) result
