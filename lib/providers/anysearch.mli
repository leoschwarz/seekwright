(** AnySearch — keyless whole-web SERP over a documented JSON API, explicit-only.

    Port of [src/seekwright/providers/anysearch.py]. Cost note: the anonymous mode
    serves 1,000 requests/day with no account, key or card (pricing page; ToS v1.1
    §5.1.1), so [cost_per_1k] is 0. and [cost_for] is flat. The keyed plans exist,
    but this adapter implements the keyless mode only: no [authorization] header is
    ever sent.

    Endpoint: [POST https://api.anysearch.com/v1/search], the operator's documented
    search API — a response document, not a scraped results page.

    Explicit-only: [anysearch] is in neither the free set nor the install default on
    purpose, though a keyless name that cannot bill would qualify the way
    [freeserp] does. It is reached only by naming it, never auto-routed or defaulted
    ([providers.md]); the config tests pin its absence from [FREE_PROVIDERS],
    [FREE_PROVIDER_ORDER] and [KEYLESS_PROVIDERS].

    Request: [max_results] is documented 1–10, so the adapter clamps rather than
    sending a documented-invalid request. [language] is the only half of the geo
    bucket reaching the wire ([zone] takes [cn]/[intl], which a country code cannot
    map into); there is no domain, date or safe-search field, so those drop with a
    notice.

    Response: [{code, message, request_id, data}], success [code: 0], hits in
    [data.results[]] as [{title, url, snippet, content}]. An empty [title] drops the
    record, [content] is page text this adapter never reads, and
    [metadata.total_results] counts this response rather than a hit pool.

    The 402 is the body the redaction rule exists for: an anonymous caller over the
    daily quota is auto-registered, and [message] can carry the generated username,
    password and API key — so [QuotaExhausted]'s message is a constant and the body
    never reaches a log line. A 200 whose business [code] is not 0 is the same
    channel, and its error text is not echoed either. *)

val name : string
(** ["anysearch"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://api.anysearch.com/v1/search]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same destination as a grant entry, so the factory (P5) builds the one
    allowlist entry this adapter can satisfy. *)

val max_results : int
(** The documented range is 1-10, and above 10 the request is a documented invalid
    one (400). The tool schema caps at 20, but the adapter is callable directly. *)

val make :
  ?cost_per_1k:float -> ?snippet_chars:int -> net:Seekwright.Provider.Net.t -> unit -> Seekwright.Provider.t
(** The adapter as a provider value. [cost_per_1k] is reporting only, and the
    Python row's [default_cost] in [factory._PROVIDERS] is the figure that takes
    effect there. [snippet_chars] is [policy.max_snippet_chars]. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [data.results[]]: {title, url, snippet, content}. A SERP backend, so
    [snippet] is filled and [text] never is: [content] is the extract and is not
    read. Records missing a URL are dropped, a [title] documented as always
    present but possibly empty drops the record when empty, and a field of the
    wrong type counts as absent. The argument is whatever the envelope's [data]
    field carried: shape drift becomes an empty result set rather than an error. *)
