# Decisions

What this tree has decided, and what it rejected. The living contract is
[`architecture.md`](architecture.md) and the pages under
[`reference/`](index.md): those state their own rules and reasons, and nothing in
`src/`, `tests/` or `tools/` cites this file. What stays here is the decision
itself — what was chosen, which alternatives cost something to refuse, and what
evidence would reopen the question. Read it before reversing one of these;
re-deriving that the obvious alternative was turned down from the code alone is
expensive.

One entry per decision, newest first, a few lines apiece: the choice in the first
sentence, what it cost, and the page that now owns the rule. A reversed entry
stays with its reversal noted. Process bookkeeping (a run's census, an
instrument's own measurements, a file move) is not a decision and gets no entry.

Entries sit newest-first at the first `## <date>` heading, and when two
branches each prepend an entry, the resolution is to keep both entries in
date order (newest first) and to make no other edit to either entry.

## 2026-10-28 — Two Agent Skills: a skill is an adapter to the deployment, never a second implementation

Two pages under `skills/`, markdown only: `skills/seekwright` drives the REST
projection of a listener the operator already runs, `skills/seekwright-deploy`
installs, verifies and debugs one. A skill cannot be the service -- it holds no
engine, no config and no key -- so the split is by install grant, not by topic: a
caller handed a URL is never handed the install path, and the usage skill's refusal
of container, key and publish vocabulary is machine-checked rather than asked to be
polite (`tests/repo/test_skills.py`, whose remaining rules read the frozen surface
from `tools/surface.py` and refuse a flag, route, provider name or environment
variable the tree stopped carrying). The operator half travels as commands a human
watches run, because the blast radius of a bundled script is that machine and every
one of its commands is already a documented one-liner. Each directory is
self-contained -- no `references/`, no link reaching `../` -- because the directory
is the unit of distribution, which is also why a pointer to `deploying.md` or
`public-api.md` is prose and not a link. Distributing one usage skill to several
operators is the multi-user question `VISION.md` gates on auth, not a hardening task
these pages take on.

## 2026-10-27 — The release lands where the reader can reach it: one CI lane, GitHub Release and `ghcr.io`

The merge gate existed twice: a copy that ran, and a copy written for the private
forge this repository was developed on, whose release lane was the only thing that
ever built a release artifact. The second copy is deleted -- gate and release lane
together -- and both roles now sit in `.github/workflows/`. The gate is one file
with three jobs, `check`, `wheel` and `container`, the two build jobs compiling the
artifacts the release ships and writing nothing: their image tag is unqualified, so
no registry is reachable from that file, and measuring an artifact no longer costs
publishing it. The release is a tag push: the wheel becomes an asset of the GitHub
Release the tag names, and the image goes to `ghcr.io`.

Refused: the private instance's own package registry -- a PyPI-compatible index and
a container registry at a machine-local address -- as the release destination. Every
URL it hands out resolves only on the machine that hosts it, while `[project.urls]`
already named GitHub, and an artifact only the operator can pull is not a published
artifact. The guards that read the deleted lane by path went with it: the
clone-credential guard is deleted outright, because the runner now hands the
checkout to the job and no step clones with a secret, and the rest read
`.github/workflows/`.

`reference/publishing.md` is rewritten for that lane, and
`reference/refactor-survey.md` left the published tree beside the guards that used
to recompute its census: a dated survey whose figures describe no reachable tree is
a stale document, not a record. That is one page deleted for a reason, not the
2026-10-26 pass's no-path-change rule reversed -- that pass moved and renamed
nothing, and nothing here moves or renames a page that stays.

## 2026-10-26 — The public-release docs pass: audiences separated, history to the record, one owner per fact, no path renames

The documentation tree was reorganised for the public release on four
principles, and the fifth decision — the one that made the other four edits
rather than moves — was **not to rename, move, add or delete a page**. Every
path under `docs/` stays where it is.

What changed in place:

- **Audiences separated.** `docs/index.md`'s page list is grouped by who a page
  is written for — the way in, the operator, integrators and contributors, the
  maintainer, and the dated records — instead of by where the file sits. A page
  that mixed contract prose with run history lost the history.
- **History out of the contract pages.** Card tables, per-commit checklists,
  census figures, pasted transcripts and "what this replaced" sections left the
  pages that state rules. Dated records are never "fixed" for staleness: this
  file, the 2026-10 refactor survey (kept outside the published tree),
  `reference/typing.md`'s section on the previous type checker and
  `reference/free-providers-survey.md`'s findings stay as written.
- **One owner per fact.** Prices live in `reference/providers.md`, the `[agent]`
  keys in `reference/configuration.md`, the frozen names in
  `reference/surface.md`, client-registration blocks in `configuration.md`,
  adapter conventions in `reference/provider-contract.md`, per-name capability
  facts in `providers.md`, ladder hazards in `reference/fetch-safety.md`, and
  dashboard and journal behaviour in `reference/metrics.md`. Every other site is
  a pointer, so the second copy cannot drift.
- **Public voice on the way in.** Instance addresses, account names, run-token
  mechanics and "answers 404 until published" notes left README,
  `quickstart.md`, SECURITY and CONTRIBUTING. The only documented install path
  for 0.1.0 is the clone plus `uv sync`, because nothing is published to PyPI or
  to a public registry; the build-and-run details moved to the maintainer page.

**Why the paths stayed.** Page paths are cited from `src/`, `tests/` and `tools/`
docstrings and constants — `Path` joins among them, which a filename grep cannot
see — plus `tools/surface.py`'s manifest, the `[project.urls]` documentation
link, the front-door markdown and the dated entries in this file; **no check
reads any of them**. A rename therefore costs a
sweep that cannot be verified, and it silently changes what a dated entry points
at. Consolidating in place costs nothing of that, and the map — which *is*
checked, one link per page — is where the grouping a reader needs is stated.
`AGENTS.md` states the same rule and the reason for it.

## 2026-10-26 — Documentation names symbols; the line-number cite and its checker go

No documentation file in this repository carries a code line number. The address a
page gives for a fact about the code is the **symbol** — `UsageRecorder._append`,
`KNOWN_PROVIDERS`, `[project.urls]` — or, for prose in another page, that page and
its section; for a config file, the key or the table.
`tests/repo/test_doc_cites.py` refuses a `file.ext:NNN` cite in `docs/` and in the
front-door markdown, and `AGENTS.md` states the rule.

What is reversed is the answer this repository gave first. `tools/doc_cites.py`
resolved every cite in `docs/` against the checkout as a `--check` step in both
copies of CI, and the 2026-10 refactor survey's first open question asked whether
the citations stay on that footing or move to symbols. Resolving is not being true.
A pointer that lands inside a 1,500-line module tells a reader only that the module
is that long, and the tree was full of cites that had already rotted: ones sitting
on a blank line, on an import, or on a docstring two definitions away from the thing
the sentence claimed. The survey recorded three; the sweep found 32. A number is not
an address — it moves whenever anything above it is edited, and no check can tell a
reader that it went stale — while a symbol names the same code the day the code
beside it is rewritten. That is the property the same survey noticed on the pages
that had names instead of numbers, and it is why the fix is the names rather than a
better resolver.

Deleting the tool is the honest half of it. Its machinery — path lookup against four
index roots, the range classes, the named exemptions carried with their reason, the
exit code for a scan that found nothing — existed to serve pointers that no longer
exist, and a prohibition has nothing to resolve. What replaces it is the shape
`tests/repo/test_decision_cites.py` already uses for the dated-cite ban: a pattern
over the pages, every offending line named in the failure, and a check that the
population is not empty, because a guard that reads nothing passes silently. The
pattern's blind spots are written down in the file that holds it: a bare `` `:NNN` ``
continuation and prose that says "line 379" stay a hand audit, and the extension
whitelist is what keeps a host and a port out of the ban.

The cost is worth naming. A symbol is not a location: a reader following
`_walk_fallbacks` searches for it, and a page that describes a sequence inside one
long function can no longer point into the middle of it. The tree accepts that — a
pointer a reader has to resolve can still be true, and one that reads as precise
while landing on a blank line is worse. The 2026-10 refactor survey's first open
question closes with this entry; its own pointers went with it.

## 2026-10-26 — `fetch.primary` names the default route; `jina` joins the permission set; the journal field is `fallback`

An unnamed `fetch` leads with the route the operator names, `[fetch] primary`,
whose default `http` is this server's own reader. What made the key worth
freezing is a difference in what a page sees: the local read goes out from this
server's IP with a plain HTTP client, which more bot walls recognise than a
provider's network or a rendering provider's real browser, while the same
route is the one that hands the URL to a third party and, for the keyed ones,
spends a credit. Which of those two to lean towards is a property of the
deployment, not of the code, so the code asks. A fallback name makes that
provider the first attempt and takes the local read out of the unnamed route
entirely rather than leaving it behind as a last resort: the operator who sets
the key is saying this machine's own address should not be what a page answers,
and a route that returns there when the named one fails is that decision
unmade. The walk behind the primary is `fetch.fallback` minus the primary, so
the name that just failed is never tried twice nor offered back in the failure
sentence, and `build_fetch_stack` builds the primary even when `fetch.fallback`
does not list it — naming a route is naming a provider this deployment runs,
and requiring the same name in two keys would only let them disagree. Any
registry name is admissible, billable ones included: the tier rule governs the
ladder, which still puts a priced name last, not the route that leads, because
a billable primary is the operator paying a stated price for every unnamed
fetch on the same ground `search.default_provider` already allows. An
unbuildable primary — no key, no `crawl4ai_url`, refused by
`permitted_providers` — stops the server at startup naming `seekwright
--check`; substituting the local reader would be the same silent reversal the
key exists to prevent. The tool surface is unchanged: `provider` still takes no
`"local"` value and nothing new reaches a caller, so the choice stays the
operator's. `reference/configuration.md` owns the key and
`reference/fetch-safety.md` the tradeoff.

This supersedes the "there is deliberately no fetch-provider default" refusal
in the five-fallback entry below. That argument was that the ladder no longer
walks a name the operator chose, so there was no cheaper name to fall back to;
what it did not consider is a route rather than a fallback — a default that
does not add an attempt, which is what `fetch.primary` is.

`permitted_providers` can now name `jina`, beside the provider names, through
`PERMITTED_FETCH_NAMES`. The set had already grown to gate the fetch
fallbacks as well as the search names, and one name fell through that: `jina`
is a third-party reader and not a provider, so every declared set excluded the
one keyless proxied route with nothing the operator could write to keep it,
which made "declare a set" and "keep the keyless fallback" mutually exclusive.
Membership is narrow on purpose: `KNOWN_PROVIDERS` is untouched, a
`[providers.jina]` table is still a startup error, and `jina` appears in no
search routing, so admitting it enables nothing on the search side.
`reference/allow-list.md` owns the site.

The usage journal's fetch field is `fallback`, and the dashboard total beside
it `fetch_pages_via_fallback` — the last place the old word for a ladder entry
survived, since the field is read by machines rather than read by a person. No
dual read and no migration: a line written before the rename simply stops
folding into that total, because a key an older line lacks is absent, not zero,
and nothing else about it is affected. That is cheap to accept on the recorded
basis that no journal has ever been released — 0.1.0 is the first release — and
the alternative was a reader that tolerates two names for one field forever.

The config-key freeze moves by this entry and `reference/surface.md` is
re-printed with the eighteenth `[fetch]` key. No frozen value set changes
membership: `KNOWN_FALLBACKS` already holds every admissible primary, and
`"http"` is a single constant rather than a set.

## 2026-10-26 — The type gate is `ty` alone; the pinned pyright fork leaves the tree

`basedpyright` is off the dev group, its `[tool.pyright]` block is gone, and the
gate is `uv run ty check` over one pinned `ty`. Two measurements in the agent
container forced it: a full `basedpyright` run did not finish in 600 s (its Node
process at ~2 GB RSS, still climbing past 10 CPU-minutes at the same head),
while `ty` 0.0.92 checked that head in 0.489 s and reported exactly the four
`ctx: Context` sites that the ported rules were expected to flag. What the swap
gives up: the untyped-boundary rule family (`reportAny` and its seven
siblings — all switched off here anyway, so no coverage moves) and
`reportUnnecessaryComparison`, for which `ty` has no rule at all. The contract
and the rule-by-rule rationale are
[`reference/typing.md`](reference/typing.md).

## 2026-10-26 — The word for a ladder entry is `fallback`

One vocabulary across the five places a ladder is named: `search.fallback`,
`fetch.fallback`, `fetcher.fallback`, the `fallback` tool parameter, and
`FetchFallback.provider`. In the fetch path, `provider` means the fetch
provider the *caller* named, not the backend the server reached. Renaming the
rung's config key was a change to a frozen name, so it travels with this
entry; the contract is
[`reference/fetch-provider-selection.md`](reference/fetch-provider-selection.md).

## 2026-10-26 — `fetch.fallback` is five rungs, and `fetch` has no provider default

The rung set widened from three to five because `tavily` and `linkup` were
adopted as fetch backends and simply never joined the frozen set; the gate had
no way to notice. Membership is a config edit — what stays frozen is the
behaviour around it: validate the set, order the paid rung last, walk only on
an empty or truncated result. The pinned baseline for the six frozen sets is
`tools/value_sets.json`, and the check that keeps it honest runs in CI before
the tree can drift from it. There is deliberately no fetch-provider default
key: the ladder no longer walks a name the operator chose, so there is no
cheaper name to fall back to, and adding one would be a behaviour change
needing its own entry.

## 2026-10-25 — `fetch` names its provider; the ladder stops walking itself

`fetch(provider=…)` chooses the backend, empty means the local fetcher alone,
an unknown name is refused before anything is dialled, and `fallback` is the
one name the ladder may substitute for that choice. A silent walk fails a
caller who cannot act — it is their key, their instance — and spends a credit
they did not choose. Rejected: a configured default rung (a name chosen on the
caller's behalf), narrowing the parameter to the configured subset (the schema
is frozen at import; a free-text parameter is what makes the set extendable
without a release), and keeping the old meaning of `fallback`. A
`mode="free"` search does not restrict `fetch`: a configured ladder is the
operator's decision, and the free half of it is the keyless rung, which cannot
bill.

## 2026-10-25 — A frozen name moved on 2026-10-21 without an entry

`[search] search_provider` → `provider` (2026-10-20) and `fetch_rung` →
`fetch.fallback` (2026-10-21) were renames of frozen names, and the entry the
freeze asks for did not exist until this one. The lesson is the machine check,
not the scold: the six frozen sets are compared against
`tools/value_sets.json` at merge time, and `--write` re-deriving a baseline
from the tree is exactly what the comparison must never do.

## 2026-10-24 — Release artifacts are built by the lane that gates merges

One lane, one checkout: the merge gate builds the wheel, the sdist and the OCI
image and pushes the tag when they succeed. Two lanes were rejected because a
tag would then point at a checkout no gate had verified, and an unverified
artifact would carry the tag's name. [`reference/publishing.md`](reference/publishing.md).

## 2026-10-24 — A rung configured by URL is cross-checked, never rendered

The egress lists render the constants `src/` dials and name as *configured by
URL* the rungs that point at a service the operator installed rather than a
literal address. The deployment's own TOML is never read: the lists carry no
secret, and rendering from it would compare a deployment with itself instead of
comparing the code with the network policy. A hardened fetch bundle therefore
refuses a rung named nowhere — it cannot allow a host it cannot name — and says
so at startup rather than refusing the connection later.

## 2026-10-24 — The walk, not the parse: what a JSON page costs once its printing is bounded

`fetch(path=…)` walks the tree with a grammar of four constructs, stdlib only.
A JSONPath or JSONPath-like library was rejected: `path` is a selector over a
document the server already holds, and the walk is a dozen lines of `ast`-free
code with a sentence to explain at review. Recursive descent (`..`) and filters
(`[?(@.price<10)]`) stay declined — they need a library or an interpreter, and
`query` already covers the searching half. Both are refused with a message
rather than answered as "no matches": the difference between "this document has
no such node" and "that was never a question" is the whole value of the error.
The media *family* is open (`+json` included, because an API's type may name a
format this server cannot extract while the body is still JSON); whether a page
is JSON stays closed to declared types, because guessing from `text/plain`
would push a config file or an error page through the path grammar and return a
tree where the caller wanted prose. Bounds: walk depth 100, 4× the document
size with a floor of 8000 characters — a 20-node document must not be
truncated at 250.

## 2026-10-23 — Image bytes reach a caller only when the operator says so

`fetch.allow_images` is a config key, not a tool parameter: the calling model
must not be able to raise its own context limit, and the cap on page text and
the floor on emptiness already share one key for the same reason. Four types,
identified by sniffing the bytes rather than trusting a header, because a page
that sends one image as `text/html` is the most common way a text reader
answers; no SVG, which is a text format carrying script. Images are never the
ladder's business: a rung that answers in prose cannot supply pixels, and
dialing a paid fetcher for an image bills for something the caller already
has. [`reference/fetch-safety.md`](reference/fetch-safety.md).

## 2026-10-23 — `fetch` is three seams, not one

What may be replaced: the **fallback** (a different network path, answering in
page text), the **extraction backend** (a different parser), and **egress** —
which belongs to the network, not the application. A fetch provider is never
written as an extraction backend: an extraction backend's whole job is parsing
untrusted bytes, and a network call does not belong inside it. A fallback
answers in page text, never in its own envelope — forwarding a vendor body as
`application/json` would break the JSON media-type rule and put a `path`
selection inside the vendor's response document rather than inside the page the
caller named. The tier rule (validate the set, paid rung last, a declared price
per fallback) is what let two further paid rungs land as config and a docs row.

## 2026-10-23 — The unit set ships, and the fetch deny-list is the default

One image, two containers, and the mounted config is the only difference: the
search role turns `fetch` off and names the providers it permits; the fetch
role sets `permitted_providers = []` and keeps `fetch` on. A second image, a
role flag and a per-role tool surface were all available and all rejected —
FastMCP freezes a tool schema at import, so a role switch cannot remove a tool
and can only make it refuse, and refusing with a clean error is the recorded
shape for "this deployment does not do that". The hardened fetch bundle denies
RFC1918 and CGNAT rather than enumerating loopback: the target is caller-chosen,
so the list is a default and not a boundary.
[`reference/deploying.md`](reference/deploying.md).

## 2026-10-23 — `fetch` gains `path`: a JSON document is fetched as structure

The grammar is dot access, subscript, slice and quoted key — the Python shapes
a reader already knows. One axis per call: `path`, `query` and `offset` are
mutually exclusive, which generalises the existing `query`/`offset` rule rather
than special-casing it. A selector the grammar cannot read is refused **before
anything is fetched**; a page with no structure to select from comes back whole
with a `notice`, because the page was already fetched and possibly billed.
Whether a page carries structure is the extraction's answer
(`ExtractResult.path_addressable`), never inferred from page text: a Makefile
begins `$ make all`, and a first character is not a type. `path` is deliberately
absent from the REST body — it is a parameter added after the freeze, and a URL
query string cannot carry brackets.

## 2026-10-23 — AGENTS.md names only what the published tree can honour

The agent guidance file travels with the checkout, so nothing in it may promise a tool,
a directory or a check the published tree does not carry: `.containerignore` drops
`tests/`, `docs/` and `tools/`, and `uv_build` packages only `src/`. A consumer who
installs the wheel and reads a rule about an instrument that is not there has been given
a rule they cannot verify, which is worse than no rule.

## 2026-10-22 — The default deployment is the image, and the egress split belongs to the network

The default deployment is the container (`docs/quickstart.md` teaches it):
stdio is unusable for a remote client, and the REST projection exists only
over HTTP. There is deliberately **no** host allow-list inside the proxy — no
`egress_allowlist` key checked before each request. It would be a second copy
of a boundary the deployment already holds, would have to be re-maintained
against every provider landing and every new rung, would quietly deny a working
provider when it drifted, and could not bound the tool that needs bounding,
because a `fetch` target is arbitrary by design. The network layer enforces the
useful half without decrypting the provider's TLS: a host name is visible in
DNS and in the SNI. The answer to list drift is generating the lists from the
constants the code dials. `permitted_providers` remains the app's contribution.

## 2026-10-21 — A parse that overruns is refused, and its deadline is the fetch timeout

The PDF parse runs inside `fetch.timeout_seconds`; there is no second key and
no default, because a second number nobody can price invites an override that
lets an unbounded parse run on a public listener. The parse happens in a worker
thread — cancellation does not reach a thread, but this is the one backend that
needs no dependency, which is what keeps a `--no-dev` install able to read
PDFs. A worker *process* was rejected: the spawn method varies by platform, the
extraction backend is not reliably picklable, and a paid-class PDF library ends
up loaded twice per fetch. `pypdf` moved into the `trafilatura` install
feature for the same reason the `Containerfile` passes `--extra`: a core
dependency would force a library into every install that never reads a PDF.

## 2026-10-20 — The quota rung is per vendor

`402`/`429` is the house row, not a universal law: a status joins an adapter's
quota rung only where that vendor answers with it on the request this proxy
actually sends, and the reason travels beside the rung. `serper` reads 402
(documented); `linkup` reads 429 alone, because its 402 belongs to an x402
payment lane this adapter never enters; `searxng` reads 429 alone, because a
self-hosted instance bills this client nothing. Matching the *status set*
across adapters for consistency was rejected: the rule is what should match.
What reopens a rung is a live keyed probe against a spent balance.
[`reference/provider-contract.md`](reference/provider-contract.md).

## 2026-10-20 — The Failures table is pinned by a test that reads the document

`reference/provider-contract.md`'s status-to-exception table is the single
place the mapping is written, and one test reads the document and asserts the
adapters' raising matches it. A second copy in prose or in code is how a
mapping drifts.

## 2026-10-20 — A drift report names the section it drifted in; two failures stay two exit codes

`tools/surface.py --check` names which section of the surface moved, and the
two ways an instrument can fail stay distinct: non-zero for drift, `2` for "the
instrument could not read its input". An exit code that means *CI was not run*
is an exit code that gets ignored, so a silent zero on an unparsable source is
the failure mode this guards.

## 2026-10-20 — A missing-extra error names the extra and quotes no command

The startup error for an enabled backend whose library is absent names the
extra and the name that needs no library, and points at the install block
rather than quoting a command: the block quotes the one command that is correct
on the reader's host, and a second copy in an error string goes stale.

## 2026-10-20 — `health.probe`'s per-name facts are one data row per name

The bodyless GET each provider answers for the health board lives in a table
keyed by name, not a branch chain and not an adapter method: an adapter method
would put a second network path into the interface every adapter must implement,
and a chain of branches is a table with worse error messages.

## 2026-10-19 — The 0.1.0 feature freeze

Frozen for 0.1.0: the three tools and their parameters; the three
`POST /api/v1/…` routes and the four operational paths; the three client verbs
and the server flags; the seventeen provider names; every config key; and the
usage-journal fields behind `GET /dashboard`. A frozen name moves only through
a superseding dated entry in this file — a rename without one is a defect in
the record, not a free change. **Values** are not frozen: adding a name, a key
or a rung is config. **Prose** is not frozen: tool descriptions are model-facing
copy, not a wire contract. The machine checks are
`tools/surface.py --check`, which diffs the rendering against
[`reference/surface.md`](reference/surface.md), and
`tools/value_sets.py --check`, which compares the six sets against
`tools/value_sets.json`; both run in the lane that gates merges.

## 2026-10-19 — Bundle hygiene: a cache on the checkout's filesystem, environments reaped by their marker

Every bundle exports `UV_CACHE_DIR` to a directory on the same filesystem the
checkout sits on, because uv builds an environment by hard-linking and a hard
link cannot cross a mount — otherwise each run writes a private copy of the
whole environment. Stale environments are reaped by their `pyvenv.cfg` marker,
not by the directory name `.venv`, sparing any environment whose newest file is
inside the last three hours; that window is what stops a reaper eating the run
that is executing it. [`../AGENTS.md`](../AGENTS.md) carries the operational
rule; this entry is the record.

## 2026-10-19 — FreeNewsAPI stays declined; SERPdive is dropped

A rolling news corpus is not a search engine: it answers "what was published"
and not "what is true", and its index is a window rather than a route. The next
look is the specialised-search review round. `SERPdive` was a candidate that
never reached a live read and is out. Both verdicts are rows in
[`reference/providers.md`](reference/providers.md).

## 2026-10-18 — A brief names a head as at an instant, so it is not the current state

A gate session re-reads the pull request and the branch tip before it reads,
comments or merges, and pins a merge to the `head.sha` that readback returns at
that moment — never to a SHA a record or a brief carried. A check written to
accept the head a record names passes on a head that no longer exists.
[`../AGENTS.md`](../AGENTS.md) states the rule.

## 2026-10-18 — The text that leaves is escaped, at the engine and at the serialisation boundary

Text scraped from the web reaches a model's context, and some of it is *about*
tokenizers: a page that quotes a special-token literal makes a backend that
parses it as a structural token reject the **whole request**. So one component
escapes it — a single U+200B after the opening delimiter of every such literal.
Escaping was chosen over stripping (loses content a prompt about tokenizers
needs to show) and over renaming the brackets (mangles quoted material): it is
visually identical, reversible, and **idempotent**, which is what lets text be
re-serialised, re-read through the fallback ladder, or paged by `offset` without
double-escaping or moving a coordinate. The match set stays tight; `<s>`,
`<think>`, comparisons and unterminated fragments are the false-positive canon,
and a tokenizer that rejects those is rejecting a large part of the web. The
rule lives once in `sanitize.py` and runs twice: the engines escape the objects
they return — so the agent's retrieved material reaches the model's prompt
already clean, which the serialiser cannot do — and the `WireModel` serialiser
re-applies it at the one choke point where the guarantee holds by construction.
It is hygiene, not prompt-injection defence.

## 2026-10-14 — The caps' discarded length is recorded, and neither cap changes

`search.cap` carries the length `max_snippet_chars` or `max_result_text_chars`
discarded, per hit, whether content logging is on or not: counts, never
content. It is what makes a cap measurable from real traffic without editing
either value, and it is on its own event because a length chosen by the calling
model must not decide how long a log line gets.

## 2026-10-14 — Fetch rungs are priced per call from the rung's declared price

The dashboard prices a `fetch` by the rung that answered it, read from the
registry row that rung declares — never from an estimate, and never one blended
figure for the whole path. A rung with no declared price is counted, not priced.

## 2026-10-14 — FreeSerp is adopted, and the install default grows from the keyless pair to the keyless set

A keyless whole-web index with no account, key or card joins `exa:free` and
`parallel:free` as the default set. The criterion is what makes a name an
install default rather than merely keyless: it must answer anonymously *and* be
a route a stranger could abuse without cost. `anysearch` meets the first and not
the second, so it stays explicit-only. The default may exist but it may not be
silent: the startup line and `--check` both say the set was chosen for the
operator. [`reference/providers.md`](reference/providers.md),
[`reference/configuration.md`](reference/configuration.md).

## 2026-10-14 — Jina Reader is a keyless rung; the shipped ladder stays empty

The third `fetch` rung dials a public reader with no key, and the shipped
default ladder stays empty. Shipping it by default was rejected while the
`fetch` path still walked a rung the caller had not named: a page served by a
third-party reader must be attributable, and a default that changes which
service answered is a change the operator should make deliberately. It is
registered, so a config line takes it.

## 2026-10-14 — The keyless pair is the install default, and the default route stays inside the free set

An enabled set that is empty resolves to the names that reach their endpoint
anonymously — the 2026-08-14 rule that made the empty set fatal is reversed, and
the reason it was safe to reverse is that the names it resolves to cannot bill.
An unnamed search on a deployment whose reachable names are all free walks that
set instead of refusing; one name that can bill restores the refusal. Routing
inside the free set is not cost routing: it never substitutes a name the caller
did not choose with one that merely costs less.

## 2026-10-14 — The allow-list is a permission set: permissive unset, deny-by-default once declared, intersected with `enabled`

`permitted_providers` narrows what a deployment may dispatch. Unset it permits
everything; declared, it denies by default, including names the config enables;
the effective set is the intersection, and every free-set question reads the
effective set. It is a deployment policy, not a caller parameter, and the tool
schema is not narrowed by it. [`reference/allow-list.md`](reference/allow-list.md).

## 2026-10-14 — The review record is a trailer in the PR body, and the gate refuses a body without it

There is one maintainer account and a forge takes no review from a PR's own
author, so the verdict lives in the pull request: `Fixes #<N>` or
`Part of #<N> - …` as the body's first line, with the review evidence under a
heading keyed to that issue, and the trailer reaching any merge commit the
landing builds. Source branches are deleted on merge, so the pull request, not
the branch, is the durable record. [`../AGENTS.md`](../AGENTS.md) states the
mechanics.

## 2026-10-14 — Safe-search is a boolean; `locale` becomes `language`; both reach the model surface

A level scale was refused because no adapter this proxy calls has two settings
to map onto it, and a parameter that one provider reads as a filter and another
as a ranking nudge is a parameter whose meaning the caller cannot know. The
renames are hard: no alias, because an alias puts two names for one thing into
the health board, the usage journal and the dashboard's per-provider series.

## 2026-10-14 — The spend ceiling is declined; a ledger was never the gate for multi-user hosting

A per-call or per-day cost ceiling was refused: the project is not building an
accounting system, and a ceiling read from a journal on the serving path puts
accounting back where the no-cache rule already refuses it. The free-only route
was accepted on its own merits and is **not** gated on this; it cannot bill.
[`ROADMAP.md`](ROADMAP.md) §5 carries the argument and the conditions that would
reopen it.

## 2026-10-14 — The REST body projects `mode`; the spec's parameter row is a reading, not the shape

The projection mirrors the tool's parameters rather than a vendor's, so the
model-facing and machine-facing surfaces take the same call. What the body omits
is a decision recorded here, not an oversight.

## 2026-10-14 — The REST projection draws 400/502 at "refused before dispatch"

A request the server refused before dialing anyone is a 400; a request it
dialed and the provider failed is a 502. The line is drawn at whether a call
happened, not at which component noticed, so a caller can tell "fix the
request" from "the provider is down". [`reference/public-api.md`](reference/public-api.md).

## 2026-10-14 — A provider variant is named `backend:flavour`

`exa:free`, `parallel:free`: a flavour exists only on a backend that exists, so
the free half cannot be mistaken for a separate service. Three consequences are
pinned: a config table for a flavoured name is quoted, the API key comes from
the backend segment alone (`:` is not legal in a POSIX variable name), and where
a name must be a Python identifier it is written snake_case. The rename from
`exa_free` was hard — no alias, no deprecation window — because an alias splits
the journal's per-provider history at the rename and doubles a name on the
health board. Recorded data keeps the names it was recorded under.
[`reference/provider-contract.md`](reference/provider-contract.md).

## 2026-10-13 — Agent mode is a third operation, off by default, with a fixed retrieval plan

`answer` retrieves on a **fixed** plan — the caller's query plus at most two
extras, five results each, up to three pages at `depth="report"` — and makes
**exactly one** model call over that material, so the cost of a call is bounded
by arithmetic rather than by accounting. A loop in which the model asks for
another search is the one shape that would make the cost the model's decision,
and it is refused. The model never drives retrieval; the model, prompt,
temperature and token budget are the server's, never tool parameters; the
citations in the response are the server's, validated against what it retrieved,
and only the prose is the model's. No usable material means no model call. It
ships off (`[agent] enabled = false`) with the open questions in `ROADMAP.md` §8;
`search` and `fetch` are untouched by any of it.
[`reference/agent-mode.md`](reference/agent-mode.md).

## 2026-10-13 — The geo bucket reports its two halves separately

A provider that supports a country and not a language, or the reverse, names
both: one "geo" bucket would hide which half is missing and make a caller's
workaround wrong half the time.

## 2026-10-13 — Latency percentiles are computed at read time, over a 14-day window

No stored histogram, no precomputed percentile: the journal is append-only and
the window is short enough that the dashboard reads it. A stored aggregate would
need invalidation, and invalidation is the failure mode the no-cache rule exists
to avoid. [`reference/metrics.md`](reference/metrics.md).

## 2026-10-13 — The public API is the tools; REST is a projection, not a second contract

`/api/v1/search` and `/api/v1/fetch` project the tool calls for clients that
cannot speak MCP. They do not extend it: anything that would need a new verb is
a change to the tool first. [`reference/public-api.md`](reference/public-api.md).

## 2026-10-13 — The search path integrates APIs; a scraped results page is out

The DuckDuckGo adapter is removed. A scraped SERP breaks without notice, carries
someone's rendering as this server's contract, and cannot be diagnosed from a
status code. Every name in the set is a documented API; a keyless name is still
an API (`freeserp`, `anysearch`, a configured SearXNG), which is what keeps the
keyless set from re-opening this question.

## 2026-10-13 — A free-only route is accepted; routing by task is declined

`search(mode="free")` is served only from names that cannot bill and fails
rather than escalating. It is a *restriction the caller asks for*, not a
selection the server makes: routing to a provider chosen by task, cost or
quality stays declined, and the gates that would have to clear first are in
`ROADMAP.md` §6. The free set is about capability, not pricing pages: a metered
tier is a price with a delay, so a name stays billable until its endpoint can
be shown to answer without an account.

## 2026-10-12 — Algolia, Parallel and their free halves join the set

Algolia is keyed and index-scoped: its registration is mandatory on every tier,
so its key is never optional and `app_id`/`index` are config, not environment.
Parallel arrives as a pair — a hosted MCP endpoint that answers anonymously, and
the billed name for a key. [`reference/providers.md`](reference/providers.md).

## 2026-10-10 — Extraction is a named backend, and trafilatura is an install feature

`fetch.extractor` picks one module in `extractors/`; the default backend's
library ships as an extra, and an enabled `fetch` whose library is missing is
startup-fatal rather than degraded. `HttpFetcher` takes the backend **injected
with no default**: a default would import a backend at `fetcher` import time,
and `stdlib` — HTML through `html.parser`, no PDF claim — is the second registry
member that keeps `fetch` buildable on a bare install.

## 2026-10-10 — A usage dashboard on an append-only journal, not a ledger

`UsageRecorder` aggregates in memory and optionally appends a JSONL line per
terminal call. The line is content-free: no query text, no result text, no
keys. Nothing on the serving path reads the journal — the dashboard backfills
from it, and any ceiling reads the in-memory totals. A new journal key is
optional and defaulted at read time, so an older reader skips it. This is the
nearest thing to a database in the tree and the reason there is still no
database: a ledger implies settlement, and settlement is not what the dashboard
claims. [`reference/metrics.md`](reference/metrics.md).

## 2026-10-09 — The default route can fail over; a named provider stays terminal

When a `search` that resolved to the configured default fails, the engine walks
the operator-ordered `[search] fallback` ladder. A search that *named* a
provider is answered by that name or by nothing: a caller who chose a backend
chose its index and its price, and substituting it silently reports a different
service's results as the one asked for. The same reasoning governs `fetch` since
2026-10-25; this entry reversed the earlier "a provider failure is terminal"
rule for the default route only.

## 2026-10-01 — Fetch paging and query targeting, and the empty-results notice

`offset` continues a page, `query` selects passages, and a `search` that came
back with nothing while a constraint was dropped says so in a `notice`. Paging
and selection are mutually exclusive with each other's axis, which is the rule
`path` later inherited.

## 2026-09-29 — Recency on `search`, and four free adapters

`recency` is an open-ended window ("published within the last …"), mapped by
each adapter onto a fixed number of days per value — the long form of the month
and the year — so a window never misses a day it claims to cover. Real month
lengths would move the window's edge between calls for no reason a caller can
see. The four free adapters that arrived with it are in
[`reference/providers.md`](reference/providers.md).

## 2026-09-29 — The fact store is removed

An earlier entry landed a fact store; this one deletes it. It read as a cache
even though its claim was different, and a component whose name promises stored
truth is a component a reader will route around. There is no cache and no
stored corpus. See also 2026-08-14 (no cache).

## 2026-09-29 — Publication waits for an explicit go, and ships as one commit

Nothing publishes on its own: a release is one commit, made on request.
[`reference/publishing.md`](reference/publishing.md).

## 2026-09-09 — The day-one honesty pass

The first release does not claim what it has not measured: every unverified
figure in the tree is marked unverified rather than rounded up.

## 2026-09-06 — The fetch ladder gains a renderer rung

Crawl4AI joins the ladder as a self-hosted renderer, behind a config URL and
never in the shipped default. A renderer is a *service*, not a library: the
browser's RAM is not the fetcher's, the browser download is not the image
build's, and a second resolution path is a second SSRF surface.
[`reference/crawl4ai.md`](reference/crawl4ai.md).

## 2026-08-18 — A snippet is a source, and a nav stub is an empty page

Two rules the adapters still carry: a snippet that names where it came from is
checkable, and a page that extracts to a navigation stub counts as empty — the
ladder moves on rather than returning chrome as content.

## 2026-08-15 — Logging is one stderr stream, and it never renders a traceback

stdout is the JSON-RPC channel, so every log line goes to stderr; a message is a
constant dotted event name and values travel through `bind()`, which is what
makes the no-secrets rule checkable — a value reaches a line only by being
named. Nothing renders a traceback: loguru's defaults print local variable
values beside the exception, and every adapter has an API key in scope where it
fails. Caller and provider content rides its own events, never `search.ok` or
`fetch.ok`, whose field set is fixed whatever the caps are set to. The rules are
enforced by walking the AST, so a new call site fails the suite rather than
review. [`architecture.md`](architecture.md).

## 2026-08-15 — `/healthz` sits outside the Host allowlist, and never fails on a provider

The check lives inside the streamable-HTTP transport rather than as middleware,
so a custom route bypasses it — which is the only reason a kubelet probe whose
`Host` is a pod IP works. It therefore reports provider names and uptime and
nothing else, and stays secret-free. A probe that fails because a provider had a
bad afternoon restarts a healthy container; liveness is the process, readiness
is `/healthz`. [`reference/container.md`](reference/container.md).

## 2026-08-14 — A result's page text is bounded, and never duplicated

A `Result` carries `snippet` **or** `text`, never both: the snippet is a prefix
of the extract, so shipping both ships the same prose twice. `text` is capped by
its own policy, because leaving it unbounded lets `max_results` — chosen by the
calling model — decide what a response costs; before the cap existed a response
measured 133k characters.

## 2026-08-14 — v1 is a proxy, with no cache

Every `search` reaches a provider. A cache would serve a stale answer to a
question whose whole value is freshness, and the invalidation it needs is a
larger system than the proxy. A named provider's answer is not a cached fact.

## 2026-08-14 — Providers are named, never inferred

Nothing picks a provider from the text of a query. With several enabled and no
default, a bare `search` is an error naming what is available — the exception
is a deployment whose reachable names all cost nothing, and that walk is still a
walk over a set the operator configured, not a guess. A "pick the cheapest"
route would make the server's cost decision the caller's surprise.

## 2026-08-14 — Exa is two providers, and `exa` spends its free tier first

`exa` escalates to the key on *any* free-fallback error rather than only a
classified quota signal, because the rate-limit sniff has never seen Exa's real
wording; a cooldown keeps free from being retried every call, and a `notice`
says whenever the key was used. `exa:free` has no ladder and cannot bill. This
is not cost routing: both rungs are the backend the caller named, and the ladder
can only undercharge it.

## 2026-08-14 — Providers are explicit opt-in

A config that enables nothing used to be an error; since 2026-10-14 the empty
set resolves to the keyless names. What has not moved is that an enabled
provider with no API key is startup-fatal, and that keys come from the
environment only. A free tier does not make a name exempt: the tier is an
account quota, and a key names whose quota a search spends.

## 2026-08-14 — HTTP is a second transport, and the network is its only boundary

The listener has no auth, deliberately: the bind address is the access control,
which is why `--host` defaults to loopback and why every call it serves is
billed. DNS-rebinding protection stays on; `--allowed-host` adds to FastMCP's
allowlist rather than replacing it, and a `421` means a name is missing, not
that the check should go. Because `lifespan` runs per request under HTTP, the
shared httpx client and the provider handshakes live in `build_app_context`.

## 2026-08-14 — Unhonourable constraints are reported, not filtered

An adapter that cannot honour a constraint says so through
`ignored_constraints`, into `ProviderResult.notice`. Nothing filters incapable
providers out before dispatch: a silent drop is a filter the caller did not ask
for and cannot see.

## 2026-08-14 — The `provider` parameter lists every adapter, not the enabled set

FastMCP builds the schema once at import, and the annotations are `eval`'d
against module globals, so a closure over a config object raises `NameError`.
Config governs behaviour behind the schema, never the schema — the same reason
the fetch provider parameter is a free-text name rather than a `Literal` of the
configured subset.

## 2026-08-14 — The agent-facing tool contract is specified in Gherkin

The tool contract that a model reads is written as scenarios under
`tests/features/`, run by pytest-bdd. The step functions must be synchronous:
pytest-bdd calls them directly, so an `async def` step is never awaited and the
scenario passes having asserted nothing.

## Earlier — `fetch` is not a provider

`fetch` is its own path: a fetcher, an extraction backend and a fallback ladder,
not a `providers/` module. A search provider returns links and snippets; a fetch
provider returns a document. Folding one into the other would give the tool list
a second `search`-shaped verb and give the fetch path a protocol built for
results.

## Earlier — Extraction is one swappable function

Extraction is a protocol over "bytes in, text out" with a registry beside it,
not a default with an override. The wiring list for a new backend lives in
`extractors/base.py`'s docstring; six places, and a backend that claims a media
type it cannot read is a startup error, not a runtime surprise.
