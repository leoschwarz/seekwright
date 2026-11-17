(** Scrappa — search-light Google SERP backend.

    Endpoint: [GET https://scrappa.co/api/search-light] with API key header.

    Billed flat per request. Result count is capped at 20. Supports domains via site operators,
    country ([gl]), language ([hl]), recency ([dateRestrict]), and safe search ([safe]).

    402 or 429 indicates credit exhaustion or rate limiting. *)

val name : string
(** ["scrappa"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** [https://scrappa.co/api/search-light]. *)

val max_num : int
(** Documented maximum result count (20). *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the Scrappa provider. [key] and [net] are mandatory. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat per request. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses hits from [organic_results[]]. *)
