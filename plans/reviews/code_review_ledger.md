# Code review ledger — ocaml-port

Status: live, empty. This file tracks **one review**: the owner's read of the
OCaml tree. It starts empty and gains entries as that read proceeds.

## What this ledger is, and is not

It is a register, not a write-up. An entry records what the reviewer noticed, how
they saw it, and what happened to it; the argument behind a finding goes in the
commit, the plan section or the `plans/` page that owns the decision, not here.

It is **the owner's**, not an agent's. An agent maintains the file on the owner's
behalf — writing what the owner says they found, and updating status when the
owner says what they did about it — and adds no findings of its own. An entry is
a claim the owner made and can defend, which is the only reason a status column
means anything.

The reviews already on this branch stay where they are: the dated files in
`plans/reviews/` and the findings sections of `plans/seekwright-ocaml-port.md`
each hold their own. This ledger does not restate them, does not carry their
findings forward, and does not count them. Where the owner's read reaches ground
one of them already covered, the entry says so in `Prior` and links the file and
heading; the entry's status stays the owner's, not the earlier review's.

## Entry rules

- **ID:** `R-NNN` for a finding, `Q-NNN` for a question, numbered in the order
  raised, never reused, never renumbered. A closed entry keeps its ID and moves
  to the closed table.
- **One entry per finding.** Not per file, not per symptom seen twice.
- **Name the symbol, never a line number.** `Engine.take`, `Config.section`,
  `KNOWN_FALLBACKS`, `test/dune`'s `ocamldep` rule — the same rule `docs/` holds,
  and for the same reason: a number moves the next time the file above it is
  edited and no check tells a reader the pointer went stale.
- **Evidence is part of the entry.** `read` (the code was read and says this),
  `probe` (a program was run against it — name it), `test` (an existing case
  pins it), `oracle` (the Python side does something different — name the module
  and symbol on both sides). An entry without evidence sits in the open table
  with `Evidence: read` at best, and does not get a severity until it does.
- **Severity is the reviewer's judgement of impact, not of effort.** The four
  rungs below.
- **An entry is never deleted**, including one later found wrong: it moves to
  closed with `Status: not a defect` and one line saying what refuted it. A
  finding that was raised and dropped is the record of a question having been
  asked.

## Vocabulary

| Status | Means |
|---|---|
| `open` | verified, unfixed, unowned |
| `owned` | a fix is in flight; `Owner` names the branch, CR or plan section |
| `fixed` | closed by a commit, recorded in `Closed in` |
| `declined` | deliberately not fixed; `Decision` names where that is recorded |
| `not a defect` | raised, then refuted; the entry keeps its evidence and says what refuted it |

| Severity | Bar |
|---|---|
| CRITICAL | a wrong answer, a crash, a secret, or a refused guardrail on a path a served process can take |
| HIGH | wrong or unbounded behaviour the gate does not see, or a promise the tree makes and does not keep |
| MEDIUM | a real defect on a narrow or unreachable path, or a duplicated fact with no owner |
| LOW / NIT | style, naming, dead weight, comment accuracy |

Design questions — a decision the plans already record and the reviewer
disagrees with — are not defects and never enter the findings tables. They go to
the question register, which names the plan section that holds the decision.

## Coverage

What the review has read, so a later session resumes in the right place. An area
is `read` only when it was read against the oracle, not skimmed; `reading` marks
where the session stopped.

| Area | State | Session |
|---|---|---|
| `lib/engine.mli` (interface; `engine.ml` read, not line-by-line) | read; edited (Q-001) | 1 |
| `lib/engine.ml` | read; edited (Q-001) | 1 |
| `lib/` core, the rest: `router`, `config`, `model`, `provider`, `health`, `usage`, `log`, `sanitize`, `agent`, `server`, `cli`, `prompts`, `http_head`, `dashboard_html`, `version` | partly read — `Usage`'s date arithmetic and field sets (R-009, R-011), `Server.serve_http`'s caller contract and `Cli_serve` (R-001), `Config`'s fallback rows (R-003), `Cli_metrics`' date math (R-009); not read against the oracle as a whole | 2 |
| `lib/caps/` — the `mcp-caps` layer | partly read — `registry.ml`/`.mli` and `server.ml` (R-002); `authority`, `policy*`, `controls*`, `event`, `error` unread | 2 |
| `lib/providers/` | partly read — the four date copies (`linkup`, `parallel`, `deepseek`, `freeserp`) and `linkup`'s request body (R-009); the adapters as a whole unread | 2 |
| `lib/fetch/` | partly read — `Fetcher.validate_url` and the hop loop, `Remote_target` (R-006), `extractors/stdlib`'s entity half (R-008), `tabledoc`'s line assembly and `jsondoc.normalize` (checked, not a finding); the `Fallback_*` bodies read only as far as R-005 needed | 2 |
| `lib/factory/`, `lib/text/`, `lib/wire/` | read for `fetch_stack.ml`, `providers_build.ml`, `provider_set.ml` and the `registry.ml` row shape (R-003…R-007); `lib/text/`, `lib/wire/` unread | 2 |
| `bin/` | partly read — `main.ml`'s serve dispatch and the provider-close path (R-001) | 2 |
| `test/` (suites, pinned rules, `should_not_compile`, `differential`, `conformance`, `corpus_html`) | partly read — the pins each finding names: `test_p8_server` (registration and `tools/list` order), `test_boot` (warmups order), `test_fetch_ladder` (ladder names and prices), `test_remote_target`, `test_fetch`'s URL gate, `test_usage`, `test/corpus_html`'s `entities-soup` digest and bar, `test/fetch_support/fallback_fixtures.ml`, `test_mcp_client`'s request log | 2 |
| `ocaml-tools/`, `live/`, `examples/` | partly read — `surface.ml`'s config-key scan (checked for R-003: a `fetch_fallback` row field never enters the manifest); `live/`, `examples/` unread | 2 |
| Build: `dune-project`, every `dune`, both generated `*.opam`, `Containerfile.ocaml`, `ci-ocaml.yml` | partly read — every library stanza, for where a shared module may legally sit (R-009); `Containerfile.ocaml` unread | 2 |

## Findings — open

| ID | Sev | Area | Finding | Evidence | Owner | Status | Prior |
|---|---|---|---|---|---|---|---|
| R-001 | LOW | `lib/cli/cli_serve.ml` | The HTTP runner's wrapper is written twice: `run_with_signals` and `run_with_stop` each open a `Fun.protect ~finally:… close ()` around a byte-identical `Server.serve_http` call, and the nine-labelled argument list appears in both wrappers, in `run_http` and in `cli_serve.mli`. *As filed this was half wrong:* there is no `run_stdio` — `git log --all -S"run_stdio"` is empty across every ref — stdio is one `Mcp_kit_stdio.run_channels` line in `bin/main.ml`, `Server.serve_http` has been the single listener owner since `2298223`, and the `server.ml` range named is the frozen-surface data (`rest_routes`, `operational_routes`, `server_flag_table`) both here and at `606dbaa` | `read` both files; `probe` (`git log --all -S`) for the `run_stdio` half | | open | the entry keeps the refuted framing, per the entry rules |
| R-002 | NIT | `lib/caps/registry.ml`, `lib/caps/server.ml` | `Registry.add` appends (`registry @ [ entry_of tool ~grant ]`) and `Server.of_registry` folds `tools @ [ tool ]`; both lists top out at the three tools of the frozen surface, so the cost is nil — the reason to fix it is that `mcp-caps` is pitched at servers with more tools | `read`; `test` — `test_p8_server.registry_lists_the_three_tools` and `tools_list_advertises_the_freeze` pin the order the fix has to preserve | | open | style-review L3 |
| R-003 | MEDIUM | `lib/factory/fetch_stack.ml`, `lib/config.ml` | Three fetch fallback prices (`scrappa` 0.30, `tavily` 1.60, `linkup` 5.00) live in `fallback_price`, a `match` on the name in the factory. The registry that owns every other fact about a fallback (`Config.known_fetch_fallbacks`: `billable`, `endpoint`, `fetch_key`) carries none, no `Fallback_*` module declares one, and `build_fallback` has already resolved the row before it looks the price up by name a second time. `fallback_cost` evaluates `fallback_price` twice | `read`; `oracle` — `fetcher.py` declares the figure on each fallback class (`ScrappaFetcher.cost_per_1k` and siblings) and `_build_*` overrides it with `fetch.cost_per_1k`; `docs/reference/providers.md` owns the prose; `test` — `test_fetch_ladder` pins `[ Some 0.30 ]`, the corrected `[ Some 0.20 ]` and `[ None; None ]` | | open | |
| R-004 | LOW | `lib/factory/fetch_stack.ml` | `build_ladder` rebuilds its accumulator per name (`Result.map (( @ ) [ fetcher ]) (build_ladder rest)`); bounded at three rungs (five registry names, at most one billable and last), so the cost is nil, and the same line shadows the local reader's `fetcher` with a rung | `read` | | open | style-review L3 |
| R-005 | LOW | `lib/factory/fetch_stack.ml` | `build_fallback`'s three arms (`jina`, `crawl4ai`, the keyed `_`) each re-derive the permission gate, the key gate, the row endpoint through `Provider.policy_of_uri (Uri.of_string …)`, the `Float.max fetch.timeout_seconds 30.0` floor (twice in one arm, where the grant floor and Tavily's *vendor body* parameter are different things sharing a literal), the grant, the target and the `wrap_fallback` call; inside the keyed arm three config records differ by one field | `read` | | open | |
| R-006 | MEDIUM | `lib/factory/fetch_stack.ml`, `lib/fetch/remote_target.ml`, `lib/fetch/fetcher.ml` | The URL gate has three owners. `preflight_of` inlines `Uri.host (Uri.of_string validated)` and `vet_public_host`, which is what `Remote_target.host_of` and `check` already do; `"URL has no host"` is spelled in `validate_url`, in `check` and in `preflight_of`; and `validate_url` parses a host and throws it away. The parse is not the cost — `Fetcher.fetch` parses again to dial — the defect is two parsers answering "which host does this URL name" and one refusal sentence with no owner | `read`; `test` — `test/differential/golden/fetch/10-url-no-host.golden`, `test_remote_target`, `test_fetch`'s URL-gate cases; `oracle` — `fetcher.py`'s `UrlBlocked("URL has no host")` | `Remote_target.vet` | landed | |
| R-007 | LOW | `lib/factory/providers_build.ml` | The two arms after `produce args` in `Providers_build.go` are identical except that one conses `(name, warmup) :: warmups` | `read`; `test` — `test_boot` pins `warmups` in registration order, which the fix preserves | | open | |
| R-008 | LOW | `lib/fetch/extractors/stdlib.ml` | `charref_at`'s `lookup` is `List.assoc_opt key entity_table`, and `entity_table` is 274 pairs (98 legacy entities in both the bare and `;` form, 78 extended in the semicolon form). `convert` runs per data run and retries the lookup for every prefix of the name run — a page full of `&` in URLs pays thousands of comparisons per ampersand and allocates a substring per attempt | `read`; `probe` — counted the table and verified all 274 keys distinct and no name in both lists, so a keyed table cannot diverge from `assoc_opt`'s first-wins | | open | |
| R-009 | MEDIUM | `lib/usage.ml`, `lib/providers/{linkup,parallel,deepseek,freeserp}.ml`, `lib/cli/cli_metrics.ml` | Hinnant's civil-date arithmetic is copied six times: `Usage.civil_from_days` plus four byte-identical adapter copies plus the same era/`doe`/`yoe`/`doy`/`mp` arithmetic inlined in `Cli_metrics.civil_of_secs`; `days_from_civil` exists twice and `days_since_epoch` (floor division by 86400) four times, with two more floor spellings. All copies agree today, so nothing answers wrongly; there is no owner | `read` all six; `oracle` — the adapters' `%Y-%m-%d…` forms are what the request bodies send, and the decision to hand-roll rather than take a timezone library is recorded in `plans/seekwright-ocaml-port.md` | | open | |
| R-010 | NIT | `test/fetch_support/fallback_fixtures.ml` | `record` appends (`t.requests <- t.requests @ [ … ]`) while every consumer pattern-matches `[ only ]`; the sibling fixture `test_mcp_client` already prepends | `read` | | open | style-review L3 |
| R-011 | LOW | `lib/usage.ml` | `ensure` appends, and `set` walks the list, rebuilds it whole and appends on a new key; `remember_run` appends a provider count and `apply_answer` a model name. Bounded by `keep_days` (370), `runs_max` (256) and 17 provider names, so the cost is a constant factor the oracle (dicts) did not pay, paid hardest by `backfill` over a whole journal. Only `runs` is order-dependent — it stores oldest-first and evicts the head | `read`; `test` — `endpoints` and `citation_rows` sort on read and `snapshot` looks days up by key, which is what leaves the rest movable; no measurement yet | | open | style-review L3 (the unbounded instance of the same habit, `Jsondoc.normalize`/`dedupe`, was already rewritten onto a `Hashtbl`) |

The fix plan for these entries is `plans/code-quality-plan.md` — one section per ID,
with the order to land them in and the three decisions (D1–D3) recorded in its §3
(D1 yes, D2 deferred, D3 yes).

## Findings — closed

| ID | Sev | Area | Finding | Status | Closed in / Decision |
|---|---|---|---|---|---|
| — | | | | | |

## Questions and design disagreements

| ID | Area | Question | Against (recorded in) | Decision |
|---|---|---|---|---|
| Q-001 | `lib/engine.mli`, and `lib/**/*.mli` generally | Is a module interface the place for this much design prose? `engine.mli` ran 163 doc-comment lines in 303, and the module header alone had five `{1}` sections (failure discipline, the two clocks, the log sink, the page cache, the document readers) before the first `val`. It costs a first-time reader the signature. | the tree's own convention — every `lib/` interface opens with an ocamldoc header, and `dune build @doc` publishes those headers as the two libraries' API docs (`ci-ocaml.yml`'s `build @doc` step); beside it, `AGENTS.md`'s Python-side rule that a comment states a constraint and prose belongs in `docs/` | **decided, applied to `lib/engine.mli` and `lib/engine.ml`.** The standard: a name or a type carries it where it can; a sentence survives only for what neither the types nor a pinned rule can carry. Reasons and tests belong in the test, not in the comment. `engine.mli`: 163 doc lines → 127, 303 → 267, oracle citations 15 → 0, `{1}` sections five → three (the log-sink one went because `Log` owns that rule). `engine.ml`: 286 comment lines → 99, 77 blocks → 50, and no code line changed — the comment-stripped text is identical to `HEAD`. What went there: oracle provenance, test narration, review citations, restatements of the interface. What stayed: one line per constraint nothing pins — the 400/502 billing split, `"http"` as the local rung's journal name, escape-once ordering, `None` meaning unbilled rather than free. Nothing else under `lib/` touched: 51 interfaces still cite oracle files, 161 cite lines, worst `lib/text/utf8.mli` (17), `lib/provider.mli` (16), `lib/fetch/fallback.mli` (12). |

| Q-002 | `Engine.Search.error`, `Engine.Fetch.error` | The two are declared identically (`Refused of string \| Failed of string`) in one file, one module above the other. Worth one type instead of two? | the Python oracle keeps these as separate classes (`SearchRefused`/`FetchRefused`), which is a fact about the oracle, not a decision of this port's | **open.** Read so far: `lib/server.ml` re-derives the same two decisions (`Refused`→`Invalid`/`400`, `Failed`→`Failed`/`502`) at four sites — the MCP route and the REST route for each engine. |

## Sessions

What was read, and the state of the gate it was read against — a finding that
depends on a build or test result is only as good as the commit it was measured
at.

| Date | Tree at | Gate | Read | Entries |
|---|---|---|---|---|
| 2026-11-16 | `606dbaa` + this ledger and its `AGENTS.md` mention | `dune build @doc` exit 0, no warning names `engine.mli`; `test_engine` (87), `test_fetch_engine` (81), `test_fetch_ladder` (6), `test_fetch_cache` (12) and `test_log` (6, the suite that pins `engine.mli` aliasing `Log.log` exactly once) all pass. `dune runtest` not run: it held the build lock for 22 minutes in this workspace and sat inside `test_drain.exe` for 21 of them | `lib/engine.mli`, `lib/engine.ml` | Q-001, decided and applied to both files, uncommitted; Q-002 open |
| 2026-11-16 | `38007a0` + this ledger and `plans/code-quality-plan.md` | `dune build @install` exit 0 against the cached `_build`, working tree clean apart from the two `plans/` files. `dune runtest --force` not run this session | `lib/factory/{fetch_stack,providers_build,provider_set,registry}.ml`, `lib/config.ml`'s fallback rows, `lib/caps/{registry,server}.ml`, `lib/cli/{cli_serve,cli_metrics}.ml`, `lib/server.ml`'s serve and surface halves, `lib/fetch/{fetcher,remote_target,tabledoc,jsondoc}.ml`, `lib/fetch/extractors/stdlib.ml`, `lib/engine.ml`/`.mli`'s cache seam, `lib/usage.ml` (dates, field sets), four `lib/providers/` date copies, `bin/main.ml`, `ocaml-tools/surface.ml`, every library stanza, and the tests each finding is pinned by; oracle beside three of them (`fetcher.py`'s fallback rows and prices, `fetcher.py`'s refusal sentence, `providers.md`'s price prose) | R-001…R-011 raised, all verified; R-001's filed framing refuted; no code touched |
