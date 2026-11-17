(** Crawl4AI — self-hosted renderer fallback. *)

type config = {
  net : Fallback.net;
  check : Remote_target.check;
  max_text_chars : int;
  base_url : string;
  token : string option;
}

val crawl4ai_crawl_path : string

val fetch :
  config -> string -> offset:int -> max_chars:int option -> (Fallback.page, Fallback.error) result
