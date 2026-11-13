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

## 7. Port status (2026-11-12)

P1–P8 all landed on `ocaml-port` (head `4afa8e5`): mcp-caps (M0–M4), router,
models+sanitize, config, provider contract + freeserp/anysearch, engines +
health + usage, fetch stack over the Net grant, agent mode, and the P8 server
(both transports, dashboard, REST projection, CLI verbs, surface manifest).
Gate state at merge: `dune build` clean, `dune runtest` 934 cases green,
scripted stdio initialize + tools/list returns exactly `search`, `fetch`,
`answer`, `--check` exits 0. Conformance against the pinned official runner is
10/37 on this fixture's declared surface (three tools only) versus the phase-1
baseline 19/18 — the delta is declared-surface gaps, not regressions; mcp-kit's
37/37 remains upstream's control, not this server's claim.

## 8. CI (2026-11-12)

F0.2 registered `.github/workflows/ci-ocaml.yml`, a separate workflow so the
Python jobs in `ci.yml` keep their behaviour. It triggers on pull requests,
`main` and `ocaml-port`, pins `ocaml/setup-ocaml` (v3.9.1) and `actions/cache`
(v6.1.0) by verified commit, installs `libgmp-dev` and the opam dependencies
(`--deps-only --with-test --with-doc`), then runs the ordinary gate verbatim —
`dune build @install`, `dune runtest --force`, `dune build @doc` — plus the
read-only `tools.surface`, `tools.value_sets` and `tools.egress_lists` checks.
The `_opam` cache is keyed on the exact compiler (`5.3.0`) and the committed
manifests, never the opam-repository head. No live or billed step is reachable.
Run mechanics, pin verification and the local `odoc` prerequisite are recorded
in `plans/infra-setup.md`, "CI: the OCaml gate"; the exit observation (a
documentation-only change proving the job runs) is made on the pull request that
carries this workflow, not from a local checkout.

## 9. F0.1 — the differential harness and parity matrix (2026-11-13)

Landed on `f0-1-diff`: `test/differential/` (the matrix tables, 165 corpus
inputs, 165 pinned goldens, the golden runner, the matrix validator) and
`ocaml-tools/oracle/` (corpus generator, Python projections, golden generator,
matrix generator). `dune runtest test/differential` runs 180 cases and needs no
Python, no network and no keys; re-pinning goldens is the oracle tooling's job
and reads the Python tree read-only. Format, mutation checks and the regeneration
recipe: `test/differential/README.md`.

Eight areas are pinned — config, router, model, sanitize, engine, fetch, jsondoc,
tabledoc — 165 cases, and the two trees agree everywhere except six registered
divergences. Each is an `explicit-divergence` golden: the suite fails if the port
changes shape *or* if the difference closes on its own.

- Two model cases: pydantic's lax mode coerces `"0.5"` and `"200"` to numbers and
  accepts the body; the port's decoder refuses string-to-number coercion. Decided
  to keep the port strict — a provider body that lies about a type is exactly the
  input the policy caps exist for — and pin both verdicts instead of arguing it.
- One sanitize case: the oracle projection must decode the corpus to call the
  Python sanitizer, so an ill-formed UTF-8 continuation byte arrives as U+FFFD;
  the port's sanitizer is byte-faithful. The escape pass itself agrees.
- Two fetch refusal-sentence cases and the systematic pydantic-report vs
  one-sentence difference: same verdict, each tree's own wording.
- The systematic `fetch.extractor` default: the port defaults to `stdlib` and
  refuses `trafilatura`, which the oracle defaults to. A P6 backend decision, on
  the record in the matrix and in the goldens.

The former open port gap, `fetch/12-url-ipv6-broken`, is closed: the port now
refuses `http://[::1/x` with the oracle's `Invalid IPv6 URL` sentence, the golden
is an ordinary `differential-golden`, and the `DIVERGENCES` entry is gone (F1.5).

The matrix is four committed TSVs (17 providers, 63 config keys, 21 behaviours,
16 surface items) validated at every `runtest`: no row may leave a consumer
unnamed, every row's verification must be one of the plan's kinds or an explicit
`pending-F*`, every `.ml`/`.py` pointer must resolve to a file in the sandbox,
and the provider rows must equal `Config.known_providers`. Fifteen adapters are
`pending-F4`, the fetch fallbacks `F6`, the page cache `F7`.

## 10. F1.3 — error discipline and log privacy (2026-11-13)

Landed on `f1-3-errors`. The boundary that raised now returns: `Server.serve_http`
answers `(unit, serve_error) result`, with `Bind_address_unresolved` and
`Listener_unavailable` as payload-free constructors, and `bin/main.ml` turns
either into one operator sentence plus exit 1. The type is deliberately not a
`string` or an exception wrapper — a host, a path or a socket fact can name
operator infrastructure, and the constructors are the redaction boundary.

Exceptions are classified, never rendered. `Log.classify_exn` is the only
exception-to-string conversion on a serving path: it maps a raised value to one
of a finite set of constants (`io`, `cancelled`, `sys_error`, `failure`,
`invalid_value`, `not_found`, `other`), so a log field says the same thing on
every run and cannot carry the URL, header or credential that was in scope when
it was raised. `Printexc.to_string` is gone from `lib/usage.ml`; a journal append
failure now logs `dashboard.journal_error` with a constant `stage="append"` and a
bounded `reason`, while the snapshot and the `create` error keep the operator
path they need. The listener logs three fixed events: `http.listen_failed`
(startup, WARNING), `http.connection_error` (per connection, WARNING) and
`http.listener_error` (a listener that returned with an exception); a rejected
Origin is the expected refusal `http.origin_rejected` at INFO, not a fault.

Two suites pin the rules where a type cannot. `test/log_guard/field_sets.ml`
drives the real engines over a stub provider and a stub fetcher — the position
Python's `MockTransport` holds — and asserts the exact `search.ok` and `fetch.ok`
key dictionaries both with `log_content` on and off, plus the absence of every
caller sentinel (query, URL/path, title, snippet, body, answer) from the decision
line and their presence in the content event that owns them when logging is on.
`test/log_guard/source_discipline.ml` scans every `.ml` and `.mli` under `lib/`
and `bin/` as whole text: no `Printexc`, no direct stderr outside `lib/log.ml`'s
sink and the thin CLI, no `failwith`/`invalid_arg` left in the serving-path
modules, and no `Mcp_kit` reference in the capability core beyond `server.ml` and
`server.mli`. Its `source_tree` dependencies and positive controls make an empty
or renamed sandbox fail instead of passing vacuously; `test_core_no_mcp_kit.ml`
now states that its own scan is whole-text too.

`test/router_dependencies.expected` grew the `log.cmi`/`log.cmx` edges because
`server.mli` names `Log.log` and `usage.ml` calls `Log.classify_exn`; the pin is
regenerated from ocamldep, not hand-edited. Gate at this commit:
`dune build @install`, `dune runtest --force` and `dune build @doc` all exit 0.
=======

## 11. F1.2 — the capability bypass closed, and the audit trail made real (2026-11-13)

Landed on `f1-2-audit`. Spec: `plans/ocaml-finalisation.md` §F1.2; it is A2 and
A3 of §5 closed together.

**The seal.** `lib/caps/dune` puts `policy_fs` and `controls_raw` in
`private_modules`, and `controls_raw.ml` has no interface file, so the bounds
record every raw operation takes has no name and no producer outside the library.
`Authority` and `Policy` stay the seam: `?controls` is gone from both
`Authority.{Fs,Net}.of_confinement`, so a call site can no longer ask for an
unbounded operation at all — the controls a grant runs under are decided where
the grant is built. An abstract public `Controls.t` facade was tried first and
rejected: `policy_net.mli`'s `request` would then take a type the library's own
raw operations cannot be handed (`Type "Controls_raw.t" is not compatible with
type "Controls.t"`), which is the plan's predicted failure mode for that shape.

**What dune's privacy is and is not,** established by probe rather than assumed,
because the two readings of "inaccessible" differ and only one of them is a
compiler error:

- A consumer of the *installed* `mcp-caps` is stopped. `dune build @install`
  files both interfaces under `.private/` (`dune-package` records
  `(visibility private)`), out of a consumer's search path, so
  `Mcp_caps.Policy_fs` and `Mcp_caps.Controls_raw` resolve to nothing there.
- A stanza *inside this workspace* is not stopped: dune generates an alias module
  for a wrapped library that re-exports private modules, and a probe in a
  neighbouring library type-checked the full bypass. `(root_module …)` is the
  wrong lever — it aliases a library's *dependencies*, not its own modules, and
  naming it on `mcp_caps` broke `Mcp_caps.Authority` for every consumer. So
  inside the checkout the rule is kept by `test/test_caps_audit.ml`, which reads
  the production sources and fails the build when anything outside `lib/caps`
  names `Policy_fs` or the bounds record.
- `policy_net` stays public on purpose. Its `request`, `response`, `method_` and
  `endpoint` records are the vocabulary a `Net` grant is *called* with, and a
  private module's records are unusable by an installed consumer — hiding the
  module failed the intended grant path in the first probe of that shape. What
  seals its `request` is the `controls:Controls_raw.t` argument instead.

**Negative compilation.** `test/should_not_compile/` grows from six programs to
thirteen: `direct_fs_operation`, `direct_net_operation`, `controls_none`,
`controls_record_forge`, `controls_record_update` and `raw_fs_call_needs_bounds`
(each with its diagnostic pinned in `<name>.expected`), plus `grant_path.ml` as
the positive half — the intended grant path still type-checks for a consumer, so
the seal closes the bypass and not the seam. `raw_fs_call_needs_bounds` is the
half that holds in *both* readings: with `Policy_fs` already in scope, the call
still fails because nothing outside `lib/caps` can produce the bounds record. The
directory's hand-written `mcp_caps.ml` mirror is what makes the package view
type-checkable with a plain `ocamlc`, and the audit suite asserts the mirror
agrees with `private_modules`.

**The audit trail.** One funnel in `lib/factory/factory.ml`:
`grant_of_decision` is the only place a serving grant is built, so
`Authority.Net.of_confinement` and `Authority.with_log` each appear exactly once
in the module and a second grant path would show up as a red line in
`test_caps_audit.ml`'s source pins. `?audit` is threaded through the public
builders (`grant_of_endpoint`, `build_providers`, `probe_net`,
`build_fetch_stack`, `agent_net`) as the *last*, optional argument, and
`build_app` always supplies it; a grant built without a sink is therefore a
diagnostic grant (`--check`), never a serving one, which is what kept
`bin/main.ml` and the boot fixtures untouched. `Factory.audit_sink` renders one
`Mcp_caps.Event.t` as the `caps.operation` line through the application's `Log`:
`operation`, `outcome` (`ok` / `failed:<kind>`), `bytes` when the operation
measured a payload, and one field per bounded note (`status`, `entries`). A note
whose key would collide with a fixed field is written as `note_<key>`, so the
line's shape never depends on what an operation happened to report.
`Authority.with_operation_budget` is deliberately absent from `Factory`: a budget
is a caller's counter and server construction has no caller scope (the name
appears there only inside brackets in a comment, which the suite's pin relies on).

**Suites.** `test/test_caps_audit.ml` — 19 cases: exactly one event per granted,
refused, filesystem and readiness-probe operation; what the line carries and what
it must not (no field name may spell request data; `Event.t` has no URL, header,
body or query field to fill); a grant without a sink records nothing; the field
dictionary including note-collision prefixing; the wiring counts; and that
descriptor 1 stays empty when the real `Log` sink is driven (an audit line on
stdout would corrupt the protocol under stdio). `test/test_caps_budget.ml` — 10
cases: limit arithmetic, non-positive limits, snapshot vs reservation, atomic
exhaustion under 32 domains and 16 fibers, one budget spanning several grants,
independent budgets not sharing a counter, a spent budget refusing without doing
the I/O, a decorated grant keeping its counter, and counting operations rather
than bytes. Neither suite touches a billed endpoint: loopback fixtures and a temp
directory only.

Gate at landing: `dune build @install`, `dune runtest --force`, `dune build @doc`
and `dune runtest test/should_not_compile` all exit 0.

## 12. F1.5 — the small oracle edge cases (2026-11-13)

Landed on `f1-5-edges`. Five forks between the port and the oracle are closed,
each pinned by a test that states the oracle's own answer.

**Non-ASCII repr.** A path refusal now quotes a token through
`Seekwright_text.Repr.py_repr`, so a printable non-ASCII key comes back as the
character the caller wrote instead of its bytes. `Repr.py_repr_ascii` is gone:
the only remaining ASCII-only escape is `Jsondoc.json_string_ascii`, which exists
because a path rendering has to read back through JSON, not because a refusal
wants every byte written out. `test/test_jsondoc.ml` pins the readable token.

**Unicode whitespace.** `Seekwright_text.Utf8` now owns `lstrip`, `rstrip`,
`strip` and `split_whitespace`, all over `is_python_space`; the separate
`is_ascii_space` set is deleted. `Engine.strip`, `Provider.normalise`/`rstrip`,
the agent's `.strip()` and whitespace test, `Fetcher`'s URL trim and `Jsondoc`'s
trim helpers all take the shared walk. The `min_text_chars` gate is covered by a
page padded with ideographic spaces: it counts as empty, where the old ASCII
walk counted three hundred characters of padding. `test/test_text.ml` pins the
helpers, `test/test_provider.ml` the collapse, and
`test/test_fetch_engine.ml` the gate.

**Bracketed IPv6.** `Fetcher.validate_url` checks the raw netloc before `Uri`
reparses it, mirroring CPython's `_check_bracketed_netloc` /
`_check_bracketed_host`: an unmatched bracket, data before `[`, or junk after
`]` before the port delimiter is `unparseable URL: Invalid IPv6 URL`; the host
itself is IPvFuture (`v` + hex + `.` + anything) or an IP address, with the
oracle's `An IPv4 address cannot be in brackets` and `'…' does not appear to be
an IPv4 or IPv6 address` sentences. A zone id is accepted on IPv6 only, as
Python's `ipaddress` does. `test/test_fetch.ml` pins both the refusals and every
accepted form (`[::1]`, `:80`, `:8443`, `:65535`, `[v1.abc]`, `[fe80::1%eth0]`,
`[::ffff:127.0.0.1]`). The differential golden `fetch/12-url-ipv6-broken` moved
from `explicit-divergence` to `differential-golden`, and its `DIVERGENCES` entry
is removed.

**Public-web port policy.** `Policy_net` now names `port_policy`
(`Default_ports | Any_port`) and `with_public_web` takes an optional one,
defaulting to `Default_ports`; `Policy` re-exports both. The default keeps the
safe rule — the scheme's own port only — while `Any_port` accepts 1..65535 when
the resolved address is public, which is the oracle's rule. The address policy is
untouched: private permission is a separate axis. The factory's one
`with_public_web` call passes `~port_policy:Policy.Any_port`; no other factory
structure changed. `test/test_authority_net.ml` pins `:8443` accepted, `:0` and
`:65536` refused as malformed, and a private answer on `:8443` still denied.
The duplicated port-policy prose is gone from the implementation; the interface
and `Policy` docs state the two modes once.

**Ownership notes.** Two surgical exceptions were approved by the coordinator:
the `Engine.strip` body and the single `~port_policy` argument at the factory's
call site. `lib/fetch/dune` gains `ipaddr` for the bracketed-host check; no other
library direction changed.

Gate at landing: `dune build @install`, `dune runtest --force` and
`dune build @doc` exit 0. No default-gate step contacts a provider.
=======
## 13. F1.1 — one routable provider set (2026-11-13)

Landed on `f1-1-routing`. Spec: `plans/ocaml-finalisation.md` §F1.1.

**One set, read once.** `Engine.Search`'s routing table now derives every
dispatchable field from the adapter registry it was handed: `providers` is the
registry, and `effective` is the registry narrowed by the permission set — not
`Config.effective_providers`, which stays what `--check` says about a *file*.
That closes the split the port had opened: with an enabled name this build has
no adapter for, a caller naming it got the router's "not enabled on this
server" refusal while the default route resolved to it and the engine's
no-adapter branch answered 502. The same pair of values cannot now produce both
answers, and `search.fallback` rungs for unbuilt names are inert for the same
reason they are inert in Python — `Router.fallback_rungs` filters against the
registry, and the registry is what routing describes. `Config.effective_providers`
is untouched: `unnamed_walks_free` reads the table's `effective`, so the free
walk now asks whether the *built* set is all free.

**The construction-time decision.** `Factory.startup_verdict` runs inside
`build_app` before an engine exists, and refuses three pairings: an explicitly
enabled name with no adapter (all offenders in one sorted line, naming what this
build *can* dispatch); an implicit keyless default that leaves no keyless
adapter built (the transition exception stops applying once applying it would
serve nothing); and a `default_provider` outside the built set, wherever it came
from — config validation already refuses one outside `enabled`, and this is the
enabled⇒built step. `bin/main.ml` turns an `Error` there into its existing
"seekwright: …" plus exit 1. The exception to the rule is exactly Python's
implicit-default exception, kept for the transition because the port carries one
of the three keyless names: an unconfigured install starts over `freeserp` and
the startup line and `startup.providers_unsupported` name the two it skipped.

**`Factory.classify` and `--check`.** One classification feeds both paths:
`set_report` carries `enabled`, `effective`, `built`, `unsupported` (explicit,
startup-fatal) and `skipped` (implicit, disclosed by name) — the same fact split
by how the config came to hold it — plus `untested`, which is this port's own
status: Python's four untested names *plus every name this build dispatches*,
until the OCaml live runner records a run of its own. A reachability probe never
moves a name, so `untested` prints beside the ready count and is never folded
into it. `--check` prints all six lines and every offending per-name row
("not built on this port", one problem each) instead of the old
"unsupported (no connectivity probe)", which read as a connectivity verdict on a
name that has no adapter at all. The classification lives in `lib/factory`, not
`bin`, so F3.2's CLI extraction moves a call site rather than a rule; the
coordinator approved editing `bin/main.ml` for the startup line and this section
alone.

**Reports and pins.** `/healthz` documents and answers the built set — the one
set every route resolves against — and the startup line's `providers` field is
now that set too, so `bin/smoke_notes.expected` is re-pinned from
`providers="exa:free,freeserp,parallel:free"` to `providers="freeserp"` (the
`unsupported=` field and its WARNING line are unchanged). Two suites carry the
tests: `test/test_routing_sets.ml` (10 cases — the shipped default over its built
remainder, the no-keyless-left refusal, only-`exa:free` as fatal, an explicit
mix refused once and sorted, `build_app` refusing end to end, permission
narrowing, the five sets apart on one config, and `/healthz` ×2), and
`test_engine.ml`'s "one routable set" group (4 cases — a named unbuilt name
refuses rather than failing, the free walk over built∩permitted, an unbuilt
ladder rung skipped with no phantom "Fallbacks also failed", and the runtime
no-adapter branch staying a returned value rather than a crash).
`Engine.Search.create`'s signature is unchanged on purpose: the off-limits suites
(`log_guard/field_sets`, `differential/projection`, `test_health_monitor`) build
engines directly, so construction-time validation belongs to `build_app`, and the
engine's own promise — fail through the return value — is what the fourth case
pins. A third pin is new at the CLI: `bin/check_unbuilt.toml` plus a `bin/dune`
rule runs `--check` over a deployment that enables only unbuilt names, so
nothing is constructed, nothing is dialled, and the five-set rendering and the
problem-count exit code are blessed in `bin/check_unbuilt.expected`
(`check_unbuilt_notes.expected` pins the empty stderr a diagnosis must keep).
No suite reached a provider endpoint.

Gate at landing: `dune build @install`, `dune runtest --force` and
`dune build @doc` all exit 0, including the stdio smoke and the new `--check`
rule.
