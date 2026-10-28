# The allow-list

The contract for the permission set over provider names. It is onboarding's fourth
tier in [quickstart.md](../quickstart.md).

## What it is

One operator-declared permission set over provider names, covering **every
dispatch this deployment can make to a third party**:

- the `search` path — a named provider, the default route, the `mode="free"` walk
  — and agent mode's retrieval;
- `fetch`'s third-party ladder fallbacks: `scrappa` (a provider name already), the
  keyed `tavily` and `linkup` that ride those providers' keys, and the keyless
  `jina` — the one member of that coverage which is *not* a provider name.

`jina` is admissible through `PERMITTED_FETCH_NAMES`, the fetch-only set beside
`KNOWN_PROVIDERS` in `config.py`; admitting it there does not make it a provider.
A `[providers.jina]` table is still a startup error, and `jina` never enters
`effective_providers()`.

Three rules, and they are the whole feature:

| Rule | What it means |
|---|---|
| **Unset is permissive** | No key means every enabled provider is permitted, so no existing config changes behaviour. |
| **Declared is deny-by-default** | With the key set, a name outside it is refused. A name *inside* it is not thereby enabled — the effective set is `enabled ∩ permitted`. |
| **The refusal is before dispatch** | A refused call never reaches an adapter, so nothing is billed. It is never a substitution and never a silent reroute to a permitted neighbour. |

The allow-list **bounds; it never picks**. It is not a routing order: it does not
interact with `[search] fallback`, `free_fallback` or `default_provider` beyond
removing names from what they can reach. It is **not auth** and not a spend
ceiling: it is the operator's own policy, identical for every caller, and it
bounds who may be called, never how much.

## The key

**Top-level `permitted_providers`, type `list[str] | None`, unset by default.**

```toml
# The providers this deployment may dispatch to. Unset means every enabled
# provider is permitted. Once set it is a permission set: a name outside it is
# refused before dispatch, whatever its `enabled` flag says, and a name inside it
# is not thereby enabled. Not the Host allowlist (`--allowed-host`).
permitted_providers = ["exa:free", "parallel:free", "tavily"]

[providers."exa:free"]
enabled = true

[providers.tavily]
enabled = false   # permitted and not enabled: a normal state, not a typo
```

**Why top-level, and not a `[policy]` table.** `[policy]`'s three keys
(`max_snippet_chars`, `max_result_text_chars`, `provider_timeout_seconds`) bound
one provider call's size and duration. This key bounds *which names exist*, is read
once at startup, and sits on the same axis as `default_provider`. It is also
cross-cutting — it covers `search` and `fetch` — so it cannot live under
`[search]` or `[fetch]` without being wrong for the other. Rejected:
**`[policy] permitted_providers`** — it would make one field of that section a
name set and the other three call limits.

**Why that name.** The feature is called *the allow-list* — the maintainer's word,
this page's title — but the key is
`permitted_providers`. The tree already spells `allow*` for two other checks, and
a third `allow*` key would be read as one of them. The name also makes the key
findable from the error: the refusal says *not permitted*, so the word an
operator greps for is the word in the config. Rejected: **`allowed_providers`** and
**`provider_allowlist`** — both put the `allow*` spelling a reader has met for the
Host check on a key about something else entirely.

### What it is not: the two other "allow" surfaces

Three different axes, and none of them is this key. Say it once here so they are
never confused:

| Surface | What it decides | Where |
|---|---|---|
| `permitted_providers` (**this key**) | Which **providers** this deployment may dispatch to | top-level TOML |
| `--allowed-host` | Which **`Host` header values** this HTTP service answers to — FastMCP's DNS-rebinding allowlist, which starts at loopback only and answers `421` without the flag | CLI flag, [configuration.md](configuration.md) §"Command-line flags" |
| `[fetch] allow_private_addresses` | Which **addresses** the fetcher may reach — the escape hatch that lets `fetch` read an intranet page | `[fetch]` in the config file |

`--allowed-host` is about names *this service answers to*, protecting the HTTP
transport from browser-based rebinding; `[fetch] allow_private_addresses` is about
addresses *this service may reach*, widening what the SSRF guardrails let through.
Neither says anything about which provider may be dispatched.

### No wildcard member

There is no `"*"` member. A list **containing** `"*"` reads as **unset** — the
permissive, not narrowed, default — and nothing else in that list is validated:
there is no partial wildcard, and no member of a wildcard list is stored.
`--check` prints the same `(unset: every enabled provider)` string the absent key
prints, so one state has one rendering. The way to write "everything" is to write
nothing.

## Validation

Same shape as `search.free_fallback`'s validator
(`src/seekwright/config.py`, `_validate_free_fallback`): a new
`@model_validator(mode="after")` on `Config` beside `_validate_providers`,
with the same two errors.

| Input | Result |
|---|---|
| key absent | `None` — permissive. Not an error. |
| a list containing `"*"` | reads as unset (above); nothing else in the list is validated |
| every name a member of `KNOWN_PROVIDERS`, or of the fetch-only `PERMITTED_FETCH_NAMES` (`jina`) | loads, whatever their `enabled` flags say — `jina` has no `enabled` flag, and being admitted enables nothing |
| an unknown name, e.g. `"kagi"` | **startup error** naming the name, then `_renamed_hint`'s replacement hint when the name is a retired one, then the supported set |
| a name twice, e.g. `["serper", "serper"]` | **startup error**: a permission set with a duplicate is a list the operator mis-wrote |
| a known name that is not enabled, e.g. `"tavily"` with no `[providers.tavily]` | **loads.** Not an error. |

The unknown-name message is `search.free_fallback`'s with this key's name
substituted; its supported list is the union of the two sets this key accepts —
provider names and fetch-only names — so `jina` sorts into it among the providers.
The duplicate message is modelled on that validator's too, with a rewritten tail.
`search.free_fallback` counts attempts in a walk (`each fallback gets one attempt
per free search`), which says nothing about a permission set, so the tail here is
`each name gets one entry`:

```text
permitted_providers names unknown provider(s) kagi; supported: algolia,
anysearch, deepseek, exa, exa:free, freeserp, jina, linkup, parallel,
parallel:free, querit, scrappa, search1api, searxng, serpapi, serper, tavily,
tinyfish

permitted_providers names a provider more than once; each name gets one entry
```

`_renamed_hint` is reused unchanged, so a retired spelling
(`exa_free`) gets `; it is now "exa:free"` in the message rather than a bare
"unknown".

**A known-but-not-enabled name is deliberately not an error.** The effective set
is the intersection, and an allowed name whose key is not set is a normal state:
the operator writes the permission set once and turns providers on and off under
it. `resolve` reports such a name as *not enabled*, the honest reason. Rejected:
**a startup error for a name the allow-list permits but nothing enables** — it
would make the key mandatory to keep in sync with `[providers]`. Rejected: **a
startup error for a name that is enabled but not permitted** — see *Removal, not
a startup error* below.

## The effective set, and every enforcement point

The effective set is `enabled ∩ permitted`. Everything below is a site in `src/`
the implementation changes, named by the symbol that carries it — never by a line
number, which would go stale the next time one of these files is edited.

| # | Site | What changes |
|---|---|---|
| 1 | `config.py`, `Config`, beside `enabled_providers` | The field `permitted_providers: list[str] | None = None`, the validator, and **two** helpers: `effective_providers()` (`enabled ∩ permitted`, or the enabled set when unset) and `is_permitted(name)` (`True` when unset). One home at the config boundary for "unset is permissive" — every site below reads it, directly or through the routing table's own `SearchTable.is_permitted`, which the engines fill from this field. |
| 2 | `router.py`, `resolve_search`, behind `SearchEngine.resolve` | After the existing enabled check and before the name is returned: refuse a `requested` name that is not permitted, and refuse a `default_provider` that is not permitted. The choke point for a caller-named provider **and** for the default route, which is why it is first. The wrapper only translates the router's `RouteRefused` into the `SearchRefused` the REST projection reports as 400. |
| 3 | `router.py`, `free_walk` — its candidates come from `free_candidates` | The comprehension's condition gains `and table.is_permitted(fallback)`, beside the redundant `fallback in table.free` check it already carries. A walk whose first fallback is unpermitted never exists, so `mode="free"` cannot dispatch one. |
| 4 | `router.py`, `_default_not_permitted`, and the second refusal of `_resolve_free` | The empty-walk refusal gains a second branch. The existing sentence is for "no free provider is enabled"; a walk emptied *by the allow-list* gets its own wording (below), so the two reasons never read alike. |
| 5 | `router.py`, `fallback_rungs`; the log line stays in `engine.py`, `_walk_fallbacks` | A fallback that is enabled but not permitted answers `RungStatus.UNPERMITTED` instead of `CANDIDATE`, and the engine skips it with a `search.fallback_unpermitted` line carrying `fallback` and `permitted`. Modelled on the open-circuit skip in the same loop, levelled `.warning` rather than `.info` because it is dead config the operator should fix, not a transient fact. |
| 6 | `engine.py`, `_resolve_or_reject` | The `search.rejected` bind gains `permitted=`, so the operator's log line distinguishes a name this deployment does not serve from one it will not dispatch. `enabled=` stays. |
| 7 | `factory.py`, `build_fetch_stack`, its ladder loop — the third-party rows of `fetcher.KNOWN_FALLBACKS` in `fetcher.py`, whose builders are `_build_scrappa`, `_build_jina`, `_build_tavily` and `_build_linkup` | Do not build the `ScrappaFetcher`, `JinaFetcher`, `TavilyFetcher` or `LinkupFetcher` when its name is not permitted: each builder answers `None`, which is how a fallback without its key is already left unbuilt, so **the fallback is not built** and nothing can fire. `jina` is admissible through `PERMITTED_FETCH_NAMES` — the fetch-only set the validator subtracts beside `KNOWN_PROVIDERS` and unions into its supported list — precisely because it is a fetch fallback, not a provider. `KNOWN_PROVIDERS` itself does not change, so `jina` gets no `[providers.jina]` table and no place in `effective_providers()`. The self-hosted `crawl4ai` fallback needs no entry, which is why `--check` asks only the third-party rows (site 9). |
| 8 | `cli.py`, `check`, its header block and the ready tally | The `permitted` line, always printed; and the `effective` line, printed only when the intersection is a proper subset of the enabled set. See `--check` below. |
| 9 | `cli.py`, `_report_fetch`, its ladder loop and the state `_fallback_state` prints | A third-party fallback reports `(inactive: not permitted)` when it is outside the permission set — the existing `(inactive: …)` shape. For `scrappa`, `tavily` and `linkup` that is the enabled, keyed fallback the set excludes, one state short of `(inactive: no API key)`; `jina` has no key, so for it the permission set is the only thing that can make the fallback inert, which leaves `(inactive: not permitted)` a real state for a declared set that omits it, and `keyless` the state a set that lists it reaches. The report asks the row, not the name, and asks the set only of a row that dials an `endpoint` constant: a self-hosted fallback has no entry to be missing (site 7), so its line reports its host instead. |
| 10 | `server.py`, `build_app_context`, the `startup` bind | `permitted=`, a comma-joined list or `None` when unset, beside `providers=`, `default_provider=` and `search_fallbacks=`. `None` is the field's own value, which is what a structured bind carries; the operator-facing `(unset: every enabled provider)` marker is `--check`'s rendering of the same state, not a second convention. A refusal is the wrong moment to learn that a policy is active; the same argument the keyless-pair rule makes for logging the implicit keyless set. |

**The declared set is read as the field, and there is no `permitted_providers()`
method.** Every site reads `config.permitted_providers` directly. The field is
declared on the same class and pydantic's field wins, so a method of that name
would raise `TypeError: 'list' object is not callable`. `enabled_providers()` is a
method precisely because no `enabled_providers` field exists. Rejected: **an
accessor named `permitted()` or `declared_providers()`** — two names for one
value, and the second is neither the config file's word nor the refusal's.

**Two sites deliberately do not change**, and they are the ones most likely to be
"fixed" by mistake:

| Site | Why it is untouched |
|---|---|
| `agent.py`, `AgentEngine._retrieve` — agent mode's retrieval | Agent mode's retrieval **is** the search path: `AgentEngine` calls `self.engine.search(...)`, the same call a `search` tool call makes. It inherits every rule above and gets **no second key**. A pinned `provider` is refused by site 2; the pages a `report` reads go through `FetchEngine`, so they inherit site 7. The only change agent mode needs is a test (below). |
| `server.py`, the `search` and `answer` tools' `provider` `Literal`s | A config value cannot reach a schema. See *The schema* below. |

### Removal, not a startup error

Sites 5 and 7 remove names from what they can reach: an unpermitted ladder
fallback does not fire, and an unpermitted fetch fallback is not built. Neither
is a startup error, and neither is silent — site 5 logs, site 9 reports in
`--check`.

That is deliberately unlike `search.fallback`'s rule that a *not enabled* fallback
is a startup error. "A fallback that cannot run makes the ladder theatre" is about
the ladder being a promise to the caller; a fallback the operator's own permission
set excludes is the permission set working. A fatal here would also let a policy key
make a config unloadable over a disagreement between two other keys.

## The refusal

`SearchRefused` in `engine.py`, the existing precedent for a search-path refusal.
It is a `SearchFailed` subclass, so the MCP tool catches it unchanged and the REST
projection reports it as `400`, exactly as it reports a name this deployment does
not serve (`public-api.md` §Status codes). It is raised **before** `_call`.

Three literals, and they are the wording shape the implementation must use:

**A named provider that is not permitted** (`resolve`, site 2):

```text
Provider 'serper' is not permitted on this server. Permitted: exa:free,
parallel:free. Retry with one of those, or omit `provider` to use the default.
```

The recovery clause is `resolve`'s existing one, offered **only when a default
exists and is itself permitted**; with no default, or a refused one, the sentence
ends at `Retry with one of those.`

**A default provider that is not permitted** (site 2):

```text
The default provider 'serper' is not permitted on this server. Permitted:
exa:free, parallel:free. Pass `provider` with one of those.
```

**A `mode="free"` walk emptied by the allow-list** (site 4):

```text
No permitted free provider is enabled on this server, so a mode="free" search
has nothing to try. Permitted: exa:free. The free providers are: exa:free,
freeserp, parallel:free, searxng, tinyfish.
```

`Permitted:` carries the same meaning in all three: the declared set, read as the
field `config.permitted_providers` (`None` when unset, and no refusal is possible
then). The third keeps the existing second sentence naming the free set, so a
caller learns both what the operator permits and what could be free.

### What the refusal never does

- **It never substitutes.** The refused name is not replaced by a permitted one,
  and `_walk_fallbacks` is not entered: the refusal is raised inside `resolve`,
  which runs before `SearchEngine.search` walks the ladder. An unpermitted
  `default_provider` is therefore not silently served by its configured fallback.
- **It never reroutes to a permitted neighbour.** The list in the message is
  advice for the *caller*. The server performs no substitution of its own.
- **It never reaches an adapter.** Sites 2, 3 and 4 run before the first `_call`;
  site 5 skips an unpermitted fallback *before* the `_call(fallback, q)` inside
  `_walk_fallbacks`' loop is reached for it; and site 7 removes the fallback from
  the stack at build time.

## `--check`

`cli.check`. Two lines are added; every existing line keeps its
text and its order.

```
seekwright check
================
config      /home/me/.config/seekwright/config.toml  (present)
default     serper
permitted   serper, exa:free
providers
  serper    reachable              $1.00/1k
  linkup    reachable              $6.00/1k
  exa:free  reachable (no key sent) unbilled
2 of 3 enabled providers ready
effective   2 of 3 enabled providers permitted; not permitted: linkup
fetch
  ...
```

Every line above is the shape `check` already prints: `config` and `default` in
its header block, `providers` and the tally in its provider section, `fetch` in
`_report_fetch`'s. The two price cells are `_probe_all`'s
`f"${provider.cost_per_1k:.2f}/1k"` read off `factory._PROVIDERS`.

- **`permitted`** sits beside `default` in the header block (site 8) and is
  printed **always**: the declared list, comma-joined in the operator's order, or
  — when the key is absent or the list holds `"*"` — **exactly**
  `permitted   (unset: every enabled provider)`. One string, one state; a test
  asserts that value, not a family of them. It follows the block's existing "no
  value, and here is what that means" shape (`default     none (callers must pass
  provider)`), because a permissive default an operator cannot see is the
  surprise this line exists to remove.
- **`effective`** is printed after the ready tally (site 8) and **only when the
  intersection is a proper subset of the enabled set**, naming the
  enabled-but-not-permitted names: providers the operator turned on that can never
  be dispatched. With the key unset the two sets are equal and the line is absent.
- **The fetch fallbacks** are reported by site 9 in the existing shape — one row
  per configured fallback, printed from its `fetcher.KNOWN_FALLBACKS` row, not
  from per-vendor code. A third-party row outside the set prints
  `  scrappa   (inactive: not permitted)`, likewise `tavily` and `linkup`; a
  permitted `jina` prints `keyless` and a permitted keyed fallback with its key
  prints `keyed`. The self-hosted `crawl4ai` row is asked no permission question —
  it has no entry to be outside, and `permitted_providers` cannot name it — so it
  reports its host: `  crawl4ai  reachable`, `unreachable`, an HTTP status, or
  `(inactive: no fetch.crawl4ai_url)`.
- **Secret-free.** Both new lines print provider *names* and nothing else: no API
  key value, no `SEEKWRIGHT_*_API_KEY` value (the existing "no API key (set VAR)"
  line prints a variable *name*), no path beyond the existing `config` line.
  `--check`'s one promise — it never bills — is untouched: neither line reaches
  the network.

## The schema

**The `provider` parameter's `Literal` still lists all seventeen names**, in both
tools — `search` and `answer` in `server.py` — and so does `mode`'s
`Literal["free"]`. The allow-list does not narrow a schema.

The reason is mechanical: FastMCP builds the tool schema once at import time and
the annotations are `eval`'d against module globals, so anything derived from
config raises `NameError`. The *enabled* set already cannot narrow a `Literal`,
and the permitted set is the same rule from the same side. So the refusal is the
surface: a model may name an unpermitted provider and learns the real set from the
refusal sentence, which is the only place it can be reported. The `provider`
descriptions are unchanged because that sentence carries the recovery.

Rejected: **shrinking the `Literal` to the permitted set** — impossible for the
same reason, since a schema cannot be built from config.

## What the tests pin

Each claim below is asserted by a test that exists, named so a reviewer can read
the assertion instead of the claim. The **sentence a model reads back over the
wire** is a Gherkin scenario in `tests/features/provider_selection.feature`,
because the tool contract is specified there.

- **A name enabled but not permitted is refused before the adapter is called** —
  `tests/test_engine.py::TestTheAllowList`: with a spy adapter that counts calls,
  a `search(provider="serper")` under a set that excludes `serper` raises
  `SearchRefused`, the spy's count is `0`, and no `search` journal line is
  written.
- **Unset is permissive** — the same class: the same call with no key dispatches,
  and the spy is called once.
- **The intersection holds both ways** — the same class, and
  `tests/test_config.py::TestPermittedProviders`: a permitted-but-not-enabled
  name is refused with the *existing* "not enabled" wording and never the "not
  permitted" one; an enabled-but-not-permitted name gets the reverse. The two
  sentences are asserted apart, not merely asserted.
- **A walk never reaches a disallowed name** — `tests/test_engine.py` for
  `search.fallback` and the `mode="free"` walk (including the refusal that says
  *permitted*, not *enabled*, when the free walk empties on the list), and
  `tests/fetch/test_fetch_fallback.py` for the ladder: an unpermitted `scrappa`
  is never built, so a fetch that fails locally never posts to its endpoint,
  while a permitted one still is.
- **The schema still lists seventeen** — `tests/test_server.py`: the `search` and
  the `answer` tool schemas each carry `provider` with exactly
  `KNOWN_PROVIDERS`.
- **`--check` prints both sets** — `tests/test_cli.py`:
  - the `permitted` line carrying exactly the declared list;
  - the `effective` line only when the intersection is smaller;
  - an unpermitted fallback reported as `(inactive: not permitted)`;
  - the exact `permitted   (unset: every enabled provider)` line for an absent
    key or a `"*"` list;
  - no API key value anywhere in the output.
- **The refusal sentence is recoverable in one call** —
  `tests/features/provider_selection.feature`: a model that names an unpermitted
  provider reads a sentence naming the refused name and the permitted set, and
  can retry from it without a second failure.
- **Agent mode inherits it** — `tests/test_agent.py`: an `answer` call whose
  `provider` pin is unpermitted fails the retrieval step with the refusal prose
  and **makes no model call**, which is the assertion that agent mode needs no
  second key.
- **The key itself** — `tests/test_config.py::TestPermittedProviders`:
  - unset is `None`; a valid list loads; a known-but-not-enabled name loads;
  - an unknown name is a startup error through `load_config`, naming the name and
    the supported set; a retired spelling gets its replacement named;
  - a duplicate is a startup error;
  - a fetch-only name (`jina`) loads too, the one admission this key makes
    outside `KNOWN_PROVIDERS`;
  - a list containing `"*"` reads as unset and is permissive;
  - a *host* value (`"localhost"`) is an unknown-provider error — the assertion
    that this key is not the Host allowlist.
