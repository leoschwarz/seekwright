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
