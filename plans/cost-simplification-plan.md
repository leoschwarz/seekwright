# Plan: the money path — what is left to simplify

Status: **proposals only; nothing here is landed.** Tree read at `4de7fe2`
(2026-11-17), after the structural pass closed: `plans/duplication-and-simplification-plan.md`
§2 S-001–S-010, its §3 weight rows and decisions D-A … D-G are all in the code,
including the cost rows — `Adapter.cost_for` injection (S-011), the row that
prices everything instead of mirroring the adapter's rule, and `provider_set`
folded into `Providers_build`. This page asks the narrower question the maintainer
raised: **is the cost API still too big, and if so where.** The answer is a split
verdict, and the evidence is in §1.

IDs here are `C-NNN` (cost). They are **not** ledger entries:
`plans/reviews/code_review_ledger.md` is the owner's register and an agent adds
nothing to it.

## 0. How this was measured

The whole vocabulary, not one module. `grep -iE "cost|credit"` over `lib/`,
`bin/`, `test/`, `live/`, `ocaml-tools/` returns 300 lines, concentrated as:
`lib/usage.ml` 71, `lib/factory/registry.ml` 60, `lib/dashboard_html.ml` 46,
`lib/config.ml` 31, `lib/agent.ml` 15, `lib/engine.ml` 11, and 4–11 in each of
fifteen adapter or fallback modules. `lib/usage.ml` owns 12 mutable money fields
and mentions a `priced_*` sample-size counter 23 times; `cost_per_1k` appears 49
times in `lib/` across five different meanings. Everything below is a claim about
one of those sites, named by symbol.

The reading order was: `Factory.Registry` (row → `rate` → `cost_of` → `price` →
`args.cost_for`) → `Provider.http_search` (`~cost_for`, `outcome.cost_usd`) →
`Model`'s `cost_usd` encoder → `Engine` (search record, `Fetch` rung,
`fallback_cost_usd`) → `Usage` (line builders, the three `apply_*` folds,
`fold_days`, `snapshot_unlocked`) → `Agent` (`spent`, `worst_case_model_cost`,
`model_cost`, the ceiling) → the dashboard's money columns.

## 1. Verdict

The **price-decision** half is at its floor and I would defend it. The **money-accounting**
half is where the surface still is, and it is one pattern spelled four times.

|Stratum|Shape today|Verdict|
|---|---|---|
|Price decision|`Registry.row`'s `default_cost : float option` + `cost_model` (`Flat` 13 rows, `Extra_results` 3, `Credit_multiplier` 1), three functions — `rate` (called by `Cli_check` and `Live.Cases`), `cost_of` (called only by `test_provider_registry`), `price = rate ∘ cost_of` (called only by `Providers_build`)|**keep.** Two fields, not one: `default_cost` carries "may the operator override this price" (`None` fixes `exa:free` at zero whatever config says; `Some 0.0` lets `parallel:free` buy the rung if the operator sets a rate) and `cost_model` carries the shape. A merged variant type re-creates that cross product (§5)|
|Adapter seam|`~cost_for : int -> float` in, `outcome.cost_usd : float option` out. No adapter exports pricing since S-011|**keep.** This is the floor|
|Wire|`Model.Search.cost_usd : float option`, `Null` when unbilled; `credits` is off the surface entirely — the only surviving credit word is `Credit_multiplier`, which is the vendor's billing unit inside the row, not ours|**keep**|
|Routing|`Config.mli` states `cost_per_1k … reporting only; nothing routes on it`; `Router` is stdlib-only by `ocamldep` and the free walk runs off `Config.free_providers`|**keep, and keep checked**|
|Accounting|12 money fields over five records, the same "amount + sample size, null when the size is zero" fold written four times, twelve render expressions|**cut — C-001**|
|Fetch boundary|the rung carries a *rate* (`Engine.Fetch.fetcher.cost_per_1k`) that `Engine.fallback_cost_usd` divides by a thousand, while a search's price arrives from the factory as an *amount*|**cut — C-003**|
|Agent money|`worst_case_model_cost` and `model_cost` are one formula written twice; `spent` reads only `Usage.search_cost_usd`, so the `max_cost_usd` ceiling never sees fetch money|**cut — C-004**|

`Config.fetch_fallback.billable` is a hand-typed second statement of
`default_cost <> None`, in all five rows of `known_fetch_fallbacks`, read by one
rule. That is the cheapest real removal in the tree: C-002.

## 2. What may not move

- `ocaml-tools/surface.expected`: 37 usage-journal fields (the three money fields
  `cost_usd`, `cost_usd`, `model_cost_usd` among them), 12 per-provider config
  keys, 49 section config keys over 6 tables. A cut that renames or drops a key
  re-pins the manifest in the same commit and says why.
- The dashboard JSON keys `snapshot_unlocked` writes: `totals.search_cost_usd`,
  `totals.fetch_cost_usd`, `totals.priced_fetches`, `answers.model_cost_usd`,
  `answers.priced_calls`, `answers.token_calls`, per-day `cost_usd`/
  `model_cost_usd`/`fetch_cost_usd`, per-endpoint `cost_usd` and the *derived*
  `cost_per_1k`. `lib/dashboard_html.ml` reads them, and `test_usage.ml`,
  `test_fetch_engine.ml`, `test_fetch_cache.ml` and `test_concurrency.ml` assert
  them. C-001 must not move one byte of this JSON — that is its acceptance test.
- `bin/smoke.expected` and the 72 provider goldens whose projection carries a
  `cost_usd` figure — `golden/provider/03-serper-credits-double.golden` is the
  clearest of them. A cut that changes a reported figure is a re-pin plus a
  sentence in `ocaml-docs/divergences.md`, not a silent promotion.
- `Cli_check`'s per-name `$x.xx/1k` line and `--check --live`'s billed figure —
  the same `Registry.rate` reading, which is the point of the row owning the rule.
- The ladder rule as prose: `ocaml-docs/configuration.md` ("at most one billable
  name, last — the validator reads each row's `billable` flag rather than a
  hard-coded name") and `ocaml-docs/egress.md` (which three fallbacks bill).
  C-002 edits both sentences in the same commit.
- The absent-field rule: an unpriced figure is absent or `null`, never `0.0`.
  `usage.mli` states it; `test_usage.ml`'s `money`/`no_money` helpers hold it.

## 3. The cuts

### C-001 — `Usage` writes the money pattern four times

**Evidence (`read`).** Five records carry money: `day_totals`
(`cost_usd`, `model_cost_usd` + `priced_answers`, `fetch_cost_usd` +
`priced_fetches`), `provider_totals` (`cost_usd`), `provider_day` (`cost_usd`),
`answer_totals` (`model_cost_usd` + `priced_calls`), and `t` (`search_cost_usd`,
`fetch_cost_usd` + `priced_fetches`). The fold is written per kind: `apply_search`
does four `+. cost_usd` assignments across three levels (the line always carries
a figure, so no counter); `apply_answer` and `apply_fetch` each write the
`match money (get … ) with Some cost → total +. cost; priced + 1; bucket.total +.
cost; bucket.priced + 1 | None → ()` block; `fold_days` merges `cost_usd` field by
field. Rendering repeats it twelve times: `endpoint_row` (`round6 totals.cost_usd`
and the derived `cost_per_1k` guarded by `calls = 0`), the empty-day row (`cost_usd
→ Float 0.` but `model_cost_usd`/`fetch_cost_usd → Null`), the day row and the
totals row and the answers block, each writing `if priced_… = 0 then \`Null else
round6 …` by hand. The invariant is prose in `usage.mli` — "Unknown is absent,
never 0.0. A money total covers only the lines that carried a price, and the count
of those travels beside it."

**What it risks.** A fold that forgets the counter renders an unpriced window as
`$0.00`, which is a claim that nothing was billed. It also means the next money
kind (a rerank or embed call, a second model) is five new fields and four new
hand-written render expressions, and each one is a place to get the null rule
wrong.

**Fix.** One record and four helpers, private to `lib/usage.ml`:

```
type money = { mutable total : float; mutable priced : int }

let add  (m : money) (value : float option) : unit  (* None adds nothing, counts nothing *)
let bump (m : money) (value : float) : unit         (* a line that always carries a figure *)
let roll (a : money) (b : money) : unit             (* fold_days, one call per kind *)
let json (m : money) : Yojson.Safe.t = if m.priced = 0 then `Null else round6 m.total
```

`day_totals` then holds `search`/`model`/`fetch : money`; `answer_totals` holds
`model : money` and keeps `token_calls` beside the token totals (that pair is the
same idea over integers and is **not** folded into `money` — it is not money, and
`nearest_rank`/`latency_samples` stay as they are for the same reason). The
snapshot's published sample-size keys (`priced_fetches`, `priced_calls`) are
rendered from the record, so `json` plus a two-field helper is the only place the
"null when the sample is empty" rule lives. Expected: 12 fields → 8 fields in 3
records, four fold blocks → four one-line calls, twelve render expressions → one
helper and its call sites; roughly −40 lines net in `lib/usage.ml`.

**Gate.** No snapshot key, journal field or byte moves: `test_usage.ml`'s money
and `no_money` assertions, `test_fetch_engine.ml`'s `fetch_cost_usd`/
`priced_fetches` pair, `test_fetch_cache.ml` and `test_concurrency.ml` pass
unmodified; `surface.expected` unmoved. Then one **new** assertion the pattern
makes cheap and today is awkward: fold a priced line and an unpriced line into the
same day and check the day renders the figure with its count, and check an
unpriced-only day renders `Null` — the case the four hand-written folds can get
apart.

### C-002 — `Config.fetch_fallback.billable` restates `default_cost`

**Evidence.** `known_fetch_fallbacks` carries both fields for all five rows, and
they agree everywhere: `crawl4ai` `false`/`None`, `jina` `false`/`None`, `linkup`
`true`/`Some 5.00`, `scrappa` `true`/`Some 0.30`, `tavily` `true`/`Some 1.60`.
The field is read in exactly one place — `validate_fetch_fallbacks`'s "at most one
billable rung, and it must be the ladder's last name" — plus `test_config.ml`'s
hand-built row and the frozen-vocabulary case that pins "that list's billable
subset". Nothing else in the tree reads it.

**What it risks.** Two hand-typed facts that must agree. A new priced fallback
with `billable = false` passes the ladder rule in the wrong tier: it may sit
*before* the free rungs while still writing money to the journal, which is exactly
the ordering the validator exists to protect ("a page reaches every free fallback
before a credit is spent").

**Fix.** Delete the field; the validator's `billable name` lookup becomes
`row.default_cost <> None`. That stays true under the operator's
`[fetch] cost_per_1k` correction, because `Fetch_stack.fallback_cost` applies the
correction only where a declared price exists — an unpriced rung stays unbilled
whatever the operator writes. The frozen-vocabulary case pins the **priced**
subset derived from the list instead of a hand-typed `billable` subset, which is
the same fact with one fewer place to be wrong; `AGENTS.md`'s frozen-surface row,
`config.mli`'s record doc, `ocaml-docs/configuration.md`'s ladder sentence and
`ocaml-docs/egress.md`'s "which three bill" line move in the same commit.
Expected: −9 lines in `lib/config.ml`, one fewer field in a public record.

### C-003 — a fetch rung carries a rate; a search result carries an amount

**Evidence.** The search side settles money in the factory:
`Providers_build` hands the adapter `Registry.price row pc`, the adapter reports
`cost_usd`, and `Engine` records what it is told. The fetch side does not:
`Engine.Fetch.fetcher` has `cost_per_1k : float option`, `Fetch_stack.wrap_fallback`
and the local `http` rung fill it from `Fetch_stack.fallback_cost`, and
`Engine.fallback_cost_usd` does `rate /. 1000.` at the journal boundary. Seven
call sites build that record — `Fetch_stack.wrap_fallback`, the local `http` rung,
the stubs in `test_fetch_engine.ml`, `test_fetch_cache.ml`, `test_concurrency.ml`
and `test_agent.ml`, and `test/log_guard/field_sets.ml`'s fixture — and
`test_fetch_ladder.ml` asserts the per-rung rates the factory resolved.

**What it risks.** `cost_per_1k` means five different things in `lib/` (the
`[providers.*]` key, the `[fetch]` key, the rate `--check` prints, the derived
per-1k figure in `endpoint_row`, and this rung field), and the unit of a fetch's
price is a factory decision that the serving path re-derives. A rung that set the
amount instead of the rate would be read by the engine with no arithmetic; a
future price that is not per-1k (a per-page or per-byte reader) has to be hunted
for in `Engine`.

**Fix.** Divide once, where the rate is known: `Fetch_stack.fallback_cost` returns
the per-read amount (`Option.map (fun rate -> rate /. 1000.)`), the rung field is
`cost_usd : float option`, and `Engine.fallback_cost_usd` is deleted — the engine
passes `rung.cost_usd` to `Usage.record_fetch` and knows nothing about money
units. `test_fetch_ladder.ml` asserts the resolved *amounts*, which is the fact
the operator's correction actually controls. Journal bytes are identical (same
division, same key), so no golden moves. Expected: −9 in `lib/engine.ml`, +3 in
`lib/factory/fetch_stack.ml`, seven construction sites renamed.

### C-004 — the agent prices a model call twice, and its ceiling sees half the spend

**Evidence.** `worst_case_model_cost` computes
`max_material_chars / chars_per_token / 1000 * cost_per_1k_in + output_cap / 1000 * cost_per_1k_out`
and answers `0.0` when either rate is unset; `model_cost` computes the same
expression over reported `prompt_tokens`/`completion_tokens` and answers `None`.
Both read the same two `Config.agent_config` fields. `spent` is
`Usage.search_cost_usd` only, and the ceiling check is
`!spent_total +. worst_case_model_cost settings depth > ceiling`. `Fetch` money is
therefore outside the bound: a run whose searches are all keyless and whose keyed
fetch fallback bills (up to `$0.005` a page at `linkup`'s declared price) can pass
a `$0.25` ceiling on paper while the journal records spend the ceiling did not
count. `Usage.search_cost_usd` has exactly one accessor caller — this `spent`.

**What it risks.** Two formulas for one price, on the safety-critical side of the
pair: change `cost_per_1k_in` handling in one and the ceiling stops meaning the
thing the answer line reports. And the operator-facing promise — `max_cost_usd` is
the per-call spend bound — is narrower than it reads.

**Fix.** `token_cost settings ~prompt ~completion : float option` is the one
formula: the worst case calls it with the caps as the token counts and the ceiling
site adds `Option.value ~default:0.0`; `model_cost` goes, and the answer line takes
`token_cost` over the reported `prompt_tokens`/`completion_tokens`. Then
`Usage.search_cost_usd` becomes `Usage.spend t` — search money plus priced fetch
money, both already accumulated — so the bound covers every off-proxy figure the
journal holds. That is a rename, not a new name: the snapshot keeps its
`search_cost_usd` key (the dashboard reads the JSON, not the accessor) and the
accessor count stays at one. `Agent`'s refusal sentence stays the sentence; the
condition it fires on widens. Expected: −8 lines, and a widened bound documented
as a behaviour change.

**Gate.** New permanent case in `test/test_agent.ml`: a retrieval whose searches
are free and whose billed fetch rung pushes the running spend past
`max_cost_usd` is refused with the ceiling sentence — the case today passes
through. Plus one case pinning that a model call with one rate unset still prices
as unknown (`Null` in the answer line), which is what keeps the `Option.value`
default from leaking into the journal. `ocaml-docs/configuration.md`'s
`max_cost_usd` line and `ocaml-docs/privacy.md`'s money wording get one clause
each; `matrix/behaviours.tsv`'s agent row keeps its evidence pointer to the new
case.

### C-005 — `Registry.cost_of` is public for one suite (optional)

`price` is what a build hands an adapter and `rate` is what `--check` and
`Live.Cases` ask; `cost_of` is called only from `test_provider_registry.ml`, which
uses it to test the three shapes apart from the rate resolution. Driving those
cases through `price` with `cost_per_1k` in the config entry covers the same
arithmetic and one less public name (with its doc paragraph) goes. **Recommend
take** — it is −20 lines of interface and prose and the suite loses nothing it
asserts. If the maintainer wants the shape testable apart from the resolution, the
name stays and nothing else here changes.

## 4. Decisions the maintainer owns

**D-H — `[fetch] cost_per_1k` is one number over three prices.** The key corrects
every priced fallback with the same figure, while the declared prices span 16×
(`scrappa` 0.30, `tavily` 1.60, `linkup` 5.00 per thousand). Options: keep it as
"my plan prices all reader calls at one rate"; drop it, so the declared prices
stand and fetch money has no operator lever (asymmetry with the search side, where
`[providers.*] cost_per_1k` exists for precisely this correction); or make it
per-name under `[fetch.fallbacks.<name>]`, which adds keys and a table to the
frozen 49-key count. *Recommend: keep and say so* — one plan, one rate is the
common case, the coarseness is already documented in `config.mli`'s `default_cost`
doc, and the alternatives cost either a promise or keys.

**D-I — whether `max_cost_usd` should count the model call's own worst case twice.**
The check compares search-plus-worst-case-model against the ceiling; after C-004
it also counts fetch money. It does **not** subtract the searches the run already
paid for when a *later* step is gated — it is a per-call bound, re-evaluated per
step, which is what `test_agent.ml`'s existing ceiling case pins. Keep.

## 5. Checked and deliberately left alone

- **`Registry.cost_model`'s three variants.** They could be one `int -> float`
  closure per row (−1 type, −2 constructors, ~15 lines). Declined: the variants are
  data, which is what `ocaml-docs/egress.md` and `Cli_check` talk about, and the
  row's whole purpose is that the rule is not hidden in a closure. `Flat` covers
  13 names; the two non-default shapes cover four rows.
- **Merging `default_cost` into `cost_model`.** Would have to re-express the
  difference between `exa:free` (price fixed at zero, `default_cost = None`) and
  `parallel:free` (rung priced at zero but buyable by an operator's `cost_per_1k`),
  i.e. the cross product the two fields already separate cleanly.
- **Two homes for `default_cost`** (`Factory.Registry` rows and
  `Config.known_fetch_fallbacks`): same word, different vendor product —
  `lib/config.ml` says the Linkup reader is priced at the `v1/fetch` rate "not the
  [linkup] search row's higher one" and Tavily's extract is "a fifth of the
  [tavily] search row's". Unifying them would invent a number no vendor bills.
- **`cost_usd` on the search result and money in the journal.** The product: the
  caller chose `max_results`, the proxy chose the name, and `max_cost_usd` is the
  only spend control. It is a frozen surface row, and 72 provider goldens carry the
  figure in their projection.
- **`cost_per_1k` as a derived display figure in `endpoint_row`** (spend ÷ calls ×
  1000). Same word as two config keys, but it is a *reading*, not an input; the
  dashboard column needs it and the alternative is a second name for the same
  unit, which is worse.
- **`answer_totals.token_calls` beside the token totals.** Same sample-size idea as
  `money`, over integers; folding it into `money` would type tokens as money.
  C-001 leaves it.
- **`credits`.** Already gone from the wire and the adapters; `Credit_multiplier`
  survives as Serper's billing shape inside the row, and `cost_of`'s
  `Credit_multiplier` branch deliberately matches the vendor's own arithmetic.

## 6. Landing order and verification

|Order|Step|Expected effect|
|---|---|---|
|1|C-002 `billable`|smallest, and it removes a field a public record advertises. Two doc sentences and the frozen-vocabulary case move with it|
|2|C-001 `money`|the big one; accepted only if the existing money assertions pass unmodified, plus the new priced/unpriced pairing case|
|3|C-003 the rung's amount|`Engine` loses its last money arithmetic|
|4|C-004 the agent price and the widened ceiling|the only behaviour change in the set, so it lands last and alone|
|5|C-005 `cost_of`|optional, last|

Every step ends on the four gate targets — `dune build @fmt`,
`dune build @install`, `dune runtest --force`, `dune build @doc` — and each
step's claim is exercised, not only asserted:

- C-001: run `_build/install/default/bin/seekwright` with `[dashboard] history_path`
  set, drive one priced and one unpriced call, read `/dashboard/data`, then restart
  and read it again — `apply` is one dispatcher the live record and the journal
  reload both feed, so a day that renders `Null` after a restart rendered `Null`
  while it was live.
- C-003: `--check`'s money column and one REST `POST /api/v1/fetch` against a
  loopback fallback listener, comparing the recorded `cost_usd` before and after.
- C-004: one `answer` call against a loopback model and a loopback keyed reader,
  with the ceiling set between the two figures, observing the refusal sentence.

After this page is landed, the money vocabulary in `lib/` is: `default_cost` and
`cost_model` (one row each, search and fallback), `cost_for` (the adapter seam),
`cost_usd` (result, journal, aggregates), `cost_per_1k` (two operator keys and one
derived display figure), `spend` (one accessor), `max_cost_usd`, `cost_per_1k_in`
and `cost_per_1k_out`. That is the floor for a proxy that bills fifteen vendors and
reports a dollar figure to both a model and a dashboard; below it sits a feature
cut, not a simplification, and `plans/` is where that would be argued.
