(** Serper.dev — the cheap raw SERP: Google's links and snippets at about $1/1k.

    Port of [src/seekwright/providers/serper.py]. It is an API with its own SERP
    cache, not a scrape, which is why it needs no timeout floor beyond the policy
    ({!Seekwright_factory.Registry} carries that row) and why the response is
    rich: this adapter reads [organic] and drops every other element family —
    knowledge panels, "people also ask", the rest — rather than modelling them.

    Endpoint: [POST https://google.serper.dev/search] with the key in the
    {i vendor's own} header spelling, [X-API-KEY]. The body is JSON, so unlike
    [scrappa] the request is a document rather than a query string, and that is
    also why no credential can ride a URL here.

    Pricing is the one thing about this name that is not flat: Serper bills
    {b two credits} once [max_results] passes {!credit_over}, so {!cost_for} says
    that and the figure [--check --live] prints is the one actually billed.

    Constraints: [site:] operators carry the domains, [gl] and [hl] are native,
    and [tbs] is the time restriction — three buckets honoured. There is {b no
    safe-search parameter at all}, which makes this adapter's [notice] the only
    thing standing between a caller that asked for filtered results and the belief
    that it got them.

    402 joins 429 in the quota row. Serper bills by credit pack, so a spent
    balance is a payment question; no vendor page pins which status a spent key
    answers with, and the classing is the house rule rather than a transcription
    of vendor prose. *)

val name : string
(** ["serper"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://google.serper.dev/search]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same destination as a grant entry, so the factory builds the one allowlist
    entry this adapter can satisfy. *)

val credit_over : int
(** The [max_results] above which a request costs two credits instead of one.
    {!Seekwright_factory.Registry} carries the same figure on the row, and a
    {i search} that bills twice without saying so is a billing surprise. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [key] is mandatory because this name is keyed
    despite its free credits — a metered allowance is a billable quota, and the key
    names whose quota the search spends. [cost_per_1k] is reporting only; the
    registry row's [default_cost] is the figure the factory builds with, so the two
    move together. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD, with the >10-results credit doubling applied. The flat
    [cost_per_1k /. 1000.] reading would under-report a 20-result search by half. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [organic[]] (link, title, snippet, date, ...). A SERP backend, so [snippet] is
    filled and [text] never is; [date] is kept only when it is a string, because a
    nested object there is upstream shape drift and must not become an internal
    error. Records without a [link] or a [title] are dropped, and a field of the
    wrong type counts as absent rather than failing the hit. *)
