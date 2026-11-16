# Evidence tiers: what each claim actually rests on

Status: live inventory (2026-11-16, at `38007a0`). Raised because "the Python tree is
the oracle" overstates what the differential harness proves. Read it before treating a
green `dune runtest` as evidence that the port works against a provider, and read
`plans/retiring-the-python-tree.md` for what happens to tier two when the oracle is
frozen and later deleted.

## Three relations, one word doing too much work

| tier | question | whose truth | instrument |
|---|---|---|---|
| one | does the implementation satisfy the spec? | `VISION.md`, the frozen surface, the operator pages, the MCP protocol | `official-conformance`, the manifest pin, `unit` |
| two | does the port answer the way the Python tree answered? | whatever Python did, **accidents included** | `differential-golden`, `explicit-divergence` |
| three | does it work against the world? | a vendor that still answers, a tokenizer that accepts the bytes, an address that stays closed | `keyless-live`, `keyed-live`, `local-live-fixture`, the capability types and `test/should_not_compile/`, loopback suites |

Tier two is an **equivalence** claim, not a correctness claim: a golden pins that the
port agrees with a recorded answer, and 91 of the 413 goldens pin an answer the port
deliberately disagrees with. It cannot say whether the routing ladder is the right
policy, whether `answer` produces a good report, or whether a vendor still answers the
way a fixture says it did. Its real productivity was during the port: every registered
divergence is a Python behaviour that had to be consciously accepted or rejected
(python's truthiness swallowing a trailing `"; "` in a fallback notice; pydantic
coercing `"0.5"`; atime-as-LRU-clock versus a sidecar clock; the `trafilatura` default).
That use is spent; what tier two does now is refuse silent behaviour change.

## What this port has a witness for, today

| claim | tier | note |
|---|---|---|
| three tools, both transports, the schema enumeration | 1 + 3 | `official-conformance` 90/90 applicable checks; `bin/smoke.expected` transcript |
| SSRF guardrail, grant unforgeability, no raw operation | 1 + 3 | `Policy_net`, abstract `Authority._ t`, fourteen `should_not_compile` diagnostics, loopback listeners. Python is not the reference here |
| the special-token escape pass | 1 | a tokenizer invariant; idempotence and reversibility are property-tested |
| byte and codepoint ceilings, request/response heads | 1 | cost and DoS properties, pinned by `test_http_head`, `test_extract_pool` |
| four keyless provider names, `fetch:local`, `fetch:metadata` | **3** | `freeserp`, `anysearch`, `exa:free`, `parallel:free` — the only names this port has dialled, recorded in `ocaml-docs/live-tests.md` |
| the page-cache on-disk format | 2, as an external requirement | worth pinning against Python-computed digests only because an in-place migration mounts a directory the other binary wrote |
| routing verdicts and every refusal sentence a caller reads | 2 | 21 behaviour rows rest on `unit; differential-golden`. The surface freeze pins the **names**, never the wording — after the freeze the sentences become this port's own contract, with the corpus as their regression net |
| adapter request bodies and verdicts for the eleven keyed names | 2 + fixture | scripted transports plus `differential-golden(provider)`. **No keyed provider has ever been dialled by this port**; `--check` says "untested" in as many words |
| config parsing, wire-model field rules, text semantics, engine ladders | 2 | `unit` plus a corpus area. Three of the text claims are registered divergences, not agreements: the malformed-sequence step, the lone-CR split, the non-printable `repr` |
| health board, usage journal, agent mode, log field sets | **1 only** | `unit`, plus `log_guard` for the log rules. Neither tree has field evidence here |
| the dashboard, the REST projection, the client verbs | 1 + loopback | `test_p8_server`, `test_cli_client`; no socket-level `/healthz` assertion inside `runtest`, and no CLI verb ever run against a live server |

Row-level source: `test/differential/matrix/*.tsv`, which the validator re-reads at
every `runtest` — 21 behaviour rows, 63 config-key rows, 17 provider rows, 16 surface
items. Counted at `38007a0`: 413 goldens (322 agreement, 91 registered divergence);
provider live status 4 `keyless-live`, 6 `keyed-live` and 1 `keyed-live-fixture`
(**the oracle's** live record, not this port's), 4 `untested-in-repo`, 1
`local-live-fixture`.

## What tier two cannot be asked to do

- It cannot validate a feature neither tree ran in production. `answer`, the dashboard,
  the usage journal and the health board were ported to **match**, not to satisfy
  `VISION.md` — `plans/seekwright-ocaml-port.md` §6 says so: *"No rewrite of behavior:
  every milestone must match the Python oracle, not improve on it."* Treat their
  greenness as "unchanged", never as "right".
- It cannot close a divergence after the freeze. Closing one requires re-generating the
  golden and re-writing its row in `test/differential/divergences.tsv`; both need an
  implementation that is no longer in the tree.
- It cannot grow. No new corpus case, no new area, once regeneration is gone.

## The evidence worth buying instead

Cheapest first, and all of it lands the same way — a row in the live-run table in
`plans/seekwright-ocaml-port.md`, the `ocaml_live_tested` flip on the `Registry` row,
and `Cases.recorded_non_provider_runs` for a non-provider case:

1. `agent:brief` and `agent:report` against an operator model endpoint — the whole of
   agent mode currently rests on tier one.
2. One named keyed provider per name you actually operate (`SEEKWRIGHT_LIVE_TESTS=1
   seekwright-live <name>`). This is the only instrument that can tell you an adapter
   still matches its vendor's live shape.
3. `fetch:jina`, `fetch:scrappa`, `fetch:tavily`, `fetch:linkup`, and a `fetch:local`
   run against a page whose shape the `stdlib` reader has not already been measured on.
4. A socket-level `GET /healthz` assertion and a CLI verb run against a live loopback
   server — both named as gaps in `plans/seekwright-ocaml-port.md` §38 and both small.
