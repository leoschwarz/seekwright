# Roadmap

What is not built yet, and what holds it. Delivered behaviour is in the code and in
`git log`, and the page that owns a rule carries its reasoning.
Project intent — goals, precedence and non-goals — is [VISION.md](../VISION.md), and how
the pieces fit is [architecture.md](architecture.md).

## Distribution

The release lane exists: a `v*` tag builds the wheel and an amd64 image, files the wheel
on the GitHub Release and pushes `ghcr.io/leoschwarz/seekwright:<tag>`
([runbook](reference/publishing.md)). Open:

- **PyPI.** No `uv publish` step and no token, so there is no bare `uvx seekwright`; the
  install stays the clone plus `uv sync`. It also waits on a question this release does
  not answer: whether the contract should ship as a Python library at all, given that the
  implementation may be rewritten once the surface settles.
- **A moving `latest` tag.** The lane publishes the tag name and nothing else.
- **A multi-arch image.** amd64 rather than fighting QEMU emulation on the runner.

## Cost drift

The dashboard counts spend; nothing measures **drift** between the recorded `cost_usd`
and the "as of" prices in [providers.md](reference/providers.md). Tavily's
`reported_cost_usd` checks the credit count, not the price, because both figures come
from the same `cost_per_1k` ([metrics.md](reference/metrics.md) reads a shortfall against
the error rate).

## Defaults by measurement

`max_snippet_chars=500`, `max_result_text_chars=2000`, `min_text_chars=200`,
`max_results=5` and the `scrappa` default were argued, not measured. The gold set that
would move them is operator-local scratch: tooling and dataset are not in the tree.
Gates before a number moves a default:

- human calibration votes against the agent verdicts (the last export held `185` rows and
  no human ones);
- a floor on `n` per task class, rather than "a bigger n";
- queries for the `extraction` class.

## Routing by task

`search(mode="free")` is built. The reserved second member, routing by task, is declined
until the gold set's per-task numbers exist: it picks a provider and a price the caller
never named. If it lands it must take a caller-*declared* `task`
(`extraction`/`lookup`/`answering`), never inferred from query shape, and it starts in the
free-set-restricted form, which cannot bill. It moves the frozen `search.mode` value set,
so it arrives as a decision.

## Agent mode

`answer` is built and off by default; its contract is
[agent-mode.md](reference/agent-mode.md). Open:

- whether a second model is worth supporting;
- whether the model's endpoint deserves a circuit breaker;
- whether the citation signal is good enough to move `default_provider` without measured
  per-task numbers — it is a live signal, not a replacement for the gold set;
- offering it to more than one operator, gated on auth and on a per-caller budget.

## Free-provider coverage

Whether the tree is leaving free coverage on the table is
[free-providers-survey.md](reference/free-providers-survey.md)'s verdict, not a work
item: it tests candidates against tier 1's criteria and rejects results-page parsers.
`jina` is the one candidate that has landed; anything else follows the survey.

## Per-fallback fetch pricing

One `[fetch] cost_per_1k` prices whichever fallback bills. A per-fallback override needs
the serving fallback on the journal line or on `FetchResponse`, both frozen sets, so it
asks before it adds. A further fallback otherwise costs one registry row, an endpoint
constant and a value-set move.

## Module splits

Deferred, not done: `fetcher.py` split along the `extractors/` convention (past 1,600
lines, four backends, the whole SSRF surface and `KNOWN_FALLBACKS`) and `cli.py` with its
`--check` diagnostics separated from its REST client (~1,330 lines, `main` at cyclomatic
complexity 22). The hazard in the second is the freeze: the three client verbs and the ten
server flags live there, so a split moves `tools/surface.py`'s read table and
[surface.md](reference/surface.md) must come out byte-identical.
