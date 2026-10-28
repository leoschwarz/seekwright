# docs/

The documentation surface of this project and its design record in the same
tree. Read the [README](../README.md) for what the project is, the
[quickstart](quickstart.md) for a first run, then the reference page that covers
what you are about to touch. The project's goals, precedence and non-goals are
[VISION.md](../VISION.md). The dated survey and the roadmap are the reasoning
those pages rest on: worth reading before changing something structural, never
needed to use the server. Open work lives in [ROADMAP.md](ROADMAP.md), not here.

## Structure

| Path | What lives there |
|---|---|
| `index.md` | This file: the map, the kinds a page can be, and where a new page goes. |
| `quickstart.md` | The first run, tier by tier, each tier ending in the check that verifies it. |
| `architecture.md` | What the system is and how the pieces fit. The page for a reader opening the code for the first time. |
| `ROADMAP.md` | Open work and its gates. The only place "what is next" is written down. |
| `reference/` | Every page that would otherwise require re-reading `src/` or a vendor's docs: the contracts and runbooks a deployment is driven by, the explanations behind them, and the dated findings. One flat directory — see the placement rule below for why it stays flat — and every page in it carries its kind in the list below. |

Operator working notes are not part of this tree; when a note settles something,
its conclusion graduates into the page that owns the contract.

`AGENTS.md` points here rather than restating any of it. Guidance that changes
what an agent *writes* belongs in AGENTS.md; the reason for a rule belongs beside
the rule, in the page that states it, and a system-wide refusal belongs in
`architecture.md`'s "Deliberate non-features".

## Kinds, and where a new page goes

Every page is one of six kinds. The kind says how the page is allowed to
change, so it is stated in the map and read before trusting an age.

| Kind | What it is | How it may change |
|---|---|---|
| `guide` | Steps followed once, in order. | Rewrite freely while the steps still work. |
| `explanation` | How the pieces fit, for a reader who has not seen the code. | Rewrite freely; it names no contract. |
| `roadmap` | Open work and its gates. | Edit in place; a closed item leaves the page. |
| `contract` | What a caller may depend on, or what the code owes. | Edit with the code, in the same PR that moves it. |
| `runbook` | The steps of an operation someone performs again. | Edit in place; every command printed has been run. |
| `survey` | A dated finding: a question answered at a date. | Supersede with a new dated page; never restate the question at a new date inside the old one. |

Three questions, in order, place a new page:

1. Is it "what is next"? A section of `ROADMAP.md`, not a page.
2. Does it settle why the code is shaped so? Not a page of its own: the rule and
   its reason sit together in the page that owns the contract, and a system-wide
   refusal in `architecture.md`'s "Deliberate non-features".
3. Is it a fact about the running system, the steps of an operation, or a dated
   answer to a question? A page in `reference/`, labelled with its kind below.

Three rules the map enforces:

- **A page is linked here, once, with its kind.** `tests/repo/test_docs_conventions.py`
  walks `docs/` and fails on a page the map does not link, on a page it links
  twice, and on a bullet that carries no kind. It is the check added when
  `reference/surface.md` reached `main` reachable only as prose.
- **A page's path, and a dated heading inside a page, is load-bearing.** Pages and their
  dated sections are cited by name from `src/` and `tests/` docstrings and from other
  pages in `docs/`, and `providers.md`'s dated rows are cited by their own dates. The
  counts of those citations live in the survey that takes them, not here — this map is
  one of the things counted, so a figure published in it moves whenever the map is
  reworded. A move or a rename therefore costs a sweep of citations no check reads, and
  it silently changes what a dated section points at. Order lives in this map, not in the
  directory tree.
- **`docs/` stays two levels deep: `docs/`, and `docs/reference/`.** A reader reaches a
  page through this map rather than by walking directories, and every citation to a page
  spells its path. A third level buys organisation nobody reads and changes the path
  every page under it is cited by, which is the sweep the rule above says no check reads.

## Documents

The groups are the reading route: who the page is written for, then the kind it
is. One line each — what the page pins — and the page itself carries the detail.
A page belongs to one group and one kind; where a page serves two audiences, it
is placed where its contract lands and the other group links it from prose.

### The way in

- **guide** — [Quickstart](quickstart.md) — the four onboarding tiers in the order a
  new operator meets them, each ending in the check that verifies it.
- **explanation** — [Architecture](architecture.md) — the three request paths, the
  routing, provider and extraction-backend seams, the fallback ladders, the observability
  half, and the deliberate non-features. The human-facing counterpart to `AGENTS.md`'s
  architecture table.

### For the operator

What a deployment's owner configures, runs and watches.

- **contract** — [Configuration](reference/configuration.md) — every TOML key,
  command-line flag and environment variable, its default, and what it actually bounds.
  `tests/test_config.py` loads this page's example through the real loader.
- **contract** — [Providers and API reference](reference/providers.md) — the in-tree
  reference: endpoint, request shape and price per name, each figure as-of the date on
  its entry. The dated archive begins at "Adoption candidates"; read that page's
  organisation note before quoting one of its dated sections.
- **contract** — [The allow-list](reference/allow-list.md) — the permission set over
  provider names: the key and its TOML, the validation, every `src/` site that
  enforces it, the refusal's wording, and what `--check` prints.
- **contract** — [Metrics: per-endpoint latency and cost](reference/metrics.md) — the
  journal line and its backward-compatibility rule, the per-provider p50/p95/cost
  aggregate and how its population is chosen, the window and retention semantics, and
  the schema the three surfaces publish — with the command or route each one is, not a
  transcript of it.
- **contract** — [Fetch safety](reference/fetch-safety.md) — what `fetch` guards
  against (SSRF, redirects, download caps) and the hazards it states it does not
  (prompt injection, DNS rebinding, `robots.txt`). `SECURITY.md` answers from here.
- **contract** — [The crawl4ai renderer fallback](reference/crawl4ai.md) — the
  self-hosted browser service behind `fetch`'s renderer fallback: its status in the
  tree, the pinned image tag and how far it has drifted, the exact `/crawl` request and
  response, auth, the resource cost, and where the vendor's hosted API sits. The file to
  update on an image bump.
- **runbook** — [Running in a container](reference/container.md) — building the OCI
  image and serving the HTTP transport from it, the two build details that are
  load-bearing, the rootless/SELinux mount traps, the single-container run, and
  what the logs, `/healthz` and the dashboard promise. The operational companion
  to the no-auth decision.
- **guide** — [Deploying it safely](reference/deploying.md) — the two-role
  deployment: the two shapes and which to start with, the four commands that
  start `deploy/compose/`, the two knobs in `.env` and the key file only the
  search role is handed, the sequence that verifies both refusals, the strict
  fetch policy, and what a name list does not defend. A `guide` rather than a
  `runbook` because no runtime ran while it was written: the compose commands are
  stated, and the page says which of its lines came from a run.

### For integrators and contributors

What a caller may depend on, and what the code owes.

- **contract** — [The public API](reference/public-api.md) — the three operations, the
  REST projection and its status codes, and the deliberate omissions. Read before
  adding a surface or a field.
- **contract** — [The frozen surface](reference/surface.md) — every name the 0.1.0
  freeze holds, printed from the tree by `tools/surface.py`, with `--check` failing CI
  on drift. The response models and the `Literal` vocabularies are in `public-api.md`.
- **contract** — [Provider contract](reference/provider-contract.md) — what an adapter
  implements, the failure and redaction rules it shares, and the six places a provider
  name gets wired. The checklist before adding an adapter; `providers.md` is the facts,
  this is the shape.
- **contract** — [Agent mode](reference/agent-mode.md) — `answer`: what the server owns
  and what the caller owns, the fixed retrieval plan, the two cost ceilings, the
  ranking data's privacy rule, and the failure contract.
- **contract** — [A provider field on `fetch`](reference/fetch-provider-selection.md)
  — the living rules of a `fetch` that names its provider and reports instead of
  retrying out of sight: what the field may name, the `fetch.auto_fallback` key
  and the tier rule it cannot reorder, each failure sentence and the surface it
  lands on, and the three conditions under which any of that is revisited.
- **explanation** — [Typing policy](reference/typing.md) — which rules in the
  `[tool.ty.rules]` block `ty` reads are on and why, and the checks `ty` has no
  rule for. Read before changing a value there.

### For the maintainer

- **runbook** — [Publishing a release](reference/publishing.md) — maintainer-only:
  the publish workflow's one trigger, where the version comes from, what the run
  refuses to do when the tag's release already holds a different asset of that
  name, and what a publish run has to show.

### Records and open work

The dated half of this tree: questions answered and work planned. None of it names
a contract, and all of it is cited as it was written.

- **roadmap** — [Roadmap](ROADMAP.md) — open work and the gates that hold it. The only
  place "what is next" is written down.
- **survey** — [Keyless and free-no-account coverage survey](reference/free-providers-survey.md)
  — the free-provider coverage question, answered as one dated verdict per candidate,
  with the tier-1 test and the parsers the 2026-10-13 no-scrape rule rejects.
  `providers.md` keeps the per-candidate records its code citations point at; the
  verdicts are here.
