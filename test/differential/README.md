# Differential harness and parity matrix (F0.1)

Two artefacts live here, and they answer two different questions.

- `matrix/` — *what is the parity story, row by row?* One row per provider, config
  key, behaviour and surface item, naming the consumer on both sides and the kind
  of verification that backs the claim. It is the inventory the finalisation plan
  asks for, and `test_differential_matrix.ml` keeps it honest.
- `corpus/` + `golden/` — *does the port answer the way the Python tree answers?*
  A case in, a pinned answer out, diffed by a plain `dune runtest`.

Nothing here reaches the network, a provider endpoint, an API key, or a Python
interpreter. The Python answers are pinned in `golden/`; the tooling that pins
them lives in `../../ocaml-tools/oracle/` and is never run by the gate.

## Layout

| Path | Role |
| --- | --- |
| `canon.ml` | The canonical rendering the corpus and goldens are written in: escaping, float formatting, sorted JSON, byte-as-hex. Shared by the driver and the runner, and mirrored by `ocaml-tools/oracle/projections.py`. |
| `projection.ml` | One projection per area: reads a corpus input, calls the port, renders answer lines. |
| `drive.ml` | `drive.exe <area> <corpus-dir>` — prints `case<TAB>line` for every input. Regeneration only; `dune runtest` never runs it. |
| `test_differential_golden.ml` | The golden runner. One test per golden, plus coverage and floor checks per area. |
| `test_differential_matrix.ml` | The matrix validator. One test per table, plus cross-checks against `Config.known_providers` and the corpus areas. |
| `corpus/<area>/` | The inputs, written by `ocaml-tools/oracle/gen_corpus.py`. |
| `golden/<area>/` | The pinned answers. |
| `matrix/*.tsv` | The parity tables, written by `ocaml-tools/oracle/gen_matrix.py`. |

## The golden format (v1)

One file per case: `golden/<area>/<case>.golden`. A header of `key: value` lines,
then the oracle's answer, then — only for a pinned divergence — the port's:

```
area: fetch
case: 08-url-port-range
verification: explicit-divergence
oracle: python
projection: fetch
reason: both trees refuse the URL; the sentence is each parser's own wording
--- oracle
url-refused= invalid port: Port out of range 0-65535
--- port
url-refused= invalid port: 99999 is not a port in 1-65535
```

- `area`, `case`, `verification`, `oracle`, `projection` are required; `reason`
  only accompanies an explicit divergence. `oracle` is `python` — the only oracle
  this harness has. `projection` must equal `area`: the runner refuses a golden
  that claims one area and sits in another's directory.
- `verification` is `differential-golden` (the two trees agree and the golden
  pins that answer) or `explicit-divergence` (they do not, the reason is on the
  record, and the golden pins both answers). The runner refuses any other value,
  so a golden cannot quietly invent a third kind of evidence.
- Determinism: the format carries no secrets, no timestamps, no absolute paths.
  Where a case involves a clock, the projection renders what the port computed
  (a day number, an elapsed comparison), never a wall-clock reading.
  `Canon.reset_key_environment` clears `SEEKWRIGHT_*` key variables at startup, so
  a golden cannot depend on the shell that runs the suite.
- Corpus input by area: `config` inputs are TOML, `sanitize` inputs are raw bytes,
  every other area is a JSON spec. The runner derives the input path from
  `area`/`case`, so a golden without its input is a failure, not an orphan.

## What the runner requires

For every golden: the input exists, the port's projection equals the pinned
answer, and the header is self-consistent. For every `explicit-divergence`
golden: a `reason`, a `--- port` section, the port still answering exactly that
section, **and** the port still disagreeing with the oracle — a divergence that
closes on its own fails the suite the same way a regression does, because the
golden and the `DIVERGENCES` entry in `gen_goldens.py` both have to change.

For every area: at least `min_cases` goldens (the floor list in
`test_differential_golden.ml`), and every corpus input has a golden. Those two
checks are what the plan's mutation requirement means in practice — emptying a
corpus or dropping an area thins the gate loudly instead of quietly.

## Mutation checks

Each of these is a demonstration that the harness fails on its own bookkeeping,
not only on the port. Run them from the repository root; each one restores
afterwards.

| Mutation | Result |
| --- | --- |
| delete `corpus/fetch/15-window-head.json`, leaving its golden | that case fails: *the golden has no corpus input* |
| add a golden whose input is not in `corpus/` | the same check fails on that golden |
| add `corpus/tabledoc/99-unpinned.json` with no golden | `coverage:tabledoc` fails: *an input nobody pinned is a case the gate does not run* |
| remove an area's `golden/<area>/` directory | `coverage:<area>` fails: *an area is added to the floor, the stanza deps, and the tree together* |
| change a `--- port` sentence in an explicit divergence | the case fails: *the port no longer answers as its divergence was pinned* |
| rewrite a golden's oracle section to match a pinned divergence | the case fails: *this divergence has closed, so the golden must become differential-golden* |
| delete a `matrix/*.tsv` | the table's test fails: *the matrix has no …* |
| put `unknown consumer` in any matrix cell | the table fails: *the matrix names a consumer or a verification, never a shrug* |
| point a matrix row at a module that does not exist | the table fails: *points at …, which is not in the sandbox the test runs in* |
| rename a matrix column | the table fails: *the header changed* |
| let a not-ported row claim a real verification kind | the table fails: *it must say which wave will verify it (pending-F\*)* |
| drop a provider row from `providers.tsv` | the cross-check fails: *only in the config: freeserp* |

## Regenerating

Only when a corpus case or an oracle answer legitimately changes. From the
repository root:

```bash
dune build test/differential/drive.exe        # the port half
python3 ocaml-tools/oracle/gen_corpus.py      # write the inputs (deterministic)
uv run python ocaml-tools/oracle/gen_goldens.py [area ...]   # re-pin the goldens
dune runtest test/differential --force        # the gate, with no Python involved
```

`gen_goldens.py` runs the Python projection and `drive.exe` over the same
directory and writes one golden per case. **An unregistered mismatch aborts the
run**: accepting a divergence is a decision made in that file, in the open, and
it lands in the golden's `reason` line. Two systematic shapes are classified
there rather than listed case by case — the extractor-default difference
(`trafilatura` vs `stdlib`, a P6 decision) and pydantic's structured validation
report vs the port's one sentence. Everything else must be named in `DIVERGENCES`.

`gen_matrix.py` regenerates `matrix/*.tsv`. The TSVs are committed data: the
generator exists so a wave can update a column mechanically, and the validator
reads the committed tables, not the generator.

### Adding a case, adding an area

A **case** goes in `gen_corpus.py` (the case list is the reviewable form; the
files it writes are not hand-edited), then regenerate that area. Both projections
must already handle it: a corpus input the port cannot read aborts regeneration
rather than pinning a golden.

An **area** costs four coordinated changes, and the harness refuses to run with
fewer than all four: a projection in `projection.ml` and the matching one in
`ocaml-tools/oracle/projections.py` (registered in `Projection.areas` and
`projections.AREAS`), a floor entry plus a glob pair in this `dune` file, and a
row in `behaviours.tsv` pointing at `corpus/<area>` — the matrix validator
compares those claims against the directories that actually exist.

## The matrix

Four tables, one row per thing that has to be equivalent:

| Table | Row per |
| --- | --- |
| `providers.tsv` | provider name — endpoint, auth, default price, timeout, constraint behaviour, result field, quota class, live status, port state |
| `config-fields.tsv` | config key — the consumer on both sides, and whether it is honoured, transitional, refused on the port, or declined |
| `behaviours.tsv` | behaviour — the oracle module and suite, the port module and suite, status |
| `surface.tsv` | surface item — the three tools, the REST routes, the operational paths, the CLI, the log and journal fields |

`test_differential_matrix.ml` pins the headers and column counts, requires every
cell to be filled, keeps the state/quota/live-status columns inside closed
vocabularies, and requires every verification cell to name a kind from the plan's
vocabulary — `unit`, `differential-golden`, `loopback-integration`,
`official-conformance`, `local-live`, `keyless-live`, `keyed-live`,
`explicit-divergence` — or to be an explicit `pending-F*` on a row whose port side
does not exist yet. A ported or honoured row resting on `pending` fails, and a
not-ported row may not claim a verification it does not have. Every `.ml`/`.py`
pointer a row names has to exist in the sandbox, which is what the source globs in
this `dune` file are for: a row crediting a consumer that was renamed away or
never written is a failure. The provider rows must be exactly
`Config.known_providers`, and the areas the behaviour rows claim must be exactly
the areas `corpus/` carries.

## Accepted divergences

`gen_goldens.py` is the source of truth: its `DIVERGENCES` table gives each
accepted difference a reason, and every one of them is pinned as an
`explicit-divergence` golden, so the suite notices if any of them changes shape.
There is no open gap left: `fetch/12-url-ipv6-broken` used to be one, and it is
now an ordinary `differential-golden` because the port refuses `http://[::1/x`
with the oracle's sentence.
