(** TinyFish — keyed search aggregator with free Search API tier.

    Endpoint: [GET https://api.search.tinyfish.ai] with [X-API-Key] header.

    Search API calls are unmetered (0 cost). Results are sliced locally because the
    endpoint has no count parameter. Supports domains, recency ([recency_minutes]),
    country ([location]), and language. Safe search is unhonoured.

    402/429 indicates Search API access not enabled or rate limit. *)

val name : string
(** ["tinyfish"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** [https://api.search.tinyfish.ai]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** Policy grant destination matching {!endpoint}. *)

val recency_minutes : Seekwright.Model.recency -> int
(** Window length in minutes: Day (1440), Week (10080), Month (43200), Year (525600). *)

val request_uri : Seekwright.Provider.search_query -> Uri.t
(** Constructs the GET URI with query parameters. *)

val parse :
  snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses hits from [results[]]. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Returns 0.0. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the TinyFish provider. [key] and [net] are mandatory. *)
