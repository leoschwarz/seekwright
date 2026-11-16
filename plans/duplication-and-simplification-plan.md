# Plan: the structural pass — duplication and weight

Status: **proposals only; nothing here is landed.** Tree read at `6e4ad90`.
Successor to the 2026-11-16 code-quality wave recorded in
`plans/seekwright-ocaml-port.md` §40: that wave read the factory, the URL gate,
the civil-date arithmetic and four adapter files, and its own ledger coverage
table records that `lib/providers/` "as a whole" and the `Fallback_*` bodies
beyond R-005 were unread. This page covers that unread ground, plus the harness
and the capability layer's unused seams.

IDs here are `S-NNN` (structural). They are **not** ledger entries:
`plans/reviews/code_review_ledger.md` is the owner's register and an agent adds
nothing to it. Where a finding here meets an open ledger question, the section
says which.

## 0. How the tree was measured

Every claim of "copied" below is backed either by a diff of the two bodies (the
normal thing — the adapter and fallback clusters are byte-identical modulo a
field name) or by a window scan, whose recipe is reproducible:

- a window is K consecutive non-comment lines;
- each line is normalised: string literals → `STR`, every identifier and path
  → `X`, whitespace collapsed;
- a window is *shared* when the same normalised text appears in ≥ 2 files
  (or, for the intra-file numbers, ≥ 2 times in one file);
- the count reported is the number of source lines covered by at least one
  shared window, per file, unioned — not a window count, so it does not
  double-count overlapping repeats;
- K = 8 for `test/` and for `lib/providers`, K = 6 elsewhere, K = 4 for the
  one intra-`Config` number, because a short window over-matches list bodies.

|Scope|Files|Lines|Lines inside a shared window|
|---|---|---|---|
|`lib/providers` (15 adapter `.ml`)|15|2,740|**984 (36%)**|
|`lib/fetch/fallback_*`|5|490|**150 (31%)**|
|`lib` + `bin` + `live` + `ocaml-tools` + `examples`|169|30,739|3,604 (12%)|
|`test`|105|39,162|**5,343 (14%)**|

Intra-file repetition, same method: `lib/model.ml` 46% at K=6 (the field-name
lists S-004 names), `lib/config.ml` 27% at K=4 — which is mostly the four
provider-name vocabularies repeating each other's prefixes, so it is **not**
counted as duplication below — `lib/factory/registry.ml` 24%, `lib/server.ml`
19%, `lib/usage.ml` 12%, `lib/engine.ml` 7%, `lib/caps/policy_net.ml` 3%.

## 1. What may not move

Carried forward from the wave, because the same walls bind every item below.

- **The frozen surface.** `ocaml-tools/surface.expected` prints 3 tools, 3 REST
  routes, 3 CLI verbs, 10 server flags, 17 provider names, 49 section config
  keys over 6 tables, 12 per-provider keys and 37 usage-journal fields. Nothing
  in §2 renames any of those. S-006 touches the journal's field *names* only if
  it goes wrong, and says so.
- **The `bin/smoke.expected` transcript** pins the tool schemas, and the
  provider enum carries all 17 names even in a config that enables none. Any
  change that derives a schema from a field list (S-004) must preserve key
  order, or the golden moves and the diff has to be justified as a surface move.
- **The embedded prose** — `Prompts.search_description`,
  `fetch_description`, `answer_description`, `answer_system`,
  `server_instructions`, `Dashboard_html`, and the refusal sentences — has a
  committed golden beside `ocaml-tools/resources.ml`. S-016 and S-017 both
  threaten a sentence; neither may reword one as a side effect.
- **The grant boundary.** `lib/factory/grants.ml` stays the only funnel that
  sets an operation bound or wraps a grant in the audit sink, and
  `test/test_caps_audit.ml` fails the build when another module does. S-009 and
  D-A/D-F each add network plumbing, and both have to route through it.
- **The library direction.** `mcp-caps → seekwright → seekwright.providers /
  seekwright.fetch (+ seekwright.fetch.stdlib) / seekwright.factory /
  seekwright.cli`, with `seekwright.text`, `seekwright.wire` and
  `seekwright.time` as the stdlib-only floor. A helper shared by `lib/`,
  `lib/providers/` and `lib/cli/` can only land on that floor — which is what
  decided R-009 and decides S-005 and S-014 too.
- **`lib/router.ml` stays stdlib-only**, machine-checked by `ocamldep` against
  `test/router_dependencies.expected`. No fix below may make the router reach a
  sibling, and none needs to.
- **`test/should_not_compile/` diagnostics pin exact line numbers.** Editing a
  snippet — including its comments — re-promotes its `.expected` in the same
  change. S-014 touches two of the fourteen programs.
- **D2, deferred by the wave and still binding.** A per-name fetch-fallback
  builder table cannot exist while every `Fallback_*.config` carries a `'tag`
  parameter that exists only so `Remote_target.check` can reach
  `Policy_net.vet_public_host`. S-010 lists the tag erasure as its step 0.
- **The no-line-number rule.** This page names files and symbols only.

## 2. Duplication

### S-001 — the adapter HTTP skeleton, fifteen times over

**Evidence (`read`, `diff`).** `Serper.parse` and `Serpapi.parse` differ in three
lines: the record list's key, the `date` field, and one `score`. Each of eleven
adapters carries its own `let rec take n items acc`; `Algolia.take` is a twelfth
spelling and `Searxng` holds two copies in one file; `Usage.take_first` and
`Tabledoc.take` are the thirteenth and fourteenth — fifteen implementations of
"the first n of a list" in `lib/`. Every `check_status` is the same four branches
with different status numbers and one different sentence. The tail of every
`search` — `Provider.transport_error` on the grant failure,
`Provider.decode_json_object`, then the `outcome` record with `answer = None`,
`cost_usd` and `ignored_constraints` — is the same code under a different name.
`make` is identical fifteen times, including the same comment about the shared
network grant. 984 of 2,740 adapter lines sit in windows shared between two or
more adapters; by file: `tavily` 247, `search1api` 91, `querit` 81, `scrappa`
77, `serpapi` 74, `tinyfish` 73, `serper` 68, `linkup` 64, `freeserp` 48,
`anysearch` 45, `searxng` 42, `deepseek` 29, `algolia` 27, `parallel` 10,
`exa` 8.

**What it risks.** The divergence is not hypothetical: `Parallel.compose_notices`
builds the "that constraint was ignored" sentence by hand over twenty-eight
lines instead of calling `Provider.ignored_constraints`, so `parallel` already
spells the tree's own reporting rule differently from the other fourteen.

**Fix.** Four values in `Seekwright.Provider`, which every adapter already
links:

```ocaml
val take : int -> 'a list -> 'a list
val check_status :
  provider:name -> ?quota:int list -> ?quota_message:string ->
  int -> (unit, error) result
val map_records :
  list_path:string -> url_field:string -> title_field:string ->
  snippet_field:string -> ?date_field:string ->
  ?score:(Yojson.Safe.t -> float option) ->
  snippet_chars:int -> limit:int -> Yojson.Safe.t -> hit list
val http_search :
  provider:name -> net:Net.t -> cost_usd:(int -> float) ->
  request:Authority.Net.request ->
  parse:(Yojson.Safe.t -> limit:int -> hit list) ->
  notice:(search_query -> string option) ->
  search_query -> (outcome, error) result
```

A vendor whose payload nests (Querit's `results.results`), whose identity field
is `url` rather than `link`, or whose body lands in `text` rather than `snippet`
is an argument or a one-line `parse`, not a re-derivation. Exa's
content-backend parse and the MCP-backed pair stay hand-written — they are not
this shape — and keep their own `search`.

**Gate.** 15 suites keep their vendor cases and lose nothing; `surface.expected`
does not move, because no `make` signature needs to change. Expect roughly 700–
900 lines off `lib/providers/`, and `parallel` moving onto the shared notice
sentence is a deliberate behaviour-adjacent change: its sentences must stay
word-for-word, or the golden re-pin belongs in the same commit.

### S-002 — the adapter suites: 9,545 lines, 102 lines of shared support

**Evidence (`read`, window scan).** `Test_support`'s own header states the rule
— a helper "copied into five files drifts in five directions". Then 13–17 suites
each define their own `query`, `test_key`, `sample_json`, `dial`, `refusal`,
`search_of` and `body_of`: 17 files define `query`, 16 `dial`, 18 `refusal`, 14
`search_of`, 13 each `sample_json` and `test_key`. Seven suites (`serpapi`,
`freeserp`, `querit`, `scrappa`, `search1api`, `searxng`, `anysearch`) also
define the same hand-written UTF-8 codepoint counter `chars`, which duplicates
`Seekwright_text.Utf8.count` and re-derives byte lead-width stepping that the
pinned decoder in `lib/text/` already specifies for ill-formed input.
`test_querit.ml` and `test_search1api.ml` share 73 windows of 8 lines.

**What it risks.** Two of the copies are already wrong in different ways: a
hand-counted `chars` agrees with `Utf8.count` on the fixtures and not on a
maximal-subpart boundary, so a cap assertion can pass on a counter the product
does not use. And the contract rows are driven twice: `test_provider_contract.ml`
drives authentication, the `>= 400` row, the operation bound, a transport
failure, a body that does not decode and a non-object body across every adapter,
while 12–13 per-adapter suites re-drive the transport-failure and malformed-body
rows they were supposed to leave to it.

**Fix.** Put `query`, `dial`, `refusal`, `search_of` and `body_of` in
`Test_support`, parameterised by the adapter's `make`; delete the per-suite
copies and the seven `chars` in favour of `Seekwright_text.Utf8.count`; delete
the per-suite transport/malformed-body cases the contract suite owns, keeping
the per-vendor quota row (which is genuinely vendor-specific, as the contract
suite's header says). Estimated −1,800 test lines with strictly better coverage,
because the harness then has one definition to fix.

**Gate.** No production change, no golden. `test/dune` already links
`test_support` for these stanzas.

### S-003 — three verbs, two dispatch sites each

**Evidence (`read`).** `Server.search_tool`, `fetch_tool` and `answer_tool` pass
the engine's optional arguments; `Server.api_search`, `api_fetch` and
`api_answer` pass the same lists again — `Agent.answer` with its ten labelled
arguments is spelled twice, verbatim — and the sites have already diverged:
`api_answer` runs `Engine.Search.resolve` and answers 400 for an unpinnable
provider, the MCP route does not. Ledger Q-002 is the same ground: the two
identical `Refused`/`Failed` pairs are re-derived at four sites.

**Fix.** One dispatch per verb (`dispatch_search`, `dispatch_fetch`,
`dispatch_answer`) taking the request record and returning the engine's result;
each surface keeps only its error-to-status or error-to-`Caps.Error` mapping. On
Q-002's open question this page's answer is: keep the two error types per engine,
share the call — the duplication is in the argument lists and the four mappings,
not in the types.

**Gate.** `test_p8_server.ml` and `test_server.ml` pin the 400/502/404 split and
the `/healthz` shape; the `api_answer` pre-check has to be decided — either both
surfaces pre-check or neither does — and that decision is the visible part of
this change.

### S-004 — the wire field vocabulary spelled five to six times per model

**Evidence (window scan, `read`).** The seven `Model.result` field names appear
five times inside `Model`'s own `reject_extra ~allowed:[ … ]` lists, a sixth time
in `Model.result_to_yojson`, and again in `Server.result_schema` and
`Server.fetch_response_schema`. `include_domains` / `exclude_domains` encoding is
written five times in the request encoders.

**What it risks.** A new result field must be edited in six places, and the only
thing that catches a missed one is the surface golden's field counts — which
move for other reasons too, so the failure is not local.

**Fix.** One key list per wire model (`result_keys`, `search_request_keys`,
…), used by both the `reject_extra` call and the schema builder. The absent-field
rule stays where it is: the encoders build from set fields only.

**Gate.** `bin/smoke.expected` pins the schemas. Key order must not change; a
schema derived from a list has to order the list as the golden already does.

### S-005 — micro-duplication with existing owners

- `Health.url_escape` is byte-for-byte `Provider.escape_path_segment`: the same
  unreserved set, the same `%%%02X` buffer. Keep one. `Uri.pct_encode` is already
  a dependency, but its encoding varies by component while the probe and path
  segments this helper builds are encoded with one fixed unreserved class, so
  replacing it with the library call is a comparison to do first, not a
  substitution. The minimal move is one helper owned by `Seekwright.Provider`, or
  by the stdlib floor if `Health` and `Cli_*` both need it.
- `Engine.base64` is a hand-rolled 22-line encoder with exactly one consumer,
  `Engine.Fetch`'s image projection. `Engine.grouped` is a thousands separator
  with two consumers, both inside one sentence. Both are presentation helpers
  sitting in the execution module; move them next to the projection that uses
  them, and delete `grouped` in favour of the plain number unless the comma is a
  promise.
- `Seekwright_fetch.Utf8` is a one-line re-export of `Seekwright_text.Utf8` plus
  a three-line interface, with two consumers: `Extractors_stdlib` and one case in
  `test_text.ml` whose assertion is that the re-export is the same module. Delete
  the shim, name the real module, and the tautological case goes with it.

### S-006 — `Agent.tally` and `Usage`'s answer line are one field set twice

**Evidence (window scan).** Nine shared windows between `lib/agent.ml` and
`lib/usage.ml`: `searches`, `results`, `fetched`, `material_chars`,
`prompt_tokens`, `completion_tokens`, `answer_chars`, `cited`, `cited_invalid`,
`sources`, `model_cost_usd`, `notice` are built as a field list in
`Agent`'s log call and again in `Usage.answer_line`, over two structurally
identical records (`Agent.tally`, `Usage.answer_totals`).

**What it risks.** The 37 journal fields the surface manifest counts are written
out by two modules. Adding an answer metric means editing both, and the only
guard is the manifest total, which does not say which half drifted.

**Fix.** One owner for the named-field list — a function taking the tally and
returning the `(key, Yojson.Safe.t)` pairs — called by the `answer.ok` log line
and by `Usage.answer_line`. Two sinks, one vocabulary. `Agent.tally` and
`Usage`'s accumulator then agree by construction rather than by care.

**Gate.** `surface.expected`'s journal-field count must not move; if a field is
genuinely missing from one half today, this fix exposes it and the manifest is
re-pinned in the same commit, which is a *finding*, not a cosmetic diff.

### S-007 — the civil-time residue after R-009

**Evidence (`read`).** R-009 put Hinnant's arithmetic on the stdlib floor, and
six copies went away. Two things remain: `Usage.civil_of` recomputes the
seconds-into-day by float subtraction and then splits it, while
`Civil.seconds_of_day` exists and does the same with the floor rule the module
header argues for; and `Usage.iso_utc_seconds` renders `…+00:00` while
`Civil.iso_utc_seconds` renders `Z`, with both live — `Cli_metrics` and
`Linkup.format_utc` on the `Civil` spelling, `Engine` and `Agent`'s
`retrieved_at` on the `Usage` one.

**What it risks.** Two timestamp spellings for one instant, no check that they
mean the same moment, and a hand-rolled floored division beside the checked one.

**Fix.** Build the journal's `+00:00` form on `Civil.seconds_of_day` and
`Civil.civil_from_days`; state in `Civil`'s interface why the journal suffix and
the `Z` suffix differ (one is the journal's key, one is a model-facing stamp).

### S-008 — the page cache holds four copies of the page shape

**Evidence (`read`).** `Page_cache.cached_page` is `Wire.Page.page` minus the
image, and its eight fields are written out in the record, in `of_page`, in
`to_page`, in `meta_of` and again in `page_of_fields`, with four typed sidecar
accessors (`meta_str`, `meta_int`, `meta_float`, `meta_bool`) hand-rolling the
decode. The sidecar serialises unset fields as explicit `null`, which is exactly
what the absent-field rule forbids at the wire boundary — the cache is not a wire
model, but a reader applying the rule from `lib/wire/` will get it wrong here.

**Fix.** Persist `Page.page` (the cache never stores an image) with one encoder
and one decoder for the record, plus the three cache-only keys (`created`,
`body_bytes`, `accessed`) as their own small record. One shape, one codec, and
the sidecar stops inventing a third null convention.

**Gate.** `test_page_cache.ml` pins TTL expiry, the `accessed` refresh, the LRU
rank and the truncated-sidecar path; a format change needs a compatibility
answer, and the honest one is "the cache is off by default and entries are
bounded by `cache_ttl_seconds`, so an old sidecar is simply a miss" — which the
decoder should implement by refusing an unknown shape rather than half-reading it.

### S-009 — `bin/main.ml` carries a second HTTP and TLS stack

**Evidence (`read`).** `Main.make_post` builds a `Cohttp_eio` client, force-loads
`Ca_certs.authenticator`, builds `Tls.Config.client` and wraps the host through
`Domain_name.host_exn` — all of which `Policy_net.tls_config` already does, and
does with the random-generator check `make_post` omits (the generator is
installed by `run_client`, so the ordering works by call sequence, not by
construction). It reads the response with a 64 MiB `Buf_read` ceiling, and
reports failure with `Printexc.to_string`, the one conversion
`test/log_guard/source_discipline.ml` exists to keep off serving paths and
exempts only because `bin/main.ml` owns operator stderr.

**Fix.** Build one `Provider.Net.t` grant for the `--server` host through
`Factory.grant_of_endpoint`, and let `Cli_client`'s `post` run on it: the CLI
verbs then dial through the same code path as every other outbound call, the
grant's own response ceiling replaces the 64 MiB one, and the TLS half of
`main.ml` goes away.

**Gate.** `bin/smoke*.expected` and the `test_cli_client.ml` cases; the exit
codes and the sentence `seekwright: …` must not change.

### S-010 — the fallback readers, after R-005

**Evidence (`diff`, window scan).** R-005 removed the duplicated gates and grant
prologue. What remains is the request tail: `Fallback_tavily` and
`Fallback_scrappa` end with the same three status branches, the same
`Fallback.Json.decode_object` and the same `to_page` call;
`Fallback_linkup`, `Fallback_crawl4ai` and `Fallback_jina` vary the numbers and
one sentence. 150 of 490 lines sit in shared windows: `scrappa` 46, `linkup` 36,
`crawl4ai` 32, `tavily` 30, `jina` 6. The status checks are also inconsistently
qualified within a single function (`response.Caps.Authority.Net.status` and then
`response.status`), which is what a reader trip-wires on.

**Fix.** Step 0 is D2's tag erasure — hand each fallback an injected
`check : string -> (string, string) result` guard built once by the factory, drop
the `'tag` parameter from every `Fallback_*.config`, and `fallback_fixtures.ml`'s
scripted resolver goes with it. Then one `Fallback.run` owning status → `Rejected`
/ `Quota` / `Failed`, the decode, and the windowing, with each vendor reduced to
its request and its field map.

**Gate.** `test_fetch_ladder`, `test_fetch_grant`, `test_grant_timeouts` and the
five `test_fallback_*` suites, plus the `fetch` differential goldens that carry
the refusal sentences.

## 3. Weight

Items here are measured, uncontroversial removals. The contested ones are
decisions, and they are in §4.

|Item|Evidence|Action|
|---|---|---|
|The regeneration driver `test/differential/drive.exe`|It prints the **OCaml** projection of every corpus case. It is not run by `dune runtest`. Run by hand and followed by a promote, it replaces the 413 frozen goldens with the output of the code under test — the parity gate becomes a rubber stamp and the `explicit-divergence` goldens then fail for the wrong reason|Delete the executable and its stanza; the goldens stay, labelled for what they now are: snapshot pins of this tree's behaviour|
|Pages that describe generators that no longer exist|`ocaml-tools/oracle/` holds only `README.md`; `test/differential/dune`'s comment sends a reader to `../../ocaml-tools/oracle/` for regeneration; `AGENTS.md`'s module map still advertises "`oracle/` … plus the `DIVERGENCES` table", and its Gotchas still says the table is in `ocaml-tools/oracle/`|Correct all three to the 12-row `test/differential/divergences.tsv` that §39 recorded, and state the freeze as the reason a golden cannot be regenerated|
|`test/differential/matrix/config-fields.tsv` (63 rows) and `matrix/providers.tsv` (17 rows)|Both re-type facts two other artifacts own: the config-key vocabulary is printed mechanically by `ocaml-tools/surface.ml` from `lib/config.ml`'s records, and the per-provider endpoint / auth / cost / live-status facts live in `Factory.Registry.rows` — which is also what `ocaml-tools/egress_lists.ml` renders the deployment's host lists from. 597 lines of `test_differential_matrix.ml` exist to police the hand-typed copies|Drop both tables and the validator's arms for them; keep `matrix/behaviours.tsv` and `matrix/surface.tsv` if the owner wants a per-behaviour evidence pointer. Update `AGENTS.md`'s frozen-surface row and `ocaml-docs/testing.md` in the same commit|
|`Factory` façade|`factory.ml` is 41 lines of `let x = Mod.x` over five private submodules whose own interfaces total 169 lines (`app`, `fetch_stack`, `grants`, `providers_build`, `verdict`), restated by a 238-line `factory.mli` and re-exporting `provider_set`'s two records (21 more lines): three places to edit per entry. `provider_set` is two records and no code, public only because a `private_modules` name in a public signature dangles|Either expose the submodules and delete the façade, or derive `factory.mli` from them; fold `provider_set` into `providers_build`|
|`Registry.row`'s `context : context_cap`|Three constructors, one field, one default, six write sites, **zero readers** in the tree|Delete|
|`Registry.row`'s `settings : string list`|Read only by the suite that checks the hand-written index is sorted, complete and free of `enabled`/`cost_per_1k`. Which per-provider keys a builder reads is knowable from that builder|Delete the field and the cases that police it|
|`Registry.row`'s `cost_model`|`registry.mli` admits the arrangement: "an adapter mirrors it in its own `cost_for`, and the registry suite pins the mirror." The credit-doubling rule is `Credit_multiplier { over = Serper.credit_over; multiplier = 2 }` in the row *and* `credits max_results = if max_results > 10 then 2 else 1` in the adapter|One owner. Either the row's model prices everything and the adapters stop exporting `cost_for`, or the row keeps only `default_cost` and `--check --live` reads the adapter|
|`Seekwright_extractor`'s double representation|`module type S`, a `backend` record of closures, and `of_module` between them, for the one backend this build can construct (`Config.known_extractors = [ "stdlib" ]`, `trafilatura` refused at load). `Extractor.supported_types` is documented as "kept for the derived-phrase tests, not for dispatch" — a value that exists because a test asserts it|One representation, and drop the union list or point it at dispatch|
|`seekwright.fetch.stdlib` as its own public library|One module, justified by "a future backend with its own dependencies"; it forces every consumer to link two libraries for one `Extractor.of_module` call|Fold into `seekwright.fetch` unless a second backend is actually planned|
|Adapter `.mli` internals exported for the suites|738 lines of adapter interfaces export `parse`, `cost_for`, `credit_over`, `policy_endpoint`, `request_body` so suites can reach them. `policy_endpoint` is `Provider.policy_of_uri endpoint`, and the suites then assert its host, scheme and port against a constant the same suite already asserted from `endpoint`|Seal the interfaces to `name`, `endpoint`, `make` and what the factory reads; delete the derived-endpoint cases (Q-001's standard: a name carries it where it can)|
|One-use and one-element helpers|`Config.permitted_fetch_names = [ "jina" ]` is a vocabulary list with a single member, driving the same refusal code path built for many|Leave the list, but say in the interface that it is the only non-provider name — its current doc reads as if the set were open|

## 4. Decisions the maintainer owns

Each has a recommendation; none is applied.

**D-A — the differential harness's posture.** Keep the 413 goldens and the
properties, delete `drive.exe` and the oracle README, and rename the suite's own
claim from "does the port answer this the way the baseline did" to "does this
behaviour still hold". *Recommend: do it.* The alternative — keeping a driver
whose only effect is to re-pin goldens from the code under test — is a
foot-gun guarded only by nobody running it.

**D-B — the parity matrix.** Options: keep all four tables; drop
`config-fields.tsv` + `providers.tsv` (the two hand-typed vocabularies, 80 rows
and their validator arms); drop all four. *Recommend: the middle one.* The
remaining `behaviours.tsv` (23 rows) and `surface.tsv` (16 rows) name an evidence
pointer per behaviour, which nothing else in the tree records; the dropped two
duplicate `ocaml-tools/surface.ml` and `Registry.rows`.

**D-C — `Caps.Budget`.** `with_operation_budget` is never called from `lib/`: its
callers are `test_caps_budget.ml` (431 lines), `test_caps_audit.ml`,
`test_authority_net.ml`, `should_not_compile/grant_path.ml` and
`examples/gated_search.ml`. No served grant carries a budget, so the operation
ceiling `mcp-caps` advertises is unenforced in this deployment. Options: delete
the seam (21 lines of accounting, the refusal sentence, and the suite;
`grant_path.ml` is the positive half of the fourteen and uses `Budget.make`, so
it changes and its pinned diagnostic re-promotes), or give `Agent`'s fixed
retrieval plan a real budget and make it load-bearing. *Recommend: delete now,
re-add with the agent change that needs it* — keeping it means every future
`Controls` change is tested against a caller that does not exist.

**D-D — `Extract_pool`.** 472 implementation lines, a 105-line interface and a
353-line suite, plus `test_fetch_workers.ml`: fixed-size worker domains fed over
an AF_UNIX socket, with request and response byte ceilings, permits, round-robin
dispatch, and four error classes for the exchange. The payload crossing that
socket is an immutable `string` in and an immutable record of strings out, and OCaml
domains share the heap for immutable values — the framing, the ceilings and the
`Worker` error class buy nothing that a `Domain` plus an admission semaphore does
not. The requirement (keep the Eio loop responsive while a large page is walked)
is real; the mechanism is what is in question. *Recommend: measure first, the way
R-011 was measured* — `ocaml-tools/extract_bench` already times the corpus, so
run inline-vs-pool A/B against a worktree on the same loaded host before cutting
anything. Two things must be re-homed if the pool goes: `max_entry_bytes`
enforcement currently rides the frame ceiling, and the `Timed_out` path is what
renders the `fetch.timeout_seconds` refusal. Note that the corpus bar is a
wall-clock ceiling and load-sensitive, so a single A/B pair on a busy machine is
not evidence — the bar is not to be moved to make a run green.

**D-E — `Config`'s Python numeric-coercion grammar.** `trim`,
`drop_separators`, `int_from_string`, `float_from_string`, `bool_words`,
`bool_from_string` and `bool_from_number` — about 110 lines — accept `"1_000"`,
`"1.000"`, `"nan"`, `"inf"`, `"yes"`, `"on"`, `"0"` for TOML values the TOML
parser has already typed as `TBool`/`TInt`/`TFloat`. They exist to mirror the
Python deployment's lax string coercion, which is a compatibility promise made to
a deployment that is no longer in this tree. Options: keep it and name it in
`ocaml-docs/configuration.md` as an operator-facing promise; or let a quoted
number meet the same `type_error` as any other wrong type. *Recommend: refuse.* A
quoted number in a config file is a typo, the tree's own rule is that an
unhonourable constraint is reported rather than quietly accepted, and 110 lines
of Python's numeric grammar is a large thing to own. If it goes: `test_config.ml`'s
frozen-vocabulary cases, the config differential corpus and its goldens, and
`config-fields.tsv` if D-B keeps it, all move in the same commit.

**D-F — Exa's private free-to-keyed ladder.** `Exa.make_tiered` is an escalation
engine inside one adapter: its own monotonic cooldown clock, its own reading of
which free-tier failure means exhaustion, its own notice composition, three event
names (`exa.escalated`, `exa.cooldown`, `exa.both_failed`), and
`free_cooldown_seconds` as a per-provider key only Exa reads — while `Router` owns
"the free walk, the fallback rungs" and `Health` owns "a quota failure gates the
name out of the fallbacks for a cooldown". Two mechanisms answer one question at
two layers. *Recommend: do not fold them together in this pass.* The sentences
are model-facing and pinned, the free walk's membership rules
(`Config.keyless_providers` versus `Config.free_providers`, and why a metered tier
is excluded from the walk) would have to say something new about `exa`, and the
cost of getting it wrong is a billed search. Take the two halves that are safe:
route Exa's and Parallel's notices through `Provider.ignored_constraints`
(S-001), and write down in the port plan that the per-adapter cooldown is a
deliberate second ladder and why the router's does not serve it.

**D-G — formatting.** There is no `.ocamlformat` and no formatter step in CI, and
the styles have drifted: `lib/engine.ml` and `lib/router.ml` carry leading-`;`
vertical records beside trailing-`;` ones, and the adapter files wrap the same
`truncate_snippet` call two different ways. Options: adopt a pinned
`.ocamlformat` with one reformat commit; or leave it. *Recommend: adopt it before
S-001 lands*, so the refactor does not add a third style — and budget for the
whole cost, which is the re-pin of every `test/should_not_compile` diagnostic
(their `.expected` files pin line numbers) plus a large one-shot diff. Do not
adopt it after the adapter commits, or the same files churn twice.

## 5. Landing order

Each step is one reviewable commit, gate green on its own, with the plan updated
in the same commit.

|Order|Step|Expected effect|
|---|---|---|
|1|S-005 micro-duplication: `take`, the percent-encoder, the `Utf8` re-export shim|small, no golden; establishes the shared helpers S-001 needs|
|2|S-001 adapter skeleton|−700 to −900 lines in `lib/providers/`; `parallel`'s notices move onto the shared sentence|
|3|S-002 test harness|−~1,800 test lines, no production change|
|4|S-003 one dispatch per verb, answering Q-002|the 400/502 mapping has one owner; the `api_answer` pre-check asymmetry is decided|
|5|S-004 field lists, then S-006, then S-007|six field spellings to one per model; the journal's answer fields gain one owner|
|6|S-008 page cache, S-009 the CLI grant|the cache stops hand-rolling a codec; `bin/main.ml` stops owning a TLS stack|
|7|§3 table + D-A/D-B docs|`drive.exe`, the two matrix tables, `context`, `settings`, `cost_model`, the façade and the extractor duality go; `AGENTS.md`, `ocaml-docs/testing.md` and the port plan move in the same commit|
|8|D-C … D-G, one decision at a time|each needs its own page section and, for D-E, an operator-visible behaviour change|

## 6. Verification

Every step ends on the three gate targets — `dune build @install`,
`dune runtest --force`, `dune build @doc` — and each step's own claim is
exercised on the served path, not only in a suite:

- S-001, S-010: a scripted `Provider.Net` and a loopback listener keep asserting
  the request that would have left; the vendor cases are moved, not deleted, and
  the count of assertions per adapter is reported before and after.
- S-002: suite-by-suite runs from `_build/default/test`, and the contract suite
  still fails when a row is dropped from an adapter — that is the check that the
  per-suite copies were redundant rather than load-bearing.
- S-003, S-009: `bin/smoke.expected`, the `--check` report pins, and a real
  `seekwright --http` plus one CLI verb against it, watching the status codes and
  the drain.
- S-004, S-006: `bin/smoke.expected` and `surface.expected` must be byte-stable;
  if they are not, the diff is a surface move and belongs in its own commit with
  its own justification.
- D-D: `ocaml-tools/extract_bench`'s `bench.exe --check` quality bar and
  `digest_cases.exe --check-parity`, before and after, on the same host.
- Nothing in this plan dials a provider. A step that would need live evidence
  says so and stops for `seekwright-live`, one named case, then the live-run row.

## 7. Checked and deliberately left alone

`Policy_net`'s special-use prefix table, `mem_network`, the transition-prefix
vetoes and the vetted-address single resolution: each is a named SSRF or
rebinding decision, 3% intra-file repetition, and no simplification that does not
remove a check. `log_guard/field_sets.ml` (sentinel absence proved in both
settings over the real engines) and `source_discipline.ml` (the non-vacuity
controls make it a guard, not a grep) — a library-wide rule dune cannot express
per-module, so the source scan is the honest mechanism.
`should_not_compile/`'s fourteen programs and their pinned diagnostics.
`Surface.record_fields`' line-based record scan: brittle to formatting, but a
break fails loudly through the golden's counts and OCaml offers nothing better
without a code generator. The three transports, the drain's two suites, the
`/healthz` Host-allowlist exemption, the absent-field rule, the refusal of
`logging.library_level` and `logging.access_log`, and the absence of a help
screen: all as documented, all load-bearing.
