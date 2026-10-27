# Contributing to seekwright

seekwright is an MCP server that fronts web-search providers behind one
normalised `search`/`fetch` surface. Those two surfaces are the contract; the
provider set and the config keys are not, and may change between 0.x releases.
There is no changelog: 0.1.0 is the first release, and each change lands in the
`docs/reference/` page that owns the fact, beside the reasoning it rests on.

Bug reports, provider adapters, documentation corrections and small behaviour
fixes are all welcome. `AGENTS.md` is the source of truth for how this repository
is written; this file is the shorter path to the same conventions, plus the
commands CI runs.

## Where to send what

- **Bugs and feature requests** — the issue tracker at
  <https://github.com/leoschwarz/seekwright/issues>. The bug template asks
  for the output of `uv run seekwright --check`, which is the first thing anyone
  will need.
- **Security problems** — not the tracker. [SECURITY.md](SECURITY.md) says what is
  in scope and where to report it privately.
- **Code and documentation** — a pull request. `main` is protected: it moves
  only through a pull request whose merge is pinned to the reviewed commit and
  landed by the merge gate, so work on a branch and never push to `main` or
  force-push. The PR body carries the review record as its first line, below.

The review record — the **first line of the PR body**, verbatim:

```text
Fixes #<N>
```

`<N>` is the issue number the pull request resolves. The rest of the body
carries the review evidence for that issue — the checks run and how each was
verified — so the record lives in the PR itself. The merge gate writes the
trailer when it opens a PR and refuses to land a body whose line 1 does not
match `^Fixes #\d+$`; on a landing that creates a merge commit the trailer
reaches that commit's message too. The author also posts the trailer as the
PR's first comment, because a verdict or gate note can hold the thread's first
slot before the pull is trailed.

Read any merged PR's record from the body alone:

```bash
gh pr view <n> --json body --jq .body | grep -oE 'Fixes #[0-9]+'
```

then `git merge-base --is-ancestor <sha> origin/main` for the SHA the body
names. That `grep -oE` is a **presence** check for a human, not a form check —
it matches the prefix anywhere in the body; opening the merged PR is what shows
the trailer is line 1. `AGENTS.md` states the merge routes and why the record
is a trailer rather than a review object.

## Set up

Python 3.14 (pinned in `.python-version`) and [`uv`](https://docs.astral.sh/uv/).
Everything else comes from the lock file:

```bash
git clone https://github.com/leoschwarz/seekwright.git
cd seekwright
uv sync
```

`uv sync` installs the dev group, which self-includes the project with the
`trafilatura` extra, so a fresh clone already has a working `fetch`. No API key
is needed for the default suite: keys are opt-in per provider, and the live tests
skip without them.

## The gate a change has to pass

These are the commands CI runs, in order (`.github/workflows/ci.yml`), and the
ones to run before opening a pull request:

```bash
uv lock --check                            # pyproject.toml and uv.lock must agree
uv sync
uv run python -m tools.surface --check      # the frozen surface manifest
uv run python -m tools.egress_lists --check # the rendered egress lists
uv run python -m tools.value_sets --check   # the frozen value sets
uv run ruff check
uv run ty check
uv run pytest -q
```

`ty` is the single type checker, pinned in the dev group. It reads the
`[tool.ty.src]` and `[tool.ty.rules]` blocks in `pyproject.toml`, so a change
there is a change to the gate — [typing.md](docs/reference/typing.md) explains
which rules are on and why, and what the previous checker caught that `ty`
cannot.

CI additionally builds the wheel, installs it into a venv with no source tree on
the path and runs the entry point from outside the checkout, and builds the
container image and smokes it. Those two steps are worth reproducing locally
before a packaging change:

```bash
uv build
podman build -t seekwright:dev .
```

## Tests

The default suite is hermetic — no network, no keys, no billing:

```bash
uv run pytest
```

The live tests hit real provider endpoints and never run by default. They are
gated on an explicit opt-in and always name the provider under test:

```bash
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k exa_free        # keyless, free
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k parallel_free   # keyless, free
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k freeserp        # keyless & free
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k anysearch       # keyless & free
SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live                    # billed; needs keys
```

Two traps worth knowing before you run them. `-k exa` is **not** the free run: it
matches `exa_free` too, but the `exa` tests bill. And a provider's free tier is an
account quota, not an exemption — `tavily`, `tinyfish` and `algolia` need a key
like any other provider.

Where a test belongs:

- `tests/` mirrors `src/seekwright/`: one module per core module at the top
  level, `tests/providers/` for an adapter, `tests/fetch/` for the fetch path,
  `tests/repo/` for a guard that reads the tree, and `tests/live/test_live.py`
  for a live test.
- `tests/features/` is the exception — the agent-facing tool contract is Gherkin,
  run by pytest-bdd from the step modules beside it. Step functions **must** be
  `def`, never `async def`: pytest-bdd calls them directly, so a coroutine step
  is never awaited and the scenario passes green having asserted nothing. Run the
  async span in one `asyncio.run` inside the when-step, as
  `tests/features/test_provider_selection.py` does.
- A test about what a model reads back over the wire goes in the feature file;
  everything else stays a plain pytest module.

`tests/providers/test_scrappa.py` is the template for a provider adapter's tests: a
`SAMPLE` payload copied from the documented response, a `provider(...)` helper,
`httpx.MockTransport` for the client, and the five classes `TestParsing`,
`TestRequestShape`, `TestErrors`, `TestCost` and `TestWiring` — including the
leak regression that asserts an exception carrying the API key produces exactly
`"network error"` with the key absent from the message.

## Conventions

The whole list is in [`AGENTS.md`](AGENTS.md). The ones that catch people:

- **Python 3.14, fully typed.** Match the house style: docstrings explain *why*
  (the codebase documents its design trade-offs inline), not what the next line
  does.
- **No decorative section banners or separators** in code — no `# ---- #` +
  `# Title` + `# ---- #`, no `# ====`. Structure comes from the module docstring
  and the functions themselves; inline comments attach to the code they explain.
- **Never render a traceback.** No `logger.exception`, no `logger.catch`, no
  `diagnose=True`/`backtrace=True`, and never log an exception object — only
  `ProviderError.message`, which the adapters sanitise for exactly that reason.
  loguru's defaults would print local variable values, and every adapter has
  `headers = {"x-api-key": ...}` in scope where it fails.
- **A log message is a constant dotted event name; values go through `bind()`.**
  No f-strings, no `%s`.
- **Caller and provider content rides its own event** (`search.result`,
  `search.answer`, `fetch.content`), never extra fields on `search.ok` or
  `fetch.ok`.
- **An unhonourable constraint must be reported, not dropped.** An adapter that
  cannot apply a filter the caller passed names it in `notice` via
  `ignored_constraints`; silence there is a silently dropped filter.
- **Keep `import seekwright` cheap** — `__init__.py` imports `cli` lazily so that
  importing the package does not load config.

## Documentation

Docs live with the reason for a thing, not next to it, and
[`docs/index.md`](docs/index.md) is the one place the shape of `docs/` is written:
it names every page, labels each with its kind, and says which kind goes where.
Read it before adding a file under `docs/`. Two paths carry a rule of their own:

- [`docs/architecture.md`](docs/architecture.md) — why the code is shaped this
  way, each section naming the alternative it rejected. Read it before changing
  anything structural; a structure change edits the section it breaks.
- [`README.md`](README.md) — the front door only. Detail that grows belongs in
  `docs/`, linked from there.

A docs change gets the same review as a code change: `tests/test_config.py` loads
the configuration reference's example through the real loader, so that page
cannot drift from what the code accepts, and `tests/repo/test_docs_conventions.py`
reads the map against the tree, so a page that arrives without its entry fails
the gate.

## Adding a provider

Read [`docs/reference/provider-contract.md`](docs/reference/provider-contract.md)
first — it is the checklist, and it is longer than this section. The shape:

1. Write the `docs/reference/providers.md` entry first (endpoint, request and
   response shapes, cost, env var, gotchas). Review then checks the doc against
   the code rather than the other way round.
2. `src/seekwright/providers/<name>.py` — module docstring stating the billing
   model and why this endpoint, a module-level `ENDPOINT`, the class,
   `cost_for`, `search`, `aclose`.
3. The six wiring points (config, key requirement, factory, the tool schema's
   `Literal`, the health probe, the live-test set).
4. `tests/providers/test_<name>.py` and a live test in `tests/live/test_live.py`.
5. The prose that hardcodes the provider count, in `AGENTS.md` and the
   `docs/` pages; the README carries no count.

## Licence

[Apache-2.0](LICENSE). By contributing you agree your contribution is licensed
under it — clause 5 of the licence covers contributions submitted for inclusion
unless you explicitly state otherwise.
