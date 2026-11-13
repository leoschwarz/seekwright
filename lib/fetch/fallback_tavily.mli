(** Tavily extract — the keyed fallback on a credential this deployment may
    already hold.

    [tavily] is a provider name, so [SEEKWRIGHT_TAVILY_API_KEY] is already in
    the environment wherever Tavily search is enabled, and the same
    allow-list entry gates this fallback too. What it buys over the local
    reader is a markdown-first read performed by a service that owns the
    fetching. Tavily bills {b successful extractions, not calls} — 1 credit
    per 5 at basic — so the factory row prices it 1.60 per 1k; the price
    itself rides the registry, not this module.

    [POST https://api.tavily.com/extract] with one URL, [format: markdown],
    and [extract_depth: basic] — the dearer depth doubles the credit, for the
    reason the search adapter gives for [search_depth]. The [timeout] request
    field is the {i vendor's} own bound on the extraction, clamped to its
    1–60 s range; the transport bound lives in the grant and is a different
    number. [query] and [chunks_per_source] would select passages of a
    search result, and this fallback is asked for a page; [include_usage]
    would be a number nothing reads.

    Status arms: 401/403 → {!Fallback.Rejected} ("authentication rejected
    (check API key)"); 429 {i and 432} → {!Fallback.Quota} ("rate limited or
    out of credits") — 432 is this vendor's monthly-credits-exhausted code,
    the same reading the search adapter on this key takes; every other ≥400 →
    {!Fallback.Failed} ("HTTP n").

    [results[]] holds one entry per URL that succeeded, and HTTP 200 with an
    empty [results] array is the vendor's way of saying every URL failed.
    That body reads as {i found nothing} — the same fact Jina's placeholder
    bodies mean — so the walk continues to the next fallback;
    [failed_results[]]'s reason is dropped. [url] is the entry's own landing
    URL when the vendor names one. Extract reports no title: inventing one
    out of the markdown's first heading would be a guess the caller cannot
    tell from the page's own title. *)

type 'tag config = {
  net : Fallback.net;
  target : 'tag Remote_target.t;
  max_text_chars : int;
  api_key : string;
  timeout_seconds : float;
}

val tavily_extract_endpoint : string
(** [https://api.tavily.com/extract]. *)

val fetch :
  'tag config ->
  string ->
  offset:int ->
  max_chars:int option ->
  (Fallback.page, Fallback.error) result
(** [fetch cfg url ~offset ~max_chars]: {!Remote_target.check} the target,
    POST the extract, and map the envelope. *)
