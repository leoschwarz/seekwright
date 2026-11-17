(** DeepSeek Search — keyed web search backend.

    Billed per successful request. A 200 response with empty results is not billed and reports cost
    0.0.

    Endpoint: [POST https://api.deepseek.com/v1/tools/search] with bearer token.

    Query operators ([site:], [-site:], [lang:], [after:]) are folded into [query]. The upstream
    backend bounds the total query string to 128 Unicode characters. If the folded query exceeds 128
    characters, operators are stripped and the bare query is sent with dropped constraints noted.
    Queries exceeding 128 characters before folding are refused.

    402 indicates insufficient balance; 429 indicates rate limiting. 408 indicates a transient
    upstream timeout. *)

val name : string
(** ["deepseek"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://api.deepseek.com/v1/tools/search]. *)

val max_results : int
(** The documented [count] range is 1..50 (not a plan limit), so a hand-built [SearchQuery] stays
    inside it whatever [max_results] asks. *)

val max_query_chars : int
(** [query] is 1 to 128 Unicode characters, counted in codepoints. *)

val recency_days : Seekwright.Model.recency -> int
(** How far [after:] reaches: 1, 7, 31 and 366 days — the long month and year, so a window never
    misses a day. *)

val after_date : now:(unit -> float) -> Seekwright.Model.recency -> string
(** [after_date now period] is [<YYYY-MM-DD>] for [today - recency_days period] in UTC. *)

val fold_operators : now:(unit -> float) -> Seekwright.Provider.search_query -> string
(** Compose the query with this API's operators folded in: term, [site:], [lang:], [after:]. *)

val parse :
  snippet_chars:int -> text_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** [results[]] (title, url, snippet, summary, date, rerank_score). [results] is documented as an
    array on every success, so a missing or non-list one is drift and answers empty rather than
    raising. [site_name], [site_icon] and [authority] have no field on [Result]; [content] is never
    filled because [need_content] is never sent. [rerank_score] is the 0–3 rerank score on the
    backend's own scale, as for every other adapter. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD: one request, flat in result count. [count] does not affect the price; the
    argument is the protocol's. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  ?text_chars:int ->
  key:string ->
  now:(unit -> float) ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** The adapter as a provider value. [key] is mandatory: there is no keyless lane. [now] is injected
    because the [after:] date moves with every call — the factory hands in the clock its grant was
    built with, and a suite hands in an instant it can pin. *)
