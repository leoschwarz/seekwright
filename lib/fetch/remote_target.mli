(** Target validation and public address verification for remote fallbacks. *)

type 'tag t = 'tag Eio.Net.t

val make : 'tag Eio.Net.t -> 'tag t

(** [vet ~net ~private_web_allowed raw] is the whole URL gate: shape validation,
    the host, then the public-address vet — the vet and the host check together
    skipped only when [private_web_allowed], which no remote route passes. *)
val vet : net:_ Eio.Net.t -> private_web_allowed:bool -> string -> (string, string) result

val check : 'tag t -> string -> (string, string) result
