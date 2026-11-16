# The frozen differential baseline

This directory has no generator left. It keeps the record of how the baseline
under `test/differential/` was produced, and why a divergence in it is accepted
rather than a bug to chase.

**Generation is frozen.** The corpus under `test/differential/corpus/` and the
goldens under `test/differential/golden/` *are* the baseline: they are the
answers the Python implementation gave, written down once, read-only for this
branch. Nothing here regenerates them, and `dune runtest` never needs a Python
interpreter, a provider endpoint or a network — it runs the port's own
projection and diffs it against the pinned answer.

Re-deriving the baseline would need a checkout that still carries the
implementation the baseline was taken from: the corpus generator read the
implementation's `docs/reference/` pages, the oracle projections imported the
implementation's own modules, and the golden generator drove both projections
through the dependency set that implementation pinned. This branch carries none
of that, so a re-derivation here would be a new oracle, not the same one — a
comparison against a different authority dressed as a refresh. If the baseline
ever has to move, do it from such a checkout, and treat the result as a new
baseline rather than a correction.

## Where the accepted divergences went

The reason beside each accepted behavioural divergence is now data, not code:
`test/differential/divergences.tsv` has one row per registered divergence —
`area`, `case`, `reason` — and `test/differential/test_differential_matrix.ml`
holds it and the `explicit-divergence` goldens to each other in both directions,
including the `reason` header the golden was pinned with. There is no
`DIVERGENCES` dict to edit any more; adding a row to that TSV is how a
divergence is registered.

Two differences are classified systematically rather than listed case by case,
and both are recorded in `test/differential/README.md`:

- **the wording rule** — same verdict, different sentence. The Python tree's
  validator reports a structured validation list; the port states one sentence
  naming the key and the fault. The golden keeps both sentences.
- **the extractor-default rule** — the port has one extraction backend, so its
  default `fetch.extractor` is `stdlib`; the oracle's default was `trafilatura`,
  a library this tree carries but the port has not wrapped. A P6 backend
  decision, and the port refuses any other name.

A family member carries the rule's reason and no TSV row. Everything else that
answers differently from the baseline is a row, or the suite fails: an
unexplained mismatch was never a silent golden, and after the freeze it is not a
silent row either.

## The extraction benchmark's Python halves

`ocaml-tools/extract_bench/` keeps its OCaml programs — the bar and metric
definitions, the fixture check, the bench and the digest runner — and none of
the Python scripts that once printed the three-backend table and the oracle's
digests. Those scripts read the implementation this branch deleted, so like the
oracle generators they cannot run here; the table they produced is recorded in
`plans/seekwright-ocaml-port.md`, the oracle's parity digests are committed
beside the corpus in `test/corpus_html/parity/`, and the gate checks the
port's own half.
