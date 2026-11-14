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

That is the whole record: **no billed endpoint has been contacted from the OCaml
build**, and no fetch-fallback or agent case has run live. `live/cases.ml` still
marks the `fetch:jina`, `fetch:scrappa`, `fetch:tavily` and `fetch:linkup` rows
`Deferred "F6.1"`, even though `Factory.build_fetch_stack` constructs those
fallbacks and the hermetic suites exercise them. So the fallbacks are built and
hermetically tested, and unverified against their real endpoints. Do not describe
them as live-verified until a gated run says otherwise.

`--check` says the same thing at startup: enabled names never live-verified in
this build appear on its `untested` line, and a reachability probe does not move
a name off it.

## Recording a pass

A live run is evidence only once it is written down, and the rule is
`live/README.md`'s "Recording a run": a row in the live-run table of
`plans/seekwright-ocaml-port.md`, `ocaml_live_tested` flipped on that row's
`Registry` entry in the same change, and for a non-provider case the selector
added to `Cases.recorded_non_provider_runs`. Never through a config key, and
never for an inconclusive run.
