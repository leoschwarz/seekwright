# Vision

What this project is for, what it will refuse, and which good wins when two collide.
Every task and decision steers by this page; if a task cannot be reconciled with it, the
reconciliation is a dated entry in [`docs/decisions.md`](docs/decisions.md). The mechanism
is [`docs/architecture.md`](docs/architecture.md), the open work is
[`docs/ROADMAP.md`](docs/ROADMAP.md), and every name a caller may depend on is
[`docs/reference/surface.md`](docs/reference/surface.md).

## Possibilities

- **Every provider worth using, behind one shape.** Search, extraction and answering
  reached as three operations whatever vendor answers, so a calling model never learns a
  vendor's request format.
- **A first run with nothing to arrange.** `uv sync && uv run seekwright` searches with no
  account, key, card or config edit.
- **A router the caller can afford.** With nothing named, a search may pick by a declared
  priority — cost, quality, task — but only where it can state the price and the evidence
  for its pick.
- **Answers that can be checked.** `answer` writes prose over pages the server retrieved
  and publishes only the citations it validated.
- **One person can run it.** A single process, no database, no cache, no account system,
  observable from logs and a dashboard.

## Main goals

- A fresh clone searches and fetches before any configuration exists.
- Every response names the provider or fallback that served it, and the price it declared.
- Adding or removing a vendor is configuration, not code.
- The surface is enumerable and checked: the three tools and every frozen name move only
  through a dated decision.
- An `answer` citation resolves to a page this deployment actually retrieved.

## Diagnosis

Vendor APIs differ in shape, price and quality, and they churn. Free tiers are metered, so
"free" is a quota with a delay rather than a property. A model caller cannot be trusted to
know which vendor it is spending, and an operator who runs a proxy privately will not
accept a second service to operate for auth, storage or accounting. What is hard is not
calling an API; it is keeping the price, the provenance and the surface honest while the
vendors behind them change.

## The bet

One honest proxy over many providers beats both a single-vendor integration and a
meta-router that hides which vendor answered. The cost accepted: the caller names a
provider or inherits a declared default, and everything that needs shared state — accounts,
tenancy, a cache — stays out even where it would be convenient.

## Precedence

Highest first. When two collide, the earlier line wins.

1. **A caller's explicit input beats every server policy.** A named provider is dispatched,
   a named cap is honoured, a named fallback is the one tried. Defaults and routing only
   fill in what the caller left unnamed.
2. **What leaves the server stays safe.** SSRF bounds, redaction and sanitisation are not
   configurable off, and no convenience removes them.
3. **Coverage beats surface stability.** A useful provider or extraction endpoint is added
   even though it widens the name set and the config; widening a frozen name is a decision,
   not a reason to refuse.
4. **Honest cost beats convenient spending.** No call bills at a price the caller did not
   choose. An unnamed search uses names that cannot bill; a router that picks by cost,
   quality or task is allowed only once it can state the price it picked.
5. **One-operator operability beats multi-user features.** No auth, tenancy, cache or
   stored corpus, even when that costs a shared deployment.
6. **Measurement beats judgement for a default — and a caller's explicit value beats both.**
   A default is the server's best reasoned answer, configurable by the operator and
   overridable per call.

## Non-goals

- **No accounts or authentication on the listener.** Forbids sign-in, tokens, OAuth,
  per-caller identity and per-caller quotas; one deployment serves one operator's keys.
- **No cache and no stored corpus.** Forbids a result cache, a replayed index and a
  news/corpus operation; every search reaches a provider.
- **No inferred routing from the query.** Forbids a classifier that reads the question and
  silently spends on a vendor; a task route must be declared by the caller.
- **No silent escalation to a billable rung.** Forbids a walk that hides which vendor
  answered or bills without the caller's setting allowing it.
- **No model-driven retrieval loop inside the server.** Forbids `answer` deciding to run
  another search; its plan is fixed and costs a bounded amount by arithmetic.
- **No scraped results pages as providers.** Forbids a parser over a search engine's HTML;
  a provider needs a documented endpoint and terms.
- **No egress allow-list inside the application.** Forbids a second copy of the
  deployment's network boundary; which hosts are reachable follows from which names are
  enabled, and the network layer enforces the rest.

## Amendment log

- **2026-10-27** — written. Precedence settled by the maintainer: explicit caller input
  first, coverage over surface stability, one-operator operability over multi-user, and a
  priced router as a future possibility rather than a refusal.
