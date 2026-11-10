# Conformance: the official MCP runner against an mcp-caps server

This directory holds the live conformance fixture and its gates
(`plans/capability-gated-mcp-server.md` §8, "Wire tests and official
conformance"). Nothing here runs under plain `dune runtest` except the stdio
transcript rule at the bottom: the live job needs Node and an npm fetch, so the
Python suite's hermeticity rule holds on the OCaml side too.

## What is pinned, and by which file

| Thing | Value | Where |
|---|---|---|
| official runner | `@modelcontextprotocol/conformance` `0.2.0-alpha.11` | `package.json`, `package-lock.json` |
| Node | >= 22 (the runner imports `globSync` from `fs`; on Node 20 it dies at import, so `run_live.sh` gates the version instead) | `run_live.sh` |
| required scenario set | 37 IDs, verified equal to `conformance list --server --requirements 2026-07-28` | `requirements-2026-07-28-server.txt` |
| unscored scenarios the same command also runs | 13 (ten `tasks-*` extension, `json-schema-2020-12`, `http-header-validation`, `http-custom-header-server-validation`) | parsed out of `runner-list.stdout` by the comparator |
| failure baseline | 18 scenarios, each naming its failing check IDs with a cause and a reason | `expected-failures-2026-07-28-server.json` |

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
(8) all pass against this fixture; the ten `tasks-*` extension scenarios fail,
and fail identically for the upstream control fixture, because mcp-kit 0.2.0
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
comparable to upstream's records rather than a new measuring stick. Both sides
are MIT-licensed (`LICENSE` here, the same in that archive). The archive the
switch installs is
`https://gitlab.com/nomadic-labs/ai-harness/ocaml-mcp/-/archive/v0.2.0/ocaml-mcp-v0.2.0.tar.gz`,
`sha256=43c8319a13be91e323ae952a71ab673533fb3295886029eed9d81e5828de5ef7`
(the `mcp-kit.0.2.0` opam entry). The control fixture is that archive's own
`test/conformance/{server,multiple_inputs_fixture,multi_round_fixture}.ml`
built unmodified in a scratch dune project; it is not committed here.
