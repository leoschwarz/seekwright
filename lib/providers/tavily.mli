(** Tavily — content-style search: page extracts rather than SERP snippets, at
    about $8/1k for a basic search.

    Port of [src/seekwright/providers/tavily.py]. Its price is the one the row
    carries and nothing else: 1,000 credits a month on the free plan, then $0.008 a
    credit, one credit per basic search whatever the result count, which is why
    [default_cost] is 8.00 and why {!cost_for} is flat — unlike
    {!Seekwright_providers.Serper.cost_for}, which doubles past ten results.

    Endpoint: [POST https://api.tavily.com/search] with the key as a bearer token.
    A content backend, so [results[].content] goes into [Result.text] and [snippet]
    is never filled; the cap that matters is therefore [policy.max_result_text_chars]
    rather than the snippet one, and [text_truncated] says which extracts were cut.

    This is also the adapter that answers with prose of its own: [include_answer]
    asks Tavily for it and {!answer} carries it into
    [Provider.outcome.answer], which the [search] tool returns as its [answer]
    field. The model is not involved: the prose is the vendor's, over the vendor's
    own retrieval.

    Constraints: both domain lists, [time_range] for recency, [country], [language]
    and [safe_search] are all native parameters, so a fully constrained query draws
    no notice — with one exception, that [country] is a {i closed enum} of English
    names rather than the ISO alpha-2 code the request surface carries. {!country_param}
    maps a code onto the enum and answers [None] for anything outside it; the
    parameter is then dropped and the notice names the country half, because the
    alternative — sending an unrecognised name — leaves the caller believing its
    filter was applied.

    432 joins 429 in the quota row: 432 is Tavily's monthly-credits-exhausted code
    and 429 its short-term rate limit, and both mean this name cannot serve the
    next call either. *)

val name : string
(** ["tavily"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://api.tavily.com/search]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same destination as a grant entry, so the factory builds the one allowlist
    entry this adapter can satisfy. *)

val country_by_code : (string * string) list
(** The vendor's closed [country] enum, spelled as ISO alpha-2 codes plus the two
    aliases callers write that the enum omits. Exported because the enum is vendor
    data a reader may want to check against the API reference without reading the
    lookup. *)

val country_param : string -> string option
(** [country_param value] maps a caller's country onto that enum: a name in the
    enum goes through lowercased and trimmed, a code goes through the table, and
    anything else answers [None] — which is the caller's signal to drop the
    parameter and file the notice rather than send a filter upstream will ignore. *)

val request_body : country:string option -> Seekwright.Provider.search_query -> string
(** The request document. [country] is the {i mapped} country, not the raw one: the
    lookup is the adapter's own, and taking the mapped value here is what lets a
    test see that an unmappable code is absent from the body rather than sent.
    [search_depth] and [include_answer] are pinned at [basic], and [include_usage]
    is asked for on every call — see {!cost_for} for what that figure is and is
    not used for here. *)

val parse :
  text_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [results[]]: title, url, content, score, published_date. A content backend, so
    [text] carries the extract and [snippet] stays empty, and [text_truncated] says
    which extracts the cap cut. Records without a [url] or a [title] are dropped,
    and a field of the wrong type counts as absent rather than failing the hit. *)

val answer : Yojson.Safe.t -> string option
(** The vendor's own answer, or [None] when the payload has none or holds
    something that is not a string. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD, flat: one credit per basic search. The [max_results]
    argument is ignored rather than absent because callers treat [cost_for] as the
    same duck-typed extra on every adapter. *)

val make :
  ?cost_per_1k:float ->
  ?text_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [key] is mandatory because Tavily's free tier
    is an account quota rather than an anonymous endpoint: [exa] and [parallel] each
    answer without a key and therefore each carry a [‥:free] row, [tavily] does
    neither, and the key names whose 1,000 credits a search spends. [text_chars] is
    [policy.max_result_text_chars], and the registry row's [default_cost] is the
    figure the factory builds with, so the two move together. *)
