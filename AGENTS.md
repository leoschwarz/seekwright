# AGENTS.md

> **Scope.** This repository is the seekwright implementation: one root dune
> workspace — `lib/`, `bin/`, `test/`, `live/`, `ocaml-tools/`, `examples/` —
> holding two packages, `mcp-caps` (the capability layer) and `seekwright` (the
> server). There is no second implementation in the tree and nothing to port:
> `ocaml-tools/surface.expected`, the differential corpus under
> `test/differential/`, the prompt goldens and the three egress lists are this
> tree's own, re-rendered from this tree's code at every `dune runtest`.
> `VISION.md` is the spec both the goals and the non-goals come from; a conflict with
> it is raised in `plans/` first, and only the maintainer amends the page — and then in
> the change it authorises, recorded in that page's amendment log.
> `plans/` is the only editable planning area and the authority for design
> decisions not yet in code; everything else in the repository is either the
> implementation, its gate, or a page an operator reads.

Guidance for AI agents working in this repository.

## Project overview

An MCP server that fronts web-search providers behind one normalised tool
surface. Three tools: `search` (one query to one provider), `fetch` (a URL in,
extracted page text out) and `answer` (agent mode, off by default). Seventeen
provider names over fifteen adapter modules, `exa` and `parallel` each appearing
twice (`exa`/`exa:free`, `parallel`/`parallel:free`) because each answers
anonymously for free and bills with a key; five fetch fallbacks behind the local
reader. The same surface is served over stdio, streamable HTTP, the
`POST /api/v1/…` REST projection and three CLI verbs.

**One native executable** — musl-linked, 16.5 MB stripped on a 37 MB Alpine
runtime layer, no interpreter and no package-manager state at run time.
`mcp-caps` makes the guardrails structural rather than conventional: a tool
declares the authority its operations need in its `'caps` type,
`Registry.add ~grant` supplies an abstract grant of exactly that kind, and the
policy constructors (`Policy.with_root`, `with_written_root`, `with_endpoints`,
`with_public_web`) own filesystem and network confinement. Forging a grant,
matching one open, or calling a raw operation is a compile error here, not a
convention. Every outbound call and every filesystem write goes through one:
adapters dial only the endpoint in their `Registry` row, `fetch` reads behind the
SSRF-validated `Net` grant, and the page cache and journal write behind an `Fs`
grant. That is what keeps "which tool may reach what" a property of
`lib/factory/` — every grant is built there, from a config decision — instead
of a review question.

Status: **production candidate**, with four exclusions disclosed in
`ocaml-docs/divergences.md` and `plans/seekwright-ocaml-port.md` §38 — no PDF page
text (measured, not incidental); the extraction backend is this port's own
`stdlib` reader and `trafilatura` is refused by name; live verification covers
only the keyless names and two fetch cases, and every keyed name is announced
untested; and there is no outbound proxy. Calling the port a *limited production
release* is a maintainer decision, not a branch one, and it carries the PDF
exclusion with the label. "Full behavioural parity" is not a claim this tree may
make while that exclusion stands.

One operator serves one deployment, and the non-goals follow: **no auth or
tenancy on the listener**, **no search cache and no stored corpus** (every
`search` reaches a provider — that is a decision, not a gap), and **no accounting
ledger** (`Usage` is an in-memory aggregate plus an optional append-only journal
for the dashboard, never a billing record). `[fetch] cache_dir` is an
off-by-default *page* cache of extracted text, bounded by `cache_ttl_seconds`,
`cache_max_entry_bytes` and `cache_max_bytes`.

## Commands

Every shell needs the switch and, on this host, the GMP search paths — the exact
exports are in the `ocaml` skill (`.agents/skills/ocaml/SKILL.md`; CI installs
`libgmp-dev` and needs none of it). The gate is four targets and all four must be
green before a change is called done:

```bash
dune build @fmt            # the tree as its pinned ocamlformat and dune formatter would write it
dune build @install        # both libraries, both executables, the generated .opam files
dune runtest --force       # every suite under test/, every pinned diff, the live inventory
dune build @doc            # odoc: a broken cross-reference is a defect
```

`dune runtest` is the interesting one: it runs the alcotest suites **and** the
diff rules that pin whole outputs — the surface manifest, the stdio transcript,
the embedded prose and the dashboard page, the three egress lists, the `--check`
reports, the differential goldens and matrix, the negative-compilation
diagnostics. A green run means both.

Formatting is pinned by `.ocamlformat` — ocamlformat 0.29.0, `margin = 100`,
spacing options chosen to preserve the tree's blank-line grouping — and
`dune build @fmt` is the gate target that checks it, over the OCaml sources and over
the stanzas with dune's own formatter; a formatter bump lands as one reformat commit
rather than a per-commit hook. Source-text
needles in the suites are matched with whitespace collapsed
(`Test_support.source_includes`, `source_excludes`, `source_count_occurrences`),
which is what keeps the formatter's line breaks from moving an assertion about
the code a needle quotes.

```bash
dune runtest ocaml-tools --auto-promote     # re-render and re-pin a golden you meant to move
./_build/default/test/test_engine.exe test "<suite name>"    # one suite, from _build/default/test

VERSION="$(dune build version.txt >/dev/null; cat _build/default/version.txt)"
docker build -f Containerfile.ocaml --build-arg SEEKWRIGHT_VERSION="$VERSION" -t seekwright-ocaml:dev .
trivy image --severity CRITICAL,HIGH --ignore-unfixed=false seekwright-ocaml:dev

_build/install/default/bin/seekwright-live --list                       # hermetic: the inventory
SEEKWRIGHT_LIVE_TESTS=1 _build/install/default/bin/seekwright-live freeserp
```

Running the server itself: `_build/install/default/bin/seekwright --check`
(config, provider construction, and one keyless readiness probe per built name
that has one — a bodyless GET to the real endpoint, so it needs egress and never
sends a key), and the same binary with no arguments for stdio, or `--http` for
streamable HTTP. `--check --live` adds one billed search per ready provider.
Conformance against the pinned official runner is `test/conformance/` and needs
Node ≥ 22 plus an npm fetch; it is setup, not a gate step, and its traps are in
the `ocaml` skill.

## The frozen surface

A frozen name moves by changing the code, promoting the pin and justifying the
move in the pull request body. Every row below is a `dune runtest` rule that
fails the moment the contract moves — the surface manifest, the prose goldens,
the three egress lists and the matrix are diffs, not assertions buried in a
suite, so a green run is the only evidence they hold. Nothing here is re-typed by
hand except where it says so.

| Pin | Where | What it refuses |
|---|---|---|
| The surface manifest — `3 MCP tools, 3 REST routes, 3 CLI verbs, 10 server flags, 17 provider names, 49 section config keys over 6 tables, 12 per-provider config keys, 4 operational routes, 37 usage-journal fields` | `ocaml-tools/surface.expected`, re-rendered by `surface.ml` | any drift in the names a consumer sees, journal fields included |
| The embedded prose — `server_instructions`, `search_description`, `fetch_description`, `answer_description`, `answer_system` — and the dashboard page | the `.expected` goldens beside `ocaml-tools/resources.ml` | a deployed sentence or a reformatted page changing without a reader noticing |
| The deployment's host lists — `search-allow` from `Registry.rows`, `fetch-allow` and `fetch-deny` from `known_fetch_fallbacks` plus the operator's own files | `deploy/compose/generated/`, re-rendered by `ocaml-tools/egress_lists.ml` | a provider or fallback row moving without the deployment that proxies it |
| The six value sets, written out by hand | `test/test_config.ml`'s frozen-vocabulary case: `Config.known_providers`, `permitted_fetch_names`, `known_extractors`, `keyless_providers`, `untested_providers`, `known_fetch_fallbacks` — plus that list's billable subset, `renamed_providers` and `default_user_agent` | a widened or narrowed set landing as a silent config change |
| The parity matrix | `test/differential/matrix/`'s two TSVs (`behaviours`, `surface`), re-read by `test_differential_matrix.ml` | a row that names no consumer on this port, a blank cell, a state outside the table's vocabulary, a `pending-*` verification on a row claimed ported |
| The routing core's dependency list | `test/router_dependencies.expected`, generated by `ocamldep` | `lib/router.ml` reaching for any sibling module |

The surface golden and the prose goldens are the manifest a *model* reads back
(tool descriptions, schemas, refusal sentences), which is why they are pinned
rather than asserted in a unit test. The matrix records which suite or corpus
area is the evidence for each row, so a module rename is a matrix edit in the
same commit, and the source globs in `test/differential/dune` are what make its
pointer check real rather than decorative.

## Version and releases

`dune-project`'s `(version …)` is the **one version owner**. `lib/version.ml` is
generated from it, `dune build version.txt` renders it for a step that cannot
read a dune file, `test/test_metadata.ml` cross-checks it against the generated
module, both `.opam` manifests, the User-Agent defaults and the MCP identity, and
`Containerfile.ocaml`'s build stage compares the `SEEKWRIGHT_VERSION` build arg
against that line and fails if they disagree. Never spell the number anywhere
else; a bump lands on `dune-project` plus the regenerated `.opam` files, which
are committed and never hand-edited.

`Version.mcp_server` is deliberately not the release version: it is the MCP
`serverInfo` identity, a separate protocol value pinned by the stdio transcript.

A release is a **tag push**, and the artifact is the container image:
`publish.yml` refuses a tag that does not name `main`'s head and refuses one that
is not `v` plus `dune-project`'s version, scans the built image, then pushes
`ghcr.io/<repo>:<version>` and `:latest` from the same local image and smokes the
pulled bytes. There is no wheel, no package index and no release asset. The
package is private until the repository's package visibility is set to Public, so
a pull may need `docker login ghcr.io` — `SECURITY.md` records that caveat, not
this file.

`ci-ocaml.yml` is the ordinary gate; `ocaml-image.yml` builds, scans and runs the
container contract (UID 10001, `--help` as a usage error, stdio `tools/list`,
`/healthz`, a 400 REST refusal, SIGTERM drain to exit 0, read-only rootfs,
mounted config and journal, layer size).

## Code style and conventions

- Read the `ocaml` skill before writing OCaml here: verified toolchain, mcp-kit
  0.2.0 API, the dune and warning traps that already cost a build. Read
  `.agents/skills/comment-discipline/SKILL.md` before writing or trimming
  comments — it is the operational form of "a comment states a constraint the
  code cannot state".
- **Plans are living documents**: when code settles differently from the plan,
  the same commit updates the plan. Wave and milestone history goes in
  `plans/seekwright-ocaml-port.md` as a new `## NN.` section, never in commit
  prose.
- Commits: one lowercase line, area first (`engine: …`, `matrix: …`, `plans: …`).
  A body only when the line would drop a constraint a reader of the diff needs.
- Every module gets an `.mli`; the public surface is deliberate. `lib/caps/dune`
  keeps `policy_fs` and `controls_raw` in `private_modules` and `controls_raw.ml`
  has no interface — the raw-bounds record has no name outside the library, so a
  `~controls` argument cannot be filled by a consumer. Preserve that boundary.
- Library direction is fixed: `mcp-caps` → `seekwright` → `seekwright.providers`,
  `seekwright.fetch`, `seekwright.factory`,
  `seekwright.cli`, with `seekwright.text` and `seekwright.wire` as the
  stdlib-only floor both big libraries link. A factory that builds adapters
  cannot live in `lib/`; it would close the cycle. `mcp-caps` never depends back
  on `seekwright`, which is what keeps dropping the layer a `seekwright`-side
  change.
- Tests mirror modules by name: `test/test_router.ml` ↔ `lib/router.ml`. Adapter
  suites drive `Provider.Net` as a fake or a loopback listener, so no billed
  socket opens and the request that would have gone out is asserted on instead.
- **No line-number cites**, anywhere: not in code, not in a comment, not in a
  page. No `file.ml:NNN`, no "line 379". The number moves the next time the file
  is edited and nothing catches it, so name the symbol (`Policy_net.with_public_web`,
  `Registry.rows`, `known_fetch_fallbacks`, `validate_url`) or the page and its
  section.
- **Log discipline.** Logs go to stderr only, because stdout is the JSON-RPC
  channel. An event name is a constant dotted name; a value reaches a line only
  by being named in the field list. Never a traceback, never an exception
  object — `Log.classify_exn` is the only exception → string conversion on a
  serving path and it returns one of a finite set of constants. Caller and
  provider content rides its own event (`search.result`, `search.answer`,
  `fetch.content`), never extra fields on `search.ok` or `fetch.ok`.
- **An unhonourable constraint is reported, not dropped.** An adapter that cannot
  apply a filter the caller passed names it in the result's `notice`; silence
  there is a silently dropped filter.
- **Absent-field rule at the wire boundary.** An unset field never serialises as
  `null`: the `Model` encoders build the JSON from only the set fields, and a new
  wire model inherits the rule rather than re-deciding it.
- **Provenance comments may name the Python implementation in the past tense** —
  "the Python reader answered this differently" is a reason the differential
  golden exists. They may never name a path that no longer exists in this
  checkout: a pointer to a deleted file is a broken citation, not provenance.
- Reviews: the twenty-point checklist is `plans/reviews/2026-11-12-style-review.md`,
  the correctness findings sit beside it, and the owner's running read is
  `plans/reviews/code_review_ledger.md`.

## Architecture

The table is the agent-facing copy of the module map; `lib/caps/README.md` is the
capability layer's own contract, and `ocaml-docs/` is the operator's map.

| Path | Role |
|---|---|
| `lib/caps/` | package `mcp-caps`, wrapped as `Mcp_caps`: `authority` (the `'caps` GADT, `Fs`/`Net` operations, `of_confinement`), `policy` / `policy_fs` / `policy_net` (the confinement decisions, never the grants), `tool`, `registry` (`add ~grant` — the one place a grant meets a tool), `controls` / `controls_raw`, `event`, `error`, `server` (the only module that knows mcp-kit: `Mcp_caps.Server.of_registry` folds a `Registry.t` into an `Mcp_kit.Server.t`) |
| `lib/router.ml` | the routing decisions, stdlib-only by machine check: which name serves, the free walk, the fallback rungs, the refusal sentences |
| `lib/model.ml`, `lib/wire/` | the wire records and their `Yojson` encoders (the absent-field rule); `wire/page.ml` is the page and image record both halves of the fetch path speak |
| `lib/text/` | package `seekwright.text`: `Utf8` — every length cap and offset in the tree counts codepoints, not bytes — and `Repr`, the quoting that keeps scraped text from fabricating a log record |
| `lib/sanitize.ml` | the U+200B escape pass on text that leaves the proxy: reversible, idempotent, byte-faithful |
| `lib/config.ml` | TOML config and every key of the frozen surface; credentials from `SEEKWRIGHT_*` env only; an enabled name without its key is startup-fatal; the vocabulary lists (`known_providers`, `free_providers`, `keyless_providers`, `known_fetch_fallbacks`, `known_extractors`) |
| `lib/provider.ml`, `lib/providers/` | package `seekwright.providers`: the adapter contract (`module type S`, `Provider.Net` as the HTTP seam, the constraint report, the caps) and fifteen adapters over seventeen names; `mcp_client.ml` is the narrow streamable-HTTP MCP client `exa:free` and `parallel:free` use |
| `lib/engine.ml`, `lib/health.ml`, `lib/usage.ml` | execution around the routing decisions, the circuit-breaker board (the first attempt of any search is never gated, and the board gates fallbacks only), the in-memory aggregate and the append-only JSONL journal |
| `lib/fetch/` | package `seekwright.fetch`: `fetcher` behind the SSRF-validated `Net` grant, `remote_target`, `extractor` (the backend contract and the shared plumbing) + `extract_stdlib` (the one backend this build can construct), `extract_pool` (bounded worker domains), `fallback` + the five `fallback_*` readers, `jsondoc`, `tabledoc`, `page_cache` |
| `lib/factory/` | package `seekwright.factory`: one facade (`Factory.build_providers`, `build_fetch_stack`, `build_app`, `grant_of_endpoint`) over `providers_build`, `fetch_stack`, `provider_set`, `registry`, `grants`, `verdict`, `app`; `Registry.rows` is one declarative row per name — endpoint, credential, cost model, live status — and `grants.ml` is the single funnel every served grant goes through |
| `lib/agent.ml` | agent mode: the fixed retrieval plan and **exactly one** model call; the model writes prose, never drives retrieval |
| `lib/server.ml` | the three tools, both transports, `/healthz`, the dashboard, the REST projection, the Host allowlist, the drain |
| `lib/cli/` | package `seekwright.cli` (`Cli_flags`, `Cli_check`, `Cli_client`, `Cli_extract`, `Cli_metrics`, `Cli_serve`): the decisions and reports, each taking its input and its network as arguments — no module here writes a stream or calls `exit` |
| `lib/log.ml`, `lib/prompts.ml`, `lib/dashboard_html.ml`, `lib/http_head.ml`, `lib/version.ml` | dotted event names on stderr; the embedded model-facing prose; the one self-contained dashboard page; the request/response byte ceilings; the generated version module |
| `bin/main.ml` | the audit surface: one `Registry.add` per tool with its grant named, the loop the grants are opened on, the CLI verbs' own endpoint grant for `--server`, the transport dispatch and the exit status. Its `dune` also carries the stdio smoke and the `--check` report pins |
| `test/` | the suites, one per module it exercises; `support/` (`Test_support`, `Binary_harness` — the one copy of each helper), `differential/` (corpus, goldens, `divergences.tsv`, properties, matrix), `should_not_compile/`, `log_guard/`, `conformance/`, `corpus_html/`, `fetch_support/` |
| `live/` | `seekwright-live`: the explicit live runner, its case inventory (`Cases`), its per-case assertions (`Checks`) and its own hermetic suite |
| `ocaml-tools/` | tree-reading instruments: `surface.ml` (the frozen manifest), `resources.ml` (the prose and dashboard pins), `egress_lists.ml` (the deployment's host lists), `extract_bench/` (the extraction corpus bench and its digests) |
| `ocaml-docs/` | the operator's pages; see the last section |
| `deploy/compose/` | the two-role unit set: `compose.yaml`, one config per role, the egress inputs under `egress/`, the rendered lists under `generated/`, reference Squid ACLs under `squid/` |
| `plans/` | the planning area and the decision record — read before changing a frozen fact, write on the same commit |
| `examples/` | four runnable servers, the layer's own audit surface: `echo.ml` (mcp-kit with no capability code, the plan's fallback path), `caps_echo.ml` (the same tool registered through `mcp-caps`, no power), `read_source.ml` (a filesystem grant), `gated_search.ml` (a network grant) |
| `skills/` | the operator-facing agent skills (`seekwright`, `seekwright-deploy`); the engineering skills are under `.agents/skills/` |

## Gotchas

- **`dune build` fails at graph construction on a missing named dep.** A `(deps …)`
  entry naming an absent file is a `File unavailable` error, and a bare
  `dune build` fails too, not just `runtest`. A suite that reads an operator page
  or a golden has to declare it, or the sandbox will not carry it.
- **A failing diff rule is usually a legitimate re-pin.** For the goldens under
  `ocaml-tools/` the re-pin path is `dune runtest ocaml-tools --auto-promote`.
  A bare `dune promote` promotes only what a **runtest** diff flagged, one
  mismatched file per run; the promoted file lands read-only — `chmod +w` before
  committing. `test/router_dependencies.expected` is the frequent one: any module
  added under `lib/` adds `ocamldep` lines. It can be stale on a branch base;
  check `git show HEAD:test/router_dependencies.expected` before blaming your
  change.
- **A test's cwd is `_build/default/<dir>`, not the source directory.** Suites
  that read repository files need them declared in `(deps …)` and read with
  `../`; running a built exe from the repo root fails exactly those cases, and
  `dune exec` re-roots the CWD, so the corpus and golden reads fail there too.
- **`lib/router.ml`'s isolation is a machine-checked dependency fact.**
  `test/dune` diffs `ocamldep`'s answer for every file in `lib/` against
  `test/router_dependencies.expected`, so the router leaning on a sibling fails
  `runtest`. `ocamldep` needs `-I ../lib` or every cross-module line is empty and
  the pin is vacuous. The router may not reference `Seekwright.Config`; its
  callers build the routing table from `Config`'s lists.
- **The grant boundary is the audit surface, and it is why a test builds its app
  through the factory.** A grant has no constructor outside `mcp-caps`'s policy
  functions, so a suite cannot hand-wire an I/O-capable app: it calls
  `Factory.build_app` (or `build_providers` / `build_fetch_stack`) and injects at
  the seam instead — a loopback listener, a scripted `Provider.Net`, a temp
  directory for the `Fs` grant. `lib/factory/grants.ml` is the one funnel that
  sets the operation bound and wraps a grant in the audit sink;
  `test/test_caps_audit.ml` fails the build when another module constructs or
  wraps one, and `test/should_not_compile/` holds fourteen programs — one of them,
  `grant_path.ml`, the positive half — whose compiler diagnostics are pinned, so
  a new capability-shaped feature has to keep that set honest.
- **Refusal compilation is part of the gate, and its failure mode is inverted.**
  `test/should_not_compile/` compiles each snippet under
  `with-accepted-exit-codes (not (or 0))` and diffs the diagnostic against its
  `.expected`: a snippet that starts compiling fails the build. The diagnostics
  quote the snippet's own source line, so editing a snippet — even its comment,
  even a whole-tree formatting sweep — re-promotes its `.expected` in the same
  change, and a plain `runtest` can hide a stale one behind a cached `.out`:
  `runtest --force` is the check.
- **Logs go to stderr or stdio breaks**, and stdout is the JSON-RPC channel.
  `test/log_guard/` walks the AST (`field_sets.ml` for the per-event field sets,
  `source_discipline.ml` for which module may write a stream), and
  `bin/smoke.expected` / `smoke_notes.expected` pin that the protocol transcript
  and the startup notes stay separate streams.
- **There is no `--help` and no `--version`.** An unknown flag prints
  `seekwright: unknown flag --help` and exits 2 (`Cli_flags`); `README.md` is the
  usage prose, and the flag list is what the surface golden prints. Do not add a
  help screen.
- **`--check` is a network diagnosis whose exit code is narrower than its
  report.** It prints the enabled, effective and built sets, the `untested` line
  and one row per name, and probes every built name that has a probe. Two rows are
  deliberately not counted: a name this build carries with no probe
  (`exa:free`, `parallel:free` print `no connectivity probe`) and an enabled name
  the deployment could not build for want of a key (`not built on this port`). So
  a keyless MCP-only deployment exits **0**, and that is pinned by
  `bin/check_unbuilt.expected`. Exit 1 means the config names something this
  binary cannot honour or a probe failed (`test/check_unreachable.expected`,
  `test/check_probe_gap.expected`); exit 2 is usage. `--check --live` adds one
  real search per ready provider — the one path on this port that bills.
- **The provider enum on the tool schemas is every registered name, not the
  enabled subset.** `bin/smoke.expected` carries all seventeen while
  `bin/smoke.toml` enables none, because the schema is the vocabulary and the
  filter is dispatch: a `provider` argument is checked against the effective set
  and refused with a sentence naming what this build carries. Adding a provider
  therefore re-pins the schema even in a deployment that never enables it.
- **`/healthz` is outside the Host allowlist and stays secret-free.** It is
  exempt on purpose, so a kubelet probe whose `Host` is the pod IP works; every
  other route answers 421 for a name missing from `--allowed-host`. It answers
  `status`, the built providers' names, `default_provider` and `uptime_s` and
  reads no journal. `test_p8_server.ml` is the suite.
- **Embedded prose has a golden, not a twin.** Every string in `lib/prompts.ml`
  and `lib/dashboard_html.ml` has a committed `.expected` beside
  `ocaml-tools/resources.ml`, and `runtest` diffs the literal against it. A
  reworded sentence or a reformatted dashboard page fails the gate; a deliberate
  change re-promotes the golden in the same commit.
- **Divergences are registered, never smoothed over.** `test/differential/divergences.tsv`
  gives each accepted difference a reason, and the reason lands in the golden's header as
  `explicit-divergence`. Such a golden fails if the port changes shape *or* if the
  difference closes on its own — closing one is a decision that edits the registration, not
  a drive-by fix. The matrix suite holds the rows and the goldens to each other in both
  directions. Corpus and golden regeneration is closed: the corpus is frozen input, the
  goldens are snapshot pins taken once from the Python tree's answers, and the tooling that
  took them (and the port's `drive.exe` that used to print the other half) is deleted, so a
  golden moves only by an edit in the change that moves it. The differential suite is a
  behaviour baseline, and `plans/evidence-tiers.md` says what that is evidence of.
- **A live run is evidence only once it is recorded.** `dune runtest` dials
  nothing, by construction. The live half is `seekwright-live` behind
  `SEEKWRIGHT_LIVE_TESTS=1`: exactly one named case per invocation, no `all`, no
  `*`, no empty selector; missing configuration skips with the variable named and
  exits 0; a quota or rate limit exits 3 and is **inconclusive**, never a pass.
  After a passing run, the same change adds a row to the live-run table in
  `plans/seekwright-ocaml-port.md`, flips `ocaml_live_tested` on that name's
  `Registry` row and — for a fetch or agent case — adds the selector to
  `Cases.recorded_non_provider_runs`. Never through a config key.
  `live/test_live_cases.ml` pins the inventory and every assertion arm
  hermetically, so an arm that never fires fails a suite instead of letting a
  live case pass vacuously.
- **`exa:free` and `parallel:free` are providers, not live cases.** A colon is a
  provider flavour and is parsed before the `fetch:` / `agent:` prefix split, so
  the free names get the bare provider selector; the cases are the seventeen
  names, six `fetch:*` selectors and `agent:brief` / `agent:report`.
- **A free tier is an account quota, not an exemption.** `Config.keyless_providers`
  is the three names that need no account, no key and no card; `Config.free_providers`
  is the wider set a `mode="free"` route may walk, and it excludes every name
  whose free tier can meter into a bill — a metered tier is out of the free walk
  by construction. So `tavily`, `search1api`, `serpapi`, `querit` and `algolia`
  need their `SEEKWRIGHT_*_API_KEY` like any other name, and a config that
  enables one without it is startup-fatal.
- **The keyless set is the empty-set rule, not a fallback.** A config that
  enables nothing resolves to `exa:free`, `parallel:free` and `freeserp` rather
  than to nothing, and both the startup line and `--check` print the resolution;
  `Config.enabled_providers` is the single reader they report from.
- **Extraction is the `stdlib` backend only, and that is measured.**
  `Config.known_extractors` is `["stdlib"]`, and `trafilatura` is refused at load
  rather than at the first fetch. No backend claims a PDF media type, so a
  fetched PDF is a named refusal. `test/corpus_html/` plus
  `ocaml-tools/extract_bench/` hold the fixture corpus, the per-case quality bar
  (`cases.json`, enforced by `bench.exe --check`) and the byte digests of each
  side's `stdlib` output — a quality bar cannot pin bytes, so
  `digest_cases.exe --check-parity` does.
- **The corpus bar is a wall-clock ceiling, so it is load-sensitive.** A single
  miss on a busy three-CPU host is reported, not hidden, and the bar is not to be
  moved to make a run green.
- **Two config keys are read and refused**: `logging.library_level` and
  `logging.access_log`, because there is no per-request server loop whose
  loggers or access line could honour them. Refusing is the honest answer;
  ignoring is not: `ocaml-docs/configuration.md` names both as refused, and the
  `test_config.ml` resolve cases pin the refusal.
- **The drain has one owner and two suites.** `test_drain.ml` drives the stopping
  state in-process (both `Drained` and `Grace_expired`); `test_binary_drain.ml`
  sends a real SIGTERM to `bin/main.exe` over a raw loopback socket and pins the
  503 sentence, the refused reconnect and exit 0. Anything that lengthens
  shutdown has to satisfy both.

## Documentation

`ocaml-docs/` is the whole operator-facing doc tree, and every page in it
describes this tree only: `configuration.md` (every key this build reads, refuses
or ignores, the flags and the exit codes), `reference-config.md` (the example
`test_config.ml` loads), `container.md` (the image, its base, the scan, the
runtime contract), `deploying.md` (the two role configs `test_config.ml` loads),
`egress.md` (what the process dials, per row), `divergences.md` (what behaves
differently from a Python deployment — read it before promising parity),
`testing.md` (the gate and its pins), `live-tests.md` (what has run live, against
which commit, and what has not), `privacy.md` (what is written to disk and to the
log).

`README.md` is the front door and nothing else: what the thing is, how to run it,
where the detail lives. Usage prose lives there because the binary has no help
screen. `CONTRIBUTING.md` is the shorter path to these conventions plus the
provider checklist; it must agree with this file rather than extend it.
`SECURITY.md` owns the disclosure scope, the egress stance and the release
caveats.

There is **no changelog**: a change a consumer sees lands in the `ocaml-docs/`
page that owns it, with its reasoning beside the rule and in the pull request.
What is not built yet belongs in `plans/`, never in a release note. Page content
is load-tested rather than quoted — `test_config.ml` parses the example and both
role blocks through the real loader, so a page cannot offer a key the parser
refuses — which is what makes a docs change a reviewed change.

Pages and comments name a **symbol** or a page and its section, never a line
number, for the reason given under Conventions: the number is the one fact about
a file that is guaranteed to move and the one fact no check reads. Nothing in
this tree enforces that rule mechanically, so it is a review obligation on every
documentation and comment change — `ocaml-docs/`, `plans/` and this file
included.
