(** FreeSerp — a keyless, whole-web SERP index: the first free name backed by one.

    Port of [src/seekwright/providers/freeserp.py]. Cost note, unchanged: FreeSerp
    cannot bill ("no key, no signup"), so [cost_per_1k] is 0. and [cost_for] is
    flat — which is why it is in the free set and the install default: nothing to
    configure. The other two keyless names are the anonymous halves of {i paid}
    endpoints; this index is the operator's own.

    Endpoint: [GET https://freeserp.ai/api.php?index=web], a JSON API over a
    whole-web crawl. The default index ([index=sites]) is a site-discovery index,
    never requested here. {!policy_endpoint} is the same endpoint in the form
    [Policy.with_endpoints] takes, so the grant an adapter is handed and the URL
    it dials are one fact rather than two that can drift.

    [engine_fallback: true] is a refusal, not a caveat: when their web engine does
    not answer, [index=web] is served site profiles the wire shape cannot carry, so
    the fallback fails and the walk moves on. The key is {b absent} on a healthy
    response, so only its present-and-[true] form fails.

    Constraints: no domain parameter, no [site:] operator, no country and no
    safe-search, so those are named in [notice]. [language] reaches [lang] and
    [recency] [published_from]; [published_to] stays unexposed for the reason
    [linkup] leaves its [toDate] alone.

    [total] is not mapped: it is the size of a top-100 candidate pool (the response
    says so in [total_note]), not a hit count. *)

val name : string
(** ["freeserp"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://freeserp.ai/api.php]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same destination as a grant entry, so the factory (P5) builds the one
    allowlist entry this adapter can satisfy. *)

val agent : string
(** What the operator asks a caller to send so its traffic is attributable. Not
    config: nothing upstream validates either this or [Seekwright.Provider.project_url], so
    there is nothing for an operator to set. *)

val max_size : int
(** [size] is 1-100 and [from + size <= 100]. The tool schema caps [max_results]
    at 20, but the adapter is callable directly, so the clamp lives here rather
    than being assumed. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  now:(unit -> float) ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [cost_per_1k] is reporting only, and the
    Python row's [default_cost] in [factory._PROVIDERS] is the figure that takes
    effect there — move both together or the adapter default becomes a lie.
    [snippet_chars] is [policy.max_snippet_chars], which the engine hands down
    rather than reading itself. [now] is the clock [recency] is measured against,
    in seconds since the Unix epoch: injected rather than read, so the date the
    adapter sends is a fact a test pins instead of one it recomputes. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [results[]]: {url, domain, title, snippet, published_at, ...}. A SERP
    backend, so [snippet] is filled and [text] never is. Records missing a title
    or URL are dropped, and a field of the wrong type counts as absent rather
    than failing the hit. *)
