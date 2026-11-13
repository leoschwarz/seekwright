(** Parallel, in its two halves.

    Port of [src/seekwright/providers/parallel.py]: {e ParallelProvider}, the
    billed REST Search API on one key, and {e ParallelMcpProvider}, the hosted
    Search MCP reached anonymously and priced at zero.

    {2 Why the two halves are not one adapter with a mode switch}

    [parallel] is REST because that is the surface with the filter fields —
    [source_policy], [location], [mode] — and it bills per request by preset.
    [parallel:free] is MCP because that is the endpoint that answers without a
    account, and its tool surface takes no filter arguments at all. A key at the
    MCP endpoint would only bill what the anonymous call does for free, so the
    free row {i never} reads one, and the two names differ in transport, not
    tier. Unlike {e Exa}, there is no free-before-key ladder behind [parallel]:
    the REST half is the only thing that can bill, and it is the thing the name
    reaches directly.

    {2 The shared parse}

    Both halves read the same {e results[]} shape — REST from [resp.json()],
    MCP from a JSON text block the tool returns — so {!parse_results} is one
    function over a {!Yojson.Safe.t}, shared the way the Python module shares
    its [parse_results]. *)

(** {1 The endpoints and the tool} *)

val endpoint : Uri.t
(** [https://api.parallel.ai/v1/search], the billed REST endpoint; no [url]
    override exists for it, and the grant and the adapter take this one URI. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same REST endpoint in the policy's own words, derived from {!endpoint}. *)

val mcp_uri : Uri.t
(** [https://search.parallel.ai/mcp], the hosted MCP endpoint the free half
    dials; [[providers."parallel:free"] url] overrides it. *)

val mcp_tool : string
(** [web_search], which requires an [objective] and at least one
    [search_queries] entry — one caller string serves as both. *)

val recency_days : Seekwright.Model.recency -> int
(** [day]/[week]/[month]/[year] reach back 1/7/30/365 days — fixed 30-day
    months and 365-day years, coarse freshness rather than calendar
    arithmetic. *)

(** {1 The parts, exposed for the suites} *)

val after_date : now:(unit -> float) -> Seekwright.Model.recency -> string
(** [YYYY-MM-DD] for [now] minus the recency window: the UTC date arithmetic
    the request carries as [source_policy.after_date]. [~now] is epoch seconds,
    injected so a suite can pin the date without waiting for one. *)

val parse_results :
  Yojson.Safe.t -> limit:int -> text_chars:int -> Seekwright.Provider.hit list
(** {e results[]} onto {!Seekwright.Provider.hit}: a record with no URL is
    dropped, a null [title] falls back to the URL, [publish_date] passes
    through verbatim or stays absent, and the [excerpts] join with a blank line
    into the capped [text]. A non-object document is not a result set. *)

(** {1 The two shapes the registry builds} *)

val make :
  ?cost_per_1k:float ->
  ?text_chars:int ->
  ?mode:string ->
  key:string ->
  now:(unit -> float) ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The billed REST adapter. [~mode] is the operator's preset
    ([[providers.parallel] mode], default [fast]) and the thing that decides
    the price, so [cost_per_1k] tracks it rather than the result count —
    {!Seekwright.Provider.S.cost_for} is flat by arithmetic. The notices are
    hand-composed rather than the shared [ignored_constraints] sentence: the
    exclude-while-include rule is finer than any bucket, country rides
    [location], and the upstream [warnings] are echoed. *)

val make_mcp :
  ?cost_per_1k:float ->
  ?text_chars:int ->
  name:string ->
  uri:Uri.t ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.session
(** The anonymous hosted-MCP half: {!Seekwright.Provider.session} because it
    owns a session — [warmup] handshakes it early, [aclose] closes it — and
    {b no} [~auth] parameter, because a key here would only bill what the
    anonymous call answers for free. *)
