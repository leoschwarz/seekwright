# Egress (OCaml port)

What this process dials, and from which symbol each host comes. The rows are the
port's own: every endpoint here is a value in `lib/providers/`,
`lib/fetch/fallback*.ml` or `lib/factory/registry.ml`, and the same rows drive
what `--check --live` probes and what `seekwright-live --list` prints. If you
change an endpoint, change this page in the same commit — the Python tree keeps
a generated copy for its own deployment (`tools/egress_lists.py` writes the
Squid host lists under `deploy/compose/generated/`), and this page is the
OCaml-side equivalent of that inventory.

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
private, and every other RFC 6890 special-use address before a socket opens
(`Policy_net.special_use` is the table; `[fetch] allow_private_addresses` is the
only way to widen it, and it is off). Redirects are re-vetted, bounded by
`[fetch] max_redirects`.

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

## No proxy, and what to do about that

This port has **no outbound proxy support**: it does not read `HTTPS_PROXY`,
`HTTP_PROXY` or `NO_PROXY`, and `Policy_net` connects to the resolved address of
the endpoint in the registry row. (The Python deployment inherits httpx's proxy
handling, so this is a real difference — see
[`divergences.md`](divergences.md).) On a network that insists on a proxy, run
the proxy at the network layer (a transparent Squid, or an nftables redirect)
rather than expecting the process to know about it, and allow the hosts above.

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
