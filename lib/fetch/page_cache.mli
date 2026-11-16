(** Disk page cache: atomic storage and windowed retrieval of fetched pages behind an Authority.Fs
    grant. *)

type cached_page = {
  url : string;
  title : string option;
  text : string;
  content_type : string option;
  status_code : int;
  path_addressable : bool;
  total_chars : int;
  truncated : bool;
}

type t

val create :
  fs:Mcp_caps.Authority.Fs.t ->
  ?max_bytes:int ->
  ?max_entry_bytes:int ->
  ?ttl_seconds:float ->
  now:(unit -> float) ->
  unit ->
  t

val entry_name : rung:string -> url:string -> string

val of_page : Seekwright_wire.Page.page -> cached_page

val to_page : cached_page -> Seekwright_wire.Page.page

val get : t -> rung:string -> url:string -> cached_page option

val get_window : t -> rung:string -> url:string -> offset:int -> max_chars:int -> cached_page option

val put : t -> rung:string -> url:string -> page:cached_page -> bool

val stats : t -> int * int
