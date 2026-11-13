(** Linkup fetch — the keyed rendering fallback.

    It renders JavaScript — the failure class the local reader cannot cover
    and the one [crawl4ai] covers self-hosted — and rides the key
    [providers.linkup] already carries for search, so the operator adds no
    secret. The vendor prices [/v1/fetch] per call by a [mode] × [renderJs]
    table; the cell this fallback sends — [standard], [renderJs: true], no
    [schema] — is $0.005, so the factory row prices it 5.00 per 1k. [mode]
    stays [standard]: [pro] is a price cliff.

    [POST https://api.linkup.so/v1/fetch]. [renderJs] is sent [true] rather
    than left at the vendor's default, because a fallback that does not
    render is a worse local reader; [extractImages], [includeRawHtml] and
    [includeRawContent] are sent [false] so a vendor-side default change
    cannot buy bytes this ladder has no path for. Image bytes reach a caller
    only through [fetch.allow_images], so [images[]] is dropped. [schema]
    cannot appear, and [instructions] without one is a 400.

    Status arms: 401/403 → {!Fallback.Rejected} ("authentication rejected
    (check API key)"); 429 → {!Fallback.Quota} ("rate limited or out of
    credits") — a spent account and a burst share 429 here, as the search
    adapter on this key reads it, and Linkup's 402 belongs to the keyless
    x402 lane this tree never enters; every other ≥400 → {!Fallback.Failed}
    ("HTTP n").

    [markdown] is the field the service always returns, and an empty one is
    a page it could not read — the near-empty class [fetch.min_text_chars]
    refuses, so the walk goes on. [url] stays the target the caller wrote:
    the service follows no links, so there is no landed address to report in
    its place, and the payload carries no title. *)

type 'tag config = {
  net : Fallback.net;
  target : 'tag Remote_target.t;
  max_text_chars : int;
  api_key : string;
}

val linkup_fetch_endpoint : string
(** [https://api.linkup.so/v1/fetch]. *)

val fetch :
  'tag config ->
  string ->
  offset:int ->
  max_chars:int option ->
  (Fallback.page, Fallback.error) result
(** [fetch cfg url ~offset ~max_chars]: {!Remote_target.check} the target,
    POST the fetch, and map the envelope. *)
