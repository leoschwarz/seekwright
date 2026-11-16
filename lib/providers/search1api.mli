(** Search1API — multi-engine SERP backend.

    Endpoint: [POST https://api.search1api.com/search] with bearer token.

    Billed flat per basic search request. Supports domains, language, and
    recency window words ("day", "week", "month", "year"). 402/429 indicates credit
    exhaustion or rate limit. *)

val name : string
(** ["search1api"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** [https://api.search1api.com/search]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** Policy grant destination matching {!endpoint}. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the Search1API provider. [key] and [net] are mandatory. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat per request. *)

val request_body : Seekwright.Provider.search_query -> string
(** Serialises the request JSON with filters. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses hits from [results[]]. *)
