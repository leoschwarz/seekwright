# Security policy

seekwright reads provider API keys from the environment, proxies calls that spend
real money, and returns page text written by whoever controls the page. This
document says which of those risks are handled, which are deliberately not, and
where to send a report.

## Reporting a vulnerability

Report privately to **mail@leoschwarz.com** — the maintainer address published in
`pyproject.toml`. Do not open a public issue for anything in the in-scope list
below: an issue publishes the details before there is a fix.

There is no dedicated security address, no PGP key in the tree, and no bug
bounty. If you need an encrypted channel, say so in a first plaintext message.
This is a single-maintainer project with no security team and no on-call rota, so
there is no response-time commitment. A report that is accepted gets a fix on a
branch; how you are credited, and whether the fix is announced, is your call —
say which you want in the report.

Useful in a report: what you did, what you expected, what happened, the commit or
version you were on, and — for anything about the fetcher — the exact URL you
asked it to fetch.

## In scope

**A provider API key reaching somewhere it should not.** The properties the code
is built to hold:

- Keys come from the environment only, as `SEEKWRIGHT_<NAME>_API_KEY`, and are
  never read from the TOML config, because a file gets committed. The one
  credential that does live in the config is `fetch.crawl4ai_token`, which
  authenticates this server to an internal renderer the same file already names —
  see [configuration.md](docs/reference/configuration.md).
- A key only ever travels to its own provider's endpoint. The fetcher owns its
  own HTTP client precisely so that no provider `Authorization` header can ride
  along on a request to an arbitrary third-party site (`fetcher.py`), and every
  fallback owns its client for the same reason.
- A key never reaches a log line or an error message. Provider failures are
  mapped to fixed strings — an httpx exception or a raw response body is never
  interpolated into a message, because both can echo the request whose headers
  hold the key ([provider-contract.md](docs/reference/provider-contract.md)) —
  and the logging setup turns off loguru's `diagnose` and `backtrace` defaults,
  which render the *values of local variables* into a traceback.
  `tests/test_logs.py` walks the AST so the rule holds at every call site rather
  than only at the ones that were reviewed.
- `/healthz` reports provider *names* and uptime and nothing else — not which
  keys are present, not the config path, not the bind address — and it is
  reachable without authentication by design.

**A way around the fetch guardrails.** `fetch` takes a URL chosen by a
suggestible caller and returns text chosen by a hostile page, so both halves are
guarded: `http(s)` only; URLs with embedded credentials refused rather than
stripped; no private, loopback, link-local, multicast or reserved address, with
*every* resolved address required to be public (including IPv4-mapped forms and
the cloud metadata endpoint); redirects followed manually, capped and
re-validated at every hop, with an https→http downgrade refused; the download
streamed against a byte cap enforced on accumulated bytes rather than on the
`Content-Length` a hostile server supplied; and one wall-clock budget for the
whole chain. The full list, and what it deliberately does not cover, is
[fetch-safety.md](docs/reference/fetch-safety.md). A bypass of any of it is a
vulnerability.

**Content or identifiers landing where the documentation says they do not.**
Query text and fetched URLs are recorded only when `[logging] log_queries` is on;
provider content only when `log_content` is on; both are off by default. The
usage journal and the dashboard carry counts, money, timing and provider names —
never query text, URLs, titles or extracted text. The docs state the caveat
plainly rather than hiding it: the `qhash` field is a correlation handle, not
anonymisation, because a short digest of a low-entropy query is
brute-forceable.

**The agent-mode egress.** With `[agent] enabled = true`, the caller's question
and the fetched page text leave for the configured model endpoint — a third party
that does not exist in the two-tool path. It is off by default. A way to reach
that endpoint, its key or its responses without the operator's configuration is
in scope.

**Resource exhaustion from a hostile page or provider** — a response that escapes
the download, text, snippet or passage caps.

## Out of scope, deliberately

These are documented non-features, not oversights. Each is stated with its
reason where it is enforced, and a report about one is answered by that
statement rather than by a patch.

- **The HTTP listener has no authentication.** Every call it serves is billed, so
  the bind address is the entire access control story — hence the `127.0.0.1`
  default. Publishing it on a routable address is a decision to trust everyone
  who can reach it. Multi-user hosting needs **auth** first, and auth is not
  shipped work; a spend ceiling is a separate question and not the gate —
  ROADMAP §5 declines the ledger and states why.
- **Prompt injection through fetched text.** Whoever controls a page controls
  what lands in your model's context. Nothing in this proxy can make fetched text
  safe to follow as instructions; the tool description says so, and
  [fetch-safety.md](docs/reference/fetch-safety.md) names it as the part that is
  not solved.
- **`robots.txt` is not consulted**, and **JavaScript is not executed** by the
  local fetcher. Both are deliberate; the second is what the renderer fallback in
  `fetch.fallback` exists for.
- **DNS rebinding is narrowed, not closed.** The address check runs before httpx
  resolves the name again for the connection, so an entry that changes in that
  gap is not caught. The trade-off is written up in `fetcher.resolve_public`.
- **The deployment's egress boundary.** The proxy bounds which provider *names*
  a call may dispatch to (`permitted_providers`), and `fetch.enabled = false`
  closes the `fetch` tool and builds no fetcher at all. It holds no list of the
  hosts it is willing to dial, and that is a decision rather than a gap: the
  hosts a search may reach follow from the enabled provider set, a `fetch`
  target is arbitrary by design, and a host list copied into the app drifts
  from the providers it was meant to bound. The two-container shape that gives
  the two tools different egress rights is
  [deploying.md](docs/reference/deploying.md). The app-side rule rests on a
  network that holds the host lists, because an arbitrary `fetch` target cannot
  be bounded by a list the app maintains; that half is in the tree:
  `deploy/compose/` starts each role behind its own Squid proxy, with the search
  role ending in `deny all` behind a host list rendered from the adapters' own
  `ENDPOINT` constants, and the fetch role refusing a named set of sinks —
  callback services, public upload sinks, tunnel listeners, metadata names —
  before allowing the rest. `EGRESS_FETCH_POLICY=strict` flips the fetch proxy to
  an allow-list. A name list is a policy, not a defence: what it bounds is the
  shapes an injected prompt reaches for, and the address-side half stays the
  SSRF guard plus a `nonpublic` ACL at the socket.
- **`fetch.allow_private_addresses = true`** is the operator's own escape hatch
  for intranet fetches. It applies to the local fetcher only; a fallback
  validates its target unconditionally, because handing an internal hostname to
  another networked service is a leak rather than a fetch.
- Anything that requires the attacker to already have the operator's
  environment, config file, or the ability to run code on the host — the keys are
  there by design.
- The security of the third-party search and scrape providers themselves.

## Versions

`0.1.0` is the first public release, and the source on `main` is the version
that gets fixes: a security fix lands there and in the next release cut from it,
and there is no backport matrix for older tags yet, because 0.1.0 is the only
one. Read the tree, not a packaging mirror, as the current state: the artifacts are
published by `.github/workflows/publish.yml` when a `v*` tag names `main`'s head — a
wheel asset on that release and an image at `ghcr.io` — while a PyPI.org artifact stays
open work ([ROADMAP §1](docs/ROADMAP.md)).

The README's 0.x warning applies on top of that: config keys, the provider set
and log fields may change between 0.x releases without a deprecation cycle, and
each change lands in the reference page that owns the fact.
