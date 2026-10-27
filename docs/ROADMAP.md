# Roadmap

Open work on seekwright: status first, detail behind links. Closed
history lives in `git log`; the docs map is [index.md](index.md), where each
page's job is named.

The first release's deferred list is the set of **Out** verdicts the sections
below carry, each held by the section that owns the thing: §1 (PyPI.org, a moving
`latest` image tag, and a multi-arch image), §3 (the gold-set A/B harness), §6
(routing by task), §9's coverage question (a keyless extraction endpoint) and §11
(the two module splits). The verdicts are the freeze audit's, dated 2026-10-19,
re-run against the frozen surface on 2026-10-20 with no verdict moved. Where an
item would move a name the freeze fixed, its line says so: that is a new decision,
not a clean-up.

## Where this stands (2026-10-10)

v0.1 is in public incubation: `search` and `fetch` are live and used daily, and the
project is looking for early adopters (see the README's status note). The operation
set has since grown to three — `answer` (§8) — so this snapshot is a record, not the
current count.

## Open work

The plan for the first release lives on the tracker. The `v0.1.0 feature freeze`
milestone closes on 2026-10-23; its audit is the freeze audit dated 2026-10-19, and
the surface it freezes is what [reference/surface.md](reference/surface.md) manifests.
The `v0.1.0 release` milestone follows, closing 2026-10-27: its deferred list is the
**Out** verdicts above, its wrap-up record is
[reference/publishing.md](reference/publishing.md), and pushing `v0.1.0` at `main`'s
head is the release act itself — guarded by the tag against `main`'s head and the tag
name against the version it built.

### 1. Distribution — a published image and/or a PyPI package

The release lane exists: `.github/workflows/publish.yml` builds the wheel and an amd64
image on a `v*` tag push, files the wheel as an asset of the GitHub Release the tag
names, and pushes the image to `ghcr.io/leoschwarz/seekwright:<tag>` (2026-10-27). It
fails before writing anything when the tag names a commit `main` does not name, when
the tag is not `v` plus the version it built, or when the release already holds a
*different* file under the same name; the release gate reads that run's colour as the
artifacts resolving, as of 2026-10-20. `docs/reference/publishing.md` is the procedure
around the workflow.

What stays open is PyPI.org: no `uv publish` step and no PyPI API token, so there is
no bare `uvx seekwright` spawn, and the documented install stays the clone plus
`uv sync`, gated on that step. A moving `latest` image tag is open too: the lane
publishes the tag name and nothing else. A multi-arch image is open; the decision
settled on amd64 rather than fighting QEMU emulation on the runner. All three are
**Out of 0.1.0** (freeze-audit verdict, 2026-10-19), and this section is where that
verdict is held. The Containerfile stays the source of truth for the image either way.

### 2. Cost evaluation

The aggregation half exists: `GET /dashboard` (backed by the append-only usage
journal, `[dashboard] history_path`) reports spend and usage across calls. What
remains is evaluation rather than counting: **drift** between the returned costs and
the "as of" prices in [providers.md](reference/providers.md). Tavily reports actual
credits as `reported_cost_usd` beside the estimate, but both figures come from the
same local `cost_per_1k` (`TavilyProvider.search`, `TavilyProvider.cost_for`), so the
pair checks the **credit count**, not the price; it is log-only, absent from the
journal. Pricing the fetch fallbacks has landed: a page the paid fallback served
records that fallback's *declared* per-call price on its journal line
(`[fetch] cost_per_1k`, default Scrappa's `0.30`/1k), and the dashboard reports the
total — absent, never `0.0`, for a page nothing billed
([metrics.md](reference/metrics.md)).

### 3. Defaults by measurement, not judgement

The caps (`max_snippet_chars=500`, `max_result_text_chars=2000`,
`min_text_chars=200`), `max_results=5` and the `scrappa` default were all set by
argument; none has been measured. The gold set — queries scored by the caller's
follow-up task, extraction, lookup or answering, never one blended leaderboard — is
operator-local scratch: its harvest, replay, scoring and export tooling left the
published tree on 2026-10-26, and the dataset was always operator-private, the
encoded export `gold.toml.b64` dropped for the first release (2026-10-21) and
untracked on 2026-10-22. Open gates on that harness before its numbers move a
default: human calibration votes against agent verdicts (the export read on
2026-10-21 held `185` agent-judged rows and no human ones); a floor on `n` per task
class rather than "a bigger n"; and queries for the `extraction` class.

The **Out of 0.1.0** verdict (freeze audit, 2026-10-19): the harness informs no 0.1.0
default — a measured ranking moves a value, not a name — so the release ships its
caps, its `max_results = 5` default and its `scrappa` default argued rather than
measured. A second run waits only on a release cycle spent on measurement.

### 4. Model-facing candidates

Both fields reach the surface by contract: **safe-search is a boolean**
(`safe_search`, `True` / `False` / `None`, deliberately no level scale) and
**language is `locale` renamed**, already mapped onto every backend's language
parameter. Both sit on the tool surface (`search` and `answer`) and the REST body,
with no config default: every adapter that cannot honour a field says so in `notice`,
and which names honour which field is
[reference/provider-contract.md](reference/provider-contract.md)'s derived capability
table rather than a count restated here.

**Built**, with `SearchResponse.answer` passthrough in place for answer-capable
backends. `country` stays off the surface: geo is its own decision, and §4 did not
name it.

### 5. Spend/call ceiling — declined 2026-10-14

*Kept in this list only because §5 is cited by number from `AGENTS.md` and from
several `reference/` pages — the number is the citation, so the heading stays; the
item itself is off the roadmap (see the deliberately-not list below).*

Decided against. A ledger with no caller identity can only enforce one
deployment-global ceiling, so it is not the precondition for multi-user hosting
(**auth** is, and auth is on the deliberately-not list); reserve-then-reconcile is
the shape a deployment with concurrent writers needs while this one has a single,
event-loop-confined writer; and `cost_usd` is a declared figure no channel in the
tree can verify against a price change, which makes a hard refusal an outage priced
on an unverified number.

Four triggers reopen it, any one alone: auth on the listener being committed; a
measured declared-vs-invoiced comparison with enough n to state a tolerance; a real
overspend the dashboard did not catch in time; or a second operator actually being
pursued (§7, §8). If it is built it should be **the journal**, not a second store:
the append-only lines already carry per-call `cost_usd` with the provider or fallback
name and a third `answer` kind with `model_cost_usd`, so a rolling window needs no
new format where `[dashboard] history_path` is set. The serving-path read exists too
— agent mode's `max_cost_usd` aborts a call on the RAM aggregate mid-dispatch
(`search_cost_usd`) — so a ceiling extends that reader over a window. Nothing here
forecloses the work; it defers it behind those triggers.

Where a section below cites §5 as a gate, the gate is now **auth** — a per-caller
budget needs auth *and* a ceiling, and a caller-declared route that cannot bill
needs neither.

### 6. Routing modes

The two modes asked for in October 2026: the free-only route is in the tree;
routing by task is still declined, gated on §3's controlled numbers rather than a
spend ceiling.

Out of 0.1.0 (freeze-audit verdict, 2026-10-19): it is the reserved second member
of `search.mode`, so adopting it moves a frozen value set and arrives as a new
decision.

**`search(mode="free")` — accepted and built 2026-10-13.** A
caller-declared route served only from providers that cannot bill, which
fails rather than escalating.

- **The set** is a constant in `config.py` beside `PROVIDERS_REQUIRING_KEY`:
  `exa:free`, `parallel:free`, `freeserp`, `searxng`, `tinyfish`. It is a fact about
  the adapters (no key, or a call free at any balance), not about a deployment, and
  nothing config-derived may reach a schema.
- **The walk** is `[search] free_fallback` when set — each name enabled, each name in
  the free set, no duplicates, a paid or unknown name a startup error, the shape
  `search.fallback` validates — and otherwise the enabled free names in a constant
  declaration order (keyless fallbacks first, then `tinyfish`). Each fallback at most
  once, an open-circuit one skipped with a line saying so, `default_provider` not
  consulted: the caller asked for a class, not the default.
- **The ending**: every fallback failed → the *first* fallback's error raises with the
  failed fallbacks appended, and the advice says the mode is why nothing paid was
  tried. A rate-limited fallback is an ordinary failure, recorded on the health board
  so the breaker gates it for the cooldown. No free provider enabled → a clean refusal
  naming the set, the way `[fetch] enabled = false` refuses rather than the tool
  disappearing.
- **The surface**: `mode: Literal["free"] | None` on `search`, mutually exclusive with
  `provider` ("pass `provider` or `mode`, not both"). `"task"` is the reserved second
  member, deliberately absent until the gates below clear.
- **Honesty**: the response names the serving provider, and the walk adds its
  substitution to `notice` in the existing wording. `mode` binds on `search.ok` always
  (None when unset) so that line keeps a fixed field set. The tool description and
  `SERVER_INSTRUCTIONS` say what the mode is and that the free names are the
  rate-limited, weaker ones.

§5's ceiling is **not** a gate for this mode — it cannot spend.

**Routing by task — declined, gated.** It waits on §3 (there is nothing to route on
until the gold set's per-task numbers read) and on the price-naming question §5 was
standing in for: it picks a provider the caller never named, at a price the caller
never named. With §5's ceiling declined (2026-10-14) that gate is not coming, which
leaves the free-set-restricted version as the only form that clears without a new
decision. The shape it must take when it lands: a caller-*declared* `task`
(`extraction`/`lookup`/`answering`), never inferred from query shape. Restricted to
the free set it could never bill, so §3 alone would gate that version — the smallest
honest form of the request, and the one to try first.

### 7. The public API's second encoding — a REST projection and a CLI client

**Built.** [reference/public-api.md](reference/public-api.md) settles the encoding:
a REST projection (`POST /api/v1/search`, `POST /api/v1/fetch`, `POST /api/v1/answer`
— `server.py`'s `api_search` / `api_fetch` / `api_answer`) on the existing `--http`
listener, and `seekwright search` / `seekwright fetch` / `seekwright answer` as a
Python client of it (`cli.py`'s subcommands). Both are additive — `/mcp` and
`--http` are unchanged for existing clients — and neither adds auth: the REST API is
single-operator, and multi-user stays gated on **auth**, which is on the
deliberately-not list; §5's ceiling was declined 2026-10-14 and was never the first
gate.

### 8. Agent mode — the third operation

**Built.** Accepted as a third operation, `answer`, off by default
(`[agent] enabled = false`), with its contract in
[reference/agent-mode.md](reference/agent-mode.md).

The shape: a **fixed** retrieval plan — the caller's query plus up to two extra
queries, five results each on the default route, up to three pages read through the
existing fetch ladder — feeding one operator-configured model, which writes prose the
server grounds by validating its citations against what it actually retrieved.
Bounded per call by arithmetic rather than a ledger, and single-shot: one model call,
no streaming, no session, no state.

Its gates and its boundaries:

- **§5 is not a gate for the per-call bound** — that bound is arithmetic (≤3
  searches × 5 results × ≤3 pages, material and output capped), which is why the
  decision could be taken before §5 was decided. §5's ceiling is now declined
  (2026-10-14), so offering agent mode to more than one trusted operator is gated on
  **auth** — and on a per-caller budget, if that is wanted, which would need the
  ceiling §5's four triggers describe. The spend is visible without either:
  `record_answer` writes an `answer` line carrying `model_cost_usd` beside search and
  fetch, so a future ceiling reading the journal would see it as a third kind.
- **§3's gates stand.** Agent mode produces a live *answering*-task signal
  (per-provider retrieved/cited, recorded content-free on the existing usage journal)
  that is an input to defaults and to provider choice — not a replacement for the gold
  set, which scored against keys a human verified. The 2026-09-29 rejection of
  in-server capture is untouched: counts, not content.
- **Not in this decision**: routing agent mode through §6's free-only route (`free`
  caps the retrieval, not the model, so combining them would advertise a free call
  that bills); multi-turn state; a model-driven retrieval loop; per-caller quotas or
  budgets (auth, still declined).
- **Open questions a future entry has to answer**, not this one: whether a second
  model is worth supporting, whether the model's own endpoint deserves a circuit
  breaker, and whether the citation signal is good enough to move `default_provider`
  without §3's controlled numbers.

*Numbering note:* agent mode is §8 because §6 and §7 landed before it, and it is cited
as §8 from `AGENTS.md` and `reference/agent-mode.md`; renumbering means repointing
both, which is why the number is a constraint.

### 9. Onboarding tiers — keyless first run, free-with-key, paid, and the allow-list

Maintainer directive, 2026-10-14: four layers of onboarding — (1) free and auth-free,
usable "right away with minimal churn", with the server picking among what is
available; (2) free options that need keys, walked through a quickstart; (3)
paid APIs; (x) "at all times ... an allow-list based set of what they allow". All
four are in the tree, each carried by a page below.

- **Tier 1 — keyless, no account:** `exa:free`, `parallel:free` and `freeserp`, two
  rate-limited anonymous halves of paid endpoints and one keyless whole-web index.
  This is also the install default: an empty `[providers]` block is that set, and a
  bare `search` with no `default_provider` walks it — the `mode="free"` walk, so no
  fallback can bill — rather than erroring; one enabled name that can bill restores
  the old refusal. [quickstart.md](quickstart.md) §1.
- **Tier 2 — free with a key:** `tavily`, `scrappa`, `algolia`, `search1api`,
  `serpapi`, `querit` and `tinyfish`, plus keyed `exa`/`parallel`, which spend their
  anonymous halves before the key does (`TieredExaProvider`). A metered allowance is
  a price with a delay on it, so the six metered names are out of `FREE_PROVIDERS`
  and `mode="free"` never reaches them; `tinyfish` is in that set because its call is
  free at any balance. [quickstart.md](quickstart.md) §2; figures in
  [reference/providers.md](reference/providers.md) §"Cost and free-tier summary".
- **Tier 3 — paid:** `serper`, `linkup` and `deepseek`, the tier-2 names past their
  allowances (`scrappa`, `search1api`, `serpapi`, `querit`), keyed `exa`/`parallel`,
  and the paid fallbacks behind `fetch`. [quickstart.md](quickstart.md) §3. Nothing
  open.
- **Tier x — the allow-list:** `permitted_providers`, a permission set over provider
  names reaching search, agent mode's retrieval and `fetch`'s paid fallback:
  deny-by-default once declared, `enabled ∩ allowed`, unset permissive, refused
  before dispatch, reported by `--check`.
  [reference/allow-list.md](reference/allow-list.md) is the contract. Nothing open.

**The coverage question.** Whether the tree is leaving free coverage on the table is
answered by a survey issue, not an implementation one. It checks candidates upstream
against tier 1's own criteria (no account, no key, no card, and an actual contract),
recording each one's endpoint, auth, limits and free-tier terms with its policy
verdict, and catalogues the results-page parsers the 2026-10-13 no-scrape rule rules
out as a rejection rather than queued work. `fetch` is outside that rule, so a
keyless extraction endpoint (Jina Reader) is a legitimate tier-1 candidate; the
survey's verdict, not this section, decides whether anything is adopted.

Out of 0.1.0 (freeze-audit verdict, 2026-10-19; cost re-measured 2026-10-26): a further
keyless extraction endpoint lands as another name in `KNOWN_FALLBACKS` — the set the
freeze held at three, which the 2026-10-25 exception moved to five, Jina Reader being
one of those five.

**Gates.** Nothing here waits on §5's ceiling, which is declined (2026-10-14) and
which nothing free-only needed in the first place. The default route is gated on
nothing. The quickstart document is gated on not inventing a published install
path — §1, the distribution item, is open, and the install-path questions are
tracked in the project's issues rather than here. Tiers 2 and 3 are
documentation only.

### 10. More fetch providers, and the tier they need

The ask, in three parts: more fetch providers; the trafilatura dependency handled
separately from the tool; and egress control kept under either a self-hosted or a
shared service. The scouting half is answered in
[reference/providers.md](reference/providers.md) §"Fetch endpoints among the in-tree
providers (2026-10-23)": ten of the seventeen provider names this tree calls answer at
an extraction endpoint, two of them keyed by a credential `[providers]` already reads.
The shape is settled in
[reference/fetch-provider-selection.md](reference/fetch-provider-selection.md), and
the split that followed -- five implementations -- has landed on it: 0.1.0 is not
held fixed (2026-10-25), so the frozen value sets moved the way
[reference/surface.md](reference/surface.md) says a frozen name moves.

- **The freeze exception** -- answered 2026-10-25. `fetch.fallback` carries five
  names and `KNOWN_EXTRACTORS` two, each move recorded rather than slipped past.
- **An extraction backend** needing no library: `extractors/stdlib.py`, so a bare
  install keeps `fetch` instead of exiting at startup.
- **A fallback registry** -- `KNOWN_FALLBACKS`, one row per fallback declaring its
  name, whether it can bill, the endpoint it dials and how to build it. The paid-last
  rule reads that declaration instead of naming `scrappa`, and a new vendor no longer
  widens a `Literal`.
- **Per-fallback pricing** -- the fallback that served the page declares its price
  (`ContentFetcher.cost_per_1k`); still open is a per-fallback *override*, since one
  `[fetch] cost_per_1k` prices whichever fallback bills.
- **The two keyed fallbacks** -- Tavily extract and Linkup fetch, on the credentials
  and the permission-set entry the deployment already has.
- **The egress hole** -- a fallback an operator configures by URL is answered for in
  that operator's strict list, and `--check` names the host it cannot derive.

The redesign asked for on 2026-10-25 is in the tree too: fetch fails the way an
empty search does, handing back the configured names to pick from instead of walking
the ladder out of sight. `fetch(provider=…)` names the fallback, `fetch.auto_fallback`
defaults to false, the ladder is `fallback` in prose, identifiers and journal alike
(`rung` was the old field), `fetch.primary` puts a provider in front of the local
read, and `permitted_providers` admits the keyless `jina` through the fetch-only
`PERMITTED_FETCH_NAMES`, so a declared set keeps that fallback by listing it. Both
moves are recorded in [decisions.md](decisions.md).

**Gates.** Nothing here waits on cost data, and nothing waits on §5's ceiling,
which is declined. The freeze exception is answered, so a further fallback now
costs one registry row, its endpoint constant and a value-set move -- not a decision.
A per-fallback price override would want the serving fallback on the journal line
or on `FetchResponse`, both of which are frozen sets, so the open half asks rather
than adds. The `fetcher.py` split keeps its existing home and its existing verdict
(Out): §11 below.

### 11. The two module splits the freeze audit left out

**Out of 0.1.0** (freeze-audit verdict, 2026-10-19). Both are candidates the
2026-10 refactor survey ranked — candidate 7 and candidate 8 — whose figures are
inlined at each bullet, that survey no longer being a page in this tree. What this
page holds is the verdict and the cost of moving one:

- **`fetcher.py`, split along the `extractors/` convention**: 971 lines, 34 defs and
  four backends under one name at the survey's 2026-10 measurement, grown past 1,600
  lines since with two more fallback rows. It holds the whole SSRF surface plus every
  fallback class and the `KNOWN_FALLBACKS` registry. Out on purpose — the split moves
  the import surface, and a release milestone lowers the tree's risk rather than
  raising it.
- **`cli.py`, its `--check` diagnostics separated from its REST client**: 1,260 lines,
  31 defs and `main` at cyclomatic complexity 22, all measured then (nearer 1,330
  lines now).

The hazard on the second one is the freeze, not the size: two frozen name groups live
in `cli.py` — the three client verbs and the ten server flags — so whoever splits it
moves `tools/surface.py`'s read table in the same PR, and the manifest at
[reference/surface.md](reference/surface.md) has to come out byte-identical. Neither
split waits on data; each waits on a decision to spend a release cycle on structure.

## Deliberately not on the roadmap

Auth on the listener, a cache, a **spend/call ceiling** (declined 2026-10-14, with
its four reopening triggers — §5), and "pick the cheapest" fallbacks. **A router**
came off this list in one scope on 2026-10-13: a caller-declared route restricted to
providers that cannot bill (§6). A second scope followed on 2026-10-14 (§9): the
*install default*, restricted to the same free set, so a deployment that enables
nothing that can bill has a bare `search` served from it — the route exists only
where it cannot spend. Routing *by task* stays off until §3 clears (§5 is declined —
2026-10-14 — so the ceiling it was waiting on is not coming). Two items were pulled
off this list on 2026-09-29 by maintainer decision: **new providers** — searxng,
tavily and tinyfish landed together as a free set (duckduckgo landed with them and
left again on 2026-10-13) — and the **model-facing freeze**, since the `recency`
filter landed 2026-09-29 and safe-search and language 2026-10-14, leaving §4 no
candidate undecided or unbuilt. **A model inside the server** came off it on
2026-10-13 by maintainer decision, in a scope narrow enough to leave the serving path
stateless, the two tools untouched and the cost bounded by arithmetic (§8).
**A corpus- or news-scoped operation** — FreeNewsAPI and anything shaped like it —
is declined (2026-10-14) and was put off again by the maintainer on 2026-10-18. A
home for it is a four-name change to a surface now frozen: a fourth tool, a fourth
route or a fourth `search.mode` member, a fourth client verb, and its own config
keys. **A provider with no endpoint** is off the list for a blunter reason:
`serpdive.com` has no A or AAAA record and both of its API hosts answer NXDOMAIN,
so SERPdive closed not executable on 2026-10-18 — no endpoint to add, no key to
store. `querit`, the other name that ask named, is in the tree. Each removal above
says what was taken out and why; reversing one is a decision with its own argument,
not an oversight, and it is made where the rule lives.
