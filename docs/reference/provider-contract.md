# What a provider adapter owes, and where a new one gets wired

`providers.md` says what each backend costs and what it returns. This file says
what the code around it requires: the protocol an adapter satisfies, the rules
it must not break, and the six places a provider name has to appear before it
works.

## The protocol

`providers/base.py` defines `SearchProvider` as a `runtime_checkable` Protocol
rather than an ABC: adapters share no implementation, so structural typing keeps
them uncoupled. There is no base class to inherit: a class that has the members
*is* a provider. "The registry" here means the name set in
`config.KNOWN_PROVIDERS`, which `tests/test_server.py` holds the tool schema
against. `health._PROBES` and `factory._PROVIDERS` record one module's decisions
about a name, and never decide whether a name is a provider.

Required:

| Member | Note |
|---|---|
| `name: str` | matches the config key |
| `cost_per_1k: float` | **declare at class level**, not only in `__init__`, or the class does not satisfy the protocol (`SerperProvider.cost_per_1k`) |
| `async search(q: SearchQuery) -> ProviderResult` | the whole job |
| `async aclose() -> None` | see ownership, below |

Two more methods are looked up with `getattr` and are deliberately *not* in the
protocol, because only some adapters have them:

- **`cost_for(max_results) -> float`** — read by `cli._live_probe` when the
  provider does not report `cost_usd` itself. Every adapter defines it, flat-priced
  ones included, which ignore the argument (`ScrappaProvider.cost_for`).
- **`warmup() -> bool`** — only the MCP-backed adapter. The server `lifespan` and
  `--check`'s `_probe_all` probe for it by `getattr`, not by provider name, so a
  renamed `exa` in config still works.

## Constraints: report what you drop

`SearchQuery` carries exactly `query`, `max_results`, `include_domains`,
`exclude_domains`, `country`, `language`, `recency` and `safe_search`; adding a
field is a change to every adapter. The field is `language`, not `locale`.

`recency` is an open-ended window — "published within the last …" — and the value
is a promise about coverage, not a calendar computation. Where the backend has a
native period (`time_range`), the value rides verbatim; where the adapter turns it
into a date range, it maps each value onto a fixed number of days: 31 and 366, or
30 and 365. Real month lengths would move the edge of the window between two calls
for no reason a caller can see.

Anything the backend cannot honour must be named through
`base.ignored_constraints(q, domains=..., dates=..., geo=..., language=..., safety=...)`,
and the result goes in `ProviderResult.notice`. `domains`, `dates`, `geo` and
`safety` are required keywords, so a new constraint is answered at every call
site. `language` is the exception — it defaults to `None`, because leaving it
unset is how an adapter with no geo surface reports both halves at once (below).
Nothing filters an incapable provider out before dispatch, so **silence there is
a silently dropped filter**, and the notice is the only place a caller can see
which of the two it got.

The buckets, and the token each drop contributes to the sentence:

| bucket | token | fires when |
|---|---|---|
| `domains` | `domain` | `include_domains` / `exclude_domains` set and not honoured |
| `dates` | `dates` | `recency` set and not honoured |
| `geo` | `country`, or the joined `country/language` | `country` set and not honoured |
| `language` | `language`, or the joined `country/language` | `language` set and not honoured |
| `safety` | `safe-search` | `safe_search` set and not honoured |

`geo` and `language` are the two halves of the geo bucket. Leave `language`
unset and `geo=False` reports the joined `country/language` token, for an adapter
that drops both. An adapter that honours one half passes `language` to split the
bucket, so the notice names only what it really dropped: `searxng.py` and
`tavily.py` both do, sending the language while the country goes unhonoured.

### What each adapter honours

This table is **derived, not the maintainer's**: read off the adapters on
2026-10-14 and against the providers' own documentation. What each name actually
sends, and the source for it, is that name's entry in [`providers.md`](providers.md);
a row here moves when that entry moves, never on its own.

| name | adapter | `language` → wire | `safe_search` → wire |
|---|---|---|---|
| `scrappa` | `scrappa.py` | `hl` | `safe=active` / `safe=off` |
| `serper` | `serper.py` | `hl` | **dropped** |
| `linkup` | `linkup.py` | **dropped** | **dropped** |
| `exa` | `exa_mcp.py` | **dropped** | **dropped** |
| `exa:free` | `exa_mcp.py` | **dropped** | **dropped** |
| `parallel` | `parallel.py` | **dropped** | **dropped** |
| `parallel:free` | `parallel.py` (MCP fallback) | **dropped** | **dropped** |
| `searxng` | `searxng.py` | `language` | `safesearch=2` / `safesearch=0` |
| `tavily` | `tavily.py` | `language` | `safe_search` |
| `tinyfish` | `tinyfish.py` | `language` | **dropped** |
| `algolia` | `algolia.py` | **dropped** | **dropped** |
| `freeserp` | `freeserp.py` | `lang` | **dropped** |
| `search1api` | `search1api.py` | `language` | **dropped** |
| `anysearch` | `anysearch.py` | `language` | **dropped** |
| `serpapi` | `serpapi.py` | `hl` | `safe` |
| `querit` | `querit.py` | `languages.include` | **dropped** |
| `deepseek` | `deepseek.py` | `lang:` operator | **dropped** |

A dropped `safe_search` is the most consequential notice in the tree: the caller
believes content was filtered, and nothing else in the response can correct that.
Every capable backend honours both of its values exactly, so there is no level
scale: `True` is the strongest on-state a backend has (SearXNG's strict, not its
moderate), `False` its off-state, and `None` means *unknown*, never *unfiltered*.

`language` is the weaker of the two: the table says only that the value reaches
the backend. On Tavily, and on the Google-backed names' `hl`, it influences which
language ranks rather than excluding the others — a boost counts as honouring
here, as `recency` already does on Tavily (`providers.md`). No backend here
guarantees a hard language filter, and the tool description must not imply one.

Three shared helpers, all in `base.py`:

- **`site_filtered_query(q)`** — folds domain filters into the query string as
  `site:` / `-site:` operators, for Google-backed backends where the operators
  *are* the interface. A provider with a native filter field uses that instead
  and does not call this. Using it counts as honouring domains, so no `notice`
  (`SerperProvider.search`).
- **`truncate_snippet(text, limit)`** — every snippet, clipped at
  `self._snippet_chars` from `policy.max_snippet_chars`: a proxy forwarding raw
  provider bodies is a tax on the caller's context window. Returns
  `(snippet, uncapped_chars)`.
- **`truncate_text(text, limit)`** — the same clip for an inline page extract,
  at `policy.max_result_text_chars`. Returns `(text, was_cut, uncapped_chars)`;
  the flag goes in `Result.text_truncated`, so a caller can tell a clipped extract
  from a short page and decide whether `fetch` is worth it.

Both return the length the cap *received*, because the clip happens before any
response is recorded and a recorded round cannot tell two cap settings apart. It
goes on `Result._uncapped_chars` — private, so it never reaches the wire — and
`search.cap` (one line per hit, counts only, `uncapped_chars` / `chars` / `cap` /
`field` / `rank`) is the record. A measurement aid, not a cap change.

Both read the value out of an upstream payload (`item.get("snippet")`,
`item.get("content")`), where the field is documented as a string and nothing
enforces it, so **both drop a non-string** — same `isinstance(value, str)` rule as
each adapter applies to its own fields — and return `None`. `AttributeError` out of
`text.split()` is not a `ProviderError`: it would escape the engine's provider-error
handling and surface as an internal error.

**Fill one field, not both.** A SERP backend fills `snippet`; a content backend
returning page text inline fills `text` (`exa_mcp.py`). Both ships the same prose
twice — the snippet is a prefix of the extract — which is what the cap exists to
prevent. Only `text` scales with `max_results`.

## Failures

Every adapter repeats the same mapping, on purpose: it is seven lines, and a
shared helper would have to take the per-provider status quirks as parameters.

| Signal | Raise |
|---|---|
| 401 / 403 | `ProviderError(name, "authentication rejected (check API key)", retryable=False)` |
| 402 / 429 | `QuotaExhausted(name, ...)` — always non-retryable |
| any other `>= 400` | `ProviderError(name, f"HTTP {code}")` |
| `httpx.TimeoutException` | `ProviderError(name, "request timed out")` |
| `httpx.HTTPError` | `ProviderError(name, "network error")` |
| `resp.json()` raising `ValueError` | `ProviderError(name, "malformed JSON response")` |
| `resp.json()` returning valid JSON that is not an object (a list, string, number or `null`) | `ProviderError(name, "malformed JSON response")` |

An undecodable body and an unshaped one are the same wire failure, which is why
the last two rows carry the same message. Without the non-object guard, `_parse`
calls `data.get` on a list or a scalar and raises `AttributeError`, which escapes
the engine's provider-error handling.

`parallel` is the exception: both its fallbacks hand the decoded body to
`parse_results`, which checks the shape and returns an empty result set, so a
non-object body there is zero results rather than a failure — pinned by
`tests/providers/test_parallel.py::TestParsing::test_a_non_dict_payload_is_empty_not_an_error`.

`tests/providers/test_provider_contract.py` checks this table as one unit: it
reads the rows out of this document, drives six of the seven over every HTTP
adapter, and fails if a row is removed or an adapter stops honouring one. The
seventh must exist but is not driven. Each `tests/providers/test_<adapter>.py`
therefore keeps the quota row's two quirks: which statuses that backend answers
with "you have run out", and the wording `QuotaExhausted` carries for its
billing model.

Which status names a quota is a per-vendor fact: a status joins an adapter's
quota rung only where that vendor answers with it on the request *this proxy
sends*. `serper` reads 402 because its documentation answers a spent balance
that way; `linkup` reads 429 alone, since its 402 belongs to an x402 payment
lane this adapter never enters; `searxng` reads 429 alone, because a self-hosted
instance bills this client nothing. Reopening a rung takes a live keyed probe
against a spent balance, not another reading of a pricing page.

**Redaction is not optional.** Never interpolate an httpx exception or a raw
response body into a message: httpx errors can echo the request, and the request
headers hold the API key. `serper.py`'s `except httpx.HTTPError` arm carries the
comment, there is a test for it (see below), and every new adapter needs both.

A failure is terminal — with no cache there is nothing to degrade to. Zero
results is not a failure: a provider that returns nothing has told the caller
something true.

**One refusal an adapter never sees.** The allow-list
(`permitted_providers` — [allow-list.md](allow-list.md)) is enforced *above* the
adapters, so an excluded name never reaches one. `SearchEngine.resolve` raises
`SearchRefused` (a `SearchFailed` subclass) before `_call` for a caller-named
provider and for an unpermitted `default_provider`, and the fetch ladder's paid
fallback is not built at all when `scrappa` is unpermitted
(`factory.build_fetch_stack`). `ProviderError` has no "unpermitted" member, and
adding one would put a policy the adapter cannot see into its failure mapping.

## Ownership and cost

The `httpx.AsyncClient` is created by the server lifespan and **shared across
every HTTP adapter**, so `aclose()` on those is a documented no-op — closing it
would break the sibling providers. Only the MCP adapter, which opens its own
connection, has real work there. The fetcher's client is separate, so no provider
key can ride along on a fetch; see [`fetch-safety.md`](fetch-safety.md).

The MCP-backed names (`exa`, `exa:free`, `parallel:free`) hold a *client session*:
one long-lived task enters and exits the transport stack while request tasks
borrow the session. Those context managers are anyio cancel scopes bound to the
entering task, so opening a session in one request and closing it in a later one
raises "attempted to exit a cancel scope that isn't the current task's" and takes
the server down. Teardown therefore cancels that owner rather than asking it to
finish, and does so while still holding the lock: releasing first would let a
concurrent caller build a fresh owner that this teardown then kills.

`cost_per_1k` is reporting only: it sets what `--check --live` prints. Its
default is written **twice** — in the adapter's `__init__` signature, and as the
row's `default_cost` in `factory._PROVIDERS` (the `_cost(pc, N)` fallback is
`_BuildSpec.cost`). Only the factory one takes effect, since the factory always
passes the argument; move both together or the adapter default becomes a lie when
someone constructs it by hand.

Per-request-billed backends map requests onto the 1k unit inside `cost_for` —
Serper doubles above 10 results, Exa adds ~$1/1k for each result past 10,
Scrappa is one credit whatever `num` says.

## The six wiring points

The provider name is repeated in six places; each site has a different reason to
exist, and none can derive the others.

1. `config.KNOWN_PROVIDERS` — an unlisted name is a startup error, not a typo
   that silently disables a provider.
2. `config.PROVIDERS_REQUIRING_KEY` — drives `missing_api_keys()`. Five names are
   exempt as keyless: `exa:free` (Exa's hosted MCP works anonymously),
   `parallel:free` (Parallel's hosted Search MCP does too), `freeserp` (a keyless
   whole-web index), `searxng` (the operator's own instance, gated on a config
   `url`), and `anysearch` — keyless and explicit-only, so no default-route
   membership ([`providers.md`](providers.md) has the detail). `exa`, `parallel`,
   `tavily`, `tinyfish` and `algolia` are *not* exempt despite free tiers: the
   tier is an account quota, and a key names whose quota a search spends
   (`algolia`'s registration is mandatory on every tier).
3. The `_PROVIDERS` table in `factory.py` — one row per name: the builder, the
   `_cost` default, and any timeout floor (with a comment saying why, e.g. a
   scraping backend being slower than a SERP index). The builder owns the name's
   prerequisite — its key, `searxng`'s `url`, `algolia`'s `app_id` and `index` —
   and returns `None` when this config lacks it, which is the skip `--check`
   reports. `tests/test_factory.py::TestProviderRows` pins each row's price and
   floor and that the table covers every name `config` admits.
4. The `Literal` in the `search` tool signature in `server.py` — FastMCP builds
   the schema once at import time, so it lists every adapter rather than the
   enabled subset. The `answer` tool carries a second copy, so a new name lands in
   two signatures.
5. The `_PROBES` table in `health.py` — one row per name: endpoint and header
   builders, beside the reason that probe has its shape (rendered into `--check`'s
   prose by `cli._probe_http`). A name with no row returns `"unsupported (no
   connectivity probe)"`, which is **not** in the ready set, so forgetting it
   makes a working provider look broken. The adapter must export a module-level
   `ENDPOINT` for `health.py` to import — `searxng` and `algolia` are the
   exceptions, building the URL from the provider's config entry and answering
   `unsupported` when it names none. A name in `PROVIDERS_REQUIRING_KEY` whose key
   is absent is answered *before* the lookup, as `key_required` (`"no API key (key
   is mandatory)"`), because `build_providers` never built it.
   `tests/test_health.py::TestProbe::test_the_table_covers_every_name_the_monitor_probes`
   is the backstop for a built, non-MCP name with no row.
6. `ALL_PROVIDERS` in `tests/live/test_live.py`.

**The keyless set is also the install default.** A config that enables nothing
resolves to `exa:free`, `parallel:free` and `freeserp` — `config.KEYLESS_PROVIDERS`,
all three exempt from `PROVIDERS_REQUIRING_KEY` and all three members of
`FREE_PROVIDERS` — so an install reaches a search with no key and no config file.
It is the one case where a config naming nothing is *not* an error; an unlisted
name still is (point 1). The startup line and `--check` name the set and say it
was implicit: a set nobody announced is a config nobody can audit. The constant
spells all three names.

Env var naming is the one thing derived mechanically: `config.api_key_env_var`
builds `SEEKWRIGHT_<BACKEND>_API_KEY` from the name's **backend segment**
(everything before the first `:`). Every site that prints a variable name goes
through it, `server.main`'s check and `--check`'s line included, so `exa:free`
never asks for `SEEKWRIGHT_EXA:FREE_API_KEY`, not a legal POSIX variable name.

Provider-specific knobs are flat fields on `ProviderConfig` with an "X only"
comment (`depth` and `output_type` are Linkup's, `mode` Parallel's, `url` Exa's
and SearXNG's, `app_id`/`index`/`title_attr`/`url_attr`/`snippet_attr` Algolia's,
`free_cooldown_seconds` `exa`'s), not per-provider subclasses: seventeen entries
over fifteen backends do not justify the hierarchy.

A name is not always a backend. `exa` and `exa:free` are one endpoint on two
credentials, split because the credential decides the price; `parallel` and
`parallel:free` are the same split over Parallel's REST API and hosted MCP, whose
halves answer on different endpoints and are priced apart. `exa:free` is
`exa_mcp.py` and `parallel:free` subclasses it, so a *second* name for an
existing backend costs the six points above and, at most, a small module.

## Renaming a name: the `backend:flavour` scheme

A name is `backend` or `backend:flavour`: the bare name is the default flavour,
and a colon introduces a variant *of the same backend* — only the two anonymous
halves carry one (`exa:free`, `parallel:free`). Three rules fall out of the
separator, each a way a rename breaks something silently:

1. **A config table name must be quoted.** `[providers."exa:free"]` parses;
   `[providers.exa:free]` is a `TOMLDecodeError` ("Expected ']' at the end of a
   table declaration"). Values need no quoting — `default_provider = "exa:free"`
   and `fallback = ["exa:free"]` are strings. `exa.free` is not an option:
   `[providers.exa.free]` parses as a *nested table* and never round-trips.
2. **The env var comes from the backend segment**, because `:` is not legal in a
   POSIX variable name (`config.api_key_env_var`).
3. **A `:flavour` is only legal on a known backend**; a flavour never exists
   without the backend it qualifies. `tests/test_config.py::TestProviderNameScheme`
   asserts this over `KNOWN_PROVIDERS` along with the two rules above: every bare
   name parses as a TOML key, every flavoured name parses quoted, and no name
   derives an illegal env-var name.

A rename is a **hard rename**: the old name leaves `KNOWN_PROVIDERS`, and the
unknown-name startup error has to name the replacement, because `supported: …`
alone sends an operator hunting for the diff. No alias and no deprecation window:
an alias puts two names for one thing onto the health board, into the usage
journal and into the dashboard's per-provider series, and splits the journal's
history at the rename, which the cost and ranking figures read. Recorded data
keeps the names it was recorded under. What would flip the choice is a name
already shipped in a released artifact with operator configs in the field: then
the answer is an alias with a warning, over one release window.

## Adding one, in order

1. **Write the `providers.md` entry first** — endpoint, shapes, cost, env var,
   gotchas — so review checks the doc against the code, not the reverse.
2. `providers/<name>.py`: module docstring stating the billing model and why this
   endpoint, module-level `ENDPOINT`, the class, `cost_for`, `search`, `aclose`.
3. `providers/__init__.py`: import and `__all__` entry, alphabetical.
4. The six wiring points above.
5. `tests/providers/test_<name>.py` plus the live test in `tests/live/test_live.py`.
6. The prose that hardcodes the provider count — all of it. `AGENTS.md` says
   "fifteen backends across seventeen names"; the README carries no count. The
   same numbers are in `docs/architecture.md` (the adapter/name table and its
   tally, the `Literal` note, the pointer to `providers.md`), `docs/ROADMAP.md`
   (the `safe_search` / `language` counts), `docs/reference/agent-mode.md`,
   `docs/reference/allow-list.md`, this file's own counts, `tools/surface.py`'s
   docstring, and the `SearchRequest` docstring in `src/seekwright/models.py`.
   The sweep is `git grep -n -iE '\b(sixteen|fourteen)\b' -- '*.md' '*.py'`: the
   pair the last bump replaced, so a live hit is a site that bump missed — put
   the pair you replace into it when you bump. `\b`, not a trailing space, since
   a count word at the end of a wrapped line has none after it. `*.toml` stays
   out of the globs: the only tracked one is `pyproject.toml`, packaging metadata
   with no count prose. Hits in historical entries stay as written.

## What the tests must cover

`tests/providers/test_scrappa.py` is the template: module-level `SAMPLE` copied
from the documented payload, a `provider(...)` helper, and a `mock_client(handler)`
over `httpx.MockTransport`. Then five classes:

- **`TestParsing`** — calls `_parse` directly (private access is allowed in tests).
  Records missing a URL or title are dropped, non-dicts skipped, a missing
  container is empty rather than an error, the limit is honoured, and **no
  `published_date` is invented** when the provider does not send one.
- **`TestRequestShape`** — captures the `httpx.Request` and asserts the auth
  header, the params sent, that empty params are omitted, `max_results` clamping,
  `site:` folding, and that `notice` matches the adapter's capabilities.
- **`TestErrors`** — the adapter's own quirks only: which statuses that backend
  answers as quota, the wording `QuotaExhausted` carries for its billing model,
  and **the leak regression** — a handler raising an `httpx.ConnectError` carrying
  the API key in its message must produce exactly `"network error"`, key absent
  from `str(exc.value)`. The other six rows are not re-asserted here;
  the table above is the source.
- **`TestCost`** — that `cost_for` tracks the real billing model.
- **`TestWiring`** — `factory.build_providers` skips the provider with no key and
  builds it with one; `ProviderConfig(cost_per_1k=...)` overrides; an unset cost
  falls back to the adapter's default. The only test of `_cost`.

Live tests go in `tests/live/test_live.py`, gated on `SEEKWRIGHT_LIVE_TESTS=1`,
skipped when the key is absent, and must **name the provider explicitly** — there
is no default when several are configured and one of them can bill.
