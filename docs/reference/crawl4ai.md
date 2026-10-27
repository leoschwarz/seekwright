# The crawl4ai renderer fallback

Facts about the self-hosted [crawl4ai](https://github.com/unclecode/crawl4ai)
service that backs `fetch`'s renderer fallback — what the proxy sends, what comes
back, and what it costs to run. The proxy-side wiring is `Crawl4aiFetcher` in
`fetcher.py`; the service itself is self-hosted infrastructure you run
yourself; this page is the proxy-side contract.

## Status in this tree

Implemented, shipped, and off by default. `Crawl4aiFetcher` lives in
`fetcher.py`, behind `factory.build_fetch_stack`, which builds the fallback
only when `fetch.fallback` names `crawl4ai` *and* `fetch.crawl4ai_url` is
set. `--check` probes the service's free `/health`, and
`tests/fetch/test_crawl4ai.py` holds the wire contract, which is the part a
renderer release can change. Nothing turns it on by itself: `fetch.fallback`
ships empty and the URL is operator-supplied, so a default install carries the
adapter and no renderer.

What is *not* done sits on the deployment side, which is why this page reads as
a design doc. The preflight has never run — every shape below was read off the
pinned source, never exercised against a running container — and the pinned image
has drifted. The drift is measured below.

## Pinned image and provenance

- Image `unclecode/crawl4ai`, **tag `0.9.3`** — the latest release on both
  GitHub and Docker Hub when it was pinned, 2026-09-06. The compose file pins
  the tag; `latest` floats. That pin lives in the deployment, not in this tree:
  when the image moves, the only thing here to update is this page.
- **The pin has drifted — read 2026-10-22 it is two releases behind, and both
  are Docker-server security releases.** The Docker server is what this fallback
  talks to. Upstream shipped `0.9.4` (2026-09-23) and `0.9.5` (2026-10-14);
  Docker Hub's `latest` now carries the same image digest as `0.9.5`. Those
  changelog entries name blind SSRF through the `robots.txt` fetch, the
  link-preview seeder and the cache freshness check — each of them fetching
  outside the server's pinning egress proxy — an untrusted-config bypass that
  let a caller read the service's environment, `SECRET_KEY` and LLM keys
  included, JavaScript injection into the crawl page through `css_selector` and
  `wait_for`, ReDoS through caller-supplied regexes, and Chromium launched with
  `--ignore-certificate-errors`. None of those fields is in what this proxy
  sends: the body is two empty configs. So the fallback is not what exercises them;
  an unpatched service is open to anyone who can post a body at it, which is
  what the auth gate below is for. Bumping the tag is a deployment-side action,
  and its procedure begins by re-running the preflight — the other open item on
  this page, so the two are one task.
- The request and response shapes below were verified against the **v0.9.3
  source** (the PyPI wheel's `docker_client.py` plus the repo's
  `deploy/docker/` server at that tag) on 2026-09-06. They have not yet been
  exercised against a *running* container — that preflight belongs to the infra
  half, and re-running it is part of the image-bump procedure in that repo's
  RUNBOOK.
- The upstream self-hosting docs are stale, in a shape that has moved once. Read
  2026-10-22, `docs/md_v2/core/self-hosting.md` does document the 0.9.x
  secure-by-default contract — the 2026-09-06 note that they still describe the
  0.7.x API no longer holds — while naming `0.9.2` as its latest release, three
  versions early. This page, checked against the pinned source, is the source of
  truth — not the docs.

## The one call the proxy makes

`POST {crawl4ai_url}/crawl`, JSON body:

```json
{
  "urls": ["https://example.com/page"],
  "browser_config": {},
  "crawler_config": {}
}
```

Empty configs are deliberate. On the 0.9.x line the defaults already mean
`cache_mode = bypass` and markdown generation — the old examples floating
around (`{"cache_mode": "bypass", "f": "markdown"}` as top-level keys) are the
0.7.x API and are rejected here. Everything else the request could ask for
(LLM extraction, screenshots, PDFs, hooks, streaming) is a feature this fallback
deliberately does not use; the proxy sends none of it, and the service is
deployed with no LLM keys so the `/llm` endpoints fail harmlessly.

Response, `200`:

```json
{
  "success": true,
  "results": [
    {
      "url": "https://example.com/page",
      "success": true,
      "status_code": 200,
      "redirected_url": null,
      "markdown": {
        "raw_markdown": "…",
        "markdown_with_citations": "…",
        "references_markdown": "",
        "fit_markdown": null,
        "fit_html": null
      },
      "metadata": { "title": "Example Domain" },
      "error_message": null
    }
  ],
  "server_processing_time_s": 1.2
}
```

The mapping rules, and the traps in them:

- **Two layers of success.** The envelope's `success` is the *service's*; each
  entry in `results` carries its own `success` plus `error_message`. A crawl
  that ran and hit a wall lands in `results` with `success: false` — and the
  HTTP status is still 200. Assert on the payload, never on the status alone.
- **`status_code` is the origin's status**, reported per result. A 404 page
  rendered successfully is a successful crawl and a failed fetch — the same
  rule as the local fetcher: an error page's body is not the article.
- **`markdown` arrives as the generation-result dict**, not a string; the
  proxy reads `raw_markdown` (`fit_markdown` trades content for tidiness, and
  the fallback's job is to show what the page says, not to tidy it). Older server
  lines sent a plain string; the adapter accepts both.
- **`title`** comes from `metadata.title`; **`redirected_url`** is where the
  crawl actually landed, and is what the response reports as `url` when set.

## Auth

0.9.x is secure-by-default: an `AuthGateMiddleware` sits outside every route
and **fails closed**. Two credentials are accepted, both as
`Authorization: Bearer <token>`:

- the **static operator token** — set once in the service config; what the
  proxy's `fetch.crawl4ai_token` holds, and the only mechanism this deployment
  uses; or
- a **server-minted JWT** (`POST /token`, short-lived) — not used here, since
  the proxy would have to re-mint it per hour and has nothing to gain.

`GET /health` and `POST /token` are the only public paths. A missing or wrong
token is `401 {"detail": "Authentication required"}`, which the adapter maps
to a non-retryable `ProviderError` naming `fetch.crawl4ai_token`.

## Health and probing

`GET /health` → `{"status": "ok", "timestamp": …, "version": …}`, free and
public — the same tier as the provider connectivity probes. `--check` calls it
when the fallback is configured. It is deliberately *not* part of `/healthz`: the
ladder degrades (local fetch → keyless fallback → paid fallback → notice) without the
renderer, and a server is never unhealthy because one of its fetch fallbacks is
down.

## Resource cost

Each concurrent crawl is a full Chromium: roughly **1 GB RAM and 1–2 cores**,
plus the `--shm-size=1g` Chromium wants for shared memory. The service gets
its own VM (≥ 4 GiB) rather than a slot alongside other services: the
rejected alternative — a browser embedded in this process — moves that RAM and
those cores into the server's own cgroup.

## The vendor's hosted API is a different question

Supporting crawl4ai's cloud is two questions, and the vendor's own comparison
table (README, read 2026-10-22) settles which is which: web search is cloud-only — `/search`, `/serp` and
`/answer` at `api.crawl4ai.com` — while the self-hosted image behind this fallback
offers no search endpoint at all (`/md`, `/html`, `/crawl`, `/crawl/stream`,
`/screenshot`, `/pdf`, `/execute_js`). So neither ask touches this contract,
this fallback, or the ladder's free renderer: each would be its own keyed adapter,
with its own price and its own unconditional target validation. Both are open
as survey-and-decision entries — one for `POST /scrape` as a `fetch` fallback and
one for `/search` and `/serp` as a search provider. Nothing here
pre-decides either, and nothing in this tree has an adapter for any of it.

The fetch half was surveyed on 2026-10-22: the vendor's endpoint, auth,
metering and limits, with the verdict against both standing rules, are in the
"Crawl4AI Cloud — `fetch` (`POST /scrape`) — surveyed 2026-10-22" entry of
[providers.md](providers.md), which is also where the cost this ladder would
carry is argued. The adoption call is the maintainer's, and the search half is
still unread.
