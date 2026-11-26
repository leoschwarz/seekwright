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
- The last two Python files are gone as well. The conformance comparators are
  `compare_results.ml` and `compare_application.ml` over one shared reader,
  `compare_common`, and the drivers call `manifest_check.exe` and
  `readiness_check.exe` for their own two checks instead of embedding an
  interpreter. The port and its evidence are the section below.

## The last two scripts, ported (2026-11-21)

| was | now |
|---|---|
| `compare_results.py` scored the fixture run and `compare_application.py` the application run, each holding its own copy of the grammar for reading the runner's output directory | `compare_results.ml` and `compare_application.ml` over one library, `compare_common`: the manifest line grammar, the `runner list --requirements` section grammar, the result-directory name grammar, the `checks.json` reader, the duplicate-key-refusing JSON reader, the report writer. Two readers of that grammar could drift, and the drift would surface as a gate that stopped failing closed rather than as a failing build |
| the drivers reached for an interpreter four times: a `python3 -` heredoc importing `compare_results.py` to check the pinned manifest against the runner's own list, a heredoc asserting the readiness body was a JSON-RPC result, a heredoc probing whether the server's port had closed, and a `python3 -c` picking a free loopback port | `manifest_check.exe` and `readiness_check.exe`, reading through the same module as the comparators, plus bash's own `/dev/tcp` redirection for the two port probes. The drivers hold no language of their own now |
| the reader treated the end of the runner transcript as a terminator for the scored section, and a stat of a missing directory raised | the shared reader requires the next section header, as the retired one did — a truncated transcript is a refusal, never a short expected set — and `dir_exists` is total as its interface promised: a results directory the runner never wrote becomes an error line, not an uncaught `Unix.Unix_error` |
| the two scripts were the parity reference, so a port of them could only be judged by reading both side by side | a throwaway differential harness generated 59 synthetic run directories — 47 for the results gate (required and pending modes, baseline validation, evidence rendering, run metadata, the list and unscored sets, the `checks.json` shapes) and 12 for the applicability gate — and compared exit code, stdout, every stderr line and the report JSON: **0 mismatches**. One accepted divergence: a manifest with a duplicate ID, where the script died with a CPython traceback and the port refuses with a single sentence and writes no report. The harness and both scripts are deleted; what they established is recorded here |

After the port, both live gates were re-run end to end through the OCaml
comparators: the fixture at **19 pass / 18 fail / 0 inconclusive** against
`expected-failures-2026-07-28-server.json`, the application at **90 / 90**
applicable checks over 177 classified. Both are written beside the older rows in
`test/conformance/README.md`, which owns the runner baselines. The four gate
targets — `@fmt`, `@install`, `runtest --force`, `@doc` — are green with no
Python anywhere in the tree.

## If new differential evidence is genuinely ever needed

Two honest options, and the choice is a decision rather than a fix: fetch the
Python tree on demand as an out-of-tree oracle (un-freezing the corpus and its
environment, and re-deriving the divergence record), or record that the
differential phase is closed and buy the equivalent with live runs —
`plans/evidence-tiers.md` names the four worth buying first.
