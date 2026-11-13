(** Scrappa — the paid JavaScript-rendering fallback.

    The point is JavaScript: {!Fetcher} reads the HTML the server sends, and
    for a client-rendered page that is an empty shell. Scrappa runs a browser
    on the far side, so it is the fallback for pages the local path cannot
    read at all. Billed one credit per request whatever the page holds —
    which is why it is opt-in and never the primary; the price itself rides
    the factory's registry row, not this module.

    [GET https://scrappa.co/api/web-scraper] with the target in the [url]
    query parameter, [javascript=1], [include_html=0], and the credential in
    the [x-api-key] header. Status arms: 401/403 → {!Fallback.Rejected}
    ("authentication rejected (check API key)"), not retryable; 402/429 →
    {!Fallback.Quota} ("rate limited or out of credits"); every other ≥400 →
    {!Fallback.Failed} ("HTTP n").

    The envelope separates two statuses: Scrappa's own (the transport arms)
    and the {i origin's} [site_status_code] — a 404 page scraped
    successfully is a successful API call and a failed fetch, and the same
    rule as the local reader's applies: an error page's body is not content.
    [success] exactly [false] means the scraper itself failed. [final_url]
    (or [url]) is where the page actually landed. *)

type 'tag config = {
  net : Fallback.net;
  target : 'tag Remote_target.t;
  max_text_chars : int;
  api_key : string;
}

val scrappa_scraper_endpoint : string
(** [https://scrappa.co/api/web-scraper]. *)

val fetch :
  'tag config ->
  string ->
  offset:int ->
  max_chars:int option ->
  (Fallback.page, Fallback.error) result
(** [fetch cfg url ~offset ~max_chars]: {!Remote_target.check} the target,
    GET the scraper, and map the envelope. *)
