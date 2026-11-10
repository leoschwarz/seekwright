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

- **Provider adapters are tools with a `Net` grant.** Each of the seventeen names
  becomes a registered tool whose grant is a `Net.t` scoped to that vendor's
  endpoint(s). The grant is built by `Policy`, so an adapter cannot dial anything
  its `Registry.add` line did not name — this enforces, structurally, the vision
  rule that "which hosts are reachable follows from which names are enabled"
  without adding an in-app egress allow-list key.
- **`fetch` is a tool with a validated `Net` grant plus optionally `Fs`.**
  The SSRF guardrails (scheme check, public-IP-only resolution, manual redirect
  re-validation, byte cap) become the *grant's* validation, not the tool's — the
  tool cannot even ask for `file://` or a private address. `fetch.cache_dir`
  becomes an `Fs.t` from `Policy.with_root`, which is what makes the page cache
  path-safe by construction.
- **`Proc`** is needed only if the port keeps `exa`-as-MCP-client or the crawl4ai
  renderer as subprocesses; in v1 those stay plain HTTP calls, so `Proc` may not
  be needed at all — decide at M3.
- **Grants per session, not per process**, resolves the vision rule that one
  deployment serves one operator's keys: keys come from the environment at
  startup, the registry is built once, and every session shares it. (Open
  question 1 in the companion plan only matters if per-client authority is ever
  wanted — it is a non-goal.)

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
| P8 | `server.py` + `cli.py` + `factory.py` + `dashboard.py` + REST routes | `bin/main.ml`, `lib/server.ml` | mcp-kit transports (stdio + cohttp-eio) replace FastMCP; `/healthz`, `/dashboard`, `/dashboard/data`, `POST /api/v1/{search,fetch,answer}` port onto cohttp-eio routes with the same Host allowlist semantics. CLI client verbs over REST, no keys. |

## 3. Cross-cutting decisions

- **Concurrency.** OCaml 5 effects + Eio. One fiber per request; the shared HTTP
  client becomes a single Eio-backed connection pool. The Python rule "the
  fetcher owns its own client so no provider key rides to a third-party site"
  becomes two grant instances with disjoint host sets — the capability layer
  makes the leak unrepresentable.
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
- **Surface freeze.** Write `tools/surface.ml` (or reuse the Python printer
  against the OCaml manifest) so the frozen name set is checked the same way:
  any drift fails CI. The seventeen provider names, three tools, routes and
  config keys move only together.
- **Testing.** (a) Ported unit suites per module (alcotest). (b) Differential
  corpus: recorded Python requests → expected JSON, replayed against the OCaml
  binary over both transports. (c) `should_not_compile` dune rules for the
  capability claims. (d) mcp-kit's 37 compliance scenarios against the OCaml
  server. (e) Live provider tests behind the same `*_LIVE_TESTS` gate, keyless
  ones first (`exa:free`, `parallel:free`, `freeserp`, `anysearch`).

## 4. Milestones

| | Deliverable | Exit criterion (VISION.md line it proves) |
|---|---|---|
| P1 | `router.ml` + ported router tests | Differential suite green; "surface is enumerable and checked" |
| P2 | `model.ml` + `sanitize.ml` | Round-trip + idempotence properties; "what leaves the server stays safe" |
| P3 | `config.ml` | `docs/reference/configuration.md` example loads; keyless default resolves to `exa:free`, `parallel:free`, `freeserp` — "a fresh clone searches before any configuration exists" |
| P4 | provider protocol + first adapters (freeserp, anysearch, exa:free, parallel:free) | Keyless live tests pass; "every response names the provider that served it" |
| P5 | engines + health + usage + journal | Fallback ladders behave identically to Python over the differential corpus; "no silent escalation to a billable rung" |
| P6 | fetch stack + SSRF grant + jsondoc/tabledoc | Escape/differential tests green; "what leaves the server stays safe" — now enforced by the grant, not convention |
| P7 | `answer` | One model call per answer, validated citations; "answers that can be checked" |
| P8 | server, both transports, dashboard, REST, CLI | mcp-kit 37/37 conformance + surface manifest identical to Python's; "one person can run it" |

## 5. Open questions / spikes

1. **HTML extraction backend.** Is there an OCaml equivalent of trafilatura worth
   adopting, or does v1 ship the stdlib parser only (Python's second registry
   member) and leave trafilatura-class extraction to a later milestone? Decide
   before P6.
2. **PDF.** pypdf has no OCaml counterpart in scope; v1 likely claims no PDF
   media types (the protocol already supports a backend that claims none).
3. **`exa` as MCP client.** Python reaches Exa through an MCP client adapter.
   In OCaml, mcp-kit can be the client too — confirm the client side exists in
   0.2.0, else that adapter becomes plain REST or waits.
4. **Differential corpus capture.** Record Python responses now (before the
   branch diverges) so P1–P8 have a fixed oracle: a script that runs the Python
   server over a scripted session and stores request/response pairs.
5. **TOML library choice** (`toml` vs `otoml`) — pick at P3 with a spike on
   error-message quality, since startup errors are operator-facing.
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
