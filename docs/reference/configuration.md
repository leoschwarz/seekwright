# Configuration reference

Secrets come from the environment; everything else lives in TOML at
`$SEEKWRIGHT_CONFIG` (default `~/.config/seekwright/config.toml`). The
`[providers]` section is optional — a config enabling nothing resolves to the
keyless set, `exa:free`, `parallel:free` and `freeserp`, rather than failing to
start. Every key below has a working default.

The canonical definitions are the pydantic models in `config.py`; this file is
the operator-facing view of them.

## Secrets

```bash
export SEEKWRIGHT_SCRAPPA_API_KEY=...    # `scrappa`
export SEEKWRIGHT_SERPER_API_KEY=...     # `serper`
export SEEKWRIGHT_LINKUP_API_KEY=...     # `linkup`
export SEEKWRIGHT_EXA_API_KEY=...        # `exa` only -- `exa:free` never reads it
export SEEKWRIGHT_PARALLEL_API_KEY=...   # `parallel` only -- `parallel:free` never reads it
export SEEKWRIGHT_TAVILY_API_KEY=...     # `tavily`
export SEEKWRIGHT_TINYFISH_API_KEY=...   # `tinyfish`
export SEEKWRIGHT_ALGOLIA_API_KEY=...    # `algolia`, alongside `app_id` and `index`
export SEEKWRIGHT_SEARCH1API_API_KEY=... # `search1api`
export SEEKWRIGHT_SERPAPI_API_KEY=...    # `serpapi`
export SEEKWRIGHT_QUERIT_API_KEY=...     # `querit`
export SEEKWRIGHT_DEEPSEEK_API_KEY=...   # `deepseek`
export SEEKWRIGHT_AGENT_API_KEY=...      # agent mode only: the `[agent]` model endpoint
# Five names need no key at all: `exa:free` and `parallel:free` reach their
# endpoints anonymously on a rate-limited free plan, `freeserp` and `anysearch`
# are keyless whole-web SERPs, and `searxng` is keyless but requires a `url` in
# config. `anysearch` is explicit-only: it is enabled by name or not at all.
```

What each keyed name costs, and what each free tier allows, is stated once per
name in [providers.md](providers.md) §"Cost and free-tier summary"; this page
names only which variable a name reads.

The variable is always `SEEKWRIGHT_<BACKEND>_API_KEY`, where the backend is the
part of a provider name before the first `:` — so `exa` and `exa:free` both read
`SEEKWRIGHT_EXA_API_KEY`. A key names the *account*; a flavour names the *route*
through it, and `:` is not legal in a POSIX variable name anyway. Keys are never
read from the TOML file, because files get committed.

## Registering with an MCP client

```json
{
  "mcpServers": {
    "seekwright": {
      "command": "uv",
      "args": ["--directory", "/path/to/seekwright", "run", "seekwright"],
      "env": {
        "SEEKWRIGHT_SERPER_API_KEY": "..."
      }
    }
  }
}
```

That is the exact `mcpServers` value Claude Desktop
(`claude_desktop_config.json`) and Cursor (`.cursor/mcp.json`) accept; Zed's
context servers take the same `command`/`args`/`env` fields. Keys come from the
client's `env` block or from the environment it was launched in: the server
reads only `os.environ`.

## Command-line flags

Everything above configures *what* the server does; these decide how it runs,
and none of them have a TOML equivalent — a transport is a property of an
invocation, not of an install.

| Flag | Default | Meaning |
|---|---|---|
| *(none)* | — | Run the MCP server on stdio. |
| `--http` | off | Serve streamable HTTP at `/mcp` instead. |
| `--host` | `127.0.0.1` | Interface to bind. Requires `--http`. |
| `--port` | `8000` | Port to bind. Requires `--http`. |
| `--allowed-host` | loopback only | A `Host` header to accept, repeatable. Requires `--http`. |
| `--check` | — | Verify config and reachability, then exit. Never billed. |
| `--check --live` | — | One real search per ready *permitted* provider; billed, and one the allow-list excludes is reported and skipped. |
| `--log-level` | `[logging] level` | Override verbosity for this run. |
| `--log-format` | `[logging] format` | `text` or `json`, for this run. |

**Nothing authenticates the HTTP listener**, and every call it serves spends a
provider credit, so the bind address is the access control — hence the
`127.0.0.1` default. `--allowed-host` widens FastMCP's DNS-rebinding allowlist,
which starts at loopback only; without it a server on a routable address answers
`421`. [SECURITY.md](../../SECURITY.md) records why there is no auth;
[container.md](container.md) is the single-container recipe, and
[deploying.md](deploying.md) is the two-role unit set.

**The REST routes add no config key.** `--http` also serves the three operations
as `POST /api/v1/search`, `POST /api/v1/fetch` and `POST /api/v1/answer`, on the
same listener and behind the same allowlist as `/mcp`, so `--http` plus the bind
address is the whole switch. An `[api] enabled` key was rejected: the projection
is not a distinct surface, and a key that 404s `seekwright search` against an
otherwise healthy server is a worse failure than the one it prevents. `answer`
is registered like its two siblings and answers `404` while
`[agent] enabled = false`, so its off state is the route's answer. The
`seekwright search`, `seekwright fetch` and `seekwright answer` subcommands are
clients of those routes and read **no config at all**; `--server` on the command
line is the only thing that says where the server is. Contract:
[public-api.md](public-api.md).

```json
{
  "mcpServers": {
    "seekwright": {
      "url": "http://192.0.2.10:8000/mcp"
    }
  }
}
```

## Full example

```toml
# Which provider serves a `search` call that names none. Optional when exactly
# one provider is enabled -- that one becomes the default. With several enabled
# and no default set, callers must pass `provider` explicitly -- unless every
# enabled provider is one that cannot bill, in which case a bare `search` walks
# that free set instead (and one enabled name that can bill restores the error).
default_provider = "serper"

# The providers this deployment may dispatch to -- the allow-list. Unset means
# every enabled provider is permitted; once set it is a permission set, so a
# name outside it is refused before dispatch whatever its `enabled` flag says,
# and a name inside it is not thereby enabled. This example names every
# provider the block below enables, which is the copy-paste-safe shape; drop
# one to refuse it. Not the Host allowlist (`--allowed-host`).
permitted_providers = ["serper", "linkup", "exa:free", "searxng", "algolia", "exa"]

[providers.serper]
enabled = true

[providers.linkup]
enabled = true
output_type = "sourcedAnswer"  # or "searchResults"
depth = "standard"             # `deep` is ~10x the cost, so it stays server-side
cost_per_1k = 6.00             # optional: only corrects what `--check --live` reports

# Anonymous Exa. Never bills, rate-limited, needs no key. A `backend:flavour`
# name is quoted: `:` ends a bare TOML key, so `[providers.exa:free]` never
# parses (`[providers.exa.free]` is a nested table, which is not the same thing).
[providers."exa:free"]
enabled = true
url = "https://mcp.exa.ai/mcp"  # override only for a self-hosted deployment

# Your own SearXNG instance. Keyless; the url is what enables it -- enabled
# without one is a startup error, and the instance must serve format=json.
[providers.searxng]
enabled = true
url = "http://searx.internal:8080"

# Algolia searches one index you own, not the web. `app_id` and `index` are
# required -- enabled without both is a startup error -- and the search API
# key (SEEKWRIGHT_ALGOLIA_API_KEY) is required on every tier.
[providers.algolia]
enabled = true
app_id = "ABC123"
index = "products"
# title_attr = "title"      # which record attribute carries each field;
# url_attr = "url"          # unset falls back to common names plus DocSearch's
# snippet_attr = "content"  # `hierarchy`, since records are schemaless

# Billed Exa, which still tries the free tier first and only spends the key
# when that fails. Requires SEEKWRIGHT_EXA_API_KEY.
[providers.exa]
enabled = true
free_cooldown_seconds = 60.0   # how long to stop retrying the free tier

[policy]
max_snippet_chars = 500        # a SERP result's preview
max_result_text_chars = 2000   # a content result's page extract, per result
provider_timeout_seconds = 10.0

[fetch]
enabled = true
extractor = "trafilatura"     # which extraction backend reads a fetched page
timeout_seconds = 15.0        # arbitrary sites are slower than paid APIs;
                              # also the wall-clock bound on one extraction
max_text_chars = 40000        # ~10k tokens: a whole article, not a context blowout
min_text_chars = 200          # under this, the page counts as having no content
max_match_chars = 6000        # budget for what a `query` or `path` fetch returns
max_download_bytes = 8388608  # memory guardrail; raise it for huge PDFs or JSON documents
max_redirects = 3
allow_private_addresses = false  # true only if you mean to fetch intranet pages
allow_images = false        # true only where a caller can read image bytes
user_agent = "seekwright/0.1.0 (+https://github.com/leoschwarz/seekwright)"
# A fallback is one named entry in a ladder: the step a search or a fetch
# walks when the step before it fails. A fetch fallback takes one of the
# five names pinned under "The fallbacks" in fetch-safety.md -- `crawl4ai`,
# `jina`, `linkup`, `scrappa` and `tavily`; a search fallback takes any
# enabled provider name.
# The fetch ladder, in the order it is walked when the local fetch fails or
# comes back nearly empty: the self-hosted crawl4ai renderer (free), then
# Scrappa's browser-backed scraper (a credit per retry). Each fallback fires at
# most once, and only when it has what it needs -- crawl4ai a URL, Scrappa
# SEEKWRIGHT_SCRAPPA_API_KEY, and the keyed extraction fallbacks `tavily` and
# `linkup` the keys their search half already reads. Off unless you set it.
fallback = ["crawl4ai", "scrappa"]
auto_fallback = false         # walk that ladder unasked; off, so a failed or
                              # nearly-empty read names these to `provider`
primary = "http"            # the route an unnamed fetch leads with; a
                            # fallback name reads through that provider and
                            # drops the local read
crawl4ai_url = "http://crawl4ai.internal:11235"  # the renderer fallback's base URL
crawl4ai_token = "..."                      # its bearer token, when it runs with auth on
crawl4ai_timeout_seconds = 60.0             # a browser render is slower than a static fetch

[search]
# Walked, in this order, when a `search` that names no provider fails on
# default_provider. Every name must be an enabled provider -- a startup
# error, not a silently absent fallback. The default itself may appear; it is
# skipped as already tried. Naming a provider never reroutes.
fallback = ["linkup", "exa:free"]
# The ladder a `search(mode="free")` walks, in this order. Free-only: every
# name must be a provider that cannot bill, and one that can is a startup
# error. Unset walks every enabled free provider, keyless ones first.
free_fallback = ["exa:free", "searxng"]
health_interval_seconds = 60.0   # periodic best-effort ping; 0.0 disables it
health_failure_threshold = 3     # consecutive failures before a fallback is gated
health_cooldown_seconds = 120.0  # how long a gated fallback stays out

[logging]
level = "INFO"           # TRACE|DEBUG|INFO|SUCCESS|WARNING|ERROR|CRITICAL
format = "text"          # "json" for a cluster; see container.md
library_level = "WARNING"  # the MCP SDK, uvicorn and httpx, held down separately
access_log = false       # uvicorn's per-request line
log_queries = false      # opt in to full query text and fetched URLs
log_content = false      # opt in to what the provider returned; verbose

[dashboard]
enabled = true           # serve GET /dashboard + /dashboard/data under --http
# Opt-in append-only usage journal (JSONL): full history across restarts.
# Volume-mount it; nothing on the serving path ever reads it.
# history_path = "/var/lib/seekwright/usage.jsonl"

[agent]
# Agent mode: the `answer` tool, which runs a fixed retrieval plan and then one
# model call over what it retrieved. Off by default, because enabling it sends
# the caller's question and the fetched page text to the endpoint below -- a
# third party that does not exist in the two-tool path. Contract and rationale:
# docs/reference/agent-mode.md — the contract, with the reason for each rule.
enabled = false
# base_url = "https://api.deepseek.com/v1"  # OpenAI-compatible; `/chat/completions` is appended
# model = "deepseek-v4.1-flash"             # the one model; also needs SEEKWRIGHT_AGENT_API_KEY
timeout_seconds = 90.0        # the whole call, retrieval included
model_timeout_seconds = 30.0  # the model request alone, inside the whole call
max_material_chars = 24000    # total retrieved characters handed to the model (~6k tokens)
max_output_tokens_brief = 500    # the `brief` output ceiling, sent as the endpoint's cap
max_output_tokens_report = 2500  # the `report` output ceiling
max_cost_usd = 0.25           # per-call abort, checked after each retrieval step
# cost_per_1k_in = 0.00014    # dollars per 1k tokens, reporting only; unset records the
# cost_per_1k_out = 0.00028   # model cost as unknown, never as 0.0
```

## Notes on individual keys

- **Provider names** are validated against `scrappa`, `serper`, `linkup`,
  `exa`, `exa:free`, `parallel`, `parallel:free`, `searxng`, `tavily`,
  `tinyfish`, `algolia`, `freeserp`, `search1api`, `anysearch`, `serpapi`,
  `querit`, `deepseek`. A typo is a startup error rather than a quietly empty
  set, and a renamed name gets its replacement named in the error, because a
  retired name is not a typo. A config that names no provider is not this case:
  it resolves to the keyless set, `exa:free`, `parallel:free` and `freeserp`. A
  name is a backend (`exa`) or `backend:flavour` (`exa:free`); a flavour only
  exists on a backend that exists, and its table must be quoted
  (`[providers."exa:free"]` — see the example above).
- **`permitted_providers`** is the allow-list: a permission set over provider
  names, and the one key that can refuse a dispatch outright. Unset means every
  enabled provider is permitted. Once set it is **deny-by-default**: a name
  outside it is refused *before* dispatch — naming the refused name and the
  list — whatever its `enabled` flag says, and never substituted or rerouted to
  a permitted neighbour. A name inside it is not thereby enabled: the effective
  set is `enabled ∩ permitted`. It covers every dispatch this deployment can
  make to a third party — a named `search`, the default route, the
  `mode="free"` walk, agent mode's retrieval (which inherits rather than getting
  a second key) and `fetch`'s third-party fallbacks. It **bounds and never
  picks**: `[search] fallback`, `free_fallback` and `default_provider` keep
  their own semantics, minus the names it removes. An unknown name or a
  duplicate is a startup error; a list containing `"*"` reads as unset. It is
  not auth (it is identical for every caller) and not a spend ceiling. `--check`
  prints the declared set as `permitted`, plus an `effective` line when the
  intersection is smaller. Contract: [allow-list.md](allow-list.md). Not the
  Host allowlist (`--allowed-host`), which decides which names this *service
  answers to*.
- **`exa` and `exa:free`** are one backend at two prices, so they are two names
  rather than one name with a flag: what a search costs is decided by which one
  the caller asks for. `exa` requires a key and needs no permission to spend it
  — naming it is the permission — but it spends the free tier first and says so
  in `notice` when it does not. `exa:free` cannot bill under any circumstances.
  With both enabled there is no default and callers pass `provider` explicitly.
- **`parallel` and `parallel:free`** are the same split over Parallel's Search
  API. `parallel:free` is Parallel's hosted Search MCP, anonymous and capped
  server-side; `parallel` is the keyed REST API, and it is the fallback that
  carries the filter fields (domains, dates, country) — so it is the one to
  name when a search needs them. `parallel` honours `country` but has no
  `language` field and no safe-search field upstream, and drops
  `exclude_domains` while `include_domains` is set; each gap is reported in
  `notice` rather than applied silently.
- **`searxng`** points at your own SearXNG instance via `url` — its base URL,
  e.g. `http://searx.internal:8080`. It is keyless, but **enabled without a
  `url` is a startup error**: the provider has no public default to fall back
  to. The instance must serve `format=json` (`settings.yml`:
  `search.formats` including `json`) or every search fails with a
  "malformed JSON response" error. See [providers.md](providers.md) for the
  request mapping.
- **`algolia`** is index-scoped: it searches **one index you already own**, not
  the web. `app_id` and `index` are required — **enabled without both is a
  startup error** — while its search API key, from the environment like every
  key, is required on every tier. Records are schemaless, so `title_attr`,
  `url_attr` and `snippet_attr` map them onto results; unset, a chain of common
  field names (and DocSearch's `hierarchy`) applies. See
  [providers.md](providers.md) for the mapping defaults.
- **`tavily` and `tinyfish`** are keyed despite free tiers — the tier is an
  *account* quota, so the key is what names whose quota a search spends.
- **`cost_per_1k`** is reporting only. Nothing routes on it; it corrects the
  figure `--check --live` prints for an operator on a different price tier.
- **`max_snippet_chars` and `max_result_text_chars`** bound different things and
  a result only ever has one of them. A snippet is a preview and is roughly
  constant; an extract runs to thousands of characters *and* multiplies by
  `max_results`, which the calling model picks. Uncapped, one Exa call at
  `max_results = 20` measured 133k characters — so this is the key that decides
  what a search costs the caller's context window. Lower it and the model
  reaches for `fetch` more often instead. Which field a cap governs, and why
  only the extract one scales with `max_results`:
  [provider-contract.md](provider-contract.md) §"What each adapter honours". The
  length each cap discards is per hit as `search.cap` (`uncapped_chars` /
  `chars` / `cap` / `field`, counts only, whatever `logging.log_content` says),
  a measurement aid rather than a cap change: both caps keep biting inside the
  adapter, and the record is what makes either value calibratable from real
  traffic without editing it.
- **`depth`, `output_type`** are Linkup-only; **`mode`** is Parallel-only (the
  Search API preset, which is priced — correct `cost_per_1k` alongside it, the
  figures being [providers.md](providers.md)'s); **`url`** is Exa's, Parallel's
  and SearXNG's (required there — see its bullet above); **`app_id`, `index`,
  `title_attr`, `url_attr`, `snippet_attr`** are Algolia-only (`app_id`/`index`
  are required there — see its bullet above); **`free_cooldown_seconds`** is
  `exa`-only. Zero re-probes the free tier on every call, which costs a doomed
  round trip per search while a rate limit lasts; too long spends on a key the
  free tier would have covered. The default is a guess — Exa's real window has
  never been observed.
- **`fetch.enabled = false`** means the `fetch` tool refuses every call with a
  clean error, and no fetcher or ladder fallback is built. The tool stays in the
  schema (frozen at import, like every tool's), so a client still sees it
  listed — the refusal is where it learns the deployment means it. Fetch
  settings sit outside `[providers]` because a fetcher has no key, no per-1k
  cost and no name a caller can pin — see [fetch-safety.md](fetch-safety.md).
- **`fetch.max_download_bytes`** guards memory, not context; `max_text_chars`
  is what bounds what reaches the model. A PDF that hits the download cap is
  refused outright rather than truncated, because a cut PDF is unparseable
  rather than merely shorter — and so is a JSON document, while a JSON Lines
  stream keeps its text because whole records survive at its head. What a JSON
  *rendering* costs is bounded separately in `jsondoc`, at four times the body.
- **`fetch.timeout_seconds`** is also the wall-clock bound on turning a fetched
  body into text: extraction runs on a worker thread, and a body still being
  parsed when the timeout expires comes back as a non-retryable
  `cannot extract text` refusal. There is deliberately no
  `fetch.parse_timeout_seconds`: the config keys are frozen, so a key of its own
  waits for the milestone that lifts the freeze. It is the bound that the byte
  cap cannot be, because parse work does not scale with the bytes — a 302 KiB
  PDF that shows the same 200 KiB content stream on each of its 300 pages costs
  pypdf 55 seconds.
- **`fetch.min_text_chars`** is the bar below which an extraction counts as
  having found nothing: with `fetch.auto_fallback` on the ladder fires, and
  either way the caller is told the page was unusable. It is not zero because a
  JavaScript-rendered page rarely extracts to the empty string — it extracts to
  a skip link or a cookie banner. Raising it above `0` is a change in **what
  gets billed**, since every page under the bar now spends a paid fallback's
  credit where one is configured and the walk is switched on; set it to `0` for
  the old behaviour, where only a literally blank page counted.
- **`fetch.max_match_chars`** bounds what a `fetch` with `query` or with `path`
  returns: the matching passages, or the parts of a JSON document the path
  addresses, totalled, each with the offset that expands it. It is separate
  from `max_text_chars` — that one bounds the full-page response; this one is
  only spent when the caller asks for a selection — and `select_passages` and
  `select_paths` stop at it rather than trimming to it, so raising it admits
  whole additional sections rather than stretching every span.
- **`fetch.extractor`** names the backend that turns a fetched page into text:
  the name of one module in `extractors/`, defaulting to `"trafilatura"`
  (trafilatura for HTML, pypdf for PDF, the standard library's `json` for JSON).
  The registry's other name is `"stdlib"`: `html.parser` for HTML, no library of
  its own, and no PDF in its type set because the standard library carries no
  PDF reader. It drops the elements its skip list names -- `script`, `style`,
  `nav`, `header`, `footer`, `aside`, `form`, `svg` -- and keeps the text of
  everything else, so what reaches the caller where trafilatura would have
  dropped it is chrome nobody marked as chrome: a skip link, a link list no
  `<nav>` wraps, a sidebar that is not an `<aside>`. A name
  outside the registry is a startup error, like a provider typo. A backend that
  reads with libraries ships as the matching extra -- the default backend's
  names `trafilatura` and `pypdf`, because the PDF parser is contained to the
  backend that parses untrusted bytes; `stdlib` has none. An install carrying
  none of a backend's libraries is fatal *for fetch*: `--check` prints an
  `UNAVAILABLE` line naming the extra and the name that needs no library, and
  the server refuses to start while `fetch` is enabled. An install with the HTML
  library and no PDF parser is not fatal: the backend drops PDF from the media
  types it claims, `fetch` refuses a PDF by name before downloading it, and
  `--check` prints a `pdf  not read` line. The install command is
  [quickstart.md](../quickstart.md) §1's; a clone's `uv sync` already includes
  it.
- **`fetch.fallback`** is the ladder, an ordered list walked top to bottom when
  `fetch.auto_fallback` is on and the local fetch fails or comes back empty:
  `"crawl4ai"` (self-hosted renderer, free), `"jina"` (the keyless hosted Jina
  Reader — free, and a third party), `"scrappa"` (paid scraper, a credit per
  page), `"tavily"` (Tavily's extract endpoint, markdown-first) and `"linkup"`
  (Linkup's fetch endpoint, and the fallback that renders JavaScript). Those five
  are the rows of `fetcher.KNOWN_FALLBACKS`, each declaring whether it can bill,
  the endpoint it dials, and what it needs to be built. The order is the policy
  — each fallback is tried at most once per fetch, and one that can bill belongs
  last, so a page the free renderer could not read still reaches a paid fallback
  but never two of them. The shape is validated at startup: a duplicated
  fallback, a name the registry does not know — the error prints the registry —
  or a billable fallback anywhere but last is an error rather than a silently
  double-billing ladder; a bare string is a startup error. A fallback only runs
  when it has what it needs — `crawl4ai` when `crawl4ai_url` is set, Scrappa when
  its key is in the environment *and* `permitted_providers` permits it, `tavily`
  and `linkup` the same way on the keys their search half already reads, and
  `jina` through the fetch-only `PERMITTED_FETCH_NAMES` — and `--check` reports a
  configured-but-inert fallback rather than failing, because fetch still works
  without any of them.
- **`fetch.auto_fallback`** is whether that ladder is walked unasked, and the
  default is off. Off, a local read that fails fails, and a nearly-empty one
  comes back with its page and a `notice` naming the providers this key lists as
  something to *name*, because `fetch` takes `provider` and the caller can retry
  once on one of them. That is why `fetch.fallback` stays load-bearing with the
  walk off: it is also the menu the caller is handed. On, the walk runs in
  config order, and a read that used up every member is reported with the list
  of what was tried (`Fallbacks also failed: …`). The tier rule is identical
  either way, so this key says whether the walk runs and cannot reorder it or
  admit a second priced name. The `answer` plan is the one route that asks for
  the walk per call: between its steps there is no caller to act on a list, so a
  refusal there is a lost page. [fetch-provider-selection.md](fetch-provider-selection.md)
  §2 has that reason in full.
- **`fetch.primary`** is the route an unnamed fetch leads with: the first
  attempt a `fetch` that names no `provider` makes. `"http"` — the default — is
  this server's own reader. A fallback name makes that provider the first
  attempt and drops the local read from the unnamed route entirely: the operator
  who sets it is saying this server's own IP should not be the one a page sees,
  and the local reader comes back only by setting the key back to `"http"`,
  because it has no caller-facing name. The names are the fallback registry's,
  billable ones included — a billable primary is the operator paying a named
  price for every unnamed fetch. `fetch.fallback` need not name the primary: the
  walk behind the primary is `fetch.fallback` minus the primary, with the tier
  rule above (one billable name, last) unchanged — nobody is tried twice, and
  the failure menu does not offer the route that just failed. A primary this
  deployment cannot build — no key, no `crawl4ai_url`, or a name
  `permitted_providers` excludes — is a startup error naming
  `seekwright --check`, never a silent return to reading from this server's own
  IP. The `answer` plan's page reads are unnamed, so they follow the primary
  too.
- **`fetch.cost_per_1k`** is the declared price of one call to a billable
  fallback, per 1000 calls — reporting only, on the same *declared* basis as
  `[providers.*] cost_per_1k`, so nothing routes on it. Unset means the price
  declared on the fallback module: Scrappa's `0.30`/1k pack on `ScrappaFetcher`,
  Tavily's `1.60` at basic extraction, Linkup's `5.00` — so a deployment on the
  `$0.20` Scrappa pack sets `0.20`. It is one key for the whole ladder, so it
  corrects every priced fallback at once. A page records as `cost_usd` the price
  of the fallback that answered it, and the dashboard's fetch total sums those;
  the key is **absent, never `0.0`**, on a page nothing billed — the local
  fetcher, a failure, or a fallback that declares no price (`crawl4ai`, `jina`).
  See [metrics.md](metrics.md).
- **`fetch.crawl4ai_url`** points at the self-hosted renderer
  ([crawl4ai.md](crawl4ai.md) has the endpoint facts and the pinned image
  tag). Absent means the fallback does not exist, whatever the ladder lists.
- **`fetch.crawl4ai_token`** is the renderer's bearer token, when the service
  runs with auth on (0.9.x fails closed without one). It is the one credential
  that lives in the config file rather than the environment, deliberately: it
  authenticates this server to an internal service the same file already names,
  not a paid third party, and it never reaches a log line — values travel only
  by being named in `bind()`.
- **`fetch.crawl4ai_timeout_seconds`** is separate from
  `fetch.timeout_seconds` because a browser render pays a page-load and
  network-idle wait a static fetch never does; 60s is the default and the floor
  Scrappa gets (`max(timeout, 30)`) is not enough.
- **`allow_private_addresses`** applies only to the local fetcher. It never
  applies to a fallback: handing internal hostnames to another networked
  service is a leak, not a fetch. See [fetch-safety.md](fetch-safety.md).
- **`allow_images`** is off because the URL is model-supplied and whether a
  stranger's pixels ever reach a model is the operator's decision, not the
  model's. On, a PNG, JPEG, GIF or WebP URL comes back as image bytes instead of
  a refusal: the body's first bytes have to agree with the media type the header
  claimed, `fetch.max_download_bytes` still bounds the read, and an image cut at
  that bound is refused rather than returned in part. It applies to the local
  fetcher only -- a fallback extracts text and never carries bytes. See
  [fetch-safety.md](fetch-safety.md), which owns the image rule.
- **`search.fallback`** is the default route's ladder: the ordered list walked
  when a `search` that *names no provider* fails on `default_provider`. The
  default is always attempted first; a caller that names a provider gets
  exactly that provider or an error, whatever this list says — a price named is
  a price paid. Each fallback is tried at most once per search, in this order
  (operator policy — nothing infers an order from cost), an open-circuit
  fallback (see the health keys below) is skipped, and the response's `notice`
  names the substitute when one served. Every name must be an **enabled**
  provider — a duplicate, an unknown name or a disabled one is a startup error,
  unlike fetch's fallbacks, which stay silently absent when their prerequisite
  is missing. `default_provider` itself may appear; it is skipped as already
  tried.
- **`search.free_fallback`** is the ladder a `search(mode="free")` walks: the
  ordered list of providers that *cannot bill*, tried in turn when the first one
  fails. It takes `search.fallback`'s shape — no duplicates, every name an
  enabled provider, a paid or unknown name a startup error — plus the rule that
  makes the mode honest: every name must be in the free set (`exa:free`,
  `parallel:free`, `freeserp`, `searxng`, `tinyfish`). `scrappa`, `tavily` and
  `algolia` are not in it despite their free tiers — a metered allowance that
  runs out is a price with a delay on it, and the mode's whole promise is a
  ceiling of zero. Left unset, the walk is every enabled free provider: the
  keyless ones first, then `tinyfish`. The default is never consulted — the
  caller asked for a class, not for the deployment's default — and the walk
  fails rather than escalating to a paid provider. The same walk serves an
  unnamed `search` on a deployment where every enabled provider is free: no
  fallback there could bill, so the walk cannot spend.
- **`search.health_interval_seconds`, `search.health_failure_threshold`,
  `search.health_cooldown_seconds`** tune the per-provider health breaker. It is
  passive first: every real search feeds it, and `failure_threshold` consecutive
  failures gate a provider out of *ladder fallbacks* for `cooldown_seconds` —
  never out of the first attempt, which is always made. After the cooldown a
  single failure re-gates (half-open) and any success closes it.
  `health_interval_seconds` also starts a periodic best-effort ping that
  re-verifies providers with the same bodyless GET `--check` uses — it sends the
  real key and is never billed, because a bodyless request cannot produce
  results. `0.0` disables the ping; the breaker keeps working from real traffic.
  A probe that finds the API key rejected gates the provider immediately rather
  than waiting for `failure_threshold`.
- **`dashboard.enabled`** serves the browser usage page at `GET /dashboard`, its
  JSON at `GET /dashboard/data`, and the per-endpoint latency-and-cost window at
  `GET /dashboard/metrics` — all three under `--http` only. It reports spend and
  usage aggregated over every call since the journal began — per-provider cost
  and latency, a 14-day chart and the last 100 calls — as **aggregates only**,
  never query text, URLs or content. Unlike `/healthz` the page sits **behind
  the `Host` allowlist**, because it carries data: a browser must reach it under
  a name in `--allowed-host`. `enabled = false` serves nothing at those paths
  (they 404) and does not gate `seekwright --metrics`, which reads the journal
  directly. The per-endpoint figures are [metrics.md](metrics.md)'s contract;
  [container.md](container.md) has the volume mount.
- **`dashboard.history_path`** is opt-in and `null` by default. When set, every
  terminal call appends one content-free JSONL line to it, and the file is read
  back **once at startup** to rebuild history — an append-only journal, never a
  cache: nothing on the serving path reads it. Volume-mount it to survive
  container recreates; the parent directory must exist and the path must be
  writable — both checked at startup, each a startup error (`seekwright:
  dashboard.history_path: ...`) — a missing file is created at startup, and a
  volume that breaks after startup is reported once and then ignored so it can
  never fail a billed call. The file grows unbounded by design (~150 bytes a
  call); move it aside to reset history.
- **`logging.format`** defaults to `text` because the *default transport is
  stdio*, where stderr ends up in a client's log file that a person reads. Set
  `"json"` in a container — [container.md](container.md) says where.
- **`logging.library_level`** is separate from `level` so that turning this
  server up to `DEBUG` to diagnose a provider does not also enable the MCP
  SDK's one-line-per-request chatter and httpx's connection logging.
- **`logging.access_log`** is off because a cluster liveness probe every ten
  seconds is 8,640 lines a day saying nothing, and a `search` already logs
  itself with fields an access line does not have.
- **`logging.log_queries`** covers the query text *and* the fetched URL, which
  are the same sensitivity class. With it off you still get `qlen` and a
  `qhash` prefix, which answer "how many, how often, was it the same one"
  without keeping the text. Treat `qhash` as a correlation handle rather than
  anonymisation: queries are low-entropy, so a short digest is brute-forceable.
  Turning it on emits a warning at startup so the choice is visible in the log
  it affects.
- **`logging.log_content`** is the other half: the titles, URLs, snippets and
  extracted page text a provider actually returned. It answers the question the
  counts cannot — *why* did that search come back with three results and no
  useful one — and since there is no cache, it is the only way to see a response
  again without re-running the query and paying for it twice. It is separate
  from `log_queries` because it is a different *volume* class, not a different
  sensitivity one: one search at `max_results = 20` is twenty extra lines of up
  to `policy.max_result_text_chars` each, and one `fetch` a single line of up to
  `fetch.max_text_chars` — 40k by default. Content rides its own events
  (`search.result`, `search.answer`, `fetch.content`), so `search.ok` and
  `fetch.ok` keep the same fields whatever this is set to. Turning both on
  together is the usual debugging pair.
- **Logs always go to stderr**, on both transports. Under stdio, stdout is the
  JSON-RPC channel, so anything printed there corrupts the protocol.
- **`[agent]`** is agent mode: the `answer` tool, the third operation, **off by
  default**. Turning it on is what creates this deployment's third-party egress
  point — the caller's question and the fetched page text go to the endpoint
  `base_url` names — so the state that sends nothing is the one to leave alone.
  `base_url` (an OpenAI-compatible base; `/chat/completions` is appended to it)
  and `model` are required once `enabled = true`, and so is the
  `SEEKWRIGHT_AGENT_API_KEY` above: **enabled without any of the three is a
  startup error**, naming what is missing. `--check` reports the same fact
  without dying and gains an `agent` line; the startup log names the model.
  Contract and cost arithmetic: [agent-mode.md](agent-mode.md).
- **`[agent] timeout_seconds` and `[agent] model_timeout_seconds`** bound the
  same call at two scales: the whole thing, retrieval and pages included (90s),
  and the model request alone inside it (30s).
- **`[agent] max_material_chars`** (24000, ≈6k tokens) is the total retrieved
  text handed to the model — the model-call analogue of
  `policy.max_result_text_chars`, and what makes the input side of that call a
  number rather than a property of whatever the providers returned.
  **`max_output_tokens_brief`** (500) and **`max_output_tokens_report`** (2500)
  are the two output ceilings, sent as the endpoint's own cap for the depth the
  caller asked for.
- **`[agent] max_cost_usd`** (0.25) is a per-call abort, checked after each
  retrieval step: if the spend so far plus the worst-case model cost would
  exceed it, the walk stops and the call fails with what it spent recorded. It
  is an early exit for a mispriced provider or a changed endpoint, not the
  ceiling — the counts are. `null` leaves the structural bound as the only one.
- **`[agent] cost_per_1k_in` and `[agent] cost_per_1k_out`** are reporting only,
  like `ProviderConfig.cost_per_1k`: nothing routes on them. They are dollars
  per 1,000 *tokens* — a model's unit, not a provider call's — and unset means
  the model cost is recorded as unknown, never as `0.0`.
- **An unknown key is a startup error**, naming the file and the key. pydantic
  ignores unknown fields by default, which for a config file is the worst option
  available: `max_snipet_chars = 50` would parse, validate, load and do nothing,
  and the only way to find out is to notice the setting never took effect.
  Provider *names* were always checked for this reason; every key name is
  checked the same way, so a key or a table the development line shipped is
  refused rather than ignored — `max_age_seconds` and `refresh_token` went with
  the SQLite cache, and `[knowledge]` with the fact store. `tests/test_config.py`
  drives both, and loads the example above through the real loader, so this
  reference cannot drift from what the code accepts without failing the suite.
