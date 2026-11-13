# Oracle tooling for the differential harness

The Python side of the F0.1 harness. Everything here reads the Python tree
(`src/`, `tests/`, `docs/`) **read-only** and writes only under
`../test/differential/`. Nothing in this directory is on the serving path, ships
in a package, or runs during `dune runtest` — the gate consumes the pinned
goldens, not Python.

| Tool | What it does | Run |
| --- | --- | --- |
| `gen_corpus.py` | Writes every corpus input under `test/differential/corpus/`. The case lists in this file are the reviewable form of the corpus: a reviewer reads the matrix of cases here rather than diffing 173 files. It reads no oracle and no port. | `python3 ocaml-tools/oracle/gen_corpus.py` |
| `projections.py` | The oracle half of each area: the same projection the OCaml side writes, expressed against `seekwright`'s own modules and canonicalised the way `test/differential/canon.ml` does. | imported by `gen_goldens.py` |
| `gen_goldens.py` | Runs both projections over one corpus directory and writes one golden per case. | see below |
| `gen_matrix.py` | Writes the four parity tables under `test/differential/matrix/`. The TSVs are committed data; the validator reads the tables, not this generator. | `python3 ocaml-tools/oracle/gen_matrix.py` |

## Re-pinning the goldens

```bash
dune build test/differential/drive.exe            # the port half, if it changed
uv run python ocaml-tools/oracle/gen_goldens.py [area ...]
```

`uv run` is what puts the Python tree and its dependencies on the path; a bare
`python3` has no pydantic. Key variables (`SEEKWRIGHT_*_API_KEY`,
`SEEKWRIGHT_CONFIG`, the agent key) are cleared before any case runs, so a golden
cannot capture what the operator's shell exports.

The tool prints `MISMATCH <area>/<case>` with both answers and exits non-zero
without writing those goldens unless the difference is registered. Registration
happens here, in the open:

- `DIVERGENCES` maps `(area, case)` to the reason the two trees answer
  differently and why that is acceptable. The reason lands in the golden's
  `reason` header line, and the golden pins both answers.
- Two systematic shapes are classified instead of listed case by case, because
  they are single decisions with many instances: the port's `fetch.extractor`
  default being `stdlib` where the oracle's is `trafilatura` (a P6 backend
  decision), and pydantic's structured validation report where the port states
  one sentence. Each classifier is an exact structural check on the pair of
  answers, not a similarity threshold — anything that is not exactly that shape
  still aborts.

An unexplained mismatch is never a silent golden. Either the projection that
drifts gets fixed, or a reason gets written here and the difference becomes
evidence the suite keeps.

## What this tooling deliberately does not do

- It never writes outside `test/differential/`, and never reads a live endpoint.
  Provider adapters are exercised through the projections, which call the pure
  parts of the Python tree; live provider behaviour is the live lanes' job, not
  the corpus's.
- It never runs during `dune runtest`. A gate that shells out to `uv` would stop
  being hermetic and would make the Python tree a build dependency of the port.
- It does not generate the corpus from a fuzz or a random walk. Random inputs
  make a golden suite unauditable; every case here is written down with a name
  that says what it pins.
