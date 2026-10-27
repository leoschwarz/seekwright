# Keyless and free-no-account coverage survey

Survey date: 2026-10-17. This document answers the ROADMAP §9 coverage question —
whether the tree is leaving free coverage on the table — as a survey, not an
implementation. It consolidates and updates the survey material already in the
tree:

- `reference/providers.md`, "Keyless coverage survey (2026-10-14)" and "SERP
  candidate re-check (2026-10-16)";
- `reference/providers.md` again, for the two standing rules — the no-scrape
  rule and the free-tier-terms check — and for each verdict this survey's
  adopt rows restate (FreeSerp, FreeNewsAPI, Jina Reader, the keyless default).

**No code, no config, and no default changes with this document.** The adopt
verdicts below restate calls the tree already made, each beside the page that
holds it; the watch rows are recommendations. This survey adopts
nothing, and nothing in it is queued work except the follow-ups named at the
end, which are recorded as separate issues.

## The tier 1 test

Tier 1 is the maintainer's wording: **no account, no key, no card, plus a real
contract — a documented API with documented limits** (ROADMAP §9; the 2026-10-14
survey in `reference/providers.md`). The readings it carries, unchanged:

- a metered allowance can bill, so it is tier 2/3 however generous;
- a keyed option whose call is free at any balance is tier 2, not tier 1
  (`tinyfish`);
- a self-hosted option is free but not zero-setup, so it is not tier 1 —
  `searxng` is the tree's instance of that shape, and this survey proposes no
  more of them;
- a candidate that needs a card at signup is out even when nominally free.

The second filter is the 2026-10-13 no-scrape rule: what the adapter *receives*
decides. A response document passes; a results *page* the adapter parses makes
seekwright the scraper. A candidate that passes the tier 1 test but fails this
rule is rejected, not queued — the rejection section below says so.

`fetch` is explicitly outside the no-scrape rule: it retrieves one caller-named
URL, it is not a search. A keyless *extraction* endpoint is therefore a
legitimate tier 1 candidate on the fetch side, and the fetch side gets its own
short section; the tables above the line cover the search side.

## Method and evidence grade

- Every third-party claim below carries a dated source: a page read on the
  stated date, or a read-only probe made on the stated date.
- Every keyless endpoint was re-probed from the deployment host on **2026-10-17** — one
  bare request each, no credentials, no key, and nothing that can bill.
- Keyed endpoints were **not called** — there are no keys, and there must be no
  spend. They are judged against their documented contracts, and each row says
  so.
- A fact not confirmed upstream is labelled **unverified** in place rather than
  filled in with a plausible guess.
- Terms are recorded as *stated by the operator*, which is not the same as
  contracted: none of these small operators publishes an SLA.

## Tier 1 — no account, no key, no card, documented contract

### FreeSerp — **adopt** (in the tree since 2026-10-14)

- Endpoint: `GET https://freeserp.ai/api.php?index=web` (query params), plus a
  hosted MCP server `https://freeserp.ai/mcp` (probed 2026-10-17: a plain `GET`
  returns the live tool catalog).
- Auth: **none** — `freeserp.ai/docs.php`, read 2026-10-17, in the operator's
  words: "What we will never ask for: no key, no token, no account. If a page
  on this site ever asks you to register to make a request, it is not this
  site."
- Documented limits: "No hard limit and no key — the service is free and open.
  Please be reasonable (a few requests/second), cache when you can, and
  identify yourself so we can reach you before a change…" (same page, read
  2026-10-17); responses edge-cached ~30 s; `from + size ≤ 100` per query; the
  `total` field is the size of a top-100 candidate pool, not a hit count
  (their caveat, in the response's `total_note`).
- Free-tier terms: no account, no key, no card; self-identification
  (`agent`/`email`/`website` params or `X-Agent` header) is requested and "stored
  privately next to request counts; never published, never shared" (same page,
  read 2026-10-17). No attribution requirement is stated.
- Probe 2026-10-17: HTTP 200, JSON, real results, no credentials.
- Verdict: **adopt**. In the tree as `providers/freeserp.py`, a member of
  `config.FREE_PROVIDERS` and the install default, because a name with no
  credential is a defaultable one. It is the first keyless name backed by an
  index of the operator's own crawl — 3.1B+ pages, the operator's figure
  (`freeserp.ai/web-search-api`, read 2026-10-17) — rather than the anonymous
  half of a paid endpoint. Provenance, stated plainly: a small operator, no SLA,
  terms *stated* not contracted.

### AnySearch — **adopt** (in the tree since 2026-10-16, explicit-only)

- Endpoint: `POST https://api.anysearch.com/v1/search` (JSON).
- Auth: **none in keyless mode** — the in-tree adapter implements the keyless
  mode only and never sends an `Authorization` header; keyed plans exist against
  the same endpoint and are a separate billing decision, not part of this tree
  (`reference/providers.md`, 2026-10-16).
- Documented limits: the free plan on `anysearch.com/pricing`, read 2026-10-17:
  **1,000 requests/day**; the same page's wording for the free plan's rate
  limit is "20 QPS rate limit per key". The anonymous response observed on
  2026-10-17 carried `x-ratelimit-limit: 10` — the response header, not the
  marketing figure, is what a caller actually sees.
- Free-tier terms: no account, no key, no card; ToS v1.1 (published 2026-04-24,
  effective 2026-05-01, updated 2026-06-02) §5.1.1 states the quota "as stated
  at the time of registration" (read in rendered form 2026-10-16, per the
  in-tree record); commercial use is allowed except reselling the API and
  directly competing products (same record).
- Probe 2026-10-17: HTTP 200, business `code: 0`, real results, no credentials.
- Verdict: **adopt**. In the tree as `providers/anysearch.py`, keyless mode
  only, **explicit-only**: not the keyless install default, not `FREE_PROVIDER_
  ORDER` — reachable only by naming it (`reference/providers.md`, 2026-10-16).
  Status: implemented, untested in-repo — the live test is keyless and free,
  and follow-up 1 below names it.

### Exa (`exa:free`) — **adopt** (in the tree since 2026-08-14)

- Endpoint: `https://mcp.exa.ai/mcp` — a streamable-HTTP MCP server, tool
  `web_search_exa`.
- Auth: **none on the anonymous tier**. A keyed session is a different name
  (`exa`) and bills the account normally — the credential decides the price,
  which is why the two names exist.
- Documented limits: the anonymous tier is free and rate-limited
  (`reference/providers.md`, 2026-08-14, verified live against the endpoint
  that day). The exhaustion message is **not characterised**: 12 consecutive
  keyless searches succeeded without tripping it, and the in-tree detector
  sniffs for `rate`/`quota`/`429` — escalation triggers on any provider error,
  not on that classification.
- Free-tier terms: never billed — `cost_usd` is always `0.0`; there is no
  credential in the environment for a call to spend.
- Probe 2026-10-17: MCP handshake 200, `serverInfo`, no credentials. Handshakes
  are free (verified 2026-08-14), so this probe spent nothing.
- Verdict: **adopt**. In the tree as `providers/exa_mcp.py` under the name
  `exa:free`, a member of the install default. One of the two keyless names
  that are the rate-limited, weaker anonymous halves of *paid* endpoints — the
  tool descriptions say so.

### Parallel (`parallel:free`) — **adopt** (in the tree since 2026-10-12)

- Endpoint: `https://search.parallel.ai/mcp` — the hosted Search MCP server,
  tool `web_search`.
- Auth: **none**. The keyed REST endpoint (`api.parallel.ai/v1/search`, name
  `parallel`) bills per request by `mode`; the anonymous MCP does not.
- Documented limits: anonymous MCP is **$0** (`docs.parallel.ai`, read
  2026-10-12, per the in-tree record); the anonymous request honours **no**
  filter — connection-level overrides are ignored for anonymous requests — so
  every constraint rides `notice`; excerpts are server-side capped at ~25k
  characters (the anonymous fallback runs `fast`).
- Probe 2026-10-17: MCP handshake 200, `serverInfo`, no credentials.
- Verdict: **adopt**. In the tree as `providers/parallel.py` under the name
  `parallel:free`, a member of the install default; the keyed `parallel` REST
  is a separate billing decision.

### Jina Reader (fetch side) — **adopt** (in the tree since 2026-10-14, as a fetch fallback)

- Endpoint: `GET https://r.jina.ai/<url>`, `Accept: text/markdown`,
  `X-No-Cache: true` to opt out of the cache.
- Auth: **none**.
- Documented limits: the response carries `x-ratelimit-limit: 20, 20;w=60` —
  20 requests per 60 s per IP (response header, probed 2026-10-17; identical
  on the 2026-10-14 probe).
- Free-tier terms: free, keyless, no card. The body is `text/plain` carrying
  `Title:` / `URL Source:` / `Published Time:` / `Warning:` lines before the
  `Markdown Content:` prefix; the cache is the default unless you opt out.
- Verdict: **adopt** — the second fallback of the `fetch` ladder, deliberately
  *not* named in the shipped `fetch.fallback`, which stays empty: a fetch target
  is caller-named and `FetchResponse` names no fallback, so shipping it by
  default would hand caller-named URLs to a third party with no channel to see
  it. The no-scrape rule does not reach `fetch` — that is the rule's own scope,
  not a reading of it. Its sibling `s.jina.ai` (search) is **not** keyless: probe
  2026-10-17 returned `401 AuthenticationRequiredError` (the 2026-10-14 probe
  the same) — so Jina contributes exactly one tier 1 fallback, on the fetch side.

## Tier 1 but not adoptable — passes the test, cannot back `search`

Each row passes the tier 1 test (keyless, a response document — the no-scrape
rule is not the reason) and is rejected for what it is. The rejection is the
survey's finding; nothing here is queued.

| Candidate | Endpoint (probed 2026-10-17 unless noted) | Auth | Documented limits (dated) | Why it cannot back `search` — verdict |
|---|---|---|---|---|
| **FreeNewsAPI** | `GET https://freenewsapi.ai/v1/search` — 200, real articles | none — `freenewsapi.ai/docs`, read 2026-10-17: "There is none. No API key, no bearer token, no query parameter, no signup" | no quota or plan; one throttle — 20 req/s sustained per IP, burst 40, 20 concurrent, daily and monthly unlimited, commercial use allowed, `429` on exceed, nothing banned or counted (`freenewsapi.ai/docs/rate-limits`, read 2026-10-17) | **reject** — the tree's standing rule. A corpus, not a search engine: the index is a rolling 30-day window of ~100–110k news articles a day from 25,000+ publishers (`freenewsapi.ai/docs`, read 2026-10-17), so a query it cannot answer in that window does not rank low — it does not exist. The operator states keyless search "stays free: it is the product" (rate-limits page, read 2026-10-17). Its corpus-scoped `GET /v1/article` is not a `fetch` backend either. The door is named in the entry: revisit first if a corpus- or news-scoped operation is ever specified. Re-checked 2026-10-17: both standing rules pass, no drift in terms or limits — the dated verdict is in `reference/providers.md`, §"FreeNewsAPI revisit (2026-10-17)"; the adoption call is the maintainer's. |
| **DuckDuckGo Instant Answer** | `GET https://api.duckduckgo.com/?q=…&format=json` — 200, empty `Abstract`/`Answer` for a general query | none | the published contract is **unverified** — the docs page redirected to a search behind a bot challenge (read 2026-10-14, in-tree record) | **reject** — an instant-answer endpoint: an abstract, `Answer`, `Heading` and `RelatedTopics`, not ranked web results. It cannot back `search`. |
| **Openverse** | `GET https://api.openverse.org/v1/images/` — 200 | none (anonymous fallback) | response headers, probed 2026-10-17: `x-ratelimit-limit-anon_burst: 20/min`, `x-ratelimit-limit-anon_sustained: 200/day` | **reject** — a media corpus (images/audio), not web search. |
| **Hacker News (Algolia)** | `GET https://hn.algolia.com/api/v1/search` — 200 | none | published limits **unverified** (2026-10-14, in-tree record) | **reject** — one corpus (HN), not web search. |
| **StackExchange** | `GET https://api.stackexchange.com/2.3/search` — 400: `search` requires `tagged` or `intitle` | none (anonymous quota) | published limits **unverified** (2026-10-14, in-tree record) | **reject** — one corpus. |
| **Wikipedia (MediaWiki action API)** | `GET https://en.wikipedia.org/w/api.php?action=query&list=search` — 200 | none | limits **unverified** (2026-10-14, in-tree record) | **reject** — one corpus. |
| **Common Crawl index** | `GET https://index.commoncrawl.org/collinfo.json` — 200 | none | — | **reject** — a crawl index with no relevance ranking: it answers "what was crawled", not "what is relevant". |

## Fails the tier 1 test — keyed, card-gated, or no longer offered

These are not tier 1. Each row states the test it fails; the dated source is
the operator's own page or a probe on the stated date. Keyed endpoints were
judged against their documented contracts, not called (no keys, no spend).

| Candidate | Endpoint | Auth | What fails the test (dated) | Verdict |
|---|---|---|---|---|
| **Brave Search API** | `GET https://api.search.brave.com/res/v1/web/search` | `X-Subscription-Token` on every request — there is no keyless path | a **card at signup** and a mandatory "POWERED BY BRAVE" attribution; the $5/month renewing credit ≈ 1,000 requests is conditional on the attribution (ToS updated 2026-02-11; `reference/providers.md`, 2026-08-14) | **reject** — the card test case the maintainer named. Tier 3. |
| **Mojeek Search API** | `GET https://api.mojeek.com/search?api_key=…&fmt=json` | **account + `api_key`** — "An active account and API key" (quickstart, read 2026-10-14) | paid plans only (Startup £2 CPM, Business £3 CPM, Enterprise by contact); no free tier published (2026-10-14, in-tree record). Its HTML search route is bot-walled — a rejection in the section below | **reject** — tier 3. |
| **Google Custom Search JSON API** | `GET https://www.googleapis.com/customsearch/v1` | API key **plus** a configured Programmable Search Engine | 100 queries/day free, then $5/1k — and Google's page now says the API is **closed to new customers**, with existing customers transitioned off by **2027-01-01** (read 2026-10-14); keyless probe → `403 … unregistered callers` (2026-10-14) | **reject** — keyed and sunsetting. |
| **Bing Web Search API** | — | — | Microsoft's own page, read 2026-10-14: "Public Bing Search and Bing Custom Search APIs were retired on 11th August 2025." | **reject** — no API route exists. |
| **Jina Search** (`s.jina.ai`) | `GET https://s.jina.ai/?q=…` | API key | probe 2026-10-17: `401 AuthenticationRequiredError` (also 2026-10-14) | **reject** — key-gated. A distinct product from the keyless Reader above. |
| **Marginalia** | `GET https://api2.marginalia-search.com/search` | `API-Key` header on every request; a documented shared `public` key — probe 2026-10-17 without header: `400 Missing API-Key header`; the `public` key was `429 QPM Limit Exceeded` (2026-10-14) | the free key is issued by email (no card), and the license is **CC-BY-NC-SA 4.0** — attribution *and* non-commercial (2026-10-14, in-tree record) | **reject** for tier 1 — a key header is a key, and the license blocks commercial use. |
| **SearXNG** | `GET {url}/search` on the operator's own instance | none — it is the operator's own instance | free on the operator's hardware; the JSON format must be enabled in the instance's `settings.yml` (`reference/providers.md`, 2026-10-02). Public instances are a non-option, deliberately: volunteer-hosted, 429-ing scripted JSON traffic (probed 2026-10-02) | **reject** as a tier 1 candidate — free but not zero-setup; the tree's standing shape of this class is the operator-hosted `searxng` (in the tree since 2026-09-29), and this survey proposes no more of them. |

## Keyed free tiers that fail the "no key" test (tier 2)

These fail the no-key test, so they are outside the tier 1 question. The 2026-10-16
SERP re-check (`reference/providers.md`) ran them against the free-tier-terms
check — no card at signup, no mandatory attribution, documented limits and ToS
verified against the provider's own docs on the check date — and all four clear
it. Operator reachability was re-checked 2026-10-17: `serpapi.com`, `s1.dev`
(`search1api.com` redirects there) and `querit.ai` resolve; `serpdive.com` still
does not resolve from the deployment host, which matches the 2026-10-16 record.

| Candidate | In the tree | Free-tier terms (2026-10-16 re-check) | Re-check verdict |
|---|---|---|---|
| **SerpAPI** | yes — `serpapi` | 250 searches/month at $0, 50/hour, only successful searches count, "no credit card required" (pricing page + blog); no attribution requirement; `api_key` rides the query string, their documented shape | **pass-recommended** (implemented 2026-10-16, untested in-repo) |
| **Search1API** | yes | 100 free credits at signup, "No credit card required"; no attribution clause in the Terms or AUP (read where the operator actually hosts them, `blog.s1.dev/pages/…`) | **pass-recommended** (implemented 2026-10-16, untested in-repo) |
| **SERPdive** | no | free plan: 1,000 API credits/month (Mako & Moby) + Krill free unlimited (fair use), "No credit card required"; no attribution clause in the ToS (effective 2026-07-15). Read via the search index because `serpdive.com` did not resolve from this host — still true 2026-10-17 | **pass-recommended** — re-verify against the live site at adoption time |
| **Querit** | yes — `querit` | 1,000 free calls/month, "without linking a payment method" (their own FAQ); free plan 1 QPS / up to 10 results / English only; no attribution clause in the Services Agreement | **pass-recommended** (implemented 2026-10-17, untested in-repo) |

**Verdict: watch.** SERPdive clears the terms check but is not in the
tree: if it deserves adoption, it is recorded as a separate
issue — this document implements nothing (follow-up 2 below). SerpAPI,
Search1API and Querit are already in the tree. The other tier 2 names in the
tree — `tavily`, `scrappa`, `algolia`, `tinyfish`, and keyed `exa`/`parallel` —
are metered or keyed, so they do not enter this survey's question; their terms
live in `reference/providers.md`, §"Cost and free-tier summary".

## Ruled out by the no-scrape rule — a rejection, not a queue

**This section is a rejection, not a backlog.** Every entry below fails one
rule: what the adapter receives decides, and a *results page* the adapter
parses makes seekwright the scraper. Nothing here will be implemented:
**no adapter, no wiring point, no live test, no dependency, no issue.** If you
are looking for work to pick up, it is not here. This catalogue exists so the
next reader does not re-propose the same dead end: a library that parses a
results page inside our process (the `ddgs` family) is the same scrape with a
dependency in front of it, and is ruled out with them.

| Candidate | Endpoint (probed 2026-10-14) | What parsing it would need | The rule that rules it out |
|---|---|---|---|
| **duckduckgo** — *removed from the tree* | `https://html.duckduckgo.com/html/?q=…` → 200 HTML | Walk `div.web-result` blocks out of DDG's results page; no API and no contract. DDG's own `robots.txt` disallows `/html` and `/lite`. Removed 2026-10-13 with its adapter, six wiring points, live test, docs entry and `lxml` dependency | 2026-10-13 — a results page, not a response document. Not grandfathered |
| **startpage** | `https://www.startpage.com/sp/search?query=…` → 200 HTML, but an Anubis proof-of-work challenge (`anubis_version v1.26.4`), not results | Parse a results page that is not even served to a scripted client; `robots.txt` disallows `/sp/` | 2026-10-13 — results page, and bot-walled at that |
| **ecosia** | `https://www.ecosia.org/search?q=…` → 403 "Ecosia Firewall" | Parse a results page; `robots.txt` disallows `/search` | 2026-10-13 — results page, and refused at the door |
| **google** | `https://www.google.com/search?q=…` → 200 HTML, JS-and-consent shaped | Parse Google's results page; `robots.txt` disallows `/search`. The API route is the Custom Search JSON API — keyed, closed to new customers and sunsetting (table above) | 2026-10-13 — results page |
| **mojeek** | `https://www.mojeek.com/search?q=…` → bot-walled: 200 HTML carrying `<title>Captcha</title>` to a scripted client, 403 "your network appears to be sending automated queries" to a real browser from this network | Parse a results page that is not served to a scripted client at all; `robots.txt` disallows `/search`. Not a pure parser: the Web Search API is account- and key-gated and paid (table above) — neither route is tier 1 | 2026-10-13 — the page is a results page; the API is keyed |
| **bing** | `https://www.bing.com/search?q=…` | Parse a results page. This is the *only* route left: Microsoft retired the public Bing Search and Bing Custom Search APIs on 2025-08-11 (their own page, read 2026-10-14) | 2026-10-13 — results page, and the API that would have avoided it no longer exists |

## The fetch side, outside the search question

The no-scrape rule does not reach `fetch`, so keyless extraction is a
legitimate tier 1 question there — but only one endpoint with a documented
contract turned up, and it is already the tree's second fallback:

- **Jina Reader** — adopted as the fetch ladder's second fallback (tier 1 table
  above).
- **Microlink** — the anonymous endpoint `GET https://api.microlink.io/?url=…`
  is free, no card: the free plan is "25 requests per day / ~1.5K req/month",
  "No card needed" (`microlink.io/pricing`, read 2026-10-14; the rate-limit page
  gives the soft limit as "25 reqs" with `429` on exceed). Probe 2026-10-17:
  200, but the anonymous response is link **metadata** — title, description,
  lang, publisher — not page text, and whether its Text/Markdown products are
  reachable on the anonymous fallback was not confirmed (2026-10-14, in-tree
  record). **Not adopted on this evidence.**
- **Wayback Machine** — `GET https://archive.org/wayback/available?url=…` is
  keyless; probe 2026-10-17 returned 429 (the 2026-10-14 probe returned 200).
  It is an archive lookup, not an extraction endpoint: what it returns is a
  pointer to the archived copy, whose body is the original HTML. **Not adopted.**
- The hosted fetch fallbacks — `scrappa` (in the tree, 1 credit/request),
  Firecrawl (self-hosted), TinyFish Fetch, Search1API crawl, Querit contents,
  Parallel extract — are keyed or self-hosted. They are reference entries in
  `reference/providers.md`, §"Extraction endpoints", and outside the tier 1
  question.

## What this survey does and does not change

- **No code, no config, no defaults.** The adopt verdicts restate calls the
  tree already made — each sits beside the page that holds it — and the watch
  rows are recommendations, not changes. The survey's verdict decides adoption:
  this document is the finding.
- The free set of the tree is unchanged by this document: the five names of
  `FREE_PROVIDERS` — `exa:free`, `parallel:free`, `freeserp` (the install
  default), the operator-hosted `searxng`, and the free-at-any-balance
  keyed `tinyfish`; `anysearch` is keyless but explicit-only, not a member
  of `FREE_PROVIDERS`.
- A name with no credential cannot bill — that is the whole of what tier 1
  guarantees. Terms throughout are *stated* by the operators, not contracted;
  nothing here is an SLA.

**Follow-ups, to be recorded as separate issues — this document implements
nothing:**

1. **AnySearch**: live-verify the in-tree adapter in the repo — implemented
   2026-10-16 against the documented API, untested in-repo; the live test is
   keyless and free. **Done 2026-10-17:** the live test ran keyless against the
   real endpoint, and the name left `config.UNTESTED_PROVIDERS`.
2. **SERPdive**: pass-recommended by the 2026-10-16 re-check, not in the
   tree. An adoption decision if more tier 2 options are wanted;
   SERPdive's own pages still do not resolve from the deployment host (re-checked
   2026-10-17), so its pages must be re-read live at adoption time.
   **Dropped 2026-10-19** — the maintainer confirmed the drop: `api.serpdive.com`
   and `www.serpdive.com` are NXDOMAIN and `serpdive.com` publishes no A and no
   AAAA record (DNS-over-HTTPS reading at both Cloudflare and Google,
   2026-10-19T21:19:37Z), so no account
   key can be obtained and none could be used. The record is in
   `reference/providers.md`, §"SERPdive", with the DNS readings that closed
   it.
3. **FreeNewsAPI**: declined 2026-10-14 for want of a home, not for its terms —
   the door stays open: if a corpus- or news-scoped operation is ever
   specified, this is the survey to revisit first. Re-checked
   2026-10-17: both standing rules pass, no drift in terms or limits — the
   dated verdict is in `reference/providers.md`, §"FreeNewsAPI revisit
   (2026-10-17)". The decline itself stands for want of a home, not terms.
   **Deferred 2026-10-19** — the maintainer answered the go/no-go (adopt under a
   corpus- or news-scoped operation to be specified, defer, or drop) with **defer**,
   on 2026-10-18, because a further round of specialised-search-API review is
   planned. The candidate stays declined-and-revisited
   and parked: no implementation issue was opened, and the door stays open —
   if that review round specifies a corpus- or news-scoped operation, this page
   is the first to weigh, with its figures re-read live that day. Nothing about
   the decline is open, and `reference/providers.md` is where the terms and
   limits it rests on are recorded.
