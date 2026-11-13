(** DeepSeek Search — in-house engine, $0.75 per 1,000 successful requests.

    Port of [src/seekwright/providers/deepseek.py]. Billed {b per successful
    request}: not by tokens, not by result count, and [count] does not move the
    price. A request that answers 200 with an empty [results] array is not billed
    at all, so [search] reports [0.0] for one — the figure tracks what the
    account paid. There is no free tier, so [cost_per_1k] defaults to the
    published rate; 402 is this API's own "insufficient balance" answer.

    Endpoint: [POST https://api.deepseek.com/v1/tools/search] with the key as a
    bearer token.

    No filter fields exist on the request body ([query], [count], [ori_question],
    [localization], [need_content] are the whole set); the documented interface is
    a set of query operators — [site:], [-site:], [lang:], [after:] — so those
    fold into [query] here. [localization] takes an {b IP address}, which is why
    [country] is reported dropped rather than mapped onto something that is not a
    country.

    Two 128s live in this file and they are not the same limit applied twice: the
    tool surface allows a 400-character query and this backend allows 128 {i code
    points} ([Utf8.count], the same [len] reading [Seekwright.Provider.truncate_*]
    uses), {b and every filter rides inside that string}, so the limit bounds the
    {i folded} query. Past 128 folded, the operators come off rather than the
    search dying: the bare query goes out and [notice] names each dropped bucket.
    A query longer than 128 {i before} folding is the adapter's own refusal —
    not retryable, because no retry changes the length.

    [snippet] (100–200 characters, for display) and [summary] (600–800, for a
    model) ride [Result.snippet] and [Result.text] under the two policy caps.
    [content] — the page body, filled only when [need_content] is asked for — is
    never requested: page text is what [fetch] is for.

    [after:<YYYY-MM-DD>] is the one date computation in this adapter, and the
    clock is therefore injected like [linkup]'s. The day counts {i differ} from
    [linkup]'s by design: 31-day months and 366-day years, the {b long} month and
    year, because a window that closes early loses results and an [after:] that
    runs a day long loses none.

    408 is this adapter's own row: documented as the request-body read timing
    out, and the operator says retry — a transient fault, not the quota.

    Untested status: written against the documented API, never called live
    in-repo, on either side of the port. *)

val name : string
(** ["deepseek"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://api.deepseek.com/v1/tools/search]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same destination as a grant entry, so the factory builds the one allowlist
    entry this adapter can satisfy. *)

val max_results : int
(** The documented [count] range is 1..50 (not a plan limit), so a hand-built
    [SearchQuery] stays inside it whatever [max_results] asks. *)

val max_query_chars : int
(** [query] is 1 to 128 Unicode characters, counted in codepoints. *)

val recency_days : Seekwright.Model.recency -> int
(** How far [after:] reaches: 1, 7, 31 and 366 days — the long month and year, so
    a window never misses a day. *)

val after_date : now:(unit -> float) -> Seekwright.Model.recency -> string
(** [after_date now period] is [<YYYY-MM-DD>] for [today - recency_days period]
    in UTC: [datetime.now(UTC).date() - timedelta(days=n)] rendered with [isoformat].
    The [civil_from_days] arithmetic is the one [Seekwright_providers.Linkup]
    carries, with no timezone library. *)

val fold_operators : now:(unit -> float) -> Seekwright.Provider.search_query -> string
(** Compose the query with this API's operators folded in. Order is the operator's
    own example — term, [site:], [lang:], [after:] — and a multi-site include is
    the [site:a OR site:b] form its docs spell out. {b Not}
    {!Seekwright.Provider.site_filtered_query}: that helper parenthesises a
    multi-site filter, and parentheses are not part of this backend's documented
    syntax. *)

val request_body : query:string -> Seekwright.Provider.search_query -> string
(** The request document. [query] is the {b decided} query — folded or bare —
   because the 128-codepoint decision is the caller's; taking the value here is
   what lets a suite pin both sides of the fold. [count] is clamped to
   {!max_results}. [ori_question] is unknown here, and [need_content] stays at its
   documented default of false, so no page body is requested. *)

val parse :
  snippet_chars:int -> text_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [results[]] (title, url, snippet, summary, date, rerank_score). [results] is
    documented as an array on every success, so a missing or non-list one is drift
    and answers empty rather than raising. [site_name], [site_icon] and [authority]
    have no field on [Result]; [content] is never filled because [need_content] is
    never sent. [rerank_score] is the 0–3 rerank score on the backend's own scale,
    as for every other adapter. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD: one request, flat in result count. [count] does not
    affect the price; the argument is the protocol's. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  ?text_chars:int ->
  key:string ->
  now:(unit -> float) ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [key] is mandatory: there is no keyless lane.
    [now] is injected because the [after:] date moves with every call — the factory
    hands in the clock its grant was built with, and a suite hands in an instant it
    can pin. *)
