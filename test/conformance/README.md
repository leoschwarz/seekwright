# Conformance: the official MCP runner against the fixture and the application

This directory holds two live baselines over the same pinned runner, plus the
hermetic transcripts that run under plain `dune runtest`. The first
(`run_live.sh`, below) scores the mcp-caps conformance fixture. The second
(`run_live_application.sh`, "The application baseline") scores the real
`bin/main.exe` by *applicability to seekwright's three-tool surface*, because
counting how many of the runner's fixture-shaped scenarios an application
passes measures resemblance, not conformance.

Nothing here runs under plain `dune runtest` except the stdio transcript rules
at the bottom: the live jobs need Node and an npm fetch, so the Python suite's
hermeticity rule holds on the OCaml side too.

## What is pinned, and by which file

| Thing | Value | Where |
|---|---|---|
| official runner | `@modelcontextprotocol/conformance` `0.2.0-alpha.11` | `package.json`, `package-lock.json` |
| Node | >= 22 (the runner imports `globSync` from `fs`; on Node 20 it dies at import, so `run_live.sh` gates the version instead) | `run_live.sh` |
| required scenario set | 37 IDs, verified equal to `conformance list --server --requirements 2026-07-28` | `requirements-2026-07-28-server.txt` |
| unscored scenarios the same command also runs | 13 (ten `tasks-*` extension, `json-schema-2020-12`, `http-header-validation`, `http-custom-header-server-validation`) | parsed out of `runner-list.stdout` by the comparator |
| failure baseline | 18 scenarios, each naming its failing check IDs with a cause and a reason | `expected-failures-2026-07-28-server.json` |
| application classification | every scored and unscored check, classed `applicable` or excluded and carrying its recorded status | `application-classification-2026-07-28-server.json` |
| application comparator | fail-closed applicability gate; no expected-failures list | `compare_application.py` |

`run_live.sh` fails closed: exact required-ID equality (no missing, extra or
duplicate), then a required gate and a pending gate that treat an unexpected
failure, a missing `checks.json`, a runner error and a **stale** baseline entry
all as failures. Its artifacts directory keeps the raw runner stdout/stderr, one
`checks.json` per scenario, the fixture's stderr notes, the announced URL and the
commit the fixture was built from.

```sh
export PATH="$HOME/.local/opt/node22/bin:$PATH"       # Node 22, see plans/infra-setup.md
dune build test/conformance/fixture.exe
test/conformance/run_live.sh /tmp/mcp-caps-conformance-results
```

## Results, recorded 2026-11-11

Same machine (`vps-01`), same switch, same pinned runner and comparator for all
three rows. The fixture's `serverInfo` is `mcp-caps-conformance 0.1.0`.

| Server under test | `--requirements 2026-07-28` | Gate |
|---|---|---|
| **this fixture**, built through `Registry.add` + `Server.of_registry` | **19 pass / 18 fail / 0 inconclusive** of 37 | pass against `expected-failures-2026-07-28-server.json` |
| **control**: mcp-kit v0.2.0's own `test/conformance/server.ml`, compiled against this switch's mcp-kit 0.2.0 | **37 pass / 0 fail / 0 inconclusive** | pass against upstream's empty baseline |
| `examples/read_source.exe --http 8811` (as shipped, ad hoc — no gate) | 8 pass / 29 fail | — |
| `examples/gated_search.exe --http 8812` (as shipped, ad hoc — no gate) | 8 pass / 29 fail | — |

The control row is the one that makes the 19 readable. Upstream's claim of 37
passes (its `docs/conformance.md`) reproduces here — same wrapper, same pinned
runner, same manifest, same comparator, same switch — so the 18 failures below
are statements about what this fixture declares, not about the machine, the
setup or mcp-kit. `MCP_CONFORMANCE_FIXTURE_BIN` is what `run_live.sh` uses to
point at a different fixture; its `fixture-identity.txt` records which binary a
run drove (its `server-commit.txt` names *this* checkout either way).

The two example rows are the reason the fixture exists at all. The examples
declare no scenario-named tool, and every one of their eight passes is a
scenario that needs no named declaration — `tools-list`, `resources-list`,
`prompts-list`, `caching`, `sep-2164-resource-not-found`,
`server-sse-multiple-streams`, `input-required-result-unsupported-methods`,
`input-required-result-validate-input`. An empty `resources/list` validates, so
those eight are not evidence of a feature.

Unscored for this revision (13 scenarios, never in the 37): `http-header-validation`
(14 checks), `http-custom-header-server-validation` (10) and `json-schema-2020-12`
(8) all pass against this fixture; nine of the ten `tasks-*` extension scenarios fail
(`tasks-status-notifications` reports all checks skipped), and they fail
identically for the upstream control fixture, because mcp-kit 0.2.0
implements no tasks extension.

## What the fixture declares, and what reaches it

Six tools go through the capability layer (`fixture.ml`):

| Declaration | Grant | Scenario that reaches it |
|---|---|---|
| `test_simple_text` | `()` | `tools-call-simple-text` |
| `test_error_handling` | `()` | `tools-call-error` — the layer's `Error.t` → `isError` mapping, seen by the official runner |
| `test_logging_tool` | `()` | `server-stateless` / `sep-2575-server-no-log-without-loglevel` |
| `test_custom_header` | `()` | `http-custom-header-server-validation` — an `x-mcp-header` annotation this layer passed through untouched |
| `json_schema_2020_12_tool` | `()` | `json-schema-2020-12` — the runner's own Draft 2020-12 document (`$schema`, `$defs`/`$anchor`, local `$ref`, `allOf`/`anyOf`, `if`/`then`/`else`, `additionalProperties: false`) arriving on the wire as declared |
| `test_read_granted_file` | one `Fs` grant | no official scenario; it is the powered neighbour that keeps `tools/list` a mixed surface and answers the stdio transcript |

Two resources, one resource template and four prompts are added **directly to
the `Mcp_kit.Server.t` that `Server.of_registry` returns** — the seam §0 of the
plan names for what `Registry` does not cover. They carry `resources-list`,
`resources-read-text`, `resources-read-binary`, `resources-templates-read`,
`caching`, `sep-2164-resource-not-found`, `prompts-list`, `prompts-get-simple`,
`prompts-get-with-args`, `prompts-get-with-image` and
`prompts-get-embedded-resource`. A pass on those is evidence about mcp-kit and
about the seam, not about a grant, and it is reported that way rather than
folded into a capability claim.

The other passes need no declaration of their own: `completion-complete`,
`tools-list`, `tools-call-error`, `server-sse-multiple-streams`,
`dns-rebinding-protection`, `input-required-result-unsupported-methods` and
`input-required-result-validate-input` are answered by the adapter and by
mcp-kit's transport checks.

The 18 failures, per check with a cause and a reason, are
`expected-failures-2026-07-28-server.json`. They fall into three groups: rich
tool content and progress, which `Tool.Output` does not have (§3); the SEP-2322
interactive-tool scenarios, which need an input-required result and per-request
capability state that the layer declares neither (§0 non-goals, §3); and the
`server-stateless` MRTR diagnostics, same cause. `cause: unsupported_feature` in
that file means "this layer's declared v1 surface has no constructor for it",
never "mcp-kit fails it" — the control row shows mcp-kit passing all 37.

## The application baseline

`run_live_application.sh` points the same 50-scenario runner at
`bin/main.exe --http`, then scores it through
`application-classification-2026-07-28-server.json` and `compare_application.py`
instead of an expected-failures list. The question is not "how much of the
fixture's surface does seekwright resemble" — it deliberately has none of it —
but "is the surface it *does* declare MCP-conformant".

Every check carries one class:

| Class | Meaning | Gate |
|---|---|---|
| `applicable` | An obligation of the three-tool surface or the transport | must pass |
| `fixture-declaration` | Needs a tool, resource, prompt or annotation only the official fixture declares | recorded status must not change |
| `absent-feature` | Needs a capability outside the frozen surface (resources, prompts, rich content, progress, MRTR, completion, tasks) | recorded status must not change |
| `oracle-parity` | Fails identically in the Python implementation, so it distinguishes nothing | recorded status must not change |
| `port-divergence` | Fails where the Python implementation behaves differently; excluded here, reported in the plan | recorded status must not change, under protest |

A scenario is `applicable` (all its checks are obligations), `mixed` (some
applicable checks among exclusions), `fixture-declaration` or `absent-feature`.
The gate is fail-closed in both directions: every applicable check must pass,
and every excluded check must still have exactly the status the baseline
recorded. The runner's scored 37 and unscored 13 must also still be exactly the
classified sets, with exactly the classified check IDs per scenario — a runner
upgrade or a renamed check fails rather than shrinking the baseline.

### Measured 2026-11-13

Same machine (`vps-01`), same switch, same pinned runner as the fixture rows.

| Measure | Result |
|---|---|
| scored by the runner (`--requirements 2026-07-28`) | 8 pass / 29 fail of 37 — **not the gate, see below** |
| applicable checks | **90 / 90** (89 `SUCCESS` + 1 `INFO` from the optional-SSE check), 0 failures |
| scenario classes | 4 `applicable`, 3 `mixed`, 4 `fixture-declaration`, 39 `absent-feature` |
| check classes | 90 `applicable`, 73 `absent-feature`, 12 `fixture-declaration`, 1 `oracle-parity`, 1 `port-divergence` |
| gate | pass |

The four `applicable` scenarios all pass: `tools-list` (three tools, valid
names, valid wire schema), `server-sse-multiple-streams` (three concurrent POST
streams), `sep-2164-resource-not-found` (no empty contents, `-32602`, the URI in
`error.data`) and `http-header-validation` (14 checks: malformed method/name
headers rejected with the right code, whitespace values accepted, header names
case-insensitive). The runner leaves the last one unscored for 2026-07-28; it is
still an obligation here. The three `mixed` scenarios — `server-stateless`,
`caching` and `dns-rebinding-protection` — contribute their applicable checks to
the 90, and their exclusions are in the classification.

The raw 8/37 is written into `application-report.json` as a footnote, not a
score. Four scenarios the runner itself calls passing are **excluded**:
`resources-list` and `prompts-list` pass because mcp-kit answers an empty list,
and `input-required-result-unsupported-methods` and
`input-required-result-validate-input` pass because the unknown tool is refused
with `-32602` before any input-required path exists. An empty list and an error
path are not features. Reporting 8/37, or 12/37 by adding those four, would
misdescribe both the application and the runner.

### The two recorded differences

- **`oracle-parity`, `localhost-host-valid-accepted`.** The runner sends
  `Origin: http://127.0.0.1:8811`; both implementations allowlist bare loopback
  origins (`http://127.0.0.1`) and answer 403. The Python oracle fails this
  check identically, so it says nothing about the port. (The check also hardcodes
  port 8811 rather than the server's URL; a real client on a non-8811 port would
  hit the same 403 in both trees.)
- **`port-divergence`, `sep-2575-server-declares-prompts-in-discover`.** The
  OCaml server answers `prompts/list` and `resources/list` with empty arrays but
  its `server/discover` result declares only `tools`; the Python server's
  `MCPServer` declares `prompts` and `resources` as well. mcp-kit 0.2.0's
  `Server.of_registry` answers the list methods without adding the capability,
  so declaration and behaviour disagree on this port. Neither the mcp-kit
  dependency nor `lib/server.ml` is in F3.3's ownership; the difference is
  recorded here and in `plans/seekwright-ocaml-port.md` §F3.3.

### Running it

```sh
export PATH="$HOME/.local/opt/node22/bin:$PATH"
dune build bin/main.exe
test/conformance/run_live_application.sh /tmp/seekwright-application-conformance
```

The script starts the application on a free loopback port with a config that
builds only `freeserp`, uses the `stdlib` extractor and sets
`search.health_interval_seconds = 0`, so **no provider endpoint is contacted**
during the run. It records the commit, the working-tree status, the runner
version, the announced URL, the server's stderr, the raw runner stdout and one
`checks.json` per scenario, then writes `application-report.json`. The hermetic
half of the same evidence is `application_transcript.jsonl`: the runner-shaped
tool calls (missing argument, too-short string, out-of-enum provider, non-URL,
private address, agent disabled, unknown tool) and a modern `server/discover`
replayed through the real binary over stdio, with the answers pinned as
`application_transcript.expected` and an empty stderr as
`application_transcript_notes.expected`. `dune runtest` runs it; nothing in it
opens a socket.

## The stdio half

`conformance server` takes `--url` and nothing else: the pinned official runner
has **no stdio mode**. The stdio evidence in this tree is therefore not the
runner's:

- `transcript.jsonl` holds the JSON-RPC bodies the runner's scenarios send —
  legacy `initialize` / `notifications/initialized` / `tools/list` /
  `tools/call`, a modern `server/discover` and a modern `tools/call` with
  `_meta`, the two grant refusals, an unknown tool, a schema-violating argument,
  and the resource and prompt reads — and the dune rule in `dune` pipes them
  through `fixture.exe --root root --stdio` and diffs both streams against
  `stdio_transcript.expected` (15 answers to 16 bodies: a notification gets no
  line) and `stdio_transcript_notes.expected` (the startup notes, which must
  never reach the protocol channel). `dune promote` re-blesses.
- `test/test_http_transport.ml::same_transcript_stdio_and_http` is what makes
  that replay transfer to the HTTP run: the same bodies answer byte-identically
  over both transports, so the JSON-RPC semantics the runner scored over
  loopback HTTP are the ones a stdio session gets; only framing differs.

## Gaps found while running this, and closed in the same branch

Recorded 2026-11-11, in the order they were found:

1. `prompts-get-with-image` and `prompts-get-with-embedded-resource` failed on a
   missing declaration, not on behaviour. Adding the two prompts through the
   direct seam took the required tally from 17 to 19.
2. `server-stateless`'s `sep-2575-server-no-log-without-loglevel` needed only a
   tool that completes without a log notification — an ordinary `~grant:()`
   tool — so `test_logging_tool` went in. That scenario still fails, on its
   three MRTR checks.
3. `json-schema-2020-12` and `http-custom-header-server-validation` (unscored)
   were fixture gaps too. Both now pass, and they are the two most useful
   unscored scenarios for this layer, because both are about a *declared input
   schema* surviving the path `Tool.make` → `Registry.add` →
   `Server.of_registry` → mcp-kit intact.
4. The first pass of the fixture had no filesystem tool at all, which made
   `tools/list` indistinguishable from `examples/caps_echo.exe`.
   `test_read_granted_file` is the fix, and the stdio transcript reads through it.

## Provenance

`package.json`, `package-lock.json`, `requirements-2026-07-28-server.txt`,
`pending-2026-07-28-server.txt`, `pending-classifications-2026-07-28-server.json`
and `compare_results.py` are copied from mcp-kit v0.2.0 (`test/conformance/`),
and `run_live.sh` follows its `scripts/run_live_mcp_conformance.sh` — same
pinned runner, same manifest, same comparator, so the numbers above are
comparable to upstream's records rather than a new measuring stick. This
repository is Apache-2.0 (root `LICENSE`); the copied/derived upstream files
are MIT-licensed by the Epure Team and carry that notice in
`UPSTREAM-LICENSE.md`, which lists them. The archive the
switch installs is
`https://gitlab.com/nomadic-labs/ai-harness/ocaml-mcp/-/archive/v0.2.0/ocaml-mcp-v0.2.0.tar.gz`,
`sha256=43c8319a13be91e323ae952a71ab673533fb3295886029eed9d81e5828de5ef7`
(the `mcp-kit.0.2.0` opam entry). The control fixture is that archive's own
`test/conformance/{server,multiple_inputs_fixture,multi_round_fixture}.ml`
built unmodified in a scratch dune project; it is not committed here.

`compare_application.py`, `application-classification-2026-07-28-server.json`,
`run_live_application.sh`, `application.toml` and `application_transcript.*`
are this branch's own (F3.3); they reuse the pinned runner and, through
`compare_results.py`, its list parsing and `checks.json` reader, but no upstream
file was modified.
