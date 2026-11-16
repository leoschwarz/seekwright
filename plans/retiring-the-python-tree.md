# Retiring the Python tree

Status: **executed 2026-11-16.** `src/`, `tests/`, `docs/`, `tools/`,
`pyproject.toml`, `uv.lock`, `.python-version`, the Python `Containerfile` and
its `.containerignore` are gone from this branch. The gate — `dune build
@install`, `dune runtest --force`, `dune build @doc` — is green with them gone,
and it was rehearsed that way before the deletion: the tree was hidden and the
same 2248 cases ran. `plans/seekwright-ocaml-port.md` §38 records a change
request that tried the deletion alone and was rejected for protected-path
scope; this page is the order that made it possible, not a re-litigation of
that review.

## The freeze

**The differential goldens are frozen.** `test/differential/corpus/` and
`test/differential/golden/` — 413 pairs over ten areas, 322 agreements and 91
registered divergences — stay committed, keep running under `dune runtest`, and
are never regenerated again. Stated as rules, so nobody rediscovers them:

- No new corpus case, no new area, no re-pinned golden. Editing a golden by hand
  is not the workaround: it deletes the only comparison left and turns a pin into
  an assertion about the port's own current answer.
- A registered divergence can no longer close. The reason each one was accepted
  now lives in `test/differential/divergences.tsv`, and the matrix suite refuses
  a golden marked `explicit-divergence` with no row, or a row with no golden.
  Closing a difference would mean re-deriving the answer from an implementation
  that is no longer in the tree, so the TSV is a record, not a to-do list.
- `ocaml-tools/oracle/`'s generators and the oracle half of
  `ocaml-tools/extract_bench/` (`py_bench.py`, `py_digest.py`, `derive_bars.py`,
  `dump_case.py`, `metrics_table.py`) are deleted: they imported the package and
  could not run once it was gone. What they produced is the baseline; what only
  they knew — the divergence reasons — is data now.
- `test/corpus_html/cases.json`'s per-case bar stops being a comparison and
  becomes **this port's own** bar: the numbers were derived from `trafilatura`
  runs, which the tree can no longer reproduce. Their provenance is in
  `ocaml-docs/testing.md`; re-deriving them would need the Python environment
  back.
- What the baseline is still worth: it refuses a silent behaviour change. Ten
  areas of routing verdicts, refusal sentences, config parsing, wire-field rules,
  text semantics, fetch guardrail verdicts, the JSON and table path grammars,
  adapter request shapes — a refactor that moves an observable answer fails a
  suite instead of a review.

For what each kind of evidence proves, and which claims currently rest on the
baseline alone, read `plans/evidence-tiers.md`.

## The decision, taken

**The OCaml binary is the published artifact.** Nothing ships from this tree
except the image, so the release lane moved with the deletion rather than
before a later release. The next ship happens when this branch lands on `main`;
no Python release is planned in between.

## Executed (2026-11-16)

| was | now |
|---|---|
| `ocaml-tools/dune` diffed `surface.exe --python-body` against the body of `docs/reference/surface.md` | `surface.expected` is the sole manifest golden for this tree; the body pair is gone |
| six `runtest` rules diffed `lib/prompts.ml` and `lib/dashboard_html.ml` literals against `src/seekwright/resources/` | six committed `.expected` goldens in `ocaml-tools/` (byte-identical copies taken while the cross-tree diff was green), diffed against `resources.exe`'s output |
| `test_config.ml` parsed and loaded the first TOML example, the `## Secrets` block and the two role blocks out of `docs/reference/configuration.md` and `docs/reference/deploying.md` | `ocaml-docs/reference-config.md` and `ocaml-docs/deploying.md`, port-owned and load-tested; the example omits `library_level`/`access_log`, which this port refuses at a non-default value |
| the four matrix TSVs carried `oracle` / `oracle_suite` / `oracle_adapter` / `oracle_consumer` columns, and `test_differential_matrix.ml` resolved `.py` pointers into `src/` and `tests/` | a `baseline` column naming the surviving evidence (`differential:<area>`, or the pinning suite); the validator resolves port-owned `.ml` pointers only |
| `tools/egress_lists.py` read the endpoints out of `src/` with `ast` and `ci.yml` ran its `--check` | `ocaml-tools/egress_lists.ml` prints the three lists from `Registry.rows` and `known_fetch_fallbacks`, and `ocaml-tools/dune` diffs each against `deploy/compose/generated/` on every `runtest` |
| `ci.yml`: uv lock/sync, the three Python `--check` instruments, ruff, ty, pytest, the Python image build and scan, the compose bundle smoke, the wheel | `ci-ocaml.yml`: `gate` (the three dune targets — the frozen facts are pins inside `runtest`) and `compose` (build the image, bring the bundle up, prove both roles answer, refuse a `Host` they were not given, dispatch keyless search and refuse it on the fetch role) |
| `publish.yml` built a wheel asset and the Python image | `publish.yml` builds `Containerfile.ocaml`, gates it on trivy CRITICAL/HIGH, pushes the version tag and `:latest` to `ghcr.io`, and smokes the pushed image; no wheel, no PyPI |
| `deploy/compose/` ran two containers from the Python image behind a Squid pair, a CoreDNS resolver and socat ingress, all on `internal` networks | two services on one image, each on its own bridge with outbound NAT, publishing its own loopback port. **Posture change, stated:** this binary reads no `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`, so a proxy-oblivious app behind an internal network dials nothing — the bundle stopped enforcing the sink deny list and the lenient-versus-strict `fetch` choice, which now belong to the operator's firewall, fed from the rendered `deploy/compose/generated/` lists. `deploy/compose/squid/` stays as reference ACLs |
| `README.md` fronted the Python tree with `docs/` behind it | `README.ocaml.md` became `README.md`; `CONTRIBUTING.md`, `SECURITY.md` and `AGENTS.md` describe this tree. `SECURITY.md` moved DNS rebinding out of the out-of-scope list: the confined grant resolves once, vets every answer and dials the vetted address |
| provenance headers, `dune` comments and `ocaml-docs` cites named files in `src/`, `tests/`, `docs/` | they name what survives: the suite that pins the fact, or the port's own page |

## What it left behind

- `VISION.md`'s three pointers into `docs/` and its `uv sync && uv run seekwright` first
  run were retargeted on the maintainer's word, in the same breath as the deletion: the
  mechanism is the module map in `AGENTS.md`, the open work is `plans/`, the frozen
  surface is the printed golden `ocaml-tools/surface.expected`, and the first run is a
  built image. Its amendment log records that no goal, precedence line or non-goal
  moved — the artifact did.
- `ghcr.io/leoschwarz/seekwright` is private until the repository's package
  visibility is set to Public. The publish workflow's own smoke passes (it pulls
  with the pushing token); an unauthenticated `docker compose pull` does not.
  Operator-facing sentence in `ocaml-docs/deploying.md`; a repository setting, not
  a tree fact.
- The retired `tests/repo/test_skills.py` guard meant the usage skill could never
  carry install or key vocabulary. Nothing enforces that split mechanically any
  more; it is a review obligation on `skills/`.
- Dependabot has no opam ecosystem, so the two `.opam` manifests and their locks
  get no automated bump PRs. The pinned Node conformance fixture is deliberately
  left out of dependabot too: bumping it is a re-baselining exercise, not a
  dependency update.
- The conformance runner speaks streamable HTTP, but neither in-tree driver can
  point it at the compose listener without a `--url` mode
  (`run_live_application.sh` boots the binary itself). The compose job therefore
  asserts the transport directly, and its step comment says so.
- That compose job makes one real keyless `search` per run to prove the role can
  reach a provider. A provider throttle turns CI red; that is the price of the
  assertion, recorded in the step comment.
- `test/corpus_html`'s wall-clock bar is load-sensitive on a busy host, and the
  quality numbers in `cases.json` are now this port's own bar rather than a
  comparison.
- The only Python left in the tree is `test/conformance/compare_results.py` and
  `compare_application.py` — stdlib-only scripts that diff the official runner's
  JSON, called by the conformance drivers. They never imported `seekwright`.

## If new differential evidence is genuinely ever needed

Two honest options, and the choice is a decision rather than a fix: fetch the
Python tree on demand as an out-of-tree oracle (un-freezing the corpus and its
environment, and re-deriving the divergence record), or record that the
differential phase is closed and buy the equivalent with live runs —
`plans/evidence-tiers.md` names the four worth buying first.
