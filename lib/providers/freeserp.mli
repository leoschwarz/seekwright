(** FreeSerp — keyless, whole-web SERP index.

    FreeSerp requires no API key and cannot bill. Part of the default free provider set.

    Endpoint: [GET https://freeserp.ai/api.php?index=web].

    [engine_fallback: true] indicates upstream web engine unavailability, treated as a transient
    refusal. Supports [language] and [recency]; domain and safe-search constraints are dropped. *)

val name : string
(** ["freeserp"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** [https://freeserp.ai/api.php]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** Policy grant destination matching {!endpoint}. *)

val agent : string
(** Attributable client identifier sent upstream. *)

val max_size : int
(** Documented maximum result count (100). *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  now:(unit -> float) ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the FreeSerp provider. [now] must return the current timestamp in seconds since Unix
    epoch. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses hits from [results[]]. *)
