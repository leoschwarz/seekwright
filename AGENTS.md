# AGENTS.md

Guidance for AI agents working in this repository.

## Project overview

An MCP server that fronts web-search providers — paid (Scrappa, Serper, Linkup,
Exa, Parallel, DeepSeek), free-tiered keyed (Algolia, Tavily, TinyFish,
Search1API, SerpAPI), and keyless (FreeSerp's own index, AnySearch's whole-web
SERP, and SearXNG via a config `url`) — behind one normalised tool surface.
Three tools: `search` (one query to a named provider), `fetch` (URL in, extracted
page text out) and `answer` (agent mode, off by default; see below). Fifteen
backends across seventeen names: Exa and Parallel each appear twice
(`exa:free`/`exa`, `parallel:free`/`parallel`) because each is free anonymously
and billed with a key.

The `answer` operation (agent mode, decided 2026-10-13) is built and **off by
default** (`[agent] enabled = false`); its contract is
[`docs/reference/agent-mode.md`](docs/reference/agent-mode.md) and its open
questions are in [`docs/ROADMAP.md`](docs/ROADMAP.md). With it on, one
operator-configured model writes prose over material the server retrieved, and
the server builds `sources` from the citations it can validate.

This is v1: a proxy and nothing else. There is deliberately **no cache** — every
`search` call reaches a provider. Read
[`docs/decisions.md`](docs/decisions.md) before changing anything structural; it
records what was removed on purpose and why.

The 0.1.0 feature freeze fixes that surface from 2026-10-23: the three tools and
their parameters, the three `POST /api/v1/…` routes and the four operational
paths, the three client verbs and the ten server flags, the seventeen provider
names, every config key, and the usage-journal fields behind `GET /dashboard`. A
frozen name moves only through a superseding dated entry in
[`docs/decisions.md`](docs/decisions.md) (the 2026-10-19 entry), and
[`docs/reference/surface.md`](docs/reference/surface.md) is the rendering CI
compares the tree against. Entries sit newest-first at the first `## <date>`
heading, and when two branches each prepend an entry, the resolution is to keep
both entries in date order (newest first) and to make no other edit to either
entry.

## Commands

All commands go through `uv` (Python 3.14, `uv_build` backend).

```bash
uv sync                       # install dependencies (dev group included, which
                              # self-includes seekwright[trafilatura], the
                              # default fetch extraction backend)
uv run pytest                 # hermetic test suite
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live             # billed provider calls (needs keys)
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k exa_free # keyless & free
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k parallel_free # keyless & free
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k freeserp # keyless & free
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k anysearch # keyless & free
uv run ty check               # type checking (pinned via dev deps / uv.lock)
uv run ruff check             # lint (pinned via dev deps / uv.lock)
uv run python -m tools.surface --check       # the frozen surface vs docs/reference/surface.md
uv run python -m tools.egress_lists --check  # deploy/compose/generated/ vs the endpoints src/ dials
uv run python -m tools.value_sets --check    # the six frozen sets vs tools/value_sets.json
uv run seekwright --check      # self-check: config, provider connectivity (free)
uv run seekwright --http       # serve streamable HTTP at /mcp on 127.0.0.1:8000
podman build -t seekwright:dev .                 # OCI image; see docs/reference/container.md
```

No formatter is configured, and ruff has no rule selection, so it checks
whatever its pinned version enables by default — bump that dependency
deliberately. The type checker reads the `[tool.ty.rules]` block in
`pyproject.toml`, which is where its strictness rules live: a change there is a
change to the gate.

## Code style and conventions

- Python 3.14, fully typed. Match the existing style: descriptive docstrings
  that explain *why* (the codebase documents design trade-offs inline — follow
  suit, don't just restate the code).
- **No decorative section banners or separators** (`# ----...---- #` +
  `# Title` + `# ----...---- #`, `# ====`, `# ----------`, and similar).
  Sectioning comes from the module docstring and the function/class structure
  itself; a banner only duplicates that structure and rots when the code moves.
  Inline comments attach to the code they explain — they never label regions.
- **A comment states a constraint; prose belongs in `docs/`.** The comment worth
  keeping is the one the code cannot state itself: a pin, an ordering, a name that
  has to match another file. A paragraph in comment syntax rots when the code
  moves, so it belongs in `decisions.md` or a `reference/` page and the file
  carries the link instead of the argument. Config files (`pyproject.toml`,
  `Containerfile`, `.gitignore`, the workflow YAML) take a comment only where a
  value would otherwise surprise a reader. The backlog of existing cases is on
  the issue tracker, which is not a licence to add to it.
- Package lives under `src/seekwright/`; `tests/` mirrors the modules it
  exercises (`test_config.py` ↔ `config.py`, etc.). The top level holds one
  module per core module, and three families sit in their own directory:
  `tests/providers/` (one module per adapter, plus `provider_base` and
  `provider_contract`), `tests/fetch/` (the fetcher, the fetch engine, the
  fallbacks, the extractors and `jsondoc`), and `tests/repo/` (the guards that
  read this tree rather than the package: `packaging`, `surface`,
  `docs_conventions`, `doc_cites`, `egress_lists`, `value_sets`, the CI
  workflows). `tests/live/` holds `test_live.py`.
- Tests use pytest-asyncio in auto mode; no fixtures are needed for async tests.
  The exception is `tests/features/` — the agent-facing tool contract is
  specified in Gherkin (`*.feature`) and run by pytest-bdd from the step modules
  beside them, whose step functions **must be synchronous** (see Gotchas below).
- Keep `import seekwright` cheap: `__init__.py` imports `cli` lazily
  precisely so importing the package does not trigger config loading.

## Architecture

| Module | Role |
|---|---|
|`models.py`|pydantic models: `SearchQuery`, `Result`, `SearchResponse`, `FetchResponse`, `ProviderResult`; `WireModel` is the base that drops unset fields|
|`prompts.py`|every model-facing string -- server instructions, the three tool descriptions and agent mode's system prompt; prose only, no logic|
| `sanitize.py` | the escape pass on text that leaves the proxy: `sanitize_text` inserts one U+200B after the opening delimiter of every model special-token literal (`<\|endoftext\|>`, the ChatML-shaped `<\|…\|>` forms) so a scraped page cannot make a tokenizer reject the whole request; reversible, idempotent, deterministic. `TEXT_FIELDS` / `sanitize_model` are the field set `models.py` applies it over at the serialisation boundary |
| `config.py` | `Config`; validates provider names, resolves `default_provider` |
| `engine.py` | `SearchEngine` resolves a provider name, records every dispatch on the health board, and walks the default-route ladder (`search.fallback`) when an unnamed search that resolved to a default fails — on a deployment where every enabled name is free and no default is configured, an unnamed search walks the free fallbacks (`search.free_fallback`, else `FREE_PROVIDER_ORDER`) instead; `FetchEngine` fetches a page on the configured primary route (`fetch.primary`, default the local reader), then walks the configured fallback ladder (`fetch.fallback`), paid fallback last; a fallback primary drops the local read from the unnamed route |
| `agent.py` | agent mode behind the `answer` tool: the model client (one OpenAI-compatible chat call on the shared httpx client — no SDK, no tokenizer) and the **fixed** retrieval plan. The model writes prose over material the server retrieved; it never drives retrieval, and there is exactly one model call per `answer`. Contract: [`docs/reference/agent-mode.md`](docs/reference/agent-mode.md) |
| `fetcher.py` | URL fetching behind SSRF guardrails; four backends — `HttpFetcher` (the free fallback, the extraction backend **injected**, no default), `Crawl4aiFetcher` (a self-hosted renderer, needs `fetch.crawl4ai_url`), `ScrappaFetcher` (the paid fallback, needs a key) and `JinaFetcher` (the keyless third-party reader) — and the fallback registry `KNOWN_FALLBACKS` beside them, one row per fallback declaring its name, whether it can bill, the endpoint it dials and how to build it. `fetch.fallback` validates against that registry, `factory.build_fetch_stack` loops it, building only the fallbacks whose row says it has what it needs, and `FetchEngine` walks them in that order |
| `extractors/` | one module per extraction backend, all implementing the `base.py` protocol; `base.py` holds the protocol, the `KNOWN_EXTRACTORS` registry, the shared plumbing (decode, sniff, normalise, `describe_types`, `is_supported`) and passage selection. The wiring list for adding a backend is in its docstring |
| `jsondoc.py` | the JSON half of the fetch path: which media types are JSON, the one-line-per-node rendering a JSON page arrives as, and the `path` grammar `fetch(path=…)` selects with — stdlib only, and the reason no dependency was added |
| `health.py` | the provider board: `HealthBoard` gates a name out of the **fallbacks** for a cooldown after the failures real traffic records, and `HealthMonitor` re-verifies it with the same bodyless GET `--check` uses. The first attempt of any search is never gated: a breaker saves the second attempt, it does not pre-empt the first |
| `logs.py` | loguru setup, the stdlib `InterceptHandler`, and the `bind`/`query_fields`/`safe` helpers every log call goes through |
| `usage.py` | `UsageRecorder`: in-memory aggregation of every terminal call plus the optional append-only JSONL journal the dashboard backfills from — content-free; the journal *file* is never read on the serving path (the dashboard backfills from it, and agent mode's per-call ceiling reads the recorder's in-memory totals, not the file) |
| `dashboard.py` | `DASHBOARD_HTML`, the one self-contained page `GET /dashboard` serves; the routes and their `_guard` live in `server.py` |
| `providers/` | one module per provider, all implementing the `base.py` protocol — the contract is written down in [`docs/reference/provider-contract.md`](docs/reference/provider-contract.md) |
| `server.py` / `cli.py` / `factory.py` | MCP wiring, entry point, construction; `factory.py` builds providers, the extraction backend (`build_extractor`) and the fetch stack (`build_fetch_stack`), so `--check` can diagnose without importing FastMCP; `server.py` also holds both transports, the process-level `build_app_context` and the custom routes — `/healthz`, the dashboard, and the REST projection (`POST /api/v1/search`, `POST /api/v1/fetch`, `POST /api/v1/answer`, behind the same `_guard` as `/dashboard`; the answer route is registered like its siblings and answers 404 while `[agent] enabled = false`); `cli.py` dispatches on `argv[0]`, so `seekwright search`/`seekwright fetch`/`seekwright answer` are a client of that projection (no config, no provider, no key) while every other invocation is the server |
| `tools/` | the three instruments that read this checkout rather than a running process, each a `--check` step in CI: `surface.py` prints the frozen surface and diffs it against `docs/reference/surface.md`; `egress_lists.py` renders the Squid host lists under `deploy/compose/generated/` from the endpoints `src/` names; `value_sets.py` compares the six frozen value sets against the pinned manifest `tools/value_sets.json`, which is what makes a widened `Literal` or a new registry member fail a merge instead of being noticed in a diff. Stdlib-only, reading source text with `ast` rather than importing the package, so each reports what the tree says instead of what an interpreter resolved. Tested in `tests/repo/`, one module per instrument, each running the gate's own command; shipped nowhere — `.containerignore` drops the directory and `uv_build` packages only `src/` |

## Gotchas

- **Nothing infers a provider from the query.** With several enabled and no
  `default_provider`, a bare `search` is an error listing what's available —
  unless every provider the deployment may dispatch is one that cannot bill, in
  which case it walks that free set instead. Adding a "pick the cheapest"
  fallback reverses a decision — see [`docs/decisions.md`](docs/decisions.md).
  Three scoped reversals are on record: a default-route `search` walks the
  operator-ordered `[search] fallback` ladder when the default fails, and a named
  provider stays terminal; a caller-declared `search(mode="free")` route
  restricted to providers that cannot bill; and a bare `search`
  with no default on a deployment whose reachable names are all free, served
  from that same walk. Both free-set conditions read the *effective*
  set (`enabled ∩ permitted`), so `permitted_providers` narrows them — see
  [`docs/reference/allow-list.md`](docs/reference/allow-list.md). Routing *by
  task* stays declined until measured per-task defaults exist; a spend ceiling
  was never this route's gate, since the free-set-restricted form cannot bill.
- **Providers are opt-in; the empty set is the keyless set.** A config that
  enables nothing — no `[providers]` block, an empty one, or every entry
  disabled — resolves to `exa:free`, `parallel:free` and `freeserp`, the names
  that reach their endpoint anonymously with no account, no key and no card. The
  startup line and `--check` say so: the default may exist but may not be
  silent. An enabled provider with no API key is startup-fatal; keys come from
  the environment only, `SEEKWRIGHT_*` prefixed. The keyless names are
  deliberate: `exa:free` (anonymous Exa), `parallel:free` (anonymous Parallel
  hosted MCP), `freeserp` (a keyless whole-web index), `searxng` (gated on a
  config `url` instead — enabled without one is a startup error), and
  `anysearch` (a keyless whole-web SERP, explicit-only, so keyless but not an
  install default; providers.md, 2026-10-16). **`exa`, `parallel`, `tavily`,
  `tinyfish`, `algolia`, `search1api`, `serpapi` and `querit` are not exempt**
  despite free tiers: the tier is an account quota, and a key names whose quota a
  search spends. For `exa` and `parallel` specifically, without a key each would
  be its `:free` sibling under a name that promises a paid fallback.
  `algolia`'s registration is mandatory on every tier, so its key is never
  optional.
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
- **`exa` spends Exa's free tier before it spends the key**, via
  `TieredExaProvider`: two fallbacks, escalating on *any* free-fallback error (not just
  a classified `QuotaExhausted` — the rate-limit sniff has never seen Exa's real
  wording), with a cooldown before free is retried and a `notice` whenever the
  key was used. This is not the "pick the cheapest" reversal: both fallbacks are the
  backend the caller named, and the ladder can only undercharge it. `exa:free`
  has no ladder and cannot bill.
- **An adapter that can't honour a constraint must say so** via
  `providers.base.ignored_constraints`, in `ProviderResult.notice`. Nothing
  filters incapable providers out before dispatch any more, so silence there is
  a silently dropped filter.
- **A provider name is `backend` or `backend:flavour`** (`exa`, `exa:free`). A
  flavour only ever exists on a backend that exists, and only the two anonymous
  halves are qualified today. Three consequences: a config table for a flavoured
  name must be quoted (`[providers."exa:free"]`), the API key comes from the
  backend segment alone (`SEEKWRIGHT_EXA_API_KEY` — `:` is not legal in a POSIX
  variable name), and where a name has to be a Python identifier it is written
  snake_case (`test_exa_free_search`), which is what the `-k` selectors in this
  file use; the README names no test selector.
  `tests/test_config.py::TestProviderNameScheme` is the guard; the scheme and
  the inventory for renaming one are in
  [`docs/reference/provider-contract.md`](docs/reference/provider-contract.md).
- **The `provider` tool parameter is a `Literal` of all seventeen names**, not
  the enabled subset — FastMCP builds the schema once at import time. Tests
  asserting on the schema must expect all seventeen (fifteen backends; Exa and
  Parallel each twice).
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
  `SEEKWRIGHT_ALGOLIA_INDEX`). Those two and `SEEKWRIGHT_SEARXNG_URL` are
  **live-test fixtures only**: the server reads `app_id`/`index` from
  `[providers.algolia]` and `url` from `[providers.searxng]` in TOML, and
  `tests/live/test_live.py` is the sole reader of all three.
  Never run `-m live` without the `SEEKWRIGHT_LIVE_TESTS=1` gate, and always
  name the provider under test — there is no default when several are
  configured. The `-k` selectors spell the free names snake_case (`exa_free`,
  `parallel_free`) because `-k` matches *test names* and a `:` cannot appear in
  a Python identifier; every string a test passes as a provider name carries the
  real spelling. `-k exa` is **not** the free run: it matches the free half's
  test name too, but the `exa` tests bill.
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
  it; it only corrects the figure `--check --live` prints.
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
- **Caller and provider content rides its own log event, never `search.ok` or
  `fetch.ok`.** `logging.log_content` adds `search.result` (one per hit),
  `search.answer` and `fetch.content`; the two `*.ok` events keep a fixed field
  set whatever it is set to, or `max_results` — chosen by the *calling model* —
  would decide how long a log line gets.
  `tests/fetch/test_fetch_fallback.py::test_the_url_is_reduced_to_a_host_by_default`
  stringifies the whole `fetch.ok` field dict, so it fails if page text lands
  there. The length a policy cap discarded is *counts*, not content, and rides its
  own per-hit `search.cap` (`uncapped_chars` / `chars` / `cap` / `field` /
  `rank`) whether `log_content` is on or not: it is what makes
  `max_snippet_chars` and `max_result_text_chars` measurable from real traffic
  without editing either value.
- **A log message is a constant dotted event name; values go through `bind()`.**
  No f-strings, no `%s`. That is what lets one call site render as text or JSON,
  and it is what makes the no-secrets rule checkable — a value reaches a line
  only by being named. Same test class enforces it.
- **`setup_logging()` must run after `server` is imported.** Constructing
  FastMCP calls `logging.basicConfig` at import time, and `basicConfig` is a
  no-op once root has handlers, so an earlier call sits behind FastMCP's handler
  and doubles every line. `cli.py` imports `server` lazily inside `main()`,
  which is what makes the call from `server.main` safe.
- **`uvicorn.Config(log_config=None, log_level=<library level as int>)` is
  load-bearing.** uvicorn's built-in config points `uvicorn.access` at *stdout*
  with `propagate: False`, and its `configure_logging` re-applies `log_level` to
  three loggers *after* `setup_logging` ran — so the default silently restores
  stdout access logs and overrides `[logging] library_level`.
- **`/healthz` is outside the Host allowlist, and must stay secret-free.** The
  check lives inside the streamable-HTTP transport rather than as middleware, so
  a `custom_route` bypasses it — which is the only reason a kubelet probe (pod
  IP in `Host`) works. It reports provider names and uptime; adding anything
  else hands it to an unauthenticated caller.
- **`tests/conftest.py` holds two loguru fixtures and nothing else.** loguru is
  process-global and its pre-installed handler has `diagnose=True`, so a failing
  test would otherwise print a stub's API key into the pytest report. Stubs
  still live next to the tests that use them.
- **A tool schema cannot be built from config.** FastMCP freezes it at
  registration and `from __future__ import annotations` means the annotations are
  `eval`'d against module globals, so a closure over a config object raises
  `NameError` — the same reason the `provider` parameter is a `Literal` of
  constant names rather than the enabled set. Config governs behaviour behind
  the schema, not the schema.
- **The HTTP listener has no auth, deliberately**, and every call it serves is
  billed — the bind address is the access control, which is why `--host`
  defaults to `127.0.0.1`. DNS-rebinding protection stays on; `--allowed-host`
  adds to FastMCP's loopback-only allowlist rather than replacing it. A `421
  Invalid Host header` means a name is missing from that list, not that the
  check should be disabled.
- **The model in agent mode must never drive retrieval** (`answer` is the third
  tool). The shape it takes: a fixed plan — the caller's query plus
  ≤2 extra queries, `max_results=5` each, up to three pages for
  `depth="report"` — feeding **exactly one** model call over the material, so the
  per-call cost is bounded by arithmetic and not by accounting. A loop in which
  the model asks for another search would make the cost the model's decision and
  put accounting back on the serving path — the ledger a spend ceiling would
  need, which is declined. `[agent]` is off by default; the model, the prompt, the
  temperature and the token budget are the server's, never tool parameters; the
  citations are the server's (validated against what it retrieved), only the
  prose is the model's. `search` and `fetch` are untouched by all of it
  ([`docs/reference/agent-mode.md`](docs/reference/agent-mode.md)).

## The review record on a pull request

Work is tracked with issue numbers and pull requests — no boards, no card ids.
Every pull request the merge gate lands carries its trailer as the **first line
of its body**, verbatim, no restyling: `Fixes #<N>`, where `<N>` is the issue
the pull request resolves, or `Part of #<N> - ` when it lands part of an issue
and the issue stays open — an issue that still owes a decision is left open by
the `Part of` line, where `Fixes #<N>` would close it. The rest of the body
carries the review evidence keyed to that issue — the checks run and how each was
verified, under a `## Review evidence (issue #<N>)` heading — so the record lives
in the PR itself.

The trailer is machine-checkable: line 1 must match `^Fixes #\d+$`, or
`^Part of #\d+ - ` with the items it lands named after the dash. The gate writes
the trailer when it opens the PR, reads the PR back and asserts the line's
**form** — not merely that `Fixes #` appears somewhere in the body — **before**
it merges; a body that does not match is not merged, and the gate comments and
stops. When the landing creates a merge commit the trailer must reach that
commit's message too, so `git log` on `main` carries it. Which call writes that
message depends on which side builds the commit, and the gate writes the trailer
into it in both cases:

- **The platform builds the merge commit** — this repository's default style, a
  GitHub merge commit (`merge_method: "merge"` on the pull's merge API, or
  *Create a merge commit* in the UI). GitHub's automatic merge-commit message is
  the pull's title followed by the pull's body, so a first-line trailer reaches
  `git log` by default; the gate still passes `commit_message` when it merges
  through the API, so the trailer does not depend on that default.
- **The reviewer builds the merge commit** — the route taken when the pull
  request has no CI read of its own, a head whose run cannot clone being the case
  that forces it. The merge is resolved in-repo, `git merge -m` writes the
  trailer into its message, and the landing is a fast-forward
  (`git merge --ff-only`), so the commit whose message the reviewer wrote is the
  commit `main` moves to.
- **An ordinary fast-forward landing** — GitHub's *Rebase and merge* — lands the
  reviewed commits themselves and cannot rewrite their messages, so there the PR
  body is the record.

The landing is then read back the way the body is. After `git fetch`, the commit
`main` now names must carry a line matching `^Fixes #<N>$` for the same `<N>` as
the body — a line matching any number would let a wrong issue number through —
its second parent must be the `head.sha` the merge was pinned to (on a
fast-forward landing the pinned head *is* the commit `main` names), and its tree
must be the tree of the head that was reviewed. A landing whose merge message
lacks the line is a process defect: file it as an issue naming the check that
should have caught it, and leave the history alone, since rewriting a commit
other clones already hold costs more than the missing line buys. The pull's
author also posts the trailer as the PR's first comment — the author, not the
gate, because a verdict or gate note can hold a thread's first slot before the
pull is trailed.

The merge path is the platform's: `main` is protected — direct pushes blocked, a
pull request required — and only the account that runs the merge gate merges.
Implementers branch and open a pull request; they never merge and never push
`main`.

It is a trailer rather than a review object because this project has one
maintainer account, and a forge will not take a review from a PR's own author:
an `APPROVE` object would need a second identity. The record is deliberately
host-agnostic.

Anyone can check a merged PR without any board or external state: the evidence is
the PR body, and the SHA it names is verified against `origin/main` with
`git merge-base --is-ancestor <sha> origin/main`. The command that reads the body
is **not** inline here: a token-bearing `curl` line makes the context loader
refuse this whole file, so it lives in [`CONTRIBUTING.md`](CONTRIBUTING.md) along
with its **presence**-check caveat (that `grep` matches the prefix anywhere in
the body; opening the merged PR is what shows the trailer is line 1). The same
read works on any host, against that host's PR-body API.
`.github/PULL_REQUEST_TEMPLATE.md` carries the trailer for a human-opened PR, and
the host does not apply that template to API-created PRs, which is why the gate
writes the body itself. The convention's decision record is in
[`docs/decisions.md`](docs/decisions.md), 2026-10-14.

### Branches are deleted when a pull request lands

Source branch names are not durable history: the repository deletes the source
branch when a pull request lands (*Automatically delete head branches*, i.e.
`delete_branch_on_merge`, or the merge command's `--delete-branch`), so the
branch is gone from the host once the landing is done.

A vanished branch is not lost work. The commits are on `main`, and the merged
pull request keeps the head SHA and the whole diff after the ref is gone — its
`head.ref` then reads `refs/pull/<N>/head`, so a restored branch has to be named
again. For a fast-forward landing the head SHA the pull request names *is* the
commit on `main`. Searching commit messages by issue number is a hint, not the
record: this repository's messages name issues both as a `Fixes #<N>` trailer and
as a parenthesised reference in the subject line, and neither form covers every
landing. To restore a deleted branch: `git fetch origin`, then `git branch <name>
<sha>` at the head SHA that pull request names. For follow-up work branch from
`main` instead. Branch names are therefore cheap — `issue-<N>-<slug>`, expected
to disappear at merge — so no document, script or CI rule should depend on a
branch surviving a merge.

## The merge-gate rules

Four rules bind the merge gate in this repository; every session working in the
tree auto-loads this file, and the dated entries beside them in
[`docs/decisions.md`](docs/decisions.md) are the record of why each one exists.
The first three came from the project's first retrospective, and the fourth from
a head that was live when a record named it and unreachable four minutes later
(`docs/decisions.md`, 2026-10-18):

- **A pull request is not landed unless its own thread carries the reviewer's
  verdict for the head under review.** A review that exists only inside an
  operator's session leaves the merged pull request without the record this
  repository promises.
- **The verdict line is literal:** `QA verdict: PASS` or `QA verdict: FAIL` as the
  first line of the reviewer's comment, naming both the reviewed head and the base
  commit. Prose around it is free; the line is what gets counted, and a bare
  `PASS` reads as no review at all.
- **A PASS on an unmoved head is merged in the same session that reads it**, before
  anything else is dispatched. A verdict that sits unmerged ages, and the next
  session pays to re-establish that it still applies.
- **A brief names a head as at one instant, so it is not the current state.**
  Before a gate session reads, comments or merges it re-reads the pull request
  (the host's pull read) and the branch tip (`git ls-remote origin`): a pull
  request that is no longer open is reported and left alone, and a merge is
  pinned to the `head.sha` that readback returns at that moment, never to a SHA
  a record or a brief carried. A check written to accept the head a record names
  passes on a head that no longer exists; what proves a head is in
  [`docs/decisions.md`](docs/decisions.md), 2026-10-18.

## Docs

[`VISION.md`](VISION.md) holds the project's goals, their precedence and its
non-goals: read it before deciding whether something belongs in this project at
all. [`docs/index.md`](docs/index.md) is the map, and the only place the shape of
`docs/` is written down: every page, its kind, which kind goes where, and why a
page's path and dated headings are never renamed for tidiness — both are cited
from `src/` and `tests/` comments and from dated records, so a move is a sweep no
check reads. Place a document by that map, not by a restatement here. Operator
working notes live outside the repository; conclusions graduate out of them into
`decisions.md` or `reference/`.

There is **no changelog**, and 0.1.0 is the first release: a change a consumer
sees lands in the reference page that owns it — `public-api.md`,
`configuration.md`, `providers.md`, `metrics.md`, or the re-printed
`surface.md` — and its reasoning goes in a dated `decisions.md` entry. An
Added/Changed/Fixed log needs an earlier release to diff against, and such a file
would restate the contract pages rather than record a delta. What the first
release leaves out is `docs/ROADMAP.md`'s, never a release note's.

Before writing or changing a provider adapter, read
[`docs/reference/provider-contract.md`](docs/reference/provider-contract.md):
the protocol and its two duck-typed extras, the status-code → exception mapping,
the redaction rule, and the six places a provider name has to be wired.

- **Documentation never cites a code line.** Not `file.ext:NNN`, not `file.ext:NNN-MMM`, not a
  bare `` `:NNN` `` continuation, not "line 379": the number moves the next time the file it
  points at is edited, and no check can tell a reader the pointer went stale — the tree has
  samples of cites landing on blank lines. Name the **symbol** instead: `UsageRecorder._append`,
  `KNOWN_PROVIDERS`, `[project.urls]`; for prose in another page, the page and its section
  (`provider-contract.md`, "Failures"); for a config file, the key or table. A source comment
  names a symbol the same way. `tests/repo/test_doc_cites.py` refuses a line cite in `docs/` and
  in the front-door markdown.

The README is the front door only: what it is, the three tools, setup, the data
privacy statement, and the links out. The caveats and any detail that grows
belong in `docs/`, linked from there.
