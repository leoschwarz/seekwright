# Egress (OCaml port)

What this process dials, and from which symbol each host comes. The rows are the
port's own: every endpoint here is a value in `lib/providers/`,
`lib/fetch/fallback*.ml` or `lib/factory/registry.ml`, and the same rows drive
what `--check --live` probes and what `seekwright-live --list` prints. If you
change an endpoint, change this page in the same commit. The generated lists
under `deploy/compose/generated/` are not maintained by hand:
`ocaml-tools/egress_lists.ml` renders `search-allow.txt` from the
`Registry.rows` endpoints and `fetch-allow.txt`/`fetch-deny.txt` from
`Config.known_fetch_fallbacks` plus the operator files in
`deploy/compose/egress/`. The `dune runtest` rules in `ocaml-tools/dune` diff
each committed file against a fresh render, so a provider or fallback row that
moves without the deployment fails the suite; refresh them with
`dune runtest ocaml-tools --auto-promote`. This page is the inventory an
operator reads; the generated files are the input to the host firewall or
nftables ruleset.

## Search providers

| Name | Host it dials | Where the host comes from |
| --- | --- | --- |
| `algolia` | `https://<app_id>-dsn.algolia.net/1/indexes/<index>/query` | derived from `[providers.algolia] app_id` and `index` by `Algolia.endpoint_of_deployment` |
| `anysearch` | `https://api.anysearch.com/v1/search` | `Anysearch.endpoint` |
| `deepseek` | `https://api.deepseek.com/v1/tools/search` | registry row |
| `exa` | `https://mcp.exa.ai/mcp` | `Exa.default_uri`, overridable by `[providers.exa] url` |
| `exa:free` | `https://mcp.exa.ai/mcp` | same, overridable by `[providers."exa:free"] url` |
| `freeserp` | `https://freeserp.ai/api.php` | `Freeserp.endpoint` |
| `linkup` | `https://api.linkup.so/v1/search` | `Linkup.endpoint` |
| `parallel` | `https://api.parallel.ai/v1/search` | `Parallel.endpoint` |
| `parallel:free` | `https://search.parallel.ai/mcp` | `Parallel.mcp_uri`, overridable by `[providers."parallel:free"] url` |
| `querit` | `https://api.querit.ai/v1/search` | registry row |
| `scrappa` | `https://scrappa.co/api/search-light` | `Scrappa.endpoint` |
| `search1api` | `https://api.search1api.com/search` | registry row |
| `searxng` | your own instance | required: `[providers.searxng] url` |
| `serpapi` | `https://serpapi.com/search` | registry row |
| `serper` | `https://google.serper.dev/search` | `Serper.endpoint` |
| `tavily` | `https://api.tavily.com/search` | `Tavily.endpoint` |
| `tinyfish` | `https://api.search.tinyfish.ai` | `Tinyfish.endpoint` |

Only the names in your `[providers]` table are ever dialed, and
`permitted_providers` narrows that further. A name you enable but do not permit
is built and never dispatched.

## Fetch

`fetch` reads **whatever URL a caller passes**, so the outbound set for the
primary route is the public web, not a fixed list. The guard is not a host
allowlist: `Policy_net` resolves the name and refuses link-local, loopback,
private, multicast, broadcast, and every other RFC 6890 special-use address
before a socket opens (`Policy_net.special_use` is the table; `[fetch]
allow_private_addresses` is the only way to widen it, and it is off). Redirects
are re-vetted, bounded by `[fetch] max_redirects`.

The fallback rungs do dial fixed hosts:

| Fallback (in `[fetch] fallback`) | Host | Needs |
| --- | --- | --- |
| `crawl4ai` | your own instance | `[fetch] crawl4ai_url`, optional `crawl4ai_token` |
| `jina` | `https://r.jina.ai/` | nothing (keyless) |
| `scrappa` | `https://scrappa.co/api/web-scraper` | `SEEKWRIGHT_SCRAPPA_API_KEY` |
| `tavily` | `https://api.tavily.com/extract` | `SEEKWRIGHT_TAVILY_API_KEY` |
| `linkup` | `https://api.linkup.so/v1/fetch` | `SEEKWRIGHT_LINKUP_API_KEY` |

`scrappa`, `tavily` and `linkup` bill, and at most one billable name may appear
in the ladder, last.

## Agent mode

One HTTPS call to `[agent] base_url` — an OpenAI-compatible chat endpoint you
configure, on any host. Nothing else in agent mode reaches the network: the
retrieval plan runs through the same provider and fetch paths above.

## Client verbs

`search`, `fetch` and `answer` run as client verbs dial the origin `--server`
names (default `http://127.0.0.1:8000`) — your own deployment, so that host is
yours and not the port's. The dial goes through one endpoint-scoped grant built
from that URL (`Policy_net.endpoint_of_uri`, then `Factory.grant_of_endpoint`),
the one place this build pins a destination by name instead of by address class:
loopback is dialable there and still refused for `fetch`. The dial carries no key
and reads no config, and an `https://` origin verifies against the same trust
anchors as the rows above.

## No proxy, and what to do about that

This process has **no outbound proxy support**: it reads no `HTTPS_PROXY`,
`HTTP_PROXY` or `NO_PROXY`, and it connects to the address its own lookup
vetted — `Policy_net` keeps every answer, refuses the ones the policy does not
allow, and hands the vetted address to the connection. The bundle in
`deploy/compose/` therefore ships direct egress: two services on ordinary bridge
networks, with nothing between them and the internet.

That moves two policies out of the bundle and onto the host firewall or nftables
ruleset: the sink deny list (callback services, upload sinks, tunnel listeners,
the `metadata.*` names) and the lenient-versus-strict `fetch` choice; there is
no `EGRESS_FETCH_POLICY` to set. Feed the ruleset
`deploy/compose/generated/fetch-deny.txt` for the denials, and either
`search-allow.txt`/`fetch-allow.txt` for a strict allow-list or the deny file
alone for the lenient shape.

On a network that insists on a proxy, run the proxy at the network layer (a
transparent Squid, or an nftables redirect) rather than expecting the process to
know about it, and allow the hosts above. The reference ACLs for one in front of
a role are still in `deploy/compose/squid/`: `search-allow.conf` for the search
role, `fetch-lenient.conf` and `fetch-strict.conf` for the fetch role, each
reading the generated lists. They are not part of the shipped bundle.

## Trust store

TLS is `tls-eio` with `x509`, and the trust anchors are whatever `ca-certs`
finds: the operating-system store, or `SSL_CERT_FILE` when you set it. The store
is read once, when the network grant is built, so a missing store is a startup
failure with a message that names both places — not a handshake error, and never
silently bypassed. There is no accept-any path and no per-call pin.

In the container image, `ca-certificates` is one of the two runtime packages for
exactly this reason. To add a private CA, mount it and point `SSL_CERT_FILE` at
it, or rebuild the image with your CA installed and `update-ca-certificates` run
in the build.
