# What `fetch` does and does not protect you from

`fetch` takes a model-supplied URL and returns extracted page text. Both halves
of that are a hazard: the URL is chosen by a suggestible caller, and the text
comes back from whoever controls the page. This file states exactly which of
those hazards are handled, so nobody has to infer it from `fetcher.py`.

## The part that is not solved

**Fetched text is untrusted third-party content.** Whoever controls a page
controls what lands in your model's context, and prompt injection through
fetched content is unsolved. The tool description says so, but tool descriptions
are weak guardrails: nothing in this proxy can make fetched text safe to follow
as instructions.

**One text pass is made, and it is not that one.** `sanitize.py` inserts a
zero-width space after the opening delimiter of every model special-token literal
— `<|endoftext|>`, the ChatML-shaped forms — because a page that quotes one makes
some backends reject the *whole request*, so a single hostile page would fail
every result in the call that carried it. The escape is reversible, idempotent and
deterministic, which is what lets the same text cross a fallback walk or an
`offset` without double-escaping or moving a coordinate. It prevents a tokenizer
failure, not an instruction: everything above still holds.

**An image carries that same exposure through a channel nothing inspects.** A
picture can hold instructions for a vision model just as a paragraph can, and
it can hold them in a layout no text rule would ever see. Nothing here opens an
image: the operator's opt-in switch is the only guard, and a guard that is a
switch is a decision, not a defence.

## The guarantees that are made

Enforced in `fetcher.py`, before and during every request:

- Only `http(s)`; every other scheme is refused.
- URLs with embedded credentials are refused rather than stripped.
- No private, loopback, link-local, multicast or reserved addresses — including
  the cloud metadata endpoint at `169.254.169.254`, and including
  `::ffff:127.0.0.1`-style IPv4-mapped addresses. *Every* resolved address must
  be public, not just the first.
- Redirects are followed manually, capped (`fetch.max_redirects`), and
  re-validated at every hop. An https→http downgrade is refused.
- The download is streamed against a byte cap enforced on accumulated bytes,
  not on the `Content-Length` a hostile server supplied.
- The fetcher owns its own HTTP client, so no provider API key can ever ride
  along on a request to a fetched host.
- The whole redirect chain shares one wall-clock budget — twice the per-request
  timeout, 30 seconds at the default 15 — so three hops cannot each spend it.
- Extraction — a library walking bytes a stranger wrote — runs on a worker
  thread, under a wall-clock deadline equal to `fetch.timeout_seconds`. A parse
  that will not finish holds neither the caller nor the event loop, and comes
  back as the same non-retryable refusal an unreadable PDF produces. The deadline
  abandons the thread without stopping what it already allocated, so an
  extraction's own build has to be bounded inside the extraction — which is why
  the JSON walk below is bounded, not merely its output.
- Only HTML, plain text, JSON and PDF are extracted — the configured extractor's
  own supported set, with the RFC 6839 `+json` suffixes riding with JSON. That set
  is the backend's claim, so the `stdlib` backend refuses a PDF before a byte of
  one is downloaded: it has no PDF reader. Anything else is refused rather than
  handed over as bytes, with one opt-in exception — the four image types returned
  when `fetch.allow_images` is on (see *Images: only when the operator says so*
  below). A JSON body that is not one document — an HTML error page under a JSON
  type, a JSON Lines stream — comes back as its text, since its bytes are the
  content. A document that hits the byte cap mid-file is refused naming the cap,
  as a cut PDF is: cut in half it is no longer one document. A response with a
  4xx/5xx status is an error, not content — an error page's body is not the
  article.
- The rendering of a JSON document carries its own budget, beside the depth cap
  and beside the byte cap: at most four times the body being rendered, floored
  at 8000 characters. Every rendered line carries the path that addresses it,
  so a document's *shape* sets what printing it costs — 400 KB nested 99 levels
  deep, with 200k leaves under them, is inside the depth cap and renders to 61
  million characters. The cut prints a line naming where it stopped. The walk
  that builds the rendering is bounded by that same budget, not by the document's
  shape: a container sits on the walk's stack as one frame over its own members,
  read one at a time, rather than queueing an entry and a full path label for
  every member of every container it opened.

## Images: only when the operator says so

`fetch.allow_images` is off, and switching it on is the only way bytes ever
reach a caller. When it is on, the local fetcher hands over the body of a PNG,
JPEG, GIF or WebP resource — the four types MCP names as image content, chosen
deliberately and no others:

- The media type the header claims has to match the body's first bytes. A
  server that labels an HTML page `image/png` is refused: the string this
  server writes into the image block is what the caller's decoder trusts, and
  a header is not evidence about bytes.
- `fetch.max_download_bytes` bounds the read, and an image cut at that bound is
  refused naming the knob — half a file is not a smaller picture, it is a
  broken one nobody can tell apart from the whole.
- The fallback ladder is not walked for an image. Its fallbacks exist to find text
  a page would not yield, so a renderer and a paid scraper would be billed to
  look for prose in a photograph.
- `image/svg+xml` stays refused with the switch on: an SVG is a document that
  can carry script, so a client that renders one executes what it renders.
- `answer` stays text-only. An image fetched inside an agent run is named in
  `notice` and its bytes are not carried; the fetch itself still happened, and
  the journal records it.

## The fallbacks

The route an unnamed fetch leads with is `fetch.primary`, and its default,
`"http"`, is this server's own reader — a plain HTTP client dialling from this
server's IP, which more bot walls recognise than a provider's network does. An
operator whose pages sit behind such a wall names a fallback as `fetch.primary`
instead: it then leads, and the local read leaves the unnamed route entirely, so
a page that provider cannot get is a failure the caller is told about rather than
a quiet second try from this server's own IP. A primary this deployment cannot
build — no key, no `fetch.crawl4ai_url`, or excluded by `permitted_providers` —
stops the server at startup with a sentence pointing at `seekwright --check`.

Whether the ladder behind that first read is walked at all is
`fetch.auto_fallback`, off by default: with it off, a failed or nearly-empty read
names the configured fallbacks to the caller as `provider` values to retry on,
and with it on the walk runs in config order, at most once each, the one billable
name last. Both sentences, and the `answer` plan's per-call ask for the walk, are
[fetch-provider-selection.md](fetch-provider-selection.md) §2 and §3. What this
page adds is the security half: **a read these guarantees refuse ends at the
reason and names no provider to retry it on**. Every remote fallback applies the
same check to the URL it is handed, and a named `provider` escapes none of them —
the same `validate_url`, the same `resolve_public`, the same client ownership
below.

The fallbacks have their own rules, stricter in one respect than the local
fetcher's:

- The target is validated and resolved **unconditionally**:
  `validate_url`, then `resolve_public` on the hostname, before anything is
  sent. `fetch.allow_private_addresses` deliberately does **not** apply. That
  switch exists to let this server reach your intranet; it says nothing about
  handing your internal hostnames to another networked service, which is a
  leak rather than a fetch. So an intranet URL the local fallback may fetch is
  still refused by every configured fallback.
- The fetchers own their HTTP clients, so no provider API key or bearer token
  can ride along on anything but its own request to its own endpoint.
- Each fallback dials a named host, and a strict fetch policy has to carry it:
  `r.jina.ai` and `scrappa.co` are hosts `fetcher.py` names by constant, and
  the renderer's host is one only this deployment can name. The rule and the
  runbook sit in the egress section of [deploying.md](deploying.md).
- **The guard covers the URL, not the page.** Every remote fallback fetches the
  URL it was handed and then pulls whatever that document asks for, the same
  exposure any browser has. That limit is why an operator who does not want
  their URLs leaving chooses `fetch.primary` and an empty ladder.
- The keyed fallbacks report `FetchResponse.status_code = 200`. Neither Tavily's
  extract endpoint nor Linkup's fetch endpoint reports the origin's HTTP status,
  so a page the origin would answer 404 for, extracted cleanly, reaches the
  caller as a fetched page. Scrappa is the one fallback whose payload carries
  the origin's status (`site_status_code`). The usage journal has no status
  field at all — its schema is [metrics.md](metrics.md)'s field table.

What each one is, and where its facts live:

- **`crawl4ai`** (`Crawl4aiFetcher`) posts the validated URL to the self-hosted
  [renderer](crawl4ai.md): a real Chromium on the same WAN as this server,
  which defeats fingerprint-based bot walls — it sends
  `seekwright/0.1.0` — but not IP-based blocks. Where the URL goes is
  `fetch.crawl4ai_url`, written in this deployment's own config, and under a
  strict egress policy that host belongs on a `fallback=crawl4ai` line of the
  egress list. The tool never opens the config file, because the table holding
  that URL can hold `fetch.crawl4ai_token` too.
- **`jina`** (`JinaFetcher`) hands the URL to the keyless
  [Jina Reader](https://r.jina.ai/), which renders and extracts server-side and
  returns markdown. Free and credential-free, metered by IP, so a burst is a
  fallback failure rather than a broken fallback; it may answer from its own
  snapshot cache, and its `Loading...` / `Please enable JavaScript` bodies count
  as *found nothing* so the next fallback fires.
- **`scrappa`** (`ScrappaFetcher`) hands the URL to a paid third-party scraper
  at `scrappa.co`, out of this server's network entirely — the genuine
  out-of-network case, and one credit per page.
- **`tavily`** (`TavilyFetcher`) hands the URL to Tavily's extract endpoint at
  `api.tavily.com`, keyed by `SEEKWRIGHT_TAVILY_API_KEY` — the credential
  `[providers.tavily]` already holds, so the permission set that gates that name
  gates this fallback and the operator adds no secret. It bills successful
  extractions rather than calls, and a `200` whose `results` array is empty
  reads as *found nothing*, so the next fallback fires rather than a
  billed-looking page ending the walk.
- **`linkup`** (`LinkupFetcher`) hands the URL to Linkup's fetch endpoint at
  `api.linkup.so`, keyed by `SEEKWRIGHT_LINKUP_API_KEY` the same way. It asks
  for `renderJs` — the failure class the local fetch cannot cover, bought from a
  vendor's browser rather than from the self-hosted renderer — and for no images
  and no raw bodies: image bytes are `fetch.allow_images`'s question.

Prices, credit arithmetic and each vendor's request shape are
[providers.md](providers.md)'s per-entry facts; the keys that enable each
fallback are [configuration.md](configuration.md)'s.

## The gaps, stated rather than hidden
**DNS rebinding is narrowed, not closed.** The address check happens before
httpx resolves the name again for the connection, so an entry that changes in
that gap would not be caught. Closing it means dialling the validated IP with a
Host header and an SNI override, which trades a real complication in TLS
verification against an attack requiring attacker-controlled DNS with a
sub-second TTL. The reasoning lives in `fetcher.resolve_public`.

**A parse that misses its deadline is abandoned, not stopped.** The deadline
bounds how long a caller waits and how much of the event loop the parse costs;
the thread it ran on goes on to completion. Repeated hostile parses queue
against the worker pool, and every parse queued behind one meets the same
deadline. Stopping a parse mid-calculation needs a worker process per parse:
the platform-dependent spawn method and a twice-loaded PDF library have refused it.

**`robots.txt` is deliberately not consulted.** The semantics for a
user-directed agent fetch are genuinely contested, and implementing it
half-correctly would be worse than being clear that it is absent.

**JavaScript is not executed by the local fetcher.** A client-rendered page
comes back nearly empty and says so in `notice` — naming the configured
providers as the thing to retry on, unless `fetch.auto_fallback` is on. Where
the ladder is configured *and* the walk is switched on, the renderer fallback
retries it through a real browser, free —
see [crawl4ai.md](crawl4ai.md) — and what remains when even that comes back
empty is the keyless `jina` fallback, then a paid fallback. Which paid fallback —
Scrappa's browser, or one of the keyed `tavily` and `linkup` extraction
fallbacks — is the operator's price decision, made in `fetch.fallback` and never
inferred here.
