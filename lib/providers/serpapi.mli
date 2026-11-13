(** SerpAPI — Google SERP behind one account key, one search per call.

    Port of [src/seekwright/providers/serpapi.py]. The free plan is {b 250
    searches/month at $0} (50/hour, no card), so [cost_per_1k] defaults to
    [0.0] — the plan an install most often runs on. A paid plan bills per search
    and an operator on one corrects the figure in config; nothing routes on it.
    Only {b successful} searches count, so the parameter-less connectivity probe
    is free.

    Endpoint: [GET https://serpapi.com/search].

    Redaction: this is the one adapter in the inventory whose credential rides
    {b in the query string} — the vendor's documented shape, diverging from this
    tree's header convention. That makes the request URL a secret surface: no
    exception or body is interpolated into a failure message here, and every line
    naming one of these URLs goes through
    {!Seekwright.Provider.redact_url}.

    Constraints: it is the second adapter (after [scrappa]) that honours every
    bucket and files no notice at all. Domains ride [site:] operators in [q],
    [gl]/[hl] are native, [tbs] carries the date restriction with Google's own
    [qdr:] codes, and [safe] carries safe-search for both values.

    402 and 429 share the quota sentence: 429 is documented as the hourly
    throughput limit {i or} an exhausted account, and a keyed client cannot tell
    which one it heard. *)

val name : string
(** ["serpapi"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://serpapi.com/search]. *)

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
(** The adapter as a provider value. [key] is mandatory: the 250 free searches a
    month are an account quota, and the key names whose quota a search spends. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat: one search per call, whatever [max_results] says.
    The argument is ignored rather than absent because callers treat [cost_for] as a
    duck-typed method and other adapters do scale with it. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [organic_results[]] (title, link, snippet, date). The other element families
    ([answer_box], [knowledge_graph], [related_questions], …) are dropped rather
    than modelled, as [serper] reads only [organic]. [date] is a display string
    ([5 days ago]), kept when it is a string and dropped otherwise. *)
