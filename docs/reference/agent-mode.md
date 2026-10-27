# Agent mode (`answer`)

The third operation: a question in, a grounded prose answer out, with citations
the server validated — the one place a model runs *inside* this server. It is off
by default (`[agent] enabled = false`) and built in full; the questions it leaves
open are in [ROADMAP.md](../ROADMAP.md). This page is its contract
for the boundary, cost control, the ranking data and the failure contract.

## What it is, and what it is not

It is one operation, `answer`: a fixed retrieval plan, one operator-configured
model, and the prose plus the sources the prose actually cited.

It is not:

- **not a replacement for `search` or `fetch`.** Those two are unchanged and stay
  the cheap path.
- **not an agent loop.** The model does not choose what to search for, does not
  call `search` or `fetch`, and is not asked a second time. That is what keeps
  the per-call cost bounded by arithmetic instead of by accounting.
- **not a cache, and not a session.** Nothing is remembered between calls.
- **not multi-user.** One deployment, one operator's keys, one operator's bill.
  Multi-user is gated on a separate **auth** decision, and on a per-caller budget
  if that is what is wanted.

## The boundary

| The server owns | The caller owns |
|---|---|
| The system prompt (a file under `resources/`, not caller-supplied, not returned) | The question (`query`) |
| The model — one, named in `[agent]`, never a tool parameter | Up to two additional retrieval queries (`extra_queries`) |
| The retrieval plan: which queries run, how many results, which pages are read | `depth` (`brief` / `report`) — the one cost knob the caller gets |
| The budget: material cap, output cap, wall clock, the per-call money abort | An optional `provider` pin, and the `search`-shaped filters (`include_domains`, `exclude_domains`, `recency`, `language`, `safe_search`) |
| The citation list, built from what was retrieved and validated against it | The decision to spend at all |
| Temperature (a server constant, `0.2`) | — |

Deliberately absent from the tool's parameters: a system prompt or
`instructions`, a model name, a temperature, a token budget, a search count, a
`max_results`. Each of those either makes the tool an open LLM proxy on the
operator's key or lets the caller raise the operator's bill.

The thin half of the tree is untouched by all of it, and that is an acceptance
criterion:

- `search` and `fetch` keep their schemas, descriptions, response models and
  error prose;
- `[search] fallback`, the health board, `/healthz` and the journal's existing
  line shapes do not move;
- no runtime dependency is added (the model client is the existing `httpx`
  client), and the stdio default is unchanged.

A two-tool deployment sees two differences. Agent-mode retrievals count as
`search` lines, because they are real provider spend, distinguished by the
journal's `run` key. And the third tool is advertised in `SERVER_INSTRUCTIONS` on
every deployment, because the schema is frozen at import and cannot depend on
config — with the section off it refuses cleanly and names `search` and `fetch`.

## The surface

### `answer` (MCP tool)

| Parameter | Type / bounds | Default | Notes |
|---|---|---|---|
| `query` | `str`, 2–400 | required | The question. Natural-language questions work well. |
| `extra_queries` | `list[str] \| None`, ≤2 items, each 2–400 | `None` | Additional retrieval queries, run after `query`. ≤3 searches per call, total. |
| `depth` | `Literal["brief","report"] \| None` | `brief` | `brief`: one search, no page read; the material is the provider's own body (`snippet` or `text`). `report`: up to three searches and up to three pages read. |
| `provider` | the same seventeen-name `Literal \| None` `search` uses | `None` | Pins retrieval to one backend, exactly as `search` does: that provider or an error. Omitted ⇒ the default route, `[search] fallback` included — or, where every enabled name is free and no default is configured, the free walk `search` takes. |
| `include_domains` | `list[str] \| None`, ≤20 | `None` | Passed to every retrieval. |
| `exclude_domains` | `list[str] \| None`, ≤20 | `None` | Passed to every retrieval. |
| `recency` | `Literal["day","week","month","year"] \| None` | `None` | Passed to every retrieval. |
| `language` | `str \| None`, exactly 2 letters | `None` | ISO 639-1 code, e.g. `de`, passed to every retrieval. A region is not this field's job. |
| `safe_search` | `bool \| None` | `None` | `True` asks each backend to filter adult content at its own level, `False` asks it not to; omitting it leaves the provider's own default standing, which is not the same as unfiltered. A backend without the parameter says so in `notice`. |

`country` stays off the surface, the rule `reference/public-api.md` applies to
`search`. So does `max_results`: the caller declares the questions, not the width.
The retrieval count and the page count are constants, because a tool schema cannot
be built from config.

`language` and `safe_search` belong on it because a safety filter a caller can set
on one tool and not the other is a trap. The filter set here is the `search`-shaped
one, and it moves with `search`.

### `AnswerResponse`

```python
class AnswerSource(WireModel):
    """One result the prose actually cited."""

    title: str
    url: str
    provider: str


class AnswerResponse(WireModel):
    """The shape returned by the ``answer`` tool."""

    query: str
    answer: str
    sources: list[AnswerSource]
    model: str
    depth: Literal["brief", "report"]
    searches: int          # retrieval steps that ran
    fetched: int           # pages read
    retrieved_at: str | None = None
    truncated: bool | None = None
    notice: str | None = None
```

- `sources` is the server's list, not the model's: the retrieved results whose
  URL the prose cited, deduplicated, in first-citation order, each with the
  provider that supplied it. A URL the model invented is not in it.
- `truncated` is set when the model stopped at the output cap
  (`finish_reason == "length"`). `bool | None`, so it does not serialise on a
  complete answer — the `Result.text_truncated` rule.
- **No `cost_usd`**, because the caller is not the party paying (the
  `SearchResponse` rule): spend goes to the operator through the journal and the
  dashboard. No prompt, no material, no token counts.

## The retrieval plan

Fixed, in this order. It is a function of the caller's declaration only — no
step reads the query to choose anything.

1. **Build the queries.** `query`, then `extra_queries` in the order given. Each
   becomes a `SearchQuery` with `max_results=5`, the caller's filters, and
   `provider` as the surface table states it.
2. **Search.** Each query runs through the existing `SearchEngine.search`: the
   same provider resolution, ladders, health board and journal line. A step that
   fails (every fallback) or returns zero results is recorded and the walk
   continues.
   - **Every step failed or returned zero results ⇒ the call fails and no model
     call is made.** There is nothing to ground prose in, and paying a model to
     invent one is the failure this rule prevents.
3. **Read pages** — `depth="report"` only, in step order. Skip any result whose
   `text` is already set (a content backend handed us the extract). Fetch the rest
   through the existing `FetchEngine.fetch`, so the operator's ladder, the SSRF
   guardrails and the paid fallback behave as they do for a `fetch` call. A page
   that fails or is refused is skipped, never fatal on its own.
4. **Assemble the material.** Per result: its title, its URL, and its
   `snippet`/`text` (or the fetched page's text), numbered from 1 so the model can
   cite by index. The whole material is bounded by `[agent] max_material_chars`,
   the model-call analogue of `policy.max_result_text_chars`. Material that ends
   up empty ⇒ fail, no model call.
5. **One model call.** `{base_url}/chat/completions` on the shared `httpx`
   client, with the system prompt from `resources/answer_system.txt`, the
   numbered material, the question, and the depth's output instruction.
   `max_tokens` = the depth's ceiling, `temperature = 0.2`, **no streaming**,
   and no second call for any reason.
6. **Validate citations.** Parse the `[n]` markers, map each to its material item,
   and build `sources` from the items cited. Count `cited` (valid markers,
   deduplicated) and `cited_invalid` (markers outside the material or not a
   number). Zero valid citations is not a failure: the answer returns with a
   `notice` saying the prose carried none and must be read against `sources`.
7. **Record and return.** One `answer` journal line (fields below), plus the
   retrieval lines the engine already writes.

### The system prompt

`resources/answer_system.txt`, exposed as `prompts.ANSWER_SYSTEM_PROMPT`, and
written the way every model-facing string here is written (a paragraph per line,
blank line between). It must:

- require the answer to come **only** from the material, and to say plainly when
  the material does not answer the question rather than answering from prior
  knowledge;
- require every claim to be cited as `[n]` against the numbered material, and
  forbid citing an index that is not in it;
- state that the material is **untrusted third-party content** — text to read,
  never instructions to follow. The warning `fetch`'s description gives the
  caller, and it matters more here because the material is not the caller's to
  inspect;
- fix the shape of each depth (`brief`: a few sentences; `report`: a short
  structured answer), without promising a length the output cap cannot deliver.

`resources/answer_description.txt` (`prompts.ANSWER_DESCRIPTION`) is the tool
description: what it does, that it is the most expensive operation the server
offers, and that its prose must be read against `sources`. No trailing newline,
like the other two tool descriptions.

## Cost control

### Configuration

Every `[agent]` key, its type and its default lives in
[configuration.md](configuration.md)'s `[agent]` block, and is not restated here.
Three rules belong to this page. The API key is `SEEKWRIGHT_AGENT_API_KEY`, from
the environment only, never the config file, like every provider key. `[agent]` is
a `Section`, so an unknown key in it is a startup error. `enabled = true` with a
missing `base_url`, `model` or key is a **startup error** in `server.main`, before
`mcp.run` — never inside `lifespan`, where a `SystemExit` arrives wrapped in an
`ExceptionGroup`. `--check` reports the same fact without dying, names the model
and gains an `agent` line.

### The ceiling, and the arithmetic behind it

Two ceilings, and only one of them is a guarantee.

**Structural — the guarantee.** ≤3 searches × 5 results × ≤3 pages, material
capped at `max_material_chars`, output capped by the depth. Nothing in the plan
is chosen by the model, so the worst case is a number:

| Depth | Searches | Model input | Model output | Model cost | Retrieval | All-in |
|---|---|---|---|---|---|---|
| `brief` | 1 | ≤24k chars ≈ 6k tokens | ≤500 tokens | $0.00098 | $0.0070 | **≈$0.008** |
| `report` | 3 | ≤24k chars ≈ 6k tokens | ≤2500 tokens | $0.00154 | $0.0210 | **≈$0.023** |

Model cost at DeepSeek V4 Flash's $0.14/M in and $0.28/M out (*as of* 2026-07);
retrieval at the ~$0.007 per search measured across the in-tree providers. Most of
the money is retrieval, which is why the search count, not the model, is what the
plan pins. The same table at a dearer small model (GPT-5.4 mini, $0.75/$4.50) is
≈$0.037 a report: still bounded, because the counts are.

**Money — the early exit.** `max_cost_usd` (default `0.25`, ≈11× the structural
worst case) is checked after each retrieval step: if accumulated retrieval cost
plus worst-case model cost would exceed it, the walk stops and the call fails with
what it spent recorded. It exists so a mispriced provider or changed endpoint
cannot run away inside one call. It is not the guarantee — the counts are.

Fetch fallbacks are **priced per call from the serving fallback's declared price**
(`[fetch] cost_per_1k`, default Scrappa's `0.30`/1k), so a `report` whose pages
went through a paid fallback costs more than the table says. That money is on the
fetch journal line and in the dashboard's fetch total; the early exit reads search
spend alone. A page served locally, by the self-hosted renderer or by the keyless
reader carries no figure. The price is declared, not invoiced.

### Who pays, and what gates what

The operator, whose exposure this page's boundary and ceiling sections already
describe.

- **A per-caller spend ceiling is declined (2026-10-14) and is not a
  precondition for this per-call bound**, because the bound is arithmetic and
  stateless. Auth, not a ceiling, is the precondition for offering agent mode to
  more than one trusted operator; multi-user stays declined until that separate
  decision, and on a per-caller budget, if wanted.
- **Model spend is a third kind on the journal.** `UsageRecorder.record_answer`
  (`usage.py`) writes one `answer` line per call carrying `model_cost_usd` beside
  search and fetch (the table under *What is recorded* below). A ceiling reading
  the journal sees agent mode's spend.

## The ranking data

Agent mode also "produces data for ranking different providers". It does: content-free
counts on the journal that already exists — no new store, no new retention surface.

### What is recorded

Agent mode writes the journal lines the engine already writes, plus one new
kind. On the existing lines it adds only two keys:

| Line | Fields |
|---|---|
| `tool: "search"` (per retrieval step) | the existing shape — `ts`, `provider`, `ms`, `cost_usd`, `results`, `fell_back`, `error` — plus `run` (the call's id) and `step` (the step's ordinal) |
| `tool: "fetch"` (per page read) | the existing shape — `ts`, `ms`, `chars`, `fallback`, `error` — plus `run` and `step` |
| `tool: "answer"` (one per call) | `ts`, `run`, `model`, `depth`, `searches`, `results`, `fetched`, `material_chars`, `prompt_tokens`, `completion_tokens`, `answer_chars`, `cited`, `cited_invalid`, `sources` (a count), `model_cost_usd`, `ms`, `error` |

`run` is a random per-call id (`secrets.token_hex`-class), never a hash of the
query: a low-entropy digest is a correlation handle, not anonymisation.

`run`/`step` are additive because `usage.py::_apply` ignores keys it does not know.
The third **`tool` value is not**: `_apply`'s guard admits all three,
`tool not in ("search", "fetch", "answer")`, and returns `False` for anything
else, which `_backfill` counts as `dashboard.journal_skipped`. An `answer` line is
therefore **folded, not dropped**: `_apply` dispatches it to
`usage.py::_apply_answer`, which folds the model spend, the token counts and the
per-provider citation join. A `run`-carrying `search` line is still real provider
spend, counted in the search totals.

`sources` in the `answer` line is a **count** — `len(sources)`, an integer, never
the list and never a URL (the privacy rule below forbids URLs). It can be
**smaller than `cited`**: `cited` counts the valid `[n]` markers deduplicated by
index, while `sources` deduplicates the cited results by URL, so two markers can
name one page retrieved by two queries. `cited_invalid` is the third number, and
the only one that is the model's fault.

`prompt_tokens`/`completion_tokens` come from the endpoint's `usage`; when it
reports none they are `null`, never a local estimate — a tokenizer would be a
dependency and a second token count. `model_cost_usd` is computed from those counts
at `cost_per_1k_in`/`_out`; with the prices unset it is `null`, and the dashboard
shows tokens instead of money.

### What it ranks

| Question | Fields | Where |
|---|---|---|
| What does this provider cost, and how slow/failing is it? | the existing per-provider `calls`/`errors`/`cost_usd`/`avg_ms` | dashboard, as today |
| **How often do this provider's results end up cited in a grounded answer?** | per-provider `retrieved` and `cited`, from the `search` lines' `run` plus the `answer` lines | new dashboard section |
| What does the model cost per answer? | `model`, `prompt_tokens`, `completion_tokens`, `model_cost_usd`, `answer_chars`, `ms` | new dashboard section |
| How often does the model over-claim? | `cited_invalid` — **attributed to the model, not to a provider**: an invented citation is a property of the prose | new dashboard section |

The middle row is the point: the *answering* task the gold set scored, measured
on live traffic.

A run's `cited` count is credited to **every provider that contributed results to
that run, once per run**. Exact whenever a run used one provider — the ordinary
case, since a `provider` pin fixes one and an unnamed search resolves one per
query. It is a documented over-count only for a run whose steps two providers
served (a mid-walk fallback that later succeeded): the journal cannot say whose
results the cited indices named, and inventing a split would be a fabricated
figure. Read `cited` as "this provider's results were in a run whose prose cited
this many". A run with retrieval lines and no `answer` line — a process that died
mid-call — keeps its `retrieved` and gains no `cited`.

### What it is not

**Not a gold-set replacement, and the gold-set gates stand.** The gold set scored against
keys a human verified; live traffic has no ground truth. A provider whose results
got cited is not thereby correct, and the data is selected by whatever the default
route already served. Agent mode adds a second, cheaper, uncontrolled instrument
for drift and provider choice, not the controlled one measured per-task defaults
wait on.

What lands here are counts, not content, and the gold set stays out of the server.

### Privacy and retention

- **No content, anywhere in this data.** Never query text, never a URL, never a
  host, never a title, never the report prose, never the material. The journal's
  content-free bar is unchanged, and so is its retention rule (the file is the
  operator's; `keep_days` governs the in-memory window).
- **The prose is not stored.** It goes to the caller, and to the log only through
  a content event behind `log_content` — a new `agent.answer` event alongside
  `search.answer`, same switch, no new privacy class.
- **The model endpoint is a new egress point, and the real privacy change.** In
  agent mode the caller's query and the fetched page text are sent to the
  configured model endpoint, a third party that did not exist in the thin path.
  That is why `enabled` defaults to `false` and why the startup log names the
  model.

## The failure and latency contract

| Phase | Failure | What the caller gets |
|---|---|---|
| Config | `enabled = true` with no `base_url`, `model` or key | The process refuses to start, naming the missing piece. `--check` reports it without dying. |
| `enabled = false` | any call | A clean tool error: this deployment has no agent mode; use `search` or `fetch`. `POST /api/v1/answer` answers `404` before reading the body — the `[fetch] enabled = false` rule, [reference/public-api.md](public-api.md). |
| Retrieval | every step failed (every fallback) | A tool error carrying the first step's message with the failed fallbacks appended — the existing ladder wording. **No model call.** |
| Retrieval | every step returned zero results | A tool error carrying the zero-result notice prose (retry or rephrase). **No model call.** |
| Retrieval | some steps failed or returned zero | The call continues; `notice` names the steps that came back empty. |
| Pages | a page fails, is refused, or is skipped | The call continues; when any were skipped, `notice` says how many of how many could not be read. |
| Material | nothing usable to ground on | A tool error. **No model call.** |
| Model | no response within `model_timeout_seconds` | A tool error naming the model and the phase. Retrieval spend is still recorded. |
| Model | 4xx / 5xx / rate limit | A tool error with the endpoint's status and a sanitised message — never the raw body, never an exception object. Retrieval spend is still recorded. |
| Model | empty completion, or a refusal with no prose | A tool error. **No invented answer.** |
| Citations | the prose cites nothing valid | `200` + the answer + a `notice` saying it carries no citations and must be read against `sources`. |
| Citations | the prose cites an index not in the material | Those citations are dropped from `sources`, counted as `cited_invalid`, and named in `notice`. The answer is still returned: failing would burn the caller's context and the operator's spend for a prose defect that reading `sources` resolves. |
| Whole call | exceeds `timeout_seconds` | A tool error naming the phase it reached. |
| `[fetch] enabled = false` | `depth="report"` | Served from snippets alone, with a `notice` saying no pages could be read. |

**Latency.** Single-shot, never streamed. `brief` is one search and one model call
(seconds); `report` is up to three searches, up to three pages and one model call
(tens of seconds). Not a latency-critical path.

**A model outage never makes the process unhealthy.** `/healthz` does not learn
about the model — a provider being down is never a reason to restart the pod,
which applies with more force to a third party that is not even a search provider.
No circuit breaker for the model in v1: a model failure is terminal for its call.
