# Architecture

seekwright is one MCP server in front of many web-search providers. A client
mounts it, calls `search`, `fetch` or, with agent mode enabled, `answer`, and
never sees which vendor answered — or how differently each vendor's API is
shaped.

This file maps that. The precise requirements an adapter must meet live in
[`reference/provider-contract.md`](reference/provider-contract.md).

## What the system is

- **One MCP server, three tools.** `search` runs one query against one provider;
  `fetch` reads one URL and returns its extracted text; `answer` (agent mode,
  off by default) runs a fixed retrieval plan and hands the material to one
  operator-configured model, returning its prose beside the sources the server
  validated. Nothing else is exposed — no cache tool, no report command.
- **Normalised in and out.** A caller passes a `SearchQuery` (query,
  `max_results`, domain include/exclude, `country`, `language`, `recency`,
  `safe_search`) and gets a `SearchResponse` of `Result`s (`title`, `url`, a
  `snippet` *or* an inline `text`, `published_date`, `score`). The backend that
  produced it is one field (`provider`); whatever it could not honour is
  another (`notice`).
- **Providers are opt-in and named.** `[providers]` in TOML lists what is
  active; a provider is never selected by inspecting the query. An empty set
  resolves to the keyless set — `exa:free`, `parallel:free` and `freeserp` —
  rather than failing to start, and an enabled name whose key is missing is a
  startup error: a walk is only safe over names that run as configured. The
  unnamed search's route is in the diagram below.
- **Two transports.** stdio by default (each client spawns its own process), or
  `--http` serving the same three tools over streamable HTTP at `/mcp`, so one
  container can back every client on a machine.
- **No cache.** Every `search` call reaches a provider and is billed, unless the
  provider is one of the free ones.

```
search:  MCP tool ─▶ engine.SearchEngine ─▶ providers/<name>.py ─▶ provider API
                              └─ default route only: search.fallback ladder
                              └─ unnamed search with no default, every enabled
                                 name free: the mode="free" walk (search.
                                 free_fallback, else FREE_PROVIDER_ORDER)

fetch:   MCP tool ─▶ engine.FetchEngine ─▶ fetch.primary ─▶ fetcher.HttpFetcher
                                 (default)                └─▶ extractors/<name>
                              └─ a primary naming a built fallback leads instead,
                                 and the local read is out of the unnamed route
                              └─ on failure or a near-empty page, and only with
                                 fetch.auto_fallback on: fetch.fallback names, in
                                 config order, the one billable name last

answer:  MCP tool ─▶ agent.AgentEngine ─▶ the fixed retrieval plan ─▶ one model call
                              └─ the query plus up to two extra queries, five results
                                 each, and up to three pages
                              └─ `depth` decides how much of it runs: `brief` is
                                 the query's own search, no page read
```

A **fallback** is one named entry in one of those ladders: the step a `search` or
a `fetch` walks when the step before it fails. The three are `[search] fallback`,
`[search] free_fallback` and `[fetch] fallback`; `mode="free"` and an unnamed
`search` on an all-free deployment walk the same `free_fallback` list, one
reached from two directions. [`reference/configuration.md`](reference/configuration.md)
is where each is set.

## The provider layer

### The contract

`providers/base.py` defines `SearchProvider` as a `runtime_checkable`
`Protocol`, not an abstract base class: there is no registry and nothing to
inherit, and a class that has the members *is* a provider.

Required members: `name` (the config key), `cost_per_1k`, `async search(q) ->
ProviderResult` and `async aclose()`. Two further methods are looked up with
`getattr` and are deliberately **not** in the protocol, because only some
adapters have them:

- **`cost_for(max_results) -> float`** — read by `cli._live_probe` when a
  provider does not report `cost_usd` itself. Every adapter defines it,
  including flat-priced ones, which ignore the argument.
- **`warmup() -> bool`** — only the MCP-backed adapter has one. The server
  lifespan and `--check` probe for it by `getattr` rather than by provider name,
  so a renamed `exa` in config is still handled.

Constraints a backend cannot honour are reported, not filtered: the adapter names
what it ignored through `providers.base.ignored_constraints`, and the result
travels in `ProviderResult.notice` — silence there would let a caller believe a
filter applied. Failures map to `ProviderError` (401/403 auth, 402/429
`QuotaExhausted`, other statuses, timeouts, network errors, malformed JSON) and
are **redacted**: no httpx exception and no response body is ever interpolated
into a message, because the request headers hold the API key. A failure is
terminal, and zero results is a valid answer. The full table is in
[`reference/provider-contract.md`](reference/provider-contract.md).

### The seventeen names, over fifteen adapters

| Name | Adapter | What it is |
|---|---|---|
| `scrappa` | `providers/scrappa.py` | Google-backed SERP; one credit per request whatever `max_results` says |
| `serper` | `providers/serper.py` | raw SERP (links and snippets); billing doubles above 10 results |
| `linkup` | `providers/linkup.py` | answer synthesis with citations, or plain results, per config |
| `exa` | `providers/exa_mcp.py` | Exa reached as an MCP *client*; keyed, spends Exa's free tier first |
| `exa:free` | `providers/exa_mcp.py` | the same endpoint anonymously; cannot bill |
| `parallel` | `providers/parallel.py` | Parallel's REST Search API; keyed, billed by mode |
| `parallel:free` | `providers/parallel.py` | Parallel's hosted Search MCP; anonymous |
| `freeserp` | `providers/freeserp.py` | keyless whole-web SERP over the operator's own index; cannot bill |
| `tavily` | `providers/tavily.py` | keyed content backend: ranking plus pre-cleaned page text |
| `tinyfish` | `providers/tinyfish.py` | keyed aggregator whose search API is free at any balance |
| `algolia` | `providers/algolia.py` | index-scoped search over records you own, not the web |
| `searxng` | `providers/searxng.py` | your own SearXNG instance over its JSON API |
| `search1api` | `providers/search1api.py` | multi-engine SERP aggregator; metered free tier, keyed |
| `anysearch` | `providers/anysearch.py` | keyless whole-web SERP; explicit-only, never a default route |
| `serpapi` | `providers/serpapi.py` | Google SERP over SerpAPI's documented JSON API; the key rides in the query string, metered free tier |
| `querit` | `providers/querit.py` | real-time SERP over Querit's documented JSON API; metered free tier, keyed |
| `deepseek` | `providers/deepseek.py` | DeepSeek's in-house engine over its documented JSON API; filters ride query operators, no free tier |

Prices, tiers and request shapes belong to the vendor and are stated per entry in
[`reference/providers.md`](reference/providers.md); this page names which name
reaches which adapter.

`providers/` holds **fifteen adapter modules** and the surface exposes **seventeen
names**, because two modules carry two names each, and the price is what
decides:

- **`exa` and `exa:free` are one endpoint on two credentials** — Exa answers
  anonymously on a rate-limited free plan and authenticated on a billed one, at
  different prices. `exa:free` cannot bill; `exa` requires a key.
- **`parallel` and `parallel:free` are the same split**, over Parallel's keyed
  REST API and its anonymous hosted MCP.
- **`algolia` is the counter-example**: its key is mandatory on *every* tier, so
  the plan rather than the credential sets the price, and one name is enough.

The same distinction decides which names need a key at all
(`config.PROVIDERS_REQUIRING_KEY`): `exa:free`, `parallel:free`, `freeserp`,
`searxng` and `anysearch` are exempt; the other twelve are not, free tiers
notwithstanding — a tier is an account quota, and a key names whose quota a
search spends. `searxng` is gated on a config `url` instead, and is a startup
error without one. `anysearch` needs nothing and is still not an install
default: it is enabled by name or not at all.

`cost_per_1k` is **reporting only**. Nothing routes on it: it corrects the
figure `--check --live` prints, and each adapter's `cost_for` maps its real
billing model onto the per-1k unit.

## The engine ladders

`engine.py` holds the orchestration, separate from the tool definitions so it is
testable without the MCP layer: it resolves what to call, calls it, records the
outcome, and turns a provider exception into something a model can act on.

### `search`: the default route may fail over

`SearchEngine.resolve` picks the provider:

- A **named** provider is used or the call fails with an error listing the
  enabled ones. A name that is not enabled is a refusal, not a silent
  substitution.
- A search that names **no** provider uses `default_provider`, which config
  fills in automatically when exactly one provider is enabled. With several
  enabled and none preferred, an unnamed search is an error telling the caller
  to choose, rather than a backend being picked for it at a price it never
  agreed to — unless **every enabled name cannot bill**, where there is no price
  to guess at and the free walk serves it.

With no default configured, the free walk takes `[search] free_fallback` when
the operator set one, otherwise `FREE_PROVIDER_ORDER`.

Only the unnamed route walks `[search] fallback`, and only once it has resolved
to a default. When the default fails, `SearchEngine._walk_fallbacks` tries each
fallback in config order:

- each fallback at most once, the failed default skipped;
- a fallback whose circuit breaker is open skipped with a log line saying so;
- the first success returned, with the substitution named in the response's
  `notice`.

If every fallback fails, the **original** error is what raises, with the failed
fallbacks appended — "serper: rate limited" explains the search that was asked
for; a later fallback's error does not.

A named provider keeps its terminal error: `search.fallback` never touches it,
because a price named is a price paid.

Membership and order of that ladder are the operator's, and a fallback that is not
an enabled provider is a startup error, not a silently inert one.

### `fetch`: the primary route, then the fallbacks

`FetchEngine` reads through its **primary** route. That is `HttpFetcher`, the
server's own reader, unless `fetch.primary` names a built fallback — and then
that fallback leads and the local read is out of the unnamed route entirely,
because whoever sets it is saying this server's own IP should not be what the
page sees. A primary this deployment cannot build is startup-fatal rather than
silently local, and `--check` prints which route leads.

The engine reaches for the ladder in two cases, and only where the route asked
for the walk:

- the primary read **failed** (`ProviderError`), or
- the extraction came back **nearly empty** at offset 0 — below
  `fetch.min_text_chars`, which is not zero on purpose: a JavaScript-rendered
  page extracts to a navigation stub rather than the empty string.

The switch is `fetch.auto_fallback`, and it is off: a read made through the MCP
tool, the REST route or the CLI stops at the primary and the sentence names the
ladder as a list of `provider` values to retry on. The `answer` plan is the
route that asks, passing `auto_fallback=True` on each page it reads, because its
steps run unattended — a list handed back would have no reader.

With the walk on it runs `fetch.fallback` in config order, minus the route that
already led. Each fallback runs at most once, and the walk continues past a
fallback that returns an empty page. `KNOWN_FALLBACKS` holds the five rows
`fetch.fallback` may name — the keyless `crawl4ai` renderer and `jina` reader,
then the billable `scrappa`, `tavily` and `linkup` — and config reads each row's
`billable` flag rather than checking a name. At most one fallback can bill and
it must be last, so a page reaches every free fallback before a credit is spent,
and at most one credit can be spent per fetch. A successful fallback adds
"refetched via `<fallback>`" to the response's `notice`.

A fallback without its prerequisite (a URL for the renderer, an API key for the
scraper) stays **silently absent** rather than failing every fetch that reaches
for it; `--check` is where that is reported. Unlike `search.fallback`, where a
fallback that cannot run is a startup error: a search ladder has to serve
through an outage, and a dead-on-arrival fallback would make it theatre.

The `fetch` tool and the REST route take a `provider` field the way `search` has
one, and it is a plain `str` validated against the built stack rather than a
`Literal`: which names exist is a function of config, a key and a permission
set, and the annotation is evaluated at import. Naming one is the whole route —
no read first and nothing behind it — so a priced name is billed for that call.
[reference/fetch-provider-selection.md](reference/fetch-provider-selection.md)
pins the decided shape: what the field may name, each failure sentence and the
field it surfaces in.

### Why nothing picks the cheapest

Nothing infers a backend from the query and nothing selects on price. The only
substitutions in the tree are the two ladders above, both written by an operator
and walked in an order the operator chose; there is no cost order in the code —
inside a ladder, position is the whole policy.

Two things that look like exceptions are not:

- **`exa` spends Exa's free tier before it spends the key.** That ladder lives
  inside the adapter, and every rung is the backend the caller named — it can
  only charge *less*. A caller that must not spend at all names `exa:free`,
  which has no ladder and cannot bill.
- **The default route fails over** (above): a caller that named no provider has
  already delegated the choice to the deployment.

One consequence is visible in the `search` tool schema: **`search.provider` is a
`Literal` of all seventeen names**, not the enabled subset, because FastMCP
freezes the schema at import time and config cannot reach it. Naming one that is
not enabled comes back as an error listing the ones that are, which is the only
place the real set can be reported.

## The fetch stack

### `HttpFetcher`

The URLs arriving here were chosen by a language model, from text written by
whoever controls the page it last read. That is the threat model — not a
determined attacker so much as a suggestible caller — so every guardrail in
`fetcher.py` assumes the URL is hostile input:

- Only `http(s)`; every other scheme is refused, as are URLs with embedded
  credentials rather than stripping them. A junk port is settled before the
  request rather than surfacing as an exception past every handler.
- No private, loopback, link-local, multicast or reserved address — including
  the cloud metadata endpoint and IPv4-mapped addresses such as
  `::ffff:127.0.0.1`. *Every* resolved address must be public, not merely the
  first.
- Redirects are followed manually, capped by `fetch.max_redirects`, and
  re-validated at every hop. The chain shares one wall-clock budget — twice the
  per-request timeout, 30 seconds at the default 15 — so three hops cannot each
  spend it.
- The download is streamed against a byte cap enforced on accumulated bytes,
  not on the `Content-Length` a hostile server supplied, and only types the
  extraction backend can read are accepted. An error status is an error, not
  content: an error page's body is not the article.
- The byte cap bounds the input, not the work it asks for, so extraction is
  bounded too: the backend runs on a worker thread under a wall-clock deadline
  of `fetch.timeout_seconds`, and a body still unparsed then is refused as a
  non-retryable extraction failure.
- **The fetcher owns its own HTTP client**, deliberately not the shared one:
  redirects must not be followed automatically, and no provider API key may
  ride along on a request to an arbitrary third-party site.

Two gaps are documented rather than hidden. **DNS rebinding is narrowed, not
closed**: the address check happens before httpx resolves the name again for the
connection, and closing that window would mean dialling the validated IP with a
Host header and an SNI override. **`robots.txt` is deliberately not consulted.**
The full list is [`reference/fetch-safety.md`](reference/fetch-safety.md).

### The extraction backend is injected

Turning fetched bytes into text is the part most likely to be replaced, so it
sits behind a named backend rather than a hardcoded call. `fetch.extractor`
picks one module in `extractors/`, the name is validated against
`KNOWN_EXTRACTORS`, and `HttpFetcher` takes the backend **injected, with no
default** — a default would import a backend module at import time, so an
install without the selected backend's libraries would fail on `import server`
rather than on the fetch that needs it. `extract` is synchronous CPU work, so
the fetcher calls it on a worker thread under a deadline: a parse that will not
end on the event loop thread is every other request's problem.

`extractors/base.py` holds the `Extractor` protocol (`name`,
`supported_types`, `extract`), the registry, the shared plumbing (decode, sniff,
normalise, and `is_supported`, the one media-type gate that reads the RFC 6839
`+json` suffix), and the passage selection `fetch(query=...)` uses.
`KNOWN_EXTRACTORS` holds two backends. `trafilatura` is the default: HTML
through trafilatura, PDF through pypdf, JSON through the standard library's
`json`. `stdlib` reads HTML with `html.parser`, claims no PDF type, and keeps
`fetch` buildable on an install that never fetched the extra. The JSON document
itself — the rendering a JSON page arrives as, and the `path` grammar
`fetch(path=...)` selects with — is `jsondoc.py`, beside the backends rather
than inside one, because a backend swap must not lose it.

Both of the default backend's libraries ride in the `trafilatura` extra, `pypdf`
included: it parses bytes a stranger wrote, so it belongs to the backend that
reads them. PDF reading survives a swap of the HTML engine through the protocol,
not the dependency list — a backend that ships no PDF parser does not claim the
PDF media types, and `fetch` refuses such a response before downloading it. A
`--no-dev` install must ask for the extra explicitly; an enabled `fetch` whose
backend library is missing is a startup error naming the extra. A backend with
an HTML library and no PDF parser is no error at all: `--check` reports it.

An admitted image is no backend's business: with `fetch.allow_images` on,
`fetcher.py` compares the body's first bytes with the media type the header
claimed and hands the whole body over unextracted, so nothing in the text layer
ever sees it — the opt-in is the whole authorisation, and extraction would
replace the bytes asked for.

### The fallbacks

`ScrappaFetcher` is the optional paid fallback: one credit per page, last in the
ladder. `Crawl4aiFetcher` is a self-hosted browser service (`POST /crawl`,
markdown only), so a client-rendered page can be retried through a real browser
for free — endpoint facts and the pinned image tag are in
[`reference/crawl4ai.md`](reference/crawl4ai.md). `JinaFetcher` is the keyless
hosted fallback: it hands the validated URL to the
[Jina Reader](https://r.jina.ai/) at `r.jina.ai`, which renders and extracts the
page server-side as markdown, free and credential-free, so nothing but the
configured User-Agent rides the request; it is metered by IP at 20 requests per
60 s, so a burst fails rather than breaks. Both remote fallbacks are third-party
egress, and they validate their target **unconditionally**:
`fetch.allow_private_addresses` is the local fetcher's escape hatch for your own
intranet, and handing an internal hostname to another networked service is a
leak rather than a fetch.

What a fallback may return is bounded: it parses its own response and hands back
page text, and `path_addressable` stays false, because a fallback that reads a
body with a library or a browser answers in prose. Forwarding a vendor's body as
`application/json` would break twice over — every `+json` type is handed to any
backend that claims JSON, and `fetch(path=…)` would then select inside the
vendor's response document rather than inside the page the caller named.

That limit is why a new fetch provider moves exactly **one** seam. The fetch path
has three replaceable parts — the **fallback** (a different network path, still
answering in page text), the **extraction backend** (a different parser, bytes
in and text out), and **egress**, which belongs to the network and not to this
application. A fetch provider is never written as an extraction backend: an
extraction backend parses untrusted bytes, and a network call does not belong
inside it.

## The observability half

### `logs.py`: one stderr stream, one event per call

Everything this process logs goes to stderr, unconditionally, because under
stdio stdout *is* the JSON-RPC channel — a log line on it is a protocol
violation that presents as a client which mysteriously stops working. loguru is
the logger and a stdlib `InterceptHandler` pulls library logging into the same
stream and format.

Two rules give the stream its shape:

- **A message is a constant dotted event name and every value travels as a
  bound field** (`bind(...).info("search.ok")`) — no f-strings, no `%s`. That
  is what lets one call site render as text or as JSON, and what makes the
  no-secrets rule checkable by a test rather than by review.
- **No traceback, ever.** loguru's `diagnose=True` default renders local
  variable *values* into a frame, and every adapter has
  `headers = {"x-api-key": ...}` in scope at the point it fails, so a single
  `logger.exception()` would put a live key in the log store.

Caller and provider content never rides `search.ok` or `fetch.ok`, whose field
sets are fixed: it rides its own events (`search.result` per hit,
`search.answer`, `fetch.content`), and only when `logging.log_content` is on. A
query is described by `qlen` and an eight-character `qhash` unless
`logging.log_queries` asks for the text. `search.cap` is the third kind, neither
content nor an aggregate: one line per hit carrying the counts a policy cap
discarded (`uncapped_chars`, `chars`, `cap`, `field`, `rank`) and no text, URL
or title, emitted whatever `log_content` says. It is the only place the
discarded length exists — both caps bite inside the adapter, before anything is
recorded — which is what makes `max_snippet_chars` and `max_result_text_chars`
calibratable from real traffic. The serving path's events are
`search.ok` / `search.cap` / `search.failed` / `search.rejected` /
`search.fallback` / `search.fallback_skipped` / `search.fallback_failed` and
`fetch.ok` / `fetch.empty` / `fetch.blocked` / `fetch.failed` /
`fetch.fallback` / `fetch.fallback_failed`, plus `health.open` /
`health.closed` / `health.probe`, `startup`, `shutdown`, `http.listening` and
the two warnings that say query or content logging is on
(`startup.query_logging_enabled`, `startup.content_logging_enabled`).

### `health.py`: the provider board

Two signals land on one board. **Real searches are the primary one**: every
dispatch records its outcome, a named failure included, because the board
describes the provider rather than the route. `HealthBoard` counts consecutive
failures and opens a gate for a cooldown once the threshold is reached, with
half-open implicit (an expired gate reads closed, one more failure re-opens it).
The optional **periodic ping** (`search.health_interval_seconds`, 60s by
default) re-verifies every enabled provider with the same bodyless GET `--check`
uses: it sends the real key and is never billed, because a bodyless request
cannot produce results. A probe that finds the key rejected opens the gate
immediately. `search.health_interval_seconds = 0` disables the ping; the
passive breaker keeps working.

The board gates **ladder fallbacks only**. The first attempt of any search — the
resolved default, or the provider the caller named — is never skipped: a breaker
saves the second attempt, it does not pre-empt the first. Gates are also not
health checks: `GET /healthz` never reports unhealthy because a provider is
down, since that would turn a degraded proxy into a restart loop.

### `usage.py` and `dashboard.py`: counts, not a cache

`UsageRecorder` aggregates every **terminal** call: in memory for the running
process, and optionally as one JSONL line per call to
`[dashboard] history_path`, which the dashboard backfills from at startup —
history that survives a container recreate. A default-route search served by a
fallback is one record, the fallback that answered; the intermediate failure
lives on the log stream and the health board. The record is content-free by
construction and **never read on the serving path**, so it is not a cache by
another name; `reference/metrics.md` is its contract.

`dashboard.py` is the page itself: one self-contained HTML document with no CDN
or script tag, serving a requests view and a spend view by polling
`GET /dashboard/data`. The routes and their Host check live in `server.py`, and
they sit behind the same allowlist as `/mcp` (unlike `/healthz`, because they
carry data). The journal is off unless `history_path` is set, and
`[dashboard] enabled = false` is the off switch — the two routes are then never
registered, so they 404 like any other absent path.

### `sanitize.py`: one hygiene pass on text that leaves

Text this proxy returns is written into a model's context window, and some of the
web is *about* tokenizers: a page quoting `<|endoftext|>` is parsed by an
open-weight backend as the end-of-text marker, and the request is rejected
before a token is generated — one hostile page becomes a call that fails for
every result in it. The fix is content hygiene in the class the truncation and
size caps belong to: strip nothing, rename nothing, insert one U+200B after the
opening delimiter of every such literal.

Escaping is **reversible** (drop every U+200B and the source bytes are back),
**idempotent** (escaped text no longer matches, so a re-read never escapes it
twice) and **deterministic**, which keeps an `offset` into a page a valid
coordinate across a fallback walk. The match set stays deliberately tight: the
`<|…|>` shapes cover the ChatML family and a short literal list covers the rest;
`<s>`, ` thinking`, `a < b` and unterminated fragments are left alone, since
rejecting those would reject a large part of the web.

The rule lives once, in `sanitize.py`, and runs twice. The engines escape the
response objects they return, which lets `search.ok` and `fetch.ok` carry a
`sanitized=` count and gets agent mode's material into the model's prompt already
clean — a serialiser cannot, since the prompt is assembled first. The `WireModel`
serialiser then re-applies it at the one choke point every response passes, so a
response built by a path that never went through an engine inherits the
guarantee. This is hygiene against a tokenizer failure, not a defence against
prompt injection; that stance is
[`reference/fetch-safety.md`](reference/fetch-safety.md).

## Module map

The table in [`../AGENTS.md`](../AGENTS.md) is this list written for an agent
working in the tree; this is the same map for a reader:

| Module | Role |
|---|---|
| `models.py` | pydantic models for the tool surface and the provider boundary; `WireModel` drops unset fields, so nothing reaches a caller as `null` |
| `sanitize.py` | the escape pass on text that leaves the proxy (above): one U+200B after the opening delimiter of every model special-token literal, applied by the engines and again at the serialisation boundary |
| `prompts.py` | every model-facing string — server instructions, the three tool descriptions and agent mode's system prompt — read from `resources/`; prose only, no logic |
| `resources/` | the text of those prompts (`server_instructions.txt`, `search_description.txt`, `fetch_description.txt`, `answer_system.txt`, `answer_description.txt`) and the dashboard page, shipped in the wheel as package data |
| `config.py` | `Config` and its sections: enabled providers, both ladders, fetch limits, logging, dashboard. Validates provider and extractor names, resolves `default_provider` |
| `engine.py` | `SearchEngine` resolves a provider, records every dispatch on the health board and walks the ladders above; `FetchEngine` fetches a page and walks `fetch.fallback`, paid fallback last |
| `agent.py` | agent mode behind `answer`: the model client (one OpenAI-compatible chat call on the shared httpx client — no SDK, no tokenizer) and the fixed retrieval plan. One model call per `answer`; the model never drives retrieval. Contract: [`reference/agent-mode.md`](reference/agent-mode.md) |
| `fetcher.py` | URL fetching behind the SSRF guardrails; `HttpFetcher` takes the extraction backend injected (no default), and `ScrappaFetcher`, `Crawl4aiFetcher`, `JinaFetcher` and `TavilyFetcher`/`LinkupFetcher` are the fallbacks, declared in the `KNOWN_FALLBACKS` registry beside them |
| `extractors/` | one module per extraction backend, each implementing `base.py`'s `Extractor` protocol; `base.py` also holds the `KNOWN_EXTRACTORS` registry, the shared plumbing and passage selection |
| `jsondoc.py` | the JSON half of the fetch path: which media types are JSON, the one-line-per-node rendering a JSON page arrives as, and the `path` grammar that addresses part of it — standard library only |
| `providers/` | one module per provider adapter, all implementing `base.py`'s `SearchProvider` protocol — the contract is [`reference/provider-contract.md`](reference/provider-contract.md) |
| `health.py` | the per-provider circuit breaker (`HealthBoard`) fed by real traffic, and its periodic probe (`HealthMonitor`) |
| `logs.py` | loguru setup to stderr, the stdlib `InterceptHandler`, and the `bind`/`query_fields`/`safe` helpers every log call goes through |
| `usage.py` | `UsageRecorder`: in-memory aggregation of every terminal call plus the optional append-only JSONL journal — content-free, never read on the serving path |
| `dashboard.py` | `DASHBOARD_HTML`, the one self-contained page `GET /dashboard` serves; the routes and their Host check live in `server.py` |
| `server.py` | the MCP wiring: the three tools, both transports, the process-wide `build_app_context`, and the HTTP-only routes `/healthz`, the dashboard, and the REST projection (`POST /api/v1/search`, `/api/v1/fetch`, `/api/v1/answer`, behind the same `_guard` as `/dashboard`) |
| `cli.py` | the entry point: run the server on either transport, or `--check` for a diagnosis that never imports the FastMCP app |
| `factory.py` | construction — `build_providers`, `build_extractor`, `build_fetch_stack` — kept out of `server.py` so `--check` can diagnose without FastMCP |

`__init__.py` imports `cli` lazily, so importing the package does not trigger
config loading (which exits on a config that names something it cannot build, or
on a missing key). The provider adapters are imported with `providers/`; the
deferred import is the **extraction** backend — its module, and the third-party
libraries it needs, load only when `fetch.extractor` names it.

Config is read from TOML (`SEEKWRIGHT_CONFIG`, else the platform default path)
and secrets from the environment only, `SEEKWRIGHT_*` prefixed, because files
get committed. Every key and its default is in
[`reference/configuration.md`](reference/configuration.md); the endpoints and
prices behind the seventeen names are in
[`reference/providers.md`](reference/providers.md).

## Deliberate non-features

These are deliberate refusals, not gaps waiting to be filled. Reversing one is
a decision, not an oversight, and it belongs in the pull request that reverses
it. The intent
behind each is [`VISION.md`](../VISION.md)'s non-goals; this section is how one
works.

- **No cache.** Every `search` reaches a provider, which is why a provider
  failure is terminal rather than degrading to older data, and why the usage
  journal is counts rather than a store.
- **No authentication on the listener.** Not a token, not OAuth: every call
  `--http` serves spends real money, so the bind address and the published port
  are the whole access-control story — hence `--host` defaulting to
  `127.0.0.1`. DNS-rebinding protection stays on, and `--allowed-host` *adds* to
  FastMCP's loopback allowlist rather than replacing it. `/healthz` sits outside
  that allowlist on purpose, so a kubelet probe works, and stays secret-free.
  See [`reference/container.md`](reference/container.md).
- **No spend ceiling.** A per-caller or per-day cap was declined: with no caller
  identity it could only be one deployment-global limit, `cost_usd` is a declared
  figure no channel here verifies against a price change, and the usage journal
  has a single event-loop-confined writer, so it needs no
  reserve-then-reconcile. Four things reopen it, any one alone: auth being
  committed, a measured declared-vs-invoiced comparison, an overspend the
  dashboard missed, or a second operator. If it is built it reads the journal,
  not a second store — agent mode's `max_cost_usd` already reads the in-memory
  aggregate mid-dispatch.
- **No router, and nothing picks the cheapest.** Nothing reads the query and
  `cost_per_1k` is reporting-only, so no caller is billed at a price it never
  named. Four scoped reversals are on record: the default-route
  `search.fallback` ladder, `exa`'s free-tier-first ladder inside one adapter
  (both above), a caller-declared `search(mode="free")` route restricted to
  providers that cannot bill (`config.FREE_PROVIDERS`, walked by
  `SearchEngine._resolve_free`), and an unnamed `search` where every enabled name
  is free. Routing *by task* remains declined until measured per-task defaults
  exist: if it lands it takes a caller-*declared* `task`, never inferred from the
  query's shape.
- **No host allow-list inside the application.** There is no `egress_allowlist`
  key: which hosts a search may reach follows from which provider names the
  config enables, so the key would be a second copy of the deployment's
  boundary, and it cannot bound `fetch`, whose target is arbitrary by design.
  The network layer enforces the useful half without decrypting TLS — a host
  name is visible in DNS and in the SNI — and `permitted_providers` stays the
  application's contribution. [`reference/deploying.md`](reference/deploying.md)
  renders those host lists.
- **No `robots.txt`, and no defence against prompt injection.** Fetched text is
  untrusted third-party content, and whoever controls a page controls what
  lands in the model's context. The tool description says so, but a tool
  description is a weak guardrail — see
  [`reference/fetch-safety.md`](reference/fetch-safety.md).
- **No second language for the CLI.** The CLI is a client of this server and
  holds no keys and no config, so a binary of its own would still need a
  reachable `seekwright` deployment. The portable surface is REST: `curl` or
  anyone's own script reaches the same three routes. The CLI ships in the same
  wheel, from the same tag, through the same CI job, reusing `models.py`, the
  `httpx` client and `argparse`. A CLI speaking MCP over `/mcp` is declined for
  the same reason, as is an in-process CLI, which would need every provider key
  on the client and duplicate the server's config resolution.

[`index.md`](index.md) is the map of everything else in this tree.
