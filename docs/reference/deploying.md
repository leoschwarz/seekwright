# Deploying it safely

Nothing authenticates the listener, so the address you publish on is the whole
access control; egress is the other half, and it belongs to the network rather
than the app (§*What the unit set does not do*). The guard the app does keep is
[fetch-safety.md](fetch-safety.md). This page is the two-role deployment shipped
as files under `deploy/compose/`; serving both tools from one container is
[container.md](container.md).

## Two shapes, and which to start with

| Shape | What runs | Egress it needs | Where |
|---|---|---|---|
| one container | `search`, `fetch` and `answer` in one process | internet-wide: whatever host a caller names | [container.md](container.md) |
| the unit set | two containers from one image, one Squid proxy each, no route around either | each role bounded by its own list | this page |

The split is the default because `search` dials a set the operator chose and
`fetch` dials whatever the caller names: one container serving both holds egress
rights wide enough to read any page on the internet.

## Egress: two containers, one image

The two tools need opposite egress rights:

- `search` talks to a set of endpoints the operator chose. One per enabled
  name: `health.py`'s `_PROBES` rows are built from the adapter's own
  `ENDPOINT` constant, so `--check` reaches the host the search would reach, and
  the MCP-backed names reach their own handshake URL.
- `fetch` talks to whichever host the caller names — that is the tool: a URL in,
  page text out. The SSRF guard rejects private, loopback, link-local and
  reserved targets ([fetch-safety.md](fetch-safety.md)); nothing else narrows the
  set, because the set is the public internet.

So the default deployment is two containers built from the same image, each with
its own config, its own published port and its own egress rights. No surface
moves: `[fetch] enabled = false` and `permitted_providers` are keys this tree
already has, and each role refuses the other half's operation before an adapter
is reached. The commands in this section were run (2026-10-26) and their output
is verbatim, except where a note says otherwise.

### The search role: a named provider set, no page fetching

```toml
# search.toml — the role that can search and nothing else.
permitted_providers = ["exa:free", "freeserp"]

[providers."exa:free"]
enabled = true

[providers.freeserp]
enabled = true

[fetch]
enabled = false

[agent]
enabled = false
```

`permitted_providers` is a top-level key, so it belongs above the first table
header: written below `[providers.freeserp]` it parses as
`providers.freeserp.permitted_providers` and startup fails with
`Extra inputs are not permitted`. The two names are the keyless pair, so this
role runs with no API key; for a paid fallback, add the name to both lists and
its key to the environment.

The check reports the role:

```console
$ SEEKWRIGHT_CONFIG=/tmp/search.toml uv run seekwright --check
seekwright check
================
config      /tmp/search.toml  (present)
default     none (a bare search walks the free set)
permitted   exa:free, freeserp
providers
  exa:free  MCP handshake ok       unbilled
  freeserp  reachable (no key sent) unbilled
2 of 2 enabled providers ready
fetch
  disabled in config
agent
  disabled in config
```

In the container the same file is mounted at `/etc/seekwright/config.toml`,
where the image's own `SEEKWRIGHT_CONFIG` already points; the entry point is the
same CLI. (The `container` job of `.github/workflows/ci.yml` builds this image and
runs `--help` inside the result — see [container.md](container.md).)

`fetch / disabled in config` is the line that carries the boundary: no fetcher and
no ladder fallback is built, so the process holds no client that could reach a
caller-chosen host. On the serving path the tool is still listed — its schema is
frozen at import — and refuses:

```console
$ curl -s localhost:8000/api/v1/fetch -H 'content-type: application/json' \
    -d '{"url": "https://example.com/"}'
{"error":"This server has the fetch tool disabled; use `search` instead."}
```

`tests/test_server.py::TestFetchDisabled` holds both halves of that: the
refusal, and the stack that never gets built.

### The fetch role: internet-wide egress, no provider dispatch

```toml
# fetch.toml — the role that can fetch and nothing else.
permitted_providers = []

[fetch]
enabled = true
```

An empty permission set is a declared one, not an unset one, so every enabled
name is refused before an adapter is reached and nothing is billed:

```console
$ curl -s localhost:8001/api/v1/search -H 'content-type: application/json' \
    -d '{"query": "example", "provider": "freeserp", "max_results": 2}'
{"error":"Provider 'freeserp' is not permitted on this server. Permitted: . Retry with one of those."}
```

Two properties of this role, both measured at the same commit:

- **The keyless trio cannot be switched off.** A config that enables nothing and
  one that disables all three explicitly both resolve to `exa:free`,
  `parallel:free` and `freeserp` — the install default, the set an install
  reaches with no account, key or card. This container therefore always has three
  provider endpoints, even though it can never search.
- **`--check` probes enabled names, not permitted ones.** This role's check
  reaches those three hosts and prints `3 of 3 enabled providers ready` before
  the line `effective   0 of 3 enabled providers permitted; not permitted:
  exa:free, freeserp, parallel:free`. The refusal lives on the serving path,
  which is the path that spends money.

### What bounds the egress, and what does not

The proxy bounds **dispatch**; the network bounds **egress**. That split is a
decision rather than an absence: the app cannot see the network, so a list of
hosts it is willing to dial would be a promise it cannot keep. What each layer
holds:

| Layer | Search role | Fetch role |
|---|---|---|
| `permitted_providers` | the two names it enables | `[]`: every name refused pre-dispatch |
| `fetch.enabled` | `false`: no fetcher, the tool refuses | `true` |
| The SSRF guard | never reached | public addresses only |
| The network | the provider hosts, and nothing else | any public host |

For the search role the network half is a host allow-list, and it needs no
decryption: the name a client dials is visible in DNS and in the TLS `Server Name
Indication`. A *path* allow-list would need the request itself, which means
terminating the provider's TLS; nothing here asks for one.

The outbound path for the search role can be a forward proxy named in the
environment: the tree constructs its `httpx` clients without touching `trust_env`,
and the MCP-backed names honour it too. Measurable against a port nobody listens
on:

```console
$ SEEKWRIGHT_CONFIG=/tmp/search.toml HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 uv run seekwright --check
  exa:free  MCP handshake failed   unbilled
  freeserp  unreachable            unbilled
```

A firewall that allows the provider hosts and drops the rest is the other
shape, and it holds without any change inside the container. The two-network
form, in the podman spelling the operator of this deployment runs:

```bash
podman network create --internal seekwright-search
podman network create seekwright-egress
podman run -d --name seekwright-search \
  -p 192.0.2.10:8000:8000 --network seekwright-search \
  -v ~/deploy/seekwright/search.toml:/etc/seekwright/config.toml:ro,Z \
  seekwright:dev --http --host 0.0.0.0 --allowed-host 192.0.2.10:8000
podman run -d --name seekwright-fetch \
  -p 192.0.2.10:8001:8000 --network seekwright-egress \
  -v ~/deploy/seekwright/fetch.toml:/etc/seekwright/config.toml:ro,Z \
  seekwright:dev --http --host 0.0.0.0 --allowed-host 192.0.2.10:8001
```

**Those `podman` lines were not exercised on a machine with a runtime**
(2026-10-26). The checkout they were written in has none, the runners carry docker
rather than podman, and the `container` job of `.github/workflows/ci.yml` runs
`--help` without starting two containers on two networks. Every other command in
this section was run.

They leave one thing open — the search role's outbound path. `--internal` gives a
network with no route to the internet, so the provider handshakes need the proxy
or the firewall rule above; the unit set below takes the proxy half, for both
roles.

Two properties of the network shape, both load-bearing:

- **The resolver is not a convenience.** `internal: true` is what makes the
  proxies un-bypassable, and it also leaves a role container with no name answer.
  `fetch` resolves the target itself — `resolve_public` runs before the proxy is
  dialled — so the fetch network carries CoreDNS at a fixed address, named in that
  service's `dns:`. The search role resolves nothing at all: its proxy resolves.
- **The address half is enforced twice.** The app refuses non-public targets
  before connecting; the proxies refuse them at the socket with a `nonpublic`
  ACL. For proxied traffic that also closes the rebinding window
  [SECURITY.md](../../SECURITY.md) records as narrowed rather than closed: the
  name is resolved by the proxy, and the address it answers with is checked there.

## First run: four commands

```bash
cd deploy/compose
cp .env.example .env      # then set SEEKWRIGHT_PUBLISH to the address you publish on
docker compose build
docker compose up -d
```

No `-f` and no `-p`: Compose discovers `compose.yaml` from the project
directory it is run in, and `name: seekwright` in that file is the project name.

There is deliberately no second Compose file at the repository root: a root
`docker-compose.yml` would be an unguarded copy of the same services, since the
checks read the bundle's own `compose.yaml` and only that copy stays honest.

Both `.env` and `search.env` are optional. With neither present the bundle runs
the keyless pair — `exa:free` and `freeserp` — bound to `127.0.0.1`, which is
what an operator who copies nothing gets. A Compose older than v2.24 cannot
treat `search.env` as optional, so on one of those run
`cp search.env.example search.env` first.

**Those four commands were not exercised on a machine with a runtime**
(2026-10-26). What *is* checked is that the four artifacts agree:
`tests/repo/test_egress_lists.py` reads the compose file and the proxy configs,
and fails on

- a mount pointing at a file the tree does not hold,
- a rendered list no proxy reads,
- a role on the wrong network, or
- a search proxy that stops ending in `deny all` behind its list.

The bundle publishes nothing new: both roles keep `--allowed-host`, and
`SEEKWRIGHT_PUBLISH` defaults to `127.0.0.1`.

## What you set, and where

`deploy/compose/` is the one piece of this repository's `deploy/` that ships;
the rest stays private. What an operator edits, and the one file they do not
have to:

| Path | What it holds |
|---|---|
| `.env` | the two substitutions in `compose.yaml`: `SEEKWRIGHT_PUBLISH`, the address both listeners are published on, and `EGRESS_FETCH_POLICY`, the fetch policy. Copied from `.env.example` |
| `search.env` | the search role's keys, `SEEKWRIGHT_<BACKEND>_API_KEY`. Copied from `search.env.example`; an empty file is the normal state |
| `search.toml`, `fetch.toml` | the two role configs printed above, verbatim |
| `egress/deny-hosts.txt` | the operator's deny-list, comments and all: one host per line, a leading dot covering that domain and everything under it. The default fetch policy reads it |
| `egress/fetch-allow-hosts.txt` | the operator's strict allow-list, plus one `fallback=<name>` line answering for every fallback whose host no constant names |
| `compose.yaml` | five services: the two roles, one Squid proxy each, and a resolver for the network that cannot reach one |

`.env` and `search.env` are gitignored; the `.example` files beside them are the
tracked templates. Nothing in `.env` reaches a container by itself — the
substitutions are rendered into a service definition — and a key reaches exactly
one container: `search`, through its `env_file`. The fetch role is handed no
`env_file` and no key, which is the half of its boundary its config cannot state.

**A key never goes in TOML** ([configuration.md](configuration.md)), and it buys
nothing unless the same name is enabled *and* permitted in `search.toml`. An
enabled name with no key stops the container at startup; a key for a name that is
not permitted is never spent. The variable is named after the segment before the
first `:` — `SEEKWRIGHT_EXA_API_KEY` is shared by `exa:free` and `exa`.

The proxies read files rendered from the tree, not the operator's lists
directly, and a provider landing without its host joining the render is a red
check rather than an outage:

```bash
uv run python -m tools.egress_lists          # print what the deployment dials
uv run python -m tools.egress_lists --write  # re-render after a provider lands or an operator list moves
uv run python -m tools.egress_lists --check  # what CI runs: 1 drifted, 2 a source the census reads moved
```

Then restart the proxy that reads the list that moved — `docker compose restart
fetch-proxy` after an edit to `egress/deny-hosts.txt` or
`egress/fetch-allow-hosts.txt`, and `search-proxy` after a provider lands.

A strict fetch list that leaves out a fallback `fetcher.py` names by constant —
`r.jina.ai` or `scrappa.co` — is refused by the renderer: that list would break
the ladder, not narrow the tool. A fallback the operator configures by URL is
answered by hand instead, because rendering it would mean reading the deployment's
config, and the file holding `fetch.crawl4ai_url` can hold `fetch.crawl4ai_token`.
So `fallback=crawl4ai renderer.internal.example` names the host this deployment
dials, a bare `fallback=crawl4ai` says it runs no renderer (what this bundle
ships), and a fallback answered nowhere fails `--check` at 2. That is all the
check proves: answered for, not matching the configured URL.

## Verify

What the two defaults do, once started. The search proxy answers `TCP_DENIED/503`
for any host `generated/search-allow.txt` does not name. The fetch proxy answers
the same for any name in `generated/fetch-deny.txt` — the callback and
out-of-band services, the public upload sinks, the tunnel listeners, the cloud
metadata names. Everything else the caller names is reachable, which is what makes
`fetch` a fetch tool.

In this order:

```bash
docker compose ps                       # five services: search, fetch, resolver, search-proxy, fetch-proxy
docker compose run --rm search --check  # the `config` line reads /etc/seekwright/config.toml
```

The `--check` report is the block quoted under §*The search role* above. Then the
two refusals, which are the two halves of the boundary:

```console
$ curl -s localhost:8000/api/v1/fetch -H 'content-type: application/json' \
    -d '{"url": "https://example.com/"}'
{"error":"This server has the fetch tool disabled; use `search` instead."}
$ curl -s localhost:8001/api/v1/search -H 'content-type: application/json' \
    -d '{"query": "example", "provider": "freeserp", "max_results": 2}'
{"error":"Provider 'freeserp' is not permitted on this server. Permitted: . Retry with one of those."}
```

Then each listener is alive, and reports the names that role holds:

```bash
curl -s localhost:8000/healthz   # {"status":"ok","providers":["exa:free","freeserp"],"default_provider":null,"uptime_s":…}
curl -s localhost:8001/healthz   # the fetch role: the keyless trio, and no default
```

A render that left a provider host out shows up as a proxy refusal rather than a
mystery 500 (`/healthz` itself is outside the Host allowlist and leaks nothing past
the enabled names — [container.md](container.md) §*Logs and health*):

```bash
docker compose logs search-proxy | grep TCP_DENIED
```

The two refusals and the `--check` report above were run. The `docker compose`
commands were not — no machine this page was written on has a runtime
(2026-10-26). What is printed under them is quoted from a run of the same code or
is a field set the code prints, never a compose transcript.

## Turning on the strict fetch policy

The one paranoid-mode switch is a line in `.env`:

```bash
EGRESS_FETCH_POLICY=strict
docker compose up -d fetch-proxy
```

That mounts `squid/fetch-strict.conf` instead of the lenient config, and from
then on the proxy reads `egress/fetch-allow-hosts.txt` and refuses every host
that file does not name. Two ways to get this wrong:

- **An empty operator tail refuses every page.** The file's shipped tail is
  empty on purpose — nothing in it is a default — so switching strict on before
  naming the sites this deployment reads makes `fetch` refuse everything.
- **A strict list that leaves out a constant-named fallback breaks the ladder**,
  not narrows it (see §*What you set, and where*), and the configured-by-URL
  fallback must be answered by hand as `fallback=<name> [host]`.

## What the unit set does not do

A name list is a policy, not a defence: anything not named stays reachable, and a
caller that controls a name outside the list can carry bytes out through it.

Nothing authenticates either listener, so the published address is still the
whole access control — `SEEKWRIGHT_PUBLISH` in `.env`, one interface address,
never `0.0.0.0`.

`[dashboard] enabled` is on by default, so both listeners serve `/dashboard`
behind the Host allowlist; `[dashboard] enabled = false` in `fetch.toml` turns
it off on that role. That page carries spend and call counts and is as
unauthenticated as `/mcp` — see [container.md](container.md) §*The usage
dashboard*.

`[agent] enabled = true` is a third egress shape — the provider hosts, plus the
pages its plan reads, plus one model endpoint — so on a split deployment agent
mode belongs on the wide-egress container. On the search role its retrieval
runs with `fetch_engine = None`: a `report` is still served, from snippets,
with a notice saying no pages could be read.

## Registering both roles with one client

They are two servers, so a client gets two entries:

```json
{
  "mcpServers": {
    "seekwright-search": { "url": "http://192.0.2.10:8000/mcp" },
    "seekwright-fetch": { "url": "http://192.0.2.10:8001/mcp" }
  }
}
```

A client handed both still cannot make the search container read a page: that
refusal is the server's, not the client's manners.

What each `command:` flag in `compose.yaml` does — `--http`, `--host`,
`--allowed-host` — is [container.md](container.md) §*Run*.
