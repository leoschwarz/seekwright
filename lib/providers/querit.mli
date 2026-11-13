(** Querit — real-time SERP, 1,000 free calls/month, then $4/1k PAYG.

    Port of [src/seekwright/providers/querit.py]. The free plan is {b 1,000 calls
    a month with no payment method required}, so [cost_per_1k] defaults to [0.0] —
    the plan an install most often runs on. The PAYG tier bills $4/1,000 requests
    and an operator on it corrects the figure in config; nothing routes on it.
    The [/v1/contents] endpoint (+$1/1,000 pages) is deliberately not part of this
    adapter: a SERP backend fills [snippet], never [text], and [fetch] has its own
    extraction backends.

    Endpoint: [POST https://api.querit.ai/v1/search] with the key as a bearer
    token.

    The free plan answers at most {b 10} results, so [count] is clamped whatever
    [max_results] asks; fewer hits than asked is a shorter answer, not a dropped
    constraint — the reading [serpapi] gives its result count.

    Constraints: domains and dates ride native filter fields. [country] and
    [language] cross a {b strict enum}: the backend takes seventeen country names
    and eight language names, so each code is looked up, and one with no entry is
    {b dropped and noticed}, never sent as a value the endpoint would reject or
    silently ignore. There is no safe-search parameter.

    The 402/429 pair is one sentence: 429 is the documented 1 QPS free limit, and
    an exhausted monthly allowance answers the same code for a keyed client.

    Untested status: no live verification against the real endpoint has happened
    in-repo, on either side of the port — the [untested] disclosure says so. *)

val name : string
(** ["querit"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://api.querit.ai/v1/search]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same destination as a grant entry, so the factory builds the one allowlist
    entry this adapter can satisfy. *)

val max_results : int
(** The free plan's documented result cap: a caller asking for more is clamped,
    because the request never asks a plan for what it cannot give. *)

val language_names : (string * string) list
(** The eight-name [filters.languages.include] enum, indexed by ISO 639-1 code:
    the bridge between the wire's two-letter [language] and the backend's word
    list. *)

val country_names : (string * string) list
(** The seventeen-name [filters.geo.countries.include] enum, same bridge. *)

val language_param : string -> string option
(** [language_param code] is the enum entry for an ISO code, or [None] when the
    code has no entry — which is the fact that decides both whether the filter is
    sent and whether the notice names [language]. *)

val country_param : string -> string option
(** The same lookup for countries. *)

val request_body :
  country:string option ->
  language:string option ->
  Seekwright.Provider.search_query ->
  string
(** The request document. [country] and [language] are the {b resolved} enum
   values rather than the raw codes, because the lookup decides whether the filter
   rides at all; taking the resolved values here is what lets a suite pin a whole
   unmappable search's body without reaching the clock or the network. [count] is
   clamped to {!max_results}. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [results.result[]] (title, url, snippet, page_age) — [results] is an object and
    the hits live under its [result] key, the wire's shape. [sentence] (body text)
    arrives only behind [needContent: true] and [highlights] behind its request
    field; this adapter sends neither, so neither is read. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat: one call per search, whatever [count] says. The
    argument is ignored rather than absent because callers treat [cost_for] as a
    duck-typed method and other adapters do scale with it. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [key] is mandatory: the 1,000 free calls a
    month are an account quota, and the key names whose quota a search spends. *)
