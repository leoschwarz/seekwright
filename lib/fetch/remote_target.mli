(** Target validation and public address verification for remote fallbacks. *)

type 'tag t = 'tag Eio.Net.t

val make : 'tag Eio.Net.t -> 'tag t

val check : 'tag t -> string -> (string, string) result
