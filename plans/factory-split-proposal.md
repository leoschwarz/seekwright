# Proposal: splitting `lib/factory/factory.ml`

Status: design only. No repository file was modified, no commit was made.
Branch: `ocaml-port` (HEAD `a7f868a`, F5.2 landed, F5.3/F5.4/F5.5 outstanding).
Reviewed and corrected against the tree on 2026-11-13; the body is the executable
version, and §6 records the corrections and the deferred follow-ups.

Inputs read: `lib/factory/factory.ml` (556 lines), `lib/factory/registry.ml` (446),
`factory.mli` (235), `registry.mli` (242), `lib/factory/dune`, the four callers
(`bin/`, `lib/cli/`, `test/`, `live/`), `plans/seekwright-ocaml-port.md` §11, §13,
§22, §25, and `plans/ocaml-finalisation.md` F1.1, F1.2, F4.1, F8.

Measured surface: **123 `Factory.` occurrences in 16 files** — `bin/main.ml`,
`lib/cli/cli_check.ml`, `lib/cli/cli_check.mli`, `lib/cli/cli_flags.ml`,
`lib/server.mli`, `lib/wire/page.mli`, `test/test_boot.ml`,
`test/test_routing_sets.ml`, `test/test_provider_registry.ml`,
`test/test_caps_audit.ml`, `test/test_concurrency.ml`,
`test/test_grant_timeouts.ml`, `test/test_fetch_grant.ml`, `test/test_wire.ml`,
`live/runner.ml`, `live/runner.mli`.

---

## 1. Why the factory exists, and which of its constraints are load-bearing

Three constraints are real. Everything else about the file's present shape is
incidental.

### 1.1 The dependency direction (load-bearing, structural)

`lib/factory/dune` is its own library, `seekwright.factory`, because the adapters
live in `seekwright.providers` which depends on `seekwright`; a factory *inside*
`seekwright` could not name `Serper.make` without closing a cycle (the P4 note in
`lib/factory/dune`). This is a compile-time fact, not a convention: it is what
makes `lib/factory` a legal consumer of both the adapters and the wire types.
**Nothing in the split may move a definition into `lib/` proper, and
`lib/factory/dune`'s `(libraries …)` list must not change.** The split is a
re-arrangement *within* one library, so this constraint is preserved for free —
but it also means every new module sees the same module set, and a new module
that names a library not already listed there is a build failure, not a design
choice.

### 1.2 `--check` diagnoses a deployment without a server (load-bearing, in substance)

`bin/main.ml`'s header states the rule: *"the `--check`/`--metrics` paths never
call `Server.registry`, a transport or `Factory.build_app`"*. The check path does
call `Factory.build_providers`, `Factory.probe_net`, `Factory.build_extractor`
and `Factory.classify` (`lib/cli/cli_check.ml`), and `Cli_flags.startup_refusal`
calls `build_extractor` too. So what the constraint actually protects is the
*absence of engines, the health monitor's loop, the usage journal and the
transport* from a diagnosis — not the absence of grants: `--check` builds real
grants (without a sink) and probes them.

The load-bearing part is therefore: **`build_app` must stay separable from
`build_providers` / `classify` / `build_extractor` / `probe_net`, and the check
path must never reach the module that constructs engines.** The split *strengthens*
this: today the separation is a convention inside one 556-line file; after the
split, `app.ml` is the only module that can construct an engine, and `cli_check`
does not name it. That is a boundary a reviewer can see without reading prose.
It is not, however, compiler-enforced inside this workspace: dune's alias module
re-exports private modules to sibling stanzas (port plan §11, established by
probe), so step 8 keeps the boundary with a check-path source pin rather than
relying on `private_modules`.

The incidental part is the claim in `factory.mli` that construction lives in *one*
module. One module is not what makes the diagnosis work; the *direction* of the
calls is.

### 1.3 One audited grant funnel (load-bearing, and the only constraint the split can genuinely break)

`grant_of_decision` is the single place a serving grant is built: one
`Authority.with_log`, one `Authority.Net.of_confinement`, the config's
per-operation bound, no `Authority.with_operation_budget`. `?audit` is threaded
as the last optional argument through every public builder, and `build_app` is the
only caller that supplies it, so a grant without a sink is a *diagnostic* grant
and never a serving one (§11).

This is the constraint that has **no compiler enforcement**. `lib/caps` seals
`Policy_fs`/`Controls_raw` with `private_modules`, but `Authority.Net.of_confinement`
and `Authority.with_log` are public and callable from any module in
`seekwright.factory`. What keeps the funnel single today is
`test/test_caps_audit.ml`'s source pins, applied to **one file's text**:
`count_occurrences ~haystack:factory_source ~needle:"Authority.with_log" = 1` and
the same for `Authority.Net.of_confinement`. A split into six files makes that
pin *structurally weaker*: each new file could hold one occurrence and the
per-file count would still read 1. **The single most important consequence of
this task is that the pin must become a library-wide total, not a per-file one.**
Section 3 makes that invariant #1 and Section 4 puts it in the first commit.

### 1.4 Incidental shape (not a constraint)

- 556 lines is the *motivation*, not a requirement.
- That `audit_fields`, `reserved_audit_fields`, `grant_of_decision`, `adapter`,
  `adapter_of_row`, `cap_of`, `error_of` and `agent_net` are private to the file
  is incidental; they are absent from `factory.mli` only because nothing outside
  needed them. After the split they are exported by their new module and still
  absent from `Factory`'s interface.
- Which function sits beside which is incidental; only the funnel and the
  check-path direction are not.

---

## 2. The split

### 2.1 Shape

Six new modules plus a facade, all inside `lib/factory` (library unchanged):

| file | contents (moved verbatim from `factory.ml`) | visibility |
|---|---|---|
| `provider_set.ml{,i}` | `type providers` (35–41), `type set_report` (212–221) | **public** |
| `grants.ml{,i}` | `reserved_audit_fields` (50), `audit_fields` (52–64), `audit_sink` (66–74), `grant_of_decision` (76–89), `grant_of_endpoint` (91–110), `probe_net` (297–325) | private |
| `verdict.ml{,i}` | `classify` (223–255), `built_phrase` (257–258), `startup_verdict` (260–295) | private |
| `providers_build.ml{,i}` | `type adapter` (112–120), `adapter_of_row` (122–126), `build_providers` (128–210) | private |
| `fetch_stack.ml{,i}` | `build_extractor` (327–334), `readers` (336–348), `cap_of` (350–354), `error_of` (356–369), `build_fetch_stack` (371–454) | private |
| `app.ml{,i}` | `agent_net` (456–466), `build_app` (468–556) | private |
| `factory.ml{,i}` | facade: doc, two type equations, ten one-line re-exports | public (unchanged name) |

`registry.ml{,i}` is **not touched** by this task.

### 2.2 The one deviation from the brief, and why

The brief puts `set_report` in `verdict.ml`. But `Factory`'s public interface must
re-export *both* record types, and a record can only be re-exported with its field
labels if the interface spells it as an **equated alias**:

```ocaml
(* factory.mli — required, not stylistic *)
type providers = Provider_set.providers = {
  built : ...; probe_table : ...; endpoints : ...; grant_errors : ...; unsupported : ...;
}
type set_report = Provider_set.set_report = {
  enabled : ...; effective : ...; built : ...; unsupported : ...; skipped : ...; untested : ...;
}
```

The equation is load-bearing because callers qualify field labels through
`Factory`, not through the owning module: `built.Factory.built` (`bin/main.ml`),
`sets.Factory.unsupported` (`lib/cli/cli_check.ml`), `providers.Factory.endpoints`
(`test/test_provider_registry.ml`), and record literals
`{ Factory.built = []; probe_table = … }` (`test/test_routing_sets.ml`). An
abstract `type providers = Provider_set.providers` would make every one of those
an "unbound record field `Factory.built`" error. So the types must be *re-declared*
in `Factory`'s signature, which means the owning module appears in a **public**
interface.

Naming a private module from a public interface is a hazard this tree has already
paid for: `plans/seekwright-ocaml-port.md` §11 records that hiding `policy_net`
"failed the intended grant path in the first probe of that shape", which is why
`policy_net` stayed public while only `policy_fs`/`controls_raw` were sealed. A
probe against dune 3.24 during this design reproduced the shape: with
`(private_modules inner)`, `Outer.cmi` is installed and a consumer type-checks
through the alias, but the manifest path to `Inner` dangles — `x.Probe_lib__Inner.a`
is "Unbound module", and odoc cannot resolve the reference.

Therefore: **`provider_set.ml` is public and owns both records; `verdict.ml` stays
private.** The public API grows by exactly one module holding two types and zero
functions. That is preferable to the brief's literal shape, which would need
`verdict.ml` public as well and would print `classify`/`startup_verdict` twice in
the docs. (If the brief's shape is preferred anyway, the only cost is
`verdict.ml` moving from private to public in the same commit that adds it, and
`Provider_set`/`Verdict` both described in `@doc`.)

### 2.3 Line budget

"Moved" counts the verbatim span plus the comments that belong to it.

| file | moved | new header/aliases | file after |
|---|---:|---:|---:|
| `provider_set.ml` | 17 | ~8 | ~25 |
| `provider_set.mli` | — | — | ~20 |
| `grants.ml` | 91 | ~14 | ~105 |
| `verdict.ml` | 71 | ~8 | ~79 |
| `providers_build.ml` | 98 | ~10 | ~108 |
| `fetch_stack.ml` | 124 | ~15 | ~139 |
| `app.ml` | 100 | ~12 | ~112 |
| `factory.ml` (facade) | — | — | ~45 |
| `factory.mli` (facade) | — | — | ~240 |

Total ~630 source lines against 556: the growth is module docstrings, per-file
`module X = …` aliases and one-line re-exports. Any proposal that claims *fewer*
lines is proposing a reformat or a doc deletion; both are out of scope (§5).

Module aliases per file, to keep bodies byte-identical:

- `grants.ml`: `Caps`, `Authority`, `Policy`, `Config`, `Engine` (for `Engine.log`),
  and `Provider` — `probe_net` builds `Provider.Net.request` / `Provider.Net.of_grant`.
- `verdict.ml`: `Config`, `Registry`, plus the local type aliases
  `type providers = Provider_set.providers` and `type set_report = Provider_set.set_report`
  (`classify` annotates `(built : providers)` and constructs a `set_report` literal).
- `providers_build.ml`: `Config`, `Provider`, `Registry`, `Policy`, `Health`, plus
  `type providers = Provider_set.providers` (the record literal in `build_providers`
  and its return type).
- `fetch_stack.ml`: `Config`, `Fetcher`, `Extractor`, `Extract_pool`, `Jsondoc`,
  `Engine`, `Provider`, `Policy`, `Caps`.
- `app.ml`: `Config`, `Engine`, `Health`, `Provider`, `Usage`, `Agent`, `Server`,
  plus `let ( let* ) = Result.bind` (only `build_app` uses it). No local `providers`
  alias is needed: the type flows from `Providers_build.build_providers`'s signature.
- `provider_set.ml`: the four short aliases the type bodies already use —
  `Config`, `Provider`, `Health`, `Policy` (for `Config.name`, `Provider.t`,
  `Health.probe_spec`, `Policy.endpoint`).

`probe_net` goes to `grants.ml`, not to `providers_build.ml`: it is an
endpoint-union grant with a timeout and a sink, it is a sibling of
`grant_of_endpoint`, and keeping the two together is what keeps "every grant this
library builds" readable in one file.

### 2.4 The facade's exact re-export list

From the 123 external occurrences, `Factory` must keep re-exporting every name it
publishes today — no additions, no omissions:

**Types (equated aliases, §2.2):**
`Factory.providers` (`bin/main.ml:153,186`, `live/runner.ml:118,172`, plus field
reads in `bin/main.ml:161,163,187,220,222`; `live/runner.ml:120,177,182,193,379`;
`lib/cli/cli_check.ml:266,270,276,286`; `test/test_boot.ml:54,56`;
`test/test_routing_sets.ml:63,89,150`; `test/test_provider_registry.ml:685,692,694,699,704,715,729,783,785,787,818,820`) and
`Factory.set_report` (`lib/cli/cli_check.ml:227–254`;
`test/test_routing_sets.ml:54,59,61,77,111,113,115,172,174,176,196–201`;
`test/test_provider_registry.ml:820,821`).

**Values (one `let` line each):**

| value | owning module | external call sites |
|---|---|---|
| `audit_sink` | `Grants` | `test/test_caps_audit.ml:307,479`; `test/test_concurrency.ml:363` |
| `classify` | `Verdict` | `lib/cli/cli_check.ml:225`; `test/test_routing_sets.ml:52,75,110,170,194`; `test/test_provider_registry.ml:807` |
| `startup_verdict` | `Verdict` | `test/test_routing_sets.ml:65,96,116,130,157,178,203` |
| `build_providers` | `Providers_build` | `lib/cli/cli_check.ml:216`; `test/test_boot.ml:50`; `test/test_routing_sets.ml:41`; `test/test_provider_registry.ml:675,778,803`; `live/runner.ml:173` |
| `grant_of_endpoint` | `Grants` | `test/test_caps_audit.ml:109,121`; `test/test_concurrency.ml:366`; `test/test_grant_timeouts.ml:64` |
| `probe_net` | `Grants` | `lib/cli/cli_check.ml:268`; `test/test_caps_audit.ml:460`; `test/test_concurrency.ml:412`; `test/test_grant_timeouts.ml:115` |
| `build_extractor` | `Fetch_stack` | `lib/cli/cli_flags.ml:142`; `lib/cli/cli_check.ml:150`; `test/test_boot.ml:25` |
| `build_fetch_stack` | `Fetch_stack` | `test/test_boot.ml:30`; `test/test_caps_audit.ml:205`; `test/test_fetch_grant.ml:191`; `live/runner.ml:221` |
| `readers` | `Fetch_stack` | `live/runner.ml:227` |
| `build_app` | `App` | `bin/main.ml:208`; `test/test_boot.ml:41`; `test/test_routing_sets.ml:137`; `live/runner.ml:358` |

Not re-exported (they are not in `factory.mli` today and must stay internal):
`grant_of_decision`, `audit_fields`, `reserved_audit_fields`, `adapter`,
`adapter_of_row`, `cap_of`, `error_of`, `agent_net`, `built_phrase`.

Two stale prose mentions are *not* part of this task: `Factory.page_of` (a value
deleted in the style review's M5) is still named in `lib/wire/page.mli`,
`test/test_wire.ml` and `plans/reviews/2026-11-12-style-review.md`. They are
comments, they do not compile into anything, and touching them here would mix a
doc sweep into a move.

`factory.mli` keeps its existing doc comments verbatim (including the audit
section and the `with_operation_budget` refusal) and gains only the two type
equations; `factory.ml` becomes the doc comment plus the equations plus ten
`let` lines. The field-level docs stay in `factory.mli` (public) rather than
moving to `provider_set.mli`, so odoc never has to cross-reference a doc comment
from the public page into a private one.

---

## 3. Hard invariants the split must preserve

1. **Exactly one `Authority.with_log` wrap site, and exactly one
   `Authority.Net.of_confinement`, across the whole library.** After the split
   the count becomes a *total* over `lib/factory/*.ml`, not a per-file count, and
   `grants.ml` is asserted to be the file that holds the one. `with_log` stays the
   outer wrapper and `with_operation_timeout` the inner one — the moved body is
   byte-identical, so the nesting cannot drift.
2. **`startup_verdict` runs before any engine exists.** In `app.ml` the order is
   `Usage.create` → `let audit = audit_sink log in` → `build_providers` →
   `grant_errors` refusal → `startup_verdict` → `Health.create` →
   `Engine.Search.create` → `build_fetch_stack`/`Engine.Fetch.create` →
   `agent_net`/`Agent.create` → `probe_net` → `Ok (app, built)`. Nothing may be
   hoisted above the `let* () = startup_verdict config built`. This order is not
   currently pinned by a test; see §4 step 8 for the cheap source-order pin that
   makes it so.
3. **No `Authority.with_operation_budget` in server construction.** The only
   mention is the bracketed prose that moves with `grant_of_endpoint`'s comment
   into `grants.ml`; the pin (`count of unbracketed mentions = 0`, `?budget` = 0)
   extends from `factory.ml` + `server.ml` to `grants.ml`, `app.ml`,
   `fetch_stack.ml`, `factory.ml`, `server.ml`.
4. **`?audit` stays the last, optional argument on every public builder**
   (`grant_of_endpoint`, `build_providers`, `probe_net`, `build_fetch_stack`,
   `agent_net`), and `build_app` stays the only caller that supplies it. Label
   order in `factory.mli` is unchanged, so no call site churns.
5. **`registry.ml` and `registry.mli` are untouched** — not one byte, including
   the rows, `make_row`, `grant_endpoint`, `key_for`, `probe_spec`. F5.3–F5.5
   edit that file; the split must not appear in its diff.
6. **Both web-grant constructions stay single.** `Policy.with_private_web` and
   `Policy.with_public_web` each appear exactly once, in the one branch that reads
   `fetch.allow_private_addresses` — now in `fetch_stack.ml`
   (`test/test_fetch_grant.ml`'s pin).
7. **Every bounded grant still reads its own config key, and the three keys stay
   distinct**: `policy.provider_timeout_seconds` (`providers_build.ml` and
   `app.ml`'s probe-net call), `fetch.timeout_seconds` (`fetch_stack.ml`),
   `agent.model_timeout_seconds` (`app.ml`) — `test/test_grant_timeouts.ml`'s pin.
8. **The public surface does not widen**: the facade re-exports exactly §2.4;
   the six new modules are `.mli`-documented and five of them private. No new
   dependency in `lib/factory/dune`.

### 3.1 How the pins move (the concrete edits)

`test/test_caps_audit.ml`:

- `factory_source` becomes a set of `(name, text)` pairs read from
  `../lib/factory/` — every `.ml`, and every `.mli` (all seven interfaces) for the
  `Policy_fs`/`Controls_raw` scan. The home is a `Test_support.factory_sources`
  helper, with two hard requirements:
  - It must be a **function** `unit -> (string * string) list`, never a top-level
    value: `test_support` is linked by dozens of suites whose sandboxes carry no
    `lib/factory` sources, so a module-load `read_file` would raise `Sys_error` in
    every one of them. Only the three pin suites call it.
  - Build the list with `Sys.readdir "../lib/factory"` filtered by
    `Filename.check_suffix` (`.ml` / `.mli`), the idiom `test_core_no_mcp_kit.ml`
    already uses — not a hand-maintained name list. A new factory module is then
    scanned automatically, which is exactly invariant #1's "a pin can never scan a
    stale file list". `read_file` still fails loudly on a missing name.
  One helper serves `test_caps_audit`, `test_grant_timeouts` and `test_fetch_grant`;
  only the *scan set* is shared — the per-file `includes` assertions stay per-file.
- `test_the_factory_builds_grants_through_one_funnel`: the two counts move to
  `grants.ml` *and* gain a library-total assertion; the `includes` needles follow
  their code — `"grant_of_decision ~mono_clock ~timeout_seconds ?audit decision"`
  → `grants.ml` (it occurs there twice, in `grant_of_endpoint` and `probe_net`),
  `"~audit config"` → `app.ml`, `"?audit adapter.endpoint"` →
  `providers_build.ml`, `"?audit decision"` → `grants.ml` and `fetch_stack.ml`,
  `"?audit endpoint)"` → `app.ml`, `"let audit = audit_sink log in"` → `app.ml`.
  Each needle is asserted against *the file named beside it*, not against the
  concatenation, so a future move fails loudly instead of passing on a stale hit.
- `test_no_operation_budget_on_the_serving_path`: extend the file list as invariant #3.
- `test_production_modules_obtain_grants_from_the_factory`: extend from
  `server.ml`/`bin/main.ml` to every factory source *except* `grants.ml`, and
  assert the one occurrence lives in `grants.ml` (this is the negative half of the
  library-wide count).
- `test_nothing_outside_caps_names_the_sealed_layer`: extend to all factory
  sources and interfaces.

`test/test_fetch_grant.ml`: the `with_private_web` / `with_public_web` counts and
the `if fetch.Config.allow_private_addresses then Policy.with_private_web` needle
move to `fetch_stack.ml`, but the `Policy.with_endpoints` needle ("endpoint grants
still exist") moves to **`grants.ml`** — `with_endpoints` is called only by
`grant_of_endpoint` and `probe_net`, neither of which is in the fetch-stack span.
The `--check` disclosure needle still reads `cli_check.ml` (unchanged).
`test/test_grant_timeouts.ml` (`factory_source` → the factory sources) follows the
same pattern.

`test/dune`: replace the individual `../lib/factory/factory.ml` deps in the
`test_grant_timeouts`, `test_fetch_grant` and `test_caps_audit` stanzas with
`(glob_files ../lib/factory/*.ml)` / `(glob_files ../lib/factory/*.mli)` (the
pattern `test/differential/dune` already uses). A glob means a pin can never scan
a stale file list — which is the whole point of invariant #1.

Nothing in `test/should_not_compile/` references `factory.ml` (verified: no
occurrence of `factory` in that directory). Those programs compile against the
`mcp-caps` interface closure and its hand-written `mcp_caps.ml` mirror; the split
does not enter that view at all. The `dune` comment there and §11's "thirteen
programs" statement stay true untouched.

Two pins that stay green without edits, and why: `test/differential/matrix/*.tsv`
rows that credit `factory/factory.ml` still resolve (`test_differential_matrix.ml`
only checks that a credited path exists, and the facade file still exists), and
`test/test_fetch_grant.ml`'s `--check` disclosure needle reads `cli_check.ml`,
which does not move. Re-crediting the matrix rows to `grants.ml` /
`fetch_stack.ml` / `app.ml` is an honesty follow-up of its own, not part of the
split (matrix columns are pinned by `test_differential_matrix.ml`).

---

## 4. Sequencing: one commit per move, gate green after each

Gate for every step: `dune build @install && dune runtest --force && dune build @doc`.
No step contacts a provider; no step needs a key.

Dependency order is free among the leaves (`grants`, `provider_set`) but fixed
after: `provider_set` before `verdict`/`providers_build`/`app`; `grants` before
`providers_build`/`fetch_stack`/`app`; `fetch_stack` and `verdict` before `app`.

**Step 1 — `test: read the factory's sources as a set, not a file`.**
Add `Test_support.factory_sources` as a `unit -> (string * string) list` function
that `Sys.readdir`s `../lib/factory` (see §3.1); rewrite the three suites' pins to
consult it — at this step the directory holds `factory.ml` only, so behaviour and
counts are unchanged; switch the three `test/dune` stanzas to `glob_files`. Gate
green. This is the enabling commit: every later step adds a file to the directory
and the scan picks it up with no pin rewrite.

**Step 2 — `factory: extract the two set records`.** Add
`provider_set.ml{,i}` (`providers`, `set_report`), delete both type definitions
from `factory.ml`, add the two equated aliases in `factory.ml` **and**
`factory.mli`; the readdir scan picks up `provider_set.ml` automatically. No
value moves; nothing else changes. Verifies the alias mechanism (the record
literals in `test_routing_sets` and every `x.Factory.built` read are the proof).

**Step 3 — `factory: extract the routable-set verdict`.** Add `verdict.ml{,i}`
(`classify`, `built_phrase`, `startup_verdict`), delete them from `factory.ml`, add
two `let` re-exports (`classify`, `startup_verdict` — `built_phrase` stays
internal). Pin edit: none — nothing in the pins mentions these functions; callers
use `Factory.classify`/`Factory.startup_verdict`, which keep working. (This is why
the type commit comes first: `verdict.ml` needs `Provider_set.providers`.)

**Step 4 — `factory: extract the grant funnel`.** Add `grants.ml{,i}`
(`reserved_audit_fields`, `audit_fields`, `audit_sink`, `grant_of_decision`,
`grant_of_endpoint`, `probe_net`), add three `let` re-exports
(`audit_sink`, `grant_of_endpoint`, `probe_net`), the scan picks it up. **Pin edit
in the same commit** (§3.1): counts move to `grants.ml` + library total, five
`includes` needles re-pointed, budget scan extended, sealed-layer scan extended.
This is the commit where a mistake breaks the audit guarantee, so it is also the
one to review hardest.

**Step 5 — `factory: extract the provider build pass`.** Add
`providers_build.ml{,i}` (`type adapter`, `adapter_of_row`, `build_providers`),
one `let` re-export, the scan picks it up. Pin edits: `"?audit adapter.endpoint"`
now points at `providers_build.ml`; `test_grant_timeouts` finds
`policy.provider_timeout_seconds` in `providers_build.ml` (and still in `app.ml`
after step 7 — the pin is per-file, so both are named).

**Step 6 — `factory: extract the fetch stack`.** Add `fetch_stack.ml{,i}`
(`build_extractor`, `readers`, `cap_of`, `error_of`, `build_fetch_stack`), three
`let` re-exports. Pin edits: `test_fetch_grant`'s web-variant counts and the
`if fetch.Config.allow_private_addresses then Policy.with_private_web` needle move
to `fetch_stack.ml`; the `Policy.with_endpoints` needle moves to `grants.ml` (it is
not in this span — see §3.1); `test_grant_timeouts` gains `fetch_stack.ml` for
`fetch.Config.timeout_seconds`.

**Step 7 — `factory: extract the app build`.** Add `app.ml{,i}` (`agent_net`,
`build_app`), one `let` re-export, the scan picks it up. Pin edits:
`"let audit = audit_sink log in"`, `"~audit config"`, `"?audit endpoint)"` →
`app.ml`; `test_grant_timeouts` gains `app.ml` for
`agent.model_timeout_seconds`. `factory.ml` is now ~45 lines.

**Step 8 — `factory: make the construction modules private, and pin the boundaries`.**
Add `(private_modules grants verdict providers_build fetch_stack app)` to
`lib/factory/dune` (the five modules that appear in no public signature). Note what
this seal does and does not do (port plan §11, established by probe):
`private_modules` stops *installed* consumers and keeps the modules out of odoc,
but a stanza *inside this workspace* can still name them through dune's generated
alias module. So the check-path boundary is kept by a source pin, not the compiler.
Rewrite `factory.ml`'s doc comment to the facade story and add two pins:
- the source-order pin `index of "startup_verdict" < index of "Engine.Search.create"`
  in `app.ml` (invariant #2, currently unpinned);
- a check-path pin: `cli_check.ml`, `cli_flags.ml` and `bin/main.ml` contain no
  `build_app` and no `App.` — the diagnosis never reaches the engine-construction
  module (§1.2). This is the rule that makes the split's headline boundary checkable.
The eight `matrix/config-fields.tsv` rows crediting `factory/factory.ml` may be
re-credited here if the owner agrees (the matrix sandbox already globs
`../../lib/factory/*.ml`, so no dune change is needed); otherwise a separate
follow-up.

**Step 9 — `plans: record the split`.** A new dated section in
`plans/seekwright-ocaml-port.md` (after §25) stating the module map, the
library-wide funnel pin, and that `registry.ml` was not touched; plus the
`docs/`-equivalent note that `factory.mli` remains the public contract. No
`plans/project-structure.md` change is needed: it does not mention
`lib/factory`.

Steps 1–7 are independently revertable; steps 8–9 are the seal.

### What must wait for the F5 waves

The F5 waves touch `lib/factory/factory.ml` itself — F5.2 changed 15 lines there
(the `adapter.uri` field, `adapter_of_row`, and the `endpoint = adapter.uri` arg in
`build_providers` — all in the providers_build span step 5 moves), and F4.1 rewrote
154. F5.3 (tavily/tinyfish/linkup), F5.4 (algolia) and F5.5 (search1api/serpapi/
querit/deepseek) will each edit `registry.ml` rows and may edit the same spans
steps 4–7 move (F5.4's config-derived host construction is a likely candidate).

- **Land the split in a window with no F5 branch open**, or accept a rebase: a
  wave branch that edits `factory.ml` conflicts with every one of steps 3–7.
- If a wave must be in flight, order it *before* the split (rows and adapters
  land, then the split rebases over them) — never the other way round, because a
  wave rebasing onto a six-module factory would have to re-find its own hunks in
  `grants.ml`/`fetch_stack.ml`.
- **Specifically deferred to the waves**: anything that changes the fetch-stack
  fallback ladder (`build_fetch_stack`'s empty `[]`) belongs to F6, not to step 6;
  and the `Deferred wave` strings in `registry.ml` belong to the waves. The split
  moves code, so a wave that changes behaviour must not be combined with it.

---

## 5. Risks, and what not to do

**Risks**

- **The funnel pin is the real deliverable.** A per-file count silently permits
  one unaudited grant path per new file. If only one thing from this proposal is
  adopted, make it the library-wide total in `test_caps_audit`, plus the
  `test_production_modules_obtain_grants_from_the_factory` extension.
- **Facade drift.** A re-export line that names the wrong module compiles (all
  types are compatible) and only a behavioural test catches it. The 123 call
  sites are the regression net; `dune runtest --force` covers all of them.
- **Record-label resolution.** If `factory.mli` ever loses an equated alias, the
  failure appears as "unbound record field `Factory.built`" in four files —
  confusing, but loud. Keep the equations and keep the field docs with them.
- **`@doc`.** Five new private modules and one public module with no functions:
  each `.mli` needs a module doc comment, and public-page cross-references to
  private modules must be avoided (state the ownership in prose instead of
  `{!Provider_set.…}` from `factory.mli`'s page if odoc complains).
- **Public surface.** §2.2 adds exactly one public module. If `verdict.ml` is
  made public instead (the brief's literal shape), the docs show two spellings of
  `classify` and `startup_verdict`; choose one deliberately.
- **Matrix credits go stale.** Eight `matrix/config-fields.tsv` rows credit
  `factory/factory.ml` — `policy.provider_timeout_seconds`, `fetch.enabled`,
  `fetch.timeout_seconds`, `fetch.allow_private_addresses`, `agent.timeout_seconds`,
  `agent.model_timeout_seconds`, `dashboard.history_path` and
  `providers.*.cost_per_1k`. They will point at the facade while the read lives
  elsewhere. The build stays green (the checker only tests that the credited path
  exists, and the facade still exists); the honesty does not. Re-credit as its own
  change — the sandbox already globs `lib/factory/*.ml`, so no dune edit is needed.
- **`test_support` becomes load-bearing for three suites.** If the shared
  `factory_sources` scan is wrong, all three pins weaken together. Mitigate by
  building it from `Sys.readdir` (a new module cannot be forgotten), having
  `read_file` fail loudly for a missing name (it does), keeping it a function so
  the other suites that link `test_support` never read the factory sources,
  and leaving the per-file `includes` assertions per-file (only the *scan set* is
  shared).

**Do not**

- Do not reformat, re-indent or re-wrap a moved body. There is no `.ocamlformat`
  in this tree and none is added; a moved span must be byte-identical, which is
  what makes `git log -S` and the pins usable.
- Do not rename any `Factory` value, argument or label, and do not reorder labels
  — `?audit` stays last and optional.
- Do not add a dependency to `lib/factory/dune`, and do not move anything out of
  the library (§1.1).
- Do not touch `registry.ml`/`registry.mli` (invariant #5).
- Do not export `grant_of_decision`, `audit_fields`, `adapter_of_row`, `cap_of`,
  `error_of`, `agent_net` or `built_phrase` from `Factory`: they are not public
  today, and widening the surface is a separate decision with its own review.
- Do not pass an audit sink on a diagnostic path, and do not "simplify"
  `build_fetch_stack`'s single private/public-web branch.
- Do not hoist anything above `startup_verdict` in `build_app`, and do not
  reintroduce a budget argument anywhere.
- Do not seek a `(private_modules …)` for `provider_set` (§2.2), and do not split
  `fetch_stack.ml`'s `error_of` into a conversion record — the style review
  records that it is a genuine translation and stays one.
- Do not combine the split with an F5 provider wave, a matrix edit, or the F8
  "sweep" items.
- Do not fold behavior-preserving cleanups into the move: `probe_net`'s duplicated
  `Unavailable` record and `build_fetch_stack`'s nested `match` ladder are
  follow-up commits after step 8 (§6), not part of a byte-identical move.

---

## 6. Review corrections and deferred follow-ups (2026-11-13)

Applied to the body above after a read of `factory.ml{,i}`, the three pin suites,
`test/dune`, `test/support/`, the matrix checker, port-plan §11/§13/§22/§25 and the
F5.2 diff (`2cedd7c`):

1. **`Policy.with_endpoints` needle → `grants.ml`, not `fetch_stack.ml`** (§3.1,
   step 6). It occurs only in `grant_of_endpoint`/`probe_net`; as first written the
   step-6 pin edit would have failed the gate.
2. **`grants.ml` needs the `Provider` alias** (§2.3) — `probe_net` uses
   `Provider.Net`.
3. **Ten value re-exports, not eleven; verdict re-exports two, not three** (§2.1,
   step 3). `built_phrase` stays internal; re-exporting it would widen the surface
   against invariant #8.
4. **`Test_support.factory_sources` is a function built from `Sys.readdir`** (§3.1,
   step 1) — a top-level value would crash the other suites linking
   `test_support`, and a hand-list could forget a new module.
5. **The seal is not compiler-enforced in-workspace** (§1.2, step 8; port plan §11).
   Added a check-path pin (`cli_check`/`cli_flags`/`bin/main.ml` never name
   `build_app`/`App`) so the split's headline boundary is checkable.
6. **Type aliases for the moved record literals** (§2.3): `verdict.ml` and
   `providers_build.ml` need local `Provider_set` aliases; `provider_set.ml` needs
   the four short module aliases its type bodies already use.
7. Count fixes: 123 external `Factory.` occurrences (same 16 files); eight matrix
   rows credit `factory/factory.ml`; the `.mli` scan covers all seven interfaces;
   the dangling "§3.3" reference now points at invariant #3; F5.2's factory.ml edit
   was the `adapter.uri` wiring in the providers_build span, not comment blocks.

**Deferred follow-ups — out of scope for the split, each its own commit:**

- `probe_net` writes the identical `Unavailable` net record twice; one shared
  binding removes ~8 lines in `grants.ml`. Behavior-preserving; after step 8.
- `build_fetch_stack`'s nested `match … Some (Ok …)` ladder can flatten with a small
  option-result bind (F8-style). Behavior-preserving; after step 8.
- Re-credit the eight matrix rows to `grants.ml`/`fetch_stack.ml`/`app.ml` (the
  sandbox already globs `lib/factory/*.ml`).
- The stale `Factory.page_of` prose in `lib/wire/page.mli`, `test/test_wire.ml` and
  the style review — a doc sweep, not a move.
- A compiler-enforced funnel (sealing `of_confinement`/`with_log` behind one audited
  constructor) is an `mcp-caps` public-API decision with its own review; the split
  is a step toward it, not the place to do it.
- Relocating `readers` out of the factory is **blocked by dependency direction** (it
  needs both `seekwright` and `seekwright.fetch`); do not attempt it.
