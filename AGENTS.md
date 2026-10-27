# AGENTS.md

Guidance for AI agents working in this repository.

## Project overview

An MCP server that fronts web-search providers behind one normalised tool
surface. Three tools: `search` (one query to one provider), `fetch` (a URL in,
extracted page text out) and `answer` (agent mode, off by default). Seventeen
provider names over fifteen adapter modules: Exa and Parallel each appear twice
(`exa`/`exa:free`, `parallel`/`parallel:free`) because each answers anonymously
for free and bills with a key. In three groups:

- **billed per call, keyed** — `scrappa`, `serper`, `linkup`, `exa`, `parallel`,
  `deepseek`;
- **keyed with a metered free tier** — `algolia`, `tavily`, `tinyfish`,
  `search1api`, `serpapi`, `querit`;
- **keyless** — `exa:free`, `parallel:free`, `freeserp`, `anysearch`, and
  `searxng`, which is gated on a config `url` instead of a key.

This is v1: a proxy and nothing else. There is deliberately **no cache** — every
`search` call reaches a provider. [`VISION.md`](VISION.md) holds the goals,
their precedence and the non-goals; [`docs/decisions.md`](docs/decisions.md)
records what was removed on purpose and why, and is worth reading before
changing anything structural.

`answer` (agent mode) is built and **off by default** (`[agent] enabled =
false`); its contract is [`docs/reference/agent-mode.md`](docs/reference/agent-mode.md).
With it on, one operator-configured model writes prose over material the server
retrieved, and the server builds `sources` from the citations it can validate.
The model never drives retrieval. Open questions are in
[`docs/ROADMAP.md`](docs/ROADMAP.md).

The 0.1.0 freeze holds the request surface: the three tools and their
parameters, the three `POST /api/v1/…` routes and the four operational paths,
the three client verbs, the ten server flags, the seventeen provider names and
every config key. [`docs/reference/surface.md`](docs/reference/surface.md) is
that surface printed from the tree by `tools/surface.py`; `--check` re-reads the
tree and fails on drift, so a frozen name moves by changing the code and the
manifest together, with a dated entry in `docs/decisions.md` for the reasoning.

## Commands

All commands go through `uv` (Python 3.14, `uv_build` backend). The gate is the
first eight; run them before calling any change done.

```bash
uv lock --check                            # pyproject.toml and uv.lock agree
uv sync                                    # dev group included, which
                                           # self-includes seekwright[trafilatura],
                                           # the default fetch extraction backend
uv run python -m tools.surface --check      # the frozen surface vs docs/reference/surface.md
uv run python -m tools.egress_lists --check # deploy/compose/generated/ vs the endpoints src/ dials
uv run python -m tools.value_sets --check   # the six frozen value sets vs tools/value_sets.json
uv run ruff check                          # lint (pinned via dev deps / uv.lock)
uv run ty check                            # types (pinned; rules in pyproject.toml)
uv run pytest                              # hermetic suite

SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k exa_free       # keyless & free
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k parallel_free  # keyless & free
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k freeserp       # keyless & free
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k anysearch      # keyless & free
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live                   # billed; needs keys
uv run seekwright --check                  # self-check: config, provider connectivity
uv run seekwright --http                   # streamable HTTP at /mcp on 127.0.0.1:8000
uv build                                   # wheel, as the release lane builds it
podman build -t seekwright:dev .           # OCI image; see docs/reference/container.md
```

No formatter is configured, and ruff has no rule selection, so it checks
whatever its pinned version enables by default — bump that dependency
deliberately. `ty` is the only type checker; it reads the `[tool.ty.src]` and
[`tool.ty.rules`] blocks in `pyproject.toml`, so a change there is a change to
the gate ([`docs/reference/typing.md`](docs/reference/typing.md) explains the
rules).

## Code style and conventions

- Python 3.14, fully typed. Match the existing style: descriptive docstrings
  that explain *why*. The codebase documents design trade-offs inline — follow
  suit, don't just restate the code.
- **No decorative section banners or separators** (`# ----...---- #` +
  `# Title` + `# ----...---- #`, `# ====`, `# ----------`, and similar).
  Sectioning comes from the module docstring and the function/class structure
  itself; a banner only duplicates that structure and rots when the code moves.
  Inline comments attach to the code they explain — they never label regions.
- **A comment states a constraint; prose belongs in `docs/`.** The comment worth
  keeping is the one the code cannot state itself: a pin, an ordering, a name
  that has to match another file. A paragraph in comment syntax rots when the
  code moves, so it belongs in `decisions.md` or a `reference/` page and the
  file carries the link instead of the argument. Config files
  (`pyproject.toml`, `Containerfile`, `.gitignore`, the workflow YAML) take a
  comment only where a value would otherwise surprise a reader.
- Package lives under `src/seekwright/`; `tests/` mirrors the modules it
  exercises (`test_config.py` ↔ `config.py`, etc.). The top level holds one
  module per core module, and four families sit in their own directory:
  `tests/providers/` (one module per adapter, plus `provider_base` and
  `provider_contract`), `tests/fetch/` (the fetcher, the fetch engine, the
  fallbacks, the extractors and `jsondoc`), `tests/repo/` (the guards that read
  this tree rather than the package: `packaging`, `surface`, `docs_conventions`,
  `doc_cites`, `decision_cites`, `egress_lists`, `value_sets`, the CI-workflow
  guards), and `tests/features/` (Gherkin). `tests/live/test_live.py` holds the
  live tests.
- Tests use pytest-asyncio in auto mode; no fixtures are needed for async tests.
  The exception is `tests/features/` — the agent-facing tool contract is
  specified in Gherkin (`*.feature`) and run by pytest-bdd from the step modules
  beside them, whose step functions **must be synchronous** (see Gotchas below).
- Keep `import seekwright` cheap: `__init__.py` imports `cli` lazily precisely
  so importing the package does not trigger config loading.

## Commits

One line per commit, lowercase, the area named first (`deploy: …`). A
description body is added only when the line alone would drop a constraint a
reader of the diff needs — the reasoning lives in the code, its comments and
`docs/`, not in history prose.

## Architecture

The table is the agent-facing copy of the module map;
[`docs/architecture.md`](docs/architecture.md) is the same map for a reader and
explains the request paths and the seams.

| Module | Role |
|---|---|
|`models.py`|pydantic models for the tool surface and the provider boundary: `SearchQuery`, `Result`, `SearchResponse`, `FetchRequest`/`FetchResponse`, `AnswerRequest`/`AnswerResponse`, `ProviderResult`; `WireModel` is the base that drops unset fields|
|`prompts.py`|every model-facing string -- server instructions, the three tool descriptions and agent mode's system prompt -- read from `resources/`; prose only, no logic|
|`resources/`|the text of those prompts (`server_instructions.txt`, `search_description.txt`, `fetch_description.txt`, `answer_system.txt`, `answer_description.txt`) and `dashboard.html`, shipped in the wheel as package data|
|`sanitize.py`|the escape pass on text that leaves the proxy: `sanitize_text` inserts one U+200B after the opening delimiter of every model special-token literal (`<\|endoftext\|>`, the ChatML-shaped `<\|…\|>` forms) so a scraped page cannot make a tokenizer reject the whole request; reversible, idempotent, deterministic. `TEXT_FIELDS` / `sanitize_model` are the field set `models.py` applies it over at the serialisation boundary|
|`config.py`|`Config` and its sections: enabled providers, both search ladders, the fetch limits, logging, dashboard, agent mode. Validates provider, extractor and fallback names, resolves `default_provider`|
|`engine.py`|`SearchEngine` resolves a provider name, records every dispatch on the health board, and walks the default-route ladder (`search.fallback`) when an unnamed search that resolved to a default fails — on a deployment where every enabled name is free and no default is configured, an unnamed search walks the free fallbacks (`search.free_fallback`, else `FREE_PROVIDER_ORDER`) instead; a named provider stays terminal. `FetchEngine` reads through the primary route (`fetch.primary`, default the local reader), then walks `fetch.fallback` — only where the route asked for the walk (`fetch.auto_fallback`); a fallback primary drops the local read from the unnamed route|
|`agent.py`|agent mode behind the `answer` tool: the model client (one OpenAI-compatible chat call on the shared httpx client — no SDK, no tokenizer) and the **fixed** retrieval plan. The model writes prose over material the server retrieved; it never drives retrieval, and there is exactly one model call per `answer`. Contract: [`docs/reference/agent-mode.md`](docs/reference/agent-mode.md)|
|`fetcher.py`|URL fetching behind SSRF guardrails; `HttpFetcher` (the free primary, the extraction backend **injected**, no default) plus five fallbacks — `Crawl4aiFetcher` (a self-hosted renderer, needs `fetch.crawl4ai_url`), `JinaFetcher` (the keyless third-party reader), and the billable `ScrappaFetcher`, `TavilyFetcher` and `LinkupFetcher` — declared in the `KNOWN_FALLBACKS` registry beside them, one row per fallback giving its name, whether it can bill, the endpoint it dials and how to build it. `fetch.fallback` validates against that registry, `factory.build_fetch_stack` loops it, building only the fallbacks whose row says it has what it needs, and `FetchEngine` walks them in that order|
|`extractors/`|one module per extraction backend, all implementing the `base.py` protocol; `base.py` holds the protocol, the `KNOWN_EXTRACTORS` registry (`trafilatura`, `stdlib`), the shared plumbing (decode, sniff, normalise, `describe_types`, `is_supported`) and passage selection. The wiring list for adding a backend is in its docstring|
|`jsondoc.py`|the JSON half of the fetch path: which media types are JSON, the one-line-per-node rendering a JSON page arrives as, and the `path` grammar `fetch(path=…)` selects with — stdlib only, and the reason no dependency was added|
|`health.py`|the provider board: `HealthBoard` gates a name out of the **fallbacks** for a cooldown after the failures real traffic records, and `HealthMonitor` re-verifies it with the same bodyless GET `--check` uses. The first attempt of any search is never gated: a breaker saves the second attempt, it does not pre-empt the first|
|`logs.py`|loguru setup to stderr, the stdlib `InterceptHandler`, and the `bind`/`query_fields`/`safe` helpers every log call goes through|
|`usage.py`|`UsageRecorder`: in-memory aggregation of every terminal call plus the optional append-only JSONL journal the dashboard backfills from — content-free; the journal *file* is never read on the serving path (the dashboard backfills from it, and agent mode's per-call ceiling reads the recorder's in-memory totals, not the file)|
|`dashboard.py`|`DASHBOARD_HTML`, the one self-contained page `GET /dashboard` serves, read from `resources/dashboard.html`; the routes and their `_guard` live in `server.py`|
|`providers/`|one module per provider adapter, all implementing the `base.py` protocol — the contract, its two duck-typed extras and the six wiring points are in [`docs/reference/provider-contract.md`](docs/reference/provider-contract.md)|
|`server.py`|MCP wiring: the three tools, both transports, `_transport_security`, the process-level `build_app_context`, and the custom routes — `/healthz`, the dashboard, and the REST projection (`POST /api/v1/search`, `POST /api/v1/fetch`, `POST /api/v1/answer`, behind the same `_guard` as `/dashboard`; the answer route is registered like its siblings and answers 404 while `[agent] enabled = false`)|
|`cli.py`|the entry point: the server on either transport, `--check` for a diagnosis that never imports FastMCP, and, dispatching on `argv[0]`, `seekwright search`/`fetch`/`answer` as a client of the REST projection (no config, no provider, no key)|
|`factory.py`|construction: `build_providers`, `build_extractor`, `build_fetch_stack`, kept out of `server.py` so `--check` can diagnose without FastMCP|
|`tools/`|the three instruments that read this checkout rather than a running process, each a `--check` step in CI: `surface.py` prints the frozen surface and diffs it against `docs/reference/surface.md`; `egress_lists.py` renders the Squid host lists under `deploy/compose/generated/` from the endpoints `src/` names; `value_sets.py` compares the six frozen value sets against the pinned manifest `tools/value_sets.json`, which is what makes a widened `Literal` or a new registry member fail a run instead of being noticed in a diff. Stdlib-only, reading source text with `ast` rather than importing the package, so each reports what the tree says instead of what an interpreter resolved. Tested in `tests/repo/`, one module per instrument; shipped nowhere — `.containerignore` drops the directory and `uv_build` packages only `src/`|

## Gotchas

- **Nothing infers a provider from the query.** With several enabled and no
  `default_provider`, a bare `search` is an error listing what's available —
  unless every provider the deployment may dispatch is one that cannot bill, in
  which case it walks that free set instead. Four scoped exceptions are on
  record, and all of them are a caller or an operator naming a route: the
  default-route `search` walks the operator-ordered `[search] fallback` ladder
  when the default fails (a named provider stays terminal); a caller-declared
  `search(mode="free")` route restricted to providers that cannot bill; a bare
  `search` with no default on a deployment whose reachable names are all free;
  and `exa`'s free-tier-first ladder inside one adapter. Both free-set
  conditions read the *effective* set (`enabled ∩ permitted`), so
  `permitted_providers` narrows them — see
  [`docs/reference/allow-list.md`](docs/reference/allow-list.md). Adding a
  "pick the cheapest" fallback reverses a decision. Routing *by task* stays
  declined until measured per-task defaults exist, and then only from a
  caller-declared `task`.
- **Providers are opt-in; the empty set is the keyless set.** A config that
  enables nothing — no `[providers]` block, an empty one, or every entry
  disabled — resolves to `exa:free`, `parallel:free` and `freeserp`
  (`config.KEYLESS_PROVIDERS`), the names that reach their endpoint
  anonymously with no account, no key and no card. The startup line and
  `--check` say so: the default may exist but may not be silent. An enabled
  provider with no API key is startup-fatal; keys come from the environment
  only, `SEEKWRIGHT_*` prefixed, and the variable is named for the backend
  segment (`SEEKWRIGHT_EXA_API_KEY` also serves `exa:free`). `searxng` is
  gated on a config `url` instead — enabled without one is a startup error.
  `anysearch` needs nothing and is still not an install default: explicit-only.
  **`exa`, `parallel`, `tavily`, `tinyfish`, `algolia`, `search1api`,
  `serpapi`, `querit` and `deepseek` are not exempt** despite free tiers: the
  tier is an account quota, and a key names whose quota a search spends.
  `algolia`'s registration is mandatory on every tier, so its key is never
  optional.
- **Shipped is not the same as live-tested.** `config.UNTESTED_PROVIDERS`
  (`search1api`, `serpapi`, `querit`, `deepseek`) names adapters whose live test
  has never run in-repo; the startup line and `--check` say so. A name leaves
  that set only once a live run has passed, and never through a config key.
- **The extraction backend is a named opt-in too, and its library is a separate
  install.** `fetch.extractor` picks one module in `extractors/`; the default
  `trafilatura` ships as the `trafilatura` extra, which a bare `uv sync` gets
  only through the dev group's self-include. An enabled `fetch` whose backend
  library is missing is **startup-fatal**, naming the extra and the name that
  needs no library — so `--no-dev` consumers (the container) must pass
  `--extra trafilatura` explicitly or write `fetch.extractor = "stdlib"`, the
  second registry member: it reads HTML with `html.parser`, claims no PDF type,
  and is what keeps `fetch` buildable on a bare install.
  `HttpFetcher` takes the backend injected with **no default** on purpose: a
  default would import a backend at `fetcher` import time. The six places a new
  backend has to be wired are listed in `extractors/base.py`'s docstring.
- **`fetch` stops at its primary route unless the route asks for the walk.**
  `fetch.auto_fallback` is off: MCP, REST and CLI reads return the primary's
  sentence naming the ladder as `provider` values to retry with, instead of
  spending a second vendor. The `answer` plan passes `auto_fallback=True` on
  every page it reads, because its steps run unattended. `fetch.fallback` may
  name only `KNOWN_FALLBACKS` rows, each at most once, and at most one billable
  name, last — config reads each row's `billable` flag rather than checking a
  name, so a new priced vendor inherits the rule.
- **`exa` spends Exa's free tier before it spends the key**, via
  `TieredExaProvider`: two fallbacks, escalating on *any* free-fallback error
  (not just a classified `QuotaExhausted` — the rate-limit sniff has never seen
  Exa's real wording), with a cooldown before free is retried and a `notice`
  whenever the key was used. This is not the "pick the cheapest" reversal: both
  fallbacks are the backend the caller named, and the ladder can only undercharge
  it. `exa:free` has no ladder and cannot bill.
- **An adapter that can't honour a constraint must say so** via
  `providers.base.ignored_constraints`, in `ProviderResult.notice`. Nothing
  filters incapable providers out before dispatch, so silence there is a
  silently dropped filter.
- **A provider name is `backend` or `backend:flavour`** (`exa`, `exa:free`). A
  flavour only ever exists on a backend that exists, and only the two anonymous
  halves are qualified today. Three consequences: a config table for a flavoured
  name must be quoted (`[providers."exa:free"]`), the API key comes from the
  backend segment alone (`:` is not legal in a POSIX variable name), and where a
  name has to be a Python identifier it is written snake_case
  (`test_exa_free_search`), which is what the `-k` selectors in this file use.
  `tests/test_config.py::TestProviderNameScheme` is the guard; the scheme and
  the inventory for renaming one are in
  [`docs/reference/provider-contract.md`](docs/reference/provider-contract.md).
- **A tool schema cannot be built from config.** FastMCP freezes it at
  registration and `from __future__ import annotations` means the annotations
  are `eval`'d against module globals, so a closure over a config object raises
  `NameError`. Hence `search(provider=…)` is a `Literal` of all seventeen names,
  not the enabled subset, and `tests` asserting on that schema must expect all
  seventeen. `fetch(provider=…)` is the counter-example: which fetch providers
  exist is a function of config, a key and a permission set, so it is a plain
  `str | None` validated at call time by `FetchEngine.resolve`, whose refusal
  lists the names this deployment did build.
- **A `fetch` page is read three ways, and a fallback's body is never one of
  them.** `offset` continues a truncated page, `query` returns matching passages
  with their offsets, and `path` addresses a JSON document. A fallback parses its
  own response and answers in page text, so `path_addressable` stays false for
  every rung: forwarding a vendor's JSON body would make `path` select inside the
  vendor's response rather than inside the page the caller named.
- **A result carries `snippet` or `text`, never both.** SERP adapters fill the
  first, content adapters the second, and each has its own policy cap
  (`max_snippet_chars` / `max_result_text_chars`). Filling both ships the same
  prose twice — the snippet is a prefix of the extract. Leaving `text` unbounded
  is worse: it lets `max_results`, which the *calling model* picks, decide what
  a response costs, and it measured 133k characters before the cap existed.
- **Unset fields must not reach a caller as `null`.** `models.WireModel`
  enforces it with a serialiser, because `exclude_none` is an argument to
  `model_dump` and FastMCP is what calls it. A new wire model inherits from
  `WireModel`, not `BaseModel`.
- **`ProviderConfig.cost_per_1k` is `None` by default** and nothing routes on
  it; it only corrects the figure `--check --live` prints. `fetch.cost_per_1k`
  is the same reporting-only figure for the priced fallback.
- **pytest-bdd step functions must be `def`, never `async def`.** pytest-bdd
  calls them directly, so a coroutine step is never awaited and the scenario
  passes having asserted nothing. Auto mode does not cover it — the generated
  test is sync. Run the async span in one `asyncio.run` inside the when-step, as
  `tests/features/test_provider_selection.py` does.
- **Live tests hit billed endpoints** unless the key is absent (they skip) or
  the provider is a free one: `exa:free`, `parallel:free`, `freeserp`,
  `anysearch` (all keyless), `searxng` (needs `SEEKWRIGHT_SEARXNG_URL` set), or
  `tinyfish` (free but keyed) — and `algolia` (free tier, keyed and
  index-scoped, so its live test also needs `SEEKWRIGHT_ALGOLIA_APP_ID` and
  `SEEKWRIGHT_ALGOLIA_INDEX`). Those, plus `SEEKWRIGHT_SEARXNG_URL`, are
  **live-test fixtures only**: the server reads `app_id`/`index` from
  `[providers.algolia]` and `url` from `[providers.searxng]` in TOML, and
  `tests/live/test_live.py` is the sole reader. Agent mode's live run needs
  `SEEKWRIGHT_AGENT_BASE_URL`, `SEEKWRIGHT_AGENT_MODEL` and
  `SEEKWRIGHT_AGENT_API_KEY`, and selects on `-k agent_mode`. Never run
  `-m live` without the `SEEKWRIGHT_LIVE_TESTS=1` gate, and always name the
  provider under test — there is no default when several are configured. The
  `-k` selectors spell the free names snake_case because `-k` matches *test
  names* and a `:` cannot appear in a Python identifier; every string a test
  passes as a provider name carries the real spelling. `-k exa` is **not** the
  free run: it matches the free half's test name too, but the `exa` tests bill.
- **`lifespan` is the session manager's, not the process's.** Under stdio it is
  entered once; under `--http` mcp 2's session manager enters it at startup, so
  its scope is the server's, and the shared httpx client has to outlive nothing
  but the socket — which only `_serve_http` can express. So the client and the
  provider handshakes live in `build_app_context`, which the HTTP path enters
  once and parks in `server._shared` for `lifespan` to hand out. Constructing
  anything expensive in `lifespan` re-does it wherever it is entered, silently
  and only in production. `tests/test_server.py::TestSharedContext` is the guard.
- **Logs go to stderr or stdio breaks.** stdout is the JSON-RPC channel, so a
  `print()` on the serving path corrupts the protocol — `--check` is the sole
  exception, because it never runs a server. `tests/test_logs.py` asserts an
  empty stdout with `capfd`, not `capsys`: the leak worth catching is a handler
  that grabbed the original stream at `basicConfig` time.
- **Never render a traceback.** No `logger.exception`, no `logger.catch`, no
  `diagnose=True`/`backtrace=True`, and never log an exception object — only
  `ProviderError.message`, which the adapters sanitise for exactly this reason.
  loguru's *defaults* are the hazard: `diagnose=True` prints local variable
  values, and every adapter has `headers = {"x-api-key": ...}` in scope at the
  point it fails. `tests/test_logs.py::TestSourceDiscipline` enforces it by
  walking the AST, so a new call site fails the suite rather than review.
- **A log message is a constant dotted event name; values go through `bind()`.**
  No f-strings, no `%s`. That is what lets one call site render as text or JSON,
  and it is what makes the no-secrets rule checkable — a value reaches a line
  only by being named. Same test class enforces it.
- **Caller and provider content rides its own log event, never `search.ok` or
  `fetch.ok`.** `[logging] log_content` adds `search.result` (one per hit),
  `search.answer` and `fetch.content`; the two `*.ok` events keep a fixed field
  set whatever it is set to, or `max_results` — chosen by the *calling model* —
  would decide how long a log line gets.
  `tests/fetch/test_fetch_fallback.py::test_the_url_is_reduced_to_a_host_by_default`
  stringifies the whole `fetch.ok` field dict, so it fails if page text lands
  there. The length a policy cap discarded is *counts*, not content, and rides
  its own per-hit `search.cap` (`uncapped_chars` / `chars` / `cap` / `field` /
  `rank`) whether `log_content` is on or not: it is what makes
  `max_snippet_chars` and `max_result_text_chars` measurable from real traffic
  without editing either value.
- **`setup_logging()` must run after `server` is imported.** Constructing
  FastMCP calls `logging.basicConfig` at import time, and `basicConfig` is a
  no-op once root has handlers, so an earlier call sits behind FastMCP's handler
  and doubles every line. `cli.py` imports `server` lazily inside `main()`,
  which is what makes the call from `server.main` safe.
- **`uvicorn.Config(log_config=None, log_level=<library level as int>)` is
  load-bearing.** uvicorn's built-in config points `uvicorn.access` at *stdout*
  with `propagate: False`, and its `configure_logging` re-applies `log_level` to
  three loggers *after* `setup_logging` ran — so the default silently restores
  stdout access logs and overrides `[logging] library_level`. `access_log=`
  carries `[logging] access_log` on the same call.
- **`/healthz` is outside the Host allowlist, and must stay secret-free.** The
  check lives inside the streamable-HTTP transport rather than as middleware, so
  a `custom_route` bypasses it — which is the only reason a kubelet probe (pod
  IP in `Host`) works. It reports provider names and uptime; adding anything
  else hands it to an unauthenticated caller.
- **`tests/conftest.py` holds two loguru fixtures and nothing else.** loguru is
  process-global and its pre-installed handler has `diagnose=True`, so a failing
  test would otherwise print a stub's API key into the pytest report. Stubs
  still live next to the tests that use them.
- **The HTTP listener has no auth, deliberately**, and every call it serves is
  billed — the bind address is the access control, which is why `--host`
  defaults to `127.0.0.1`. DNS-rebinding protection stays on; `--allowed-host`
  adds to FastMCP's loopback-only allowlist rather than replacing it. A `421
  Invalid Host header` means a name is missing from that list, not that the
  check should be disabled.
- **The model in agent mode must never drive retrieval** (`answer` is the third
  tool). The shape it takes: a fixed plan — the caller's query plus ≤2 extra
  queries, `max_results=5` each, up to three pages for `depth="report"` —
  feeding **exactly one** model call over the material, so the per-call cost is
  bounded by arithmetic and not by accounting. A loop in which the model asks
  for another search would make the cost the model's decision and put
  accounting back on the serving path — the ledger a spend ceiling would need,
  which is declined. `[agent]` is off by default; the model, the prompt, the
  temperature and the token budget are the server's, never tool parameters; the
  citations are the server's (validated against what it retrieved), only the
  prose is the model's. `search` and `fetch` are untouched by all of it
  ([`docs/reference/agent-mode.md`](docs/reference/agent-mode.md)).

## Docs

[`VISION.md`](VISION.md) holds the project's goals, their precedence and its
non-goals: read it before deciding whether something belongs in this project at
all. [`docs/index.md`](docs/index.md) is the map, and the only place the shape of
`docs/` is written down: every page, its kind, which kind goes where, and why a
page's path and dated headings are never renamed for tidiness — both are cited
from `src/` and `tests/` comments and from dated records, so a move is a sweep no
check reads. Place a document by that map, not by a restatement here. Operator
working notes live outside the repository; conclusions graduate out of them into
`decisions.md` or `reference/`. [`CONTRIBUTING.md`](CONTRIBUTING.md) is the
shorter path to the same conventions.

There is **no changelog**: a change a consumer sees lands in the reference page
that owns it — `public-api.md`, `configuration.md`, `providers.md`,
`metrics.md`, or the re-printed `surface.md` — and its reasoning goes in a dated
`decisions.md` entry. An Added/Changed/Fixed log would restate the contract
pages rather than record a delta; what is not built yet is
[`docs/ROADMAP.md`](docs/ROADMAP.md)'s, never a release note's.

**`docs/decisions.md` is newest-first.** Entries sit newest-first at the first
`## <date>` heading, and when two branches each prepend an entry, the resolution
is to keep both entries in date order (newest first) and to make no other edit to
either entry.

Before writing or changing a provider adapter, read
[`docs/reference/provider-contract.md`](docs/reference/provider-contract.md):
the protocol and its two duck-typed extras, the status-code → exception mapping,
the redaction rule, and the six places a provider name has to be wired.

- **Documentation never cites a code line.** Not `file.ext:NNN`, not
  `file.ext:NNN-MMM`, not a bare `` `:NNN` `` continuation, not "line 379": the
  number moves the next time the file it points at is edited, and no check can
  tell a reader the pointer went stale — the tree has samples of cites landing on
  blank lines. Name the **symbol** instead: `UsageRecorder._append`,
  `KNOWN_PROVIDERS`, `[project.urls]`; for prose in another page, the page and
  its section (`provider-contract.md`, "Failures"); for a config file, the key or
  table. A source comment names a symbol the same way.
  `tests/repo/test_doc_cites.py` refuses a line cite in `docs/` and in the
  front-door markdown.

The README is the front door only: what it is, the three tools, setup, the data
privacy statement, and the links out. The caveats and any detail that grows
belong in `docs/`, linked from there.
