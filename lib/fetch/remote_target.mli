(** The URL gate a remote route runs on its target, as a value. *)

type check = string -> (string, string) result

val make_check : net:_ Eio.Net.t -> private_web_allowed:bool -> check
(** [make_check ~net ~private_web_allowed] is the whole gate: shape validation, the host, then the
    public-address vet — the vet and the host check together skipped only when
    [private_web_allowed], which no remote route passes. It is handed to a reader as a function
    rather than a switch, so who may resolve a name is decided once by the factory and a reader's
    config carries no address family of its own. *)
