# `fetch`: a provider field, and what replaces the silent ladder

`fetch` names its provider: the tool, the REST body and the CLI verb each take a
`provider` field, a name this server cannot serve is refused with the list of the
names it can, and the ladder stops walking itself unless `fetch.auto_fallback`
turns the walk on. One entry of a ladder is a **fallback**, in the config keys,
the identifiers, the log events and the journal field alike. Each rule below
carries its own reason: a walk that chooses silently hands the caller a failure
it cannot act on and spends a credit nobody chose.

Where this page states what is in the tree, it names the code symbol it reads,
never a line number.

## 1. `fetch` takes a `provider` field, and it may name anything

**Decision.** `FetchRequest` gains `provider: str | None`, and the MCP tool
gains the matching parameter. It is a plain string, not a `Literal`, for the same
two reasons `SearchRequest.provider` gives itself: which names this deployment
can run is a config fact the schema cannot know at import time, and the frozen
surface manifest would have to move for every name the registry gains.

**What it may name.** Any name in the fetch registry, whether or not this
deployment runs it. Three cases collapse into one answer:

- the name is unknown to the registry (`scraper`),
- the registry has it and this deployment has not built it (no
  `SEEKWRIGHT_SCRAPPA_API_KEY`, no `fetch.crawl4ai_url`),
- the operator's permission set excluded it, so `factory.build_fetch_stack`
  never built it.

All three are refused **before anything is dispatched**, by a fetch-side
`FetchEngine.resolve` that mirrors `SearchEngine.resolve`, and the sentence names
the names that *are* available. Nothing is billed by a refusal, and the caller is
the only party who can act on it. A name from the search set (`serper`) lands in
the same case: it is unknown to the fetch registry, and the list in the answer is
the fetch list, not the search list.

**What it does not name.** There is no name for the local fetcher, and no
`provider = "local"`. Omitting the field *is* the local read, which is what
`search` does with its default and what the REST body and the CLI flag both
follow. A name for it would be a fourth value set to freeze for no caller
benefit.

**A named provider is served as named.** When the name resolves, it is the one
attempt: no second guessing, no substitution. That is `search`'s rule verbatim —
*a price named is a price paid* — and it is what makes `provider` usable as a
cost knob rather than only as a retry knob.

## 2. The ladder stops by default and names its members

**Decision.** The walk becomes opt-in. New key `fetch.auto_fallback`, boolean,
default `false`.

| `fetch.auto_fallback` | The local read fails | The local read comes back nearly empty |
|---|---|---|
| `false` (default) | the failure names the configured fetch providers as a choice | the page comes back with a `notice` naming them as a choice |
| `true` | the walk runs, in config order, as today | the walk runs, as today |

`fetch.fallback` keeps its current meaning and gains one more: it is the list the
failure message prints, and so the menu a caller may name. Nothing new is
configured, and the key stays load-bearing with the walk off.

**The tier rule does not move.** The validator over the list is untouched, and
it carries the standing promise: a name that can bill belongs last, so *"a page
reaches every free fallback before a credit is spent"*, and at most one billable
name may appear at all. It reads `billable` off each registry row rather than off
a vendor name, so a priced vendor this build has never heard of inherits the
rule. `fetch.auto_fallback` says whether the walk runs; it cannot
reorder it, and it cannot admit a second priced name.

**The `answer` plan keeps the walk.** A search-and-fetch walk inside `answer` has
no caller between its steps: a refusal there is a lost page, not a choice, and
the plan would silently read less on JavaScript-heavy sites the moment the
default flipped. So the walk is a property of the route, not only of the key: the
interactive routes (MCP tool, REST, CLI) stop and report, and the plan asks for
the walk. The mechanism is an explicit argument on the fetch call, not a
reading of the `run`/`step` journal fields, which are observability and must not
become load-bearing.

**Unchanged:** the emptiness gate still arms only at offset 0; an image still
never walks; a member that cannot run is still absent rather than fatal, and
`seekwright --check` is still where *why* is printed.

## 3. The messages, and where each one lands

The wording follows `search`'s zero-results recovery sentence: state what came
back empty, list the alternatives, say what the symptom usually means, and tell
the caller to retry once before concluding.

```
Fetch failed - {reason}. Other configured fetch providers: {names}. Retry once
with `provider` set to one of those before concluding the page cannot be read.
```

```
Almost no readable text came back from the local fetcher. Other configured fetch
providers: {names}. A page that extracts to nothing usually needs a browser, not
a second try at the same reader: retry once with `provider` set to one of those
before concluding the page has no text.
```

```
Fetch provider {name!r} is not enabled on this server. Available: {names}. Retry
with one of those, or omit `provider` to read the page locally.
```

With no fetch provider configured, the middle clause becomes `No other fetch
provider is configured on this server.`, which is `search`'s *"`{name}` is the
only enabled provider"* of the same shape. With the walk on and every member
failed, the caller is not offered a choice it has not already had, and the
sentence reports what was tried instead — `Fetch failed - {reason}. Fallbacks
also failed: {names}.`, the same note `Search failed` carries.

The first sentence is for a read that failed and left the caller a choice. A
guardrail refusal left none: `Fetch failed - {reason}.` ends at what was refused,
with or without a ladder configured. Every remote fallback runs the same SSRF
check and would refuse the same URL, so the retry the sentence would otherwise
name is the one move [fetch-safety.md](fetch-safety.md) rules out.

| Surface | Where the message appears | Status |
|---|---|---|
| REST | the `error` field of the body from `POST /api/v1/fetch` | `502` for the two failed-read sentences, `400` for the unknown name — `FetchRefused` already means *refused before a request was sent* |
| REST | the `notice` field of a normal `200` body | the near-empty sentence, joined to any existing notice exactly as `search` joins its zero-results notice |
| MCP | the tool error text | the same two sentences, the tool layer turning the exception into text as it does today |
| MCP | the `notice` field of `FetchResponse` | the near-empty sentence; over MCP that is model-facing text, not only a JSON key |
| CLI | `seekwright: <the server's prose>` on stderr, exit code `1` | the two error sentences, printed by `cli._send` — the client writes no wording of its own |
| CLI | `notice: <…>` on stdout | the near-empty sentence, in `cli._print_fetch` |
| `--check` | one row per configured name, with what it is missing | unchanged: it stays the only place that says *why* a configured name was not built |

No new response field carries the list. `search` puts the same information in
prose, and a caller that wants machine-readable availability reads the tool
description and the failure sentence, not a second encoding of the operator's
config.

## What would make this revisited

- An operator asks that `fetch` retry automatically for interactive callers too
  and only report which member served. Then `fetch.auto_fallback` defaults to `true`
  and the recovery sentences collapse into the `Fallbacks also failed: …` form.
- A caller turns out to need the availability list as data rather than prose — a
  client that offers the operator's own names in a picker. Then a response field
  carrying the names is justified, and this page's *no new response field*
  reading is superseded by an edit to this page.
- A second billable fetch provider arrives. The validator refuses one today, so
  admitting two reopens the tier rule as well, and this page's *at most one
  priced name* sentence moves with it.
