# Plan: the 2026-11-16 code-quality findings

Status: **design only.** No `lib/`, `bin/` or `test/` file was modified, no commit
made. The findings are registered in `plans/reviews/code_review_ledger.md` as
R-001…R-011; this is the plan they point at — one section per ID, plus the order to
land them in.

Tree read at `38007a0`. Baseline: `dune build @install` exits 0 against the cached
`_build`; `dune runtest --force` was **not** run this session (the previous session's
run held the build lock 22 minutes, 21 of them inside `test_drain.exe`).

Files read for this plan, with the oracle beside them where the finding is about a
fact rather than a shape: `lib/factory/fetch_stack.ml`, `lib/factory/providers_build.ml`,
`lib/factory/registry.ml`, `lib/factory/provider_set.ml`, `lib/config.ml` (the
`fetch_fallback` rows), `src/seekwright/fetcher.py` (`Fallback`, `KNOWN_FALLBACKS`,
the three priced fetchers), `lib/caps/registry.ml` + `.mli`, `lib/caps/server.ml`,
`lib/cli/cli_serve.ml` + `.mli`, `lib/server.ml` (`serve_http`, the surface data),
`lib/server.mli`, `bin/main.ml`, `lib/fetch/fetcher.ml` (`validate_url`, the hop
loop), `lib/fetch/remote_target.ml`, `lib/fetch/fallback*.ml`/`.mli`,
`lib/fetch/extractors/stdlib.ml`, `lib/fetch/tabledoc.ml`, `lib/engine.ml`
(`read_page`, `try_fallbacks`), `lib/engine.mli` (`Cache`), `lib/usage.ml`,
`lib/cli/cli_metrics.ml`, `lib/providers/{linkup,parallel,deepseek,freeserp}.ml`,
`test/{test_registry,test_p8_server,test_boot,test_fetch_ladder,test_usage,test_remote_target,test_fallback_scrappa,test_fallback_tavily}.ml`,
`test/fetch_support/fallback_fixtures.ml`, `test/corpus_html/*`, `ocaml-tools/surface.ml`.

## 0. Verdicts

Nine of the eleven are real and worth fixing; two are real but bounded, and the
earlier style review already weighed the same idiom and said so. None of the
severity ratings is above MEDIUM: nothing here answers wrongly today, and the two
findings that name a quadratic cost sit behind a config or protocol bound.

| ID | Filed as | Verdict | Sev | After the fix, one owner for… |
|---|---|---|---|---|
| R-001 | `run_stdio`/`run_http` duplication, `cli_serve.ml` × `server.ml` | **half refuted.** No `run_stdio` exists, and never did: `git log --all -S"run_stdio"` is empty across every ref. The named `server.ml` range is the frozen-surface data (`rest_routes`, `operational_routes`, `server_flag_table`) at HEAD and at `606dbaa`. `Server.serve_http` has been the single listener owner since `2298223`. What survives is inside `Cli_serve`: two wrappers, one serve call written twice | LOW | the serve call and the close-on-exit protect |
| R-002 | quadratic append in the capability registries | real, bounded at three tools | NIT | (idiom) |
| R-003 | fallback prices hardcoded outside the registry | real; three prices, two other spellings of the same fact elsewhere | MEDIUM | a fallback's declared price |
| R-004 | quadratic ladder assembly | real, bounded at three rungs (five registry names); the shadowed binder is the worse half | LOW | — |
| R-005 | duplicate fetch fallback match arms | real: the gates and the grant prologue are written three times | LOW | the gates + grant prologue |
| R-006 | redundant URI parse in the fetch preflight | real, but mis-diagnosed: the cost is not the parse. Two parsers answer "which host", and one refusal sentence has three owners | MEDIUM | the URL gate (validate → host → public vet) |
| R-007 | duplicate match arms in the provider builder | real, one accumulator apart | LOW | — |
| R-008 | linear HTML entity lookup | real: 274 entries scanned per prefix attempt; a trie is not the answer, a hash table is | LOW | (unchanged: the two source lists) |
| R-009 | Hinnant `civil_from_days` copied | real, and worse than filed: six copies of the arithmetic, two of `days_from_civil`, four of `days_since_epoch` | MEDIUM | civil-date arithmetic |
| R-010 | quadratic append in the fixture request log | real, test-only, one request per case today | NIT | — |
| R-011 | quadratic field insertion in `Usage` | real, bounded by `keep_days`/`runs_max`; measure before rewriting | LOW | — |

## 1. What may not move

- **The frozen surface.** Nothing in this plan changes a tool, a route, a flag, a
  provider name or a config key. `ocaml-tools/surface.ml` prints config keys from
  `config.mli`'s `t`, `fetch_config`, `search_config`, `logging_config`,
  `policy_config`, `agent_config`, `dashboard_config` and `provider_config` records;
  R-003's new field
  goes on `Config.fetch_fallback`, which is a *registry row* and is not one of those
  records, so `ocaml-tools/surface.expected` does not move.
- **The library direction.** `mcp-caps → seekwright → seekwright.providers /
  seekwright.fetch`, with `seekwright.text` and `seekwright.wire` as the stdlib-only
  floor under both big libraries. Consequences that bind two findings: a module
  shared by `lib/`, `lib/providers/` and `lib/cli/` can only land on that floor
  (R-009), and `Config` — which lives in `seekwright` — can never hold a builder
  closure over a `Seekwright_fetch` module, so R-003 can move the *price* onto the
  registry row but the *builder* stays in `seekwright.factory`. Python's
  `KNOWN_FALLBACKS` row carries `build`; the port's cannot, and that is the
  direction, not an oversight.
- **The URL guard stays per-hop and per-rung.** `Fetcher.fetch` re-validates each
  redirect hop, and every remote rung re-runs `Remote_target.check` (a fresh DNS
  answer, so a rebinding window stays closed); `engine.mli`'s `Cache.preflight`
  documents that the guard runs "before any lookup even with a warm entry". R-006
  gives that gate **one owner**; it never caches its answer.
- **The oracle's sentences and figures.** `"URL has no host"` (pinned by
  `test/differential/golden/fetch/10-url-no-host.golden`), the ladder prices
  (`test_fetch_ladder`'s `cost_per_1k` checks), and the `%Y-%m-%d…` forms are a
  contract with `docs/reference/providers.md` and the goldens. Moving a fact to a
  new owner is a refactor; rewording it is a surface change and does not belong in
  these commits.
- **No new dependency.** The civil-date arithmetic stays hand-written: the decision
  ("`civil_from_days`, no timezone library") is recorded in
  `plans/seekwright-ocaml-port.md`. R-009 moves the arithmetic, it does not buy it.
- **Warning-as-error policy is ambient dune default.** Two fixes drop a binder or an
  accumulator, which is where warnings 26/27/32/69 bite; each of those steps deletes
  the now-unused name in the same commit rather than `_`-renaming it.

Per-suite runs: `dune build test/<name>.exe && ./_build/default/test/<name>.exe`
(`dune exec` re-roots the CWD and breaks suites that read repo files). Suites that
read the checkout — `test_p8_surface`, `test_metadata`, `test_provider_registry`,
the `test/corpus_html` rules — need `dune runtest`.

## 2. Order of work

| # | Commit line | Findings | Depends on |
|---|---|---|---|
| 1 | `fetch: one owner for the URL gate` | R-006 | — |
| 2 | `factory: the fallback rows carry their price` | R-003, R-004 | — |
| 3 | `factory: one prologue for the keyed fetch fallbacks` | R-005 | 1 |
| 4 | `factory: one recursive step in build_providers` | R-007 | — |
| 5 | `time: civil-date arithmetic on the floor` | R-009 | — |
| 6 | `fetch.stdlib: a hash table for the entity table` | R-008 | — |
| 7 | `cli: one serve call; stdio closes providers` | R-001, D3 | — |
| 8 | `caps: prepend, reverse once` | R-002 | — |
| 9 | `test: prepend the fixture's request log` | R-010 | — |
| 10 | measure, then decide: `Usage`'s field sets | R-011 | — |

Commit 3 goes after 1 because its prologue calls the gate 1 just gave a single
owner. 10 is last because it is a measurement, not a patch.

---

## R-001 — the CLI's HTTP runner writes its own wrapper twice

**Refuted as filed.** There is no `run_stdio` in this repository's history
(`git log --all -S"run_stdio"` — empty), and stdio is one expression in `bin/main.ml`
(`Mcp_kit_stdio.run_channels server stdin stdout`). `Server.serve_http` is the only
listener implementation since `2298223` ("server: stop, drain and close the listener
under one owner"); the `lib/server.ml` range the finding names is the frozen-surface
data. The entry stays in the ledger because the question was asked, and because the
residue is real.

**What is real.** `Cli_serve` has three functions for one job. `run_with_signals`
and `run_with_stop` each write the same
`Server.serve_http ~env ~sw ~log app server ~host ~port ~stop ~grace_seconds ()`
call inside a `Fun.protect ~finally:… close ()`, and the nine-labelled-argument
list is written four times (both wrappers, `run_http`, and `cli_serve.mli`'s
signature, which restates `Server.serve_http`'s).

**Fix.** One partial application inside `run_http`'s scope. Both wrappers are
top-level today, so they nest inside `run_http` to share it; `cli_serve.mli` exports
only `run_http`, so the move is invisible outside the module:

```ocaml
let serve ~stop =
  Server.serve_http ~env ~sw ~log app server ~host ~port ~grace_seconds ~stop ()
```

`run_with_stop` becomes
`Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> close ())) (serve ~stop)`;
`run_with_signals` keeps its self-pipe, handler and watcher join, and passes the same
`serve ~stop` to its own `Fun.protect` whose `finally` stays the whole
`Eio.Cancel.protect` block — `try_resolve resolve_abort`, join the watcher, then
`cleanup ~restore ~read_end ~write_end ~close`. The `Eio.Cancel.protect` shields are
load-bearing and must survive the rewrite: under fiber cancellation an unprotected
finally is itself cancelled and `close` would not run, which is exactly what
`test_drain`'s cancellation-re-raise and close-exactly-once cases pin. One serve call,
one protect shape per path, the argument list written once. `cli_serve.mli` is
unchanged — it already promises "[close] once on exit", which is what the change
preserves.

**Verification.** `test_drain` is the pin: it drives a stop promise it fills itself,
counts `close` calls to prove "exactly once", and checks `Drained` vs `Grace_expired`
and that fiber cancellation re-raises. `test_binary_drain` covers the signal path
through the real binary. Both are slow suites; run them once, not per edit.

**Adjacent, decided (D3): stdio closes providers too, in this commit.** The stdio
path never runs `close_providers`, while the HTTP path does. That is not invisible:
`Mcp.aclose` issues a best-effort DELETE to terminate the remote MCP session
(`mcp_client.mli`), so the sessions `exa` and `parallel`'s keyed half warm up at boot
linger on the provider's endpoint until its own timeout. `bin/main.ml`'s `run_server`
calls `close_providers built ()` after `Mcp_kit_stdio.run_channels server stdin
stdout` — `~env`/`~sw` are still live at EOF, so the DELETE can fire. Most adapters'
`aclose` is `()`, so the call is cheap. See §3 D3.

## R-002 — `Registry.add` and `Server.of_registry` append

**Evidence (`read`).** `Registry.add` returns `Ok (registry @ [ entry_of tool ~grant
])`; `Server.of_registry` folds `Ok (tools @ [ tool ])` over `Registry.entries`.
Both lists top out at the three tools of the frozen surface, so the cost is nil;
this is the same idiom `plans/reviews/2026-11-12-style-review.md` L3 already filed
as *[different]* — "with at most seventeen provider names this is style, not cost".
It is worth landing for `mcp-caps`'s sake, not seekwright's: the package's pitch is
that other servers build on it.

**Fix.** `registry.mli` already declares `type t` abstract and promises
`entries : t -> entry list` "in registration order", so the reversal is internal:
`add` conses `entry_of tool ~grant :: registry`, `entries` returns `List.rev
registry`, and `find`/`add`'s duplicate scan are order-agnostic. Add one line of
comment naming the storage order, because it is the constraint `entries` exists to
undo. In `Server.of_registry`, fold by consing and `List.rev` once before `add_all`.

**Pins that make this a behaviour change if done wrong.**
`test_p8_server.registry_lists_the_three_tools` checks `[ "search"; "fetch";
"answer" ]` as *registration order*, and `tools_list_advertises_the_freeze` checks
the same order over the wire, so mcp-kit's `add_tool` order is observable.
`test_registry` (`duplicate_names_are_refused`, `grants_do_not_leak_between_tools`)
and `test_server` cover the registry itself.

## R-003 — three fallback prices live in a `match` in the factory

**Evidence (`read`, `oracle`).** `Fetch_stack.fallback_price` answers `"scrappa" →
Some 0.30`, `"tavily" → Some 1.60`, `"linkup" → Some 5.00`, `_ → None`. The registry
that owns everything else about a fallback — `Config.known_fetch_fallbacks`, whose
rows carry `name`, `billable`, `endpoint`, `fetch_key` — carries no price, and no
`Fallback_*` module declares one. `build_fallback` has already resolved the row
before it dispatches on the name, so the row is in hand and the price is looked up
by name a second time. `fallback_cost` then calls `fallback_price` twice, once to
test whether the name is priced at all.

Oracle: `src/seekwright/fetcher.py` declares the figure on the fallback class —
`ScrappaFetcher.cost_per_1k = 0.30`, `TavilyFetcher = 1.60`, `LinkupFetcher = 5.00`,
`None` for the two free ones — and `_build_*` overrides it with
`fetch.cost_per_1k`. `docs/reference/providers.md` owns the prose and the vendor
tables those figures come from.

**Fix.** Widen the row type rather than inventing a new home:

```ocaml
type fetch_fallback = {
  name : name;
  billable : bool;
  endpoint : string option;
  fetch_key : string option;
  default_cost : float option;  (** the price the journal records; [fetch.cost_per_1k] corrects it *)
}
```

Rows: `crawl4ai` and `jina` → `None` (nothing was billed — the same reason the
local reader answers `None` and not `0.`), `scrappa` → `Some 0.30`, `tavily` →
`Some 1.60`, `linkup` → `Some 5.00`. Landed as: each priced row carries a
one-line comment naming the vendor product the figure belongs to and the
`lib/factory/registry.ml` search row it is *not* — the `providers.md` the finding
named is no longer in this tree, so the provider row beside it is the prose
owner, and the `[None]`-is-unbilled fact lives once, on the `.mli` field. Then:

```ocaml
let fallback_cost config (row : Config.fetch_fallback) =
  match row.Config.default_cost with
  | None -> None
  | Some declared -> Some (Option.value ~default:declared config.Config.fetch.Config.cost_per_1k)
```

`fallback_price` is deleted. Behaviour is identical: today the operator's
`fetch.cost_per_1k` override applies only to a priced name, and that stays true —
`None` rows still yield `None`.

**Breakage the widening causes.** `fetch_fallback` is concrete in `config.mli`, so
every literal row must add the field: the five registry rows above and
`test_config.ml`'s `priced_elsewhere` — the test-only extra row that proves
unknown-name refusal, which takes `default_cost = None`. `ocaml-tools/surface.ml`
does not scan `fetch_fallback`, so `surface.expected` does not move (§1).

**Verification.** `test_fetch_ladder` is the pin and it already asserts the figure:
`"the price the fallback declares"` → `[ Some 0.30 ]`, the corrected ladder →
`[ Some 0.20 ]`, and the free ladder → `[ None; None ]`. Run it plus
`test_cli_check`/`test_cli_metrics` (the `--check` report reads the same rows) and
`dune runtest test` to confirm no `.expected` moved.

## R-004 — `build_ladder` appends

**Evidence (`read`).**
`Ok Some fetcher -> Result.map (( @ ) [ fetcher ]) (build_ladder rest)` rebuilds the
accumulator per name. Bounded: `fetch.fallback` may name each registry member at
most once and at most one of them billable (and it last), so the list is at most
three rungs today — the two free names plus one billable — out of five registry
names. The worse half
of the line is that the binder `fetcher` shadows the local reader's `fetcher` from
`build_fetch_stack`, which is the name the same function uses for the primary route.

**Fix.** Fold with the tree's one `Result` idiom (`let ( let* ) = Result.bind` is
already bound in this module), consing, and reverse once; rename the inner binder
`rung`:

```ocaml
let build_ladder names =
  let* acc =
    List.fold_left
      (fun acc name ->
        let* acc = acc in
        match build_fallback ~sw ~net ~mono_clock ?audit config name with
        | Error message -> Error message
        | Ok None -> Ok acc
        | Ok Some rung -> Ok (rung :: acc))
      (Ok []) names
  in
  Ok (List.rev acc)
```

The error short-circuit and the skip-unbuilt rung both survive.

**Verification.** `test_fetch_ladder` (name order is `fetch.fallback`'s order, and
a gate that does not build a name must drop it from the middle of the list),
`test_fetch_cache`, `test_fetch_engine`, `test_grant_timeouts`.

## R-005 — three arms, one gate

**Evidence (`read`).** `build_fallback` matches `"jina"`, `"crawl4ai"`, `_`. Each
arm re-derives the same prologue: the permission gate (`Config.is_permitted`;
crawl4ai's is documented as none because its host is the operator's own config), the
key gate (`keyed ()`, empty string = absent), the endpoint
(`Provider.policy_of_uri (Uri.of_string (Option.value ~default:"" row.Config.endpoint))`
— written twice verbatim, and once more with the crawl4ai URL), the
`Float.max fetch.timeout_seconds 30.0` floor (twice in one arm),
`Grants.grant_of_endpoint`, `Remote_target.make net`, `Fallback.of_grant grant`, and
`wrap_fallback name (fallback_cost …)`. Inside the keyed arm, three config records
differ only in Tavily's extra `timeout_seconds` — which is the *vendor's* body
parameter, clamped to 1–60 inside `Fallback_tavily`, not the grant timeout; the two
floors share a literal and a name and mean different things.

**Fix, step A (landed).** One `grant_and_target ~sw ~net ~mono_clock ?audit config
row` — the row endpoint through `Provider.policy_of_uri`, the grant on it, and the
target — shared by the keyed rungs and by `jina`, which is keyless and so takes the
prologue without the key gate. Both floors are named: `grant_floor` is the rung's
grant timeout, `tavily_body_floor` is the vendor's own body parameter, so they no
longer share a literal. In the keyed arm the gates sit above the dispatch —
permission, then key, then the prologue — and the `match built with Some … | None`
scaffolding is gone. The dead `| _ -> None` is gone too, but not by trusting the
row lookup: a string match cannot be exhaustive, so the keyed names go through one
`keyed_vendor` table that returns a closed polymorphic variant, and the
record-construction match is exhaustive over that variant with no fallthrough — a
keyed row added later fails to compile until its arms are written. `keyed_vendor`'s
own `None` answers *before* the prologue runs, so a registry row with no builder
costs no grant; that is the only skip left, and it is what the old code did.
`crawl4ai` keeps its own shape: the operator's `fetch.crawl4ai_url`,
`crawl4ai_timeout_seconds`, no permission gate and no key gate, the exemption the
evidence above records. Behaviour and the refusal order are unchanged: an
unpermitted or unkeyed name is still `Ok None`, an unknown name is still the
registry's `supported:` sentence.

**Fix, step B (deferred — D2).** A per-name builder *table* at module level
— the shape `lib/factory/registry.ml`'s rows already have (`~endpoint`,
`~default_cost`, `~build`) — is not expressible today, and the reason is recorded in
the branch skill: an Eio flow record is parameterised by the backend's resource tag
and cannot carry an existential. `Remote_target.t` *is* `'tag Eio.Net.t`, so every
`Fallback_*.config` carries a tag parameter that exists only to let
`Remote_target.check` reach `Policy_net.vet_public_host`. Erasing it — handing each
fallback an injected guard `check : string -> (string, string) result` built once by
the factory — makes the vendor records tag-free, lets the builder table sit beside
the row it describes, and deletes `fallback_fixtures.ml`'s scripted resolver, which
exists today only because the fixture must answer a DNS lookup the guard performs.
That is a design change with a test-visible payoff, not a mechanical one; it is
listed as an option rather than slipped into commit 3.

**Verification.** `test_fetch_ladder` (both gates, per name), `test_fetch_grant` and
`test_grant_timeouts` (the grant each fallback gets), `test_fallback_{jina,crawl4ai,
scrappa,tavily,linkup}`, and after step B `test_remote_target` plus those five again.

## R-006 — the URL gate has three owners

**Evidence (`read`).** `Fetch_stack.preflight_of` runs `Fetcher.validate_url` and
then `Caps.Policy_net.vet_public_host ~host:(Uri.host (Uri.of_string validated))`.
`Remote_target` already owns exactly that pair: `host_of` (with the comment that
states why the URI library's host is the right answer once `validate_url` has refused
the shapes a parser could get wrong) and `check`, which validates, takes the host and
vets. So the gate is written twice, and `"URL has no host"` is spelled in three OCaml
places — `Fetcher.validate_url`, `Remote_target.check`, `preflight_of` — plus the
oracle's `fetcher.py`, with the golden `10-url-no-host` pinning the sentence.
`Fetcher.validate_url` itself already parsed a host and threw it away, returning only
the canonical string.

The parse is not the cost: `Fetcher.fetch` parses again anyway to dial, and a fetch
already did a DNS vet. What the duplication risks is a divergence — the preflight's
answer to "which host does this URL name" and the vetting answer would no longer be
one reading.

**Fix.** One entry point in `Remote_target`:

```ocaml
val vet : net:_ Eio.Net.t -> private_web_allowed:bool -> string -> (string, string) result
```

validate → `host_of` → `Policy_net.vet_public_host`, skipped only when
`private_web_allowed` (the local reader's grant honours `fetch.allow_private_addresses`;
the remote rungs never do — the comment in `check` says why, and that comment moves
to `vet`). `check net raw` becomes `vet ~net ~private_web_allowed:false raw`, and
`preflight_of` becomes that call with the refusal mapped into
`Engine.Fetch.Url_blocked` — its own `Uri.of_string`, its own host branch and its own
copy of the sentence all deleted. `host_of` stays unexported. The sentence
`"URL has no host"` ends with **two** owners, not one: `Fetcher.validate_url` keeps
its copy (the per-hop gate inside `Fetcher.fetch`) and `vet` keeps the `host_of`
branch's; only `preflight_of`'s third copy is deleted. Do not delete `validate_url`'s
— the per-hop refusal the `10-url-no-host` golden pins reads it.

**Not fixed, deliberately.** `Fetcher.fetch` re-validating hop 0 that preflight
already validated, and each rung re-vetting the same URL: those are the redirect
chain and the time window, and `engine.mli`'s `Cache.preflight` documents that the
guard runs before a warm lookup precisely so a cached entry cannot be a bypass.

**Verification.** `test_remote_target` (the gate's two refusal sentences),
`test_fetch`'s URL-gate cases, `test_fetch_cache` (preflight refusals before a warm
entry), and the `10-url-no-host` golden. Then `dune runtest test` so
`test/differential` re-checks the fetch goldens.

## R-007 — `Providers_build.go` repeats itself for one accumulator

**Evidence (`read`).** After `produce args`, two arms differ only in that one conses
`(name, warmup) :: warmups`.

**Fix.** Bind once and call `go` once — a `let`, not a one-arm `match`:

```ocaml
let adapter', warmup = produce args in
go ((name, adapter') :: built)
  ((name, Registry.probe_spec row) :: table)
  (adapter.endpoint :: endpoints)
  errors unsupported
  (match warmup with Some w -> (name, w) :: warmups | None -> warmups)
  rest
```

Order-preserving by construction, which matters: `test_boot` checks
`List.map fst built.Factory.warmups` against `[ "exa:free"; "parallel:free" ]`, i.e.
registration order, and the same list is `List.rev`'d at the end of `go`.

**Verification.** `test_boot`, `test_routing_sets` (four `warmups = []` checks),
`test_provider_registry` (the `warmups` the session-carrying rows must hand out),
`test_grant_wiring`.

## R-008 — the entity table is an association list

**Evidence (`read`, counted).** `Entity` lookup in `charref_at` is
`List.assoc_opt key entity_table`, where `entity_table` is 274 pairs: 98
`legacy_entities` in both the `name` and `name;` form, plus 78 `extended_entities` in
the semicolon form. `convert` runs per data run, and `charref_at` retries the lookup
for every prefix of the name run, from `len - 1` down to 2 — a page full of `&` in
URLs pays a few thousand string comparisons per ampersand, each attempt allocating a
substring.

Verified for the swap: **all 274 keys are distinct and no name appears in both
lists**, so a keyed table cannot diverge from `List.assoc_opt`'s first-wins choice.

**Fix.** Build the table once at module init from the same two source lists — a
`Hashtbl string int` (or `Map.Make (String)`, if a purely functional table is
preferred) behind one private `lookup : string -> int option`, and leave the
algorithm exactly as written: whole name, then longest prefix down to two
characters. A trie buys nothing here: `name_run` caps a name at 32 characters, so the
prefix loop is ≤ 31 O(1) lookups either way.

**Verification.** This is the one finding with a byte-exact pin already in the tree:
`test/corpus_html`'s `entities_soup.html` fixture feeds `entities-soup`, whose
`parity/port-stdlib.txt` digest is recomputed by
`digest_cases.exe --check-parity` and whose bar carries `bar_max_ms: 25`. Before
deleting the association list, a throwaway script should assert old and new agree on
every table key, every prefix of every key, and the corpus's wrong-form references;
the permanent pin is the corpus digest, and the differential script is not kept.

## R-009 — civil-date arithmetic, six times

**Evidence (`read`, md5-probed).** Four byte-identical copies of `civil_from_days`
in `Providers_linkup`, `Providers_parallel`, `Providers_deepseek` and
`Providers_freeserp` (identical to each other); `Usage.civil_from_days` is the same
algorithm with drifted spelling — type annotations, `d`/`m`/`y` binders, extra
parentheses — and `Cli_metrics.civil_of_secs` inlines the era/doe/yoe/doy/mp
arithmetic with underscore literals. The drift has already happened, which is what
the floor library prevents. `days_from_civil` exists twice (`Usage`, `Cli_metrics`);
`days_since_epoch` — Int64 floor division by 86400 — four times (the adapters only),
with float-floor variants `Usage.days_of_secs` and `Cli_metrics`'s integer
`(secs - 86_399) / 86_400`. All copies agree semantically today, which is why nothing
has gone wrong; the decision they implement (Hinnant's algorithm, no timezone
library) is recorded in `plans/seekwright-ocaml-port.md`.

**Fix.** A third stdlib-only floor library, following the precedent the tree already
set twice: `seekwright.text` and `seekwright.wire` exist because the two big
libraries may not link each other, and `lib/wire/dune`'s comment says so. A module
inside `lib/` cannot be reached from `seekwright.providers`, and `(include_subdirs
…)` is not available beside the existing stanzas, so `lib/time/` gets its own:

```
(library (name seekwright_time) (public_name seekwright.time))   ; stdlib-only
```

`lib/time/civil.ml` (+ `.mli`) with: `days_from_civil`, `civil_from_days`,
`days_of_secs`, `date_of_days`, `date_of_string`, `iso_utc_seconds` for
`%Y-%m-%dT%H:%M:%SZ`.

`days_of_secs` is the one signature decision. The floor rule survives in three type
spellings today: `Usage.days_of_secs` (`float -> float`), the four adapters'
`days_since_epoch` (`float -> int` via `Int64.div` plus a `rem` correction) and
`Cli_metrics`'s inline `(secs - 86_399) / 86_400` (`int -> int`). The canonical is
`int -> int`, the exact floor division `if secs >= 0 then secs / 86_400 else
(secs - 86_399) / 86_400`; the float callers floor to whole seconds first
(`int_of_float (Float.floor secs)`) and the adapters' `Int64` path collapses onto it,
because epoch seconds across the range the suites exercise (pre-epoch to year 9999)
are exact in float. The `Int64` spelling was belt-and-braces, not a range
requirement. Then:

- `Usage`: keep `utc_date`, `civil_of`, `iso_utc_full` and the microsecond spelling
  on top of `Civil.civil_from_days`; drop the two arithmetic functions. `Usage`'s
  journal day-key rules (the prune compares the `YYYY-MM-DD` string) stay where they
  are — they are a `Usage` rule, not calendar arithmetic.
- the four adapters: `format_utc`/`after_date`/`published_from` become one call each;
  their `days_since_epoch` disappears with `Civil.days_of_secs`.
- `Cli_metrics`: `civil_of_secs` and `days_from_civil` fold onto the same module.

Wiring: add `seekwright.time` to `lib/dune`, `lib/providers/dune`, `lib/cli/dune`
(and `test/dune`/`test/differential/dune` where a suite names it). A sublibrary of
the `seekwright` package adds no opam dependency, but `dune build @install`
regenerates `seekwright.opam` — commit the diff if it moves, never hand-edit.
`test/router_dependencies.expected` does **not** move: `test/dune`'s ocamldep rule
globs `../lib/*.ml` with `-I ../lib`, so a module in `lib/time/` is invisible to it
(the pin already carries no `text`/`wire` lines for the same reason), and qualified
`Seekwright_time.Civil` references do not resolve under that include path. Run
`dune runtest test` and promote only if it diffs; extending the rule to cover the new
floor is a separate decision, not part of this commit.

**Verification.** `test_usage` (day buckets, ISO stamps, the prune),
`test_linkup`/`test_parallel`/`test_deepseek`/`test_freeserp` (the `fromDate`/`after`
request fields), `test_cli_metrics`. Plus a throwaway differential — the new module
against each deleted copy over pre-epoch, leap-day, 2100-03-01, year 9999 and the
Int64-vs-float floor boundary — because equivalence of six hand copies is exactly
what this change must not lose; the script is not kept, the suites are the pin.

**Landed, with one difference the plan did not predict.** The floor exports
`days_from_civil`, `civil_from_days`, `whole_seconds` (the float-to-whole-second
floor `Usage` and three adapters would otherwise repeat), `days_of_secs`,
`seconds_of_day`, `date_of_days`, `date_of_string` and `iso_utc_seconds` for the
`%Y-%m-%dT%H:%M:%SZ` form. `Usage`'s `+00:00` spellings and its microsecond rule
stay in `Usage` — they are journal forms, not calendar arithmetic — and
`Linkup.format_utc` stays in `linkup.mli`, aliased to the floor's stamp, because
`test_linkup` pins that name. The differential ran the new module against every
deleted copy over 6 million consecutive days, a date corpus (leap days,
1900-03-01, 2100-03-01, year 9999, the epoch) and an instant corpus across the
floor boundary: **the calendar arithmetic agreed everywhere; the day bucket did
not.** The adapters' `days_since_epoch` branched with `Int64.succ` where
flooring a negative count needs `pred`, so a pre-epoch instant landed on the
wrong day *and* got a negative seconds-of-day: `format_utc -1.` answered
`1970-01-02T-24:00:-1Z`, while its own comment claimed pre-1970 was handled. The
canonical `days_of_secs` floors, so this commit fixes that latent bug instead of
moving it, and `test_linkup` now carries the case the six copies failed
(`1969-12-31T23:59:59Z`).

## R-010 — the fixture's request log

**Evidence (`read`).** `Fallback_fixtures.record` does `t.requests <- t.requests @ [
…]`. Every consumer pattern-matches `[ only ]` (`test_fallback_scrappa.request_shape`,
`test_fallback_tavily.timeout_clamp`), so today's list length is one; the tree already
prepends in the sibling fixture, `test_mcp_client`'s `state.requests <- recorded ::
state.requests`.

**Fix.** `record` conses; `requests` returns `List.rev t.requests`, so
"the requests this fixture saw, in the order they were sent" survives a case that
issues more than one — the phrasing is the differential projection's own. Keep the
`mutable requests` field (warning 69 bites a `mutable` field nothing assigns, not one
assigned differently).

**Verification.** `test_fallback_{jina,scrappa,crawl4ai,tavily,linkup}` and
`test_remote_target`.

## R-011 — `Usage`'s field sets: measure, then decide

**Evidence (`read`).** `Usage.ensure` appends `fields @ [(key, created)]`; `Usage.set`
walks the list (`List.mem_assoc`), rebuilds it whole (`List.map`) and on a new key
appends. `remember_run` also appends per provider (`counts @ [(provider, results)]`),
and `apply_answer` appends a new model name (`totals.models @ [model]`).

Bounds, and they are real bounds: `days` ≤ `keep_days` (370 by default), `runs` ≤
`runs_max` (256), provider keys ≤ 17, per-run provider counts ≤ the ladder. So the
cost is not unbounded — it is a constant factor the oracle did not pay (Python used
dicts), paid once per journal line, and paid hardest during `Usage.backfill`, which
folds every historical line once at startup. Nothing in the suite sizes is large
enough to see it.

Order is load-bearing in exactly one place: `runs` stores oldest-first and evicts the
head (`_ :: older`). Everything else is sorted or projected when read — `endpoints`
sorts rollups by cost then name, `citation_rows` sorts by citations, `snapshot`
looks a day up by key, `answers.models` is sorted on the way out — which is what
makes the rest movable.

**Plan: measure first (step 1 is the deliverable, not the patch).** Generate a
synthetic journal at the sizes `keep_days` allows (say 200k search lines spread over
370 days, plus answer runs to fill `runs_max`), time `seekwright --metrics` and the
dashboard backfill at `38007a0`, and time it again with:

- `t.days` and both levels of `t.provider_days` as `Hashtbl`s — pure key→value maps,
  read only by `assoc_opt`, `filter` and the prune, so no order to preserve;
- `t.runs` as a `Hashtbl` plus a FIFO of run keys, so "evict the oldest" is O(1) and
  stops being a positional accident a reader has to infer from `_ :: older`;
- `answers.models` and the per-run provider counts: cons, since order is not read.

If the measurement is noise, the entry closes as **declined** with the number in
this section — a speculatively rewritten `usage.ml` buys nothing and its 1126 lines
carry the dashboard's whole contract.

The same idiom sits in `Engine.try_fallbacks`/`fallback_failed` (`tried`, `failed`,
`notices` — bounded by the ladder), `Cli_flags`' `allowed_hosts`, `Health.ensure`'s
states and `Cli_check`'s report lines. `plans/reviews/2026-11-12-style-review.md` L3
filed all of them together and the unbounded instance, `Jsondoc.normalize`/`dedupe`,
was already rewritten onto a `Hashtbl`. Decide the *cost* rule once — config-bounded
lists are not rewritten for cost, per-input accumulators are — and apply it to
whichever of these the measurement puts on the wrong side of that line. (D1's fixes
for R-002/R-004/R-010 are a separate axis: they land for idiom consistency, not
cost.)

---

## 3. Decisions taken

Recorded so the commits execute without re-deciding; flag any to reverse.

**D1 — R-002/R-004/R-010: fix the bounded appends. Yes.** Each is one small commit
pinned by an existing test, the risk is nil, and the gain is that cons+rev stops
being the minority idiom in a tree that already writes it (`test_mcp_client`'s
`recorded :: state.requests`). The earlier review's "style, not cost" verdict is
about cost, not about whether to land the idiom. They stay in commits 8, 2 and 9.

**D2 — R-005 step B: defer.** Step A removes the duplication that hurts; B is a
design change touching every fallback's interface and five suites, and it re-touches
`Remote_target`, the module R-006 just gave a single owner — let R-006 settle first.
The payoff (tag-free vendor records, a builder table beside the row, deleting
`Scripted_resolver`) is real but belongs to a later wave. The `'tag`-existential
reason is recorded in R-005 step B; commit 3 lands A only.

**D3 — stdio closes providers. Yes.** `Mcp.aclose` issues a best-effort DELETE to
terminate the remote MCP session (`mcp_client.mli`), so the asymmetry is not
invisible: `exa` and `parallel`'s keyed half warm up a session at boot, and on stdio
it is never politely terminated — the provider's endpoint keeps it until its own
timeout. `bin/main.ml`'s `run_server` calls `close_providers built ()` after
`Mcp_kit_stdio.run_channels server stdin stdout`; `~env`/`~sw` are still live at EOF,
so the DELETE can fire. Most adapters' `aclose` is `()`, so the call is cheap. This
rides in commit 7, the commit that already owns the close-on-exit shape.

## 4. Not in this plan

Nothing here changes a wire contract, a config key, a provider name, a refusal
sentence, or the two libraries' dependency direction; no dependency is added; no
`.expected` or golden file is re-pinned — `test/router_dependencies.expected` does
not move (R-009's floor library is invisible to the ocamldep rule, see there), and
the only generated diff is `seekwright.opam` if `dune build @install` moves it.
R-011's rewrite is gated on a measurement this plan asks for but does not assume.
