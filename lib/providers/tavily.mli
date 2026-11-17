(** Tavily — content-style web search returning full page extracts.

    Endpoint: [POST https://api.tavily.com/search] with bearer token. Extract text is returned in
    [Result.text] rather than snippets. Optional vendor answer prose is returned in
    [Provider.outcome.answer].

    Supports domains, recency ([time_range]), language, safe search, and country (via closed
    English-name enum). 432 or 429 indicates credit exhaustion or rate limit. *)

val name : string
(** ["tavily"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** [https://api.tavily.com/search]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** Policy grant destination matching {!endpoint}. *)

val country_by_code : (string * string) list
(** Supported country enum mapping ISO alpha-2 codes and aliases to country names. *)

val country_param : string -> string option
(** Resolves a country code or name to the vendor's enum value. *)

val parse : text_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses hits from [results[]] into hits with extracts in [text]. *)

val answer : Yojson.Safe.t -> string option
(** Extracts the vendor's answer prose if present. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat per request. *)

val make :
  ?cost_per_1k:float ->
  ?text_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the Tavily provider. [key] and [net] are mandatory. *)
