(** TinyFish — a keyed aggregator whose search API costs nothing to call.

    Port of [src/seekwright/providers/tinyfish.py]. It bills its agent and browser
    work, not search: a Search API request is free whatever the account balance, so
    [default_cost] on the row is 0.0 and {!cost_for} is flat. Free and {i keyed} at
    the same time, which is what puts it in the free set the router may walk while
    still requiring a key: the key says whose account a request runs against, and an
    account without Search API access answers 402.

    Endpoint: [GET https://api.search.tinyfish.ai] with the key in the vendor's own
    header spelling, [X-API-Key]. Every constraint but one has a native parameter,
    which is why a fully constrained query draws no notice at all.

    Result count is the exception in a different way: there is no result-count
    parameter upstream, so the slice in {!parse} is the only place [max_results]
    takes effect, and the vendor may answer with more records than a caller asked
    for and did not get.

    402 joins 429 in the quota row, where [scrappa]'s 402 is its x402 payment lane
    and [serper]'s is a spent credit pack: here it reads "Search API access is
    required for your account", which is an account question rather than a malformed
    request, and the quota class is what moves the walk off the name. *)

val name : string
(** ["tinyfish"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://api.search.tinyfish.ai]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same destination as a grant entry, so the factory builds the one allowlist
    entry this adapter can satisfy. *)

val recency_minutes : Seekwright.Model.recency -> int
(** The freshness window in minutes: 1, 7, 30 and 365 fixed days, matching the
    [fromDate] arithmetic [linkup] and the [published_from] window [freeserp] use.
    A [recency_minutes] value is a count of minutes upstream, not a calendar
    boundary, so no clock is involved. *)

val request_uri : Seekwright.Provider.search_query -> Uri.t
(** The GET's URL. The two domain lists are {i comma-joined} into one parameter
    each rather than repeated, [location] is the country upper-cased as the
    documented examples spell it, [language] is lower-cased, and an absent
    constraint sends no parameter rather than a default that would narrow the
    search unasked. *)

val parse :
  snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [results[]]: position, site_name, title, snippet, url, date. A SERP backend, so
    [snippet] is filled and [text] never is; [position] and [site_name] are dropped
    because nothing in the surface carries a rank. Records without a [url] or a
    [title] are dropped, and a field of the wrong type counts as absent rather than
    failing the hit. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD: flat, and zero at the row's default. The [max_results]
    argument is ignored rather than absent because callers treat [cost_for] as the
    same duck-typed extra on every adapter. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [key] is mandatory even though the search is
    free: the account is what the 402 row is about, and without a key there is no
    account to answer. [cost_per_1k] is reporting only; the registry row's
    [default_cost] is the figure the factory builds with, so the two move
    together. *)
