# Quickstart

seekwright puts one MCP surface in front of a set of search providers, and you can
have it answering before you have an account with anyone. This page walks the four
onboarding layers in order — keyless, free-with-a-key, paid, and the operator's
allow-list — so you can stop at the first one that fits. Every output shown is one
a run printed.

## 1. Keyless, no account — start here

Three names need no key, no account and no card: `exa:free`, `parallel:free` and
`freeserp`. The first two are the anonymous halves of paid endpoints, so each is
**rate-limited and weaker** than the keyed route to the same provider — the price
of a call that cannot cost anything. `freeserp` is a keyless whole-web SERP with
its own index. A config that enables nothing resolves to all three, which is why
the check below reads three names. `anysearch` is a fourth keyless name, a
whole-web SERP with a documented 1,000 requests/day anonymous quota, but it is
explicit-only: no default and no free walk reaches it. It is live-verified as of
2026-10-17.

The one public install path in 0.1.0 is the clone:

```bash
git clone https://github.com/leoschwarz/seekwright.git
cd seekwright
uv sync
```

`uv sync` brings the dev group, which self-includes the `trafilatura` extra — the
extraction backend `fetch` needs — so nothing else has to be asked for. No package
is published to PyPI yet: a tagged release files the wheel as a GitHub Release
asset and pushes the image to `ghcr.io`
([reference/publishing.md](reference/publishing.md)).

To run it in a container instead, build and check it from the same clone — with no
config mounted the image runs the keyless three, so the check costs nothing:

```bash
podman build -t seekwright:dev --build-arg SEEKWRIGHT_REVISION="$(git rev-parse HEAD)" .
podman run --rm seekwright:dev --check
```

The run command, the published-port decision and the two-container egress split
are [container.md](reference/container.md) and
[deploying.md](reference/deploying.md).

Then the check. It validates the config and handshakes each provider, and it
never bills:

```bash
uv run seekwright --check
```

With no config file at all, a healthy run prints:

```text
seekwright check
================
config      /home/you/.config/seekwright/config.toml  (defaults)
default     none (a bare search walks the free set)
permitted   (unset: every enabled provider)
providers
  implicit  nothing was enabled, so the keyless set (exa:free, parallel:free, freeserp) is the effective set
  exa:free  MCP handshake ok       unbilled
  freeserp  reachable (no key sent) unbilled
  parallel:free MCP handshake ok       unbilled
3 of 3 enabled providers ready
fetch
  enabled   40000 chars max, 3 redirects, private addresses blocked
  primary   http (the local reader)
  extractor trafilatura
agent
  disabled in config
```

The path on the `config` line is `$SEEKWRIGHT_CONFIG`, defaulting to
`~/.config/seekwright/config.toml`. Exit 0 means every enabled provider answered,
so the check gates a script. Those handshakes are live calls to a rate-limited
anonymous tier, so one throttled at that moment prints `MCP handshake failed` and
turns the code non-zero: re-run before concluding the install is broken. A
**fallback** is one named entry in the ladder a `search` or a `fetch` walks when
the step before it fails; the three ladders are `[search] fallback`,
`[search] free_fallback` and `[fetch] fallback`, set in
[configuration.md](reference/configuration.md).

The `implicit` line is the one to read: an empty config is not an error, it *is*
the keyless set, and the check says so rather than leaving you to guess why a bare
`search` reached a provider you never configured. A bare `search` walks the keyless
names in order, and the walk **fails rather than escalating to a paid provider**,
so a free search can come back with nothing. To use it, point your MCP client at
the server: [configuration.md](reference/configuration.md#registering-with-an-mcp-client)
has the `mcpServers` block for Claude Desktop, Cursor and Zed.

`--check --live` adds one real search per ready provider; on the keyless names that
is free, and rate-limited like the handshakes above.

A keyless install fetches too, through the server's own reader and nothing else:
`fetch.primary` is `http` and `fetch.fallback` ships unset, because a fetch target
is caller-named and handing it to a third party is the operator's opt-in. Five
fallbacks can sit behind that first read: `crawl4ai` (self-hosted renderer, free,
needs a `crawl4ai_url`), `jina` (the keyless hosted reader — free, no key, no URL,
a third party), and the billable `scrappa`, `tavily` and `linkup`, of which at most
one can be in a ladder and it must be last. A JS-rendered page needs one
configured. `jina` is the fallback with nothing to supply, and a declared
`permitted_providers` admits it the way it admits a provider: list `jina` beside
the provider names, since the key accepts that one fetch-only name through
`PERMITTED_FETCH_NAMES`. Leave it out and the keyless fallback is not built.

An operator who would rather a named fallback led every unnamed fetch sets
`fetch.primary` to it; the local read then leaves the unnamed route entirely,
which is how a page stops seeing this server's own IP.

## 2. Free with a key

Seven names are keyed and free to use: `tavily`, `scrappa` and `algolia` each
carry a monthly allowance, `search1api` carries 100 metered credits at signup,
`serpapi` carries 250 searches a month, `querit` carries 1,000 calls a month, and
`tinyfish` is free at any balance. The key always comes from the environment,
never from the TOML file — a secret in a file gets committed — and the variable is
always `SEEKWRIGHT_<BACKEND>_API_KEY`, the backend being the part of the name
before the first `:`. Four shipped names carry no live test that has run in-repo —
`search1api`, `serpapi`, `querit` and `deepseek` — and `--check` names whichever of
them you enabled on an `untested` line rather than letting a green run imply they
were exercised.

| Provider | Environment variable | Extra config |
|---|---|---|
| `tavily` | `SEEKWRIGHT_TAVILY_API_KEY` | — |
| `scrappa` | `SEEKWRIGHT_SCRAPPA_API_KEY` | — |
| `algolia` | `SEEKWRIGHT_ALGOLIA_API_KEY` | `app_id` and `index` required — it searches one index you own, not the web |
| `search1api` | `SEEKWRIGHT_SEARCH1API_API_KEY` | — |
| `serpapi` | `SEEKWRIGHT_SERPAPI_API_KEY` | — |
| `querit` | `SEEKWRIGHT_QUERIT_API_KEY` | — |
| `tinyfish` | `SEEKWRIGHT_TINYFISH_API_KEY` | — |

```bash
export SEEKWRIGHT_TAVILY_API_KEY=...
```

```toml
[providers.tavily]
enabled = true
```

The same block with any of the other six names is the whole of it, except
`algolia`, whose `app_id` and `index` are required as well. The allowances and the
per-1k prices are in [providers.md](reference/providers.md) §"Cost and free-tier
summary"; the config surface is [configuration.md](reference/configuration.md).

**The honesty rule this tier turns on.** A metered allowance is a price with a
delay on it, not a free route: `tavily`, `scrappa`, `algolia`, `search1api`,
`serpapi` and `querit` can bill once the allowance is spent, so none of them is in
the set that cannot bill, and `mode="free"` never reaches them. `tinyfish` is the
exception and is in that set: keyed, but free at any balance, so no quota can run
out. A key also turns on `exa` and `parallel`, the keyed halves of `exa:free` and
`parallel:free` — `exa` still tries the anonymous tier first and spends the key
only when that fails, while `parallel` bills per request — so both are really
tier 3.

Two behaviours to know before enabling a second name: with exactly one provider
enabled it becomes the default, and with several enabled and no `default_provider`
a bare `search` is an error listing them (the free-set case from tier 1 applies).
An enabled provider whose key is absent is a startup error, not a surprise bill:

```text
seekwright: missing API key(s) for enabled provider(s): tavily (SEEKWRIGHT_TAVILY_API_KEY)
```

`--check` reports the same fact without dying, and is still free — the same run
reads:

```text
  tavily    no API key (set SEEKWRIGHT_TAVILY_API_KEY)
  (none ready)
no providers ready -- searches would fail until configured
```

## 3. Paid

`serper`, `linkup`, `deepseek`, `scrappa` past its allowance, `search1api` past its
credits, `serpapi` past its searches, `querit` past its calls, keyed `exa` and
`parallel`, and the paid fallbacks behind `fetch` — the ladder walked when the
local fetch fails or comes back nearly empty, where a paid fallback costs a credit
per page. Nothing here is a surprise: enabling a name that can bill is naming a
price, a `search` that names a provider never reroutes to another one, and the
free-only routes stop existing the moment one enabled name can bill. Prices and
the fallbacks: [providers.md](reference/providers.md) §"Cost and free-tier
summary".

```toml
[providers.serper]
enabled = true

[fetch]
fallback = ["crawl4ai", "scrappa"]
```

```bash
uv run seekwright --check          # never billed
uv run seekwright --check --live   # one real search per ready provider
```

`--check --live` is the one check that costs money: it makes a real call against
each ready provider, which is the only way to prove a key works rather than merely
being present. The same run reports a paid fallback that is configured but inert:

```text
  fallback  crawl4ai -> scrappa
  crawl4ai  unreachable
  scrappa   (inactive: no API key)
```

## 4. The allow-list

`permitted_providers` is a permission set over provider names, so a deployment can
be told which third parties it may dispatch to at all. It is a top-level key,
validated at startup and enforced before dispatch wherever a provider can be
reached, and `--check` reports it — a `permitted` line always, and an `effective`
line naming what the intersection refuses. The config surface is the
[configuration reference](reference/configuration.md); the contract behind it is
[reference/allow-list.md](reference/allow-list.md).

## Where to go next

[index.md](index.md) is the map: every page, its kind, and who it is written for.
The two a first-time operator needs next are
[configuration.md](reference/configuration.md) for the keys and
[providers.md](reference/providers.md) for what each name does and costs.
