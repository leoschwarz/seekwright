(** Crawl4AI — the self-hosted renderer fallback.

    A real Chromium that executes the JavaScript the local reader cannot,
    self-hosted so it costs nothing (the factory's registry row declares no
    price). It is a service the proxy talks to over HTTP, deliberately not a
    library in this process; its URL is this deployment's own config, so the
    endpoint grant is built from [fetch.crawl4ai_url] rather than a constant.

    Only the free markdown path of the pinned 0.9.x API is used:
    [POST {base}/crawl] with empty default configs, which means
    bypass-cache plus markdown on that server line — every interesting
    non-default is a feature this fallback does not use. With an optional
    [fetch.crawl4ai_token], the header is [Authorization: Bearer …], built
    per request rather than parked on the client: a credential that only
    exists at the call site cannot ride along on any other request.

    Status arms: 401/403 → {!Fallback.Rejected} ("authentication rejected
    (check fetch.crawl4ai_token)") — the token sentence is this vendor's, not
    the keyed-vendors' "check API key" — and every other ≥400 →
    {!Fallback.Failed} ("HTTP n"). No quota arm: a self-hosted service does
    not meter this deployment.

    Two layers of success to separate in the envelope. The envelope's
    [success] is the {i service's}: false there means the crawl never ran.
    Each entry in [results] then carries its own [success] and the origin's
    [status_code] — a 404 page rendered successfully is a successful crawl
    and a failed fetch. Older server lines sent [markdown] as a string,
    newer ones a result dict: accept both, prefer [raw_markdown], since
    [fit_markdown] trades content for tidiness. *)

type 'tag config = {
  net : Fallback.net;
  target : 'tag Remote_target.t;
  max_text_chars : int;
  base_url : string;
  token : string option;
}

val crawl4ai_crawl_path : string
(** [/crawl], appended to the configured base URL (which is right-stripped of
    [/] at build time, as the oracle's client does). *)

val fetch :
  'tag config ->
  string ->
  offset:int ->
  max_chars:int option ->
  (Fallback.page, Fallback.error) result
(** [fetch cfg url ~offset ~max_chars]: {!Remote_target.check} the target,
    POST the crawl, and map the envelope. *)
