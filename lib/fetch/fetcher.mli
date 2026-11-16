(** Fetching a URL safely, behind the Net authority grant. *)

type fetched_image = Seekwright_wire.Page.image = { media_type : string; body : string }

type fetched_page = Seekwright_wire.Page.page = {
  url : string;
  title : string option;
  text : string;
  content_type : string option;
  status_code : int;
  truncated : bool;
  total_chars : int;
  path_addressable : bool;
  image : fetched_image option;
}

type refusal = Url_blocked of string | Redirect_blocked of string | Blocked of string

type error = Refusal of refusal | Failed of string

type t

val fetch :
  ?chain_timeout:Eio.Time.Timeout.t ->
  t ->
  string ->
  offset:int ->
  max_chars:int option ->
  (fetched_page, error) result
(** [fetch t url ~offset ~max_chars] fetches, extracts and windows to the slice (offset, offset +
    max_chars) in codepoints. [max_chars = None] means the fetcher's own configured default;
    {!total_chars} always reports the full extraction, whatever the window. *)

val default_user_agent : string

val make :
  net:Mcp_caps.Authority.Net.t ->
  extractor:Extractor.backend ->
  ?max_download_bytes:int ->
  ?max_text_chars:int ->
  ?max_redirects:int ->
  ?allow_images:bool ->
  ?user_agent:string ->
  ?workers:Extract_pool.t ->
  ?parse_timeout_seconds:float ->
  unit ->
  t

val validate_url : string -> (string, string) result

val window_text : string -> offset:int -> max_chars:int -> string * bool

val uncapped : int

val resolved_cap : int -> int option -> int

val image_types : string list

val sniff_image_type : string -> string option
