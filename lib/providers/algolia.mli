(** Algolia — a keyed, index-scoped SERP-shaped backend over records you own.

    Port of [src/seekwright/providers/algolia.py]. Billed {b per search request},
    whatever it returns: free is 10K requests a month, Grow includes 10K then
    $0.50/1K, Grow Plus $1.75/1K — so the default price is the cheapest paid rate
    and {!cost_for} ignores its argument. It is reporting-only anyway; an operator
    on Grow Plus corrects it in config.

    The Search API at [{app_id}-dsn.algolia.net] is the only surface that returns
    the operator's own records, and the provider is index-scoped by nature — one
    index, not the web. [app_id] and [index] are config (the host is
    per-deployment, the [searxng] precedent); the search API key is the
    credential. One name, not an [algolia]/[algolia_free] split: the key is
    mandatory on {b every} tier, so the credential never decides the price — the
    plan does.

    Endpoint: [POST] to {!endpoint_of_deployment} with both headers — the
    Application-ID {i and} the API key; the one names the deployment, the other
    authorises the index.

    Records are schemaless JSON, and the parse is the adapter's whole shape:
    common-name chains for title ([title]/[name]/[question], then the DocSearch
    [hierarchy.lvl0..lvl6] fallback at the deepest non-empty level), url
    ([url]/[link]) and snippet ([description]/[summary]/[excerpt]/[content]/
    [answer]); a wrong type counts as absent and the chain continues. An
    explicitly configured [*]_attr is used alone — no chain, no hierarchy —
    because an operator who names an attribute has said what their records hold.
    A hit with no title or no url is dropped, never shipped as a result the
    caller cannot cite or follow.

    Every constraint the query surface carries is dropped here — there is no
    filter field in this API — so the ignored-constraints notice names all four
    buckets whenever the caller asked for any of them. 403 (not 401) is Algolia's
    answer for a bad Application-ID or key, and 402 ([FeatureNotEnabled]) joins
    429 on the quota row: both are plan questions, like a spent rate limit. *)

val name : string
(** ["algolia"], the config key and the [provider] every response names. *)

val endpoint_of_deployment : app_id:string -> index:string -> Uri.t
(** [endpoint_of_deployment ~app_id ~index] is the Search API query endpoint for
    one deployment: [https://{app_id}-dsn.algolia.net/1/indexes/{index}/query]
    with the index name percent-encoded — it rides the path, so it cannot be
    allowed to escape its segment. This is the one spelling of the derivation:
    the factory resolves the row's grant from here, and the adapter dials that
    same URI rather than re-deriving it. *)

val scalar_text : Yojson.Safe.t -> string option
(** [scalar_text value] is the oracle's [_first_str] coercion: a plain scalar
    ([string], [int], [float]) becomes text, and everything else — including a
    JSON [true], which is not the prose a field claims to be — counts as absent. *)

val first_str : string list -> Yojson.Safe.t -> string option
(** The first of [attrs] that holds a scalar in [record], coerced; [None] when
    none of them does. *)

val hierarchy_title : Yojson.Safe.t -> string option
(** The DocSearch-shaped title: the most specific non-empty [hierarchy.lvl0..6]. *)

val parse :
  snippet_chars:int ->
  ?title_attr:string ->
  ?url_attr:string ->
  ?snippet_attr:string ->
  Yojson.Safe.t ->
  limit:int ->
  Seekwright.Provider.hit list
(** [hits[]] mapped onto title/url/snippet. The limit slices the upstream list
    before anything is dropped; non-object records are skipped. *)

val check_status : int -> (unit, Seekwright.Provider.error) result
(** The status rows: 401/403 authentication, 402/429 quota, anything else
    [>= 400] the plain HTTP row. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat: Algolia bills the request whatever it returns.
    The argument is ignored rather than absent because callers treat [cost_for]
    as the same duck-typed extra on every adapter. *)

val request_body : Seekwright.Provider.search_query -> string
(** The whole document the endpoint is asked with: [query] and [hitsPerPage].
    There is no filter field to send, so a constrained query's filters appear
    nowhere on the wire — the notice is the only trace they leave. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  ?title_attr:string ->
  ?url_attr:string ->
  ?snippet_attr:string ->
  app_id:string ->
  key:string ->
  endpoint:Uri.t ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [app_id] and [key] are both mandatory and
    ride their own headers; [endpoint] is the deployment URI read once by the
    registry ({!endpoint_of_deployment}) — the adapter never re-reads a config
    key, and the grant this adapter is handed is confined to that destination.
    The three optional attribute names are the [providers.algolia] settings;
    absent, the common-name chains apply. [cost_per_1k] is the row's figure,
    the cheapest paid rate by default. *)
