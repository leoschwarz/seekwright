---
name: seekwright-deploy
description: Install, start, verify or debug a seekwright deployment: the two-role container unit set or a uv checkout. Use when no seekwright listener answers, when the user asks to install, run, deploy, configure providers, add keys, publish a port, or register the server with an MCP client, or when a deployment misbehaves with 421 Invalid Host header, TCP_DENIED, a not-permitted provider or a provider that stops at startup.
---

# Deploying a seekwright

## Pick the shape

| Shape | What it is |
|---|---|
| the Compose unit set, `deploy/compose/` | two roles, one egress proxy each — the default, because `search` dials a set the operator chose and `fetch` dials whatever a caller names |
| one container from the `Containerfile` | everything in one process, internet-wide egress |
| a `uv` checkout | development, stdio MCP |

The prose lives in `docs/reference/deploying.md`,
`docs/reference/container.md` and `docs/quickstart.md`.

## The unit set: four commands

```bash
cd deploy/compose
cp .env.example .env      # then set SEEKWRIGHT_PUBLISH to the address to publish on
docker compose pull       # ghcr.io/leoschwarz/seekwright:$SEEKWRIGHT_TAG
docker compose up -d
```

No `-f` and no `-p`: `compose.yaml` is discovered from the directory it is run
in, and its `name: seekwright` line is the project name. Both `.env` and
`search.env` are optional — with neither, the bundle runs the keyless pair bound
to `127.0.0.1`. `docker compose up -d --build` is the path for an unreleased
tree.

**Never create a `docker-compose.yml` at the repository root**: the checks read
the bundle's own `compose.yaml`, and a second copy of those services is
unguarded.

## Keys

Copy `search.env.example` to `search.env`. A key is
`SEEKWRIGHT_<BACKEND>_API_KEY`, named after the segment before the first `:` —
`SEEKWRIGHT_EXA_API_KEY` serves both `exa` and `exa:free`. A key never goes in
TOML, and it buys nothing unless the same name is both `enabled` in
`search.toml` and listed in `permitted_providers`. A key reaches exactly one
container, `search`, through its `env_file`; the fetch role is handed no key at
all, which is the half of its boundary its config cannot state. An enabled
provider with no key stops the container at startup; an empty `search.env` is
the normal keyless state.

## Publish a listener — ask first

This is the load-bearing security step, and it is a rule, not a value to pick.
Nothing authenticates either listener, so the published address **is** the whole
access control. `SEEKWRIGHT_PUBLISH` names **one interface address, never
`0.0.0.0`**; the Host allowlist then answers `421 Invalid Host header` for every
client that did not name itself. Changing the published address, or serving a
caller on another machine, is a change to who can spend the operator's money:
state that, and wait for the operator to name the address. What adds the name is
`--allowed-host`, and a trailing `:*` matches any port. `/healthz` stays
outside that check on purpose — a probe whose `Host` is a pod IP has to reach it
— and must stay secret-free.

## Verify, in this order

```bash
docker compose ps                       # seven services: search, fetch, resolver, search-proxy, fetch-proxy, search-ingress, fetch-ingress
docker compose run --rm search --check  # unbilled handshakes, one per enabled provider
```

The report reads the container's config at `/etc/seekwright/config.toml`, which
`compose.yaml` mounts out of `search.toml`.

Then the two refusals, which are the two halves of the boundary, bodies verbatim:

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

## What each failure means

- `421 Invalid Host header` — a name missing from `--allowed-host`, not a broken
  server. Add the name the caller sends; never disable the check.
- `TCP_DENIED/503` in a proxy log, from
  `docker compose logs search-proxy | grep TCP_DENIED` — the egress list
  working. It is also how a render that left a provider host out shows up, and
  it is fixed from a checkout by `uv run python -m tools.egress_lists --write`
  followed by `docker compose restart search-proxy`, or `fetch-proxy` after an
  operator list moved — never by editing `deploy/compose/generated/` by hand.
- `{"error":"…not permitted…"}` — `permitted_providers` in `search.toml`.
- A container that stops at startup naming a provider — that provider's key is
  absent.
- The fetch role answering `Provider '…' is not permitted` — correct and
  expected, not a fault: that role declares an empty permission set.

## The uv checkout path

```bash
uv sync                    # the dev group brings the trafilatura extraction backend
uv run seekwright --check  # config path, plus one unbilled handshake per enabled provider
uv run seekwright          # stdio MCP
uv run seekwright --http   # the listener at /mcp on 127.0.0.1:8000
```

A fresh clone with no config searches and fetches on the keyless names, so there
is nothing to sign up for. A `--no-dev` consumer must pass `--extra trafilatura`
or write `fetch.extractor = "stdlib"`: an enabled `fetch` whose backend library
is missing is startup-fatal, by design.

## Register it with the client

The two roles are two servers, so a client gets two entries:

```json
{
  "mcpServers": {
    "seekwright-search": { "url": "http://192.0.2.10:8000/mcp" },
    "seekwright-fetch": { "url": "http://192.0.2.10:8001/mcp" }
  }
}
```

A client handed both still cannot make the search container read a page: that
refusal is the server's, not the client's manners. An agent with no MCP
registration path uses the `seekwright` skill against these same routes.

## Never

- Never put a key in TOML, in `fetch.toml`, or in the fetch container.
- Never set `fetch.allow_private_addresses` to make a refusal go away.
- Never widen `SEEKWRIGHT_PUBLISH` on the operator's behalf — name the risk and
  ask.
- Never edit the generated egress lists under `deploy/compose/generated/`.
- Never add a second Compose file.
