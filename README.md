# seekwright

Web search for your AI assistant.

`seekwright` sits in front of the search providers you choose — a paid API, a
free tier, your own SearXNG, or the keyless defaults — and gives a model three
web operations in one shape: `search`, `fetch` and `answer`. Add the server to
Claude Desktop, Cursor, Zed or any other MCP client and the model you are
talking to gets them; the same three are HTTP routes and CLI verbs, so a script
or a skill file reaches them too.

## Run it

In 0.1.0 the clone is the install path, and it needs Python 3.14 or newer.

```bash
git clone https://github.com/leoschwarz/seekwright.git
cd seekwright
uv sync
uv run seekwright --check
```

There is no PyPI package, and none is planned while the implementation language
is still open: the tool surface is the contract, this Python code is one
implementation of it, and it may be rewritten in another language once the shape
settles — a package name would promise an importable Python library that this is
not. A tagged release files the wheel on its GitHub Release and pushes the image
to `ghcr.io`.

There is nothing to sign up for first: with no config the server resolves to the
keyless providers, so a fresh clone already searches. `--check` prints the config
path it read, then reaches every enabled provider without billing anything. Keys,
when you have them, come from the environment, never from the config file.

```bash
uv run seekwright          # stdio MCP — your client launches this (the default)
uv run seekwright --http   # one process serves every client: MCP at /mcp
```

Under `--http` one process backs every client, and the same listener answers
`GET /healthz` for an orchestrator and serves a spend dashboard at
`GET /dashboard`. The `mcpServers` block that registers the server with your
client, and every config key, flag and environment variable, are in
[configuration](docs/reference/configuration.md).

## The three tools

- `search` — one query, and one result shape whatever provider sat behind it:
  title, URL, and the snippet or the extract. Domain filters, recency, 1 to 20
  results.
- `fetch` — one URL, the text of that page. Pass `query` for the passages that
  match instead of the whole document; a JSON page arrives as one line per value
  labelled with its path, and `path` takes one part of it.
- `answer` — a cited answer written over several searches and a few pages. Off by
  default: switching it on names a model and its endpoint in config, because your
  query and the retrieved text go there
  ([agent mode](docs/reference/agent-mode.md)).

Every call logs its provider, its cost and how long it took. The parameter table,
the status codes and the deliberate omissions are in
[the public API reference](docs/reference/public-api.md).

## Without an MCP client

The `search`, `fetch` and `answer` verbs drive those same routes from a shell —
how a Makefile, a cron job or a skill file reaches them. They read no config and
hold no key, so the config, the provider keys and the bill stay on the server:

```bash
uv run seekwright --http   # once
uv run seekwright search "first plasma in a tokamak" --json
uv run seekwright fetch https://en.wikipedia.org/wiki/Tokamak --query plasma
```

`--json` prints the response body verbatim, so it pipes into `jq`; exit codes are
`0` on success, `1` on a server error and `2` on a usage error; `--server URL`
names a deployment on another machine.
[The CLI client](docs/reference/public-api.md#the-cli-client) has every flag,
status code and remote-host flag.

## Deploying it

Nothing authenticates the listener, so the bind address is the access control:
`--host` defaults to `127.0.0.1`, every call it serves is billed, and a caller
from another machine needs the `Host` value it sends named with `--allowed-host`.
`/healthz` is outside that check and secret-free, so a kubelet probe needs
nothing. The image builds from the `Containerfile` at the root and takes a mounted
config file plus environment keys: [container.md](docs/reference/container.md) is
the runbook, [deploying.md](docs/reference/deploying.md) the two-role deployment
that gives `search` and `fetch` different egress rights.

## Choosing a provider

A `[providers.<name>]` block enables a provider; an environment variable carries
its key. Providers differ in result quality, in which filters they honour, and in
price. [The quickstart](docs/quickstart.md) walks the four tiers in the order a
new deployment meets them — keyless, free with a key, paid, and the allow-list
that caps which names a deployment may dispatch to at all — and
[providers.md](docs/reference/providers.md) has each one's endpoint, filters and
price. Cost is measured rather than quoted: `uv run seekwright --metrics` prints
latency and dollars per 1,000 calls from your own usage
([metrics.md](docs/reference/metrics.md)).

## Data privacy

A search leaves your machine, for the provider your deployment configured; with
no config that is Exa, Parallel and FreeSerp, reached anonymously. `fetch` goes
to the page you name. `answer` also sends the query and the retrieved text to
your own model endpoint, which is why it ships off.

Nothing else leaves: no telemetry, no analytics, no crash reporting, no update
check. Logs and the dashboard carry counts, cost and timing, never query text,
URLs or page content. `--check` prints one line per enabled provider, so the set
you will talk to is on the screen rather than only in these docs, and each
provider's own terms are worth reading before you pick one — that part is the
operator's job.

## Status: 0.1, incubating

The first release, maintained by one person and looking for early adopters. What
you can build on: the `search` and `fetch` surfaces are the contract and are
meant to stay stable, while the config keys, the provider set and the log fields
may change between 0.x releases without a deprecation cycle. That contract is
about the tool surface, not about this code: the Python here is an implementation
that may be replaced before 1.0, which is the other reason not to publish a
library. What confused you and what broke is the most useful thing you can send
back: [open an issue](https://github.com/leoschwarz/seekwright/issues). Security
reports have their own route, [SECURITY.md](SECURITY.md), and not a public issue;
how people here behave with each other is [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Docs

| I want | Read |
|---|---|
| the first run, tier by tier | [quickstart](docs/quickstart.md) |
| every config key, flag and environment variable | [configuration](docs/reference/configuration.md) |
| endpoints, filters and prices per provider | [providers](docs/reference/providers.md) |
| the tool and route contract, and what is deliberately not in it | [public API](docs/reference/public-api.md) |
| run it in a container | [container](docs/reference/container.md) |
| deploy it, safely | [deploying](docs/reference/deploying.md) |
| what `fetch` guards against, and what it does not | [fetch safety](docs/reference/fetch-safety.md) |
| how the code is shaped, and why | [architecture](docs/architecture.md) |
| why it exists: goals, precedence, non-goals | [vision](VISION.md) |
| everything else, with each page's kind | [docs/index.md](docs/index.md) |

`uv run pytest` runs the suite, and [CONTRIBUTING.md](CONTRIBUTING.md) carries the
rest of the commands, the conventions and the live smoke tests that hit real
providers. Licensed under [Apache-2.0](LICENSE).
