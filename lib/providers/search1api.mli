(** Search1API — multi-engine SERP backend.

    Endpoint: [POST https://api.search1api.com/search] with bearer token.

    Billed flat per basic search request. Supports domains, language, and recency window words
    ("day", "week", "month", "year"). 402/429 indicates credit exhaustion or rate limit. *)

val name : string
(** ["search1api"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** [https://api.search1api.com/search]. *)

val make :
  cost_for:(int -> float) ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the Search1API provider. [cost_for], [key], and [net] are mandatory. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses hits from [results[]]. *)
