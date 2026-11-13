# The OCaml live harness

`seekwright-live` is the port's explicit live runner: one named provider, fetch
or agent case per invocation, a gate variable that must be set, and the live
assertions ported per adapter from `tests/live/test_live.py`. It is the F4.3
acceptance instrument from `plans/ocaml-finalisation.md`, not part of the
hermetic gate.

The Python suite is the oracle and stays read-only. This harness re-implements
its *assertions* — a SERP backend fills `snippet` and never `text`, a content
backend the reverse, a domain filter constrains the returned URLs — against the
OCaml adapters, so a passing run says something about the port rather than about
a call having returned.

## Running it

```sh
dune build @install                      # builds _build/default/live/main.exe
_build/default/live/main.exe --list      # hermetic: the inventory
SEEKWRIGHT_LIVE_TESTS=1 _build/default/live/main.exe freeserp
SEEKWRIGHT_LIVE_TESTS=1 _build/default/live/main.exe fetch:local
```

`--list` and `--help` are gate-free and dial nothing. A run needs
`SEEKWRIGHT_LIVE_TESTS=1`; without it the process refuses with exit 2.

Exactly one case is accepted. The default is **no provider**, never "all
configured providers": there is no `all`, `*` or empty-string selector, and a
name is reached only by naming it on a gated invocation. A billed case therefore
requires two deliberate acts — set the gate and spell the case.

Missing configuration skips the case rather than failing it: an absent key, or a
`searxng` instance with no `url`, prints the reason and exits 0. An unexpected
call or a response that breaks its adapter's contract fails.

Exit status:

| code | meaning |
|------|---------|
| 0 | passed, or skipped with its reason printed |
| 1 | failed: a contract assertion did not hold |
| 2 | refused or misused: gate unset, no case, more than one, unknown name |
| 3 | inconclusive: quota or rate limit, so the parser is unproven |

A rate-limited run is **not** a pass. The engine appends its "Do not retry
immediately." advice on the quota branch, which is what the runner reads to
report inconclusive instead of failed.

## Selectors

- **Provider** — the seventeen frozen names, including the flavours
  `exa:free` and `parallel:free` (parsed before the namespace split, so a
  colon is a provider, not a fetch/agent prefix).
- **Fetch** — `fetch:local`, `fetch:metadata`, `fetch:jina`, `fetch:scrappa`,
  `fetch:tavily`, `fetch:linkup`.
- **Agent** — `agent:brief`, `agent:report`.

A case this build cannot run yet skips with the wave that lands it (`F5.1`… for
providers, `F6.1` for fetch fallbacks). `--list` prints each case's build
status, OCaml live status, spend class and required environment.

## Construction follows the application

The harness does not build a private stack:

- a provider case builds through `Seekwright_factory.Factory.build_providers` and
  one `Engine.Search`, so a named provider is terminal exactly as it is when
  served;
- a fetch case builds through `Factory.build_fetch_stack` and one
  `Engine.Fetch`, and closes the stack afterwards so a selected case leaves no
  reader or worker pool behind;
- an agent case builds the whole app through `Factory.build_app` (only
  `freeserp` enabled, so the unnamed route is free-only) and answers through its
  agent engine.

`fetch:metadata` is the one case that expects an error: the public-web grant must
refuse `169.254.169.254` before a request leaves, so an answer there is a failed
run.

The provider config the harness builds is env-driven where a name cannot run
without an instance or an index: `SEEKWRIGHT_SEARXNG_URL`,
`SEEKWRIGHT_ALGOLIA_APP_ID`, `SEEKWRIGHT_ALGOLIA_INDEX`. Agent cases read
`SEEKWRIGHT_AGENT_BASE_URL`, `SEEKWRIGHT_AGENT_MODEL` and
`SEEKWRIGHT_AGENT_API_KEY` (and optionally
`SEEKWRIGHT_AGENT_MODEL_TIMEOUT_SECONDS`) through the same construction the
server uses. Provider keys are read by the adapter construction that has always
read them; the harness only names the variable in its header.

## Nothing secret is printed

The header prints the route as `scheme://host` (or a phrase for a
config-supplied destination), the credential as the **variable name**, and a
spend sentence. It never prints a key value or a URL query. The route, cost and
needs columns come from `Registry` rows and `Cases`, so the harness cannot drift
from what `--check` reports.

## Recording a run

A live run is evidence only once its facts are in the plan. After a run:

1. add a row to the live-run table in `plans/seekwright-ocaml-port.md` with the
   date, case, branch commit, result and any inconclusive reason;
2. when a provider passes, flip `ocaml_live_tested` for its `Registry` row in the
   change that records the run — a name leaves the OCaml-untested set only
   there, never through a config key;
3. a fetch or agent case has no registry row, so add its selector to
   `Cases.recorded_non_provider_runs` in the same change.

A rate-limited or quota-exhausted result is recorded as inconclusive and does not
flip the status: it proves nothing about the parser.

## Hermetic coverage

`live/test_live_cases.ml` runs under `dune runtest` and dials nothing. It pins
the inventory (seventeen providers, six fetch cases, two agent depths), the
selector rules (no all-providers spelling, `exa:free` stays a provider), every
per-adapter assertion against synthetic responses, the absent-key/no-secret
paths, and the consistency between `Cases.live_status` and the registry row. The
running half is in `runner.ml`; the pure halves are `cases.ml` and `checks.ml`.

Adding a case means adding its selector to `Cases.all`, its steps and assertion
arm to `Cases.provider_steps`/`Checks.provider_step`, and a hermetic case for
the new arm. `Checks.provider_step` fails loudly for a name with no arm, so a new
provider cannot arrive with a generic "returned something" check.
