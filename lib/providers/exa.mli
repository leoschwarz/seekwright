(** Exa, reached as an MCP client rather than over HTTP.

    Port of [src/seekwright/providers/exa_mcp.py]: {e ExaMcpProvider} plus
    {e TieredExaProvider}. The one adapter where seekwright is an MCP {i client}
    — {!Mcp_client} is its session, and this module is the tool call, the
    block-format parser, and the price around them.

    Two facts the live endpoint taught the oracle, both verified again from
    this port (plans/seekwright-ocaml-port.md, F4.2): the answer is {b plain
    formatted text}, not [structuredContent], parsed out of a
    [Title:]/[URL:]/[Published:]/[Highlights:] block format; and one
    endpoint answers both credentials — anonymous on a rate-limited free plan
    and authenticated on a paid one — which is why a key here is not a
    capability upgrade but the difference between $0 and ~$7/1k for identical
    results. {e TieredExaProvider} spends the free tier first for exactly that
    reason, and {!make_mcp} behind the [exa:free] name is the deployment's way
    of saying {i this name may never spend}.

    {2 The ladder}

    Free before key on {b any} free-tier failure, not only a classified quota:
    Exa's wording for exhaustion has never been observed, so a misclassification
    costs one paid search, not the tier. A monotonic clock bounds the cooldown —
    a wall-clock adjustment must not extend it — and the moment the deployment
    stopped being free is a [exa.escalated] warning, a billed-by-cooldown call an
    [exa.cooldown] info line, and a both-tiers-down failure an [exa.both_failed]
    error. The caller always learns a key was spent: the notice says so on the
    success, and the failure message carries both halves. *)

(** {1 The endpoint and its tool} *)

val default_uri : Uri.t
(** [https://mcp.exa.ai/mcp], the one documented endpoint; [[providers.exa] url]
    and [[providers."exa:free"] url] override it, and the registry hands the
    resolved value to {!make_mcp} and {!make_tiered} as one URI shared by the
    adapter and its grant. *)

val tool_name : string
(** [web_search_exa], which advertises exactly [query] and [numResults] — no
    filter argument a caller's constraints could reach, which is what {!
    Seekwright.Provider.ignored_constraints} files the notice for. *)

(** {1 The parts, exposed for the suites} *)

val cost_for : cost_per_1k:float -> int -> float
(** The published shape: [cost_per_1k] covers the first ten results and each
    result past them adds [$1.00] per thousand. A price of zero answers zero
    whatever the count — the free half cannot bill. *)

val parse : text_chars:int -> string -> limit:int -> Seekwright.Provider.hit list
(** The block-format parser: [Title:] starts a record, [URL:] makes one real,
    [Published:] keeps its first ten characters, [Highlights:] and [Text:]
    lines join into the capped [text], and a continuation line belongs to the
    last of those two fields — a bare [...] elision belongs to neither. A
    record with no URL is not a result; a title of [N/A] falls back to the URL. *)

(** {1 The two shapes the registry builds} *)

val make_mcp :
  ?cost_per_1k:float ->
  ?text_chars:int ->
  name:string ->
  ?auth:string ->
  uri:Uri.t ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.session
(** One MCP session on one credential: anonymous without [~auth], billed with
    it. [~name] is the reporting name — [exa:free] behind that row, [exa] inside
    the ladder — because the same class answers at two prices. The session is
    the adapter's: {!Seekwright.Provider.session.warmup} opens it before the
    first search pays for the handshake, and {!Seekwright.Provider.S.aclose}
    closes it. *)

val make_tiered :
  ?cost_per_1k:float ->
  ?text_chars:int ->
  ?cooldown_seconds:float ->
  now:(unit -> float) ->
  ?log:Seekwright.Log.log ->
  key:string ->
  uri:Uri.t ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.session
(** The billed [exa]: the free tier first, the key only when free cannot serve.
    [~now] is the {b monotonic} clock the cooldown deadline is set on — the
    oracle's [loop.time()], injected so a suite can move time without waiting
    for it. [~log] receives the three ladder events; with no sink the ladder
    still runs, it just says nothing. [warmup] warms the {i free} session only:
    a rejected key completes the MCP handshake anyway and fails only at the
    tool call, so warming the keyed half buys nothing. *)
