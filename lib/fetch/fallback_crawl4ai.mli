(** Crawl4AI — self-hosted renderer fallback. *)

type 'tag config = {
  net : Fallback.net;
  target : 'tag Remote_target.t;
  max_text_chars : int;
  base_url : string;
  token : string option;
}

val crawl4ai_crawl_path : string

val fetch :
  'tag config ->
  string ->
  offset:int ->
  max_chars:int option ->
  (Fallback.page, Fallback.error) result
