(** Tavily extract — keyed fallback. *)

type config = {
  net : Fallback.net;
  check : Remote_target.check;
  max_text_chars : int;
  api_key : string;
  timeout_seconds : float;
}

val tavily_extract_endpoint : string

val fetch :
  config -> string -> offset:int -> max_chars:int option -> (Fallback.page, Fallback.error) result
