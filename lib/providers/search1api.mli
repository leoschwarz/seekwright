(** Search1API — multi-engine SERP, one credit per basic search.

    Port of [src/seekwright/providers/search1api.py]. A basic search is one
    credit whatever [max_results] says, so {!cost_for} is flat; Deep Search
    ([crawl_results > 0]) adds a credit per crawled page, and this adapter never
    sends [crawl_results] — deep search is a cost policy, not a caller choice,
    as [tavily] pins [search_depth].

    Endpoint: [POST https://api.search1api.com/search] with the key as a bearer
    token.

    [cost_per_1k] defaults to the entry Basic plan's rate ($0.76/1k; plans run
    $0.49–0.76/1k), so a cheaper plan corrects the figure in config and nothing
    routes on it.

    Constraints: domains, dates and language ride native parameters —
    [include_sites]/[exclude_sites]/[time_range]/[language] — so the domain and
    date buckets never fire. There is no country half (the geo bucket is split,
    naming [country] alone when it is set) and no safe-search parameter at all.

    The 402 row is this vendor's documented payment answer
    ([application/problem+json]): a bearer-keyed client that hears it is out of
    credits, so 402 and 429 share the quota sentence here. *)

val name : string
(** ["search1api"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://api.search1api.com/search]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same destination as a grant entry, so the factory builds the one allowlist
    entry this adapter can satisfy. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [key] is mandatory: the free credits are an
    account quota, and the key names whose quota a search spends. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat: one credit per basic search, whatever [max_results]
    says. The argument is ignored rather than absent because callers treat [cost_for]
    as a duck-typed method and other adapters do scale with it. *)

val request_body : Seekwright.Provider.search_query -> string
(** The request document: [query], [max_results], and the native filter fields only
    when asked. [time_range] carries the {i window word} ([day]/[week]/[month]/
    [year]) rather than a computed date, so no clock is needed here. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [results[]] (title, link, snippet, published_date). A SERP backend, so [snippet]
    is filled and [text] never is: [content] exists upstream only when
    [crawl_results > 0], which this adapter never sends, so it is never read. *)
