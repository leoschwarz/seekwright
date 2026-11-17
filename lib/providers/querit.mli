(** Querit — SERP backend with strict enum mapping for geo/language.

    Endpoint: [POST https://api.querit.ai/v1/search] with bearer token.

    [count] is clamped to maximum 10 results. Supported countries (17 names) and languages (8 names)
    are strictly mapped from ISO codes; unmapped codes are dropped and reported in the notice.

    429 indicates rate limiting or quota exhaustion; 402 indicates account issue. *)

val name : string
(** ["querit"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://api.querit.ai/v1/search]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same destination as a grant entry, so the factory builds the one allowlist entry this
    adapter can satisfy. *)

val max_results : int
(** The free plan's documented result cap: a caller asking for more is clamped, because the request
    never asks a plan for what it cannot give. *)

val language_names : (string * string) list
(** The eight-name [filters.languages.include] enum, indexed by ISO 639-1 code: the bridge between
    the wire's two-letter [language] and the backend's word list. *)

val country_names : (string * string) list
(** The seventeen-name [filters.geo.countries.include] enum, same bridge. *)

val language_param : string -> string option
(** [language_param code] is the enum entry for an ISO code, or [None] when the code has no entry —
    which is the fact that decides both whether the filter is sent and whether the notice names
    [language]. *)

val country_param : string -> string option
(** The same lookup for countries. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [results.result[]] (title, url, snippet, page_age) — [results] is an object and the hits live
    under its [result] key, the wire's shape. [sentence] (body text) arrives only behind
    [needContent: true] and [highlights] behind its request field; this adapter sends neither, so
    neither is read. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat: one call per search, whatever [count] says. The argument is ignored
    rather than absent because callers treat [cost_for] as a duck-typed method and other adapters do
    scale with it. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [key] is mandatory: the 1,000 free calls a month are an account
    quota, and the key names whose quota a search spends. *)
