---
name: seekwright-deploy
description: Install, start, verify or debug a seekwright deployment: the two-role container unit set, one container from Containerfile.ocaml, or a source checkout. Use when no seekwright listener answers, when the user asks to install, run, deploy, configure providers, add keys, publish a port, or register the server with an MCP client, or when a deployment misbehaves with 421 Invalid Host header, TCP_DENIED, a not-permitted provider or a provider that stops at startup.
---

# Deploying a seekwright

One binary and one config channel: a TOML file plus `SEEKWRIGHT_*` variables. It
serves the three tools and three REST routes the `seekwright` skill calls.

## Pick the shape

| Shape | What it is |
|---|---|
| the Compose unit set, `deploy/compose/` | the default: one image, two role containers — `search` searches and reads no page, `fetch` reads any caller-named page and holds no key — a listener each, on 8000 and 8001 |
| one container from `Containerfile.ocaml` | everything in one process, egress to the open internet, no egress list |
| a source checkout | development, stdio MCP, and the `--check --live` rehearsal |

Prose: `ocaml-docs/deploying.md` (both role configs), `ocaml-docs/container.md`
(the image), `ocaml-docs/configuration.md` (keys, flags, exit codes).

**Egress is a network-layer concern here.** The process dials the endpoint in its
registry row directly and reads no `HTTP_PROXY`, `HTTPS_PROXY` or `NO_PROXY`, so a
proxy it is merely told about does nothing. The lanes a role needs are
`deploy/compose/generated/search-allow.txt`, `fetch-allow.txt` and
`fetch-deny.txt`, rendered from the rows `ocaml-docs/egress.md` lists: give the
containers a route they allow, or nothing leaves.

## The unit set: three commands

```bash
cd deploy/compose
cp .env.example .env      # then set SEEKWRIGHT_PUBLISH to the address to publish on
docker compose pull       # ghcr.io/leoschwarz/seekwright:$SEEKWRIGHT_TAG
docker compose up -d
```

No `-f`, no `-p`: `compose.yaml` is discovered from its own directory and carries
the project name. `.env` and `search.env` are optional — with neither, the bundle
runs the keyless pair bound to `127.0.0.1` — and `up -d --build` builds the image
from this checkout through `Containerfile.ocaml`. **Never create a
`docker-compose.yml` at the repository root**: the bundle's own file is the unit
set, and a second copy is unguarded.

## The image

`Containerfile.ocaml` builds `seekwright` and ships nothing else: Alpine in both
stages, the committed `*.opam.locked` locks, `strip`, `gmp` and `ca-certificates`.
`SEEKWRIGHT_VERSION` is checked, not trusted: the build stage compares it with
`dune-project`'s `(version …)` and fails when they disagree, so pass what this
prints.

```bash
VERSION="$(dune build version.txt >/dev/null; cat _build/default/version.txt)"
docker build -f Containerfile.ocaml \
  --build-arg SEEKWRIGHT_VERSION="$VERSION" \
  --build-arg SEEKWRIGHT_REVISION="$(git rev-parse HEAD)" \
  -t seekwright-ocaml:dev .
```

BuildKit finds `Containerfile.ocaml.dockerignore` by itself; podman needs
`--ignorefile Containerfile.ocaml.dockerignore --format docker`. No config is
baked in — `SEEKWRIGHT_CONFIG` is `/etc/seekwright/config.toml`, a directory the
layer does not carry — so bind-mount one and pass keys as environment. `--http
--host 0.0.0.0` is what makes a published port reachable; the default bind is the
container's own loopback.

## Keys

Copy `search.env.example` to `search.env`. A key is
`SEEKWRIGHT_<BACKEND>_API_KEY`, named for the backend segment before the first
`:` — `SEEKWRIGHT_EXA_API_KEY` serves `exa` and `exa:free`. A key never goes in
TOML, and it buys nothing unless the name is both `enabled` in `search.toml` and
in `permitted_providers`. It reaches one container, `search`, through its
`env_file`; the fetch role is handed none, which is the half of its boundary its
config cannot state. An enabled provider with no key is startup-fatal; an empty
`search.env` is the normal keyless state.

## Publish a listener — ask first

A rule, not a value to pick: nothing authenticates either listener, so the
published address **is** the access control. `SEEKWRIGHT_PUBLISH` names **one
interface address, never `0.0.0.0`**, and the Host allowlist answers `421 Invalid
Host header` for every client that did not name itself. Serving a caller on
another machine changes who can spend the operator's money: state that, and wait
to be told the address. `--allowed-host` adds a name — exact `host:port` or a
`host:*` prefix — and the unit set passes the published one in already. `/healthz`
stays outside that check on purpose, and stays secret-free.

## Verify, in this order

```bash
docker compose ps                       # seven services: search, fetch, resolver, search-proxy, fetch-proxy, search-ingress, fetch-ingress
docker compose run --rm search --check  # the config it read, five provider sets, one probe per name that has one
```

The report reads `/etc/seekwright/config.toml`, mounted out of `search.toml`.
`--check` is a network operation, its probe a bodyless GET carrying no key;
`--check --live` adds one real search per ready permitted provider, the only path
here that bills. The two refusals, bodies verbatim:

```console
$ curl -s localhost:8000/api/v1/fetch -H 'content-type: application/json' \
    -d '{"url": "https://example.com/"}'
{"error":"This server has the fetch tool disabled; use `search` instead."}
$ curl -s localhost:8001/api/v1/search -H 'content-type: application/json' \
    -d '{"query": "example", "provider": "freeserp", "max_results": 2}'
{"error":"Provider 'freeserp' is not permitted on this server. Permitted: . Retry with one of those."}
```

Then both listeners, reporting the set each can dispatch:

```bash
curl -s localhost:8000/healthz   # {"status":"ok","providers":["exa:free","freeserp"],"default_provider":null,"uptime_s":4}
curl -s localhost:8001/healthz   # same shape, the keyless three, no default — `providers` is the built set, not the configured one
```

## What each failure means

- `421 Invalid Host header` — a name missing from `--allowed-host`, not a broken
  server. Add the name the caller sends; never disable the check.
- `TCP_DENIED/503` in a proxy log (`docker compose logs search-proxy | grep
  TCP_DENIED`) — the egress list refusing a host, and how a render that left a
  provider host out shows up. Re-render and restart `search-proxy`, or
  `fetch-proxy` after a fetch list moved; never hand-edit `generated/`. This
  process cannot produce that line unless the network forces its dials through
  the proxy.
- `{"error":"Provider '…' is not permitted on this server…"}` —
  `permitted_providers` in `search.toml`; `"…is not enabled…"` instead means the
  name is absent from `[providers.*]`, or this binary could not construct it for
  want of a key.
- A container that stops with `seekwright: missing API key(s) for enabled
  provider(s): serper (SEEKWRIGHT_SERPER_API_KEY)`, exit 1 — that provider is
  enabled and its variable is absent; the sentence names both.
- The fetch role answering `Provider '…' is not permitted` — correct and expected:
  it declares an empty permission set.
- `--check` exiting 1 naming an unbuildable `fetch.primary`, a probe that came back
  down, an enabled `[agent]` block missing its endpoint or model, or a cache root it
  could not create — the config asks for what this binary cannot honour. A keyless
  pair with no probe exits 0 and serves.

## The egress lists are rendered, not written

`ocaml-tools/dune` prints them from the code: `egress_lists.exe search-allow` is
the union of the destinations on `Registry.rows`, `fetch-allow` filters
`deploy/compose/egress/fetch-allow-hosts.txt` against
`Config.known_fetch_fallbacks`, `fetch-deny` unions
`deploy/compose/egress/deny-hosts.txt` with the metadata names the program
carries. Each output is committed under `deploy/compose/generated/` and diffed on
`dune runtest`, so a provider or fallback row that moves without the deployment
fails the suite instead of shipping a stale list. After an intended move:

```bash
dune runtest ocaml-tools --auto-promote   # or: dune runtest, then dune promote
docker compose restart search-proxy       # fetch-proxy after a fetch list moved
```

## The source checkout path

```bash
opam install . --deps-only --with-test -y
dune build @install                          # _build/install/default/bin/seekwright
dune runtest --force                         # suites, surface golden, egress-list diffs
dune build @doc                              # needs odoc — the opam line with --with-doc
_build/install/default/bin/seekwright --check    # names, probes, exit code
_build/install/default/bin/seekwright            # stdio MCP
_build/install/default/bin/seekwright --http     # the listener at /mcp on 127.0.0.1:8000
```

A fresh clone with no config file runs on the keyless three and says so, so there
is nothing to sign up for. Put `_build/install/default/bin` on `PATH` and the last
three lines are bare `seekwright`. `[fetch] extractor` accepts `stdlib` only here:
naming `trafilatura` is refused when the file is read, not at the first fetch.

## Register it with the client

Two roles are two servers, so a client gets two entries:

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
- Never widen `SEEKWRIGHT_PUBLISH` on the operator's behalf — name the risk, ask.
- Never edit the generated egress lists under `deploy/compose/generated/`.
- Never add a second Compose file.
