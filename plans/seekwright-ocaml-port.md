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

## 14. F1.4 — every config field honoured or honestly rejected (2026-11-13)

F1's exit criterion is that no key loads, validates and then changes nothing
without saying so. Three answers are possible and each is taken by exactly the
class of key that deserves it: wire the consumer now, refuse the value at load
where this port will never honour it, or — only for a key whose consumer a named
later phase owns — disclose it in `--check` until that phase lands.

**`fetch.allow_private_addresses` — wired now.** The switch picks the capability
variant the local reader's grant is *built with*: `Policy_net` gains a third
address rule, `Private_web`, beside `Public_web` and `Endpoints`, and
`Factory.build_fetch_stack` selects `Policy.with_private_web` or
`Policy.with_public_web` from the key at construction. It is not an empty
endpoint list — an endpoint list pins names and trusts them, and this key says
something about a *network*, so it gets its own variant. The address rule is one
axis wide: loopback, private, link-local and unique-local addresses become
dialable, while a multicast group, a broadcast address and the unspecified
address stay refused on any network, and the port modes are unchanged — the
widening is only ever an address widening. Every refusal sentence names the
policy that fired (`the private-web policy reaches the operator's own network…`
under this variant), so an operator who approved intranet reads is never sent
looking at a key they never set. Third-party routes stay public-only by
construction whatever the key says: their grants come from
`Factory.grant_of_endpoint` over the vendor they dial, and the key licenses
*this* process, not someone else's view of the intranet. The policy layer's own
docstring records that a loopback test server is a normal `with_endpoints`
fixture, a refusal under `with_public_web`, and an ordinary destination under
`with_private_web` — which is how `test/test_fetch_grant.ml` runs its real-socket
cases without any test reaching beyond loopback.

**`logging.library_level` / `logging.access_log` — refused at load.** Both exist
only to steer uvicorn's loggers, and there is no uvicorn on this port.
`Config.validate_logging_on_this_port` runs first inside `resolve`, so a file
load and a programmatic `resolve` refuse alike, and the refusal says so: no
uvicorn on this port, name the key and the value, and point at the logging keys
that *do* bite here. The inert defaults (`"WARNING"`, `false`) still load — the
corpus's own doc-example sets both, and refusing the default would refuse every
config — and if real third-party or access logging lands later, that phase
removes the refusal in the same change.

**Unknown keys — all of them, sorted.** `Config.section` used to name one
unread key per section and return; it now emits every unread key as its own
`<path>: unknown key` clause, sorted, joined with `; `. Single-key sentences are
byte-identical to what they were — every `differential/golden/config` pin that
quotes one still passes — and a section carrying three typos now costs one fix
instead of three reloads.

**`--check` discloses the transition.** `transitional_features` collects what
the file asks for and this binary does not run — a set `cache_dir` (no page
cache until F7) and a non-`http` fetch primary or fallback ladder (no
third-party fetch route until F6) — and the diagnosis prints each one twice:
`unsupported on this port` beside the row it qualifies, and in one aggregated
list at the end of the run, with every entry counted as a problem (exit 1). The
private-web widening is not in that list — it is honoured — but the fetch row
says `private addresses allowed (the local reader is built with the private-web
grant)` so the capability the binary runs is visible in one line. Provider
option keys need no rows: the names that carry them already print "not built on
this port". The marker phrase is one constant, `unsupported_here`, so the row
and the aggregate cannot drift; each entry disappears from the list in the pull
request that lands its consumer, which is what keeps a permanent "parsed, not
honoured" table from forming.

**Config path parameters.** `Config.config_path` and `Config.load` take a
`string option` — the provider-name `name` alias no longer appears where a file
path is meant.

**Pins.** `test/test_fetch_grant.ml` (8 cases) pins both halves of the switch:
the public-web grant refuses a loopback connect while the private-web grant
serves a loopback page over a real fixture; the widening is real at the address
*and* port axes (a loopback dial on an unlistened port fails in the kernel, not
in the policy) while multicast, broadcast and the unspecified address stay
refused and their sentences name the private-web rule; `build_fetch_stack`
selects the variant from the key and the served reader answers for a loopback
page only when the switch is on; and a source pin keeps the private-web
construction at exactly one site — the factory branch that reads the key — so
no other route can gain the grant. `test/check_transitional.toml` plus
`test/dune` rules run `--check` over a config that sets `cache_dir`, names a
`jina` primary and ladder, and turns the switch on: only unbuilt provider names
are enabled, so nothing is constructed, nothing is dialled, and the per-row
markers, the aggregated list, the private-web disclosure line and the exit-1
problem count are all blessed (`check_transitional_notes.expected` pins the
empty stderr). `test/test_config.ml` adds the uvicorn-key cases (non-default
refused at load and through `resolve`, defaults load and pass the rule) and the
all-unknown-keys-sorted case. The parity matrix moves `fetch.allow_private_addresses`
from `transitional` to `honoured` (with the new loopback-integration
verification) and both uvicorn keys to `refused`.

Gate at landing: `dune build @install`, `dune runtest --force` and
`dune build @doc` all exit 0 — including both `--check` pins, the stdio smoke,
the differential suite and the matrix guard. No suite reached a provider
endpoint.

## 15. F2.1 — the request and response heads have named byte ceilings (2026-11-13)

The serving path read every request through `Eio.Buf_read.of_flow ~max_size:max_int`
and every response head was written by hand at its call site. That is the one
trust boundary where a stranger decides how much this process allocates before
any routing, key or allowlist is consulted — the listener has no authentication,
so the request head is the first thing an unauthenticated peer can make it
buffer. Both directions now have a named ceiling in one module, `Http_head`, and
neither is `max_int`.

**The ceilings.** `Http_head.request_head_limit` is 16 KiB, matching h11's
`MAX_INCOMPLETE_EVENT_SIZE` — the bound the Python oracle inherits from uvicorn
without ever writing it down. `Http_head.response_head_limit` is 8 KiB and is a
guard, not a budget: no route in the tree produces a head near it, and it exists
so a future route that starts echoing a caller-shaped value into a header cannot
turn an answer into an allocation the caller chose.

**Reading.** `Http_head.request_reader` is the only reader built at the trust
boundary: `Buf_read.of_flow ~max_size:(limit + 1)`. `read_request_head` then
reads a byte at a time through `Buf_read.any_char`, so the count is of wire bytes
that actually arrived, terminators included, and the refusal happens *before*
the byte that would pass the ceiling is asked for. That makes the ceiling
cumulative and not per line: a thousand short headers are refused exactly as one
long one is. The result carries the parsed head and the exact bytes consumed, so
the transport parses what the peer sent rather than a reconstruction — a
bare-LF head is replayed with its LF, not rewritten into CRLF. Failures are
values (`Client_closed`, `Request_head_too_large`, `Malformed_request_head`), and
the one exception that can still escape, `Eio.Buf_read.Buffer_limit_exceeded`,
is caught and answered the same way.

**Replay without a recording.** The old `Tap` source recorded every byte of the
connection into an unbounded `Buffer.t`, and the replay reader was unbounded
too. Both are gone: the replay source is the exact head prefix plus
`Eio.Buf_read.as_flow` over the reader that consumed it, so bytes that were
already read ahead are served from the reader's own bounded buffer and bytes
still on the socket are read once. There is no second copy of the connection and
no `max_int` reader left on the path.

**Refusals.** The driver is now `Server.serve_connection ~clock ~log ~app
~server ~flow ~peer`, exported so a test can drive one connection and inject its
own clock; `serve_http` builds the listener and hands each accepted socket to
it. A head over the ceiling is `431 Request Header Fields Too Large`, a
malformed one `400 Bad Request`, a head that misses
`Server.request_head_timeout_seconds` (10 s, measured on the caller's monotonic
clock) `408 Request Timeout`, and a Host outside the allowlist (still applied
before either transport sees the request) `421 Invalid Host header`. Each
refusal carries `connection: close` and logs `http.head_rejected` with a
constant `kind` (`too_large`, `malformed`, `timeout`); a connect-and-close probe
gets no answer. After writing a refusal the driver drains the peer's remaining
input under the same timeout before closing: a refused over-cap head always has
at least the offending byte unread, and closing a socket with unread input makes
the kernel answer with RST, which can discard the refusal before the peer reads
it. The drain is bounded, so a peer that refuses to stop sending costs one
timeout and not an unbounded read.

431 is a deliberate divergence from the Python oracle: uvicorn/h11 reports a
head overflow as 400. F2.1 asks for a "431/400-class response", 431 is the
code HTTP defines for the condition, and the frozen surface does not name
refusal codes, so the clearer code is taken and recorded here rather than
inherited.

**Writing.** `Http_head.response_head` renders the status line, the caller's
headers, `content-length` from the body it will write, `connection: close` and
the blank line, computing the size before rendering anything and returning
`Response_head_too_large` past the ceiling. `Server.http_text_response` derives
every refusal's head from it (its signature is unchanged, so the exact-byte pin
in `test_p8_server.ml` still holds), and the custom routes go through
`bounded_response`, which replaces an over-cap head with a bounded empty 500
rather than writing it. `content-length` and `connection` are the module's,
never a caller's: hand-written protocol bytes compute their own lengths.

**Pins.** `test/test_http_head.ml` (11 cases) runs both layers. The pure cases
assert the boundary in bytes — a head of exactly `request_head_limit` bytes is
accepted and the next byte refused, many short headers are counted together, a
single huge header is refused, bare-LF bytes and CRLFs survive the replay, and
a response head at the cap is accepted while one byte over is refused. The wire
cases run one loopback connection through `Server.serve_connection`: an at-cap
head is served, an over-cap one gets a readable 431 with `connection: close`,
and an ordinary request on a fresh connection immediately afterwards is served;
a head delivered in pieces plus a chunked `POST /mcp` body reaches the tool
list; an unterminated head meets a fake `Eio.Time.Pi` clock whose `sleep_until`
returns at once, so the 408 is decided by the timeout and not by wall time; and
on a keep-alive connection a later over-wide header line is refused 431 through
the same bounded reader. No case sleeps on the wall clock.

**Boundary left open.** The exact cumulative counter covers the first head on a
connection. A later head on a keep-alive connection is read by the transport
from the same bounded `Buf_read`, so a line past the ceiling is refused before
the buffer grows, but a head assembled from many small lines on a *later*
request is bounded by the transport's parser rather than by the counter. Closing
that would mean owning keep-alive framing — reading each head with
`read_request_head` and handing the transport one request at a time — which is a
refactor of the connection driver, not a ceiling; it is recorded here rather
than half-done. The other response-header path, the cohttp client read of a
*provider's* response headers in `lib/caps/policy_net.ml`, is outside this
task's ownership and remains a follow-up.

Gate at landing: `dune build @install`, `dune runtest --force` and
`dune build @doc` all exit 0. The new suite opens only loopback sockets; no
suite reached a provider endpoint.
=======
## 16. F3.3 — corpus breadth, property runs and the application conformance baseline (2026-11-13)

Landed on `f3-3-diff`. F0.1's corpus was broad enough to prove the harness, not
broad enough to trust a port module against hostile input. This wave extends it
over every OCaml module the port already has, adds the deterministic property
half of the same claim, and gives the real binary an MCP-conformance baseline
that scores applicability to its own surface rather than resemblance to the
runner's fixture.

**Corpus: 294 inputs, 294 goldens, 304 runner cases.** The per-area counts are
config 85, sanitize 23, fetch 44, jsondoc 51, tabledoc 18, text 47, router 8,
model 7, engine 11; the `min_cases` floors are config 80, sanitize 20, fetch 40,
jsondoc 45, tabledoc 16, text 42, router 7, model 7, engine 10. The additions
target the shapes a fuzz report would name: malformed and truncated UTF-8,
printable and non-printable Unicode (NBSP, ZWSP, C0 controls, combining marks,
emoji), empty/deep (50 levels)/wide (40 members) documents, duplicate JSON keys
in both a JSON document and a tool request, 63-bit integers and past-their
range integers and floats, whitespace and BOM variants, JSONL and trailing
garbage, path grammar edge cases, differential window offsets (one, at end,
past end, on a paragraph break, mid-codepoint, cap of one, negative offset and
cap), five-rung ladders, and unicode query/result names.

A new area, `text`, covers `lib/text/utf8.ml` and `lib/text/repr.ml`:
`count`, `take`, `strip`/`lstrip`/`rstrip`, `words`, `lines`, `slices`, `repr`
and `roundtrip`. Its inputs carry a `hex` field so ill-formed bytes reach both
projections as bytes; the Python side decodes with `errors="replace"`, which is
why the four registrations below are called out rather than hidden. The `model`
area grew a `body_text` field for the same reason: duplicate keys must reach
both decoders uncollapsed.

**Properties: 14, 200 cases each.** `test_differential_properties.ml` runs
`sanitize` idempotence and reversal (modulo a U+200B the caller wrote), `utf8`
slice partition, valid round-trip, `take` prefix/count and `strip` fixed point,
`fetch window` prefix/marker/flag agreement, past-end emptiness, uncapped
identity, `jsondoc` render/schema path parsing and name/ordinal path round
trips, and `tabledoc` cell-path selection. Determinism is explicit: each
property has its own `Random.State` from the literal seed `20261113` and a salt,
with `~count:200 ~long:false`, so `QCHECK_SEED`, `QCHECK_COUNT` and
`QCHECK_LONG` cannot change what the gate ran (verified: `QCHECK_SEED=1
QCHECK_COUNT=2` still runs 14 × 200).

**Dependency decision: QCheck.** `qcheck-core` + `qcheck-alcotest` are
`:with-test` in `dune-project`. Measured in the `default` switch: two packages,
about 5 MB installed, BSD-2-Clause, no transitive dependency this tree does not
already carry (`dune`, `alcotest`, `base-unix`). A hand-rolled generator plus
shrinker was the alternative; shrinking is the part that makes a failure
readable, and writing it is how the suite grows a second, worse one.

**Divergences found, and why they are recorded rather than fixed.** F3.3 owns
`test/differential/**`, `ocaml-tools/oracle/**` and `test/conformance/**`;
`lib/**` is read-only on this branch. Each of these is an `explicit-divergence`
golden with a named reason in `gen_goldens.py`, and each is a candidate for the
module owner:

1. `Utf8.next_index` clamps by bytes present, not by the valid continuation run
   → `count`/`roundtrip` differ on `\xe2abc`, overlong `\xc0\xaf` and surrogate
   `\xed\xa0\x80`; `of_string` → `to_string` is not the identity on ill-formed
   input.
2. `Utf8.splitlines` appends a trailing empty line after a final break; Python
   drops it. `utf8.mli`'s doc-comment claims Python parity and is wrong.
3. `Utf8.is_line_boundary` omits lone CR (deliberate and documented, because the
   CSV reader depends on CRLF keeping its CR) → CRLF keeps its CR and a lone CR
   does not break.
4. `Repr.py_repr` passes non-printable non-ASCII (NBSP, ZWSP) through where
   Python escapes it; also visible in a router refusal sentence.
5. `Tabledoc.read_records` drops a field that is empty and last in a record
   (`a,b,` reads as two columns, not three with an empty `column3`).
6. `Config`'s TOML reader reports `PARSE-ERR` for valid TOML above OCaml's
   63-bit int (2^62, 2^70), and does not support hex ints or `nan`/`inf`
   floats, all of which `tomllib` accepts.
7. `Model`'s decoder refuses `Intlit` (2^70 in `fetch_request.offset`) with
   "expected an integer, got an integer" where pydantic accepts; duplicate keys
   resolve first (Yojson) vs last (Python `json.loads`).
8. `Fetcher.window_text` raises `Invalid_argument("Array.sub")` on a negative
   offset and returns an empty window on a negative cap. Unreachable through
   the tool surface (it checks `offset ≥ 0` and uses config-constant caps), so
   the corpus pins the function-level behaviour only.

**Application conformance baseline.** `test/conformance/run_live_application.sh`
drives `bin/main.exe --http` with the same pinned runner and the same 37 scored
+ 13 unscored scenarios, but scores through
`application-classification-2026-07-28-server.json` and
`compare_application.py`. Every check is classed `applicable`, `fixture-declaration`,
`absent-feature`, `oracle-parity` or `port-divergence`; every applicable check
must pass, every excluded check must keep its recorded status, and the runner's
scenario/check sets must still equal the classification. Measured 2026-11-13:
**90/90 applicable checks pass** (89 `SUCCESS`, 1 `INFO`), 4 applicable + 3
mixed + 43 excluded scenarios, gate pass. The raw runner tally is 8/37, written
down as a footnote: `resources-list` and `prompts-list` pass on an empty list,
and two SEP-2322 scenarios pass on the unknown-tool error path, so counting
them would measure the runner's fixture shape, not the three-tool surface.

Two failures are recorded rather than silenced:

- `localhost-host-valid-accepted` is `oracle-parity`: the runner sends
  `Origin: http://127.0.0.1:8811`, both implementations allowlist bare loopback
  origins and answer 403, so the check distinguishes nothing. (Its hardcoded
  8811 is also not the server's URL.) A future widening of the Origin allowlist
  must change both trees and reclassify this check.
- `sep-2575-server-declares-prompts-in-discover` is a `port-divergence` and a
  real wire inconsistency: the OCaml server answers `prompts/list` and
  `resources/list` with empty arrays but declares only `tools` in
  `server/discover`, while the Python `MCPServer` declares both. mcp-kit 0.2.0's
  `Server.of_registry` answers the list methods without adding the capability;
  neither mcp-kit nor `lib/server.ml` is in this wave's ownership. Fixing it
  means either declaring the capability or returning method-not-found, and
  landing the same choice in both trees.

The hermetic half is `application_transcript.jsonl`: the runner-shaped tool
calls (missing argument, too-short string, out-of-enum provider, non-URL,
private address, agent disabled, unknown tool) and a modern `server/discover`
replayed through the real binary over stdio, pinned as
`application_transcript.expected` with an empty stderr. `dune runtest` runs it;
no socket opens, no provider is contacted, and `application.toml` sets
`search.health_interval_seconds = 0` besides.

**Gate at landing.** `dune build @install`, `dune runtest --force` and
`dune build @doc` exit 0 under the opam+GMP environment. No gate step reaches a
provider; the live application script is not part of `runtest`, and its only
network traffic is loopback to the binary it started.
=======
## 17. F3.2 — the CLI as library plus effects (2026-11-13)

Landed on `f3-2-cli`. Spec: `plans/ocaml-finalisation.md` §F3.2.

**Why the split.** The Python's CLI calls `parser.error` and `sys.exit` from
the middle of its argument code, so nothing of it is callable — which is why
`tests/test_cli.py` can only drive it as a subprocess. The port moves every
decision out of `bin/main.ml` into a new library, `seekwright.cli`
(`lib/cli/`), that names no stream and never exits:

- `Cli_extract` — the client's argument scan (`scan_args`) and the three
  request bodies; the scan keeps argparse's quirks, `--flag=value` inline,
  `BooleanOptionalAction` for `--safe-search`/`--no-safe-search` (both
  spellings fill the field without eating the next token), and the request
  models are the validators, so a body the REST route would refuse is refused
  at the scan with the Python's sentence.
- `Cli_flags` — the server-flag scanner (still dispatched only through
  `Server.flag_spec` and the table's keys) and `startup_refusal`, the four
  startup refusals in the Python's order, as sentences.
- `Cli_client` — verbs, routes, status handling, human rendering, exit codes,
  over an injected `post : path -> string -> (int * string, string) result`.
- `Cli_check` / `Cli_metrics` — the two reports, driven through an `emit`
  line callback, and the metrics report takes `now` as an argument so the
  window's dates are facts of the test rather than of the clock.

`bin/main.ml` (1011 → 263 lines) keeps only the effects: which verb or flag
set this invocation is, the `Eio_main` loop and the `Eio.Stdenv.t` the
network grants open on, the one real `post` (plain HTTP to the loopback
default, HTTPS through `ca-certs` + `tls-eio`), stdout/stderr and the exit
status. The verb's own flags stay with the verb: `Cli_client.run` reads
`--json` and `--server` from its scan, so the binary spells no flag at all.
`test_p8_server`'s flag guard now reads `lib/cli/cli_flags.ml` for
the scanner and requires `bin/main.ml` to hold no `flag_spec` and no flag
spelling of its own; `test_fetch_grant`'s private-web disclosure guard reads
`lib/cli/cli_check.ml`.

**New suites** (`test/test_cli_extract|flags|client|check|metrics.ml`): the
flag-to-field table, the usage sentences, the startup refusals over in-memory
fixture configs, the client around a fake `post` (route per verb, `--server`
origin, status → sentence → exit code, the human layouts, the `--json`
echo), and both report pieces through `emit`. Plus executable rules in
`test/dune` (the pattern `bin/check_unbuilt` already used) that pin the
binary's frozen sentences byte for byte: three usage refusals and two startup
refusals on stderr with their exit codes, empty stdout pinned beside each by
one shared empty golden, and `--metrics --json` over an empty board on
stdout — the only metrics pin that survives the calendar,
since the report's window is counted from the run's clock; the dated table
stays pinned in `test_cli_metrics.ml` with the clock injected. `seen` is now
the Python's `fromisoformat().astimezone(UTC)` rendering rather than a
string cut, so `±HH:MM` stamps print as UTC like Python's do.

Gate at landing: `dune build @install`, `dune runtest --force` and
`dune build @doc` all exit 0 — every existing golden (`bin/check_unbuilt*`,
`bin/smoke*`, `test/check_transitional*`) byte-identical. No suite reached a
provider endpoint.

## 18. F2.4 — shared state under concurrent calls (2026-11-13)

Landed on `f2-4-concurrency`. Spec: `plans/ocaml-finalisation.md` §F2.4.

**What is shared, and by whom.** Every MCP and REST call is served on its own
Eio fiber, so one process reaches three mutable things at once: `Usage`'s
aggregates plus its JSONL journal, `Health`'s provider board, and the app value
the routes read. The Python confined all three to one event loop (plain
attributes, no locks); the port cannot borrow that argument, so each seam states
its own.

- `Usage` now owns an `Eio.Mutex` (`t.lock`). `record_search`,
  `record_fetch` and `record_answer` fold the line into the aggregates and
  append it to the journal inside one critical section, and `snapshot` takes
  the same guard. The fold has no suspension point today, but `append` is I/O
  and therefore is one, so the guard is what makes the aggregate order, the
  journal order and a dashboard read agree, and what keeps two fibers' bytes
  from sharing a journal line. `Eio.Mutex`, not `Stdlib.Mutex`: a waiting fiber
  must park and let the holder's append finish rather than block the domain it
  needs. `t` remains a single-domain value; a worker domain would need a real
  lock at the boundary, which the absence of one records.
- `Health` needed no lock, and `lib/health.mli` now says why: every public
  mutator is a critical section with no yield — the clock read, the lookup, the
  update and the log emission all run between two yields — so fibers interleave
  only between whole transitions. The invariant to preserve when editing is
  exactly that; a suspension point inside a mutator would need a guard.
- `lib/server.mli` records the transport decision instead of adding a lock.
  Streamable HTTP is stateless per POST: one body in, one dispatch against the
  immutable `Mcp_kit.Server.t`, one response out, so request ids cannot be
  confused and a duplicate id on two connections is two calls. stdio is one
  line stream and is serialised by construction. `serve_connection` carries no
  lock and must not gain one — a mutex over dispatch would queue every
  dashboard read behind every provider call.

**The determinism suite** (`test/test_concurrency.ml`, one `Alcotest` case).
It builds `Server.app` by hand with a fake `Provider.S`, a fake fetcher and a
real `Agent` over a fake model endpoint, all dialing a second loopback listener
through audited `Factory` grants (`Factory.grant_of_endpoint`,
`Factory.probe_net`, `Factory.audit_sink`). The REST projection is served by an
accept loop handing each socket to `Server.serve_connection` — the same
function production uses — so six searches, six fetches, six answers, three
dashboard reads and eight health ticks overlap on real connections. Both clocks
are one fixed instant and the monitor's `sleep` is a `Fiber.yield`, so no case
waits: the assertions are exact and order-independent.

They assert:

- each response carries its own request's marker (a body handed to another
  caller fails even if every aggregate still adds up);
- the aggregates are arithmetic over the fixture — twelve searches (six direct
  plus the answers' retrieval steps), six fetches, six answers, `$0.012` of
  search spend, one dispatch per fake provider/fetcher call;
- every dashboard read satisfies the same identities at the moment it was
  taken (lifetime = provider rows = window, recent holds one entry per line);
- the journal is one complete JSON object per terminal line, ends with a
  newline, carries the right tool counts and attributes every search line;
- one `caps.operation` audit event per provider, fetch, model and probe
  request, and one `health.probe` per tick;
- the switch drains: no connection outlives it, no gate is open after only
  successes.

The fixture sets `SEEKWRIGHT_AGENT_API_KEY` and `SEEKWRIGHT_SERPER_API_KEY` so
agent mode and the probe take their dialing branch rather than refusing before
any request, and installs `Mirage_crypto_rng_unix.use_default ()` because the
capability grants mint tokens. No case reaches a real provider.

Gate at landing: `dune build @install`, `dune runtest --force` and
`dune build @doc` all exit 0 under the opam+GMP environment. The new suite is
hermetic — loopback and fakes only.
=======
## 19. F2.2 — extraction runs on a bounded pool of worker domains (2026-11-13)

Landed on `f2-2-extract`. Spec: `plans/ocaml-finalisation.md` §F2.2.

**The runner.** `seekwright.fetch` gains `Extract_pool` (`lib/fetch/extract_pool.ml{,i}`):
a fixed-size pool of worker domains — `workers_default = max 1 (min 4
(recommended_domain_count - 1))`, so the Eio loop keeps a core — fed one job at
a time over per-worker `AF_UNIX` stream sockets, not a shared-memory queue.
That transport is the design's load-bearing choice: the loop-side half of every
job is an ordinary cancellable `Eio.Net.connect`/flow exchange, so a deadline
or a caller's cancellation closes the socket on the way out, the worker
observes the half-job as EOF and discards it, and a late result arrives on a
closed connection and fails to write — the cooperative abandonment the F2.2
spec asks for, with no shutdown protocol to fake. Workers speak plain `Unix`
syscalls (no Eio inside a worker domain); the frame grammar is
length-prefixed big-endian i64 fields under `~max_body_bytes` /
`~max_result_bytes` ceilings, so an over-declared frame closes the connection
instead of allocating.

**Bounds, by construction.** The domain count never grows. `Eio.Semaphore`
permits (`workers + queue_limit`, default queue = workers) bound
in-flight-plus-queued jobs; a caller past the ceiling waits as a fiber, opening
no socket. Socket paths are created `0600` under `~dir`, named for pid + pool
sequence + worker index, unlinked by the worker itself on exit; `~dir` over the
107-byte `sockaddr_un` limit is refused at `make` with the real sentence. A
worker that cannot bind fails `make` as an `Error` — a fetch stack silently
running inline again is the failure mode the constructor exists to make loud.
`make`'s readiness handshake keeps one close per fd: domains share the process
fd table, so the constructor closing a pipe write-end the worker had already
closed was a use-after-close on a reused number — it killed other domains'
sockets at flaky odds (an accept loop starved of its quit sentinel, a
`Domain.join` that never returned; the suite caught it, only under load). The
worker closes the write-end and always writes its `R`/`E` byte before it can
die; the parent closes only the read-end.
The factory (`build_fetch_stack`) builds one pool per fetch stack in the system
temp dir (no config key: the sockets are process-scoped, `0600`, and gone on
close) and passes it beside `~parse_timeout_seconds:fetch.timeout_seconds` to
`Fetcher.make`; the reader's `aclose` drains the pool (quit sentinel, then
`Domain.join`, so running jobs are waited on — the Python fetcher's rule for
its worker threads, said once in `extract_pool.mli`'s shutdown section).

**Timeouts.** `Extract_pool.extract ?timeout_seconds` answers the sum
`Timed_out | Pool_closed | Backend of string | Worker of string`; the timeout
bounds the exchange from the moment the job takes its permit — queue wait is
bounded instead by the `workers + queue_limit` semaphore ceiling. (The plan
said "counts queue wait too, matching `asyncio.wait_for`"; building it that
way deadlocked the suite: `Eio.Semaphore.acquire` **leaks the permit** when a
parked fiber is cancelled mid-handoff — verified with a standalone probe — so
deadline-cancelled queue-waiters shrink the pool's budget forever. The acquire
is run under `Eio.Cancel.protect` and the caller's cancellation lands at a
`Fiber.check` inside the guard that releases the permit; `asyncio` lands the
same way, since `Queue.get` has taken the item before a `wait_for` deadline
can fire around it.) `Fetcher`
`extract_body` turns `Timed_out` into the oracle's exact non-retryable
refusal (`cannot extract text: {kind} extraction did not finish within %g
seconds; raise fetch.timeout_seconds to allow a longer parse` — the missing
" seconds" the port had dropped from the `%g` sentence is restored),
`Pool_closed` into a `Failed`, and `Backend`/`Worker` into the same
`cannot extract text:` shape an inline `Extraction_failed` already produced.
The chain budget (twice the request timeout, built at the call site) bounds
the whole request around it. The inline path (`?workers` absent) stays as the
fixture/embedder seam so the ~71 existing fetch tests keep their construction;
the factory always wires the pool.

**Tests.** `test/test_extract_pool.ml` (8 cases) and
`test/test_fetch_workers.ml` (4 cases) port the oracle's
`_GrindingExtractor`/`TestExtractionTime` shapes: a busy parse leaves the loop
ticking (≥10 ticks) and runs on a domain other than the loop's; an overrunning
parse answers `Timed_out` at its deadline with the pool healthy afterwards;
ten pressured calls against two burner workers all end, in-flight never exceeds
the pool, open fds return to baseline, and ordinary work answers afterwards;
backend failure is carried as a value; an over-ceiling result frame is a
`Worker` failure, not a stall; `close` waits for a running job, then answers
`Pool_closed`, idempotently; and through the fetcher: the exact deadline
sentence for an `application/pdf` body, a chain budget cutting an unbounded
parse, and an in-time parse returning its page. The oracle's shared-stream
real-PDF case is deferred with PDF support (F6.2) — this port ships no PDF
backend, and the refusal sentence keeps the oracle's media type.

Gate at landing: `dune build @install`, `dune runtest --force` and
`dune build @doc` all exit 0; the `router_dependencies` pin is untouched (the
pool lives under `lib/fetch/`, outside the pin's `lib/*.ml` glob). No suite
reached a provider endpoint.

## 20. F4.2 — one narrow MCP client, no second MCP stack (2026-11-13)

Landed on `f4-2-mcpclient`. Spec: `plans/ocaml-finalisation.md` §F4.2.

**What landed.** `seekwright.providers` gains `Mcp_client`
(`lib/providers/mcp_client.ml{,i}`), the session half of the oracle's
`ExaMcpProvider`: `initialize`/`notifications/initialized`, `tools/call` with
sequential JSON-RPC ids, JSON and bounded SSE result framing, the
`Mcp-Session-Id`/`MCP-Protocol-Version` headers, exactly one reconnect after a
dead session, and a best-effort `DELETE` on close. It is not part of
`mcp-caps` and does not grow server features: a provider adapter is a client,
and the two share no code path, transport or type. `lib/providers/dune` needed
no edit — the library names no module list, so the new module is picked up.

**The spike's answer: discrete POSTs are sufficient, so the grant was not
widened.** Streamable HTTP carries one JSON-RPC message per POST, so the
"session" a client owns is the server's header value, not a held socket — the
same one-request/one-response shape the endpoint-scoped `Provider.Net.t` grant
already offers, with its byte ceiling and whole-operation timeout. Probed
against the documented endpoints before writing the module (keyless tiers only;
the one Exa search was the free anonymous one): Exa answers
`text/event-stream` with an `mcp-session-id`, answers the notification `202`
with an empty body, and returns a keyless search as a single SSE frame whose
`content[0].text` is the `Title:`/`URL:`/`Published:`/`Highlights:` block;
Parallel answers `application/json` with an `mcp-session-id`, acknowledges the
notification `202`, and returns `content[0].type == "text"` with `isError:
false` beside a `structuredContent` this client deliberately ignores. Two live
findings matter for F5.1: Exa's `web_search_exa` currently requires
`objective` in addition to `query` (the request is refused without it), and a
bogus `Mcp-Session-Id` is still answered `200`, so Exa never exercises the
404-reconnect path in production — that path is specification-driven and
pinned hermetically here, not observed live.

**Bounds and vocabulary are the module's own.** One frame (a JSON body or one
SSE event) is capped at 262 144 bytes, and one POST may carry 64 events; a
frame over the ceiling or an event over the count is refused, never truncated.
A body that ends without its final blank line still dispatches — refusing a
whole answer over a trailing newline would be a parser bug wearing a bound's
clothes. Failures carry one sentence from a fixed list (`MCP handshake failed`,
`MCP handshake timed out`, `MCP session unavailable`, `malformed MCP response`,
`MCP response exceeded its frame bound`, `upstream MCP request was rejected`,
`upstream MCP tool reported an error`, `rate limited`, `MCP client is closed`)
or one of the contract's shared rows; an `isError` result is classified by the
oracle's rule (a mention of `rate`, `quota` or `429` is the quota row,
everything else is the tool-error sentence) and its text is never echoed. Exa's
live invalid-key answer is a `200` with `isError: true` carrying
`web_search_exa error (401): Invalid API key …`, so it lands on the tool-error
row rather than the auth row: there is no status line to map, exactly as in
Python. The reconnect trigger is exactly a `404` answering a call that carried
a session id; one retry per call, and a second `404` is `MCP session
unavailable`. Timeouts, malformed or oversized frames and valid provider
errors are never retried.

**Single-domain state, no new dependency.** The client's session, id counter and
closed flag are plain references, mutated in sections that do not yield before
the id is captured — safe on the one Eio domain a provider adapter runs on, and
the reason the adapter library did not gain an `eio` dependency for a mutex.
`call_tool` handshakes lazily, so a caller that fans calls out to fibers
handshakes once first; two concurrent *first* calls would each handshake, and
`mcp_client.mli` says so rather than pretending a lock exists.

**Tests.** `test/test_mcp_client.ml` (20 cases) drives the client through a
`Policy.with_endpoints` grant against a real loopback `Cohttp_eio.Server`, the
same fixture shape `test_fetch_http.ml` and `test_authority_net.ml` use. The
routes cover JSON and SSE answers, an SSE body whose first frame is a
notification, a stateless endpoint, a `500`/garbage/RPC-error/timed-out
handshake, `isError` in its quota, Exa-invalid-key and generic shapes, a `401`
status, a malformed body, an oversized SSE event and an oversized JSON body,
two concurrent calls with distinct ids, a session that dies once and one that
dies twice, a tool-call timeout, and close (including that `DELETE` carries the
session id and that closing twice sends one). The fixture answers every
stateful route only for the session it issued, and echoes a probe key in the
bodies it fails with; each expectation renders the failure it got, so a body or
header reaching a provider error fails the case that produced it. No suite
names a provider endpoint, so the gate cannot bill anything.

**Two guards moved, minimally, with the coordinator's approval.** Adding a
non-adapter module under `lib/providers/` tripped two pre-existing guards:
`test_provider_contract.ml`'s "every adapter module on disk is driven here"
now exempts `mcp_client` (it is a client, not an adapter, so it owes no failure
row), and `test_provider.ml`'s source-discipline count moved 3 → 4 so the
client is scanned for the forbidden literals too — it builds provider errors,
so the redaction rule applies to it. Neither guard's rule changed.

Gate at landing: `dune build @install`, `dune runtest --force` (54 suites) and
`dune build @doc` all exit 0; the new `.mli` adds no odoc warning. Live-endpoint
evidence above is a report finding, not part of the default gate.
=======
## 21. F2.3 — stop, drain and close in one owner (2026-11-13)

Landed on `f2-3-drain`. Spec: `plans/ocaml-finalisation.md` §F2.3.

**The stop input and the lifecycle value.** `Server.serve_http` now takes
`~stop:unit Eio.Promise.t` and `?grace_seconds` (default
`Server.drain_grace_seconds = 10.0`, a constant because the oracle has no flag
or config key for it) and answers
`(lifecycle, serve_error) result`, where `lifecycle = Drained | Grace_expired`.
The stop promise is no longer discarded: a requested stop is a success even
when the grace had to force the last connections out, so `bin` exits 0 on
either arm and `Error` is reserved for the listener's own startup failure.
Cancellation arriving from an enclosing switch is re-raised as
`Eio.Cancel.Cancelled`, never translated into a listener or provider failure.

**Why the accept loop is ours.** `Eio.Net.run_server ~stop` stops accepting but
leaves the listening socket open (the caller owns it), so a probe arriving
during the drain would still complete its TCP handshake into the backlog and
never be refused. `serve_http` therefore runs its own accept loop: the loop has
its own `Cancel.sub` context, so a stop cancels just the loop and joins it, and
then closes the listener — after which another connection attempt is refused
while the accepted request is still being drained. The accepted connections
live in one `Eio.Switch.run` scope, so the grace ceiling can fail that switch
as a unit; `Eio.Condition` over an active-connection counter is the join point,
so the drain waits for real work rather than sleeping out the grace. Connection
exceptions still go to `on_error` (a rejected Origin stays INFO), not to the
switch, so one bad connection never cancels its neighbours.

**The stopping state.** An `Atomic.t` set before the accept loop is told to
stop is threaded as `?stopping:(unit -> bool)` through `serve_connection`,
`custom_handler` and `handle_custom` (default `false`, so route-level suites
need no change). While it is true, `/healthz`, `/dashboard/data` and
`/dashboard/metrics` answer 503 `{"status":"stopping"}`, the three REST
projections answer 503 `{"error":"The server is stopping; retry shortly."}`
before touching their engines, and `/dashboard` itself stays the static 200 it
is — it accepts no work. Nothing new is read to say so.

**Signals.** `lib/cli/cli_serve.ml{,i}` owns the process path: SIGINT and
SIGTERM handlers write one byte to a `Unix.pipe` self-pipe and do nothing else
(no promise, no allocation, no log, no protocol stream); one watcher fiber
waits with `Eio_unix.await_readable` and fills the stop promise on the first
byte, so a second signal is ignored. The handlers are installed only when the
caller supplies no `?stop`, restore the previous behavior under
`Eio.Cancel.protect`, and the descriptors close after the watcher is joined.
`Cli_serve.run_http` also owns "close exactly once": `close` runs in a
`Fun.protect` finally on every exit path — bind failure, cancellation and a
completed drain — after the listener has joined its connections but before the
caller's app switch ends. `bin/main.ml` supplies
`close = List.iter (fun (_, p) -> Provider.aclose p) built.Factory.built` and
the health fiber is cancelled through its own `Cancel.t`, so an in-flight probe
is aborted rather than waited out. The usage journal needs no flush step:
`Usage.append` opens, appends one record and closes before returning, so every
completed call's line is already on disk when the drain starts.

**Known gap.** The fetch stack's readers own an `Extract_pool` whose `aclose`
drains worker domains, but the reader value is reachable only through
`Server.app.fetch`, which is abstract, and `lib/factory/` is out of this task's
scope. `bin` closes the built providers only; the pool's sockets are
process-scoped and are reclaimed when the process exits, so no worker outlives
the process, but the drain is not the thing that ends it. Making the app carry
its construction graph would close this properly and is the follow-up.

**Tests.** `test/test_drain.ml` drives the injected-stop path in-process: a
stub `Provider.S` resolves a `started` promise and waits on a `release`
promise, a real loopback client keeps the REST call in flight, and the suite
asserts the 200 answer, `Ok Drained`, and that `close` ran once and only after
the call. A second case hangs the provider, passes `~grace_seconds:0.2` and
asserts `Ok Grace_expired` under a one-second wall bound, with `close` still
exactly once. A third asserts the stopping surface: 503 + sentinel on the three
operational GETs, 503 + retry sentence on all three projections, 200 on
`/dashboard`, and 200 `{"status":"ok"}` when stopping is the default false.
`test/test_binary_drain.ml` is the real process case: it starts
`bin/main.exe` on a free loopback port under `test/drain.toml` (keyless
defaults, stdlib extractor, health interval 0), opens a REST request with half
its body, sends SIGTERM, waits until a second connect is refused, finishes the
body, reads 503 with the retry sentence and asserts `WEXITED 0`. The search body
names `serper`, which this build does not carry, so even a missed stop cannot
dial anything; no case reaches a public provider.

Gate at landing: `dune build @install`, `dune runtest --force` and
`dune build @doc` all exit 0 under the opam+GMP environment. The new suites are
hermetic — loopback and promises only.
=======
## 22. F4.1 — one declarative row per provider name (2026-11-13)

Landed on `f4-1-registry`. Spec: `plans/ocaml-finalisation.md` §F4.1.

**The table.** `seekwright.factory` gains `Registry` (`lib/factory/registry.ml{,i}`):
one data row per name, for all seventeen, carrying the endpoint and how it is
derived, the credential's wire shape, what the name needs before it can be built,
the default price and the pricing model, the timeout floor, which policy cap
bounds its results, its readiness probe, the `[[providers.<name>]]` keys its
adapter reads, and whether this port has a recorded live run. `build_providers` is
now one pass over those rows: the two-entry `adapters` table, the `keyless_headers`
stub and the local `cost_of` are deleted, and the three decisions the function
still makes are the three a row cannot make — is the name enabled, is it built on
this port, did this deployment supply what its row requires. `build` is
`Adapter of (args -> Provider.t) | Deferred wave`, so fifteen rows are the
inventory of names F5 will carry rather than a promise of dispatch: an enabled
name with a `Deferred` row is still `unsupported` and still startup-fatal, which
is why every F1.1 pin (`test_routing_sets`, `test_cli_check`'s expected `--check`
output) holds with its old wording.

**One destination.** `Registry.uri` is the only place a destination is computed and
`Registry.grant_endpoint` turns it into the `Policy` entry through
`Seekwright.Provider.policy_of_uri`, the new seam in `lib/provider.ml{,i}`; the
adapter dials that URI, the grant allows the entry derived from it, and there is
no third spelling of the host. `freeserp` and `anysearch` now write
`policy_endpoint = Provider.policy_of_uri endpoint` instead of a literal triple,
and `Factory.agent_net` reads the same derivation — `[agent] base_url` is a second
configured destination, not a second scheme/host/port spelling. The
config-derived ones are `Url_required` (`searxng`), `Url_override` (`exa`,
`exa:free`, `parallel:free`) and `Algolia_index` (`{app_id}-dsn.algolia.net`, with
`index` escaped by `Provider.escape_path_segment`, the port of the oracle's
`quote(value, safe="")` — `Uri.escape` keeps `&` and `?` literal, which splits a
path segment). A config `url` that is not an absolute http(s) URL, or that carries
userinfo, is a construction failure naming the **key** and never echoing the value;
a `Fixed_uri` row ignores a config `url` as the oracle does, and the row's
`settings` list is what discloses that.

**One price, one rung.** `default_cost` is the figure a `[[providers]]`
`cost_per_1k` may correct; `None` fixes it at zero, which is `exa:free` alone — a
config correction cannot bill the name that cannot bill. `cost_model` is `Flat`
everywhere except `exa`, whose published shape is a subscription covering the
first 10 results plus `$1.00` per thousand beyond; `Registry.cost_of` applies it,
and each built adapter's own `cost_for` is pinned against that figure.

**A floor, not a ceiling.** `timeout_seconds row ~policy_seconds = max policy floor`,
floors `exa`/`exa:free`/`parallel:free` 30s (the MCP handshake's headroom), `linkup`
20s (the deep rung), `scrappa` and `searxng` 15s (a scrape and a metasearch
fan-out); the grant's operation bound is that number, so a raised
`policy.provider_timeout_seconds` still raises a name that had no floor.

**No credential crossing.** `key_for` consults `requires` before it consults the
environment, so a keyless row answers `None` with `SEEKWRIGHT_EXA_API_KEY` in hand
and a `searxng` grant cannot acquire a header by accident. `credential` is the
wire shape — `Header {header; prefix}`, `App_id_and_key` (Algolia's public
identifier plus the secret), `Key_in_query "api_key"` (`serpapi`) — and
`probe_spec` builds its headers from that same declaration, so `--check` cannot
authenticate a name in a shape no search uses; `No_probe` is the three MCP-backed
names, which the oracle proves with a session handshake this contract has no
`warmup` member for, so they answer `Unsupported` like a name with no probe.
`serpapi`'s query-string key is why `Provider.redact_url` (the oracle's
`urlsplit(url).hostname or "?"`) is in the seam now, before the adapter lands in
F5.5: a probe URL carrying it is pinned to reduce to `serpapi.com`.

**Live-tested is one field.** `ocaml_live_tested` is not a labelled argument of
`make_row` — it is written there, `false`, once, until the F4.3 runner records a
run. `classify` reads the field, so `--check`'s OCaml-untested disclosure and the
table are the same fact rather than two lists kept in step.

**Rows stay out of routing.** `permitted_providers` filters no row: an enabled,
built, unpermitted name is still built, so the refusal stays the router's sentence
naming the permitted set and `Factory.classify`'s `effective` stays the one place
the narrowing shows.

**Tests.** `test/test_provider_registry.ml` (21 cases in eight groups) asks the
rows themselves the questions, with sentinel keys in the environment and grants
constructed but never dialled: the row names equal `Config.known_providers` and are
stored sorted; the built half is `anysearch`/`freeserp` and the deferred half
names its wave; the default-cost column is the oracle's seventeen figures, and a
config `cost_per_1k` moves every one of them except `exa:free`'s; only `exa` has
the extra-result rung, pinned at 10 results and $1.00 per thousand beyond; the six
floors and the `max` merge are pinned both ways; every grant entry equals
`policy_of_uri` of the row's own URI, an override that
says `:8443` pins that port, `searxng` without a `url` and `algolia` without
`app_id`/`index` refuse, and a userinfo-bearing `url` is refused without echoing
it; each probe asks the host its grant allows and authenticates with its row's
credential; the `Api_key` prerequisite is exactly `Config.providers_requiring_key`
(the instance keys ride beside it) and a name that needs a key has a place on the
wire to put it; `redact_url` kills the sentinel; the union of the rows' `settings`
is the field list `provider_config` has (and no row claims `enabled` or
`cost_per_1k`, the two the factory reads for every name); and construction builds
two of seventeen with no grant error, prices each adapter at its row and pins its
own `cost_for` against the row's `cost_of` at 1, 10 and 20 results, and carries a
config `cost_per_1k` through to the adapter. A new case pins that a narrowed
permission set changes no row's price or endpoint and builds both names.

`test/differential/matrix/providers.tsv` is untouched: its column set is pinned by
`test_differential_matrix.ml` and generated by `ocaml-tools/oracle/gen_matrix.py`,
so widening it to carry a floor or a pricing rung is its own change with its own
reasoning.

Gate at landing: `dune build @install`, `dune runtest --force` (54 suites) and
`dune build @doc` all exit 0. The `test_caps_audit` funnel pins survive the
rewrite intact — `build_providers` names its endpoint/bound pair `adapter` and
`agent_net` binds `endpoint`, so the source scan still reads one
`Authority.with_log`, one `Authority.Net.of_confinement`, `?audit adapter.endpoint`
and `?audit endpoint)`. No suite reached a provider endpoint; no key was needed.

## 23. F4.3 — the explicit live harness, and its first keyless runs (2026-11-13)

Landed on `f4-3-live`. Spec: `plans/ocaml-finalisation.md` §F4.3.

**What landed.** `live/` holds the port's live runner: a `live_harness` library
(`Cases`, `Checks`, `Runner`), the executable `main` published as
`seekwright-live`, and the hermetic `test_live_cases`. It is deliberately *not*
part of the test aliases — `dune runtest` stays offline, and no gate step
reaches a provider. `seekwright-live` is built by `dune build @install` so the
instrument travels with the tree, but running it is a maintainer act, not CI.

**One named case, never a sweep.** `main` requires
`SEEKWRIGHT_LIVE_TESTS=1` and exactly one selector: one of the seventeen
provider names (the flavour form `exa:free` is parsed as a provider before the
namespace split), `fetch:local|metadata|jina|scrappa|tavily|linkup`, or
`agent:brief|report`. `all`, `*`, `every` and the empty string are refused; there
is no "everything configured" mode, so a billed name is reached only by setting
the gate and spelling it. `--list` and `--help` are hermetic.

**The case is data; the assertions are per adapter.** `Cases` holds the query,
width, filters and cost class of each case and derives build status from the F4.1
registry rows: the fifteen unbuilt names skip with their wave (`F5.1`–`F5.5`) and
the fetch fallbacks with `F6.1`, while `freeserp` and `anysearch` are runnable.
`Checks` ports the oracle's assertion bodies one function per case — a SERP
backend fills `snippet` and never `text`, a content backend the reverse, a domain
filter constrains the returned URLs, an answer backend answers, the metadata case
is a refusal — and `Checks.provider_step` fails loudly for a name with no arm, so
a new adapter cannot arrive behind a generic "returned something" check. Status
mapping: 0 pass/skip, 1 failed assertion, 2 refused/misused, 3 inconclusive. The
quota branch is the engine's own "Do not retry immediately." advice, so a
rate-limited run is recorded as unproven, never as a pass.

**Construction is the application's.** A provider case builds through
`Factory.build_providers` and one `Engine.Search` (a named provider is terminal,
as when served); a fetch case through `Factory.build_fetch_stack` and one
`Engine.Fetch`, closing the stack afterwards; an agent case through
`Factory.build_app` with only `freeserp` enabled, so the unnamed retrieval route
is free-only. The header prints `scheme://host` and the credential's *variable
name*, never a key value or a URL query.

**Initial acceptance: the two keyless runs.** The maintainer authorised exactly
one run of each keyless built case, separately, and no billed call:

| date | case | commit | result | note |
|---|---|---|---|---|
| 2026-11-13 | `freeserp` | `73fcf73` | passed, 6/6 | keyless; `search "python asyncio tutorial"`, 5 results |
| 2026-11-13 | `anysearch` | `73fcf73` | passed, 6/6 | keyless; same query; endpoint is POST-only |

Neither was rate-limited, so neither is inconclusive. Both checks held: the
response names the asked-for provider, returns at least one result, every result
has an http(s) URL and a title, at least one carries a snippet, and no result
carries `text` (both are SERP-shaped). `ocaml_live_tested` is now `true` for
exactly these two `Registry` rows, and `test/test_provider_registry.ml` pins that
set instead of the former all-untested assertion. The routing-set pins that
asserted the implicit default's dispatch was untested move with it: `freeserp` is
now the built, tested name there, and `search1api` is the only name left in the
five-way config's untested set. Every other name stays OCaml-untested: its
adapter, or its first recorded live run, is still to come.

The fetch and agent cases are ported and selectable but **not yet run live** —
`fetch:local` would dial the open web and the agent case needs an operator model
endpoint plus a model call. They remain OCaml-untested in
`Cases.recorded_non_provider_runs`.

*(Superseded for the fetch half: §38 records `fetch:local` and `fetch:metadata`
passing on 2026-11-14 and the arms those runs read. The agent cases have still
never run from this port.)*

Gate at landing: `dune build @install`, `dune runtest --force` (58 suites, the
harness's 19 hermetic cases included) and `dune build @doc` all exit 0. The two
live runs above are the only provider contacts made; no billed endpoint was
reached. The skip paths were exercised gated but offline for `serper` (no key,
and its build is deferred to F5.2), `exa` (F5.1), `fetch:jina` (F6.1) and
`searxng` (F5.2): each exits 0 with its reason named, as a missing configuration
must.
=======
## 24. F5.2 — the Serper, Scrappa and SearXNG adapters, and a differential area that dials them (2026-11-13)

Landed on `f5-2-serp`. Spec: `plans/ocaml-finalisation.md` §F5.2 and the F5 common
acceptance rows.

**Three adapters, three wire shapes.** `Seekwright_providers.Serper`
(`lib/providers/serper.ml{,i}`) is one `POST https://google.serper.dev/search`
with the JSON body the vendor names (`q`, `num`, `gl`, `hl`, `tbs`) and the key in
`X-API-KEY`; `Scrappa` is one `GET …/api/search-light` with `query`, `num`, `gl`,
`hl`, `dateRestrict`, `safe` and the key in `x-api-key`; `Searxng` is one `GET`
against `{instance}/search` with `format=json`, `pageno`, `time_range`,
`language`, `safesearch`, and no credential at all — an instance URL is not a
secret and never becomes a header. Domain filters ride `site:` in the query on all
three; the `ignored_constraints` sentence each files is the oracle's, and the
buckets differ by adapter rather than by house style: Serper drops safe-search,
SearXNG drops `country`, Scrappa drops nothing.

**The status classes are the adapter's, and each says what its own quota is.**
Serper folds `402` in with `429` (a credit pack and a spent balance are the same
failure to a caller, and both must reach the quota fallback); Scrappa folds in the
`402` that is its x402 payment challenge; **SearXNG keeps `402` out** — a 402 in
front of an instance URL is the reverse proxy sitting there, so it answers
`HTTP 402` as an ordinary retryable failure and reserves the quota class for `429`
("rate limited by the instance"). `401`/`403` are non-retryable everywhere; on
SearXNG the sentence names the instance's own cause, `authentication rejected
(enable \`format=json\` for this client)`. Transport failures go through
`Provider.transport_error`, whose own comment is the redaction rule: the grant's
message — which may name the peer, and in the oracle's tree echoed the request
that carried the key — is never copied.

**Pricing is arithmetic the row states.** `Registry.Cost_model` gains
`Credit_multiplier { over; multiplier }`, and Serper's row carries `over =
Serper.credit_over` (10) with `multiplier = 2`, so `Registry.cost_of` and
`Serper.cost_for` compute the same figure the Python adapter does: `(cost_per_1k
/. 1000.)` times 1 or 2 credits by `max_results`. `--check`'s expected spend for a
name that prices this way is therefore right before the name is dialled. Scrappa
is flat at 0.30 per thousand and its `num` is clamped to `max_num = 20` — the clamp
is a cost ceiling as much as a vendor limit, since the caller picks `max_results`.
SearXNG is 0.0, and its `cost_for` ignores the argument for the reason the freeserp
adapter gives: callers treat it as duck-typed.

**A row now carries the destination it was granted.** `Registry.args` gains
`endpoint : Uri.t`, filled by `Factory.adapter_of_row` with the URI it built the
grant from. That is SearXNG's whole requirement: the instance URL is config, the
grant is confined to it, and the adapter must dial the same value rather than
re-derive it — so `Searxng.search_uri` joins `search` onto the granted URI
(`rstrip_slashes` first, one trailing slash however the operator wrote it) and
never looks at a config key. `args.endpoint` is the same URI, not a re-parse, so
the destination in the request and the destination in the confinement cannot drift.

**A keyed row without its key refuses at build time.** `Registry.require_key`
raises `Invalid_argument` naming the row rather than handing an adapter `""`; the
oracle's `build_providers` refuses at the same point, and an adapter that dialled
with an empty credential would turn a configuration mistake into a billed 401.

**SearXNG's walk is the adapter's, and it is bounded.** `max_pages = 3`; the first
page is required and a later page that fails is dropped rather than destroying a
search that already returned hits; an empty page ends the walk; the accumulator is
built reversed (each page's records reversed, prepended) and sliced once at the
end, so its size comes from pages the instance chose, not from a count known up
front. Page size is the instance's to choose, so `max_results` is a number of asks
as much as a number of hits — which is why the timeout floor is 15s.
`providers.tsv` names `policy.provider_timeout_seconds` because its vocabulary is
closed; the floor itself is the row's `timeout_floor`, and `test_grant_timeouts.ml`
already pins how floors merge.

**Tests.** `test/test_serper.ml` (30 cases), `test/test_scrappa.ml` (28) and
`test/test_searxng.ml` (39) drive each adapter over a scripted `Provider.Net.t`:
the request is pinned as a method, a destination, a decoded query, header names,
and a canonical body; the verdict is pinned as a kind, a retryability and a
sentence. Every acceptance row in the spec has a case — request shape, credential
location, paging, clamping, recency mapped onto each vendor's own date parameter,
native vs folded filters, the ignored-constraint notice, zero results, malformed
JSON, the provider-specific quota classes, snippet caps with the uncapped figure,
and the cost arithmetic. `test/test_provider_contract.ml` now runs the shared table
over all five on-disk adapters; the two places the adapters legitimately differ
(the auth sentence, which statuses are quota) are fields on the record
(`auth_message`, `quota_statuses`) rather than rows dropped from the shared
table, so a deviation fails a case instead of quietly narrowing the sweep.
`test/test_provider.ml`'s sandbox pin goes from four adapter sources to seven with
an explicit per-file existence list. `test/test_provider_registry.ml` (21) moves
with the rows: the built half is now `anysearch`, `freeserp`, `scrappa`,
`searxng`, `serper` and the deferred half names twelve.

**A differential area that dials an adapter.** `provider` is the tenth corpus area
(`test/differential/projection.ml`, `ocaml-tools/oracle/projections.py`, 38 cases
under `corpus/provider/`), and unlike every area before it the case is an
adapter's whole answer: the projection hands the adapter a scripted peer, records
every request it dialled, and renders the verdict. The two trees percent-encode
differently, so the rendering keeps the claim and drops the spelling: the query is
decoded and sorted, the destination is printed without it, a POST body is
re-emitted through the canonical JSON rendering, header names are lowercased and
the credential's value becomes `sentinel` — the area pins the credential's
*location* and never the credential. Transport cases carry the probe key inside
the failure's own message, because what is under test is that none of it reaches
the caller. SearXNG's walk is cast with a `pages` table keyed by the `pageno` the
adapter chose to send, which pins a paging adapter without pinning a clock. All
38 goldens are `differential-golden`: no divergence had to be registered, so the
port's wire shape and failure vocabulary match the oracle's case for case. The
area is in the floor list (30), the stanza deps, and `behaviours.tsv`; the
`+` byte is kept out of query values on purpose — the two URL writers disagree
about whether it means a space, and the area is not about the renderer.

**Generator drift, fixed rather than propagated.** `ocaml-tools/oracle/gen_matrix.py`
had fallen behind the committed tables: regenerating it dropped the `text`
behaviour row and rewrote three `config-fields` rows (`fetch.allow_private_addresses`,
`logging.library_level`, `logging.access_log`) back to older wording. Those rows
are restored in the generator so `gen_matrix.py` is faithful, and only the three
`providers.tsv` rows and the adapter behaviour row change in the commit — the
three names move to `ported` with `unit(test_<name> scripted transport);
differential-golden(provider)`, and the adapter-parity row claims
`corpus/provider`, which is the check that ties a corpus area to a row.

**Gate at landing.** `dune build @install`, `dune runtest --force` and `dune build
@doc` all exit 0, and the three new `.mli` files build doc-clean. Nothing in this
change reached a provider endpoint: no live test ran, no key was read, and each
new row keeps `ocaml_live_tested = false` until the F4.3 runner records a run.

## 25. F8 — jsondoc/tabledoc totality and comment sweep (2026-11-13)

Landed on `f8-jsondoc`, the jsondoc slice of F8. `Jsondoc.dump_leaf` no longer
has an `assert false`: its domain is a local `leaf` variant (`Null`, `Bool`,
`Int`, `Intlit`, `Float`, `String`), and `render_json` destructures exactly those
six Yojson constructors, so the container cases are handled by the branches that
print headers and the leaf case cannot reach a failure arm.
`Extractor.describe_types` walks the label list with one recursive `phrase`
instead of `List.rev`/`List.tl`/`List.hd`; the phrase is byte-for-byte the old one
(`a, b and c`, `a and b`, `nothing`), so no golden moved. The `supported_types`
doc is on the value in `extractor.mli`, and the `json_types`/`table_types` docs
that had drifted onto `text_types`/`json_types` are back on their own
declarations. Two stale comments went with the change: the `dump_leaf` note that
said containers could never arrive, and the `classify` note that recounted a past
style-review edit rather than the constraint it protects.

`test/test_jsondoc.ml` gains a leaf-kind case (float repr and an out-of-range
integer that Yojson hands over as `Intlit`) and a source guard over `jsondoc.ml`,
`tabledoc.ml` and `extractor.ml` refusing `assert false`, `List.hd` and
`List.tl`. The three files are declared in the stanza's `deps`, so the guard reads
them from the dune sandbox. No differential golden changed. Gate at landing:
`dune build @install`, `dune runtest --force` (61 suites) and `dune build @doc`
all exit 0; nothing reached a provider endpoint.

## 26. F5.3 — the Tavily, TinyFish and Linkup adapters (2026-11-13)

Landed on `f5-3-content`. Spec: `plans/ocaml-finalisation.md` §F5.3 and the F5 common
acceptance rows.

**Three adapters, three wire shapes, two result fields.** `Seekwright_providers.Tavily`
(`lib/providers/tavily.ml{,i}`) is one `POST https://api.tavily.com/search` with the
body the vendor names (`query`, `max_results`, `include_answer: "basic"`,
`include_raw_content: false`, `search_depth: "basic"`, `time_range`,
`include_domains`/`exclude_domains` as JSON lists, `country`, `language`,
`safe_search`) and the key as `Authorization: Bearer`; it is a **content** backend, so
`content` lands in `Result.text` with `text_truncated`, `snippet` stays empty, and the
vendor's prose lands in `Provider.outcome.answer`. `Tinyfish` is one
`GET https://api.search.tinyfish.ai` with the key in the vendor's own `X-API-Key` and
every constraint on a native parameter — the two domain lists comma-joined into one
parameter each, `recency_minutes`, `location` upper-cased, `language` lower-cased — so
a fully constrained query draws no notice at all; there is no result-count parameter
upstream, which makes the slice in `parse` the only place `max_results` takes effect.
`Linkup` is one `POST https://api.linkup.so/v1/search`, and it is the only adapter in
the tree with **two payload shapes**: `sourcedAnswer` parses `sources[]` with its
`snippet` field and answers with prose, `searchResults` parses `results[]` with its
`content` field and answers with nothing. The two parses also differ in how they
spend the limit — the citation list slices the upstream list first, so a record that
fails to parse still costs a slot, while the results walk keeps going until `limit`
*usable* items arrive because image rows carry no text a response could use. That
asymmetry is the vendor's payload, and it is pinned rather than reconciled.

**The expensive knobs stay operator-configured.** Linkup's `depth` is a ~10× cost
cliff and `outputType` is the shape that buys the prose, so both are constructor
arguments the row reads from config (`~settings:["depth"; "output_type"]`) and neither
is ever a tool parameter. `Registry.linkup_output` maps `Config.output_kind` onto
`Linkup.output`, a total match: a widened config enum fails the build at that
function rather than reaching the adapter as an unclassified string. Tavily's
`search_depth` stays pinned at `basic` for the same reason.

**One reported figure has no counterpart, and it is recorded rather than invented.**
The oracle asks Tavily with `include_usage: true` and reads `usage.credits` back into
`Result._reported_cost_usd` so `--check --live` can diff the billed figure against the
estimate. `Provider.outcome` has no private channel to carry an actual-usage number —
`lib/engine.ml`'s note is the on-record statement of that gap — so the port keeps the
**ask** on the wire (the request body is byte-for-byte what the oracle sends, and the
differential area pins it) and does not invent a reader for the reply. Tavily's
`cost_for` therefore answers the flat estimate alone. Closing the gap means a channel
at the provider boundary, which is a surface decision for a plan, not an adapter
decision; it is the one behaviour in these three names that a golden does not equalise.

**A closed vendor enum, not a code.** Tavily's `country` is a closed set of lowercase
English names valid on the `general` topic, so `Tavily.country_param` carries the
vendor's own table (the two Congo codes share one entry, `uk` and `usa` are aliases
callers write and the enum does not list) and lets an already-valid name through
untouched. An unmappable code is not guessed at: the parameter is dropped and
`~geo:(country <> None)` makes the notice name `country` alone — the geo bucket answered
per call rather than per adapter, which is what a filter that works *only sometimes*
owes the caller.

**Each adapter owns its quota class.** Tavily folds `432` (monthly credits exhausted)
in with `429`; TinyFish folds `402` — "Search API access is required for your account"
is an account question, not a malformed request, so it moves the fallback walk like a
spent quota does; **Linkup keeps `402` out**, because its 402 belongs to a keyless x402
lane this adapter never enters — every request it makes is bearer-keyed — so a 402 that
reaches it is an unexpected status and stays on the `HTTP 402` row. Those three
differences are fields on the shared-contract record (`quota_statuses`), not rows
dropped from the sweep.

**A date is computed once, and the clock comes from outside.** Linkup's `fromDate` is
the only date an adapter in this tree derives (`now − {1,7,30,365}` days, rendered
`%Y-%m-%dT%H:%M:%SZ` by Hinnant's `civil_from_days`, no timezone library), so
`Linkup.make` takes `~now:(unit -> float)` and the registry hands it the same
`args.now` the row's grant was built with. TinyFish's `recency_minutes` and Tavily's
`time_range` are windows the endpoint measures, so they need no clock at all.

**Tests.** `test/test_tavily.ml` (42 cases), `test/test_tinyfish.ml` (30) and
`test/test_linkup.ml` (41) drive each adapter over a scripted `Provider.Net.t`, one
case per acceptance row in the spec: request shape, credential location, clamping,
recency (with the injected clock pinned), native versus folded filters, the
ignored-constraint notice, zero results, the adapter's own quota statuses, malformed
and non-object JSON, the text cap with `text_truncated`, the snippet cap with the
uncapped figure, and the cost arithmetic. `test/test_provider_contract.ml` runs the
shared table over all eight on-disk adapters. `test/test_provider_registry.ml` (21)
moves with the rows: the built half is now `anysearch`, `freeserp`, `linkup`,
`scrappa`, `searxng`, `serper`, `tavily` and `tinyfish`; the deferred half names nine.
`test/test_provider.ml`'s sandbox pin goes from seven adapter sources to ten.

**The provider area grows where content adapters need it.** 35 cases (60–70 tavily,
71–80 tinyfish, 81–94 linkup) join the 38 Serper/Scrappa/SearXNG ones, and the
projection gains three lines on both sides — `result text=`, `result text_truncated=`
and `answer=` — because without them a content adapter's whole answer was the part no
golden compared. Serper, Scrappa and SearXNG answer all three with `-`, so the change
costs nothing there and pins everything here. The same area also had a hole the bearer
adapters fell through: the header rendering replaced the probe key only when a header
held it alone, so `Authorization: Bearer <key>` echoed it. The rendering now replaces
the key wherever it appears in a value, and a bearer header lands as `Bearer sentinel` —
the location pinned, the credential not. Recency for Linkup is the one case where a
golden would otherwise record the day it was generated: a case that asks for a window
names the instant its clock reads as `now` (the fixed `1_700_000_000`), the OCaml
projection freezes its injected clock to it, and the oracle side rebinds
`linkup.datetime` inside `ocaml-tools/oracle/projections.py` — the read-only oracle tree
is not edited to become deterministic. All 73 goldens are `differential-golden`; no
divergence had to be registered, so the port's wire shape, both parse shapes and failure
vocabulary match the oracle case for case. `min_cases` for the area moves from 30 to 70,
and the `providers.tsv` rows for the three names move to `ported` with `unit(test_<name>
scripted transport); differential-golden(provider)`.

**Gate at landing.** Rebased onto `ocaml-port@ a382e7d`, which carries the
`live/cases.ml` `Credit_multiplier` arm and the live pin that reads the three new rows
as runnable — neither was edited here, both are `live/**` and outside this task's
ownership. `dune build @install`, `dune runtest --force` (64 suites) and
`dune build @doc` all exit 0. Nothing in this change reached a provider endpoint: no
live test ran, no key was read, and each new row keeps `ocaml_live_tested = false`.
## 27. F3.3 follow-up — the divergence list closed (2026-11-13)

Landed on `f8-divergences`, rebased onto `ocaml-port@1cda755`. §16 recorded eight
divergences for the module owners; this wave takes them in order, verifies each
against the Python oracle before touching the port, and closes everything the
ownership allows. Six of the eight are gone, one is closed down to a platform
limit, and one is recorded as unclosable under its own rule.

**What closed, and how the port now agrees.**

1. `Utf8` walks maximal subparts. `lead_width`/`next_index` claim the bytes one
   ill-formed subpart owns (Python's `utf-8`/`errors="replace"` rule), so
   `count`, `take` and `slices` agree on `\xe2abc`, overlong `\xc0\xaf` and the
   surrogate `\xed\xa0\x80`, and `of_string` emits exactly one U+FFFD per
   maximal subpart. `take`/`slices` keep returning raw-byte substrings — that is
   what the QCheck partition property pins — while `of_string` is the replacing
   decode.
2. `Utf8.splitlines` follows Python: a trailing break ends the last non-empty
   line, so `"a\n"` is one line, `"\n\n"` is two empties and `""` is none.
   `is_line_boundary` now includes lone CR, which is a Python boundary; the CSV
   reader takes its line structure from the same split, so a CRLF file keeps its
   CR only where the record's own terminator consumes it.
3. `Repr.py_repr` escapes the codepoints `str.isprintable()` calls false: a
   generated 28-range table over the `Cc Cf Cs Co Zl Zp Zs` categories of
   Unicode 16.0 (the oracle's `unicodedata`), minus U+0020. `\xNN`/`\uNNNN`/
   `\UNNNNNNNN` are chosen by codepoint width and printable non-ASCII is still
   left as bytes. Unassigned (`Cn`) codepoints are the one residual: escaping
   them needs the whole assignment map, so they pass through and the module
   comment says so.
4. `Tabledoc.read_records` saves the pending empty field at a record terminator,
   so `a,b,` is three columns with an empty third — Python's `csv`.
5. `Fetcher.window_text` implements Python's slice bounds: a negative index
   counts from the end and clamps at zero, a past-the-end one at the length, and
   the cut point uses floor division for `max_chars // 2` (OCaml's `/`
   truncates toward zero, which only differs for the negative cap the corpus
   reaches and the tool surface cannot).
6. `Config`'s TOML reader takes the three non-decimal integer bases and the
   `inf`/`nan` spellings. A lexical pass rewrites only those literals, tracking
   comments, the four string forms, headers and bracket/brace depth so a
   literal-looking run inside a string or key is never touched, and only where a
   value can begin; signed non-decimal and uppercase base markers are left for
   the parser to refuse, as TOML does. **The pass found a real bug while being
   pinned:** `int_of_string` wraps a hexadecimal/octal/binary literal modulo the
   int width instead of failing, so the documented "leave a too-wide value for
   the parser" rule was silently rewriting it — possibly to a negative number.
   `digits_value` now accumulates in `Int64` with an explicit `max_int` ceiling,
   so the widest literal this build holds decodes and one past it is left alone.
7. `Model` resolves a duplicate key last, which is what Python's `json.loads`
   keeps (it replaces the value under the key's first position), and its
   `req_int`/`opt_int`/`default_int` accept an `Intlit` that fits OCaml's int
   instead of reporting "expected an integer, got an integer"; one that does not
   fit reports `field %S is outside the integer range`.
8. `Fetcher.window_text` no longer raises on a negative offset or returns an
   empty window on a negative cap, so the corpus's function-level cases pin the
   same answers as `text[offset:offset+cap]`.

**What remains, and why.** Twelve named cases stay `explicit-divergence`, plus
the two systematic classes (38 wording cases and 41 extractor-default cases):

- `sanitize` 09/22/23: the oracle projection must decode bytes to `str` before
  its sanitizer runs, so an ill-formed byte reaches the escape pass as U+FFFD;
  the port is byte-faithful. The pass agrees wherever the walk does not touch.
- `fetch` 08/09: both trees refuse a bad port; the sentence quotes each
  implementation's own parser. The verdict is the contract.
- `config` 49: the documented example names `fetch.extractor = "trafilatura"`,
  which the port has not wrapped (the P6 backend gap).
- `config` 86/87 (2^62, 2^70) and `model` 06 (offset 2^70): platform limits. An
  OCaml `int` is 63 bits; `policy.max_snippet_chars` and `FetchRequest.offset`
  are read as `int` by the engine, the factory, the server and the projections,
  so closing these needs a big-integer representation across those modules.
- `model` 01/03: pydantic's lax mode coerces `"0.5"`/`"200"` to a number; the
  decoder refuses string-to-number coercion. Both verdicts pinned.
- `router` 08: `lib/router.ml` is stdlib-only and quotes a requested name with
  its own single-quote pass, so a non-printable codepoint reaches the
  projection's escape unescaped — one backslash where Python's `repr` plus
  `json.dumps` gives two. Same verdict, same sentence otherwise; closing it
  means giving the router a `repr`, which its stdlib-only rule forbids.

**Goldens.** 367 pinned: 276 `differential-golden` and 91 `explicit-divergence`
(41 extractor default, 38 wording, 12 named). The 16 cases that were pinned in
§16 as explicit divergences are now `differential-golden`: text 10/11/12/30/31/
32/33/43/44/47, fetch 43/44, tabledoc 17 and model 07. Config 89/93/94 now differ
only by the accepted extractor-default gap.

**Tests.** `test/test_text.ml` moves the splitlines/CR expectations and gains a
maximal-subpart count and round-trip case plus the repr escapes (`\xa0`,
`\u200b`, `\u3000`, an astral codepoint). `test/test_config.ml` gains a "toml
literals" group: the three bases, separators, the widest literal that fits, one
past it, the signed/uppercase/underscore refusals, bare `inf`/`nan`, and a
quoted/comment lookalike that must stay untouched. `test/test_model.ml` gains
duplicate-key last-wins and the fitting `Intlit` (including its range fault).
`test/differential/projection.ml`'s `window_case` drops the `Invalid_argument`
arm the old implementation needed; the function it projects no longer raises.

**Gate at landing.** `dune build @install`, `dune runtest --force` (64 suites)
and `dune build @doc` exit 0 under the opam+GMP environment. Nothing in the wave
reached a provider endpoint: no live test ran and no key was read.
=======

## 28. F5.4 — the Algolia adapter: a deployment the operator configures (2026-11-13)

Landed on `f5-4-algolia`. Spec: `plans/ocaml-finalisation.md` §F5.4 and the F5 common
acceptance rows.

**The destination is config, so the derivation lives in one function.** Every other
adapter in the tree dials a host the port knows; `Seekwright_providers.Algolia`
(`lib/providers/algolia.ml{,i}`) dials a host the *operator* names —
`https://{app_id}-dsn.algolia.net/1/indexes/{index}/query`, where the DSN host **is**
the deployment and the index is what gets searched. `Algolia.endpoint_of_deployment
~app_id ~index` is the one spelling of that derivation, and it is now read three ways:
`Registry.uri`'s `Algolia_index` arm calls it instead of assembling the host and path
itself (the hand-written `Provider.escape_path_segment` path is gone — the F4.1 rule is
that a row and its adapter may not hold two spellings of one destination), the grant is
confined to the URI that call returns, and the adapter dials that same URI as its
`~endpoint` argument rather than re-deriving it. The index name is percent-encoded
because it is a path segment: an unescaped slash there moves the `/query` segment to
another route, and the app id is host config, never a request value. Both credentials
ride their own headers — `x-algolia-application-id` names the deployment,
`x-algolia-api-key` authorises the index — and neither rides the URL: a key alone names
nothing in this API, which is the same reason this name is never an `algolia:free`.

**The parse is the adapter's whole shape, because the records are the operator's.**
`hits[]` holds schemaless JSON, so the mapping is common-name chains — title
`title`/`name`/`question` then the DocSearch `hierarchy.lvl0..lvl6` at the deepest
non-empty level, url `url`/`link`, snippet
`description`/`summary`/`excerpt`/`content`/`answer` — and a wrong type counts as absent
so the chain continues instead of failing the hit. `Algolia.scalar_text` is the oracle's
`_first_str`: string, int and float become text, a JSON `true` does not, because a
boolean is not the prose a field claims to be. An explicitly configured `*_attr` is used
**alone** — no chain, no hierarchy fallback — since an operator who names an attribute
has said what their records hold. A hit with no title or no url is dropped rather than
shipped as a result the caller cannot cite or follow, and the limit slices the upstream
list *before* anything is dropped, so a non-object record costs a slot.

**Two numbers, and one boundary neither tree reaches through the surface.** The float
coercion goes through Yojson's renderer, which writes `7.0` and `100.0` where Python's
`str()` writes the same, so the coercion is identical for the scalars this API returns;
the only risk in that reading is an exotic float spelling neither tree can be handed
through the tool surface. The other boundary is `hits` itself: a truthy non-list (`"hits":
5`) is a `TypeError` in the oracle and an empty result list here, which is how every
sibling adapter already treats a list field it cannot read. The corpus carries neither
case, so neither is pinned; both are stated here rather than left to be discovered.

**One name's quota pair, and the status that is not quota.** `401` and `403` are
authentication — 403 is Algolia's real answer for a bad Application-ID or key, and 401 is
the spelling a caller writes when it reads the vendor's status list, so both land on the
same row; the oracle's own suite parameterises only the quota pair, which is why the auth
row is pinned in the unit suite and the differential area instead. `402` joins `429` on the
quota row with the default `quota exhausted` sentence: `402` is `FeatureNotEnabled`, a
plan question like a spent rate limit, and it moves the fallback walk the way any quota
does. That is the opposite of the decision F5.3 recorded for `linkup`, which keeps 402
out because its 402 belongs to a lane that adapter never enters — the difference is a
`quota_statuses` field on the shared-contract record, not a row dropped from the sweep.
Cost is flat: `cost_for` ignores its argument because Algolia bills the request whatever
it returns, and the row's `default_cost` is the cheapest paid rate.

**The row was already wired; flipping it is the whole factory change.** `make_row
"algolia"` carried `App_id_and_key`, `requires:[Api_key; App_id; Index]`, the
`app_id`/`index`/`*_attr` settings list and the `Health.algolia_endpoint` probe from
F4.1, so `build` moves from `Deferred "F5.4"` to an `Adapter` builder that reads the
config entry and hands the adapter what it needs. `Registry.require_setting` joins
`require_key` for that: the row declares the prerequisite and `missing_prerequisite`
declines the name before the builder is asked, and an empty `app_id` would otherwise
build a request to a host the grant was never meant to allow. `live/cases.ml` and
`live/checks.ml` already carried the algolia steps and its `Billed` cost class; the only
`live/**` line that moves is the inventory pin, `F5.4` → `runnable`, which is exactly
what the registry now says. The row keeps `ocaml_live_tested = false`.

**Tests.** `test/test_algolia.ml` (25 cases) drives the adapter over a scripted
`Provider.Net.t`: the three chains and the hierarchy level, both drop cases, an
explicitly configured attr used alone, non-object records and the slice-before-filter
limit, numeric coercion through the whole chain, the POST body as one document
(`query` and `hitsPerPage`, and no invented `filters`/`facetFilters`/`numericFilters`/
`tagFilters`/`restrictSearchableAttributes` key — silence there would be a filter the
caller believes ran), both headers with the app id pinned in the host *and* the header,
the encoded index, the four-bucket notice, the 402/429 pair, 401, a transport failure
that must not echo the key, and the flat cost. `test/test_provider_contract.ml` runs the
shared table over nine adapters now, algolia's quota statuses being the shared
`[402; 429]`. `test/test_provider_registry.ml` moves the built half to nine names and
the deferred half to eight, and `test/test_provider.ml`'s sandbox pin goes from ten
adapter sources to eleven.

**The provider area gains its first config-derived destination.** 15 cases (95–109) join
the 73, and both projections build the adapter from the case's own `app_id` and `index`:
the OCaml half calls `Algolia.endpoint_of_deployment`, the oracle half lets its adapter
constructor build the string, so the golden compares two derivations rather than one
spelling twice. `97-algolia-encoded-index` is the case the derivation is really about —
`products/2026` must reach the wire as `products%2F2026` on both sides.
`104-algolia-non-string-fields` pins the type guards (a `7` title and a `1.5` url are
text, a list and a `true` are absent and the chain moves on), `107-algolia-shape-drift`
pins the slice, and `100-algolia-feature-not-enabled` sits beside `93-linkup-payment-lane`
so the corpus carries both readings of x402 rather than one. All 88 goldens are
`differential-golden`: no divergence had to be registered, so the request, the parse, the
notice and the failure vocabulary match the oracle case for case. `min_cases` for the
area moves from 70 to 85.

**The matrix says what the adapter now consumes.** `providers.tsv` puts algolia at
`ported` with `unit(test_algolia scripted transport); differential-golden(provider)`, and
the five config rows it reads — `providers.*.app_id`, `.index`, `.title_attr`,
`.url_attr`, `.snippet_attr` — move from `transitional` to `honoured`, naming the
consumer instead of a future wave; the three `*_attr` rows are widened to say they
configure the searxng **and** algolia parsers. The behaviour row becomes nine scripted
adapters, and the not-ported row names the other eight.

**Gate at landing.** Base `ocaml-port@ 5a85eaf`; nothing outside this task's ownership
was edited except the one live pin line named above. `dune build @install`, `dune
runtest --force` (65 suites) and `dune build @doc` all exit 0. Nothing in this change
reached a provider endpoint: no live test ran, no key was read, and the row keeps
`ocaml_live_tested = false`.

## 29. F5.5 — the last four adapters: Search1API, SerpAPI, Querit, DeepSeek (2026-11-13)

Landed on `f5-5-final4`. Spec: `plans/ocaml-finalisation.md` §F5.5 and the F5 common
acceptance rows. With this wave every one of the seventeen names has an adapter on
the port; the four still `Deferred "F5.1"` are the Exa/Parallel MCP pair and their
anonymous halves, not a gap in the REST adapters.

**Four adapters, three shapes already in the tree and one that is new.**
`Seekwright_providers.Search1api`, `Querit` and `Deepseek` (`lib/providers/*.ml{,i}`)
POST JSON with the key in a bearer header, the pattern F5.3 set with `tavily`;
`Seekwright_providers.Serpapi` is a GET SERP like `serper`, with one difference that
dominates its whole failure story.

- **SerpAPI: the URL itself is the secret.** Its documented shape rides the key in
  the query string (`api_key=…`), not a header — the only adapter in the tree that
  does, which is why its row's credential is `Key_in_query "api_key"` and its probe
  (`serpapi_probe`) carries the key as a parameter. Every failure sentence is a
  redaction case: the oracle's suite asserts no message can echo the request URL,
  and the port's `ProviderError.message` vocabulary ("request timed out", "network
  error", "authentication rejected (check API key)", "HTTP <n>") never interpolates
  it. All five constraint buckets have a documented parameter — `site:` operators
  folded into `q`, `gl`, `hl`, `tbs`, `safe` — so the notice stays `None` whatever
  the caller asked.
- **Querit: the container is the wire's, not a slip.** `results` is an *object* and
  the hits live under its `result` key; a `results` that drifts to a list — the
  intuitive reading of the name — is a missing container and answers empty, which
  the corpus now pins (`125-querit-shape-drift`). `count` is clamped to the free
  plan's 10 whatever `max_results` asks, and the country and language enums are
  crossed by *name*: `de` becomes `germany` for the geo include and `german` for
  the language include — an enum value the backend cannot express is noticed, not
  silently sent.
- **DeepSeek: the constraints ride the query itself.** No filter fields exist on
  this wire, so domains, language and the recency rung *fold* into the query text —
  `site:`/`-site:` terms, `lang:xx`, and `after:YYYY-MM-DD` as the computed date —
  and the fold is bounded by the backend's 128-**codepoint** ceiling, counted with
  `Text.Utf8.count`, not bytes and not OCaml's `String.length`. When the folded
  query fits, the filters are on and the notice names only `country` and safe
  search; when it does not, filters come off, the bare query goes out, and the
  notice names every dropped bucket — the adapter never sends a filter the backend
  would silently ignore. A 200 with an empty `results` array is documented as not
  billable, so `cost_usd` is a pinned zero there rather than the per-query figure,
  and `408` — its request-body read timeout — is a retryable failure with its own
  sentence, not a quota.
- **Search1API: native parameters, and two buckets it simply has no field for.**
  Domains, language (lowercased, not split) and `time_range` ride the POST body;
  `country` and safe-search have no wire form at all, so `ignored_constraints`
  names exactly those two — silence there would be a dropped filter.

**The rows were already wired; flipping them is the whole factory change.** The four
`make_row`s carried endpoints, credentials, prices and probes from F4.1, so `build`
moves from `Deferred "F5.5"` to `Adapter` builders reading the config entry —
`require_key` for all four (the free tiers are account quotas, and the key names
whose quota a search spends), and `deepseek` additionally takes `~text_chars` from
the policy and `~now` from the grant's clock, because its `after:` date moves with
every call. The serpapi probe keys the same GET the adapter sends. All four rows
keep `ocaml_live_tested = false`: these are four of Python's `UNTESTED_PROVIDERS`,
and a name leaves that status only through a live run recorded in the tree.

**Tests.** `test/test_search1api.ml` (29 cases), `test/test_serpapi.ml` (34),
`test/test_querit.ml` (36) and `test/test_deepseek.ml` (39) drive the adapters over
a scripted `Provider.Net.t` — parse and shape drift, the request bodies and query
parameters as documents, the credential's location (header *or* parameter), the
constraint notices, the failure vocabularies including the serpapi URL-redaction
cases and deepseek's 408, the caps with their `uncapped_chars` counts, and the
costs. The deepseek suite pins its clock to 2026-10-21 so the `after:` arithmetic
is asserted against constants. `test/test_provider_contract.ml` runs the shared
table over thirteen adapters now, all four with the `[402; 429]` quota pair;
`test/test_provider_registry.ml` moves the built half to thirteen and the deferred
half to the four F5.1 names; `test/test_provider.ml`'s sandbox pin goes from eleven
adapter sources to fifteen; `test/test_routing_sets.ml`'s five-way fixture now
builds `search1api` from a sentinel key in the environment and rests its
unsupported category on the still-unported `exa`.

**The provider area gains its second computed date, and its first query-string
credential.** 21 cases (110–130) join the 88: five per adapter plus
`120-serpapi-refused-dial`, whose transport message carries the probe key and the
caller sees only "network error". DeepSeek's `after:` is the second date an adapter
computes, so the oracle freezes `deepseek.datetime` the way it already freezes
`linkup`'s, and the corpus cases name the instant (`now: 1792540800`) — the golden
pins the arithmetic, not the day it was generated. `127-deepseek-recency` shows
`after:2026-10-14` in the request body; `128-deepseek-constraints` shows the full
fold with `site:` and `lang:en`. SerpAPI's cases are the first where the credential
rides the query line of the dial rendering. All 109 goldens are
`differential-golden`: nothing had to be registered in `DIVERGENCES`, so request,
parse, notice and failure vocabulary match the oracle case for case, and
`min_cases` for the area moves from 85 to 105. One pre-existing drift surfaced on
regeneration: `63-tavily-text-cap`'s corpus file was written before the generator
raised its fixture to 450 words, so the case had never actually crossed the text
cap; regenerating pins `text_truncated=true` and the 2249-character measurement it
was always meant to test.

**The matrix says what the adapters now consume.** `providers.tsv` puts the four at
`ported` with `unit(test_<name> scripted transport); differential-golden(provider)`,
and their `live_status` stays `untested-in-repo` — porting the adapter is not
evidence a live run passed. No `config-fields.tsv` row moves: none of the four
reads a provider key beyond the shared `cost_per_1k`. The live harness pins the
four names `runnable` beside their existing steps, in its own commit.

**Gate at landing.** Base `c354c9d` (the F5.4 live-pin commit); nothing outside
this task's ownership was edited except two blessed artefacts: the live pin line
named above, and `bin/check_unbuilt.expected`, whose `--check` golden the registry
flip moves — `search1api` leaves the `unsupported` line of that report (the name
is built now; the fixture has no key, so the build pass still dispatches nothing,
and the untested sentence beside it is unchanged), re-blessed with `dune promote`
rather than hand-edited. `dune build @install`, `dune runtest --force` (69 suites
plus the blessed diff rules) and `dune build @doc` all exit 0. Nothing in this
change reached a provider endpoint: no live test ran, no key was read, and the
rows keep `ocaml_live_tested = false`.


## 30. F5.1 — the Exa/Parallel pair: session-bearing rows, and the last four names built (2026-11-13)

Landed on `f5-1-mcp`. Spec: `plans/ocaml-finalisation.md` §F5.1 and the F5 common
acceptance rows. With this wave every one of the seventeen names dispatches: no row
carries `Deferred` anymore, and the constructor stays only so a later wave could
express one.

**A seam, not a widened protocol.** Four of the names dial a streamable-MCP endpoint,
which needs a session — an `initialize`/`notifications/initialized` exchange with an
`mcp-session-id` header — where the thirteen already in the tree are one-shot request/
response shapes. The seam is `Seekwright.Provider.session = { adapter; warmup }`:
the `S` protocol itself gains nothing (an MCP name implements exactly the `S` a REST
name does, and close stays `S.aclose`), and the registry's `build` is
`Adapter | Adapter_session | Deferred`, `Adapter_session` closing over
`args -> Provider.session`. `warmup` is the deferred handshake: building providers
still opens no socket — startup constructs grants and nothing else — and a readiness
proof for these names is an MCP handshake, which `--check`'s bodyless-GET probe
vocabulary cannot express. The factory's build record carries a `warmups` table
beside `probe_table`, and `build_providers` takes `?log` for the tiered adapter's
notices. Rows name adapter constants the way every row already does: `Exa.default_uri`,
`Parallel.endpoint`, `Parallel.mcp_uri`.

**Four builders, and a never-auth rule on both free halves.** `exa` is
`Exa.make_tiered`: the oracle's `TieredExaProvider` parity — two anonymous attempts
before the key, escalating on *any* free-leg error rather than only a classified
quota (the oracle's rate-limit sniff has never seen Exa's real wording), a
`free_cooldown_seconds` gap before the key is retried, and a `notice` whenever the
key was spent. `exa:free` is `Exa.make_mcp ~name:"exa:free"`, and `parallel:free` is
`Parallel.make_mcp` — neither reads a key even when the environment holds one, which
is pinned at the registry too (`Registry.key_for` answers `None` for both). `parallel`
rides REST `Parallel.make ~mode`, not the authenticated MCP: REST is the surface that
carries the filter fields, and `mode` is the preset that decides price.

**Pricing rides one rung with a zero short-circuit.** `exa`, `exa:free` and
`parallel:free` carry `Extra_results { first = 10; per_extra_1k = 1.0 }` — the
oracle's `ParallelMcpProvider` subclasses `ExaMcpProvider`, so its `cost_for` is
Exa's rung and the row models that rather than calling the name flat — and
`Registry.cost_of`'s `Extra_results` branch returns zero at `cost_per_1k = 0.0`,
mirroring `Exa.cost_for`'s zero-price guard: the free halves keep their class
without their price.

**The MCP client landed as its own commit first** (`providers: a narrow MCP client
for the Exa and Parallel adapters`): a JSON-RPC 2.0 session client riding
`Provider.Net.t` — `initialize` (reading the session header), the 202-answering
initialized notification, `tools/call`, and a `DELETE` only where a session actually
connected. Twenty cases in `test_mcp_client.ml`. One deviation from the oracle: the
oracle's `exa.retry` debug line is *not* ported — reconnect is the client's
responsibility, its event vocabulary is pinned in that suite, and a per-retry line
belongs to the client, not the ladder.

**Tests.** `test/test_exa.ml` (39 cases) and `test/test_parallel.ml` (35) drive the
adapters over a scripted MCP endpoint that answers the whole session lifecycle, and
over a fake `Provider.Net.t` for the REST half: parse and shape drift, the block
format becoming results, highlights joined verbatim into `text` with the ellipsis
riding the cap, the ladder's attempt order, cooldown and notices, caps with their
`uncapped_chars` counts, and the costs. Tier-dial assertions pin
`count ~meth:"tools/call" ~keyed:…` rather than counting key-bearing POSTs, because
the authed tier's own handshake and notification carry the credential too. The guard
suites move with the wave: `test_provider.ml` counts seventeen adapter sources in the
sandbox; `test_provider_contract.ml` drives fourteen REST-shaped modules — `exa` is
the one excluded, because its status rows are the shared client's and pinned there;
`test_provider_registry.ml` puts all seventeen rows on the built side with the four
new price and key pins. `test_routing_sets.ml` needed re-shaping rather than
name-swapping: with every row built, no real config can produce an `unsupported`
name, so the two cases that leant on one now use the file's hand-built-pair idiom —
the build pass's sorted-offenders postcondition has no real-world example left to
drive it, and the five-way fixture drops `serper` back out of a real build pass's
output, the exact shape an unbuilt row leaves behind.

**The provider area gains its first hosted-MCP name that *can* ride it — and three
that deliberately cannot.** `parallel` (REST) joins the corpus with ten cases
(140–149): basic, constraints, the `advanced` mode preset, a text cap, payment
required, warnings becoming a notice, a non-object document answering empty, auth
rejected, rate limited, and a year-long recency whose `today`-relative arithmetic is
pinned by a frozen clock in the oracle projection (`projections.py`) and the `~now`
the OCaml projection now takes. All 423 goldens regenerate matching — 10 new, none
registering in `DIVERGENCES` — and the area's floor moves 105→115. The three
MCP-session names are *not* corpus cases on purpose: the oracle's MCP SDK client
will not ride `httpx.MockTransport`, so no projection can dial it; their wire
behaviour is pinned by the unit suites, and `providers.tsv` says so in the
verification column rather than claiming a differential that does not run. All
seventeen matrix rows read `ported`; the two free rows carry `0.00` costs, not the
`-` an unbuilt row wore.

**Live.** `live/cases.ml` names all seventeen runnable now — the four new cases
search with a two-result query, and `exa`'s sentence adds the free-tier-first
expectation — with `live/test_live_cases.ml` pinning the set. All four rows keep
`ocaml_live_tested = false`: this wave dialed no provider endpoint and read no key,
and a name leaves that status only in a change that records its OCaml live run.

**Gate at landing.** Nothing outside the task's ownership moved except blessed
artefacts: `bin/check_unbuilt.expected` and `bin/smoke_notes.expected` (the `--check`
and smoke reports no longer list any unported name) and
`test/check_transitional.expected`, all re-blessed by `dune promote` rather than
hand-edited. `dune build @install`, `dune build @doc` (one benign odoc warning on an
`!Seekwright.Provider.ignored_constraints` reference in `exa.mli`) and
`dune runtest --force` all exit 0, 71 suites green, nothing left to promote.

**Follow-up for the health owner.** `lib/health.mli`'s `no_probe` and `run_probes`
docstrings still say there is "no [warmup] member for yet" — stale since this wave's
seam landed. The prose move is the health area's, not this wave's; recorded here so
it is not lost.

## 31. The factory split — one facade over six construction modules (2026-11-13)

Landed on `factory-split` as nine commits, one per move, gate green after each. The
design and the pin edits are `plans/factory-split-proposal.md`, which lands with this
section so the sequence is reviewable against the diff.

**The module map.** `lib/factory` now holds eight implementation modules where it
held two. `factory.ml` is a 73-line facade — ten `let` re-exports and the two record
aliases, nothing else. `provider_set.ml{,i}` carries the two records a build
reports in — `providers` and `set_report` — and is the only new module left public,
because `factory.mli` re-exports them with their field labels and a private module
named from a public signature leaves a dangling path (§11). `verdict.ml{,i}` carries
`classify`, `built_phrase` and `startup_verdict`; `grants.ml{,i}` carries the audit
field set, `audit_sink`, `grant_of_decision`, `grant_of_endpoint` and `probe_net`;
`providers_build.ml{,i}` carries `adapter`, `adapter_of_row` and `build_providers`;
`fetch_stack.ml{,i}` carries `build_extractor`, `readers`, `cap_of`, `error_of` and
`build_fetch_stack`; `app.ml{,i}` carries `agent_net` and `build_app`. Every moved
body is byte-identical — the only edits inside a span are the header `let` aliases
that let one module call another's moved value, so the diff is a move and reviewable
as one. `registry.ml` and `registry.mli` are untouched: the registry is data, and the
split deliberately left it where it was. `factory.mli` is unchanged apart from the two
equated aliases, so it remains the public contract; the ten values a caller names are
the same ten, and `lib/server.ml`, `lib/cli/`, `bin/` and the test suites needed no
call-site edit.

**The funnel pin is now a library total.** The audit guarantee was pinned per file
while there was one file, and a per-file count over seven would let the funnel
multiply quietly. `Test_support.factory_sources` reads `lib/factory` with
`Sys.readdir` as a `unit -> (string * string) list` — a function, not a top-level
value, so the suites that link `test_support` but have no factory do not read a
directory that may not be in their sandbox — and the three `test/dune` stanzas that
read the factory now declare `(glob_files ../lib/factory/*.ml)` and `*.mli` rather
than naming `factory.ml`. `test_caps_audit` counts `Authority.with_log` and
`Authority.Net.of_confinement` as totals over every implementation in the library,
and separately names `lib/factory/grants.ml` as the file that must hold each of them,
so the check is a total and a location. Its negative half — no other factory module,
and neither `lib/server.ml` nor `bin/main.ml`, constructs or wraps a grant — is the
same scan. The per-call-site `includes` needles name the file that owns the code they
describe, which is what turned each of steps 4–7 into a gate failure rather than a
silent re-pointing; `test_grant_timeouts` and `test_fetch_grant` moved their config-key
and web-variant needles to the new module in the same commit as the move. Two of these
pins were checked for non-vacuity by hand: a decoy naming the audit wrapper in
`verdict.ml` turns the funnel totals red (both halves), and a decoy naming
`Engine.Search.create` above the verdict call turns the source-order pin red.

**The seal, and what it does not do.** `(private_modules app fetch_stack grants
providers_build verdict)` keeps those five away from installed consumers and out of
odoc. It does not stop a stanza inside this workspace naming them through dune's
generated alias module, so the boundary that matters on the serving path is pinned by
source instead, and step 8 adds those two pins: `app.ml`'s verdict call sits before its
`Engine.Search.create` (the ordering every type still checks without), and
`lib/cli/cli_check.ml` and `lib/cli/cli_flags.ml` name neither `App.` nor `build_app`
while `bin/main.ml` names `Factory.build_app` — the diagnosis never reaches the module
that can build an engine, and the transport entry is the only door. The proposal's
draft of the second pin said `bin/main.ml` contains no `build_app`; it does, and it is
supposed to, so the pin asserts the call site exists rather than its absence.

**Gate at landing.** `dune build @install`, `dune runtest --force` (71 suites, all
green) and `dune build @doc` all exit 0, with the one pre-existing odoc warning in
`factory.mli`'s empty reference unchanged. Nothing reached a provider endpoint and no
key was read.

**Follow-ups, deliberately not folded in.** The eight
`test/differential/matrix/config-fields.tsv` rows that credit `factory/factory.ml`
still credit the facade for code that now lives in `grants.ml`, `fetch_stack.ml` and
`app.ml`; the matrix sandbox already globs `lib/factory/*.ml`, so the re-credit is a
data edit in the differential area, not a factory one, and the split left it alone.
Behaviour-preserving cleanups are separate commits for the same reason:
`grants.ml`'s `probe_net` writes the identical `Unavailable` net record twice, and
`fetch_stack.ml`'s `build_fetch_stack` is a nested `match … Some (Ok …)` ladder that
would flatten with an option-result bind. The stale `Factory.page_of` prose in
`lib/wire/page.mli` and `test/test_wire.ml` names a value this library has never
exported — a doc sweep for whoever owns `lib/wire`. A compiler-enforced funnel
(sealing `of_confinement` and `with_log` behind one audited constructor) is an
`mcp-caps` public-API decision with its own review; this split is the step toward it.
Relocating `readers` out of the factory stays blocked by dependency direction: it
would need both `seekwright` and `seekwright.fetch`.

## 32. F6.2 — an extraction corpus, a measured quality bar, and the PDF decision (2026-11-14)

**The corpus, and who owns it.** Thirty-two cases under `test/corpus_html/`:
twenty-five HTML and text pages over the families the fetch path actually meets —
ordinary articles, navigation-heavy documents, malformed markup (unclosed tags,
a stray `<`, misnested elements, an unterminated attribute, a two-thousand-deep
nesting), encodings (UTF-8 BOM, cp1252, an undeclared Latin-1 page, undecodable
bytes, an entity soup), multiscript Unicode, a JS shell, a form, a table, lists,
an SVG sprite, a 186810-byte generated page, a page with 120 copies of one promo
block — and seven PDFs, including a 261818-byte grinder whose pages each
reference one shared Form XObject. Every fixture is written by one OCaml program,
`ocaml-tools/extract_bench/gen_fixtures.ml`, and `gen_fixtures --check <dir>`
runs under `runtest`: a fixture that no longer matches its generator fails the
gate, so nothing in the corpus is scraped and nothing is hand-tuned. That is also
the licensing answer — the corpus is this project's own text, Apache-2.0, with no
third-party page in it.

**What "quality" is measured as, and where the bar lives.** Not exact-string
equality. Each case in `cases.json` carries the phrases its answer must hold
(`essential`), the furniture it must not (`boilerplate`), what to expect of the
title (`title_rule` is `exact`, `none` or `any`), the Unicode strings that must
survive, and the per-case bar: `bar_essential_min`, `bar_boiler_max`,
`bar_title_ok`, `bar_unicode_ok`, `bar_max_ms`. The metric definitions are in one
OCaml module, `ocaml-tools/extract_bench/extract_metrics.ml`, which is what the
gate runs (`test/corpus_html/dune` runs `bench.exe --check .` under `runtest`)
and what the operator's table runs, so a bar cannot mean two things. Needles are
searched over text and title together: both implementations keep a page's em dash
only in the title, and a body-only search would call that a loss. The bar is a
**regression floor, not an aspiration**: `derive_bars.py` rewrites the five bar
fields in `gen_fixtures.ml` from a measured run, in the shape
`tools/surface.py --write` has in the Python tree, so a bar only moves when an
operator re-runs the instrument and commits the new number. `bar_max_ms` is four
times the measured median over a 25 ms floor — a ceiling that catches a parser
that went quadratic or stalled, not a performance target. Current state: **32 of
32 cases meet their bar**.

**Three backends, one table.** `test/corpus_html/metrics.md` records the corpus
run against the port's `stdlib` backend and the oracle's two — totals:

| backend | answer | essential | boiler leaked | title ok | Unicode ok | codepoints | U+FFFD | median ms (total) |
|---|---|---|---|---|---|---|---|---|
| ocaml-stdlib | 24 text / 7 refusal | 84/89 | 34/35 | 31 | 32 | 221591 | 9 | 43.3 |
| python-stdlib | 24 text / 7 refusal | 79/89 | 18/35 | 31 | 29 | 221591 | 23 | 43.3 |
| trafilatura | 28 text / 2 refusal | 80/89 | 2/35 | 10 | 20 | 1910349 | 23 | 5374.6 |

The port holds the most of the page (84/89 essential phrases), refuses exactly
what the oracle's stdlib backend refuses (the seven PDFs), and takes 43 ms over
the corpus against the trafilatura backend's five and a half seconds. What
it pays for that is boilerplate: 34 of 35 needles leak, against the oracle's 18
and trafilatura's 2, because this backend removes the `skip_tags` elements and
nothing else — the chrome outside them survives, which is its documented
contract, and `shared-blocks` (120 copies of one promo block, 25744 codepoints)
is where that contract costs the most. trafilatura buys its 2/35 by cutting
harder: it answers 317 codepoints for that same page and loses the title on 22
of 32 cases, and it drops a Unicode string in 12 of the 32 where the port keeps
it. The table is generated (`metrics_table.py` reads the runners' JSON rows); the
runners are the only place the metrics are defined.

**The parity result, at the byte.** `test/corpus_html/parity/` holds two files of
the same shape: `port-stdlib.txt` and `oracle-stdlib.txt`, each a `Digest.to_hex`
of the text and the title and the `total_chars` for every case — the port's from
`digest_cases.exe --digest`, the oracle's from `py_digest.py` over the same
fixture bytes. **On 31 of 32 cases the two are identical**, which is a stronger
claim than the matrix's `partial` row suggested before this: the port's stdlib
backend and the oracle's stdlib backend return the same bytes, not merely the
same phrases. The one drift is `encoding-cp1252`, and the port is ahead of the
oracle there: it implements the cp1252 codec, so it answers 4/4 essential phrases
with one replacement character where the oracle's strict codec gives up on fifteen
bytes and answers 0/4. The port's own digests are a gate rule
(`digest_cases.exe --check-parity`): a bar is a floor on recall, so an edit that
trades one paragraph for another can still pass every bar, and the digest cannot.

**The timing finding, and the fix it earned.** The measurement said the cost is
not in the parser. On `huge_generated.html` (186810 bytes) the end-to-end extract
was 71 ms, of which `Extractor.decode` was 0.4 ms and `Extractor.normalise` alone
was 72.8 ms. The two whitespace passes in `Extractor.normalise` built a cons cell
per codepoint, then `Array.of_list (List.rev …)` per pass, plus an
`Array.to_list`/`@` per newline run. The fix does both passes in place on the
`Uchar` array: a whitespace pass only ever deletes a codepoint, so its write
index never passes its read index, and one array serves both passes and the
strip. Measured: 26.8 ms for `normalise`, 30.8 ms end to end (the table's
`huge-article` row), against python-stdlib's 17.0 ms and trafilatura's 170.8 ms —
the port is now 1.8x off the oracle's stdlib backend on the biggest page instead
of 3.9x, and the digests are unchanged, which is the whole point of a whitespace
rewrite. `test_fetch.ml`'s "plain text whitespace collapses" caught the first
attempt at it (a tab run wrote the tab instead of the space the oracle emits),
which is the suite doing its job. `lib/fetch/extractor.ml` is outside this task's
ownership list; the exception was asked for and granted on the strength of the
digest parity, and it is a separate commit.

**PDF: the decision is no reader, and the measurement behind it.** The port ships
no PDF type, so `fetch` refuses a PDF by media type before spending the body, and
the seven PDF fixtures carry `expect = "refusal"` precisely so that answer is
visible in the table rather than inferred. The candidate was the only PDF package
in the opam index, camlpdf 2.9 (`LGPL-2.1-or-later WITH
OCaml-LGPL-linking-exception`, one maintainer, `ocaml >= 4.10`, no other
dependency). It was evaluated out of the tree — no stanza, no switch-level change
to this repository's build, a probe in `/tmp` over the corpus's own PDFs. What it
showed:

- the parser is fast and small: 0.3–2.1 ms to read all seven, object counts
  between 1 and 15;
- text needs a walk that camlpdf does not provide: page contents through
  `Pdfops.parse_operators`, then `Op_Tf`/`Op_Tj`/`Op_TJ` resolved through
  `Pdftext.text_extractor_of_font`, then Form XObjects followed by hand. On the
  easy fixtures that walk is correct (`pdf_minimal` gives the sentence back in
  6.8 ms);
- on two of the six readable fixtures it is behind the oracle outright:
  `pdf_two_pages` raises `Unknown font type` where the oracle's stack gives 2/2
  essential phrases, and `pdf_xref_stream` answers **zero pages** — not a refusal,
  an empty page, which is the worst way to be wrong on this path;
- the shared-stream grinder behaves the way the oracle's PDF stack does: a naive
  walk expands one XObject referenced per page into 80030 operators and
  1720010 bytes of text in 380 ms, against pypdf-plus-trafilatura's 1720028
  codepoints in 4955–10403 ms. Both readers expand; neither bounds itself. The
  port's answer is 0 ms and a sentence;
- malformed input is refused honestly but noisily: `pdf_truncated` and
  `pdf_not_a_pdf` raise `Pdf.PDFError` after camlpdf prints its own repair
  narrative — "Attempting to reconstruct the malformed pdf channel… Read 6
  objects" — on stdout. That is a direct collision with this port's rule that
  stdout is the JSON-RPC channel on the stdio transport, and it is not a value
  this library lets a caller redirect.

So the cost is not the dependency's size — it pulls nothing else — it is that a
usable PDF backend is a content-stream walker on top of camlpdf plus a work
ceiling the extraction contract does not have, plus a stdout guard, plus an LGPL
linking-exception licence next to an Apache-2.0 tree, plus a container that has to
keep scanning clean at CRITICAL/HIGH with a new C-stub-bearing package in it
(camlpdf ships `libcamlpdf_stubs.a`). Against that, what this port would buy is a
backend that answers two fixtures worse than the oracle and one of them by
silently returning nothing. Recorded as an explicit divergence rather than a gap:
`test/differential/matrix/behaviours.tsv` carries a row for PDF page text with
`partial` and `explicit-divergence(the port refuses a PDF by media type, and the
reader decision with its measurements is in plans/seekwright-ocaml-port.md)`, and
the extraction row now names the corpus's bar and digest pins beside
`test_fetch.ml`. The re-entry condition, if anyone wants it: a reader with a
bounded-work API, or real traffic that shows PDF fetches matter, and then behind
a per-call work budget in the backend contract — not behind a naive walk.

**Also recorded, as divergences rather than defects.** The port is byte-identical
to the oracle's stdlib backend on 31 of 32 cases, so the extraction row's
`partial` status now rests on much narrower ground than it did: the cp1252 codec,
the PDF type set, and the trafilatura backend, which this port refuses outright.
`boiler` is where the port is measurably behind trafilatura and marginally behind
the oracle's stdlib backend (34/35 against 18/35); closing that is a content
decision about what the stdlib backend is allowed to remove, not a bug fix, and it
is left to a wave that has to choose between matching the oracle byte-for-byte and
matching trafilatura's cleanliness — the corpus is now the place where that
argument can be run with numbers.

**Gate at landing.** `dune build @install`, `dune runtest --force` and
`dune build @doc` all exit 0, with the two new `runtest` rules in
`test/corpus_html/dune` in the middle of it: 32/32 cases meet their bar, the
digest pin matches, and `gen_fixtures --check` proves the checked-in corpus is
still exactly what its generator writes. Both rules were checked for non-vacuity
by hand: a tampered line in `parity/port-stdlib.txt` fails the run, and a
hand-edited fixture fails the generator check. Nothing reached a provider
endpoint and no key was read; the benchmark's Python rows need the checkout's own
`.venv`, which is why they are an operator run and not a gate step.

**Follow-ups, deliberately not folded in.** `ocaml-tools/extract_bench/` is not
installed and not packaged, and no rule there imports the Python tree — the
oracle rows come from `.venv`, so the three-backend table cannot be a gate step.
`digest_cases.exe --phases` is the phase timer behind the `normalise` finding and
is worth keeping for the next time a fetch-path number moves. The corpus's
`note` field is prose a reader sees in `cases.json`; a per-case note in the table
would duplicate it. The whitespace collapse over bytes rather than codepoints is
a further 2x on the table for the price of re-deriving `total_chars` without
decoding, and was not taken: the `Uchar` array is what keeps the strip's
`Utf8.is_python_space` rule honest for the non-ASCII spaces Python's `strip`
removes.

## 33. F7 — the page cache, its written root, and the seam on the served path (2026-11-14)

**What landed.** `src/seekwright/pagecache.py`'s `DiskPageCache` is
`Seekwright_fetch.Page_cache` (`lib/fetch/page_cache.ml`), and a served
`fetch` reads through it whenever `fetch.cache_dir` names a directory. Four
pull requests: the filesystem API the cache needs; the cache itself; the seam
above it; and `--check` reporting what the directory holds.

**The entry format is the oracle's, with one clock moved.** One entry is a pair of
files in one directory, named by the hex SHA-256 of `provider`, a NUL byte and the
*i validated* URL — never a spelling of the URL, so nothing a model typed becomes a
path. The body file is the extraction; the sidecar carries the metadata the cache
reads back (the rung, the URL, the stored size, the retrieval instant and the
access clock). Per-entry and total ceilings, TTL, LRU eviction, orphan and corrupt
entries reading as misses, and the atomic temp-file-then-rename pair are ported case
for case, and the digests themselves are pinned against values computed from the
Python (`test_page_cache.ml`).

**The divergence, on record.** The oracle keeps the LRU order in the body file's
*atime* and touches it on a hit. This port keeps the access clock in the sidecar and
rewrites only the sidecar on a hit. It is not a shortcut: Eio's filesystem API has no
`utimes`, and on Linux `relatime` would not move the atime at cache timescales (it
updates at most once per mount interval, and a cache TTL is measured in minutes), so
the mount's atime cannot be the clock here. `stat`'s atime is still read, as the
fallback for an entry this process did not write. The case that pins the
divergence — and the one a reviewer should read before calling it a bug — is
`a_hit_touches_the_sidecar_not_the_body`: a hit leaves the body's inode and mtime
alone and moves `accessed`.

**The filesystem API extension stayed inside the capability layer.**
`Mcp_caps.Policy_fs.with_written_root` opens (and creates, mode `0o700`) a subtree
and confers, on top of the read grant's bounded reads, exactly the operations the
cache needs: `read_range` (the bounded range read, which is what lets a windowed
read stream instead of loading the body), `stat`, `atomic_write` (temp-then-rename
*inside* the subtree), and `unlink`. No native path operation escapes the subtree,
and the grant's byte and entry ceilings apply to writes as well as reads.
`Authority.Fs` re-exports them, and `test/test_authority_fs.ml` exercises each
against a real temporary directory.

**The grant is minted in the funnel, not at the call site.** The caps-audit guard
(`test/test_caps_audit.ml`, which counts text occurrences in `lib/factory/*.ml`
comments included) refused a second place that turns a confinement into an
authority, so `lib/factory/grants.ml` gained
`fs_grant_of_written_root ~sw ~parent ~mono_clock ~max_bytes ~max_entries ?audit dir`
— the one `Authority.with_log` site for a written root, with the same audit
decoration every other factory grant gets — and `fetch_stack.ml` calls that. The
guard's own file was not touched. The cache root's ceilings are
`max_read_bytes = max_write_bytes = max cache_max_entry_bytes 65_536` and
`max_entries = 10_000`: the per-entry ceiling is what the store enforces, and the
floor is the window chunk, so a grant can never refuse a read the cache's own
config asked for.

**The engine's seam is two questions, and only one site asks them.**
`Seekwright.Engine.Fetch.Cache` is `{ preflight; read }`, and `Engine.Fetch.create`
takes `?cache`. `read_page` in `lib/engine.ml` is the only place
that decides between a cached page and a dispatch, which is why the flag it returns
means *dispatch-free* rather than *cache involved*: the call that fills an entry is
journalled and priced as the dispatch it was, and every later read of that entry is
not. `preflight` is a field of the seam rather than a step the caller may skip,
because the guardrails have to answer before the directory does — with a warm entry
and without one alike. `fetch.ok` carries `cached` on every line, and a cached read
of a priced rung carries no `cost_usd`, whatever that rung charges, because the
journal's absence means "nothing was spent".

**Singleflight lives in the factory seam, not in the cache.** `cache_seam` in
`lib/factory/fetch_stack.ml` holds the per-key in-flight table, because what a
follower inherits is the leader's `Engine.Fetch.fetch_error` — a type
`Page_cache` has no business naming. The rules are the oracle's: the fill dispatches
uncapped at offset 0 so one entry answers every later window; a follower that finds
an entry is dispatch-free; a follower whose fill could not store (an over-cap page)
fetches its own window; a failed fill wakes every waiter with the one failure the
leader saw and stores nothing; the leader serves its own window out of the entry it
just wrote but is still reported as a dispatch.

**Window parity is one function, not a mirror.** The oracle's cache cuts a window
with its own `_cut` because `pagecache.py` may not import `fetcher`. This port
imports it: `get_window` streams a head of `offset + max_chars + 2` codepoints
through chunked `Authority.Fs.read_range` (64 KiB at a time) and hands it to
`Fetcher.window_text`, the same function a live read uses. So the parity sweep asks
the cached path and the live path for the same window instead of pinning a copy
against an original, and it includes a body far larger than the chunk — which is
where a chunked walk over a UTF-8 text goes wrong on its own, at a codepoint
split across a chunk boundary. That case is pinned too.

**`--check` measures the directory instead of restating the ceiling.**
`fetch.cache_dir` left the transitional list because it has a consumer now, and the
row answers with figures: `cache <dir> (256 MiB cap, ttl 300s)  3 entries, 1.2 KiB`
— the cap and the TTL configured, the entry count and the body bytes read off the
directory by `Factory.page_cache_stats`, which opens the same written root the
served process builds. That is also why an unopenable `cache_dir` is a problem row
(`UNAVAILABLE: <reason>`, counted) rather than a row of zeroes: the server refuses
to start on such a config, and a diagnosis that could not open the directory should
not print a comfortable answer. An unset `cache_dir` prints `cache off`. The
`check_transitional` golden was re-blessed for both halves, and its rule `rm -rf`s
the cache directory first so "0 entries, 0 B" is the answer rather than whatever an
earlier run left behind.

**Tests, and the negative pins that did not move.** `test_page_cache.ml` (18 cases)
is the entry format against a real grant and an injected clock, including the
concurrency race where a reader meets a writer and an eviction and must see a whole
entry or none; `test_fetch_cache.ml` (12 cases) is the seam on the served path —
one cold fill per key with the followers reported cached (three fibers, one
dispatch), the failed fill that wakes its waiters with the leader's failure and
stores nothing, the over-cap page that is served and stays uncached, the image page
that bypasses the store, the priced rung that is unbilled on a cached page, the
guardrail that answers a warm entry with the address refusal, and the directory this
process cannot create, which is a refusal at build time rather than a cache that
silently never fills. `test_cli_check.ml` gained three cases and re-pinned the transitional one, which now
says `cache_dir` is no longer inert.

No new negative-compilation pin was added. The two existing ones already seal the
write path this wave opened: `test/should_not_compile/raw_fs_write_needs_bounds.ml`
(a write through a grant whose ceiling the body would breach) with its expected
output, and the `write_under_root` half of `grant_path.ml` (a write at a path the
grant does not confer). A `cache_write_needs_grant` fixture would have re-asked one
of those two questions from the cache's side, and the cache has no path-building
code of its own to get wrong — it names entries by a digest.

**Gate at landing.** `dune build @install`, `dune runtest --force` (80 suites, all
`Test Successful`) and `dune build @doc` all exit 0. Nothing reached a provider
endpoint and no key was read: the pages in the served-path suite come from stub
fetchers, and the one case that needs an address refusal asks for a loopback IP
literal, which `Policy_net.vet_public_host` answers from the address rule with no
lookup. `test/differential/matrix/behaviours.tsv` moves the page-cache row from
`not-ported / pending-F7` to `ported`, with the LRU divergence named in its
verification column, and the four `fetch.cache_*` rows in `config-fields.tsv` move
from `transitional` to `honoured` with the consumer each now has.

## 34. F8 — the style and architecture leftovers, closed (2026-11-14)

Landed on `f8-rest`, the rest of `plans/ocaml-finalisation.md` §F8 after the
jsondoc slice (§25). Eight commits; no wire behaviour moved and no differential
golden changed.

**`surface.ml` by name, not by position.** The ten-int tuple `count_lines`
returns is a `counts` record with one field per counter, the config-key scan
returns a `record`-shaped `config_keys` record, the two stripping passes share
one `strip_trailing_blanks`, and the prefix/suffix tests are `String.starts_with`
/ `String.ends_with` rather than `String.sub` arithmetic. The record scanner's
layout assumptions (a header line starts at column 0, a record line never
does) are now written beside it rather than implied. The proof this is a
no-op is already in the tree and ran unchanged: the `surface.expected` golden
and the body-diff rule in `ocaml-tools/dune` both pass byte-identically.

**`usage.ml` grows by cons.** `samples_ms` is accumulated newest-first by
`fold_days` (its reads only sort and sum, so the order it builds in is free),
and the recent deque is stored newest-first with a `take_first` — `drop_first`
is gone, so the deque never rebuilds itself from the wrong end. The snapshot
emits `("recent", `List t.recent)` directly. Two existing pins are the proof:
`the_deque_is_bounded_and_newest_first` and the "both lines … newest first"
check.

**Arity-only parameters removed.** `Config.api_key` takes just the provider
name (no config table), `Factory.Registry.key_for` just the registry row, and
`Factory.Registry.missing_prerequisite` the row and its provider config — the
Python oracle's `api_key(self, …)` body never reads `self`, and nothing in the
tree passes a shared function type that would need these arities. `live/runner.ml`
and the two config/registry suites take the new calls mechanically; no
behaviour changes.

**Total pattern matches over position.** `validate_fetch_fallbacks` reads the
ladder's last rung with a `List.rev` match instead of `List.hd (List.rev …)` /
`List.nth`, and `Usage.remember_run` evicts with `_ :: older -> older` instead
of `List.tl t.recent_runs`. `Policy_net`'s vetted address arrives as
`address :: _`. An audit closed the rest of the partial-accessor bullet: the
remaining `List.hd`/`List.nth`/`List.tl` uses in
`extractors/stdlib.ml`, `agent.ml`, `usage.ml`'s percentile, `cli_metrics.ml`
and `extract_pool.ml` are each guarded by a length or index check beside them,
so they stay.

**One bind spelling.** `>>=` is gone from `lib/` and from the two caps test
suites; every module that chains Results binds `let ( let* ) = Result.bind` at
module level (a local shadow was promoted, and `policy_net`/`policy_fs` lost
their local bindings entirely). The convention is recorded in the OCaml skill.

**Argument labelling.** `Event.add_note ~key ~value`, `Jsondoc.select_paths
~text ~path ~max_chars`, `Extractor.select_passages ~text ~query ~max_chars`,
`Extractor.table_extraction ~text ~kind` and `Tabledoc.table_delimiter ~kind
~text` now carry labels, which caught one live hazard: `table_extraction` and
`table_delimiter` had their two `string` arguments in opposite orders, and
`extractors/stdlib.ml` passes them positionally at the seam. The readers record
in `Engine` already named its fields, so the eta-reduced wiring in
`factory/fetch_stack.ml` and the differential harness's call sites follow
without touching a golden; `test/differential/projection.ml` and
`test_differential_properties.ml` are updated as harness code only.

**Typed agent failures, pinned not parsed.** The typed `Agent_error` variants
landed with the lifecycle work; what F8 asked for was the proof no consumer
reads sentences. `test_p8_server.ml`'s `an_answer_failure_projects_the_typed_
failure` drives one failing model endpoint through all three consumers: REST
answers 502 with the failure's prose verbatim, MCP answers `isError` with the
same text, and the usage journal records class `AgentFailed` — each field
arrives by destructuring `Agent.failure_class` / `failure_message`, never by
matching on a sentence.

**Judged and left alone.** The duplicate `type name = string` aliases
(`config.mli`, `provider.mli`, `router.mli`) stay: `Router` imports nothing of
`Seekwright` — `test/router_dependencies.expected` pins that — so it cannot
re-use `Config.name`, and the aliases are three modules' claims about the same
plain string, not one type spelled twice. Small frozen config-sized `@ [x]`
lists (adapter param builders, the engine's ladder refs, the caps registry
fold) stay per §F8's own carve-out: their length is bounded by a config
ceiling, and reversing them would read worse.

**Gate at landing.** `dune build @install`, `dune runtest --force` and
`dune build @doc` exit 0 after every commit. Nothing reached a provider
endpoint.
=======
## 35. F9.1 — one version owner, coherent metadata, and a tested lock (2026-11-14)

**What landed.** `dune-project` now owns the release version (`0.1.1`, matching
the Python oracle) and the licence (`Apache-2.0`, matching `LICENSE`); the two
opam files are generated from it; `lib/version.ml` is generated from the same
field; the mcp-kit components are exact pins; the declared compiler floor is
the tested 5.3.0; and both `.opam.locked` files are committed. The metadata
suite is `test/test_metadata.ml`.

**One number, four readers, and one deliberate exception.** The chain is
`dune-project`'s `(version …)` → `lib/version.ml` (`package`, `user_agent`) →
`Config.default_user_agent`; → both generated opam files; → `version.txt`
(root `dune`, `@version`) for a release script or the F9.2 image label. No
other source spells the release: `lib/fetch/fetcher.ml` is outside F9.1's
ownership, so its default User-Agent stays a literal and the metadata suite
compares it with `Version.user_agent` rather than editing that layer.
`Version.mcp_server` stays `0.1.0` on purpose: the MCP `serverInfo` version is
protocol identity (the Python oracle lets FastMCP supply it, not
`__version__`), and `bin/smoke.expected` and the conformance transcripts pin
it. The suite asserts the two values differ, so a refactor cannot quietly
collapse them.

**The manifests say the same thing.** Project-level `authors`, `maintainers`,
`homepage` and `bug_reports` are declared once and generated into both files;
`opam lint` passes on each. The compiler floor moved from 5.1 to 5.3.0 because
5.3.0 is what CI builds and what this switch runs, and the tree is not tested
below it. Every mcp-kit component carries `= 0.2.0`; `mcp-caps` spells
`mcp-kit-cohttp-eio` as `(and (= 0.2.0) :with-test)` because dune 3.11 rejects
a constraint and a flag as separate atoms. `seekwright.opam`'s
`mcp-kit-cohttp-eio` moved from `>= 0.2.0` to `= 0.2.0` — the drift the task
named.

**The lock records a combination, not a platform.** `opam lock .` (opam 2.3.0,
repository `https://opam.ocaml.org`, snapshot stamp
`a5eaafdc34c654a11462c864b3a55621e68e9ae3`) produced both `.opam.locked`
files. From an empty switch both resolutions succeed: unlocked `--deps-only
--with-test --with-doc` asks for 104 installations and takes
`ocaml-base-compiler 5.4.1` (the newest compiler the floor allows), while
`--locked` asks for 102 and takes `ocaml-system 5.3.0` (the tested compiler).
The caveat is in `plans/infra-setup.md`: the lock was exported from this
host's `default` switch, so it names the system compiler and host depext
packages; a lock exported on CI would name `ocaml-base-compiler`. It is a
reproducible record of the tested combination, not a cross-platform build
plan, and it is refreshed by re-running `opam lock .` on the switch that was
tested.

**`opam install . --with-test` could not run, and that is pre-existing.** The
generated files build with `dune build -p <package> @runtest`, and `-p`
restricts the build to one package. The test stanzas in `bin/`,
`test/log_guard/`, `test/differential/`, `live/` and `ocaml-tools/` are not
package-attributed, so the filtered build fails with `No rule found for
bin/main.exe` and a `mcp-caps` library conflict between `_build/default` and
the installed switch. Repairing that means adding package/module attribution
across directories F9.1 does not own; it is recorded rather than papered over.
The equivalent verification was done: `opam reinstall . --working-dir
--with-doc -y` rebuilt and installed both packages at 0.1.1, and the installed
`seekwright` binary run from outside the checkout produced output identical to
`bin/smoke.expected` (serverInfo `0.1.0`, all three tools) and stderr identical
to `bin/smoke_notes.expected`. The smoke stops before any tool call, so no
provider was contacted and no key was read.

**mcp-kit provenance stays a recorded caveat.** The opam entry names Nomadic
Labs' `ocaml-mcp` and checks its `v0.2.0` archive (sha256
`43c8319a13be91e323ae952a71ab673533fb3295886029eed9d81e5828de5ef7`), while
the archive's own `dune-project` says "Epure Team" and
`github.com/epure-team/mcp-kit` (404). The `epure-team` organisation is real
and shares a maintainer with the Nomadic Labs entry, so this reads as two
homes for one maintainer rather than a substituted artifact; the checksum is
unchanged. Staying on `0.2.0` with the caveat in `plans/infra-setup.md`
satisfies F9.1, and an upgrade that widens the trust boundary still needs an
upstream answer.

**Tests.** `test/test_metadata.ml` has seven cases: the version is the same in
`dune-project`, `Version.package` and both manifests; the User-Agent derives
from the owner in `Version`, `Config` and `Fetcher`; the project URL agrees in
`dune-project`, `Version` and both manifests; the licence is Apache-2.0 and no
MIT declaration survives; the compiler floor and both mcp-kit pins agree while
the old 5.1 floor and moving transport floor are gone; the MCP identity stays
separate and matches `bin/smoke.expected`; and every embedded prompt plus the
dashboard is present and the dashboard is the served page. Every file the suite
reads is a declared `deps` entry, so a source pin in the dune sandbox cannot
read an undeclared tree. `test/router_dependencies.expected` was re-pinned for
the new `Version` module and the `Config`/`Server` edges to it.

**Gate at landing.** `dune build @install`, `dune runtest --force` (81 suites,
all `Test Successful`, including the metadata suite's seven cases) and
`dune build @doc` all exit 0. Nothing reached a provider endpoint; the
installed-binary check is the stdio smoke above, which stops at `tools/list`.

## 36. F9.2 — the OCaml image, its runtime contract, and the operator path (2026-11-14)

**What landed.** `Containerfile.ocaml` (a two-stage build on `alpine:3.22` in both
stages) and `Containerfile.ocaml.dockerignore`; a new CI job,
`.github/workflows/ocaml-image.yml`, that builds the image, scans it, and then
drives the running container; and the operator entry point — `README.ocaml.md`
plus `ocaml-docs/{divergences,configuration,container,egress,live-tests,privacy,testing}.md`.
No OCaml source, manifest or test changed: `Containerfile` (Python), `ci.yml` and
`publish.yml` are untouched, so both artifacts keep shipping through their own
lanes during the transition.

**The artifact, measured.** Build context 18.39 kB. `/usr/local/bin/seekwright`
is 16,539,864 bytes after `strip` (28,705,688 before): a stripped PIE, musl-
linked, `ldd` naming `libgmp.so.10` and musl and nothing else — `liburing` is
statically linked, which is why the runtime layer does not carry it. The image is
37,293,789 bytes unpacked (8.97 MB base + 1.7 MB apk + 16.6 MB binary layer) and
9,961,989 bytes as `docker save | gzip -1`. The runtime layer installs two
packages, `gmp` and `ca-certificates`, and 18 packages in total. `dune install`
runs with `--bindir=/opt/seekwright/bin` and only the one executable is copied
out: no `seekwright-live`, no sources, no suites, no compiler, no opam.

**Why Alpine in the builder, not a compiler image.** The artifact is musl-linked,
so a glibc builder produces a binary this runtime cannot `exec`; the stage
therefore builds its own 5.3.0 switch. That switch cannot take F9.1's lock as
committed, because the lock names `ocaml-system 5.3.0` — the host's distribution
compiler, the caveat §35 recorded. `Containerfile.ocaml` rewrites that one row to
`ocaml-base-compiler`, refuses if the row is not there to rewrite, then rewrites
it back and `cmp`s against the committed file: a lock that drifts, or a `sed` that
stops matching, fails the build instead of quietly freeing the resolver over 100
packages. The repository is pinned to the snapshot commit the locks were resolved
against (`opam repository set-url default https://opam.ocaml.org#a5eaafdc…`,
separate because opam 2.3.0's `init` takes no `--repo`), and `--no-depexts` skips
opam's system-package name matching in favour of the `conf-*` probes, which are
the stronger check. Two apk facts cost one full build each: Alpine spells the
shared-library package `gmp`, not `libgmp`; and `uring.2.15.1` needs
`linux-headers` under musl for `linux/swab.h`.

**Version labels have one owner and a guard.** The image's
`org.opencontainers.image.version` travels in as `--build-arg SEEKWRIGHT_VERSION`,
because a `LABEL` cannot read a dune file, and the build stage refuses an argument
that does not equal `dune-project`'s `(version …)` — §35's one-owner rule enforced
at build time rather than in review. `Version.mcp_server` (0.1.0) is deliberately
never the label: it is the MCP `serverInfo` identity. The CI job derives the same
value with the same `sed` the guard uses, so the two cannot disagree.

**Scan stance, and what it does not cover.** `trivy image --severity
CRITICAL,HIGH --ignore-unfixed=false` reports **0 findings** on this image
(trivy 0.76.2, alpine 3.22.8); across all severities there is one MEDIUM,
`zlib 1.3.2-r1` / `CVE-2026-4738`, whose fix version `1.4-r0` is newer than the
base tag carries. An image scan is the only scan that means anything here: trivy
has no parser for opam or for `*.opam.locked`, and an `fs` scan of this checkout
reads `test/conformance/package-lock.json` and `uv.lock` and reports no OCaml
package — at CRITICAL/HIGH it reports seven HIGH findings in the conformance
runner's npm fixtures. The dependency set's reproducibility control is therefore
the lock files plus the pinned snapshot, recorded as such in
`ocaml-docs/container.md` rather than dressed up as CVE coverage. *For whoever
owns `ci.yml`:* its `scan` job runs `trivy fs` over `.` at CRITICAL/HIGH with
`exit-code: 1`, and `test/conformance/package-lock.json` is tracked, so that job
will report those seven the next time `ci.yml` runs over this tree. F9.2 does not
edit it.

**The runtime contract, asserted against the shipped image.** Each of these ran on
this host against `seekwright-ocaml:dev` built from `254f122`, and each is a step
in the new job: `id -u`/`id -g` are 10001 with the group made explicitly (busybox
`adduser -S` alone would put the user in `nogroup`); `--help` is
`seekwright: unknown flag --help` at exit 2; stdio `initialize` + `tools/list`
returns serverInfo 0.1.0 and the three tools with the 17-name provider enum;
`GET /healthz` answers `{"status":"ok","providers":["exa:free","parallel:free",
"freeserp"],"default_provider":null,"uptime_s":N}`; `POST /api/v1/search` with
`provider: no-such-provider` answers 400 naming it and listing this build's names;
`docker stop` logs `INFO http.stopping grace_seconds=10.0` and exits 0;
`--read-only --tmpfs /tmp` starts and serves; and a mounted `/etc/seekwright`
config plus a `/var/lib/seekwright` volume passes `--check` and leaves the journal
file and the cache directory behind. Stdio under the image writes only the startup
line, and only to stderr.

**Two facts the container page had to learn from running it.** `--host 0.0.0.0` is
load-bearing *inside* the container: the default bind is loopback, so a server
started with a bare `--http` goes `healthy` — the `HEALTHCHECK` runs in the
container's own namespace — while every published-port request from the host is
refused. And the journal file exists at startup rather than at first append,
because `Usage.create` opens it to prove the mount is writable: with
`history_path` set and no writable mount the server refuses to boot
(`seekwright: not writable: /var/lib/seekwright/usage.jsonl (io)`, exit 1), and
`--check` reports the same shape for an uncreatable `[fetch] cache_dir`. A call
refused before dispatch — the 400 above — writes no journal line.

**Findings this task did not fix, because they are not F9.2's files.** `--check`
exits 1 on a keyless MCP-only deployment: `exa:free` and `parallel:free` print
`unsupported (no connectivity probe)`, and the run prints `1 of 3 enabled
providers ready`, even though the same config boots and serves; an operator who
gates a deploy on `--check` needs `freeserp` or a keyed name in the set. The two
stale disclosures §35-style recorded are still open — `lib/cli/cli_check.ml` prints
that no third-party fetch fallback is built while `lib/factory/fetch_stack.ml`
builds five, and `live/cases.ml` still marks those rows `Deferred "F6.1"`.

**Where the operator pages live, and why not under `docs/`.** `docs/` is the
read-only Python tree, and `tests/repo/test_docs_conventions.py` requires every
page under `docs/` to be linked from `docs/index.md`'s `## Documents` census — so a
`docs/ocaml/` subtree can only land by editing that census, which is outside F9.2's
ownership. The OCaml reference material therefore sits beside `ocaml-tools/` as
`ocaml-docs/`, linked from `README.ocaml.md`. Both gates are green with the new
files: `uv run pytest tests/repo` 113 passed (including the pinning guard for every
`uses:` line in `.github/workflows/*.yml`), and no line-number citation anywhere in
the new pages.

**Gate at landing.** `dune build @install`, `dune runtest --force` (81 suites, all
`Test Successful`, 2239 cases) and `dune build @doc` all exit 0 at `254f122`. The
image build and the container runs contacted no billed endpoint: the only network
calls were the keyless readiness probe `--check` makes, which sends no key, and
`--check --live` was never run. podman has still never built this file — its
`--ignorefile` and `--format docker` requirements are documented from the
Containerfile header, not verified here.

## 37. The three F9.2 follow-ups: `--check`'s exit code, the `scan` job's scope, and the stale `F6.1` rows (2026-11-14)

**What landed.** Three commits on `f9-followups`, the full OCaml gate green after
each one: `71905bd` (ci), `53034b0` (the probe accounting), `5a6fb2d` (the fetch
rows in the report and in the live inventory). Nothing outside `lib/cli/`, the two
fixture directories, `live/cases.ml{,i}`, its test, and `ci.yml` changed.

**`--check` on a keyless MCP-only deployment.** `exa:free` and `parallel:free` are
built here and have no bodyless-GET probe, so each row read
`unsupported (no connectivity probe)`, the run printed `no providers ready --
searches would fail until configured`, and the exit code was 1 — on a deployment
whose server starts and serves. A row now reads `no connectivity probe`, and a
built-but-unprobed name is neither counted ready nor counted as a problem: the
summary prints `probes      no connectivity probe on this port for: …` and says
where its readiness actually lives. `bin/check_unbuilt.expected` is re-pinned to
that shape with the rule's accepted exit code moved from 1 to 0, which is the
assertion: a keyless MCP-only config is not a fault in the config. The refusal
sentence still fires where a build or a probe actually failed, and two new pins
hold that half — `test/check_unreachable.*` (one probed name, found down: the
sentence prints, exit 1) and `test/check_probe_gap.*` (one unprobed built name and
one probed-and-down name together: both sentences, exit 1). Both dial only
`http://127.0.0.1:1/`, a loopback port nothing listens on, so a failing probe can be
a test without a public provider in the gate.

**The `scan` job's `fs` scan.** Measured here with trivy 0.76.2 against the current
DB: `uv.lock` reads 0 at CRITICAL/HIGH, `test/conformance/package-lock.json` reads
7 HIGH — all seven `Status: fixed`, so neither stance of `ignore-unfixed` hides
them, and the step's comment was asserting a flag it never passed. The job failed on
a lockfile that reaches no artifact (`uv_build` packages only `src/`,
`.containerignore` drops `tests/`). The failing `fs` step now passes
`skip-dirs: test/conformance` and spells `ignore-unfixed: "false"` as an argument,
and a second, report-only step scans that directory at `exit-code: "0"` so the seven
stay in the log; the job header names that step as the one exception to "the job
fails rather than reports". Locally: the scoped scan exits 0 with `uv.lock` still
read, the report-only step prints the seven and exits 0.
`uv run pytest tests/repo -q` is 113 passed with the change (the SHA-pin and
job-timeout guards included).

**The stale `F6.1` disclosures.** `lib/cli/cli_check.ml` had it twice: every fetch
row carried `unsupported on this port`, and one aggregated row counted a problem,
while `lib/factory/fetch_stack.ml` had been building all five registry rows since
F6.1. `fallback_state` now reads the registry row, the permission set and
`Config.providers_requiring_key` and answers the Python's vocabulary — `keyed`,
`keyless`, `self-hosted  <host>`, or one of the four `(inactive: …)` reasons — and a
`fetch.primary` counts a problem only when its state begins `(inactive:`, which is
the one case the server's startup verdict refuses on. `transitional_features`,
`print_transitional`, `unsupported_here` and `requested_fetch_routes` are gone: their
last entry was that ladder, and an empty mechanism for a table the plan refuses is
the table. `test/test_cli_check.ml`'s inert-features group is replaced by five route-
state cases — keyless primary built, keyed primary inert with and without the
environment's key, the permission set refusing `jina`, the self-hosted renderer
naming its host, disabled fetch — and `check_transitional` is re-pinned to the
honest rows with its accepted exit code at 0. Deliberately ported *not*: the
renderer `/health` probe the Python runs inside `_fallback_state`. `--check` dials
nobody's reader on the operator's behalf, so the row prints the configured host and
no probe, which is the same rule the probe accounting above applies to providers. In
`live/cases.ml` every fetch case is `Runnable`, and `live/test_live_cases.ml` now
fails if any fetch case is deferred.

**Follow-ups this wave leaves to other owners.**

- `ocaml-docs/configuration.md`, "`--check` dials, and `--check --live` bills": the
  row spelling, the `no providers ready` sentence and the exit code it quotes are all
  now wrong for the keyless MCP-only case, and "a transitional key" is no longer a
  counted category.
- `ocaml-docs/testing.md`: the "Transitional `--check` output" row names
  `test/check_transitional*.expected`, which no longer pins a transitional
  disclosure; the two new pins (`check_unreachable`, `check_probe_gap`) belong in
  that census too. The fixture keeps its name because `ocaml-docs/testing.md` and
  `test/differential/matrix/config-fields.tsv` both cite it.
- `test/differential/matrix/config-fields.tsv` still marks `fetch.fallback`,
  `fetch.cost_per_1k` and the three `fetch.crawl4ai_*` keys `transitional` with the
  F6 wave as their consumer; `Fetch_stack.build_fallback` and `Cli_check.fallback_state`
  are consumers today. `providers.*.url` looks dated on the same evidence — a
  `searxng` whose host is config is built and probed by `test/check_unreachable.toml`.
  Untouched: the matrix and its guard are not this wave's ownership.
- `live/runner.ml` and `live/checks.ml`: with those rows runnable, `Checks.verify_fetch`'s
  placeholder arm and the runner's `this fetch case has no ported assertion in the
  runner` failure are now the reachable path. That failure is the honest outcome —
  the harness refuses to invent a check — and closing it means one page-shape
  assertion per case, plus the arm comment that still says those cases are
  unreachable and the `--list` skip sentence "the fallback lands with wave %s".
- `live/README.md`, "Selectors": still says a fetch case skips with `F6.1`.
- `.containerignore` drops the Python tree's own non-context entries but not the
  OCaml fixture directories (`lib/`, `bin/`, `live/`, `test/`, `plans/`,
  `ocaml-docs/`, `*.opam*`, `dune*`), so the Python build context carries them. It
  changes no artifact; it does mean the 18.39 kB context F9.2 measured is not what
  that file's comment reads.

**Host note.** The global opam selection on this box moved to a new switch
(`f9-1-resolve`, empty at the time) mid-wave, which is what makes `dune: command not
found` and a `cannot find -lgmp` link failure look like source breakage. Every gate
run here therefore pins the switch per command — `eval "$(opam env --switch=default
--set-switch)"` with the `CPATH`/`LIBRARY_PATH`/`PKG_CONFIG_PATH` triple
`plans/infra-setup.md` records for the hand-placed `libgmp-dev` tree.

**Gate at landing.** `dune build @install`, `dune runtest --force` and
`dune build @doc` exit 0 at each of the three commits — 81 alcotest suites, 2239
cases, unchanged from §36 because the `test_cli_check` group was replaced rather than
grown — and the four `--check` pins run as `runtest` rules, not as alcotest suites.
No gate step contacted a public provider or a billed endpoint: the new pins dial a
closed loopback port, `--check --live` was never run, and `SEEKWRIGHT_LIVE_TESTS` was
never set.

## 38. F9.3 — the final verification, and what this port may be called (2026-11-14)

**Spec.** `plans/ocaml-finalisation.md` §F9.3. Work on `f9-3-final`, based on
`ocaml-port@cb122aa`. The instrument for the checklist is F0.1's matrix
(`test/differential/matrix/`), re-read at every `dune runtest` by
`test_differential_matrix.ml`; the checklist below is that matrix plus the gate,
read against the tree rather than against memory.

**Authorisations this task needed and got** (run mailbox, one ruling per question):
the six keyless live selectors; `npm ci --prefix test/conformance --ignore-scripts`
as a dev-tool fetch, with Node 22; and the stale spots outside the task's original
ownership — `live/README.md`, `live/cases.mli`, the `behaviours.tsv` row, then the
status flips and the hermetic fetch-arm pins too. No keyed or billed name was run.

### The checklist

| # | row | verdict |
|---|---|---|
| 1 | clean build / test / doc / install, no promotion | pass, with one load-sensitive flake named below |
| 2 | seventeen construction paths, five fallback paths, hermetically | pass |
| 3 | default stdio and HTTP start, three tools enumerate, keyless named search and loopback fetch over MCP, REST and CLI, no key in a fixture | pass, with two coverage gaps named |
| 4 | official conformance and both transport transcripts | pass, re-measured on this tree |
| 5 | keyless live tests; every other name named untested, no prose upgraded | pass for the six keyless cases; the rest stay named untested |
| 6 | SSRF, header/body/worker bounds, concurrency, cache restart and eviction, log sentinels, negative compilation, SIGTERM drain | pass |
| 7 | the OCI image installs, runs, scans, and carries no oracle, tests, credentials or build logs | pass on §36's evidence; its inputs are unchanged since |
| 8 | plan, capability docs, operator guide and README state the real guarantees and exclusions | pass, after the fixes listed below |

**1 — the gate.** `dune build @install && dune runtest --force && dune build
@doc`, each exit code read from dune itself: `INSTALL_EXIT=0`, `RUNTEST_EXIT=0`,
`DOC_EXIT=0`. 81 alcotest suites, 2244 cases, plus the pinned-rule diffs that are
not suites (`bin/smoke`, the four `--check` report pins, the CLI usage pins, the
corpus bench). The run quoted is at `aaa4678`, the last commit of this wave that
changes anything the gate reads; `5b783bb` — this section, prose only — re-runs
identically. No step contacted a provider: the only network in the gate is
loopback.

*One flake, reported rather than hidden.* The first baseline run on this host
failed `test/corpus_html`'s rule — `bench.exe --check .` reported
`huge-article: median 161.8ms over the ceiling of 148ms`, "1 of 32 corpus cases
miss their recorded bar". Three direct `bench.exe --check test/corpus_html`
re-runs and four later full gate runs report 32/32. The host has three CPUs and
was at load 4–5.8 during the failing run. The bar is a wall-clock ceiling, so it
is load-sensitive by construction; the case is not a parity failure and the bar
is not being moved here.

**2 — the construction and fallback paths.** `providers.tsv` carries seventeen
rows, all `ported`, and `test_provider_registry.ml` pins seventeen built `Registry`
rows and no deferred row. Each of the five fetch fallbacks has its own suite —
`test_fallback_crawl4ai.ml`, `test_fallback_jina.ml`, `test_fallback_scrappa.ml`,
`test_fallback_tavily.ml`, `test_fallback_linkup.ml` — and `test_fetch_ladder.ml`
pins `Fetch_stack.build_fetch_stack`'s ladder, its permission gating and the
round trip against a loopback renderer. `Cli_check.fallback_state` is what makes
the same five rows readable in `--check` (§37).

**3 — the surface as served.** `bin/smoke.expected` is a real subprocess of
`bin/main.exe` over stdio answering `initialize` and `tools/list`; the three tool
schemas enumerate there with the seventeen-name provider enum, and
`bin/smoke_notes.expected` pins that the startup notes never reach the protocol
channel. `test_boot.ml` boots the stock config through the real construction path.
Over loopback, `test_concurrency.ml`'s "search, fetch, answer and health ticks
share one record" runs the actual `Server.app` — config, factory grants, the three
engines, `Server.serve_connection` — with a second listener answering every
provider, page and model call, and asserts the `POST /api/v1/search|fetch|answer`
bodies, the usage aggregates and one journal line per terminal call. The REST
status table, `GET /healthz`, the dashboard routes and the host guard are
`test_p8_server.ml`; the client verbs are `test_cli_client.ml`, whose pinned route
per verb and status handling is checked against an injected transport. `--check`
dials only a closed loopback port, and the fixtures hold no key:
`live/test_live_cases.ml` asserts no sentinel secret reaches a printed line.

*Two gaps named rather than papered over.* `GET /healthz` is asserted at the
handler (`Server.handle_custom`) and in the container run §36 recorded, not from a
socket inside `dune runtest`; and no test starts a server and runs a CLI verb
against it. Either would be a small addition to `test/` — neither is F9.3's file
to add under this task's ownership.

**4 — conformance.** Re-run on this tree: `test/conformance/run_live_application.sh`
against `bin/main.exe --http` on a free loopback port, Node v22.23.4, the pinned
`@modelcontextprotocol/conformance` runner (0.2.0-alpha.11), scored fail-closed by
`compare_application.py` against `application-classification-2026-07-28-server.json`
— **90 applicable checks, 90 passed, 177 checks classified, gate=pass**. That is
§16's number re-measured, not carried. Hermetically, the same evidence rides as two
`runtest` transcript rules — the mcp-caps fixture over stdio
(`stdio_transcript.expected`) and the application over stdio
(`application_transcript.expected`, six `tools/call`s refused by validation or the
SSRF guard before a socket opens) — and `test_http_transport.ml`'s
"the same transcript answers the same way over stdio and HTTP" is the transfer
argument the runner's missing stdio mode forces this tree to supply.

**5 — live runs.** Six authorised keyless selectors, one per invocation, at
`4b6b443` (the only uncommitted delta at run time was prose in `live/README.md`
and `live/cases.mli` and a helper rename in `Checks`; the assertion bodies were
the committed ones in `573ffcc`). None was rate-limited, so none is inconclusive.

| date | case | commit | result |
|---|---|---|---|
| 2026-11-14 | `fetch:metadata` | `4b6b443` | passed, 3/3 — the metadata endpoint is refused before a request leaves; no endpoint dialed |
| 2026-11-14 | `fetch:local` | `4b6b443` | passed, 5/5 — keyless read and extraction of one public page |
| 2026-11-14 | `freeserp` | `4b6b443` | passed, 6/6 — keyless; second recorded run |
| 2026-11-14 | `anysearch` | `4b6b443` | passed, 6/6 — keyless; second recorded run |
| 2026-11-14 | `exa:free` | `4b6b443` | passed, 3/3 — keyless anonymous MCP endpoint |
| 2026-11-14 | `parallel:free` | `4b6b443` | passed, 3/3 — keyless anonymous MCP endpoint |

The status flips landed with the record, as the rule requires: `ocaml_live_tested`
is now true for the `exa:free` and `parallel:free` `Registry` rows, and
`Cases.recorded_non_provider_runs` names `fetch:local` and `fetch:metadata`.
`test_provider_registry.ml` and `test_routing_sets.ml` moved to the new sets, and
the three `--check` report pins that quoted the old `untested` line were
regenerated from the run rather than hand-edited. `test_live_cases.ml`'s
"live status agrees with the records" is what keeps the three sources from
drifting apart again.

Still unverified live, and still called that in prose: `fetch:scrappa`,
`fetch:tavily`, `fetch:linkup` (keyed), `fetch:jina` (keyless but not selected),
`agent:brief` and `agent:report` (an operator model endpoint is required), and
every keyed provider name. `ocaml-docs/divergences.md` and
`ocaml-docs/live-tests.md` say so in those words.

Closing the §37 follow-up in the same change: `Checks.verify_fetch` now has one
arm per fetch case, ported from the oracle live suite's own assertions, and the
runner dispatches a named fallback route (`fetch ~provider:<name>` with that name
alone in `fetch.fallback`) so no other vendor can serve the run, skipping a keyed
rung whose key is absent instead of calling a router refusal a failure. The
oracle's `path_addressable is False` assertion has no field to land on in
`Model.fetch_response` — the port carries it on the page record, and it is pinned
in `Seekwright_fetch.Fallback.windowed` and the engine's suite — so the live arm
asserts the half a caller can see, and the arm's comment says why.
`live/test_live_cases.ml` pins the five vendor arms and the metadata arm
hermetically, so an arm that never fires fails a suite instead of letting a live
case pass vacuously.

**6 — the boundary suites.** SSRF and the private-address opt-in:
`test_fetch_grant.ml`, plus the `fetch:metadata` refusal above. Request and
response ceilings: `test_http_head.ml`, including a real loopback connection and
an over-cap keep-alive head. The bounded extraction pool: `test_extract_pool.ml`
and `test_fetch_workers.ml`. Shared state under concurrent calls:
`test_concurrency.ml`, which also asserts no connection outlives the switch.
Cache format, ceilings, TTL and the served-path seam: `test_page_cache.ml` and
`test_fetch_cache.ml`. Log privacy: the two `test/log_guard/` suites
(`log-field-sets`, `log-source-discipline`) and `test_log.ml`. Negative
compilation: fourteen programs under `test/should_not_compile/`, each diffed
against its `.expected`. Drain: `test_drain.ml` (library level, both
`Drained` and `Grace_expired`) and `test_binary_drain.ml`, which sends a real
SIGTERM to `bin/main.exe` over a raw loopback socket and pins the 503 sentence,
the refused reconnect and exit 0.

**7 — the image.** §36's evidence stands: `git log` over `Containerfile.ocaml`,
`Containerfile.ocaml.dockerignore`, `dune-project` and both `*.opam*` locks shows
no change since `ccf6092` landed them, so the measured 16.5 MB stripped binary on
the 37 MB Alpine layer, the 0 CRITICAL/HIGH trivy result, and the container
contract run (`id` 10001, `--help` exit 2, stdio `tools/list`, `GET /healthz`, a
400 REST refusal, `docker stop` draining to exit 0, read-only rootfs, mounted
config and journal) all describe this tree. The image carries no oracle, tests,
suites, plans, docs or build logs: `Containerfile.ocaml.dockerignore` drops
`src/`, `tests/`, `tools/`, `docs/`, `test/`, `live/`, `ocaml-tools/`, `plans/`
and `ocaml-docs/`, and `dune install --bindir` copies one executable. Not
re-run here: an image build is an npm-free but registry-heavy network build, and
nothing this task changed reaches the artifact beyond `--check`'s `untested` line,
which §36's steps do not assert.

**8 — the documentation sweep.** What was wrong and is now fixed:
`ocaml-docs/configuration.md` quoted the pre-§37 probe sentence, the `no providers
ready` sentence and the wrong exit code, and its report excerpt quoted an
`untested` line that no longer prints for the keyless default; `ocaml-docs/testing.md`
's pin census named `test/check_transitional*` as a transitional disclosure and
omitted the two probe pins; `ocaml-docs/live-tests.md` still said the fetch rows
were `Deferred "F6.1"` and that no fetch case had run live;
`ocaml-docs/divergences.md` carried two stale disclosures (`cli_check` and
`live/cases.ml`) as open items and understated the live record; `live/README.md`
and `live/cases.mli` said a fetch case skips with wave `F6.1`;
`README.ocaml.md` called the port "not a drop-in replacement yet" with nothing
about what has since been verified. In the matrix, `config-fields.tsv`'s nine
`transitional` rows now name their real consumers (`Fetch_stack.build_fallback`,
`Cli_check.fallback_state`, the `Url_override`/`Url_required` registry endpoints,
`Exa.make_tiered`, the linkup and parallel request bodies) and are `honoured` —
no `transitional` row survives, because no key is read-and-ignored any more;
`behaviours.tsv` claimed "the other eight adapters" were `not-ported` while
`providers.tsv` carried seventeen `ported`, and the REST/CLI row pointed its port
column at pending work; `surface.tsv` had the three client verbs as
`not-ported`. All six corrections say what the tree does, and the matrix guard
re-reads them on every run.

### What this port may be called

**Production candidate**, with these exclusions disclosed prominently:

- **No PDF page text.** A fetched PDF is refused by media type. This is measured,
  not incidental: §32 records the corpus, the quality bar and why the `camlpdf`
  route was rejected. Any wording that implies PDF parity is wrong, and "full
  behavioural parity" is not this port's label while that exclusion stands.
- **The extraction backend is the port's own stdlib reader**, not `trafilatura`;
  §32's corpus bar is the quality evidence, and `[logging] library_level` and
  `[logging] access_log` are read and refused because there is no uvicorn here.
- **Live verification is partial by design on this host.** The keyless set —
  `exa:free`, `parallel:free`, `freeserp`, `anysearch` — and the two fetch cases
  above are the only names with a recorded run from this port; every keyed name
  and every keyed fetch fallback is announced untested by `--check`, by
  `ocaml-docs/live-tests.md` and by the harness's own `--list`.
- **No outbound proxy**, and `Policy_net` dials the registry row's endpoint
  directly (`ocaml-docs/egress.md`).

Under `plans/ocaml-finalisation.md` §F9.3, calling this a *limited production
release* is the maintainer's decision and requires carrying the PDF exclusion
with the label; a product release, push or tag is not in this task's scope and
nothing was pushed.

### Findings for other owners

- **An open CR to watch, not to merge.** `cr_f3e67d7f27e4` ("seekwright: fill the
  live fetch assertions") reports a 494-file diff that *deletes* the read-only
  Python oracle — `src/seekwright/**` (including `server.py` at 3385 lines),
  `tests/`, `docs/`, `tools/`, `pyproject.toml`, `uv.lock` — and touches protected
  paths (`.github/workflows/ocaml-tests.yml`, `AGENTS.md`, `Containerfile`,
  `README.md`, `examples/`). That payload does not describe this branch: at
  `aaa4678` the branch still tracks 47 files under `src/`, 72 under `tests/`, 20
  under `docs/` and 5 under `tools/`, which is what the differential corpus
  regeneration and the `tests/repo` guards read. The review thread's verdict was
  REJECT for protected-path scope with no recorded approval. The CR store was not
  readable from this session's tools, so it could not be answered in-thread; it
  is reported here and in the worker report instead.
- `.containerignore` (the Python image's) still lets the OCaml directories into
  that build's context, so §36's measured 18.39 kB context figure is not what that
  file's comment implies. No artifact changes either way; the file is the Python
  lane's.
- `GET /healthz` from a socket inside `dune runtest`, and a CLI verb run against a
  live loopback server, are both small additions `test/` does not yet have.
- `test/corpus_html`'s wall-clock bar is load-sensitive on a busy three-CPU host
  (the one flake above). If it keeps costing gate runs, the bar belongs in a
  machine-relative form, which is `test/corpus_html`'s owner's call.

## 39. The Python tree is deleted, and the lanes move with it (2026-11-16)

Executed on this branch: `src/`, `tests/`, `docs/`, `tools/`, `pyproject.toml`,
`uv.lock`, `.python-version`, the Python `Containerfile` and its
`.containerignore` are gone, along with `ci.yml` and the wheel half of
`publish.yml`. The order and the reason for each step are
`plans/retiring-the-python-tree.md`; this section is the entry in the port's own
narrative.

- **The gate did not change shape, only its inputs.** The same three targets, and
  the runtest case count moved by one: the accepted-divergence record is now the
  12-row `test/differential/divergences.tsv`, held to the 91
  `explicit-divergence` goldens in both directions (79 of them sit inside the two
  systematic families), which is the case that moved it. Everything the Python
  tree used to pin — the surface manifest, the five prompts, the dashboard page,
  the three egress host lists, the documented example and the two role tables, the
  matrix's cross-references — is pinned by an OCaml-side artifact now.
- **A deletion rehearsed before it was done.** With the seven Python paths hidden
  out of the tree, `dune build @install` and `dune runtest --force` were green and
  ran the same 2248 cases. That is why the deletion is a `git rm` and not a
  debugging session.
- **One posture change, not a cleanup.** `deploy/compose/` stopped enforcing
  anything at the network layer: this binary reads no `HTTP_PROXY`/`HTTPS_PROXY`,
  so the Squid pair, the CoreDNS resolver and the socat ingress were either broken
  or theatre. The two roles now sit on ordinary bridges with outbound NAT and
  publish their own loopback ports. The sink deny list and the lenient-vs-strict
  `fetch` choice moved to the operator's firewall, fed from the rendered
  `deploy/compose/generated/` lists, which `dune runtest` re-renders from
  `Registry.rows` and `known_fetch_fallbacks`. `SECURITY.md` states what the
  bundle no longer covers.
- **The claim about this port does not move.** §38's four exclusions still hold,
  including no PDF page text, and `production candidate` is still the honest
  label. Deleting the tree the baseline was taken from removes a kind of evidence,
  not a defect.
- **`VISION.md` moved with the tree, on the maintainer's word.** Its three `docs/` links
  and its `uv sync && uv run seekwright` first run are retargeted — mechanism to the
  module map, open work to `plans/`, the frozen surface to the printed golden, the first
  run to the built image — and its amendment log states plainly that no goal, precedence
  line or non-goal changed.
- §38's `cr_f3e67d7f27e4` finding is closed by this section: the payload that was
  rejected for touching protected paths without approval is, in substance, what
  this branch did deliberately, with the lanes moved first.

## 40. The 2026-11-16 code-quality wave, and what it settled (2026-11-17)

The owner's read of the tree filed R-001…R-011 in
`plans/reviews/code_review_ledger.md`; the plan page those entries pointed at,
`plans/code-quality-plan.md`, has now been removed, so this section is the wave's
record. The findings, their evidence and their dispositions stay in the ledger —
an entry is never deleted — and the argument behind each fix is in the commit that
landed it.

| Finding | Disposition | Commit |
|---|---|---|
| R-001 `Cli_serve`'s two wrappers around one `Server.serve_http` call; half refuted as filed — no `run_stdio` ever existed | landed, plus D3 | `71110c3` |
| R-002 quadratic append in `Caps.Registry.add` and `Server.of_registry` | landed | `b8e6704` |
| R-003 fetch-fallback prices spelled in the factory, not on the row | landed — `default_cost` moved onto `Config.fetch_fallback` | `a56ccab` |
| R-004 `Providers_build.go` rebuilt its accumulator per name, and shadowed the local reader's binder | landed | `d01a0ba` |
| R-005 `Fetch_stack.build_fallback`'s three arms re-derived the gates, the grant prologue and the floor | landed, step A only | `818a605` |
| R-006 the URL gate had three owners and one refusal sentence four spellings | landed — `Remote_target` owns validate → host → vet | `197a681` |
| R-007 the two post-`produce` arms of `Providers_build.go` were identical but for one cons | landed with R-004 | `d01a0ba` |
| R-008 `Extractors_stdlib`'s 274-pair `entity_table` scanned with `List.assoc_opt` | landed — keyed table, first-binding insertion, pinned byte-exact by `test/corpus_html` | `78f1f27` |
| R-009 civil-date arithmetic copied six times | landed — `seekwright.time` is the third stdlib-only floor, and the wave found a real defect on the way: the adapters' `days_since_epoch` floored a negative count with `Int64.succ` where `pred` belongs, so a pre-epoch instant named the wrong day; `test_linkup` pins the fix | `828bd1c` |
| R-010 `fallback_fixtures.ml` appended its request log while every consumer matched one element | landed | `9b61d9a` |
| R-011 quadratic field insertion in `Usage.ensure`/`set` | **declined, measured** — 13 alternating pairs against a worktree at `9b61d9a`, a 356,142-line journal over 370 days: lists 6.97 s mean, the `Hashtbl` variant 6.87 s, paired −92 ms with a standard error of 86 ms. Inside the run-to-run spread, so the rewrite was reverted and the cost rule stated instead | `6e4ad90` |

The three decisions taken while landing them:

- **D1 — fix the bounded appends (R-002, R-004, R-010). Yes.** Each is one small
  commit and each removes a shape a later reader has to reason about; none of the
  three was slow.
- **D2 — R-005 step B: defer, with the blocker named.** A per-name fallback
  builder table beside the row it describes is not expressible today: every
  `Fallback_*.config` carries a `'tag` parameter that exists only so
  `Remote_target.check` can reach `Policy_net.vet_public_host`, because an Eio flow
  record is parameterised by the backend's resource tag and cannot carry an
  existential. Erasing that tag — handing each fallback an injected guard built
  once by the factory — makes the vendor records tag-free and lets the table sit with
  the row. It was also expected to delete `fallback_fixtures.ml`'s scripted resolver,
  which exists because the fixture must answer a DNS lookup the guard performs; §41
  erased the tag and the resolver stayed, because five vendor suites assert that a
  private target is refused *and* that the vendor saw no request, which is evidence
  about the vet only while the vet is the real one.
- **D3 — stdio closes providers. Yes.** `run_stdio` now runs `close_providers` at
  EOF while the switch and env are still live, so a warmed remote MCP session gets
  its `DELETE`; the local adapters' `aclose` is `()`, so the call is cheap.

What the wave did **not** cover is the shape of the adapters and their suites: it
read four adapter files and the `Fallback_*` bodies only as far as R-005 needed,
and the ledger's coverage table says so. The structural pass that does cover them
is `plans/duplication-and-simplification-plan.md`.

## 41. The structural pass — what landed, and what it settled (2026-11-17)

`plans/duplication-and-simplification-plan.md` carries the measurements and the argument
per item; this section is the pass's history. Every step left `dune build @install`,
`dune runtest --force` and `dune build @doc` green, and no step promoted a golden except
where the row says so.

| Step | What moved | Commit |
|---|---|---|
| D-G — formatting | ocamlformat pinned at 0.29.0 in `dune-project` and the tree reformatted, before any structural edit, so a later diff shows the change and not the reflow | `eec2e7a` |
| S-005 | one percent-encoder and one codepoint walk on the `Provider`/`Seekwright_text` floor; `base64` moved next to the projection that prints it; `grouped` deleted; the `Seekwright_fetch.Utf8` re-export and its tautological case deleted | `f113f95` |
| S-001 | the adapter skeleton (`Provider.request`, the shared outcome tail) and `take`; thirteen adapters off their own copies, and `Provider.take` replaced the fifteen hand-rolled list takes | `dd699df`, `c49aa93` |
| S-002 | one adapter test harness (`adapter_support`) replacing the per-suite request-log and scripted-`Net` copies | `5b6abae` |
| S-003 | one dispatch per verb across the stdio tools, the REST projection and the CLI, and the answer-pin pre-check answered for both surfaces (Q-002) | `bdd300f` |
| S-004 | one key list per wire model; the tool schema reads the model's own list instead of re-typing it | `6a1fd9d` |
| S-006 | one answer-field vocabulary shared by the `answer.ok` log line and `Usage.answer_line`, so the two sinks cannot drift | `2c0cdd0` |
| S-007 | the civil-time residue after R-009: `Civil` owns the fraction-keeping clock split, and `Usage.iso_utc_full` / `iso_utc_seconds` are built on it; the two timestamp spellings are pinned to one instant | `4548740` |
| S-008 | the page cache holds one `Seekwright_wire.Page` record and one sidecar codec, replacing four copies of the page shape | `ff7cf44` |
| S-009 | `bin/main.ml`'s private cohttp-eio + TLS stack deleted: the client verbs dial through `Factory.grant_of_endpoint` over a `Policy_net.endpoint_of_uri` endpoint, with the response ceiling and the operation bound now grant properties | `b98a460` |
| S-010 | the `'tag` erased from every `Fallback_*.config` (D2 lifted): `Remote_target.make_check` is a value the factory builds once per rung, and `Fallback.status_rule` / `status_error` / `send` / `send_json` own the tail the five readers shared | `423ee5b` |
| D-A | `test/differential/drive.exe` and `ocaml-tools/oracle/README.md` deleted; the corpus claim renamed to "does this behaviour still hold"; `AGENTS.md`, `ocaml-docs/testing.md` and `test/differential/README.md` corrected to `test/differential/divergences.tsv` and the freeze | this change |
| D-B — the parity matrix | `matrix/providers.tsv` and `matrix/config-fields.tsv` deleted with the validator's arms for them — `check_provider_names`, `closed_columns`, `check_closed` — the provider row set's only other consumer; the matrix keeps the behaviour and surface evidence pointers, the refused-key fact the config table carried is pinned by `ocaml-docs/configuration.md` and `test_config.ml`, and `Factory.Registry`'s `context_cap` / `context` / six `~context:` rows go with the table that read them | this change |
| §3 — `Registry.row`'s `settings` index | the field, its eight row arguments and the cases that policed the index are gone; "which names take a `url`" is resolved from the rows' endpoints, with and without an override, instead of asserted from the list, and the per-provider key vocabulary stays where `surface.ml` derives it from `lib/config.ml` | this change |
| §3 — the stdlib backend's own library | `seekwright.fetch.stdlib` is gone: the backend is `lib/fetch/extract_stdlib.ml` inside `seekwright.fetch`, its stanza and public name deleted, twelve `(libraries …)` entries and seven consumers renamed, and the two `behaviours.tsv` pointers, the module map (which still listed a `lib/fetch/utf8` that S-005 removed) and the skill's layout line corrected in the same commit | this change |
| §3 — the extractor's double representation | `Extractor.S` and `Extractor.of_module` are gone: `extract_stdlib` exports the one `backend` record the fetcher holds, and the union `Extractor.supported_types` goes with them — the derived-phrase case spells the families it renders, and the pool suite's fake backends claim the family they actually read | this change |
| D-G follow-through — the gate runs the formatter | `dune build @fmt` is clean over the tree — ocamlformat over the three sources it still disagreed with, dune's own formatter over every stanza — and `ci-ocaml.yml` runs it as the first step; `AGENTS.md`, `CONTRIBUTING.md`, `ocaml-docs/testing.md` and the `ocaml` skill now describe a four-target gate | this change |
| §3 — adapter interfaces, first cut | the six `request_body` vals are gone from `lib/providers/`: no suite, tool or live case called a request builder, and the body a keyed name would send is pinned where it is already pinned — the scripted `Provider.Net` capture | `fd66405` |
| §3 — the derived endpoint grant | twelve `policy_endpoint` vals are gone, with the 34 host/scheme/port assertions that restated them; each adapter suite keeps its endpoint literal and the "the adapter dials that host" check, now taken against its own `endpoint`, because the row→adapter→grant chain is pinned once in `test_provider_registry`'s `the_grant_is_the_endpoint_read_once` and `a_fixed_endpoint_is_the_adapters_own` | this change |
| D-F's safe half — the constraint sentence | Parallel's REST-half notices go through `Provider.ignored_constraints`, which gained the mandatory `~drops_exclude_domains` bucket every adapter answers; the adapter's private sentence is gone and the differential case that pinned it is now a registered divergence | this change |
| §3 — the price has one owner | the price is a function the row hands over: `Registry.price row pc : int -> float` reaches every adapter as `make ~cost_for` through `Registry.args`, `Provider.S` loses `cost_per_1k` and `cost_for`, and the fifteen adapters lose their own arithmetic and their `?(cost_per_1k = …)` defaults — `Serper.credit_over`, Exa's extra-results rung and Parallel's credit reading go with them. `--check` prints `Registry.rate`; `--check --live` and the caller's `cost_usd` read `price`, one reading of the same entry. The differential provider projection links `seekwright.factory` and builds each adapter with its row's `price`, exactly as the factory injects it, so a golden's `cost_usd` is the row's figure and no golden moved; the one corpus case that carries a stub `cost` key leaves it unread, because a stub has no price to report and its golden already printed `cost_usd= -`. `cost_of` is exported only so the registry suite can pin a row's published shape against a figure. 66 files, net −361 lines | this change |
| D-C — the operation-budget seam | `Budget`, `Authority.with_operation_budget` and the `budget` field of the bounds record go, and with them `test_caps_budget.ml` (431 lines), the two budget rows in `test_authority_net.ml`, `test_caps_audit`'s needle case that counted mentions of the decorator, `--max-calls` on `examples/gated_search.ml`, and `budget.cmi` in the interface-mirror rule the negative fixtures compile against. `grant_path.ml` still compiles without it, which is the proof the seal never needed the seam; `controls_record_forge.ml`'s diagnostic re-promotes over a record one field shorter. `lib/caps/README.md` now states that the layer enforces no operation ceiling, and the capability plan's §6 carries the reason and the condition for a counter coming back | this change |
| D-D — the extraction pool | measured, not moved. An inline-vs-pool A/B over the frozen corpus on this host (medians of seven alternating runs per case, seven sweeps) puts the socket hop at +0.06…+0.24 ms on a ≤ 5 KB page and inside run-to-run noise on the two big fixtures, while the loop starvation it prevents is two orders of magnitude: with eight 187 KB parses running inline, a probe fiber asking the Eio loop for 50 ms is not even scheduled for 259–323 ms; pooled, for 0.0–0.4 ms. The `Domain` plus admission-semaphore rewrite could recover only the socket hop and would re-home the `Timed_out` rendering, the bounded queue's named refusal and the result ceiling, so it is declined and `Extract_pool` stands as written | no code change |
| D-E — the scalar coercion grammar | `Config`'s Python numeric-coercion grammar is deleted: `trim`, `drop_separators`, `int_from_string`, `float_from_string`, `bool_words`, `bool_from_string`, `bool_from_number` (net −101 in `lib/config.ml`). A TOML scalar is read at its own type, with one widening — an integer for a float, or a fractionless float for an integer, because TOML spells one number two ways. `test_config.ml`'s new "the scalar types" group pins the refusals by name; seven `explicit-divergence` config goldens re-pin to the refusal sentence, and `94-float-inf` goes the other way: its `inf` is *bare*, the port reads it, so it returns to the extractor-only registration and loses its `divergences.tsv` row. The literal-rewrite pass could not survive the cut untouched — it turned TOML's `inf` and `nan` into quoted strings precisely so the deleted readers could turn them back into numbers. Measured against `toml` 7.1.0: the lexer rejects `inf`, `+inf`, `-inf`, `nan` and `NaN` outright, and `1e1000` parses to `inf`. So an infinity is rewritten to `±1e1000`, the same value through the lexer's own float grammar, while a bare `nan` is refused naming the key — no bound in this file can be satisfied by a NaN. `ocaml-docs/configuration.md` states the rule for operators, `ocaml-docs/divergences.md` gains the section, `matrix/behaviours.tsv`'s config row names the divergence kind, and the `ocaml` skill's TOML line records what pydantic used to take | this change |

Two corrections to the plan's own predictions, recorded where they were wrong rather
than left for a reader to find: D2's resolver (above, in §40), and S-010's line-count
claim — the five readers lost 19 lines while `fallback.ml` gained 31, so the gain is the
single owner of the status reading, not a smaller tree.

Still open on this pass: the last contested §3 weight row (the `Factory` façade).
D-D closed without a change: the A/B it asked for was run and is recorded in §4 of
the structural plan, and the numbers decline the rewrite. D-E closed by deleting the
grammar: what remains of the difference is an operator-facing rule in
`ocaml-docs/configuration.md`, a section in `ocaml-docs/divergences.md` and seven
registered config divergences, not a compatibility layer. The `context` row closed
with D-B rather than on its own: its one reader was the `providers.tsv` row the
validator cross-checked, so `context_cap`, the field and the six `~context:` rows
went with the table that consumed them.

One design point was settled rather than changed. `Exa.make_tiered` keeps its own
cooldown clock, deliberately: its escalation happens inside one in-flight call — the
free half has already been dialled and the keyed half is tried before the caller sees an
error — while `Health`'s breaker and `Router`'s free walk decide which name a *later*
call starts with. Folding the two would make a billed retry depend on breaker state the
failing call has no way to read. What did move is the constraint vocabulary:
`Provider.ignored_constraints` gained the mandatory `~drops_exclude_domains` bucket,
every adapter answers it, and the one sentence Parallel used to own went with it —
model-facing, so `provider/141-parallel-constraints` is now a registered divergence
with its reason in `test/differential/divergences.tsv`.
