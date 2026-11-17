# Plan: the structural pass — duplication and weight

Status: **§5 steps 0–7 are landed; §3, the §4 decisions and the D-C … D-F steps are
proposals.** Tree read at `6e4ad90`;
reviewed and corrected against the tree at `742a9c7` on 2026-11-17 (the code is
unchanged between the two commits — the diff is plans only). The corrections are
recorded in §8; the §4 decisions remain the maintainer's.
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

Line counts are `wc -l` plus one per file. The two whole-tree rows count `.ml`
and `.mli` alike; the adapter row is the fifteen adapter `.ml` (not
`mcp_client.ml`), the fallback row the five `.ml`.

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
  committed golden beside `ocaml-tools/resources.ml`. S-001 and S-010 both
  threaten a sentence; neither may reword one as a side effect.
- **The grant boundary.** `lib/factory/grants.ml` stays the only funnel that
  sets an operation bound or wraps a grant in the audit sink, and
  `test/test_caps_audit.ml` fails the build when another module does. S-009 adds
  an outbound call and S-010's step 0 moves the fallback host check into the
  factory; both have to route through it.
- **The library direction.** `mcp-caps → seekwright → seekwright.providers /
  seekwright.fetch (+ seekwright.fetch.stdlib) / seekwright.factory /
  seekwright.cli`, with `seekwright.text`, `seekwright.wire` and
  `seekwright.time` as the stdlib-only floor. `seekwright.providers` and
  `seekwright.cli` link `seekwright`; `seekwright.fetch` links neither big
  library. So a helper shared by `lib/`, `lib/providers/` and `lib/cli/` can
  live in `seekwright` itself — only a helper `seekwright.fetch` also needs is
  forced onto the floor. R-009's `Civil` sits on that floor, though no
  fetch-side consumer reads it today; S-001's `take` and S-005's percent-encoder
  have no fetch-side consumer either, so `Provider` owns them.
- **`lib/router.ml` stays stdlib-only**, machine-checked by `ocamldep` against
  `test/router_dependencies.expected`. No fix below may make the router reach a
  sibling, and none needs to.
- **`test/should_not_compile/` diagnostics pin exact line numbers.** Editing a
  snippet — including its comments — re-promotes its `.expected` in the same
  change. D-C touches two of the fourteen programs: `grant_path.ml` (the
  positive half, which calls `Budget.make`) and `controls_record_forge.ml`
  (which forges a `Controls.t` with a `budget` field).
- **D2, lifted.** Every `Fallback_*.config` used to carry a `'tag` parameter that existed
  only so `Remote_target.check` could reach `Policy_net.vet_public_host`, which is what
  made a per-name fetch-fallback builder table untypeable. S-010 erased it: the gate is a
  value (`Remote_target.make_check`) the factory builds once per rung, so the table is now
  expressible. It is not built — what `build_fallback`'s arms differ in is their gates (the
  permission set, the key, `fetch.crawl4ai_url`), which is what the match still owns.
- **The no-line-number rule.** This page names files and symbols only.

## 2. Duplication

### S-001 — the adapter HTTP skeleton, fifteen times over · **landed**

**Evidence (`read`, `diff`).** `Serper.parse` and `Serpapi.parse` differ in the
record list's key — `organic` versus `organic_results` — and in `truncate_snippet`
wrapping; the `date` field reads the same `published_date` (through a local helper
in `serper`) and both leave `score = None`. Twelve adapters carry their own
`let rec take n items acc` — `Searxng` holds two copies in one file, thirteen copies
— `Algolia.take` is a fourteenth spelling and `Usage.take_first` a fifteenth: fifteen
implementations of "the first n of a list", every one in `seekwright` or
`seekwright.providers`. Every `check_status` is the same four branches with the
vendor's own quota sentence; the status numbers are almost everywhere the same
(`tavily` adds 432, its monthly-credit status, beside 429). The tail of the thirteen
REST adapters' `search` — `Provider.transport_error` on the grant failure,
`Provider.decode_json_object`, then the `outcome` record with `answer = None`,
`cost_usd` and `ignored_constraints` — is the same code under a different name;
`parallel`'s REST half spells the transport mapping and the decode inline instead of
calling the two helpers. `make` is the same shape in the fourteen modules that define
it — defaults, labels and extra parameters vary — and thirteen carry the same comment
about the shared network grant; `exa` builds through `make_tiered` and `make_mcp`
instead. 984 of 2,740 adapter lines sit in windows shared between two or
more adapters; by file: `tavily` 247, `search1api` 91, `querit` 81, `scrappa`
77, `serpapi` 74, `tinyfish` 73, `serper` 68, `linkup` 64, `freeserp` 48,
`anysearch` 45, `searxng` 42, `deepseek` 29, `algolia` 27, `parallel` 10,
`exa` 8.

**What it risks.** The divergence is not hypothetical: `Parallel.compose_notices`
(about 38 lines) builds the REST half's constraint report by hand — the language
and safe-search clauses re-spell `Provider.ignored_constraints`' sentence, while the
include/exclude-domains interaction and the upstream-warning tail are beyond that
helper's vocabulary — and the MCP half already calls `Provider.ignored_constraints`.
So `parallel` spells the tree's own reporting rule two ways in one file.

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
  notice:(search_query -> Yojson.Safe.t -> string option) ->
  search_query -> (outcome, error) result
```

A vendor whose payload nests (Querit's `results.results`), whose identity field
is `url` rather than `link`, or whose body lands in `text` rather than `snippet`
is an argument or a one-line `parse`, not a re-derivation. `notice` reads the
decoded payload as well as the query because `parallel`'s upstream warnings depend
on it; its domain-interaction clause is one the shared helper does not have, so the
helper grows that clause or `parallel` keeps a vendor extension — either way the
sentences stay word-for-word (the gate below). Exa's content-backend parse and the
MCP-backed pair stay hand-written — they are not this shape — and keep their own
`search`.

**Gate.** 15 suites keep their vendor cases and lose nothing; `surface.expected`
does not move, because no `make` signature needs to change. Expect roughly 700–
900 lines off `lib/providers/`, and `parallel` moving onto the shared notice
sentence is a deliberate behaviour-adjacent change: its sentences must stay
word-for-word, or the golden re-pin belongs in the same commit.

**Landed.** `Seekwright.Provider` owns five of these values rather than four:
`take`, `check_status`, `map_records`, `map_content_records` and `http_search`;
the separate `search_outcome` the sketch implied is `http_search`'s tail. Two
signatures moved from the sketch because the vendor variation is wider than the
sketch assumed: `check_status` gained `?named:(int * error) list` (SearXNG's 401
says `format=json` is not enabled, DeepSeek's 408 is its own request-body
timeout, Linkup has no 402, Tavily's 432 sits beside 429), and `map_records`
takes `list_path:string list` rather than `string` (Querit walks
`results.result`, Anysearch `data.results`) with `?date:(Yojson.Safe.t -> string
option)` rather than `?date_field:string`, because the *reading* is what differs
— Freeserp takes the first non-empty of `published_at`/`crawled_at`, Serper takes
`date` as it comes. `map_content_records` is not in the sketch: Tavily, DeepSeek
and Parallel answer `{title, url, text}` with `text_truncated` and, for two of
them, a separately capped snippet, and one mapper over a private `body` sum
covers both shapes. `http_search` carries `?status`, `?check`, `?answer` and
`?decode`; `?decode` exists for Parallel alone, whose REST half answers an empty
result set for a body that is valid JSON but not an object where
`decode_json_object` would report the malformed row.

Measured, against the proposal's −700–900: `lib/providers/*.ml` goes 3,003 →
2,492 (−511) and `lib/provider.ml` plus its interface 405 → 630 (+225), a net
−286. The gap is three things the estimate assumed away: the lines did not
vanish, they moved to one owner and gained a documented contract; `exa` (by
decision), `searxng`'s paged walk and `parallel`'s tiered warm-up keep their own
`search`; and four `parse`s are not the search-backend record shape (Algolia's
score-first records, Linkup's `results`+`content` split, DeepSeek's
content-only rows, Exa's content backend).

`parallel`'s notices now use `Provider.ignored_constraints`' wording, called
twice — once with language left unanswered, once with safe-search — because that
vendor's report names each dropped bucket in its own clause. The single joined
clause the helper builds when both buckets are open would have diverged
`141-parallel-constraints` and `145-parallel-warnings` from the Python oracle;
registering that divergence is a §4 decision, not this step's, and both goldens
are byte-stable. `Algolia.check_status` and its `algolia.mli` export are gone: an
adapter's status rows are not a module's public fact. The fifteen `take` bodies
are one function, called from four adapters and `Usage` directly and from
`map_rows` for the rest; `Tabledoc`'s `take` stays, being string truncation in
another package.

Two suite facts moved with the change and no case was lost: `test_anysearch.ml`
hands `parse` the whole envelope, because `data.results` is now one `list_path`
argument — so the fixture is the body the vendor sends and the container-drift
cases exercise the unwrap that used to sit in `search` — and `test_parallel.ml`'s
notice case is renamed to what it pins. `test/router_dependencies.expected`
grows two lines: `lib/usage.ml` links `Provider` for `take` instead of its own
`take_first`.

### S-002 — the adapter suites: 9,217 lines, 103 lines of shared support · **landed**

**Evidence (`read`, window scan).** The set is the fifteen per-adapter suites plus
`test_mcp_client.ml`; `Test_support`'s own header states the rule — a helper "copied
into five files drifts in five directions". The per-suite helpers repeat: 17 files
define `query`, 15 `dial`, 14 each `refusal` and `search_of`, 13 `sample_json`, 12
`test_key` and 6 `body_of` — top-level `let` definitions counted by name across
`test/test_*.ml`. Seven suites (`serpapi`,
`freeserp`, `querit`, `scrappa`, `search1api`, `searxng`, `anysearch`) also
define the same hand-written UTF-8 codepoint counter `chars`, which duplicates
`Seekwright_text.Utf8.count` and re-derives byte lead-width stepping that the
pinned decoder in `lib/text/` already specifies for ill-formed input.
`test_querit.ml` and `test_search1api.ml` share 73 windows of 8 lines.

**What it risks.** The seven `chars` copies are byte-identical and already wrong on
ill-formed input: they step a fixed 2/3/4 bytes off a lead byte, while `Utf8.count`
steps by the maximal-subpart rule (`Utf8.lead_width`), so an overlong or truncated
lead counts differently — a cap assertion can pass on a counter the product does not
use. And the contract rows are driven twice: `test_provider_contract.ml` drives
authentication, the `>= 400` row, the operation bound, a transport failure, a body
that does not decode and a non-object body across every adapter, while thirteen
per-adapter suites still carry their own case for one of those rows — some with a
vendor-specific assertion the contract row does not make, which has to move with the
case rather than vanish.

**Fix.** Put `query`, `dial`, `refusal`, `search_of` and `body_of` in
`Test_support`, parameterised by the adapter's `make`; delete the per-suite
copies and the seven `chars` in favour of `Seekwright_text.Utf8.count`; delete
the per-suite failure-row cases the contract suite owns, keeping any vendor-specific
assertion the contract row does not make and the per-vendor quota row (which is
genuinely vendor-specific, as the contract suite's header says). Estimated −1,800
test lines with strictly better coverage, because the harness then has one
definition to fix.

**Gate.** No production change, no golden. `test/dune` already links
`test_support` for these stanzas — but not a second support library: the eight
counter suites also need `seekwright.text`, a fact the plan did not carry.

**Landed.** The harness is a second private library under `test/support/`, not
new modules in `Test_support`, and the split is the link closure:
`Test_support` holds what a suite needs without the server — strings, files,
Alcotest and now the JSON and list accessors (`get`, `items`, `str`, `int`,
`bool`, `is_null`, `hd`, `nth`) — while `Adapter_support` drives a
`Seekwright.Provider.Net.t` (`query`, `test_key`, `response`, `answered`,
`refusing`, `recording`, `ok_search`, `drive`, `json_object`, `body_of`,
`body_field`, `has_body_field`, `params`, `param`, `has_param`) and is linked
only by the suites that already link `seekwright`. Each suite keeps its own
`dial`, `refusal` and `search_of`, because those wrappers are where that
adapter's `make` signature is named: `~snippet_chars`, `~text_chars`,
`?title_attr`, `~now`, `~endpoint`, `~app_id` are not the harness's to know.

Measured, against the proposal's −1,800: the sixteen adapter suites go 9,072 →
8,413 (−659) and the six journal suites that copied the accessors
(`agent`, `engine`, `concurrency`, `usage`, `fetch_cache`, `fetch_engine`)
another −80, while `test/support/` grows 208 → 450 (+185 harness, +57
accessors that used to sit in the suites) — net −497 in `test/`. The estimate
counted the `dial`/`refusal` wrappers as removable and the failure rows as
still duplicated. Neither holds: the wrappers are the adapters' signatures, and
most of the contract duplication had moved in an earlier wave — every suite's
section comment already says the six rows are pinned once by
`test_provider_contract.ml`. What was left to delete is four cases:
`freeserp`'s grant-bound row and not-JSON row, `serpapi`'s constant-message row
and `parallel`'s malformed-body row. Every failure case that stays in an
adapter suite states a vendor fact that suite cannot drive — which statuses mean
"you have run out", the auth wording, and the non-echo assertion (serper's
`X-API-KEY`, searxng's instance host, serpapi's key riding in the query string,
freeserp's secret marker, parallel's credential header).

The case count moves by exactly those four: 1,434 → 1,430 (`freeserp` 38 → 36,
`serpapi` 34 → 33, `parallel` 35 → 34). Two suite facts moved with the change:
`test_exa.ml`'s query default was that file's own (`"write-ahead logging"`, not
`"q"`), so the one case that asserts the text on the wire now passes it
explicitly; and eight suites gained `seekwright.text` in `test/dune` because
they now write `Utf8.count` against the pinned decoder instead of a
hand-rolled lead-width walk. `test_mcp_client.ml` is untouched — its fixture is
a scripted MCP endpoint, not a `Net` that answers one request.

### S-003 — three verbs, two dispatch sites each · **landed**

**Evidence (`read`).** `Server.search_tool`, `fetch_tool` and `answer_tool` pass
the engine's optional arguments; `Server.api_search`, `api_fetch` and
`api_answer` pass the same lists again — `Agent.answer` with its nine labelled
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

**Landed.** `dispatch_search`, `dispatch_fetch` and `dispatch_answer` now sit
above the three tools and the three REST routes, so the argument list each
engine is called with is spelled once; what stays per-surface is the mapping,
which is the half that genuinely differs — a refusal is `Error.Invalid` on a
tool call and 400 on REST, a failure is `Error.Failed` and 502, and a disabled
verb is 404 on REST only, because a tool call has no status to answer with. The
file does not shrink (973 → 971): the six call sites collapsed into three
functions and the saved lines went to the decision below.

Q-002's open question is answered as this page proposed — the two error types
per engine stay, the call is shared. The visible decision: **both surfaces
pre-check**. `answer_tool` runs `Engine.Search.resolve` before retrieval, so an
`answer` pinned to a name this build carries no adapter for is refused with an
`invalid:` tool error, and 400 on REST, instead of reaching `Agent.answer`,
where the retrieval walk turned it into a model failure (502 / `failed:`) and
billed a search step on the way. This is reachable rather than theoretical
because the `provider` enum on the tool schema is the vocabulary, not the
enabled set: the schema refuses only names outside the seventeen, so an
in-vocabulary-but-unbuilt name is exactly what reaches the run.
`test_p8_server.ml` pins the new half with the invariant that makes it more than
a status change — the refusal journals nothing, so no retrieval step and no
model call ran.

### S-004 — the wire field vocabulary spelled four times per model · **landed**

**Evidence (window scan, `read`).** The named `*_allowed` lists already exist for
every request and response decoder (`Model.result_allowed`, `fetch_response_allowed`,
`search_request_allowed`, `fetch_request_allowed`, `answer_request_allowed`); it is
the encoders and the schemas that re-spell them. The seven `Model.result` field names
appear in `result_allowed`, `result_of_yojson`, `result_to_yojson` and
`Server.result_schema` — four spellings; the fetch-response set is likewise spelled
four times, its schema (`Server.fetch_response_schema`) re-listing the page fields
and the nested `matches` / `image` objects. `include_domains` / `exclude_domains`
list-encoding is written three times in the request encoders.

**What it risks.** A new result field must be edited in four places, and a missed
schema spelling is caught only by `bin/smoke.expected`'s whole-transcript pin — which
moves for other reasons too, so the failure is not local.

**Fix.** Wire the schemas to the decoders' key lists — `Server.result_schema`,
`Server.fetch_response_schema` and the nested `matches` / `image` objects read the
`*_allowed` lists (or one typed key list per model that both the `reject_extra` call
and the schema builder read). The absent-field rule stays where it is: the encoders
build from set fields only, so they remain the one hand-spelled half.

**Gate.** `bin/smoke.expected` pins the schemas. Key order must not change; a
schema derived from a list has to order the list as the golden already does.

**Landed.** The six named lists are now ten: the four `reject_extra` calls that
spelled their list inline (`search_response`, `fetch_match`, `fetch_image`,
`answer_source`) name theirs too, so every wire model has exactly one key list
and it is exported from `Model`. `Server`'s three request tables and seven
response tables are built by one `properties` over those lists, which owns both
the vocabulary and the key order — `Model.fetch_request_allowed` was put in the
order the schema declares (the decoder only asks membership), and
`bin/smoke.expected`, the stdio transcript and `surface.expected` came out
byte-identical, which is the evidence the schemas did not move.

What is left per field is the schema itself: one name→schema pair per field is
not a second vocabulary, it is the schema. So the drift this section is about is
caught where it is created — `Server.untabled_wire_fields` returns every name a
model's list has and its table lacks, as `"model.field"`, and
`test_p8_server`'s "every wire field has a property schema" fails the build over
a non-empty answer, naming it. That is a suite and not a raise: the first
version failed at module initialisation with `invalid_arg`, and
`test/log_guard/source_discipline.ml` forbids `invalid_arg` and `failwith` in
`lib/server.ml` — the guard refusing it is the guard working. Probed, not
assumed: putting an extra name in `Model.fetch_image_allowed` made that case
fail with `["fetch_image.probe_field"]`.

In `Model` the absent-field rule is also one spelling now
(`field_str`/`field_esc`/`field_bool`/`field_int`/`field_float`/`field_words`/
`field_list`/`field_value`) instead of a hand-written
`match … with None -> [] | Some v -> [ … ]` per field. The section said the
encoders stay the hand-spelled half; they are, but the *rule* is spelled once and
the per-field choice of escaping stays with the field. The two nulls-carrying
projections (`search_query_to_yojson`, `provider_result_to_yojson`) keep their own
shape on purpose: there null is the contract, not an omission.

Net +82 lines across `lib/model.ml`, `lib/model.mli`, `lib/server.ml`,
`lib/server.mli` and the suite: the audit and the named tables cost more than the
encoder boilerplate saved. The gain is not line count — it is that a field name
now exists once as a vocabulary entry, and a schema that does not know it fails
by name instead of only widening the transcript golden.

### S-005 — micro-duplication with existing owners · **landed**

- `Health.url_escape` is byte-for-byte `Provider.escape_path_segment`: the same
  unreserved set, the same `%%%02X` buffer. Keep one. `Uri.pct_encode` is already
  a dependency, but its encoding varies by component while the probe and path
  segments this helper builds are encoded with one fixed unreserved class, so
  replacing it with the library call is a comparison to do first, not a
  substitution. The minimal move is one helper owned by `Seekwright.Provider`:
  `Health` is in `seekwright` and the adapters link it, so both consumers reach it
  there; no `Cli_*` module calls either escaper today.
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

**Landed.** `Health` now calls `Provider.escape_path_segment` and its copy is
gone; `Engine.base64` sits inside `Engine.Fetch` beside `image_notice` and
`finish_image`; `grouped` is deleted, because its comma was never a promise —
`test_fetch_engine.ml` already asserts that sentence with `string_of_int`. The
proposal's consumer count for the shim was wrong: six `lib/fetch/` modules name
`Utf8` unqualified, so deleting `lib/fetch/utf8.ml` leaves one
`module Utf8 = Seekwright_text.Utf8` alias per consumer, which is the spelling
every other library in the tree already uses, and `seekwright.fetch.stdlib`
links `seekwright.text` for it. `{!Utf8.ascii_lower}` in `extractor.mli` and
`extractor.ml` becomes a named symbol rather than an odoc link: a cross-package
reference has no precedent here, and `dune build @doc` has to stay green. No
golden moved — `surface.expected`, the prose goldens and
`test/router_dependencies.expected` are byte-stable, `health.ml` having already
named `Provider`.

### S-006 — `Agent.tally` and `Usage`'s answer line are one field set twice · **landed**

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

**Landed.** `Usage.answer_metrics` is the record and `answer_fields` — a list of
`(key, getter)` pairs — is the one spelling of the names. `answer_line` writes
those pairs to the journal, `answer_metric_fields` hands the identical pairs to
`Agent`'s `answer.ok`/`answer.failed` line, and `Server.journal_fields` prints
`answer_metric_keys` for the manifest's `[answer]` row. That row was a third
hand-typed spelling of the set and is now derived; the manifest's count stayed at
37 and `surface.expected` did not move, so no field was missing from either half.
`Agent.record` builds one metrics value and feeds both sinks: the 16-argument
`record_answer` call is gone, and so is the third hand-written field list.

Two things the section overstated. First, the records did not merge and should
not: `Agent.tally` is the plan-time accumulator (it is stepped as the retrieval
plan runs, so a call that dies at the model still records what it paid for), and
`Usage.answer_totals` is the aggregate over calls with its sample-size counts
(`token_calls`, `priced_calls`) beside the sums. What agrees by construction is
the field *vocabulary*, which is what the drift was. Second, `tally`'s fields and
`answer_metrics`' are name-identical, so the conversion needs a type annotation
on `~tally` — without it the record literal resolves `tally.searches` against the
nearer vocabulary and the conversion does not typecheck. That is recorded at
`Agent.record`.

The journal pin keeps its teeth where it had them: `test_p8_surface` compares a
real journal's keys per line kind against the manifest, which for `[search]` and
`[fetch]` is still hand-typed against a single writer; the `[answer]` row is now
true by construction, which is the point of one owner. The on-disk reader
(`apply_answer`) stays string-keyed on purpose: it reads journals an older version
wrote, where a missing key means absent from the aggregate, not zero. The
`[answer.ok]` line's `ms` moved to the end of the field list — no pin covers log
field order, and it is not a contract. The stale comment claiming seventeen keys
on an `[answer]` line says eighteen now.

Line counts: +10 across `lib/`, +48 in the two suites that call `record_answer`
by keyword (a 16-label call becomes a record literal). The step is not a
reduction; it is the removal of a third spelling and of the manifest's freedom to
drift from the writer.

### S-007 — the civil-time residue after R-009 · **landed**

**Evidence (`read`).** R-009 put Hinnant's arithmetic on the stdlib floor, and six
copies went away. Two things remain: `Usage.civil_of` already calls
`Civil.whole_seconds`, `Civil.days_of_secs` and `Civil.civil_from_days`, but
re-derives the seconds-into-day by float subtraction and the hour/minute/second
split, because `Civil.seconds_of_day` is `int -> int` and drops the fraction
`Usage.iso_utc_full`'s microsecond stamp needs; and `Usage.iso_utc_seconds` renders
`…+00:00` while `Civil.iso_utc_seconds` renders `Z`, with both live — `Cli_metrics`
and `Linkup.format_utc` on the `Civil` spelling, `Engine` and `Agent`'s `retrieved_at`
on the `Usage` one.

**What it risks.** Two timestamp spellings for one instant, no check that they
mean the same moment, and a hand-rolled floored division beside the checked one.

**Fix.** Give `Civil` a fraction-keeping clock split (`seconds_of_day` is
`int -> int` today), and build both `Usage.iso_utc_full` and `Usage.iso_utc_seconds`
on `Civil`'s day arithmetic and that split; state in `Civil`'s interface why the
journal suffix and the `Z` suffix differ (one is the journal's key, one is a
model-facing stamp).

**Landed.** `Civil.clock_of_instant : float -> int * int * int * float` is the
fraction-keeping split — hour, minute, whole second, leftover fraction — computed
from `whole_seconds` and `seconds_of_day`, so its day bucket is the one
`days_of_secs` names and its fraction is in 0 .. below 1 for a pre-epoch instant
too. `Usage`'s `civil_of` is gone: `stamp` calls `Civil.civil_from_days` over
`Civil.days_of_secs` and `Civil.clock_of_instant`, and returns whole microseconds
rather than a float for a caller to floor. `seconds_of_day` stays `int -> int` as
proposed.

The two spellings stay, and `Civil`'s interface now says why: `…+00:00` is the
journal's `ts` key — read back, backfilled and pruned by `Usage.parse_offset`, and
a deployed journal already holds that spelling — while `Civil.iso_utc_seconds`'s
`Z` is what `Cli_metrics` and `Linkup.format_utc` print. What the section said was
missing is pinned: a `test_usage` clock case asserts, over six instants (whole
seconds, a half second, the epoch, the instant below it, and a leap-day end), that
the two render the same calendar moment and that `iso_utc_full`'s microsecond
field truncates to it. No observable output changed: the hand-rolled subtraction
and `Civil`'s floor agree on every instant measured.

The case needs `seekwright.time` in the suite's libraries, because the whole point
is to see both renderers. One unrelated odoc defect surfaced in the same
`@doc` run and is fixed here: `lib/sanitize.mli`'s comment quoted
`Text without '<' or '[' …`, and odoc parses a bracket as the start of a code
span — the warning was pre-existing, hidden by caching until the library was
recompiled.

### S-008 — the page cache holds four copies of the page shape · **landed**

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

**Landed.** `cached_page`, `of_page` and `to_page` are gone. `get`, `get_window`
and `put` speak `Seekwright_wire.Page.page`, and the store's seam in
`lib/factory/fetch_stack.ml` lost both conversions: the rung dispatch hands the
cache the page it just built and reads one back. What is on disk is one record
with one encoder and one decoder — the page's fields except `text` and `image`,
plus the three cache-only keys `created`, `body_bytes` and `accessed`. `truncated`
is not stored: a stored page is whole, so the entry a read returns is the sidecar
plus the text that read produced, and a windowed read reports the truncation of
the window it cut. `meta_str`/`meta_int`/`meta_float`/`meta_bool` went with the
half-read they made possible (`meta_int` defaulted a missing `status_code` to 200,
`meta_bool` a missing `path_addressable` to false); the decoder now requires every
key the writer emits — `req_str`/`req_int`/`req_float`/`req_bool`, with the two
genuinely optional strings read by `opt_str` — and a missing or mistyped key is a
miss, not a default.

No format version key, because none is needed: the keys and their JSON types are
the ones the previous writer emitted, so an entry on disk from before this change
decodes exactly as it did before, and only a shape this tree never wrote (a hand
edited or truncated file) is newly refused. The null-for-absent convention stays,
and `Page_cache.mli` now says why it is not the wire rule: `lib/wire`'s
absent-field rule governs what leaves the proxy, while a sidecar is a file this
module both writes and reads, where "this page has no title" and "this is not a
sidecar this build knows" have to be tellable apart — the second is what the strict
decoder refuses.

One fixture moved, and it is the interesting diff: the undecodable-body arm of
`a_corrupt_sidecar_is_a_miss` wrote a three-key sidecar, which under a strict
decoder is a miss *for the sidecar's reason*, so the case would have gone on
passing vacuously while pinning nothing about the body. The suite now writes a
well-formed sidecar there (`valid_sidecar`), which doubles as the format pin — a
required key the writer gains turns those arms into misses for the wrong reason,
and the foreign-shape arm beside them is what refuses an unknown shape. The other
17 cases needed only the type annotation changing; the crash-restart, eviction and
concurrency cases read a directory a previous writer process left, and they go
through the current writer, so they pin the new sidecar's round trip too.

### S-009 — `bin/main.ml` carries a second HTTP and TLS stack · **landed**

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

**Landed.** `Main.make_post` and `Main.tls_client_config` are gone, and with them
`cohttp-eio`, `http`, `tls`, `tls-eio`, `ca-certs`, `cstruct`, `ipaddr` and
`mcp-kit-cohttp-eio` as direct libraries of the executable — `bin/main.ml` now
touches `uri`, `eio` and `yojson` and nothing else on the HTTP side. The dial is
`Factory.grant_of_endpoint` over one endpoint, and the endpoint comes from
`Policy_net.endpoint_of_uri` (re-exported as `Policy.endpoint_of_uri`), which is
the same `scheme_of_uri`/`normalise_host`/`port_of_uri` trio `decide_destination`
applies to a request — so the refusal a caller gets for `--server ftp://…` is the
sentence it would have got at the first request, and the grant cannot be built for
a destination the request would then refuse. The RNG ordering the section flagged
is now construction rather than sequence: `tls_config` runs `ensure_rng`, and
`run_client` installs the generator before the grant is built.

Two numbers moved, and both are named rather than invented. The response ceiling
is `Policy.max_configurable_response_bytes` (16 MiB, the widest a grant
constructor accepts) instead of the hand-rolled 64 MiB `Buf_read` limit, so the
ceiling is a grant property the layer enforces rather than a read the caller
remembers to bound; `Factory.grant_of_endpoint` took `?max_response_bytes` for it,
defaulting to `Policy.default_max_response_bytes`, so the funnel is still the only
place a ceiling is set. The CLI is the one consumer that raises it: the response
is this server's own REST projection and its size belongs to `[fetch]` config the
client does not load. That is also the one direction the change tightens — a REST
body above 16 MiB, reachable only by pushing `[fetch] max_text_chars` into the
megabytes, was readable and is now refused.

The per-operation bound is 300 s, where the old client had none. It is not a
config key, because these verbs read no config and loading one would make a
broken config fatal for a verb that never touches it; it is set above what a
served call can take — a ladder walk or an agent run outlasts every single-outbound
timeout this process could name — so the operator's interrupt or the server's own
shutdown stays the thing that stops a CLI request, and the bound exists for a
socket that would otherwise hang forever.

`Cli_client` no longer receives a transport, it receives a `dial`: the origin the
`--server` flag settled on is handed over and the caller answers with the
transport, which is where the confinement belongs. `Cli_client` still names no
config, no key and no provider — the source pin in `test_cli_client` still covers
that — and the argument-before-dial order is pinned, so a malformed command stays
exit 2 whatever `--server` says. `Printexc.to_string` left the path: a failure
sentence is now `Caps.Error.render`, still exit 1.

The gate the section asked for, plus the half it did not name. `bin/smoke*.expected`
and the exit codes are unmoved; `test_cli_client.ml` gained the two seam cases (a
refused origin carries the caller's sentence at exit 1, and the body is validated
before a dial is built). The gap was that nothing ever drove a client verb over a
socket — the suite comment claimed `[bin/]` did, and it does not — so
`test_cli_dial.ml` runs `bin/main.exe search` against a loopback responder owned by
the suite: it pins that the endpoint grant dials loopback at all (which `fetch`
refuses), the `POST /api/v1/search` with both JSON headers and the flags' body, the
rendered line and exit 0 with `SEEKWRIGHT_CONFIG` naming a file that is not there,
and the two failure shapes — an undialable scheme that never opens a socket, and an
unreachable origin that is a transport failure with no policy sentence. Its
port/spawn/wait helpers went into `test/support/binary_harness.ml` and
`test_binary_drain.ml` now uses them, rather than the suite carrying a second copy.

### S-010 — the fallback readers, after R-005 · **landed**

**Evidence (`diff`, window scan).** R-005 removed the duplicated gates and grant
prologue. What remains is the request tail: `Fallback_tavily` and
`Fallback_scrappa` end with the same three status branches, the same
`Fallback.Json.decode_object` and the same `to_page` call;
`Fallback_linkup`, `Fallback_crawl4ai` and `Fallback_jina` vary the numbers and
one sentence. 150 of 490 lines sit in shared windows: `scrappa` 46, `linkup` 36,
`crawl4ai` 32, `tavily` 30, `jina` 6. The status checks are also inconsistently
qualified within a single function (`response.Caps.Authority.Net.status` and then
`response.status`) in all five readers, which is what a reader trip-wires on.

**Fix.** Step 0 is D2's tag erasure — hand each fallback an injected
`check : string -> (string, string) result` guard built once by the factory, drop
the `'tag` parameter from every `Fallback_*.config`, and `fallback_fixtures.ml`'s
scripted resolver goes with it. Then one `Fallback.run` owning status → `Rejected`
/ `Quota` / `Failed`, the decode, and the windowing, with each vendor reduced to
its request and its field map.

**Gate.** `test_fetch_ladder`, `test_fetch_grant`, `test_grant_timeouts` and the
five `test_fallback_*` suites, plus the `fetch` differential goldens that carry
the refusal sentences.

**Landed.** `Remote_target` is a value now: `make_check ~net ~private_web_allowed` returns
`check : string -> (string, string) result`, and `type 'tag t`, `make` and `check` are
gone. `fetch_stack` builds one per rung (`grant_and_check`, and the crawl4ai arm, whose
endpoint is the operator's own config) and one for the local route's preflight, so the
decision about who may resolve a name is made at build time and a reader's config carries
no switch, no address family and no type parameter. All five `Fallback_*.config` records
and all five interfaces lost the `'tag`.

The tail went the same way `Provider.request` did for the search adapters. `Fallback`
owns: `status_rule`, a `(int list * error) list` — the codes a vendor answers and the fact
each means, in the order it wants them tested; `status_error`, which adds the
`Failed "HTTP n"` catch-all every reader had anyway, so a rule supplies only the sentence a
named code earns; `send`, the seam plus the one transport sentence, with the response
ceiling left where the grant puts it; and `send_json`, which runs send → classify →
`Json.decode_object` in that order, so an error page is answered with its status sentence
and never with a JSON parse error. Each vendor's module now states its codes as data at the
top of the file (`tavily` 401/403 and 429/432; `scrappa` 401/403 and 402/429; `linkup`
401/403 and 429; `crawl4ai` 401/403 naming the operator's own key; `jina` 402/429 and
deliberately nothing that reads as an auth failure, because it sends no credential). `jina`
uses `send` and `status_error` rather than `send_json` — its body is `text/plain` — which
is why the two are separate functions and not one. The inconsistent
`response.Caps.Authority.Net.status` / `response.status` qualification the section flagged
went with the fifteen branches it was written in, and `Fallback.transport_error` left the
public interface because only `send` reads it.

The correction the proposal got wrong: `fallback_fixtures.ml`'s scripted resolver does
**not** go away, and deleting it would have cost the suite its best assertion. Five of the
vendor suites pin that a private target is refused *and* that the vendor saw no request
(`check_no_request`), which is only evidence about the vet if the vet is the real one. What
went is the `'tag` on `Remote_target.make`; the fixture now exposes `scripted_net` (for the
suite that pins the gate itself, `test_remote_target`) and `check` (for the five that
inject it), which is the same seam the factory uses.

Line-wise this is close to a wash — the five readers lost 19 lines and `fallback.ml` gained
31, with the interfaces losing the type parameters — so the claim is the ownership, not the
count: one place decides what a status means, one place turns a grant failure into a
sentence, one place orders classification before decoding, and a vendor that adds no rule
row gains no pass. Behaviour did not move: `dune runtest --force` was green with no
promote, and the `fetch` differential goldens that carry these refusal sentences are
unmodified.

## 3. Weight

Items here are measured removals; the contested ones are decisions, and they are
in §4. Two rows are decision-owned — the driver waits on D-A, the matrix tables on
D-B — and land only if those decisions do. The last row is a keep, not a removal.

|Item|Evidence|Action|
|---|---|---|
|The regeneration driver `test/differential/drive.exe` · **deleted (D-A)**|It prints the **OCaml** projection of every corpus case. It is not run by `dune runtest`. Run by hand and followed by a promote, it replaces the 413 frozen goldens with the output of the code under test — the parity gate becomes a rubber stamp and the `explicit-divergence` goldens then fail for the wrong reason|Delete the executable and its stanza; the goldens stay, labelled for what they now are: snapshot pins of this tree's behaviour|
|Pages that describe generators that no longer exist · **corrected (with D-A)**|`ocaml-tools/oracle/` held only `README.md`; `test/differential/dune`'s comment sent a reader to `../../ocaml-tools/oracle/` for regeneration; `AGENTS.md`'s module map advertised "`oracle/` … plus the `DIVERGENCES` table" and its Gotchas still said the table is in `ocaml-tools/oracle/`; `test/differential/README.md`'s layout row and "Regeneration is closed" block still described `drive.exe`|Correct all four to the 12-row `test/differential/divergences.tsv` that §39 recorded, and state the freeze as the reason a golden cannot be regenerated|
|`test/differential/matrix/config-fields.tsv` (63 rows) and `matrix/providers.tsv` (17 rows) · **dropped (D-B)**|Both re-type facts two other artifacts own: the config-key vocabulary is printed mechanically by `ocaml-tools/surface.ml` from `lib/config.ml`'s records, and the per-provider endpoint / auth / cost / live-status facts live in `Factory.Registry.rows` — which is also what `ocaml-tools/egress_lists.ml` renders the deployment's host lists from. 597 lines of `test_differential_matrix.ml` exist to police the hand-typed copies|Drop both tables and the validator's arms for them; keep `matrix/behaviours.tsv` and `matrix/surface.tsv` if the owner wants a per-behaviour evidence pointer. Update `AGENTS.md`'s frozen-surface row and `ocaml-docs/testing.md` in the same commit|
|`Factory` façade|`factory.ml` is 41 lines of `let x = Mod.x` over five private submodules whose own interfaces total 169 lines (`app`, `fetch_stack`, `grants`, `providers_build`, `verdict`), restated by a 238-line `factory.mli` and re-exporting `provider_set`'s two records (21 more lines): three places to edit per entry. `provider_set` is two records and no code, public only because a `private_modules` name in a public signature dangles|Either expose the submodules and delete the façade, or derive `factory.mli` from them; fold `provider_set` into `providers_build`|
|`Registry.row`'s `context : context_cap` · **deleted (with D-B)**|Three constructors, one field, one default and six write sites, read by exactly one thing: the `providers.tsv` row the parity matrix cross-checked. The capability layer's row of the same name had no such field, so the row as first written described a field the dead table consumed and nothing else did|Delete the type, the field, the optional argument and the six `~context:` rows in the same commit as the table — a field whose only consumer is a copy of itself is the copy's|
|`Registry.row`'s `settings : string list` · **deleted**|A hand-typed index of which per-provider keys each builder reads, read only by the suite that policed the index — sorted, complete against a hand-spelled key list, free of `enabled`/`cost_per_1k`, and holding the four names that take a `url`. The key vocabulary itself is derived from `lib/config.ml` by `ocaml-tools/surface.ml`'s `record_fields`; which fields a builder reads is a property of that closure, and a renamed `Config` field breaks the build|Delete the field and the four index cases. Keep the one fact the index carried that a reader needs: which names take a `url` — resolved from the rows' endpoints, with and without an override, instead of asserted from the list|
|`Registry.row`'s `cost_model`|`registry.mli` admits the arrangement: "an adapter mirrors it in its own `cost_for`, and the registry suite pins the mirror." The credit-doubling rule is `Credit_multiplier { over = Serper.credit_over; multiplier = 2 }` in the row *and* `credits max_results = if max_results > credit_over then 2 else 1` in the adapter|One owner. Either the row's model prices everything and the adapters stop exporting `cost_for`, or the row keeps only `default_cost` and `--check --live` reads the adapter|
|`Extractor`'s double representation · **collapsed**|`module type S`, a `backend` record of closures, and `of_module` between them — for the one backend this build can construct (`Config.known_extractors = [ "stdlib" ]`, `trafilatura` refused at load). Beside them, `Extractor.supported_types`: the union of every family, documented as kept for the derived-phrase tests and read by nothing on a serving path|The record is the contract. The backend module exports a `backend` value; `S` and `of_module` go. The union goes with them: the phrase case spells the families it wants to render, and a fake backend in the pool suite claims the family it actually reads|
|`seekwright.fetch.stdlib` as its own public library · **folded**|One module in its own stanza, library and public name, justified by "a future backend with its own dependencies" — while its only imports are the stdlib-only floor `seekwright.fetch` already links. Twelve `(libraries …)` entries and seven consumers name it for one `Extractor.of_module` call|`lib/fetch/extractors/stdlib.ml` becomes `lib/fetch/extract_stdlib.ml` inside `seekwright.fetch`; the stanza, the public name and the twelve link sites go. A backend that does bring dependencies is still its own library, and the fetcher keeps taking the backend injected either way. The two `behaviours.tsv` pointers move in the same commit|
|Adapter `.mli` internals exported for the suites|738 lines of adapter interfaces export `parse`, `cost_for`, `credit_over`, `policy_endpoint`, `request_body` so suites can reach them. `policy_endpoint` is `Provider.policy_of_uri endpoint`, and the suites then assert its host, scheme and port against a constant the same suite already asserted from `endpoint`|Seal the interfaces to `name`, `endpoint`, `make` and what the factory reads; delete the derived-endpoint cases (Q-001's standard: a name carries it where it can)|
|One-use and one-element helpers|`Config.permitted_fetch_names = [ "jina" ]` is a vocabulary list with a single member, driving the same refusal code path built for many|Leave it: `config.mli`'s doc and the comment above the definition already say it is the only non-provider name `permitted_providers` may hold. The plural is the vocabulary's shape, not an open set|

## 4. Decisions the maintainer owns

Each carries a recommendation. D-A, D-B and D-G are decided (2026-11-17, the maintainer);
D-C … D-F stay open.

**D-A — the differential harness's posture.** Keep the 413 goldens and the
properties, delete `drive.exe` and the oracle README, and rename the suite's own
claim from "does the port answer this the way the baseline did" to "does this
behaviour still hold". *Recommend: do it.* The alternative — keeping a driver
whose only effect is to re-pin goldens from the code under test — is a
foot-gun guarded only by nobody running it.

**Decided: do it.** Landed with the four page corrections the §3 rows name, plus the
corpus claim renamed in `ocaml-docs/testing.md`, `test/differential/README.md` and
`test/differential/dune`. `ocaml-tools/oracle/` is gone, so `ocaml-tools/` is now the
three tree-reading instruments and the bench; the recorded history in
`plans/seekwright-ocaml-port.md` §9 keeps its wording, because it records what landed
then, and §41 records the deletion.

**D-B — the parity matrix.** Options: keep all four tables; drop
`config-fields.tsv` + `providers.tsv` (the two hand-typed vocabularies, 80 rows
and their validator arms); drop all four. *Recommend: the middle one.* The
remaining `behaviours.tsv` (23 rows) and `surface.tsv` (16 rows) name an evidence
pointer per behaviour, which nothing else in the tree records; the dropped two
duplicate `ocaml-tools/surface.ml` and `Registry.rows`.

**Decided: the middle one.** Both tables went, with `check_provider_names`,
`closed_columns` and `check_closed` — the provider row set's only other consumer — and the
validator is 90 lines shorter over two tables. The behaviour/surface evidence pointers
stay, and the refused-key fact the `config-fields` rows carried is pinned where it is
owned: `ocaml-docs/configuration.md` names both keys and `test_config.ml`'s resolve cases
refuse them. The mutation row the harness page credited to `providers.tsv` was re-run
against a `behaviours.tsv` row before it was rewritten, so the page still records a check
that actually fails.

**D-C — `Caps.Budget`.** `with_operation_budget` is never called from `lib/`: its
callers are `test_caps_budget.ml` (431 lines), `test_caps_audit.ml`,
`test_authority_net.ml`, `should_not_compile/grant_path.ml` and
`examples/gated_search.ml`. No served grant carries a budget, so the operation
ceiling `mcp-caps` advertises is unenforced in this deployment. Options: delete
the seam (21 lines of accounting, the refusal sentence, and the suite; two of the
fourteen change and re-promote their pinned diagnostics — `grant_path.ml`, the
positive half, uses `Budget.make`, and `controls_record_forge.ml` forges a
`Controls.t` whose `budget` field goes with the seam), or give `Agent`'s fixed
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
anything. One thing must be re-homed if the pool goes: the `Timed_out` path is what
renders the `fetch.timeout_seconds` refusal (`Fetcher` maps it to
`parse_timeout_refusal`). The byte ceilings are not the pool's to move —
`Extract_pool.extract` takes no size bound; the request ceiling is
`fetch.max_download_bytes`, passed at `Fetch_stack`'s pool construction, the
response ceiling defaults to four times it, and the download cap is already
enforced fetcher-side by `Fetcher.cap_body` on the grant-delivered body. Note that
the corpus bar is a wall-clock ceiling and load-sensitive, so a single A/B pair on
a busy machine is not evidence — the bar is not to be moved to make a run green.

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
route Parallel's REST-half constraint clauses through
`Provider.ignored_constraints` (S-001) — Exa's already call it; what Exa composes
privately is the escalation reason, the ladder's own notice, not a constraint
report — and write down in the port plan that the per-adapter cooldown is a
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

**Decided and applied, ahead of S-001.** `.ocamlformat` pins ocamlformat 0.29.0
with `margin = 100`, `break-cases = fit`, `module-item-spacing = preserve` and
`sequence-blank-line = preserve-one`; margin 100 and the two spacing options are
what keep the reformat close to the style the tree already has (only 1,550 of
its lines were longer). One commit reformatted all 272 `.ml`/`.mli` files:
about 15,800 lines each way over 251 files. No `.expected` golden moved and no
`test/should_not_compile` diagnostic moved — the snippets' line numbers survived.
What did move is one class of test: `test_caps_audit`'s source needles quoted a
call across a line break and one ended in `)`, which is the formatter's paren
docking, not the code's. `Test_support` now matches source needles with
whitespace collapsed (`source_includes`, `source_excludes`,
`source_count_occurrences`) and the `)` is gone from that needle; the
`includes`/`excludes` pair still matches prose byte-for-byte. The follow-through landed
with the §3 weight rows: `dune build @fmt` is clean over the whole tree — ocamlformat over
the sources, dune's own formatter over the stanzas — and `ci-ocaml.yml` runs it as a step,
so the pin is checked rather than instructed. `AGENTS.md`, `CONTRIBUTING.md`,
`ocaml-docs/testing.md` and the `ocaml` skill describe the four-target gate.

## 5. Landing order

Each step is one reviewable commit, gate green on its own, with the plan updated
in the same commit.

|Order|Step|Expected effect|
|---|---|---|
|0|D-G formatting: pin `.ocamlformat`, reformat the tree — the maintainer's call, taken ahead of step 1|**landed** — one-shot reformat of 272 files, ~15,800 lines each way; `Test_support`'s source needles made whitespace-insensitive. The claim that no pin moved was wrong: five `should_not_compile` diagnostics quote the snippet's own source line, so the sweep re-pinned them, and `dune runtest` has been red on them since — three of the five stayed hidden behind a cached `.out` until a library change invalidated it. Re-pinned with step 2|
|1|S-005 micro-duplication: the percent-encoder, `base64`/`grouped`, the `Utf8` re-export shim|**landed** — small, no golden, no re-pin|
|2|S-001 adapter skeleton, `take` landing in `Provider`|**landed** — −511 lines in `lib/providers/`, +225 in `lib/provider.ml` and its interface (net −286, short of the estimate for the reasons in §2); 13 of 14 REST adapters on the shared tail, `parallel` onto the shared sentence with its per-bucket clauses kept word-for-word|
|3|S-002 test harness|**landed** — −659 in the sixteen adapter suites, −80 in the six journal suites that copied the JSON accessors, +242 in `test/support/` (net −497, short of the estimate for the reasons in §2); one harness for the `Net` mock, one for the accessors, four contract-duplicate cases deleted|
|4|S-003 one dispatch per verb, answering Q-002|**landed** — three dispatch functions, six call sites collapsed; Q-002 answered (the types stay, the call is shared); the `api_answer` pre-check asymmetry resolved by pre-checking on both surfaces, so an unbuilt `answer` pin is `invalid:` on the tool call and 400 on REST|
|5|S-004 field lists, then S-006, then S-007|**landed** — S-004: ten key lists, one per wire model, read by `reject_extra` and by the schema builder, with the schema mismatch reported by name through `Server.untabled_wire_fields` and failed by a suite because `lib/server.ml` may not raise (net +82, all three pins byte-stable). S-006: one `answer_metrics` record and one `(key, getter)` vocabulary feeding the journal line, `Agent`'s log line and the manifest's `[answer]` row, which was a third hand-typed spelling (+10 in `lib/`, +48 in the two suites, `surface.expected` unmoved at 37). S-007: `Civil.clock_of_instant` keeps the fraction, `Usage.civil_of`'s hand-rolled floored division is gone, and the journal's `+00:00` key and the model-facing `Z` are documented apart and pinned equal by a clock case|
|6|S-008 page cache, S-009 the CLI grant|the cache stops hand-rolling a codec; `bin/main.ml` stops owning a TLS stack|
|7|S-010 fallback readers, lifting D2|the `'tag` goes, one `Fallback.run` owns the tail, and the factory builds the host check once|
|8|§3 table + D-A/D-B docs|`context`, `settings`, `cost_model`, the façade and the extractor duality go; the driver and the two matrix tables only if D-A/D-B decide so; `AGENTS.md`, `ocaml-docs/testing.md`, `test/differential/README.md` and the port plan move in the same commit|
|9|D-C … D-F, one decision at a time (D-G landed as step 0)|each needs its own page section and, for D-E, an operator-visible behaviour change|

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

## 8. Review record — 2026-11-17

Reviewed and corrected against the tree at `742a9c7`; the code is unchanged from
the `6e4ad90` read (the diff between them is plans only). Every `read`/`diff`
claim was re-probed; the substantive corrections, now folded into the sections
above:

- **§1 walls.** The dangling IDs (`S-016`/`S-017`/`S-014`) resolved to S-001,
  S-010 and D-C. The floor rule corrected: `seekwright.providers` and
  `seekwright.cli` link `seekwright`, so only a fetch-shared helper is forced to
  the stdlib floor — R-009's `Civil` has no fetch-side consumer, and S-001's
  `take` and S-005's percent-encoder belong in `Provider`. D2 is a deferral S-010
  proposes to lift, not a binding wall.
- **S-001.** Serper/Serpapi differ in one record key, not three lines; the take
  census is fifteen list-take bodies in twelve adapters plus `Algolia` and
  `Usage` (`Tabledoc.take_chars` is string truncation, not a list take, and is
  out); `make` is the same shape in fourteen modules, not identical fifteen
  times; the shared search tail covers the thirteen REST adapters, `parallel`'s
  REST half spelling it inline; `compose_notices` is ~38 lines with a
  payload-dependent warning tail, so `notice` reads the decoded JSON; Exa's
  constraint notices already call `Provider.ignored_constraints`.
- **S-002.** The suite set named and recounted (9,217 lines under §0's
  convention, not 9,545); helper counts restated with the counting rule
  (17/15/14/14/13/12/6); the seven `chars` copies are byte-identical and diverge
  from `Utf8.count` on ill-formed leads; thirteen suites re-drive contract
  failure rows, not 12–13 transport/malformed specifically.
- **S-003 / S-004.** Nine labelled arguments, not ten. Four spellings per model,
  not five to six; the `*_allowed` lists already exist; `fetch_response_schema`
  carries the page set, not the result set; `include_domains` encoding is three
  sites, not five; the missed-schema guard is `bin/smoke.expected`, not the
  surface manifest's field counts.
- **S-005 / S-007 / S-010.** No `Cli_*` consumer of either escaper, so `Provider`
  ownership suffices. `civil_of` already calls `Civil`'s day arithmetic; the
  residue is the float seconds-of-day and clock split, and `seconds_of_day` is
  `int -> int`. The qualification mix is in all five fallback readers.
- **§3.** The driver and matrix rows marked decision-owned; the pages row gains
  `test/differential/README.md`; the credit quote is `> credit_over`; the jina
  doc already states singularity, so the row is a keep.
- **§4.** D-C re-pins a second diagnostic (`controls_record_forge.ml`). D-D: the
  pool has no `max_entry_bytes` linkage — its ceilings are `max_body_bytes`
  (`fetch.max_download_bytes`) and `max_result_bytes` (4×), and `Fetcher.cap_body`
  already enforces the download cap; only `Timed_out` must be re-homed. D-F: only
  Parallel's REST half needs routing; Exa's private composition is the escalation
  reason.
- **§5 / §0.** `take` lands with S-001, not S-005; S-010 inserted as its own step;
  the line-count convention stated (`wc -l` + 1 per file; `.mli` in the two
  whole-tree scopes).
- **Landing (steps 0–2).** The step-0 cell's "no golden moved" was measured on
  the prose, surface and egress pins only: the sweep also moved five
  `should_not_compile` diagnostics, which quote the snippet's source line, and
  the tree has been red on them since `eec2e7a`. Re-pinned alongside S-001; the
  refusals themselves are unchanged, so the capability boundary holds. S-001's
  measured line counts replace its −700–900 estimate in §2, and the shared
  `check_status` needed a third argument the sketch did not have.

**As reported, not re-run:** the window-scan aggregates (984/150/3,604/5,343, the
per-file numbers, the 73 querit/search1api windows, S-006's nine windows, the
intra-file percentages) and the −700–900 / −1,800 line estimates. §0's recipe is
reproducible; the scan itself was not re-executed for this review. The gate was
not run — this is a plans-only edit.

**Sign-off:** the plan's measurements and proposals are verified against the tree
as corrected above. The §4 decisions (D-A … D-G) remain the maintainer's; §5
steps 0–2 are landed and recorded in their sections, the rest is proposal, and
no entry was added to `plans/reviews/code_review_ledger.md`.
