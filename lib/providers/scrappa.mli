(** Scrappa — the same Google index as {i serper}, at a third of the price.

    Port of [src/seekwright/providers/scrappa.py]. Cost note, unchanged: ~$0.30/1k
    and {b one credit per request on every endpoint}, so {!cost_for} is flat and
    unlike {!Seekwright_providers.Serper} a 20-result search costs the same as a
    five-result one. It is the cheapest name in the inventory, which is why it is
    here at all.

    Endpoint: [GET https://scrappa.co/api/search-light], not the fuller
    [/api/search]: both cost one credit, but search-light returns 20 results
    instead of 10, and everything [/api/search] adds — knowledge graph, related
    questions, local results — is what the parse throws away anyway.

    Constraints: it is the only adapter that honours every bucket, so it files no
    notice at all. Domains ride [site:] operators, [gl]/[hl] are native, the date
    restriction is native, and [safe] carries safe-search for both values — [active]
    for [true], [off] for [false] — while an unanswered [safe_search] sends neither,
    which is not the same as asking for no filter.

    The date codes are the map this port carries rather than a verified one: the
    provider's entry in docs/reference/providers.md says so, and a live rejection
    means correcting the map and that entry together. *)

val name : string
(** ["scrappa"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://scrappa.co/api/search-light]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same destination as a grant entry, so the factory builds the one allowlist
    entry this adapter can satisfy. *)

val max_num : int
(** The endpoint's documented ceiling: a caller wanting more is clamped rather than
    paginated, because each page would be another credit. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [key] is mandatory: the 1,000 free calls a month
    are an account quota, and the key names whose quota a search spends. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat: one credit, whatever [num] says. The argument is
    ignored rather than absent because callers treat [cost_for] as a duck-typed
    method and other adapters do scale with it. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [organic_results[]] (position, title, link, snippet). A SERP backend, so
    [snippet] is filled and [text] never is. [search_information] and [pagination]
    are read by nobody: no [published_date] is invented, because search-light does
    not report one and guessing it from the snippet would be a guess. *)
