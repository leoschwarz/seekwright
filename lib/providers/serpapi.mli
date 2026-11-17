(** SerpAPI — Google SERP backend with query-parameter credentials.

    Endpoint: [GET https://serpapi.com/search]. API key is sent as [api_key] query parameter; URLs
    are treated as sensitive.

    Honours all query constraints: domains, country ([gl]), language ([hl]), recency ([tbs]), and
    safe search ([safe]). 402/429 indicates quota exhaustion or rate limiting. *)

val name : string
(** ["serpapi"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** [https://serpapi.com/search]. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the SerpAPI provider. [key] and [net] are mandatory. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat per request. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses hits from [organic_results[]]. *)
