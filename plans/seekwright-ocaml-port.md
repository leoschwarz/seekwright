# Porting seekwright to OCaml — plan

Status: draft, v1. Companion to `capability-gated-mcp-server.md`. Nothing here is
implemented; this is the shape of the effort.

## 0. Method: vision-based, differential

Two anchors, in this order:

1. **`VISION.md` is the spec.** Its possibilities, main goals, precedence list and
   non-goals are the acceptance criteria for every milestone. When the OCaml port and
   the Python tree disagree, VISION.md decides which one is wrong — and if the task
   cannot be reconciled with it, VISION.md changes in the same PR, exactly as the
   Python project's own rule says. The non-goals (no auth, no cache, no inferred
   routing, no silent billable escalation, no model-driven retrieval loop, no
   in-app egress allow-list) are ported as *refusals*: the OCaml tree must decline
   them too, and the capability layer is a natural place to make some of them
   unrepresentable rather than merely unimplemented.
2. **The Python tree is the oracle.** Behavior is ported by differential testing:
   same input, same observable output, Python vs OCaml, over a corpus of recorded
   calls (queries, URLs, configs). The frozen surface
   (`docs/reference/surface.md`, checked by `tools/surface.py`) is the wire
   contract both implementations must satisfy — the OCaml build gets its own
   surface-printer and the two manifests must diff clean.

"Vision-based programming" here means: write the milestone's exit criterion as a
VISION.md line *before* writing OCaml, then let the differential suite prove it.

## 1. Why the capability layer is the right substrate

The Python architecture already separates *decide* (pure `router.py`) from
*execute* (`engine.py`, providers, fetcher). The capability layer from the
companion plan maps onto that split:

- **Provider adapters receive endpoint-scoped `Net` grants.** The enabled
  provider set is assembled into the search engine's authority record, and that
  record is supplied to the `search` tool's `Registry.add`; each adapter receives
  only its own vendor grant. Only the frozen `search`, `fetch`, and `answer` tools
  are registered — providers never become MCP tools. An adapter cannot use the
  authority API to dial outside its endpoint set. Trusted OCaml code can still
  bypass the API directly; this is an audit boundary, not a sandbox. Endpoint
  sets follow enabled provider names rather than adding an egress config key.
- **`fetch` is a tool with a public-web `Net` grant plus optionally `Fs`.**
  The SSRF guardrails (scheme check, public-IP-only resolution bound to the actual
  connection, manually re-validated redirects, byte cap) become the *grant's*
  validation, not the tool's — the authority API cannot be asked for `file://` or
  a private address. `fetch.cache_dir` becomes an `Authority.Fs.t` from
  `Policy.with_root`, whose Eio subtree handle confines page-cache paths.
- **`Proc`** is not in the capability layer's v1. Reconsider it only if a real
  port requirement introduces subprocesses; Exa and crawl4ai remain HTTP calls.
- **Grants have server lifetime.** This matches one deployment serving one
  operator's keys: keys come from the environment at startup, the registry is
  built once under the transport's enclosing switch, and every session shares
  the same confined policies. Per-client authority and per-client quotas remain
  non-goals.

## 2. Port order — follow the repo's own seam order

`docs/architecture.md` already names routing as the first layer worth porting,
and the module map gives a natural dependency order. Port bottom-up so each layer
has a working oracle above it:

| Step | Python source | OCaml target | Why here |
|---|---|---|---|
| P1 | `router.py` (stdlib-only, pure) | `lib/router.ml` | Already the designated port; pure functions over a frozen routing table translate 1:1. Port `tests/test_router.py` as the first alcotest suite — it is the differential proof. |
| P2 | `models.py` + `sanitize.py` | `lib/model.ml`, `lib/sanitize.ml` | Wire types as OCaml records + `Yojson.Safe` encoders; `WireModel`'s drop-unset rule becomes "build the JSON from only the set fields". Sanitizer is pure string → string, ports directly; property-test idempotence/reversibility. |
| P3 | `config.py` | `lib/config.ml` | TOML via the `toml` opam package; env-only secrets (`SEEKWRIGHT_*`). Every key from `docs/reference/configuration.md`; validation errors must match the Python wording where the surface doc pins it. |
| P4 | `providers/base.py` + adapters | `lib/provider.ml` + `lib/providers/*.ml` | The protocol becomes an OCaml module type (`module type S`) — stricter than Python's runtime-checkable Protocol, which is the point. Status-code → error mapping and the redaction rule port verbatim. Seventeen names over fifteen modules, one file per adapter, keyless set defaulting included. |
| P5 | `engine.py` + `health.py` + `usage.py` | `lib/engine.ml`, `lib/health.ml`, `lib/usage.ml` | Execution around the ported router. asyncio → Eio fibers; circuit breaker and JSONL journal are plain data structures + a writer fiber. |
| P6 | `fetcher.py` + `extractors/` + `jsondoc.py` + `tabledoc.py` | `lib/fetch/*.ml` | HTTP behind the capability grant. Extraction backends: `stdlib` HTML parser first (no dependency), trafilatura equivalent is an open spike (no mature OCaml trafilatura port — decide: call the Python one via a sidecar, or accept a simpler extractor in v1). `jsondoc`/`tabledoc` are stdlib-only in Python and port directly. |
| P7 | `agent.py` | `lib/agent.ml` | Fixed plan + exactly one model call; the plan's fetches reuse the gated fetch tool, so `answer` inherits SSRF bounds for free. |
| P8 | `server.py` + `cli.py` + `factory.py` + `dashboard.py` + REST routes | `bin/main.ml`, `lib/server.ml` | mcp-kit transports (stdio + cohttp-eio) replace FastMCP; `/healthz`, `/dashboard`, `/dashboard/data`, `/dashboard/metrics`, `POST /api/v1/{search,fetch,answer}` port onto cohttp-eio routes with the same Host allowlist semantics. CLI client verbs over REST, no keys. |

## 3. Cross-cutting decisions

- **Concurrency.** OCaml 5 effects + Eio direct style, with bounded operations
  under an enclosing switch. Provider HTTP clients and the fetch client are owned
  by separate authority grants. Provider credentials are attached only by the
  adapter holding its fixed-endpoint grant; `fetch` receives a public-web grant
  and no provider credentials. This prevents credential forwarding through the
  capability API without claiming to sandbox arbitrary OCaml code.
- **JSON Schema.** mcp-kit compiles 2020-12 locally and has a PPX for typed tool
  declarations — the `search(provider=…)` `Literal` of seventeen names becomes a
  PPX-generated variant, which is *stricter* than Python's runtime `Literal`.
- **Logging.** Port the loguru discipline as a small `lib/log.ml`: constant
  dotted event names, bound fields, stderr only, never a backtrace, never an
  exception object. In OCaml this is easier to enforce — no `logger.exception`
  exists to misuse.
- **Config/secrets.** TOML from `SEEKWRIGHT_CONFIG` or the platform default;
  keys from `SEEKWRIGHT_*` env only. Startup-fatal on enabled-without-key,
  exactly as Python.
- **Surface freeze.** Write `ocaml-tools/surface.ml` (root `tools/` belongs to the read-only Python
tree; decided 2026-11-10) — or reuse the Python printer
  against the OCaml manifest) so the frozen name set is checked the same way:
  any drift fails CI. The seventeen provider names, three tools, routes and
  config keys move only together.
- **Testing.** (a) Ported unit suites per module (alcotest). (b) Differential
  corpus: recorded Python requests → expected JSON, replayed against the OCaml
  binary over both transports. (c) `should_not_compile` checks that also match
  the expected diagnostic. (d) The pinned official MCP runner against an explicit
  scenario baseline for the fixture's advertised features; mcp-kit's full
  37-scenario fixture is not evidence about this application by itself. (e) Live
  provider tests behind the same `*_LIVE_TESTS` gate, keyless ones first
  (`exa:free`, `parallel:free`, `freeserp`, `anysearch`).

## 4. Milestones

| | Deliverable | Exit criterion (VISION.md line it proves) |
|---|---|---|
| P1 | `router.ml` + ported router tests | Differential suite green; "surface is enumerable and checked" |
| P2 | `model.ml` + `sanitize.ml` | Round-trip + idempotence properties; "what leaves the server stays safe" |
| P3 | `config.ml` | `docs/reference/configuration.md` example loads; keyless default resolves to `exa:free`, `parallel:free`, `freeserp` — "a fresh clone searches before any configuration exists" |
| P4 | provider protocol + first adapters (freeserp, anysearch; exa:free/parallel:free deferred — see open question 3) | Keyless live tests pass for freeserp/anysearch; "every response names the provider that served it" |
| P5 | engines + health + usage + journal | Fallback ladders behave identically to Python over the differential corpus; "no silent escalation to a billable rung" |
| P6 | fetch stack + SSRF grant + jsondoc/tabledoc | Escape/differential tests green; "what leaves the server stays safe" — enforced by the grant's network/filesystem boundaries |
| P7 | `answer` | One model call per answer, validated citations; "answers that can be checked" |
| P8 | server, both transports, dashboard, REST, CLI | Applicable official conformance scenarios green against the checked baseline + surface manifest identical to Python's; "one person can run it" |

P1 landed on `p1-router`: `lib/router.ml`/`.mli` (so `Seekwright.Router`) and
`test/test_router.ml`, one alcotest case per case of `tests/test_router.py`.
Three things worth recording for the phases behind it:

- The router's seam is machine-checked as a dependency fact, not a source grep,
  and it takes two checks: `lib/dune` has no `[libraries]` field, which is what
  makes an out-of-library reference (`Mcp_caps`, say) a compile error, and
  `test/dune` diffs `ocamldep`'s answer for the whole library against
  `test/router_dependencies.expected`, which is what makes the router leaning on
  a sibling module fail `runtest`. `ocamldep` is lexical — it reports only the
  module names it can resolve among the files it is handed — so scanning the
  whole library is what gives the pin its teeth. Verified both ways: a reference
  to `Mcp_caps` refuses to compile, and a reference to a temporary
  `lib/model.ml` lands in the pin and fails the diff.
- The differential ran against the live oracle rather than a recorded corpus
  (open question 4 stays open for the phases that need responses, not decisions):
  the suite's case matrix plus edges it does not pin, printed identically from
  `src/seekwright/router.py` and from the compiled library. One divergence came
  out of that and is now matched and pinned: Python's truthiness makes an
  empty-string fallback notice read as unset, so a suffix ending in `"; "` never
  ships. P5 should assume that rule when it builds the sentence.
- The suite re-declares the frozen free vocabulary (`FREE_PROVIDERS` /
  `FREE_PROVIDER_ORDER`) because `config.ml` is P3, and pins the sentences that
  quote it literally. When P3 lands, its constants feed the tables; the pinned
  sentences stay, which is what makes a moved name fail a run.
- Corrected when P3 landed (2026-11-11): the constants feed the *callers'* tables,
  never the router module's source. `lib/router.ml` may not reference
  `Seekwright.Config` — the stdlib-only rule is enforced by the `ocamldep` pin in
  `test/dune`, which fails the diff on any dependency line — so the router's
  caller (the engine, P5) builds a `search_table` from `Config`'s lists, and the
  two frozen copies stay copies. They agree today: `Config.free_provider_order` is
  `exa:free, parallel:free, freeserp, searxng, tinyfish` and
  `Config.free_providers` is that set sorted, matching what
  `test/test_router.ml` re-declares. Keeping them equal is a test someone has to
  write down; nothing enforces it across the two suites yet.

P4 landed on `p4-providers`: the contract as `lib/provider.ml`/`.mli`
(`Seekwright.Provider`: `module type S`, the `error`/`outcome`/`hit` rows, the
JSON payload readers, the caps, the constraint report, and `Provider.Net` as the
HTTP seam) plus `lib/providers/{freeserp,anysearch}.ml/.mli`, and four alcotest
suites (`test_provider`, `test_freeserp`, `test_anysearch`,
`test_provider_contract`, 98 cases) ported from `tests/providers/`. Four things
for the phases behind it:

- The adapters are their **own dune library** — `seekwright_providers`, public
  name `seekwright.providers`, module path `Seekwright_providers.Freeserp` —
  because the dependency direction is now fixed: `Provider` needs the `Net`
  grant from `mcp-caps`, and an adapter needs `Seekwright` for the wire models.
  P5's factory therefore cannot be `lib/factory.ml`: a factory that builds
  adapters would close a cycle. It needs its own stanza (or the adapters move
  into it). A `lib/dune` `(include_subdirs qualified)` was tried and does not
  work while `lib/caps/` has its own stanza.
- The exit criterion is **half met**. "Every response names the provider that
  served it" is pinned for both adapters, and the failure rows are driven over
  every adapter module on disk; but the *keyless live* half has no OCaml
  harness yet, so nothing here proves the two endpoints still answer as the
  Python oracle recorded. Open question 4 covers that corpus, and the P4 suites
  would take it directly: each adapter is driven through an injected
  `Provider.Net.t`, which is where a recorded-response Net would sit.
- `test_provider_contract.ml` ports the Python suite's *driving*, not its
  document parser. That suite reads the Failures table out of
  `docs/reference/provider-contract.md` so code and prose cannot drift; the
  table's *signals* are spelled in httpx vocabulary (`httpx.TimeoutException`,
  `httpx.HTTPStatusError`), which the port does not raise — its signals are the
  two kinds a `Net` grant answers with. Sharing the table across both trees
  means revising that page's wording, which is a Python-tree change and so out
  of scope here; the row names are pinned in OCaml meanwhile.
- `test/router_dependencies.expected` was already stale on the branch base: P2
  added `lib/model.ml` and `lib/sanitize.ml` without re-pinning, so `dune
  runtest` failed there before P4 started. P4 re-pinned it (`dune runtest test`
  then `dune promote`), and P3 will move it again.

## 5. Open questions / spikes

1. **HTML extraction backend.** Is there an OCaml equivalent of trafilatura worth
   adopting, or does v1 ship the stdlib parser only (Python's second registry
   member) and leave trafilatura-class extraction to a later milestone? Decide
   before P6.
2. **PDF.** pypdf has no OCaml counterpart in scope; v1 likely claims no PDF
   media types (the protocol already supports a backend that claims none).
3. **`exa`/`parallel` as MCP clients (blocks their :free adapters in P4).** Python reaches Exa and Parallel's hosted MCP through MCP client adapters; mcp-kit 0.2.0 ships no client (verified against the installed package). Decide: hand-rolled streamable-HTTP MCP client over the `Net` grant, plain REST where the MCP tool merely wraps REST (parallel.py), or defer both :free names. P4 starts with freeserp + anysearch meanwhile.
   In OCaml, mcp-kit can be the client too — confirm the client side exists in
   0.2.0, else that adapter becomes plain REST or waits.
4. **Differential corpus capture.** Record Python responses now (before the
   branch diverges) so P1–P8 have a fixed oracle: a script that runs the Python
   server over a scripted session and stores request/response pairs.
5. **TOML library: decided — `toml`** (installed in the default switch,
   recorded in plans/infra-setup.md).
6. **Whether the capability layer lives in the same repo** as the port (one
   dune workspace, `lib/` for the layer, `bin/` for seekwright) or a separate
   package the port depends on. Recommendation: same repo, separate library
   stanza, so the grant claim stays testable in-tree.

## 6. What this plan deliberately does not do

- No rewrite of behavior: every milestone must match the Python oracle, not
  improve on it. Improvements are VISION.md amendments in their own PR.
- No new surface: three tools, same names, same fields, same refusal sentences.
- No auth, cache, or spend ceiling — the declined features stay declined, now
  partly enforced by the type system instead of by convention.
