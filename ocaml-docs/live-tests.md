# Live tests (OCaml port)

The live harness is a separate binary, `seekwright-live`, built by
`dune build @install` to `_build/install/default/bin/seekwright-live`. It is the
port of `tests/live/test_live.py`'s assertions, and it is **not** in the container
image: the image ships the server binary only, so live verification runs from a
build tree or a CI job, never on a serving host.

The full contract — selectors, construction, what is printed, exit codes, how a
pass is recorded — is `live/README.md`. This page is the operator's half.

## Running one case

```bash
dune build @install
_build/install/default/bin/seekwright-live --list          # hermetic inventory
SEEKWRIGHT_LIVE_TESTS=1 _build/install/default/bin/seekwright-live freeserp
SEEKWRIGHT_LIVE_TESTS=1 _build/install/default/bin/seekwright-live fetch:local
```

Exactly one case per invocation, and the gate variable must be set: without
`SEEKWRIGHT_LIVE_TESTS=1` the process refuses with exit 2. There is no `all`, no
`*` and no empty selector, so a billed case always takes two deliberate acts.
Missing configuration **skips** with its reason and exits 0; a broken adapter
contract fails with 1; a quota or rate limit is 3, inconclusive, and is never
recorded as a pass.

Fixtures the harness reads from the environment (and the server does not):
`SEEKWRIGHT_SEARXNG_URL`, `SEEKWRIGHT_ALGOLIA_APP_ID`, `SEEKWRIGHT_ALGOLIA_INDEX`,
and for the agent cases `SEEKWRIGHT_AGENT_BASE_URL`, `SEEKWRIGHT_AGENT_MODEL`,
`SEEKWRIGHT_AGENT_API_KEY`, optionally `SEEKWRIGHT_AGENT_MODEL_TIMEOUT_SECONDS`.
Provider keys are read by the same adapter construction the server uses, named as
in [`configuration.md`](configuration.md).

## What is proven on this port today

| Date | Case | Commit | Result |
| --- | --- | --- | --- |
| 2026-11-13 | `freeserp` | `73fcf73` | passed, 6/6 (keyless) |
| 2026-11-13 | `anysearch` | `73fcf73` | passed, 6/6 (keyless, POST-only endpoint) |
| 2026-11-14 | `freeserp` | `4b6b443` | passed, 6/6 (keyless) |
| 2026-11-14 | `anysearch` | `4b6b443` | passed, 6/6 (keyless) |
| 2026-11-14 | `exa:free` | `4b6b443` | passed, 3/3 (keyless, anonymous MCP endpoint) |
| 2026-11-14 | `parallel:free` | `4b6b443` | passed, 3/3 (keyless, anonymous MCP endpoint) |
| 2026-11-14 | `fetch:local` | `4b6b443` | passed, 5/5 (keyless read of a public page) |
| 2026-11-14 | `fetch:metadata` | `4b6b443` | passed, 3/3 (the cloud-metadata refusal is the assertion; no endpoint was dialed) |

That is the whole record: **no billed endpoint has been contacted from the OCaml
build**. The four keyed fetch fallbacks — `fetch:jina` apart, which is keyless
but was not selected — `fetch:scrappa`, `fetch:tavily` and `fetch:linkup` have
never run against their real endpoints, and neither has an agent case, which
would need an operator model endpoint. Those cases are built, and
`Checks.verify_fetch` now asserts each one's page shape; `live/test_live_cases.ml`
pins those arms offline, so an arm that never fires fails a suite rather than
letting a live case pass vacuously. But "built and asserted offline" is not
"live-verified", and none of those four names may be described as verified
against its vendor until a gated run records one.

`--check` says the same thing at startup: enabled names never live-verified in
this build appear on its `untested` line, and a reachability probe does not move
a name off it. The keyless default set — `exa:free`, `parallel:free`, `freeserp`
— no longer appears there, because each of the three has a recorded run.

## Recording a pass

A live run is evidence only once it is written down, and the rule is
`live/README.md`'s "Recording a run": a row in the live-run table of
`plans/seekwright-ocaml-port.md`, `ocaml_live_tested` flipped on that row's
`Registry` entry in the same change, and for a non-provider case the selector
added to `Cases.recorded_non_provider_runs`. Never through a config key, and
never for an inconclusive run.
