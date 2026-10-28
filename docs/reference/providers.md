# Provider and API reference

Endpoint, request-shape and pricing facts for every search provider this project uses or
has studied, in one place, so the code never has to be re-read to answer "what does
Tavily expect?" or "what does Gemini grounding cost?".

There is no single snapshot date, and that is deliberate: each entry carries the date
its own facts were read, because entries are written when the adapter lands and the page
holds no second, aggregate as-of. The oldest material is the baseline study of
`pi-web-access`, an upstream project compared against early on (an internal study, not
part of this tree), whose findings survive under [Adoption
candidates](#adoption-candidates-from-the-pi-web-access-comparison); the newest entries
run to 2026-10-24. **Pricing is volatile and most of it came from provider marketing
pages, read on the date on the entry — treat every number below as "as of", never as
contract.** When a provider's pricing or shape changes, update that entry.

The `kind` labels (`serp`, `answer`, `content`) describe what a provider *returns* —
ranked links, synthesised prose plus citations, or extracted page text. They are
description only: the `Kind` literal and the router that dispatched on it are gone.

## How this page is organised

Three kinds of thing live in one page, and reading the wrong one is how a stale answer
gets quoted as a current one.

- **In-tree providers** — one entry per name this tree can call, with its
endpoint, request shape, price and live-test status.
- **Adoption candidates** — names studied and not wired. An adopted one becomes
a pointer ("moved in-tree <date>") rather than being deleted, because `src/` and
`tests/` comments and this page's own dated rows cite that heading; the facts move up.
- **Dated survey sections** — `Keyless coverage survey (2026-10-14)`, `SERP
candidate re-check (2026-10-16)`, `FreeNewsAPI revisit (2026-10-17)` and `Ruled out:
results-page parsers` record findings that code comments of the same date cite. The tier
test and the verdicts are in [free-providers-survey.md](free-providers-survey.md).

No count here is a current count: the frozen provider names print from the tree in
[surface.md](surface.md), and a price is as-of the date on its entry.

## Conventions shared by every provider here

Four rules hold for every adapter; their home is
[provider-contract.md](provider-contract.md), which carries the status-code table the
tests pin.

- **Auth from the environment only**, `SEEKWRIGHT_*` prefixed, in a header and
never in the URL.
- **Status classes** — 401/403 auth, 402/429 quota, 400/422 invalid request,
408/425/5xx transient, connection errors and timeouts network — mapped onto the
adapter's exceptions, never onto prose.
- **Redaction** — a raw response body or an `httpx` exception never reaches an
error message, because the request headers carry the key.
- **`cost_per_1k` is reporting only** — nothing routes on it; it sets what
`--check --live` prints, and a per-request-billed backend maps requests onto the 1k unit
in `cost_for()`.

Every figure here is a **declared** price. Actual spend per thousand calls over a 14-day
window is the `cost_per_1k` of the metrics aggregate — per terminal call, failures
included, so it sits below the declared row by the failure rate. See
[metrics.md](metrics.md), which also holds per-provider p50/p95 latency.

## In-tree providers

### Tavily — `content` + `answer` (free-tier keyed)

Snapshot: 2026-10-02 (entry created 2026-09-29; geo and usage re-checked against the
official API reference that day), against the documented API and the candidate entry
this adapter was adopted from (2026-08-01 shape).

- Endpoint: `POST https://api.tavily.com/search` (JSON)
- Auth: `Authorization: Bearer`
- Request: `{"query", "search_depth": "basic", "max_results", "include_answer":
"basic", "include_raw_content": false, "include_usage": true, "time_range",
"include_domains", "exclude_domains", "country", "language"}`. `time_range` from
`recency` (`day|week|month|year`; map the older `days`/`weeks` form if a live call shows
it). Domains are **native**, so `site:` folding is *not* applied.
  - `search_depth` pinned at `basic`: `advanced` is 2 credits per request, a
cost policy, not a caller choice. `auto_parameters` (may pick `advanced`) is never sent.
  - `country`/`language` are **ranking boosts**, not filters. `country` is a
closed enum of lowercase names for the default `general` topic, held as a code map
(`gl`-style codes plus `uk`/`usa`); an unmappable value is **omitted and noticed**.
`language` takes a code (Serper's `hl` mapping); `filter_by_language` is the strict form
and is not sent.
  - `safe_search` (bool, default `false`) drops adult content, verified
2026-10-14 at <https://docs.tavily.com/documentation/api-reference/endpoint/search> —
unsupported for the `fast`/`ultra-fast` depths the pin excludes.
  - `include_usage` asks for reported credit usage per call (see Cost).
- Response: `{"answer", "results": [{title, url, content, score,
published_date}], "usage": {"credits"}}`. A **content endpoint**: `content` (pre-cleaned
page text) fills `Result.text` under `policy.max_result_text_chars`, `text_truncated`
flagging a cut; `answer` goes to `SearchResponse.answer`. `usage.credits` is reported
usage: `ProviderResult._reported_cost_usd` (`TavilyProvider.search`), bound as
`reported_cost_usd` on `search.ok` (`SearchEngine._log_ok`) — a `PrivateAttr`, log-only,
never on the wire and not a journal field. Both sides use the same local `cost_per_1k`
(`TavilyProvider.cost_for` for the estimate), so their diff is the **credit count**
consumed (1 `basic`, 2 `advanced`), never a price: a Tavily repricing moves neither, and
the drift between recorded and published prices stays unmeasured.
- Failure classification: 401/403 auth (non-retryable); **429 and 432 quota**
(432 is the monthly-credit-exhausted code); other ≥400 generic.
- Cost: **1,000 credits/month free**, then $0.008/credit pay-as-you-go;
`cost_per_1k` defaults to 8.00 and `cost_for` ignores its argument (cost does not scale
with result count).
- Env: `SEEKWRIGHT_TAVILY_API_KEY` (required; the free tier is an account
quota).
- Fetch: `POST https://api.tavily.com/extract` is the `TavilyFetcher` ladder
fallback (2026-10-24), same key and permission-set name: `format: markdown`,
`extract_depth: basic`, one URL, no `include_usage`. Declared rate as read 2026-10-23:
**1 credit per 5 successful extractions** at `basic`, 2 per 5 at `advanced` — $1.60 per
1k at $8/1k, so the allowance buys ~200 extractions; an extraction that found nothing
bills nothing. `tests/live/test_live.py` holds the unrun `live`-marked call.
- Gotchas: `content` is pre-cleaned, so this sits between a raw SERP and a
fetch. The tool schema exposes `language`/`safe_search` only; `country` is
adapter-correctness until geo is exposed in its own change.

### TinyFish — `serp` (free keyed aggregator)

Snapshot: 2026-09-29, against the official docs (`docs.tinyfish.ai/search-api`,
reference page included). Supersedes the 2026-08-01 candidate entry.

- Endpoint: `GET https://api.search.tinyfish.ai` (query params)
- Auth: `X-API-Key` on every request; keys come from
`agent.tinyfish.ai/api-keys`.
- Request: `query` (required), `include_domains`/`exclude_domains`
(comma-joined, **native**, so `site:` folding is *not* applied), `recency_minutes`
(1–5256000; from `recency` as day=1440 / week=10080 / month=43200 / year=525600),
`location` (uppercased country code), `language` (lowercased). All honourable, so such a
search sets no `notice`. `page` (0-based, max 10) unused: results are sliced to
`max_results`, there being no result-count parameter. `domain_type`, `purpose` and the
research-paper params are unexposed. **No safe-search parameter** (checked 2026-10-14
against the reference and OpenAPI): `safe_search` dropped and noticed.
- Response: `{query, results: [{position, site_name, title, snippet, url, date,
publisher?, ...}], total_results, page}` — `snippet` filled, never `text`; `date` →
`published_date`. Zero results is a valid empty response.
- Failure classification: house table, plus **402 → `QuotaExhausted`** ("Search
API access is required for your account" is an account-level question, not auth —
Scrappa's x402 reasoning). 429 is rate limiting (30 req/min per key default); 503 is
documented as retryable.
- Cost: **free at any wallet balance, including $0**; `cost_per_1k` 0.0.
- Env: `SEEKWRIGHT_TINYFISH_API_KEY` (required; free is not anonymous).
- Gotchas: `snippet` is all you get — page text is the separate Fetch API
(`api.fetch.tinyfish.ai`), unwired here. Freshness is TinyFish's own index notion of
date.

### Algolia — `serp` (registered free tier / keyed)

Snapshot: 2026-10-12, against the Search API docs and <https://www.algolia.com/pricing>.

Algolia's Search API is **not a web search**: it searches one index the operator owns.
The provider is **index-scoped** — `app_id` and `index` are config, the search key is
the credential. One name covers every tier, the key being mandatory on all of them; the
*plan*, not the credential, sets the price — the opposite of the `exa`/`exa:free` split.

- **Endpoint**: `POST https://{app_id}-dsn.algolia.net/1/indexes/{index}/query`
(JSON). The app ID is part of the host, so there is no module-level `ENDPOINT` constant
— config-derived, like `searxng`'s.
- **Auth**: `x-algolia-application-id` (public, names the host) and
`x-algolia-api-key` (secret, environment-only).
- **Request**: `{"query", "hitsPerPage"}`, `hitsPerPage` being `max_results`, no
clamp needed (Algolia allows 1–1000, the tool caps at 20). No filter field:
`facetFilters`/`numericFilters` address attributes the adapter cannot know, so
**domains, dates, country, language and safe-search all ride `notice`** via
`ignored_constraints`.
- **Response**: `{"hits": [...], "nbHits", "page", "nbPages", "hitsPerPage",
"processingTimeMS", "query"}`, `hits[]` **schemaless** (`objectID` plus whatever was
indexed). Fills `snippet`, never `text`; no `published_date`, no `score` invented.
- **Attribute mapping**: title from `title_attr`, else first of
`title`/`name`/`question`, else DocSearch `hierarchy.lvl6…lvl0` (deepest non-empty); URL
from `url_attr` else `url`/`link`; snippet from `snippet_attr` else
`description`/`summary`/`excerpt`/`content`/`answer`. A hit missing title or URL is
dropped.
- **Failure classification**: 401/**403** auth (`403` is `Invalid
Application-ID or API key`, landing in the house auth row); 402 (`FeatureNotEnabled`,
plan-gated) and 429 → `QuotaExhausted`; **404** is `IndexNotFound`, falling to generic
`HTTP 404`; other ≥400 generic. What an exceeded 10K/month free quota returns is **not
characterised**.
- **Cost**: Free = 10K requests/month; Grow = 10K included then $0.50/1K; Grow
Plus $1.75/1K; `cost_per_1k` defaults to `0.50`.
- **Env**: `SEEKWRIGHT_ALGOLIA_API_KEY` (required; registration is mandatory on
every tier). `app_id`, `index` and the three attribute overrides are config.
- **Gotchas**: mapping defaults are a convenience, the knobs are the contract; a
wrong `index` surfaces as `HTTP 404`; the connectivity probe cannot run a real search
without spending quota (see the probe note in `health.py`).

### SearXNG — `serp` (self-hosted metasearch)

Snapshot: 2026-10-02 (entry created 2026-09-29), against the documented JSON API
(`/search?format=json`).

- Endpoint: `GET {url}/search`, `url` from config (`[providers.searxng] url`).
**There is no public default**: enabling it without a `url` is a startup config error.
- Auth: none — the operator's own instance. The URL is operator-fixed config and
no caller input reaches it, so unlike `fetch` there is no SSRF guard here.
- Request: `q` (with `site:` / `-site:` folded in; the aggregated engines honour
them), `format=json`, `pageno` from 1, `time_range` from `recency`
(`day|week|month|year`), `language` from `language` (verbatim; the docs' "Code of the
language"), `safesearch` from `safe_search`.
  - `safesearch` is `0|1|2`, defaulting to the instance's `search.safesearch`
(verified 2026-10-14 at <https://docs.searxng.org/dev/search_api.html>). `True` sends
`2`, the strict level: a caller who asked for filtering cannot tell how much it got, and
under-filtering is the invisible failure.
  - Pagination: page size is the instance's, not this API's, so a short page
walks `pageno` forward, bounded at three pages; an empty page or a failed continuation
stops the walk and returns what it holds (page one failing still raises).
- Response: `results[]` with `{title, url, content, score, publishedDate,
engines, infobox}`. Kept: `title`/`url`/`content` (→ `snippet`), optional `score` and
`publishedDate`; dropped: `engines`, `infobox` and the rest. Zero results is a valid
empty response, not an error.
- Cost: 0 — the operator's hardware aggregating other engines' results.
- Env: none (keyless); `url` in config is what enables it.
- Gotchas: the instance needs JSON enabled (`settings.yml`: `search.formats`
including `json`), else the endpoint answers HTML and the adapter raises "malformed JSON
response". It answers at scraper speed, so the factory floors its timeout at 15s. No
country parameter, so a `country` caller gets a `notice` naming the country half alone —
the language rides `language`, so a joined `country/language` token would claim a drop
that did not happen.
- **Public instances are a non-option, deliberately**: volunteer-hosted, and
their limiters 429 scripted JSON traffic (probed 2026-10-02: several of the largest
returned 429 to a bare GET), while the operator's standing position is to put no agent
load on them. The provider exists for your own instance; no fallback to anyone else's
should be added.
- **No 402 fallback either**: nothing bills this transport, so no spent upstream
quota exists to answer with a payment status, and the JSON-API page
(<https://docs.searxng.org/dev/search_api.html>, read 2026-10-20) lists parameters, not
a status table. 429 from the instance limiter is the whole quota row; a 402 in front of
an instance URL is the reverse proxy (2026-10-20).

### Serper — `serp`

- Endpoint: `POST https://google.serper.dev/search` (JSON)
- Auth: `X-API-KEY` header
- Request: `{"q", "num"}` plus `gl` (country), `hl` (language), `tbs` (recency:
Google's `qdr:d/w/m/y`, from `recency`). Domain filters fold into `q` with `site:` /
`-site:`. **No safe-search parameter**: the playground-observed set is `q`, `gl`, `hl`,
`tbs`, `num`, `page` (plus `autocorrect`, and `location`/`ll` elsewhere), and two client
integrations document the same list with no `safe` (checked 2026-10-14) — so
`safe_search` is dropped and noticed, not mapped onto an unverified field.
- Response: `organic[]` with `{title, link, snippet}`; the ~10 other element
families (knowledge panels, people-also-ask, ...) are deliberately dropped.
- Cost: `~$1/1k` (config default). **Requests over 10 results cost 2 credits** —
`cost_for()` accounts for it.
- Env: `SEEKWRIGHT_SERPER_API_KEY`
- Gotchas: **out of credits is classed with the rate limit, at `402 / 429`** —
both ride `QuotaExhausted` since 2026-10-20. The vendor page for that status is
unreachable (probed 2026-10-20: `https://dev.serper.dev/faq` fails DNS,
`https://serper.dev/faq` answers 404, and the 200 landing page, 1,043,932 bytes, never
names the state), so the widening rests on what does resolve: Serper is credit-metered
(`https://serper.dev/`: "50k credits ($1.00/1k)"), 402 is Payment Required
(<https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/402>), and the
house table puts `402 / 429` on one row. The class is one-sided: an unclassified `HTTP
402` never fires the fallback and never reaches cost tracking. Google's index, so
`gl`/`hl` do what you expect.

### Linkup — `answer` or `serp` (per configured instance)

- Endpoint: `POST https://api.linkup.so/v1/search` (JSON)
- Auth: `Authorization: Bearer`
- Request: `{"q", "depth", "outputType", "maxResults", "includeDomains",
"excludeDomains", "fromDate"}`. `outputType` is `sourcedAnswer` or `searchResults`;
`fromDate` is RFC-3339 from `recency` (now minus 1/7/30/365 days); `toDate` stays
unexposed, recency being open-ended. `SearchInput` has **no language field and no
safe-search field** (checked 2026-10-14 against its OpenAPI), so both are dropped and
noticed.
- Response: `sourcedAnswer` → `{answer, sources: [{name, url, favicon,
snippet}]}`; `searchResults` → `{results: [{name, url, content, favicon, type}]}` (image
results dropped).
- Cost: `~$6/1k` for `sourcedAnswer` (config default), **per request**. `depth`
is deployment policy, not a caller parameter: `deep` is roughly a 10× cliff ($0.05 vs
$0.006).
- Env: `SEEKWRIGHT_LINKUP_API_KEY`
- Fetch: `POST https://api.linkup.so/v1/fetch` is the `LinkupFetcher` ladder
fallback (2026-10-24), same variable and permission-set name: `renderJs: true` at `mode:
standard`, with `extractImages`, `includeRawHtml` and `includeRawContent` sent as
`false` rather than left to the vendor default. The pricing page read 2026-10-24 bills
per call off a `mode` × `renderJs` table, and the cell sent here is `$0.005`, so the
fallback declares `cost_per_1k = 5.00` — the price of the call it makes, not the
`renderJs: false` cell it never sends. `images[]` is dropped; `402` stays out of the
quota fallback for the x402 reason below.
- Gotchas: 429 is both the rate limit **and the documented spent-credit answer**
(429 → `QuotaExhausted`): "You have run out of credit or you are sending too many
concurrent requests", with the pricing page adding "If your account runs out, the API
will respond with a 429 HTTP error"
(<https://docs.linkup.so/pages/documentation/platform/errors> and
<https://docs.linkup.so/pages/documentation/platform/pricing>, fetched 2026-10-20).
**`402` is on the table but stays out of the quota fallback, and the reason is the lane,
not the status**: its 402 row is "x402 payment signature is missing, invalid, or
settlement failed", reached by a request without authentication
(<https://docs.linkup.so/pages/documentation/platform/x402>, fetched 2026-10-20). This
adapter always sends the `Bearer` key and `linkup` sits in
`config.PROVIDERS_REQUIRING_KEY`, so that 402 fronts a request this proxy never sends —
unlike `scrappa`, `tinyfish` and `anysearch`, whose 402s arrive on the request this
client makes. The fallback was checked on 2026-10-20 and left at 429. `400` is a
bad-request row; the credit case is only the body name `LinkupInsufficientCreditError`,
which is never read — classification is on status, never on a body.

### Scrappa — `serp` (+ extraction, for `fetch`)

Snapshot: 2026-08-14 (docs, not a live response — verify the shapes on the first real
call and correct this entry if they differ).

- Endpoint: `GET https://scrappa.co/api/search-light` (query params). The sibling
`GET /api/search` is the fuller Google SERP at the same 1 credit, but caps results at 10
and its extra payload (knowledge graph, related questions, local results) is what this
project drops.
- Auth: `x-api-key` header.
- Request: `query`, `num` (1–20, default 10), `gl` (country), `hl` (language),
`dateRestrict` (recency: `d1`/`w1`/`m1`/`y1` — the docs snapshot's shape, verify live),
plus `lr`/`cr`/`start`/`page`/`sort`, not exposed. `safe` **is** exposed: "Safe search:
off or active (default: off)", verified 2026-10-14 at
<https://scrappa.co/docs/google-search-api/google_search_light> — the only on/off state
Google offers, so `safe_search=True` sends `safe=active`. Domain filters fold into
`query` with `site:` / `-site:`, as on Serper.
- Response: `organic_results[]` with `{position, title, link, snippet}`;
`search_information` and `pagination` are dropped.
- Extraction: `GET https://scrappa.co/api/web-scraper` — `url`, `javascript`
(renders JS), `include_html`, `response_type=markdown`; returns `{success,
site_status_code, url, final_url, data: {title, description, body_text, links, images,
html, ...}}`. The `fetch` fallback, in JSON mode rather than `response_type=markdown`
because it carries the title and the origin's status code, which `FetchedPage` wants.
- Cost: **1 credit per request** on every endpoint, no multipliers — cost does
not scale with `num`, unlike Serper. ~$0.30/1k on the $10 starter pack, down to $0.20/1k
at volume; **500 free credits every month**; failed requests are not billed.
- Env: `SEEKWRIGHT_SCRAPPA_API_KEY`
- Gotchas: `num` is capped at 20, so a larger ask silently gets 20 (clamping, not
paginating, which would multiply credits). Rate limits are undocumented, so the 429
branch is speculative; 401 returns `{"message": "Unauthenticated"}` and 402 covers x402
accountless payment challenges, which is why 402 is quota here. Unverified: whether
`javascript=1` costs more than 1 credit.

### Exa — `content` (hosted MCP), as two names: `exa:free` and `exa`

One backend, two selectable providers: the same endpoint serves both an anonymous free
tier and a billed authenticated one.

| Name | Key | Behaviour |
|---|---|---|
| `exa:free` | none — one of the five names exempt from `PROVIDERS_REQUIRING_KEY` (`parallel:free`, `freeserp`, `searxng` and `anysearch` are the other four) | anonymous only, never billed, `cost_usd` always `0.0` |
| `exa` | **required**, `SEEKWRIGHT_EXA_API_KEY` | tries the anonymous tier first, escalating to the key only when it fails |

Naming `exa` agrees to ~$7/1k, and the ladder can only charge less, never more; naming
`exa:free` cannot charge anything.

- Endpoint: `https://mcp.exa.ai/mcp` — a streamable-HTTP MCP server, not a REST
API. The transport yields `(read, write, get_session_id)`, verified live; auth is a
pre-configured httpx client.
- Direct API (candidate if the free MCP tier ever gets too limiting):
`https://api.exa.ai/search` and `https://api.exa.ai/answer`.
- Cost: the anonymous MCP tier is free and rate-limited; a **keyed** MCP session
bills the account normally. Direct API is pay-as-you-go: ~$20 free credits on signup +
$10/month free-tier credits; standard search ~$7/1k (raised from $5); a $1/1k surcharge
per result past the 10th on most endpoints; `deep` search takes 4–50s and is priced
higher; page contents for the first 10 results are included.
- Env: `SEEKWRIGHT_EXA_API_KEY` for `exa`; none for `exa:free`.

Verified against the live endpoint on 2026-08-14:

- **A keyed MCP session is authenticated and billed.** An invalid key is rejected
(`401: Invalid API key`), and one keyed search moved the account's daily spend by
exactly $0.007: a key is not a decorative header on a free tier but the difference
between free and billed.
- **An invalid key arrives as `isError=True` inside an otherwise successful MCP
call**, not as a transport error, so the adapter's `isError` branch is the only place
that can classify it; a plain `ProviderError` there would look like a transient upstream
failure.
- **Handshakes are free**; only tool calls bill — three handshakes plus one
search produced one search charge, which is what makes `TieredExaProvider.warmup`
opening the keyed session at startup safe, and keeps `--check` free.
- **Unauthenticated REST returns 402**, not 401 — an x402 payment challenge
("Payment required to access this resource") quoting $0.007 in USDC on Base or Solana,
plus an agentkit flow offering 100 free uses to an agent that proves a human backs it.
The 402-means-quota row above reads differently here.
- The anonymous tier's *exhaustion* message is *not* characterised: 12
consecutive keyless searches all succeeded (~1.4s each). The rate-limit detector in
`exa_mcp.py` sniffs for `rate`/`quota`/`429` and may miss the real wording — which is
why escalation triggers on any provider error.

- Gotchas: the free tier is the point — if adoption grows, the direct API is
where the cost curve starts mattering.
- **Length is ours to bound, not Exa's.** `web_search_exa` advertises exactly
`query` and `numResults`, with `"additionalProperties": false` (verified 2026-08-14), so
there is no shorter result, no summary and no filter of any kind — no dates, domains,
language or safe-search. Every constraint on an `exa` search is dropped and noticed.
Each hit is several thousand characters of page text, which the proxy clips
(`policy.max_result_text_chars`). The direct API is where `contents.text.maxCharacters`
and server-side summaries live; getting them costs a key and ~$7/1k.

### Parallel — `content`, as two names: `parallel:free` and `parallel`

Snapshot: 2026-10-12, against `docs.parallel.ai` and live calls (anonymous MCP verified
end to end; the keyed REST shape read from the docs and the returned 401 body).

One backend, two selectable providers: the REST Search API is keyed and billed per
request, the **hosted Search MCP is free anonymously**, so — as with Exa — the
credential decides the price and the two prices get two names.

| Name | Key | Behaviour |
|---|---|---|
| `parallel:free` | none | anonymous hosted MCP, never billed, `cost_usd` always `0.0` |
| `parallel` | **required**, `SEEKWRIGHT_PARALLEL_API_KEY` | billed REST, priced by `mode` |

- Endpoint: `POST https://api.parallel.ai/v1/search` (JSON) — `/v1`, never the
older `/v1beta`. `parallel:free` instead speaks streamable HTTP to the hosted MCP server
`https://search.parallel.ai/mcp`, tool `web_search`.
- Auth: `x-api-key: <key>` on REST; anonymous MCP sends none.
- Request (REST): `search_queries` (a **list**, required), `mode`
(`turbo`/`fast`/`basic`/`advanced`), `advanced_settings.max_results` (server default 10,
no documented ceiling), `advanced_settings.source_policy` (`include_domains` /
`exclude_domains`, list[str], plus `after_date` as RFC 3339 `YYYY-MM-DD`) and `location`
(ISO 3166-1 alpha-2 country). `objective` is optional and unused — the query rides
`search_queries`. **No language field and no safe-search field** (checked 2026-10-14
against `advanced_settings`' reference), so both are dropped and noticed. Domain filters
are native, so `site:` folding is *not* applied.
- Request (free MCP): tool `web_search` takes `objective` (required),
`search_queries` (required), `session_id` and `model_name` — **no filter arguments at
all**, and connection-level overrides are ignored for anonymous requests, so this
fallback honours no constraint (reported in `notice`).
- Response: `{"search_id", "results": [{"url", "title" (nullable), "publish_date"
(nullable `YYYY-MM-DD`), "excerpts": [str, ...]}], "warnings": [{"type", "message"}] |
null, "usage", "session_id"}`. `usage` is **documented but unwired**:
`ParallelProvider.search` reads `results` and `warnings` only. A **content endpoint**:
the joined `excerpts` fill `Result.text` under `policy.max_result_text_chars`,
`text_truncated` flagging a cut; a null `title` falls back to the URL. The anonymous MCP
returns the same JSON, as `structuredContent` and in a `TextContent` block.
- Errors: REST rejects an anonymous call with `401 {"code":16,"message":"No API
key provided (C.0)"}`. Bodies are never interpolated (redaction rule).
- Cost: REST bills **flat per request by mode** — `turbo` $1/1k, `fast` $1/1k,
`basic` $5/1k, `advanced` $5/1k — so result count does not price the call. The default
is `fast` (Parallel's agent recommendation: ~700ms, $1/1k) rather than the API default
`advanced` (~3s, $5/1k); pin another with `[providers.parallel] mode = "..."` and
correct `cost_per_1k` alongside it. Anonymous MCP is **$0**.
- Env: `SEEKWRIGHT_PARALLEL_API_KEY` for `parallel`; none for `parallel:free`.
The variable is built from the name's **backend segment** (`config.api_key`).
- Gotchas: **`exclude_domains` is ignored whenever `include_domains` is
non-empty** — the adapter notices the drop rather than letting the caller believe it
applied. `language` has no API field, so it is dropped with a notice while `country` is
honoured via `location`. Domain and path prefixes in `source_policy` require a
non-`turbo` mode. Anonymous MCP ignores connection overrides and caps excerpts at ~25k
characters server-side (it runs `fast`).

### Search1API — `serp` (metered free tier keyed)

- Endpoint: `POST https://api.search1api.com/search` (JSON; `Authorization:
Bearer` key from the dashboard). `/crawl` is a hosted `fetch` fallback — reference only
(see the extraction table below).
- Request: `query` required; `max_results` (1–50, default 5), `include_sites[]` /
`exclude_sites[]`, `language`, `time_range` (`day`/`week`/`month`/`year`) — the native
filter fields, so no `site:` folding. `crawl_results` (Deep Search) is **never sent**:
each crawled page costs an extra credit, a cost policy, not a caller choice.
`search_service` picks one engine (google/bing/...); unset here, so results are
multi-engine.
- Response: `results[]` with `{title, link, snippet, published_date}` plus
dropped engine-specific fields. `content` exists upstream only when `crawl_results > 0`,
so it is never read; the `searchParameters` echo and `images[]` are dropped.
- Cost: a basic search is **1 credit** whatever `max_results` says (credit
guide, 2026-10-16); Deep Search would be `1 + n` credits and is never sent. 100 free
credits at signup, "No credit card required". Plans $0.49–0.76 per 1k searches (Basic
$19/mo ≈ $0.76/1k is the `cost_per_1k` config default).
- Env: `SEEKWRIGHT_SEARCH1API_API_KEY`
- Gotchas: no country and no safe-search parameter — `country` is dropped and
noticed (the notice names `country` alone because `language` is honoured); `max_results`
above 50 is a documented invalid request; 402 is "payment required" — for a keyed
client, the credits are gone.
- **Status (2026-10-16): implemented, untested.** Written against the documented
API (re-verified that day) but never run live in-repo: the live test
(`tests/live/test_live.py`) is gated and skips without the key. Until it runs, the
startup line and `--check` announce the name from `config.UNTESTED_PROVIDERS`, which it
leaves when the live test has run.

### AnySearch — `serp` (keyless, explicit-only)

- Endpoint: `POST https://api.anysearch.com/v1/search` (JSON, re-verified against
the live docs 2026-10-16). Keyed plans exist (`Authorization: Bearer` against the same
endpoint), but the adapter implements the **keyless mode only**: no `Authorization`
header is ever sent.
- Request: `query` required; `max_results` (1–10, default 10 — clamped, not sent
as a documented-invalid request); `language` is the only filter field sent. `zone` takes
`cn` / `intl`, which a country code cannot be mapped into without guessing, so `country`
is dropped and noticed; there is no domain, date or safe-search field. `tag`, `params`
and `format` are never sent: sub-domain routing, AnyMix passthrough, and the encoding of
the extract the adapter does not read.
- Response: envelope `{code, message, request_id, data}`; success is `code: 0`
and hits are `data.results[].{title, url, snippet, content}`. `title` may be empty,
which drops the record like a missing one. `snippet` is the SERP field; `content` is a
cleaned page-text extract the adapter never reads. No date field exists upstream.
`metadata.total_results` counts this response, not a hit pool, and is not mapped.
- Cost: the anonymous mode serves **1,000 requests/day** with no account, no key
and no card (pricing page; ToS v1.1 §5.1.1), so `cost_per_1k` is 0.0 — a call here
cannot bill, as `freeserp`'s cannot. Paid plans take Alipay/WeChat Pay.
- Gotchas: the anonymous daily-quota 402 can carry auto-generated account
credentials in its `message` (the operator auto-registers the caller) — the constant
`QuotaExhausted` message is the redaction rule, and the body never reaches a log line. A
200 whose business `code` is not 0 is the error channel at another status, and its
`message` is not echoed either.
- **Explicit-only (the survey's routing stance, 2026-10-16):** tier 1 by the
survey's criteria — the only SERP candidate with a keyless route, confirmed by the
keyless probe — and nevertheless in **no walk**: not the keyless install default, not
`FREE_PROVIDERS`, not `FREE_PROVIDER_ORDER`. Unlike its four keyed siblings, whose
exclusion follows from billing, it is reached only by naming it.
`tests/test_config.py::TestAnysearchRouting` pins that.
- **Status (2026-10-17): implemented, live-verified.** The live test
(`tests/live/test_live.py`) has run against the real endpoint from the repo's
environment: `api.anysearch.com` resolves behind CloudFront, the TLS handshake is clean,
and keyless calls came back `code: 0` with the documented envelope and real SERP
results. The name has left `config.UNTESTED_PROVIDERS`.

### SerpAPI — `serpapi` (metered free tier keyed)

- Endpoint: `GET https://serpapi.com/search` (documented JSON API; `output=json`
is the default, `html` and `md` exist and are never requested). Google and other engines
behind one key.
- Naming: the survey recorded this backend as `serp`, already the in-tree name of
FreeSerp; the provider and module are `serpapi` on purpose — a distinct name, module and
key, and no collision with `serper` (Serper.dev), a different operator at a different
endpoint.
- Auth: the API key rides **in the query string** (`api_key=…`) — the operator's
documented shape, diverging from this tree's header convention. The request URL is a
secret surface: no failure path interpolates an exception or body into a message, and
`tests/providers/test_serpapi.py` pins that for every failure mode.
- Request: `q` and `engine` (`google`) required. `gl` takes `country`, `hl` takes
`language` (lowercased), `tbs` takes `recency` (`qdr:d/w/m/y`, as `serper` uses), `safe`
takes `safe_search` (`active`/`off`; unset sends nothing). Domain filters fold into the
query as `site:` / `-site:`, as on every Google-backed backend — all five constraint
buckets are honoured and `notice` stays empty. `max_results` is a cap, not a request:
the documented parameter set has no result-count field, and the parse honours the cap.
- Response: `organic_results[]` with `position`, `title`, `link`, `snippet` and
an optional display `date` ("5 days ago"); `snippet` filled, never `text`.
`search_metadata`, `answer_box` and the other element families are dropped.
- Cost: the free plan is **250 searches/month at $0** (50/hour, no card), and
only successful searches count, so `cost_per_1k` defaults to `0.0`. Paid plans bill per
search (pricing page, read 2026-10-16); an operator on one corrects the figure in
config.
- Env: `SEEKWRIGHT_SERPAPI_API_KEY`
- Gotchas: 429 is the hourly throughput limit *or* an exhausted allowance (the
`QuotaExhausted` fallback); 400 is "missing required parameter", reported by code alone.
The `--check` probe is a parameter-less GET with the key in the query string: rejected
before any search runs, and only successful searches count, so it proves the path and
key for free.
- **Status (2026-10-16): implemented, untested.** Written against the documented
API (pages re-verified that day) but never run live in-repo: the live test
(`tests/live/test_live.py`) is gated and skips without the key. Until it runs, the
startup line and `--check` announce the name from `config.UNTESTED_PROVIDERS`, which it
leaves when the live test has run.

### Querit — `serp` (metered free tier keyed)

- Endpoint: `POST https://api.querit.ai/v1/search` (documented JSON API; the
operator's reference page for coding agents, re-read 2026-10-17). A real-time SERP over
hundreds of billions of records. The companion `POST https://api.querit.ai/v1/contents`
extraction endpoint (+$1/1,000 pages) is not part of this adapter — the `fetch` path has
its own extraction backends (the entry stays in the extraction table below, reference
only).
- Auth: the account API key in `Authorization: Bearer …`, environment-only via
`SEEKWRIGHT_QUERIT_API_KEY`.
- Request: `query` required, `count` the result count — clamped to the free
plan's documented **10-result cap**, whatever `max_results` asks: the adapter must not
silently exceed the cap of the plan it bills against. Fewer hits than asked is a shorter
answer, not a dropped constraint, so the clamp puts nothing in `notice`. Domain filters
ride native fields (`filters.sites.include` / `filters.sites.exclude`, no `site:`
folding), `recency` rides `filters.timeRange.date` (`d1`/`w1`/`m1`/`y1`), `country`
rides `filters.geo.countries.include`, `language` rides `filters.languages.include`. The
last two are strict operator enums (17 country names, 8 language names), so only codes
the adapter can express are sent: an unmappable code is reported in `notice`, an
off-enum value being a 400, not a filter. `needContent`, `highlights` and the deprecated
`chunksPerDoc` are never sent — they return body text (`sentence` / `highlights`), which
would fill `text` on a SERP backend.
- Response: `results` is an **object** whose `result` array carries the hits (the
singular key is the wire's shape; every result field documented optional): `url`,
`title`, `snippet`, `page_age` (plaintext UTC+0), `site_name`. `snippet` filled, never
`text`; `search_id`, `took`, `query_context` and `site_icon` are dropped.
- Cost: the free plan is **1,000 calls/month with no payment method required**
(the operator's own FAQ, 2026-10-16 re-check), so `cost_per_1k` defaults to `0.0`. The
PAYG tier bills $4/1,000 requests at 10 QPS (same re-check).
- Env: `SEEKWRIGHT_QUERIT_API_KEY`
- Gotchas: the free plan is 1 QPS, up to 10 results and English only
(2026-10-16 re-check), so a 429 can be the rate limit or an exhausted monthly allowance
— the `QuotaExhausted` fallback is right either way (terminal, non-retryable).
`error_code` mirrors the HTTP status, so body-level errors are already surfaced. The
`--check` probe is a bodyless GET: the endpoint answers 401 without a key (verified
2026-10-17), proving path and key without a search.
- **Status (2026-10-17): implemented, untested.** Written against the documented
API (pages re-read that day) but never run live in-repo: the live test
(`tests/live/test_live.py`) is gated and skips without the key. Until it runs, the
startup line and `--check` announce the name from `config.UNTESTED_PROVIDERS`, which it
leaves when the live test has run.
- **Live verification deferred 2026-10-19, not waived.** The owner put it with
the providers that need an account key: the live test runs in one billed batch with
`search1api` and `serpapi` once those keys exist. Its allowance is a metered account
quota, and a metered quota is a price with a delay on it, so `querit` stays keyed and
out of `FREE_PROVIDERS` — `tests/test_config.py::TestQueritRouting` pins it.

### DeepSeek — `serp` (+ a model-facing `summary`) (keyed, billed per request)

- Endpoint: `POST https://api.deepseek.com/v1/tools/search` (the Search & Fetch
guide, `api-docs.deepseek.com/guides/search`, read 2026-10-21), on DeepSeek's in-house
engine, so the folded operator syntax is its own, not Google's. The companion `POST
https://api.deepseek.com/v1/tools/fetch` endpoint ($0.75/1k requests) is **not part of
this adapter** — page text is the `fetch` path's job, and the entry stays out of the
extraction table below until that fallback exists.
- Auth: the account key in `Authorization: Bearer …` with
`Content-Type: application/json`, environment-only via `SEEKWRIGHT_DEEPSEEK_API_KEY` —
the same bearer auth as the model API.
- Request: `query` required, **1 to 128 Unicode characters and never all
whitespace**; `count` the result count, documented **1 to 50** (default 10), clamped to
that range — the backend's ceiling, not a plan cap like `querit`'s 10 — while the
surface asks for at most 20. `ori_question` is never sent (a proxy does not know the
question behind a search); `need_content` is never sent, so no page body is asked for.
- Filters ride the **query string** — `query`, `count`, `ori_question`,
`localization` and `need_content` are the whole body — folded in the guide's example
order: term, `site:`, `lang:`, `after:`. Domains use `site:` / `-site:`, multiple
includes joined by `OR`; `site_filtered_query` is deliberately **not** used, because it
parenthesises a multi-site filter and parentheses are not in the documented syntax.
`language` rides `lang:<code>`; `recency` rides `after:<YYYY-MM-DD>` from today (1, 7,
31 and 366 days back — the guide takes a date, not a unit). `country` has **no wire
form** (`localization` takes an IP address), so the ask is named in `notice`. There is
no safe-search parameter.
- The 128-character ceiling bounds the **folded** query while the surface allows
400. Neither answer is silent: an over-limit query is refused before sending, naming the
limit (not retryable — the request would have to change); a fold that would exceed it
drops the operators, sends the bare query and names every dropped bucket in `notice`.
- Response: a `results` array, empty when nothing matched. Each hit carries
`rerank_score` (0–3, 1.5+ documented as high-quality), `title`, `url`, `snippet`
("typically 100 to 200 characters", for display in a UI), `summary` ("typically 600 to
800 characters", to be read by a model), `content` (empty unless `need_content`),
`site_name`, `site_icon`, `date` (RFC 3339 UTC or null) and `authority` (0–4, `-1`
unknown). `snippet` rides `Result.snippet` and `summary` rides `Result.text`: the one
name in the tree that fills both, because the operator says which field is for a UI and
which for a model — the two policy caps and `text_truncated` carry the size difference.
`rerank_score` rides `Result.score`. `site_name`, `site_icon` and `authority` have no
`Result` field and are dropped; `content` is never requested.
- Cost: **$0.75 per 1,000 successful requests**, billed **per request** — not by
tokens, not by result count, and `count` does not change the price. A 200 with an empty
`results` array is **not billed**, so the adapter reports `0.0` there. There is **no
free tier**: a prepaid balance, `402` the documented "insufficient balance" answer — why
the name is keyed, sits out of the cannot-bill set, and defaults `cost_per_1k` to the
published rate.
- Rate limits: Search is 100 QPS per account regardless of key, separate from
Fetch's 25 QPS and from model concurrency; above it, `429`.
- Status codes (the guide's own table): 400 invalid headers or body, 401 missing
or invalid key, 402 insufficient balance, 403 Fetch-only security rejection, 404
Fetch-only, 408 request-body read timeout (retry), 413 body too large, 429 QPS exceeded,
500 internal, 504 downstream timeout. The adapter reads 401/403 as auth, 402/429 as
quota, 408 as a retryable upstream timeout and every other ≥400 as a provider error
carrying the status; the vendor's body is never echoed.
- Env: `SEEKWRIGHT_DEEPSEEK_API_KEY`
- Gotchas: the `--check` probe is a bodyless GET against a **POST-only**
endpoint, so it answers an error rather than `querit`'s auth check; like `anysearch` it
proves the network path to the host the adapter dispatches on. The bearer key is also
the model API credential, so an operator pointing `[agent]` at DeepSeek spends one
balance from two products.
- **Status (2026-10-21): implemented, untested.** Written against the documented
API (guide re-read that day) but never run live in-repo: the live test
(`tests/live/test_live.py`) is gated and skips without the key. Until it runs, the
startup line and `--check` announce the name from `config.UNTESTED_PROVIDERS`, which it
leaves when the live test has run.

### FreeSerp — `serp` (keyless)

Snapshot: 2026-10-14, against <https://freeserp.ai/docs.php> and
<https://freeserp.ai/web-search-api>, plus a live probe of the endpoint that day.

- Endpoint: `GET https://freeserp.ai/api.php` (also reachable as `/api`; query
params). Two indexes: `index=web` (FreeSerp Global — the operator's own full-web index)
and `index=sites` (the default: homepage-level profiles of live sites with an LLM
summary, a Domain Rating and a tech-stack taxonomy). Only `index=web` is a web-search
backend in this proxy's sense, and it is the one the adapter asks for.
- Auth: **none** — the docs' words are "No key, no signup". The operator asks
callers to self-identify with optional `agent` / `email` / `project` / `website` params
(or an `X-Agent` header) so they can warn before a breaking change; nothing is validated
or rejected without it.
- Request (`index=web`): `q` (required), `lang` (ISO 639-1 — the `language`
mapping), `fresh` (0/1), `published_from` / `published_to` (`YYYY-MM-DD`), `ranking`
(`bm25_trust` default, or `bm25` / `bm25_rank` / `bm25_fresh`), `sort` (`relevance` /
`fresh`), `size` (1–100, default 10), `from` (offset, with `from + size ≤ 100`).
`index=sites` takes filter/sort params instead of `q`. Domain control exists only as
`index=sites` keyword filters — no `site:` operator, no domain field — and there is **no
country parameter**, so `include_domains`/`exclude_domains` and `country` are dropped
and noticed.
- Response: `{ok, index, query, total, count, from, size, sort, ranking, filters,
took_ms, engine_ms, cached, results[]}`, each result `{url, domain, title, snippet,
language, published_at, crawled_at, score, site{…}, source{index, captured_at,
digest}}`. `snippet` is filled and no page text requested, so it maps onto
`Result.snippet` and carries a `published_date` (`published_at`, falling back to
`crawled_at` — the docs say the declared date is missing for many pages). `total` is the
size of the top-100 candidate pool, **not** an exhaustive hit count (their caveat,
verbatim), and nothing reads it as one.
- Cost: 0 — no account, no key, no card, so `cost_per_1k` is `0.0`. Documented
limits: "no hard limit and no key — the service is free and open", asking callers to
stay around "a few requests/second"; responses are edge-cached ~30 s; `from + size ≤
100` per query. Errors: `400 query_required` (`index=web` without `q`), `502` upstream
(retry with backoff), `204` CORS pre-flight. Bad params do not error — unknown filters
are ignored and an invalid `sort` falls back to `relevance`.
- Free-tier terms: no attribution requirement is stated, and every result carries
a `source.digest` citation to their crawl record. `--check`'s probe is a live keyless
call against a small operator's service: the one name whose readiness line is somebody
else's quota.
- Hosted MCP: `https://freeserp.ai/mcp` — streamable HTTP, nothing to install,
five tools (`freeserp_search`, `freeserp_help`, `freeserp_stats`,
`freeserp_list_endpoints`, `freeserp_get`); a plain `GET` on that URL returns the live
tool catalog. This adapter dials the documented GET instead.
- Gotchas: the index is theirs, batch-refreshed from their own crawl, so a page
changed after its `crawled_at` is not reflected yet; `index=web` can answer from the
sites index when their web engine is unavailable (`engine_fallback: true` in the body),
so a caller must check that field; `score` is their BM25×trust number, not a normalised
relevance; `site` is null for a domain absent from their sites index. Provenance: a
small operator with no SLA, and every term above is *their* statement as read on
2026-10-14 — verified as stated, not as contracted. The no-scrape rule holds: the
adapter receives a JSON response document, not a results page.
- Env: none (keyless). Nothing in config enables it but its own name in
`[providers]`, and it is one of the three names an empty `[providers]` block resolves to
(`config.KEYLESS_PROVIDERS`).
## Adoption candidates (from the pi-web-access comparison)

Adoption status is the P0–P2 priority that comparison recorded. These are
documented so the endpoint knowledge does not have to be re-extracted from a
fast-moving upstream. Env names listed are pi-web-access's own; adoption here
would use `SEEKWRIGHT_*`.

### Gemini API grounding — `answer` (P0)

- Endpoint: `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`
- Auth: `x-goog-api-key` header **only** — never the URL. Gateway variant:
  `GOOGLE_GEMINI_BASE_URL` + `CLOUDFLARE_API_KEY` sends `cf-aig-authorization`.
- Request: `{"contents": [{"role": "user", "parts": [{"text": query}]}],
  "tools": [{"google_search": {}}]}`. Model default `gemini-3.6-flash`.
- Response: answer = joined `candidates[0].content.parts[].text`; results =
  `groundingMetadata.groundingChunks[].web.{uri,title}`. Chunk URLs under
  `vertexaisearch.cloud.google.com/grounding-api-redirect` need a HEAD request
  with manual redirect handling (5s timeout) to resolve to the real URL.
- Cost: **5,000 grounded prompts/month free** on the Gemini 3 tier (shared
  across models), then $14/1k search queries. Model tokens billed separately
  (~$1.50/1M in, $7.50/1M out on the paid tier).
- Gotchas: billed per *search query executed*, and one prompt can execute
  several. The API key must be redacted from error text before it is surfaced.

### Perplexity Sonar — `answer` (P1)

- Endpoint: `POST https://api.perplexity.ai/chat/completions`
- Auth: `Authorization: Bearer`
- Request: `{"model": "sonar", "messages": [{"role": "user", "content":
  query}], "max_tokens": 1024, "return_related_questions": false}` plus
  `search_recency_filter` and `search_domain_filter`.
- Cost: sonar $1/1M input + $1/1M output; sonar-pro $3/1M in, $15/1M out.
  A grounded answer is a few thousand tokens, so fractions of a cent per query.
- Gotchas: pi-web-access runs its own local rate limiter for this provider;
  credentials are redacted from errors.

### Tavily — moved in-tree 2026-09-29

Adopted from this candidate list; see the in-tree entry above.

### Brave Search API — `serp` (P1)

Snapshot: 2026-08-14. Re-checked after the February 2026 repricing, and probed
live against the endpoint; the rest of this file is the 2026-08-01 snapshot.

- Endpoint: `GET https://api.search.brave.com/res/v1/web/search` (`POST` also
  accepted, for long queries and inline Goggles)
- Auth: `X-Subscription-Token` header, plus `Accept: application/json` and
  `Accept-Encoding: gzip`. **Required on every request — there is no keyless
  path.** Brave is not an Exa-style free-tier option; it would belong in
  `PROVIDERS_REQUIRING_KEY`.
- Request: query params `q` (**capped at 400 characters and 50 words**),
  `count` 1–20, `offset` 0–9 (so ~200 results is the ceiling for one query),
  `country`, `search_lang` / `ui_lang`, `freshness`, `result_filter`,
  `safesearch`, `extra_snippets`. There is **no domain parameter**: `site:` and
  `-site:` operators inside `q` are the interface (the `operators` flag defaults
  on), which is what `site_filtered_query` produces — but the folded operators
  count against the 400-character cap. `goggles` is the native re-ranking
  mechanism and is the real answer for domain control. Both domains and geo are
  therefore honourable: an adapter would set no `notice`.
- Response: `web.results[]` with `{title, url, description}`. Dates come as
  `page_age` (ISO-ish timestamp), `age` (display string, e.g. "5 months ago")
  and `page_fetched` (crawl time) — **all three are optional and frequently
  absent**, and Brave's own quickstart shows `age` holding a full timestamp, so
  both fields need defensive parsing. `extra_snippets` is plan-gated.
- Cost: Search plan **$5/1k** requests at 50 req/s (Answers plan $4/1k + $5/1M
  tokens; Spellcheck and Autosuggest $5/10k). Every plan carries $5/month of
  renewing credit ≈ 1,000 requests — **but a credit card is required at signup,
  and the credit is conditional on displaying "POWERED BY BRAVE" attribution**.
  The old Free/Base/Pro/Data tier names no longer exist; figures quoted against
  them anywhere else are stale.
- Env: `SEEKWRIGHT_BRAVE_API_KEY` (were it adopted)
- Gotchas:
  - **Authentication failure is `422`, not `401`/`403`** — a missing token and
    an invalid one both return `422`, so Brave does not fit the shared status
    table above. An adapter would have to read `error.code ==
    "SUBSCRIPTION_TOKEN_INVALID"` out of the body to tell a bad key from a
    malformed request, which is the one place it would diverge from every other
    adapter here.
  - The ToS (updated 2026-02-11) §3(b) forbids storing or caching results beyond
    transient operation — which the no-cache design already satisfies — and
    forbids making the API available to third parties, which is a live question
    for anything fronting more than its own operator. §4(d) requires the
    attribution to be conspicuous.
  - Rate limiting is reported via `X-RateLimit-Limit` / `-Policy` /
    `-Remaining` / `-Reset`, and exceeding it is a `429`.
  - An official MCP server exists (`@brave/brave-search-mcp-server`, maintained
    by Brave) and it also refuses to start without a key, so it is not a keyless
    route in either form.
  - Scraping `search.brave.com` instead is not an option: its `robots.txt`
    disallows `/search` for every user-agent, and the API ToS separately forbids
    circumventing rate limits.
  - Still a genuinely independent index (neither Google nor Bing), which is the
    reason to want it — the price of entry is a card and an attribution line,
    not zero.

### Search1API — moved in-tree 2026-10-16

Adopted from this candidate list; see the in-tree entry above. The search
endpoint is wired as `search1api`; the crawl endpoint is still reference only
(see the extraction table below). The 2026-10-16 re-check record — the Terms
and AUP read where the operator actually hosts them, `blog.s1.dev/pages/…`,
the `www.search1api.com` footer links 404'ing — is in the SERP candidate
re-check section below.

### TinyFish — moved in-tree 2026-09-29

Adopted from this candidate list; see the in-tree entry above.

### SERPdive — dropped 2026-10-19

- **Dropped 2026-10-19: there is no endpoint to call.** `api.serpdive.com` and
  `www.serpdive.com` return NXDOMAIN, and `serpdive.com` answers NOERROR with no
  A and no AAAA record — read at both Cloudflare and Google DNS-over-HTTPS from
  the deployment host at 2026-10-19T21:19:37Z, the same reading as the 2026-10-18 re-check,
  whose Wayback evidence puts the last served content at 2026-09-10. A key
  cannot be obtained from `serpdive.com/dashboard/keys`, and a key could not
  be sent to a name that publishes no addresses. The maintainer confirmed the drop
  on 2026-10-18T20:08:37Z, answering the single question put to it; the
  reopen ask is closed as not executable. Reopen it only with a resolvable
  endpoint and an account key in hand, and re-read the terms and limits at that
  point — every figure below is the 2026-10-16 record, kept because this file
  is a record and not a queue.
- Endpoint: `POST https://api.serpdive.com/v1/search` (JSON; Bearer key from
  `serpdive.com/dashboard/keys` per their docs)
- Models: two retrieval models — **Mako** (fast, ~1k tokens per search,
  1 credit per search) and **Moby** (deep: the full readable source content
  with a cited answer); **Krill** is a free model, unlimited (fair use) on
  every plan (their homepage, 2026-10-16).
- Cost (2026-10-16 re-check, replacing "not gathered on the snapshot date"):
  Researcher free plan — **1,000 API credits/month for Mako & Moby, Krill
  free, "No credit card required"**; PAYG $0.005/credit at launch (list
  $0.007); failed searches are never billed; production rate limit 200
  req/min.
- ToS (effective 2026-07-15): no attribution requirement; the user is
  responsible for the rights in third-party content returned; credits are
  non-transferable; French law, Toulouse courts. Privacy (their own
  policy): queries and results are stored for cache and quality, not
  shared, not sold, not used to train models.
- Provenance: a sole proprietor (Eden d'Alexis, France) — the
  small-operator caveat FreeSerp carries; no SLA.
- Gotchas: `max_results` is a **cap, never a minimum**, clamped to 10 in
  pi-web-access; the engine returns what it returns.
- **Checked against the no-scrape rule: it passes** — the docs' words are
  "one POST request returns clean, answer-ready web content" — a response
  document, not a results page.
- **Verdict (2026-10-16): pass-recommended.** Clears both rules: a
  documented JSON API (no-scrape) and a free tier with no card at signup
  and no mandatory attribution (free-tier-terms check). Evidence grade:
  `serpdive.com` did not resolve from the deployment host on the check date, so the
  operator's own pages were read via the search index that day; the
  adoption issue re-reads them live.

### Querit — moved in-tree 2026-10-17

Adopted from this candidate list; see the in-tree entry above. The search
endpoint is wired as `querit`; the contents endpoint is still reference only
(see the extraction table below). The 2026-10-16 re-check record — the
1,000 calls/month free plan without a payment method, the 1 QPS / 10 results
/ English-only free-plan limits, the $4/1k PAYG tier and the no-attribution
finding in the Services Agreement — is in the SERP candidate re-check
section below.

### Parallel — moved in-tree 2026-10-12

Adopted from this candidate list; see the in-tree entry above. The search
endpoint is wired as `parallel`/`parallel:free`; the extract endpoint is still
reference only (see the extraction table below).

### SearXNG — moved in-tree 2026-09-29

Adopted from this candidate list; see the in-tree entry above.

### AnySearch — moved in-tree 2026-10-16

Adopted from this candidate list; see the in-tree entry above. The search
endpoint is wired as `anysearch` (keyless mode only; the keyed plans are a
separate billing decision, not part of this tree). The 2026-10-16 re-check
record — the ToS v1.1 read in rendered form, the pricing page, and the keyless
live probe — is in the SERP candidate re-check section below.

### SerpAPI — moved in-tree 2026-10-16

Adopted from this candidate list; see the in-tree entry above. The documented
search endpoint is wired as `serpapi` — named `serpapi` rather than the
survey's `serp`, which the in-tree FreeSerp entry already holds. The
2026-10-16 re-check record — the documented endpoint, the key-in-query-string
shape, the 250 searches/month free plan and the no-card and no-attribution
findings — is in the SERP candidate re-check section below.

### OpenAI web search — `answer` (P2)

- Endpoint: `POST https://api.openai.com/v1/responses` (gateway-overridable
  via `openaiResponsesUrl`). Uses the Responses API's web-search tool.
- Cost: works with a Codex subscription's existing auth, or a key.
- Gotchas: pi-web-access only uses it in `auto` mode "when suitable" —
  skipped when a recency filter or non-default result count is requested,
  because the tool's search budget is bound to its token budget.

### FreeSerp — moved in-tree 2026-10-14

Adopted by the 2026-10-14 keyless survey and wired as
`src/seekwright/providers/freeserp.py`; its endpoint, request shape, response,
limits and gotchas are its entry in *In-tree providers* above, which is where a
wired name's facts live. It was the survey's main finding, and its verdict —
tier 1, and the third name of the install default — is recorded in
[free-providers-survey.md](free-providers-survey.md).

### FreeNewsAPI — `serp` over a news corpus (P1, keyless) — added by the 2026-10-14 keyless survey

Snapshot: 2026-10-14, against <https://freenewsapi.ai/docs> and
<https://freenewsapi.ai/docs/rate-limits>, plus a live probe that day.

- Endpoint: `GET https://freenewsapi.ai/v1/search` (siblings: `/v1/stats`,
  `/v1/article`, `/v1/trends`, `/health`).
- Auth: **none** — the docs' words: "There is none. No API key, no bearer
  token, no query parameter, no signup", and the stated reason is that an AI
  agent cannot register for an account, so a key would put a human back in the
  loop. An `X-Agent` header is *requested* for contactability; nothing is
  rejected or throttled without it.
- Request: `q` plus filters by country, language, TLD, host and date;
  multi-value params take a comma-separated list up to 50 items; unknown
  parameters are ignored rather than rejected.
- Response: `{took_ms, total, total_is_lower_bound, size, offset, results[]}`
  with `{id, url, title, description, published_at, crawled_at, host, sitename,
  country, country_source, lang, tld, author, categories, image}`. A **SERP
  backend**; `description` may be null, so `title` is the only always-present
  text. `GET /v1/article` returns one article's full body text by exact URL —
  extraction-shaped, but scoped to their corpus rather than to a caller-named
  arbitrary URL, so it is not a `fetch` backend.
- Corpus: "roughly 100–110 thousand news articles per day, from 25,000+
  publishers in 90+ countries and 50+ languages", in a rolling 30-day window
  (their figures, 2026-10-14). That window is the constraint that matters: this
  is a **news** search, not a web search.
- Documented limits: no quota, no daily cap, no plan to upgrade to — one
  throttle, for fairness between callers: 20 requests/second sustained, burst
  40, 20 concurrent connections, per IP; daily and monthly unlimited;
  **commercial use allowed**; exceeding it returns `429` with nothing banned and
  nothing counted against the caller. Probed live 2026-10-14: HTTP 200,
  `application/json`, no key.
- Free-tier terms: free, keyless, no card, no signup. The operator states that
  free keyless search "stays free: it is the product", and that any future
  change would be optional keys for accounting and higher personal limits,
  announced on the changelog first. A hosted MCP server is offered on the same
  site.
- **Checked against the no-scrape rule: it passes** — a JSON response
  document, not a results page.
- Gotchas: news-only, so it can back a `search` narrowed by `recency` but
  cannot answer a general query; `total` is a lower bound
  (`total_is_lower_bound: true` in the response); the rolling window means an
  older article is gone rather than ranked low. Provenance as above: a small
  operator, no SLA, terms as stated on 2026-10-14.
- **Tier 1.** Same credential argument as FreeSerp.
- **Verdict (2026-10-14): declined.** It clears tier 1 and the no-scrape rule,
  and it is declined for want of a home rather than for its terms or its limits:
  **it is a corpus, not a search engine.** Its index is a rolling 30-day window
  of news, so a query it cannot answer in that window does not rank low — it
  does not exist. A name that cannot answer a general query has no honest home
  in this tree, and by the reading the 2026-10-14 survey's FreeSerp verdict
  takes ([free-providers-survey.md](free-providers-survey.md)), a keyless
  name is a defaultable one, so admitting it would let a general `mode="free"`
  search end on a news corpus with an empty result set that reads as "no
  results" rather than "wrong index". Its `GET /v1/article` is corpus-scoped —
  one article's body by exact URL *inside their index*, not a caller-named
  arbitrary URL — so it is not a `fetch` backend either. The reading holds
  without a record behind it: a name that cannot answer a general query has no
  honest home in a general free walk.

- **Adoption call (2026-10-19): deferred; the decline above stands.**
  The 2026-10-17 re-check in §"FreeNewsAPI revisit (2026-10-17)" below cleared
  both standing rules, so the maintainer was asked to make the call — adopt it
  under a corpus- or news-scoped operation to be specified, defer, or drop. The
  maintainer chose **defer** (2026-10-18T20:11:44Z), because further specialised
  APIs are still to be researched and reviewed. Nothing was implemented: no
  adapter, no wiring point, no dependency, and no implementation issue was
  opened; `freenewsapi` remains in no config set, so the general free
  walk still cannot reach this corpus. The door stays open where this page
  leaves it: if that review round specifies a corpus- or news-scoped operation,
  this survey is what to weigh first, and every figure above is re-read live at
  that point. Until then the decline stands, and nothing in a config set
  reaches the corpus.

### Crawl4AI Cloud — `fetch` (`POST /scrape`) — surveyed 2026-10-22

Snapshot: 2026-10-22, read that day from the deployment host at the vendor's own pages:
`https://crawl4ai.com/llms.txt` (the same body is served at
`api.crawl4ai.com/llms.txt`), `https://api.crawl4ai.com/docs`,
`https://api.crawl4ai.com/legal/` and `GET https://api.crawl4ai.com/v1/prices`.
It is the hosted half of the same vendor as the self-hosted renderer fallback
([`crawl4ai.md`](crawl4ai.md)); the search half (`/search`, `/serp`) is its own
entry, and neither is pre-decided here. No key was obtained and no billable call
was made: the probes were the vendor's own free reads — `GET
/v1/prices` → `200 application/json` with no credential, and `GET /health` →
`200 {"ok":true}` — plus one negative control, `POST /scrape` with no
credential → `401`, empty body.

- **Endpoint.** `POST https://api.crawl4ai.com/scrape` — "Fetch one URL and
  return clean content. The service auto-picks the cheapest engine that works
  (cache → HTTP → browser) per domain; you can ask for a browser with `engine`."
  Request `{"url", "format", "proxy", "country", "parse", "engine"}`; response
  `{"ok":true,"markdown":"…","html":"…","content_hash":"…","ms":312}`. `url` is
  documented as "a public http/https URL"; `format` is `both` (default) | `md`
  | `html`; `engine` is `auto` (default) | `browser-light` | `browser`. "Requests
  and responses are JSON unless noted. Errors return `{"error":"..."}` with an
  HTTP status." Every answer also names the road it took: "`engine` (`cache`,
  `fetch`, `browser-light`, `browser` or `browser-heavy`), `exit` (`isp:<cc>` or
  `residential:<cc>` when a proxy carried it) and `ladder`, the steps tried in
  order, each with its `step` … its `outcome` and its `ms`." No in-tree fallback
  reports that audit trail.
- **Shapes this ladder would not use.** `POST /scrape/batch` (up to 50 URLs,
  streamed NDJSON, "Bills one unit per URL") and `POST /scrape/jobs` (up to
  10,000 URLs in the background; "URLs that never got an answer are refunded at
  the end"). The vendor also ships an MCP server at
  `https://api.crawl4ai.com/mcp`; the rule that took the self-hosted renderer
  into the ladder already rejected pointing this proxy at
  another service's tools, and this survey does not reopen it.
- **Auth.** "Authenticate every request: `Authorization: Bearer sk_live_...`
  (the header `x-api-key: sk_live_...` also works)." The key is free and
  instant: "Get a free key: visit https://api.crawl4ai.com/ and click "Get a
  key" (a 7-day pass key is issued instantly; verify your email for a permanent
  key and the monthly free credit (verifying revokes the pass key and issues a
  new one)". Adopted here the key would be `SEEKWRIGHT_CRAWL4AI_API_KEY`, from
  the environment only ([`provider-contract.md`](provider-contract.md)):
  `config.api_key_env_var` derives the variable name from the segment before the
  `:`, so a `crawl4ai:cloud` fallback would ask for exactly that name — and that is
  not where the self-hosted fallback's credential lives. `fetch.crawl4ai_token` is
  the one credential this tree lets a config file hold, precisely because it
  authenticates an internal service that same file names.
- **Metering.** "Every request costs credits (1 credit = $0.001; a result
  already in our archive costs half; the effort a page needed sets the price
  …)". `GET /v1/prices` needs no key and is machine-readable — the only such
  table any candidate in this file has: `usd_per_credit: 0.001`;
  `base.scrape: 0.50` credits; `levels` — `instant` ×0.5 "already in our
  archive: half price", `light` ×1.0 "a plain fetch", `standard` ×1.0 "the page
  needed more work", `heavy` ×2.0 "a real browser rendered it", `hard` ×4.0 "the
  site fought back; we used our strongest road"; `proxy_mult` — `isp` ×2.0,
  `residential` ×4.0, `browser_heavy` ×4.0. One `fetch`-sized page is therefore
  0.5 credits ≈ **$0.50/1k**, a browser-served page **$1/1k**, the hardest road
  **$2/1k**, before the proxy multipliers. `engine_level` — the map from the
  engine names a response carries to those multipliers — is `{}` on the read
  date, so that mapping exists only as prose ("priced at the engine that serves
  it"). Every response carries `x-c4-cost`, `x-c4-balance` and
  `x-c4-allowance-left`, and "the body's `usage.quota.remaining_before` carries
  the same figure as `credits_month`". `POST /v1/estimate` prices a call *before*
  it runs: "The answer is a range: the fixed part is exact, the level and the
  tokens are a band from real traffic" (`{"min":"0.20","max":"2.00"}`). "The
  balance call trails the per-call `x-c4-balance` header by about a minute:
  receipts reach the ledger in batches. The header is the exact running figure."
  The vendor's own caveat is a field of that table: "Soft launch: the prices and
  the free credit can change while we learn. Credit you bought keeps its value
  and never expires. Read this table before you rely on a number."
- **The refusals, and whether they bill.** In the vendor's words: "A 403
  "blocked" means every step got the site's block page; a 403 "login-wall"
  means the page asks for a login or a payment, which no browser of ours can
  pass; a 502 "no-answer" means the site did not answer, or gave an empty page
  on every road we tried (`no-answer:empty-render`): a retry rarely helps; a 502
  "origin-error:<n>" means the site itself answered an error (its own code is
  in the reason and in `origin_status`; a 4xx the site gives, like a 404, reaches
  you as the site gave it); a 503 "busy" means no browser was free for a
  moment: send the same request again in a few seconds. A 500 is our own fault.
  None of these is charged." Quota refusals are a separate family: `402
  {"error":"no_credit"}`, `402 plan_cap` ("it resets on the 1st; a bigger plan
  lifts it"), `402 spend_cap`, and `402 plan_needed` for a top-up attempt on an
  account with no plan; plan rate limits are `429` with `X-RateLimit-*` headers
  and a body message meant to be shown as it is. The gate's own refusals are
  free: "A request the gate refused itself (a bad URL, a rate limit) costs
  nothing; a 5xx costs nothing."
- **Limits, and the time budget.** Free plan, the vendor's words: "10 a minute,
  2 at a time, 1,000 credits every month". `limits.free` from the same read:
  `requests_per_minute 10`, `requests_per_10s 5`, `concurrent 2`, `keys 3`,
  `allowance_per_month 2500`, beside `credit.monthly: 1000.00`. **The vendor's
  two free figures disagree on the page as read today** — 1,000 in the prose and
  in `credit`, 2,500 in the plan allowance; the `429` example in the docs quotes
  "You still have 1,774 credits", which reads like the 2,500. Paid, from
  `plans[]`: Starter $10 — 10,000 credits, 120 a minute, 10 at a time, extra at
  $1.00/1k; Builder $99 — 125,000 credits, 600, 20, $0.79/1k; Scale $499 —
  750,000, 1,500, 50, $0.67/1k (`usd_year` is the yearly price). Time: "Most
  pages come back in 1 to 2 seconds. A page that needs a real browser usually
  takes 10 to 60 seconds, and the slowest up to 90. Set your client's timeout to
  120 seconds and wait for the answer. A call you cancel early is not charged,
  but you lose the page." That is twice `fetch.crawl4ai_timeout_seconds` (60 s),
  which is the self-hosted fallback's budget and cannot be borrowed.
- **What the vendor keeps, and who answers for the target.** Docs: "What we
  keep: every request's parameters and result summary for 90 days … the pages we
  fetch for you sit in our cache so a repeat is instant. We never sell or share
  what you fetch." Notes: "Caching: repeated URLs are served from a shared
  archive" — a page fetched for one account can be served to another at the
  archive price, which is a fact about a fallback whose URL is model-supplied, not a
  footnote. Privacy policy (effective 2026-09-23): usage records kept "for 13
  months", "service logs for 90 days"; its sharing list names the egress
  networks (`Bright Data`, `Massive`, `IPRoyal`) and, under the search half,
  `Serper`. Terms (CONTEXT4AI PTE LTD, effective 2026-10-15, Singapore law) put
  the target question on the caller: "You represent and warrant that, for every
  request you make, you have the legal right to access, collect, and use the
  data you request, and that your use complies with all applicable laws, the
  target site's terms, and any access directives it publishes (including robots
  directives)"; the Acceptable Use Policy adds "Respect each target site's terms
  and its published access directives (including robots directives)" and forbids
  access to "content behind authentication or paywalls that you are not
  authorized to access". This proxy does not judge a model-supplied URL, so that
  warranty is the operator's to carry — the part of a metered cloud fallback that is
  not a price.
- **Verdict against the two standing rules, both read live 2026-10-22.**
  - The no-scrape rule (documented APIs / response documents only):
    **pass.** A documented request, a JSON response document, a public
    machine-readable price table and an estimate route. Nothing in this route
    parses a page of the vendor's markup.
  - The free-tier-terms rule: **pass, as written.** No card at signup and no
    paid step stands between an operator and a key; the instant key is a 7-day
    pass, and the permanent key and the monthly credit need a verified email;
    nothing in the Terms, the AUP or the privacy policy conditions use on
    attribution; the limits above are the vendor's own pages and table on the
    check date, and that table says its own numbers are soft.
  - Both passes say the door is open, not that the fallback is wanted. It is keyed
    and metered, so it sits in the class this page already keeps out of the free
    walk: "a metered allowance (`scrappa`, `tavily`, `algolia`) is a price with
    a delay on it".
- **Adoption call: open, and it is the maintainer's.** Two questions
  stand in front of it: whether this project wants a metered third-party
  `fetch` fallback at all, and who holds the key, since keys come from the
  environment only. The four questions the issue asked, measured against this
  tree, are answered above — two passes, one open number. Nothing was
  implemented: no adapter, no config key, no `fetch.fallback` name.

### Crawl4AI Cloud — `GET /search` and `GET /serp` (keyed, metered) — surveyed 2026-10-22, not adopted

This entry is the search half, split from the original cloud question. The same
vendor's `POST /scrape` half is the entry above; [`crawl4ai.md`](crawl4ai.md)
§"The vendor's hosted API is a different question" is where the two entries are
told apart, and the self-hosted `crawl4ai` renderer fallback is a third thing
again — same project, no search endpoint. Everything below was read from the
vendor's own pages on **2026-10-22** (`crawl4ai.com/llms.txt`,
`crawl4ai.com/legal`, and `GET /v1/prices` and `GET /health` probed keyless from
the deployment host). **No Crawl4AI key exists in this deployment**, so no
response document was ever fetched: every shape below is documented, not
live-verified, and the measured lines say which they are.

- **Vendor and endpoints.** Crawl4AI Cloud at `https://api.crawl4ai.com`
  (CONTEXT4AI PTE LTD), "served from three regions (EU, Singapore, US) … routed
  to the nearest one". `GET /search` — "Browser-free, multi-engine, results
  ranked and cleaned"; `GET /serp` — "Google's results page as structured data:
  true ranks, every block Google showed, and the place the page was localised
  to. Built for rank tracking and SEO tools. Not the same as /search, which is
  Crawl4AI's own web search for reading results" (beta, "added 8 Oct 2026");
  `GET /answer` — "direct answer (experimental)". One key and one meter for all
  of it, and an MCP server at `/mcp` is offered in the same breath.
- **Auth.** "Authenticate every request: `Authorization: Bearer sk_live_...`
  (the header `x-api-key: sk_live_...` also works)." **Measured 2026-10-22 from
  the deployment host:** `GET /search?q=…` and `GET /serp?q=…` with no credential →
  **`401`, empty body**; `GET /v1/prices` → `200 application/json`; `GET /health`
  → `200 {"ok":true}`. There is no keyless path, so adoption puts the name in
  `config.PROVIDERS_REQUIRING_KEY`.
- **Key grant.** "Get a free key: visit https://api.crawl4ai.com/ and click
  "Get a key" (a 7-day pass key is issued instantly; verify your email for a
  permanent key and the monthly free credit (verifying revokes the pass key and
  issues a new one)". Email verification, not a card, is the gate on the
  permanent key.
- **Metering.** `GET /v1/prices` read keyless 2026-10-22: `usd_per_credit
  0.001`, `base.search 1.00`, `base.serp 1.00`, `base.answer 1.00` credits —
  **`/search` is $1.00/1k declared**. `/serp` bills per page, not per call: "1
  credit per Google page fetched live; a page from our cache costs half. `num=100`
  is up to 10 credits. A failed answer (a 5xx) costs nothing" — $1.00/1k at
  `num=10`, to $10/1k at `num=100`. `flat[]` lists `search` and `answer` beside
  `monitor` and `price`; the field is not defined in prose, and `levels[]`
  ("instant … already in our archive: half price" ×0.5 up to "hard" ×4.0) and
  `proxy_mult` are documented for pages, so an adoption has to ask the vendor
  which of those move a search price. Credits are reported per call in
  `x-c4-cost` / `x-c4-balance` / `x-c4-allowance-left` and in
  `usage.quota.remaining_before.credits_month` — enough for `usage.credits` and a
  correct `cost_per_1k` without guessing.
- **Error shape fits the house table with no divergence.** Over the rate limit:
  `429` with `X-RateLimit-*` and a showable `message` ("You reached the free
  plan's limit: 10 requests a minute. You still have 1,774 credits; the free plan
  only limits the pace."). Out of credit: `402 {"error":"no_credit"}`; over the
  month's allowance: `402 plan_cap`; over the account's own monthly cap: `402
  spend_cap`. That is the `402 / 429` = quota row above, the same fallback `serper`
  was widened onto (2026-10-20) — unlike Brave, which answers a bad key with
  `422`.
- **Free tier — the vendor's own figures disagree, and a keyed test cannot settle
  it blind.** The page header says "Free: 10 a minute, 2 at a time, 1,000 credits
  every month" and `credit.monthly` is `1000.00`, while
  `limits.free.allowance_per_month` is **`2500`** and the vendor's own `429`
  example quotes 1,774 credits left. `limits.free` also carries
  `search_per_minute: 20` beside `requests_per_minute: 10`, `requests_per_10s: 5`
  and `concurrent: 2`, and `credit.guest` is `20.00`. The table's own `note`:
  "Soft launch: the prices and the free credit can change while we learn. … Read
  this table before you rely on a number." Ask which figure is the grant before a
  live test spends it.
- **Request shape against `search`'s nine arguments**
  ([`surface.md`](surface.md)):
  - `/search` takes `q` (**max 512 chars**) and `rich` (`0|1`) **only** — "best
    for question-style queries", adding a `rich` block of
    `follow_up_questions[]`, `related_queries[]`, `entity`, `videos[]`,
    `news[]`, `discussions[]`, `did_you_mean`. There is **no result-count,
    recency, language, safe-search or domain field**: domains fold into `q` as
    `site:` / `-site:` operators through `site_filtered_query` (which counts as
    honouring domains, so no notice in `SerperProvider.search`), and `recency`, `language`
    and `safe_search` are **dropped and noticed** through
    `base.ignored_constraints`. Three of the four buckets a SERP adapter must
    answer land in the notice; `max_results` becomes a client-side cap over
    whatever arrives.
  - `/serp` takes `q` (max 512), `country` (2 letters, default `us`),
    `language` (Google code, default `en`), `location` ("a city or region …
    Unknown → 400 with the 3 closest names"), `num` ("any multiple of 10 up to
    100 … `num/10` Google pages are fetched at once"), `page` (1..30), `time`
    (`hour|day|week|month|year`) and `fresh` (skip the cache). That maps the same
    `hl` / `tbs` / `num` shape `serper` and `serpapi` already map, so it honours
    `language`, `recency` and `max_results` natively, drops only `safe_search`
    into the notice, and offers a `location` half this tool surface has no
    argument for. `empty_reason` names two failure kinds the adapter would have
    to read: `google_no_results` ("Google's own no-results page") and
    `rescue_no_results` ("Google refused the query to us and our fallback had
    nothing: another provider may still have results, fall back on this one
    only") — an upstream refusal arriving as an empty 200, which is the class
    this tree treats as found-nothing, not as an error.
  - Result fields map with no work: `/search` returns `{title, url, snippet,
    source}` per hit; `/serp` returns `position`, `position_absolute`, `title`,
    `url`, `domain`, `displayed_url`, `snippet`, optional `date` and
    `sitelinks[]`, plus `blocks[]`, `total_results` (Google's own estimate) and
    `pages {asked, got, missing[]}`, `cached`, `age_s`. A SERP backend fills
    `snippet`, never `text`.
- **`source: index` is not the novelty the split assumed.** The vendor: "`source`
  is `gg` or `gs` for a live web result, `index` for a result from the Crawl4AI
  index: added after the live results when the web returns fewer than 10, or
  served alone when the live search fails. Same price either way." `freeserp`
  already answers from its own crawl index and already substitutes one index for
  another when an upstream is unavailable ("read `index` in the response rather
  than assume the web index replied", above), so the tree has met this shape. The
  difference is granularity — here the corpus marker rides on **each result**
  while the price stays flat — and the consequence is the same one already
  recorded for `freeserp`: an archived page is only as current as its crawl, and
  Terms §7 says so ("we do not warrant that any target will be reachable, that
  results will be complete or accurate").
- **What it overlaps, priced against the rows above.** The live half of `/search`
  is not the vendor's own: the Privacy Policy (effective 2026-09-23) lists the
  vendors it shares requests with — "…**Serper** (web search results), and our
  network providers Bright Data, Massive and IPRoyal". So `/search` is a metered
  front on the upstream of an in-tree name at the **same declared price**:
  `serper` is $1.00/1k (config default, `factory._PROVIDERS`), and Crawl4AI is
  $1.00/1k (`base.search` × $0.001). It is dearer than `search1api` ($0.76),
  `deepseek` ($0.75), `algolia` ($0.50) and `scrappa` ($0.30); cheaper than
  `querit` ($4) and `tavily` ($8); level with `serper`. `/serp`'s block detail
  overlaps `serper` and `serpapi` in the opposite direction: those entries drop
  "the ~10 other element families (knowledge panels, people-also-ask, …)" and
  "`search_metadata`, `answer_box` and the other element families" **on purpose**,
  and `SearchResponse` carries no field for a block. An adapter for `/serp` would
  buy 16 block families and `position_absolute` and then throw all of it away;
  its use case is rank tracking ("Built for rank tracking and SEO tools"), which
  is not an operation this project specifies.
- **`/answer` is declined, not parked.** The 2026-10-16 re-check in §"SERP
  candidate re-check (2026-10-16)" put answer-kind candidates out of scope for
  `search` — "Answer-kind candidates (Gemini, Perplexity Sonar, OpenAI web
  search) are out of scope — they are not SERP (search) options". `answer` is
  also already this project's own operation: agent mode is "one model call over
  material the server retrieved" which "writes prose the server grounds by
  validating its citations against what it actually retrieved"
  ([`agent-mode.md`](agent-mode.md), which carries the grounding rule). The
  vendor's endpoint is the inverse: `answer.source` is
  `google_ai_overview` or `google_ai_mode` — "the web's own direct answer, word
  for word" — or `crawl4ai`, "our model wrote it from the pages", and `q` takes
  "the question, or a whole prompt (max 4,000 chars)" with a `schema` the answer
  must match. Adopting it would drop a third party's answer text into the slot
  this tree reserves for grounded prose, and it is metered three ways in one
  vendor: `base.answer 1.00`, `llm_flat_mc.answer 2000` (2 credits), and "1
  credit for an answer found directly; 3 credits when our model wrote it".
- **Terms, in the vendor's own words (read 2026-10-22, `crawl4ai.com/legal`;
  Terms effective 2026-10-15, Privacy 2026-09-23, AUP 2026-08-06).**
  - **No attribution condition anywhere** — no "powered by", no credit back.
    Terms §6: "As between you and us, you keep whatever rights you already have
    in the data you retrieve — subject to the rights of the third parties it
    belongs to." Contrast Brave §4(d) and Marginalia's CC-BY-NC-SA above.
  - **No storage or republication prohibition** (contrast Brave §3(b)). The
    vendor caches on its own side: "Caching: repeated URLs are served from a
    shared archive", `/serp` carries `fresh` to skip it, and §"Notes" states
    "Provenance: every response tells you which engine served it and whether it
    came from cache."
  - **One clause a proxy has to read**: AUP §3 forbids using the Services to
    "Resell, sublicense, or repackage the Services except as these Terms allow",
    and Terms §6 grants "a limited, non-exclusive, non-transferable right to use
    the Services". Running the name as one backend for its own operator is inside
    that; offering this vendor's results onward to third parties is what the
    clause names.
  - **The target-data warrant sits on the caller.** Terms §4: "You represent and
    warrant that, for every request you make, you have the legal right to access,
    collect, and use the data you request, and that your use complies with all
    applicable laws, the target site's terms, and any access directives it
    publishes (including robots directives)" — AUP §2 repeats it and adds "Use
    reasonable request volumes and not place an undue burden on any target." For
    `/serp` the fetched page is Google's, fetched by the vendor on this proxy's
    instruction, and §4 puts the warrant on whoever sends the instruction.
    §7 disclaims everything else: "The Services are provided "as is" and "as
    available" … we do not warrant … that results will be complete or accurate."
- **Standing rule 1 (the no-scrape rule, stated in §"Ruled out: results-page
  parsers" above): passes — and `/serp` is the
  candidate that looks like a results page and is not one.** `/serp` returns
  Google's results page — as *data*, read by the vendor on instruction: the
  adapter receives `results[]`, `blocks[]`, `pages`, `cached`, `total_results`.
  The rule asks what the adapter receives ("a response document, or a results
  *page* it parses"), and that reading is what keeps `serper` (a SERP API over
  Google) and `scrappa` ("a paid SERP API that scrapes Google on its own side",
  which is the same distinction) in the tree, and what kept `searxng` in. Nothing in
  seekwright would parse a page, so §"Ruled out" stays a rejection and this
  candidate does not belong in it.
- **Standing rule 2 (the free-tier-terms check): passes on terms, open on the
  number.** No card at signup (instant pass key; the permanent key costs an email
  verification), no attribution clause that blocks use, and limits and terms read
  off the vendor's own pages on the check date — but the free grant itself is
  stated two ways 1,000 / 2,500 and the vendor says the free credit can change
  during the soft launch.
- **Tier: 3.** Keyed and metered, so beside `scrappa` and `serper` in
  `PROVIDERS_REQUIRING_KEY` — never the `mode="free"` walk (`FREE_PROVIDERS`
  excludes anything that can bill) and never the install default
  (`KEYLESS_PROVIDERS` = `exa:free`, `parallel:free`, `freeserp`).
- **Verdict (2026-10-22): not adopted; the adoption call is the maintainer's.** No
  adapter, no provider name, no config key — `crawl4ai` appears in no provider
  set (`KNOWN_PROVIDERS`, `PROVIDERS_REQUIRING_KEY`, `FREE_PROVIDERS`), and the
  only `crawl4ai` in `src/` is the self-hosted renderer's `fetch.crawl4ai_url` /
  `crawl4ai_token` / `crawl4ai_timeout_seconds` (`FetchConfig`), which is
  a LAN endpoint, not this vendor. The reading this pack puts in front of that
  call: **decline `/answer`**; **do not adopt `/search`** — it displaces no name
  and would sit keyed-and-unused the way `linkup` and `algolia` already do;
  **park `/serp`** behind an operation that would read `blocks[]` or
  `position_absolute`; **ask the maintainer** for the key (nothing here can be
  live-verified without it, and an unverified name enters `UNTESTED_PROVIDERS`)
  and whether a search name whose `index` half is a third party's crawl belongs
  in a proxy whose `search` citations the server validates. Every figure here is
  dated 2026-10-22 and is re-read live at adoption, as this file requires. What
  is set out above is this page's reading, not an adoption: nothing here enters
  a provider set until the maintainer calls it.

## Keyless coverage survey (2026-10-14)

**Adoption verdicts (2026-10-14).** The survey below is the *finding*; the calls
it fed are those stated on this page, and they are all
taken, so nothing below is still open. **FreeSerp is adopted** — a provider in
the tree, a member of `config.FREE_PROVIDERS`, and the third name of the install
default. **FreeNewsAPI is declined** — a rolling news corpus cannot back a
general `search`, and its corpus-scoped `/v1/article` is not a `fetch` backend
either; its adoption call went to the maintainer and was **deferred on
2026-10-19**, so the decline stands and no implementation issue was opened.
**Jina Reader is adopted as the second fallback** of the `fetch` ladder,
though deliberately *not* named in the shipped `fetch.fallback`, which stays
empty. Each entry below carries its own verdict line; this note is the summary.

What follows is the record of a survey that is **finished**. It answers the
maintainer's coverage question — "i wonder if we are missing out a bit on free
options at the moment" — and it is a *finding*, not a queue: the only rows that
can produce an issue are the two entries directly above and Jina Reader in the
extraction table below. Every other row closes a question.

**Tier 1 is the maintainer's own words: no account, no key, no card, plus a real
contract (a documented API).** Anything that needs a card at signup is out even
when nominally free; a metered allowance can bill, so it is tier 2/3 however
generous; a keyed option whose call is free at any balance is tier 2, not tier 1
(`tinyfish`). A **self-hosted** option is free but not zero-setup, so it is not
tier 1 — `searxng` is already the tree's instance of that shape, and this survey
proposes no more of them.

**Method, and the evidence grade.** Every candidate was read upstream — the
operator's own docs or pricing page — on **2026-10-14**, and every keyless
endpoint was additionally probed with a bare `GET` on that date; the row names
what was read. A fact not confirmed upstream is labelled **unverified** in
place rather than filled in with a plausible guess. Terms are recorded as
*stated by the operator*, which is not the same as contracted: none of these
small operators publishes an SLA.

**The headline.** The keyless-with-a-contract space on the search side is not
empty, which is the one thing this survey changed. The tree's two keyless names
were the rate-limited anonymous halves of *paid* endpoints (`exa:free`,
`parallel:free`); the survey found two further keyless names backed by an index
of the operator's own — FreeSerp (whole web) and FreeNewsAPI (a 30-day news
corpus) — and both pass the no-scrape rule because the adapter receives a
response document. Everything else keyless that turned up is either
single-corpus (Hacker News, StackExchange, Wikipedia), a crawl index rather
than a search engine (Common Crawl), an instant-answer endpoint rather than
results (DuckDuckGo's), media-only (Openverse), key-gated (Marginalia, Mojeek,
Google, s.jina.ai), card-gated (Brave), closed to new customers and sunsetting
(Google's), or retired (Bing's). On the `fetch` side, Jina Reader is confirmed
keyless and is the one extraction addition; its own search endpoint is not.

### Surveyed and not tier 1, or tier 1 but not adoptable

| Candidate | Endpoint (all read/probed 2026-10-14) | Auth | Documented limits & free-tier terms | Tier → verdict |
|---|---|---|---|---|
| **Marginalia** | `GET https://api2.marginalia-search.com/search` (`about.marginalia-search.com/article/api`) | `API-Key` header on every request; a documented shared `public` key for experimentation | free non-commercial key by email (no card), licensed **CC-BY-NC-SA 4.0** — attribution *and* non-commercial; commercial use needs a metered key. Probes: no header → `400 Missing API-Key header`; `public` → `429 QPM Limit Exceeded` | 2 — not tier 1 (a key header is a key, and the shared one was rate-limited out at probe time) |
| **DuckDuckGo Instant Answer** | `GET https://api.duckduckgo.com/?q=…&format=json` | none | no rate limits read; the docs page (`duckduckgo.com/api`) redirected to a search behind a bot challenge on 2026-10-14, so **the published contract is unverified** | 1 by criteria — **not adoptable**: it returns an abstract, `Heading`, `Answer` and `RelatedTopics`, not ranked web results. It cannot back `search` |
| **Openverse** | `GET https://api.openverse.org/v1/images/` | none (anonymous fallback) | keyless probe returned `x-ratelimit-limit-anon_burst: 20/min`; the docs page was not read in this survey, so **the published limits are unverified** | 1 by criteria — **not adoptable**: a media corpus (images/audio), not web search |
| **Hacker News (Algolia)** | `GET https://hn.algolia.com/api/v1/search` | none | keyless probe 200; published limits not read (**unverified**) | 1 by criteria — **not adoptable**: one corpus (HN), not web search |
| **StackExchange** | `GET https://api.stackexchange.com/2.3/search` | none (anonymous quota) | keyless probe 200; the anonymous quota was not read (**unverified**) | 1 by criteria — **not adoptable**: one corpus |
| **Wikipedia (MediaWiki action API)** | `GET https://en.wikipedia.org/w/api.php?action=query&list=search` | none | keyless probe 200; limits not read (**unverified**) | 1 by criteria — **not adoptable**: one corpus |
| **Common Crawl index** | `GET https://index.commoncrawl.org/collinfo.json`, then `…/CC-MAIN-<crawl>-index` | none | keyless probe 200 | 1 by criteria — **not adoptable**: a crawl index with no relevance ranking. It answers "what was crawled", not "what is relevant" |
| **Brave Search API** | `GET https://api.search.brave.com/res/v1/web/search` | `X-Subscription-Token` | $5/1k; $5/month renewing credit ≈ 1,000 requests — **a card at signup and a mandatory "POWERED BY BRAVE" attribution**. See the fuller entry in §"Adoption candidates" | 3 (paid tier with a credit) — **not tier 1**: the card test case the maintainer named |
| **Google Custom Search JSON API** | `GET https://www.googleapis.com/customsearch/v1` (`developers.google.com/custom-search/v1/overview`) | API key **plus** a configured Programmable Search Engine | 100 queries/day free, then $5/1k — and the page now says the API is **closed to new customers**, with existing customers transitioned off by **2027-01-01**. Keyless probe → `403 … unregistered callers` | 3, sunsetting — **not adoptable** |
| **Mojeek Search API** | `GET https://api.mojeek.com/search?api_key=…&fmt=json` (quickstart read 2026-10-14) | **account + `api_key`** — "An active account and API key" | paid plans only: Startup £2 CPM, Business £3 CPM, Enterprise by contact; no free tier published. See also its HTML search route (bot-walled) in the rejection section below | 3 — **not tier 1** |
| **Bing Web Search API** | — | — | Microsoft's own page, read 2026-10-14: "Public Bing Search and Bing Custom Search APIs were retired on 11th August 2025." | n/a — **no API route exists** |
| **Jina Search** (`s.jina.ai`) | `GET https://s.jina.ai/?q=…` | API key | keyless probe → `401 AuthenticationRequiredError`; free-tier terms not read (**unverified**) | 2/3 — **not tier 1**. Distinct from Jina *Reader*, which is keyless |
| **Microlink** | `GET https://api.microlink.io/?url=…` (`microlink.io/docs/api/basics/rate-limit`) | none on the anonymous endpoint; `x-api-key` against `pro.microlink.io` | anonymous "free" endpoint: **soft limit 25 reqs/day** — `microlink.io/docs/api/basics/rate-limit`, read 2026-10-14: *"It has a soft limitation of 25 reqs"*, `429` on exceed; `microlink.io/pricing`, read the same day, gives the free plan as *"25 requests per day / ~1.5K req/month"*, *"No card needed"* | 1 by criteria — **unverified, not adopted**: the anonymous response is link metadata (title, description, lang, publisher), **not page text**, and whether its Text/Markdown products are reachable on the anonymous fallback was not confirmed. Do not adopt on this evidence |
| **Wayback Machine** | `GET https://archive.org/wayback/available?url=…` | none | keyless probe 200 | 1 by criteria — **not adopted**: an archive lookup, not an extraction endpoint; what it returns is a pointer to the archived copy, whose body is the original HTML |

## SERP candidate re-check (2026-10-16)

Re-check of every undetermined SERP candidate still under "Adoption
candidates", against the two standing rules: the no-scrape rule
(documented APIs / response documents only) and the free-tier-terms check
(no card at signup, no mandatory attribution that blocks use, documented
limits/ToS verified against the provider's own docs on the check date).
Answer-kind candidates (Gemini, Perplexity Sonar, OpenAI web search) are out
of scope — they are not SERP (search) options. Each candidate entry above
carries its own verdict line; this table is the summary, not a second
source.

**No new rejections.** Every candidate re-checked today clears both rules,
so the rejection section below is untouched: nothing moved into it, and the
two lists — adoptable API candidates versus parsing-required rejections —
stay physically separate. SerpAPI, a stock public SERP option that was not
in this file before, was surveyed on this pass and added with its own entry
above.

| Candidate | Endpoint (read/probed 2026-10-16) | Auth | Free-tier terms (provider's own docs, 2026-10-16) | Verdict |
|---|---|---|---|---|
| **Search1API** | `POST https://api.search1api.com/search` | API key | 100 free credits; "No credit card required" (their own homepage); no attribution clause in the Terms or the AUP (pages live at `blog.s1.dev/pages/…` — the www.search1api.com links 404) | **pass-recommended** (keyed, metered free tier) |
| **Querit** | `POST https://api.querit.ai/v1/search` (+ `/v1/contents`) | API key | 1,000 free calls/month; "without linking a payment method" (their own FAQ); free plan 1 QPS / 10 results / English only; no attribution clause in the Services Agreement | **pass-recommended** (keyed, metered free tier) |
| **AnySearch** | `POST https://api.anysearch.com/v1/search` | **none in keyless mode** (live probe: HTTP 200 JSON, no credentials) | free quota 1,000 requests/day (pricing page; ToS §5.1.1 "as stated at the time of registration"); no card, no attribution (ToS v1.1); commercial use allowed except reselling the API / directly competing products | **pass-recommended** (keyless: no account, no key, no card, documented API — tier 1) |
| **SerpAPI** | `GET https://serpapi.com/search?api_key=…` | `api_key` **in the query string** (their documented shape) | 250 searches/month, $0, 50/hour; "no credit card required" (their own pricing page + blog); no attribution requirement | **pass-recommended** (keyed, metered free tier) |

Evidence notes:

- **SERPdive**: `serpdive.com` did not resolve from the deployment host on the check
  date (DNS), so the operator's own pages were read via the search index
  that day; the facts above come from the operator's own homepage, ToS and
  privacy policy as indexed. Re-verify against the live site at adoption
  time.
- **AnySearch**: ToS v1.1 (published 2026-04-24, effective 2026-05-01,
  updated 2026-06-02) was read in rendered form — the legal page loads its
  body client-side — and the keyless probe was one read-only call under
  their own terms.
- **Search1API**: the Terms and AUP were read where the operator actually
  hosts them, `blog.s1.dev/pages/terms` and
  `blog.s1.dev/pages/acceptable-use` (the `www.search1api.com` footer links
  404).

## FreeNewsAPI revisit (2026-10-17)

Re-check of the one candidate the free-providers survey (2026-10-17) flagged
for a revisit before any adoption call (follow-up 3), against the two standing
rules: the no-scrape rule (documented APIs / response documents
only) and the free-tier-terms check (no card at signup, no mandatory attribution
that blocks use, documented limits/ToS verified against the provider's own docs
on the check date). Everything below was re-verified live from the deployment host on
the check date — bare requests, no credentials, nothing that can bill.

| Candidate | Endpoint (probed 2026-10-17) | Auth | Free-tier terms (provider's own docs, 2026-10-17) | Verdict |
|---|---|---|---|---|

Evidence notes:

- **Probes** (2026-10-17, the deployment host, no credentials, one request each):
  `GET https://freenewsapi.ai/health` → `200 {"status":"ok","documents":39943951}`;
  `GET https://freenewsapi.ai/v1/search?q=climate+news` → `200`,
  `content-type: application/json`, 20 results, `total_is_lower_bound: true`.
- **No-scrape rule**: the adapter receives a JSON response document, not a
  results page — re-verified live on the check date, the same reading as
  2026-10-14.
- **Attribution, stated precisely**: the Terms' "You should / Link back" (the
  original `url` when showing an article to a person) and "You may not / … strip
  attribution" are publisher-credit rules about article content, not a
  "powered by" condition on API use — nothing in the terms blocks or conditions
  use on attribution. The clause exists; the check says what it does and does
  not block.
- **New contract fact**: every JSON response carries a constant
  `strongly_recommended` field — pointers to other services (two keyless or
  free, two paid; the field says the cost), "not part of your result set"
  (`freenewsapi.ai/docs`, read 2026-10-17). Not in the 2026-10-14 survey's
  response record; the operator's compatibility policy is additive-only under
  `/v1` (changelog, read 2026-10-17), so an adapter must ignore unknown fields.
- **Verdict scope**: pass means the two standing rules clear; it does not
  re-open the 2026-10-14 decline — that stands on want of a home, not on
terms. No code, no wiring point, no adoption with this entry; the follow-up was
**deferred** by the maintainer on 2026-10-18T20:11:44Z and is parked, so this entry
stays the first to revisit if a corpus- or news-scoped operation is ever
specified. The decline stands on want of a home, not on terms.

## Ruled out: results-page parsers (the no-scrape rule)

**This section is a rejection, not a backlog.** Every entry below fails one
rule: what the adapter receives decides, and a *results page* the adapter
parses makes seekwright the scraper, which is the scrape. Nothing here will be
implemented — **no adapter, no
wiring point, no live test, no dependency, no card.** If you are looking for
work to pick up, it is not here — the section above and §"Adoption candidates"
are where candidates live. This catalogue exists so the next reader, or the next
agent, does not re-propose the same dead end; a library that parses a results
page inside our process (the `ddgs` family) is the same scrape with a dependency
in front of it, and is ruled out with them.

| Candidate | Endpoint (probed 2026-10-14) | What parsing it would need | The rule that rules it out |
|---|---|---|---|
| **duckduckgo** — *removed from the tree* | `https://html.duckduckgo.com/html/?q=…` → 200 HTML | Walk `div.web-result` blocks out of DDG's results page; no API and no contract. DDG's own `robots.txt` disallows `/html` and `/lite`. Removed 2026-10-13 with its adapter, six wiring points, live test, docs entry and `lxml` dependency | 2026-10-13 — a results page, not a response document. Not grandfathered |
| **startpage** | `https://www.startpage.com/sp/search?query=…` → 200 HTML, but an **Anubis proof-of-work challenge** (`anubis_version v1.26.4`), not results | Parse a results page that is not even served to a scripted client; `robots.txt` disallows `/sp/` | 2026-10-13 — results page, and bot-walled at that |
| **ecosia** | `https://www.ecosia.org/search?q=…` → **403 "Ecosia Firewall"** | Parse a results page; `robots.txt` disallows `/search` | 2026-10-13 — results page, and refused at the door |
| **google** | `https://www.google.com/search?q=…` → 200 HTML, JS-and-consent shaped | Parse Google's results page; `robots.txt` disallows `/search`. The API route is Google's Custom Search JSON API, which is keyed, closed to new customers and sunsetting (survey table above) | 2026-10-13 — results page |
| **mojeek** | `https://www.mojeek.com/search?q=…` → **bot-walled**: 200 HTML carrying `<title>Captcha</title>` to a scripted client, and 403 *"your network appears to be sending automated queries"* to a real browser from this network | Parse a results page that is not served to a scripted client at all; `robots.txt` disallows `/search`. **Not a pure parser**, though: Mojeek also publishes a Web Search API — which is account- and key-gated and paid, so it is tier 3 (survey table above). Neither route is tier 1 | 2026-10-13 — the page is a results page; the API is keyed |
| **bing** | `https://www.bing.com/search?q=…` | Parse a results page. This is the *only* route left: Microsoft retired the public Bing Search and Bing Custom Search APIs on 2025-08-11 (their own page, read 2026-10-14) | 2026-10-13 — results page, and the API that would have avoided it no longer exists |

## Extraction endpoints (for `fetch`)
The content-tier fallbacks, alongside the extraction ladder. Four are in the tree as
ladder fallbacks: Jina (`JinaFetcher`), Scrappa (`ScrappaFetcher`), and, since
2026-10-24, Tavily Extract (`TavilyFetcher`) and Linkup Fetch (`LinkupFetcher`). The
rest are reference. The self-hosted `crawl4ai` fallback is not a row here — it dials
your own deployment; see [crawl4ai.md](crawl4ai.md).

**No keyed live call has been run for either keyed fallback yet**: this deployment holds
neither `SEEKWRIGHT_TAVILY_API_KEY` nor `SEEKWRIGHT_LINKUP_API_KEY`, so
`tests/live/test_live.py` carries the two `live`-marked calls. Every price below is a
vendor-page reading with its date, not a measured bill.

| Service | Call | Notes |
|---|---|---|
| **Jina Reader** | `GET https://r.jina.ai/<url>`, `Accept: text/markdown`, `X-No-Cache: true` | Free, no key — **verified live 2026-10-14**: HTTP 200 with no credential, and the response carries `x-ratelimit-limit: 20, 20;w=60` with `x-ratelimit-remaining: 19` on that first call (20 requests per 60 s per IP). The body is `text/plain` carrying `Title:` / `URL Source:` / `Published Time:` / `Warning:` lines before the `Markdown Content:` prefix to strip; reject <100 chars or `Loading...` / `Please enable JavaScript` starts. The two `Warning:` lines observed were a not-fully-loaded notice and a cached-snapshot notice, so a caller must treat the cache as the default unless it opts out. Its sibling `s.jina.ai` (search) is **not** keyless — `401 AuthenticationRequiredError` (probed 2026-10-14). **Verdict (2026-10-14): adopted as a fallback** — `jina` is the second fallback of the `fetch` ladder in the tree (`JinaFetcher`), and it is deliberately *not* named in the shipped `fetch.fallback`, which stays empty, because a fetch target is caller-named and `FetchResponse` names no fallback. |
| **Scrappa** | `GET https://scrappa.co/api/web-scraper?url=…&javascript=1` | The `fetch` fallback. Renders JS, which is the failure class `HttpFetcher` cannot cover. 1 credit; see the Scrappa entry above. |
| **Firecrawl** | self-hosted base URL, `/v2/scrape` (or `/v1`) | Cache-only by default (`lockdown`); fresh scraping is an explicit opt-in because the Firecrawl server performs its own egress. |
| **TinyFish Fetch** | `POST https://api.fetch.tinyfish.ai` | Hosted fetch fallback. |
| **Search1API crawl** | `POST https://api.search1api.com/crawl` | Hosted fetch fallback. |
| **Querit contents** | `POST https://api.querit.ai/v1/contents` | Hosted fetch fallback. |
| **Tavily Extract** | `POST https://api.tavily.com/extract` | The keyed fallback on the credential `[providers.tavily]` already holds: in, `urls` (up to 20; the fallback sends one), `format` (`markdown`/`text`), `extract_depth` (`basic`/`advanced`), `timeout` (1-60 s), `include_usage`; out, `results[].raw_content` and `failed_results[]`. Two traps the fallback refuses to pass through — an HTTP 200 can carry an empty `results` array when every URL failed, and **billing counts successful extractions, not calls**: 1 credit per 5 at `basic`, 2 per 5 at `advanced` (extract page read 2026-10-23), ~$1.60 and ~$3.20 per 1k at the $8/1k credit rate, so the 1,000-credit allowance buys about 200 basic extractions, not 1,000. `TavilyFetcher` pins `basic` and declares `cost_per_1k = 1.60`. |
| **Linkup Fetch** | `POST https://api.linkup.so/v1/fetch` | The keyed fallback on the credential `[providers.linkup]` already holds, and the fallback that renders JavaScript. In: `url`, `renderJs`, `extractImages`, `includeRawHtml`, `includeRawContent`, `mode`, `schema`, `instructions`; out: `markdown`, `contentType`, `favicon`, `images[]`, optional typed `data`. The vendor's pricing page (read 2026-10-24) bills Fetch per call off a `mode` × `renderJs` table — `standard`/`false` `$0.001`, `standard`/`true` `$0.005`, `pro`/`false` `$0.005`, `pro`/`true` `$0.01`, and a flat `$0.001` more for a `schema` — and puts it at "<2s / Synchronous", 4,000 queries free with no card, SOC 2 Type II on every plan, ZDR Enterprise-only; so `LinkupFetcher` declares `cost_per_1k = 5.00`, the price of the cell it sends: `mode: standard`, `renderJs: true`, no `schema`. It sends the three body-flag fields `false` and drops `images[]`: the image question is the ladder's, not this fallback's. |
| **Parallel extract** | `POST https://api.parallel.ai/v1/extract` | Hosted fetch fallback. |
| **Gemini URL Context / Gemini Web** | Gemini API + browser cookies | The URL-context API is a Gemini capability; Gemini Web is browser-cookie access and is a deliberate non-transfer. |
## Fetch endpoints among the in-tree providers (2026-10-23)
This section asks the half of the question this page has mostly answered for `search`:
of the provider names this tree already calls, which could serve `fetch` as well. The
population is the seventeen names of `config.KNOWN_PROVIDERS` read on 2026-10-23, asked
name by name rather than vendor by vendor -- the reason a fallback and a search adapter
for one vendor are cheaper together than apart is that the fallback reuses the
credential that name already carries and joins the permission set that name is already
in.

Method, so the codes below can be read rather than guessed at: one keyless `POST` of an
empty JSON body per candidate endpoint from the deployment host on 2026-10-23, no key
sent, no billed call. A second pass on 2026-10-24 covers the four names the first pass
left resting on documents, at the same budget: at most one keyless request per name, an
empty JSON `POST` body, or a `url` query parameter where the vendor's documented API is
`GET`-shaped. This page's own status-code table is the interpreter. A `400` means the
request reached request-validation, so a route is there; a `401` or `403` answered
before any field of the body is read proves only that something keyed sits behind that
path, so there the vendor's reference page is what closes the shape, and it is cited as
read. `402` is this page's quota fallback.

| In-tree name | Candidate endpoint | Keyless read (2026-10-23; the four names probed in the 2026-10-24 pass carry their own date) | What that settles |
|---|---|---|---|
| `linkup` | `POST https://api.linkup.so/v1/fetch` | `400 {"error":{"code":"VALIDATION_ERROR","details":[{"field":"url","message":"Invalid input: expected string, received undefined"}]}}`; then with `Authorization: Bearer pk_test_invalid` and a `url` set, `401 {"error":{"code":"UNAUTHORIZED"}}` | Route real, keyed, request field `url`. Contract read from the vendor reference page: `url`, `renderJs`, `extractImages`, `includeRawHtml`, `includeRawContent`, `mode`, `schema`, `instructions` in; `markdown`, `contentType`, `favicon`, `images[]`, optional typed `data`, and the raw bodies out. `mode` has two values, read from the vendor on 2026-10-24 at `docs.linkup.so/pages/documentation/endpoints/fetch/overview` and `.../fetch/best-practices`: `standard`, the default and the more cost-effective, and `pro`, which "delivers significantly higher success rates on hard-to-retrieve pages" at a higher per-call cost; that page also records that `mode` and `renderJs` are independent choices. |
| `tavily` | `POST https://api.tavily.com/extract` | `401 {"detail":{"error":"Unauthorized: missing or invalid API key."}}` | Keyed. Documented shape: `urls`, `query`, `chunks_per_source` (1-5, only with `query`), `extract_depth` (`basic`/`advanced`), `format` (`markdown`/`text`), `timeout` (1-60 s), `include_usage`. Two traps for a fallback: an HTTP 200 can carry an empty `results` array when every URL failed, and billing counts successes, not calls. `POST /crawl` also answers `401`: a crawl endpoint exists and is not extraction of a caller-named URL. |
| `parallel` | `POST https://api.parallel.ai/v1/extract` | `401`; `POST /v0/extract` also `401` | Keyed, and the wall answers ahead of routing, so the probe cannot tell a live path from a dead one -- the `/v1` form is the documented one, and the `v0` probe is a negative control that this vendor's auth runs first. |
| `querit` | `POST https://api.querit.ai/v1/contents` | `401` | Keyed. The shape stays as the entry above records it; reference until someone builds the fallback. |
| `deepseek` | `POST https://api.deepseek.com/v1/tools/fetch` | `401` | Keyed. Its search adapter already dials `/v1/tools/search` on the same host, so a fallback adds no host and no secret. Its fetch price is read from the vendor on 2026-10-24 at `api-docs.deepseek.com/guides/search/`: `$0.75` per 1,000 successful requests, billed per request and only where HTTP 200 produced page content, at a 25 QPS Fetch limit; the same page's error table puts `402` at an insufficient account balance and `403` at a Fetch request rejected by security policy. |
| `tinyfish` | `POST https://api.fetch.tinyfish.ai` | `401` | Keyed, and a second host for one vendor: the search adapter dials `api.search.tinyfish.ai`. Two hosts, two lines in the rendered egress lists. |
| `search1api` | `POST https://api.search1api.com/crawl` | `402` | Quota answers before validation, which is the same wall the search adapter behind that key is behind. Shape read 2026-10-24 from the vendor's own published schema, `api.search1api.com/openapi.json` (`POST /crawl`, "Crawl a URL and extract its content"): the body is one object or an array of objects with `url` required (uri, at least one character) and `enableFallback` optional and default `true` (`enable_fallback` accepted as an alias), `additionalProperties: false`; the response is `{crawlParameters: {url}, results: {title, link, content, metadata}}`, and a batch response holds only the URLs that succeeded, in no guaranteed order, failed ones omitted and not charged -- 1 credit per request. `402` is a documented error row of that path, which is what the keyless call above answers. |
| `serper` | `POST https://google.serper.dev/scratchpad` | `403` | The auth wall, and nothing behind it read here. The route is named from the vendor's marketing pages and stays **unverified** for want of a reference page: re-read 2026-10-24, `serper.dev` -- the vendor's only public API page -- names no `/scratchpad`, the plausible docs path `serper.dev/api-for-search` answers 404 at that read, and a web search for a Serper page naming the route returns third-party code and no vendor document. |
| `serpapi` | `GET https://serpapi.com/search.json?engine=url_request&url=...` | `401`; `GET https://serpapi.com/search/url` `404` | Its URL fetch is an `engine` parameter on the path the in-tree adapter already dials, not a path of its own -- the guessed path answers 404. |
| `exa`, `exa:free` | `POST https://api.exa.ai/contents` | `402 {"error":"Payment required to access this resource","tag":"X402_PAYMENT_REQUIRED","x402Version":2,...}` | Exa answers a keyless call at `/contents` by asking for x402 payment, so the keyed REST route is not the only way in. Nothing in this tree dials `api.exa.ai`: the `exa` names go through `mcp.exa.ai/mcp`, which is a different egress fact and a different contract. |
| `searxng` | the instance this deployment configures -- `searxng` has no fixed host to dial, its `url` is operator config, and `tools/egress_lists.py` counts it as one of the two config-derived names (with `algolia`) | **2026-10-24: no request sent, because this host configures no instance.** `deploy/compose/search.toml` and `deploy/compose/fetch.toml` carry no `[providers.searxng]` section, no config on this host supplies a `url`, and `Config._validate_providers` makes the config `url` a startup precondition for an enabled name: "provider 'searxng' is enabled but no url is configured; it has no public default" | The ask for this name was to probe the instance this deployment configures; the read is that it configures none, so no SearXNG extraction route is settled here -- and that is a named blockage, not a return to a document reading. Substituting a public instance is closed by the standing rule the entry above records (volunteer-hosted, their limiters 429 scripted JSON, probed 2026-10-02), so this row closes only on a host that runs one |
| `algolia` | `POST https://crawler.algolia.com/api/1/crawlers/probe/test` -- the only URL-named route in the vendor's own API surface; the in-tree name's Search API host is `{app_id}-dsn.algolia.net`, and no `app_id` is configured on this host, so that host cannot be dialled from here at all | `401`, body the literal word `Unauthorized` (probed 2026-10-24T13:25:14Z, empty JSON body, no credential) | A keyed wall answering ahead of routing, which proves nothing about the route: there the vendor reference closes the shape, and it is cited as read. The Crawler REST API page (base `https://crawler.algolia.com/api`; `Authorization: Basic <user-id>:<api-key>`; "The Crawler credentials are different from your regular Algolia credentials"; read 2026-10-24) and the vendor's own OpenAPI spec for that API (`algolia/api-clients-automation`, `specs/crawler`: `POST /1/crawlers/{id}/test`, "Test crawl a URL ... shows the extracted records", request field `url` required; `POST /1/crawlers/{id}/urls/crawl` hands URLs to a crawl) give the shape. That is a second product, on a second host, behind a second credential pair, and it needs a crawler id -- not the `algolia` name's Search API, so not a same-name fallback |
| `freeserp` | `GET https://freeserp.ai/api.php?url=...&content=1` -- the vendor documents one endpoint, `api.php` (also `/api`), and `content=1` is its page-text switch | `200`, `application/json` (probed 2026-10-24T13:27:09Z): `{"ok":true,"index":"sites","query":"","total":17811216,"count":1,"from":0,"size":1,"sort":"relevance","order":"desc","filters":{"real_site":"1"},...}` -- one record, `domain":"google.com"`, and neither the echo nor the record names the URL that was asked for | The candidate route is the search endpoint, and it does not honour a caller-named URL: the `filters` echo carries only `real_site`, `query` is empty, and the hit returned is the top of their index rather than the page requested. The page text this endpoint can return is `content` of a page already in the vendor's own index, selected by query or filter. No caller-named URL-to-content route -- which is the docs' own line, "Bad params do not error — unknown filters are ignored and an invalid `sort` falls back to `relevance`." |
| `anysearch` | `POST https://api.anysearch.com/v1/extract` | `400 {"code":-1,"message":"URL is invalid.","request_id":"94c63d63-057a-4148-a9c5-2e8854297525","error_code":"invalid_extract_url"}` (probed 2026-10-24T13:24:00Z, empty JSON body, no `Authorization` sent). Two calls with a real `url` and still no `Authorization` answer `200` -- read twice, once at 2026-10-24T17:50Z-17:53Z and once from the checkout writing this row at 2026-10-24T18:03:49Z and 2026-10-24T18:04:05Z; `Content-Type: application/json`, no credential of any kind sent, nothing billed. First, body `{"url":"https://example.com/"}`: `200 {"code":0,"message":"success","request_id":"57bae256-3d75-4028-99ce-3381564fac8d","data":{"url":"https://example.com/","title":"Example Domain","content":"This domain is for use in documentation examples without needing permission. This is not a service; avoid relying on it for testing and monitoring purposes."}}` -- `data.content` is 156 characters, and a direct `GET https://example.com/` taken in the same minute (`200`, 577 bytes) returns that sentence character for character as the page's own prose, together with `<title>Example Domain</title>` and one inline `<style>` block that the vendor's read drops. Second, body `{"url":"https://httpbin.org/html"}`: `200 {"code":0,"message":"success","request_id":"4b549e57-ad85-45c1-9a38-aa6e0eef5547","data":{"url":"https://httpbin.org/html","title":"","content":"# Herman Melville - Moby-Dick\n\n..."}}` -- `data.content` is 3,597 characters beginning `# Herman Melville - Moby-Dick`, and `data.title` is the empty string; a direct `GET https://httpbin.org/html` in the same minute (`200`, 3,741 bytes) returns an `<h1>` reading `Herman Melville - Moby-Dick` and carries no `<title>` element, which is why the title came back empty. | **A real caller-named URL-to-content endpoint, and it serves a keyless call.** `400` answers at request-validation, so the route is there and the wall does not sit ahead of routing on this path. The vendor's page `anysearch.com/docs/api-endpoints/v1-extract` (read 2026-10-24, re-read 2026-10-24T18:05:25Z) reads "Fetches and extracts clean content from a public HTTP or HTTPS URL": the body is "exactly one object containing one non-empty string `url`", valid UTF-8, at most 16 KiB, no unknown or duplicate fields; the response is `data.{url,title,content}`, and that page describes `title` as "Extracted page title, or an empty string when unavailable" and `content` as "Cleaned HTML, plain text, JSON, or Markdown". `anysearch.com/docs/auth` (read 2026-10-24, re-read 2026-10-24T18:05:24Z) puts `/v1/*` under the mode "Anonymous", whose header format is "No Authorization header" and whose quota policy is "Rate-limited per client IP and metered against the daily free quota", so keyless use of this path is not ruled out. **What the two `200` reads settle:** the path serves a keyless call -- no `Authorization` header, no credential of any kind, and page text back rather than a wall, a placeholder or an echo, since the 156-character `content` is the prose of `example.com` itself; `data.title` carries no guarantee, being the empty string when the page has no `<title>`, which is the case that page documents; and a multi-kilobyte page comes back as one extracted body (3,597 characters, markdown-shaped), not a clipped lead paragraph. **What it leaves open on this name is price only** -- and the two quota readings are not one figure, so they are kept apart here: `anysearch.com/docs/auth` meters an anonymous call against "the daily free quota" without naming any price for `/v1/extract`, while the `1,000 requests/day` of the `## Cost and free-tier summary` table is the search quota read from `anysearch.com/pricing` (re-read 2026-10-24T18:05:23Z: the free plan is "$ 0 /mo" and lists "Structured Outputs", "1,000 requests/day" and "20 QPS rate limit per key", "Professional Search Pro" is "Coming Soon" and Enterprise is "Contact Sales", so that page names no paid price at all). No vendor page read here names a price for `/v1/extract`, so the extract price is recorded as unread; `anysearch.com/docs/pricing` answers `404` (2026-10-24T16:52Z, and again at 2026-10-24T18:05:23Z). Whether an extract call draws on the same daily quota as a search call is not stated on the pages read here, and the endpoint's own error table only names the walls: `402` "Quota exhausted." and `429` "API-key, user, or anonymous-IP rate limit exceeded." The finding is recorded in the row; this card builds no fallback from it and opens no value-set move: both are one pull request of their own |
One name stays out of that table: `scrappa` is already the ladder's paid fallback
(`ScrappaFetcher`), so there is nothing to scout.

**The 2026-10-24 pass, and what it changed.** `searxng`, `algolia`, `freeserp` and
`anysearch` were the four names of this section whose case rested on documents this tree
already held rather than on a request; they are rows above now, each with its date and
the literal status it answered, and the sentence that used to excuse them is gone. Three
reached a vendor. The fourth names what blocked it: no SearXNG instance is configured on
this deployment, and the standing no-public-instances rule closes the substitute, so
that row stays open until somebody probes their own instance. Two readings came out flat
-- `algolia` answers a keyless call at a `401` wall in front of the Crawler's URL-test
route, a different product behind its own credential pair, and `freeserp` ignores a
caller-named `url` because its one documented endpoint is a search over its own index.
One came out a finding: `anysearch` has `POST /v1/extract`, a caller-named
URL-to-content endpoint the tree does not use, and the two keyless `200` reads added to
that row settle more than that a route is there: it answers without a credential and
returns the page's own text, so only price stays open on the name. It is recorded in the
row, and nothing is built from it here -- a new fallback name and a value-set move are
one pull request: the code, `tools/value_sets.json`, the re-printed `surface.md`
and this page move together.

**Price as of 2026-10-23, and what it says about the ladder.** Linkup's own pricing page
reads `$0.001 - $0.006` per request for "URL content extraction", "<2s / Synchronous",
with "Run 4,000 queries for free", SOC 2 Type II on every plan and ZDR on Enterprise.
Tavily's extract page reads basic extraction at 1 credit per **5 successful** URL
extractions and advanced at 2 per 5, which at the $8/1k PAYG rate of the entry above is
~$1.60 and ~$3.20 per 1k -- so the 1,000-credit monthly allowance buys about 200 basic
extractions, not 1,000. Against Scrappa's ~$0.20-0.30 per 1k, the row above the ladder
already carries, both are 3x to 30x the price per page. Neither is interesting on price;
what they buy is a JS-rendered read and a markdown-first answer, the two failure classes
`docs/reference/fetch-safety.md` records for `HttpFetcher` and the reason the `crawl4ai`
fallback exists.

**What this section supersedes.** The rows of the section above this one that name a
host in one line with no reading -- TinyFish, Search1API, Querit, Parallel -- are that
page's older pass over the same endpoints. Read here for the 2026-10-23 reading; the
older rows stay written as they were written.

**Where the work went.** The work is split by piece: the freeze exception both a new
fallback and a new extraction backend need, then the backend with no library of its own,
the fallback registry, per-fallback pricing, the two keyed fallbacks, and the egress
hole in the rendered egress lists. `images[]` in the Linkup response is the field in
question; whoever builds that fallback should not answer the image question twice.

## Cost and free-tier summary
One row per name this tree can call: fifteen backends, seventeen names, because
`exa`/`exa:free` and `parallel`/`parallel:free` share a row. Names studied and not wired
are not rows here — their figures live on their own entry under [Adoption
candidates](#adoption-candidates-from-the-pi-web-access-comparison).

Per 1k queries unless noted, an "as of" estimate rather than contract. **A row is only
as fresh as the entry it summarizes**, so the date travels with the row: the `As of`
column names that entry's date.

| Provider | Kind | Cost per 1k | Free tier | As of |
|---|---|---|---|---|
| **Scrappa** | serp+fetch | ~$0.20–0.30 | **500 credits/month** | 2026-08-14 |
| Serper | serp | ~$1 | — | 2026-08-01 |
| Linkup | answer | ~$6 | — | 2026-08-01 |
| Exa MCP | content | ~$7 keyed (`exa`) | **rate-limited, keyless (`exa:free`)** | 2026-08-14 |
| **Parallel** | content | ~$1 keyed (`parallel`, `turbo`/`fast`); $5 (`basic`/`advanced`) | **rate-limited, keyless (`parallel:free`)** | 2026-10-12 |
| **SearXNG** | serp | — | **free (self-hosted)** | 2026-10-02 |
| **Tavily** | content+answer | $8 PAYG / $5–7.5 plans | **1,000 credits/month** | 2026-10-02 |
| **TinyFish** | serp | — | **free at any balance (keyed, rate-limited)** | 2026-09-29 |
| **Algolia** | serp | $0.50/1k after the 10k/mo included (Grow) | **10K search requests/month (keyed — registration always required)** | 2026-10-12 |
| **Search1API** | serp | $0.49–0.76/1k (plans; Basic ≈ $0.76 is the config default) | **100 credits, no card** | 2026-10-16 |
| **Querit** | serp | $4/1k PAYG (`cost_per_1k` defaults to 0.0, the free plan) | **1,000 calls/month, no card** | 2026-10-16 |
| AnySearch | serp | — (paid plans per pricing page) | **1,000 requests/day, keyless (no account, no key, no card)** | 2026-10-16 |
| **SerpAPI** | serp | — (paid plans per pricing page; `cost_per_1k` defaults to 0.0, the free plan) | **250 searches/month, no card** | 2026-10-16 |
| **DeepSeek** | serp (+ `summary` in `text`) | **$0.75/1k successful requests** (billed per request, not per result; a 200 with no results is not billed) | **none** — prepaid balance, `402` when it is gone | 2026-10-21 |
| **FreeSerp** | serp | — | **free, keyless (no account, no key, no card)** | 2026-10-14 |
Nothing in the code consults this table to pick a provider. The routes that pick without
the caller naming a backend are `search(mode="free")` and an unnamed `search` with no
default configured where every enabled name is free; they are one walk, over
`config.FREE_PROVIDERS` only — `exa:free`, `parallel:free`, `freeserp`, `searxng`,
`tinyfish`. The **Free tier** column is deliberately *not* that set: a metered allowance
(`scrappa`, `tavily`, `algolia`) is a price with a delay on it, so those three can bill
and the free-only mode excludes them. Otherwise the choice is the operator's, made in
config; there is no cache.

Every price above is what a provider *charges*. What a deployment *spent* — per
provider, over the last 14 days, beside p50/p95 latency — is reported by `seekwright
--metrics`, `GET /dashboard/metrics` and the dashboard's endpoint panel; the figures and
window are in [metrics.md](metrics.md). Its `$/1k` is spend per terminal call, `cost_usd
/ calls * 1000` (`UsageRecorder._citation_rows`'s docstring), with `calls` counting
every terminal call, failures included, and a terminal failure recorded at `cost_usd =
0.0` (`UsageRecorder._apply_search`, `SearchEngine._record_failure`). So it reads
`declared × (billed calls / all terminal calls)`: a row below the table above is a
failure rate before it is a repricing — check `errors` against `calls` before reading it
as a price cut.

## Updating this document
- **Adding a provider**: write the endpoint, request/response shapes, cost, env
var and gotchas here in the same mini-schema before wiring it up, so the code review
checks the doc against the code.

- **Pricing drift**: re-check the provider marketing page when a `cost_per_1k`
default looks stale, and update both the adapter's own default (in its `__init__`, where
`factory._cost` falls back to it) and this table.
