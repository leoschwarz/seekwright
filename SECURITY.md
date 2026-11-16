# Security policy

seekwright reads provider API keys from the environment, proxies calls that spend
real money, and returns page text written by whoever controls the page. This
document says which of those risks are handled, which are deliberately not, and
where to send a report.

## Reporting a vulnerability

Report privately to **mail@leoschwarz.com** — the maintainer address published in
the `.opam` manifests. Do not open a public issue for anything in the in-scope
list below: an issue publishes the details before there is a fix.

There is no dedicated security address, no PGP key in the tree, and no bug
bounty. If you need an encrypted channel, say so in a first plaintext message.
This is a single-maintainer project with no security team and no on-call rota, so
there is no response-time commitment. A report that is accepted gets a fix on a
branch; how you are credited, and whether the fix is announced, is your call —
say which you want in the report.

Useful in a report: what you did, what you expected, what happened, the version
(`dune build version.txt`, or the image tag and its `org.opencontainers.image.version`
label), and — for anything about the fetcher — the exact URL you asked it to
fetch.

## In scope

**A provider API key reaching somewhere it should not.** The properties the code
is built to hold:

- Keys come from the environment only, as `SEEKWRIGHT_<NAME>_API_KEY`, and are
  never read from the TOML config, because a file gets committed. The one
  credential that does live in the config is `fetch.crawl4ai_token`, which
  authenticates this server to an internal renderer the same file already names —
  see [configuration.md](ocaml-docs/configuration.md).
- A key only ever travels to its own provider's endpoint, and this is a
  capability rather than a convention: every outbound call runs on a network
  grant built for one endpoint (`Factory.grant_of_endpoint`), and a fetch
  fallback dials only the host its own row names (`Remote_target.check`). A
  provider `Authorization` header cannot ride along to a third-party site
  because the grant refuses the dial at all — there is no shared client to leak
  through.
- A key never reaches a log line or an error message. Provider failures carry
  `Provider.error.message`, prose from a fixed vocabulary: no httpx-style
  exception text and no raw response body is ever interpolated, because both can
  echo the request whose headers hold the key. Nothing logs an exception object.
  `test/log_guard/source_discipline.ml` walks the sources so the rule holds at
  every call site rather than only at the ones that were reviewed, and
  `test/log_guard/field_sets.ml` pins the field set of the two decision lines.
- `/healthz` reports provider *names* and uptime and nothing else — not which
  keys are present, not the config path, not the bind address — and it is
  reachable without authentication by design.

**A way around the fetch guardrails.** `fetch` takes a URL chosen by a
suggestible caller and returns text chosen by a hostile page, so both halves are
guarded. Address-side, the guard is a network confinement rather than a check
beside the connection: the grant resolves a name **once**, vets **every** answer
against the special-use table — private, loopback, link-local, multicast,
broadcast, and the cloud-metadata ranges, IPv4-mapped forms included — and then
makes the connection to that vetted address by IP, so the resolve-then-dial gap
an attacker would need is closed by construction, not narrowed. URL-side,
`Fetcher.validate_url` accepts `http(s)` only and refuses a URL with embedded
credentials rather than stripping it. Redirects are followed manually, capped,
and re-validated at every hop (`Redirect_blocked` is the refusal, and an
https→http downgrade is refused). The download is streamed against a byte cap
enforced on accumulated bytes rather than on the `Content-Length` a hostile
server supplied, and one wall-clock budget covers the whole chain. The endpoint
inventory is [egress.md](ocaml-docs/egress.md). A bypass of any of it is a
vulnerability.

**Content or identifiers landing where the documentation says they do not.**
Query text and fetched URLs are recorded only when `[logging] log_queries` is on;
provider content only when `log_content` is on, and then on its own event
(`search.result`, `search.answer`, `fetch.content`) rather than as extra fields
on the decision line. Both are off by default. The usage journal and the dashboard
carry counts, money, timing and provider names — never query text, URLs, titles
or extracted text — and that field set is frozen and pinned, so a new field is a
reviewed change. The docs state the caveat plainly rather than hiding it: the
`qhash` field is a correlation handle, not anonymisation, because a short digest
of a low-entropy query is brute-forceable.

**The agent-mode egress.** With `[agent] enabled = true`, the caller's question
and the fetched page text leave for the configured model endpoint — a third party
that does not exist in the two-tool path. It is off by default. A way to reach
that endpoint, its key or its responses without the operator's configuration is
in scope.

**Escaping the capability layer.** Every outbound call and every write runs on a
grant built by `lib/factory/` — network grants pinned to an endpoint or to public
address space, filesystem grants confined to a written root. A path from a
request handler to a raw socket, an unconfined filesystem handle, or a grant
another route was issued is in scope, and the refusals that keep it impossible
are compiled in `test/should_not_compile/`.

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
  [`VISION.md`](VISION.md)'s non-goals decline the accounts-and-accounting service
  and say why.
- **Prompt injection through fetched text.** Whoever controls a page controls
  what lands in your model's context. Nothing in this proxy can make fetched text
  safe to follow as instructions; the tool description says so.
- **`robots.txt` is not consulted**, and **JavaScript is not executed** by the
  local reader. Both are deliberate; the second is what the renderer fallback in
  `fetch.fallback` exists for.
- **The deployment's egress boundary.** The server bounds which provider *names*
  a call may dispatch to (`permitted_providers`), and `fetch.enabled = false`
  closes the `fetch` tool and builds no fetcher at all. It holds no list of the
  hosts it is willing to dial, and that is a decision rather than a gap: the
  hosts a search may reach follow from the enabled provider set, a `fetch`
  target is arbitrary by design, and a host list copied into the app drifts from
  the providers it was meant to bound. The binary dials its endpoints directly and
  reads no `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`, so the host half of the policy
  belongs to the network in front of it. `deploy/compose/generated/` is that
  half, rendered from the provider and fetch-fallback rows and pinned by
  `dune runtest`: the search role's allow list, the fetch role's allow and deny
  lists. `deploy/compose/squid/*.conf` are reference ACLs for an operator who puts
  a proxy there; the shipped bundle runs none, and a name list is a policy, not a
  defence — what it bounds is the shapes an injected prompt reaches for, while the
  address-side half stays the confinement described above.
- **`fetch.allow_private_addresses = true`** is the operator's own escape hatch
  for intranet fetches: it swaps the confinement for one that admits private
  ranges and still refuses multicast and broadcast. It applies to the local reader
  only; a fallback validates its target unconditionally, because handing an
  internal hostname to another networked service is a leak rather than a fetch.
- Anything that requires the attacker to already have the operator's
  environment, config file, or the ability to run code on the host — the keys are
  there by design.
- The security of the third-party search and scrape providers themselves.

## Versions

`0.1.0` is the first public release, and the source on `main` is the version
that gets fixes: a security fix lands there and in the next release cut from it,
and there is no backport matrix for older tags yet. Read the tree, not a
packaging mirror, as the current state: the artifact is published by
`.github/workflows/publish.yml` when a `v*` tag names `main`'s head — an image at
`ghcr.io` and nothing else. That package is private until the repository's
package visibility is set to Public, so a pull may need `docker login ghcr.io`.

The README's 0.x warning applies on top of that: config keys, the provider set
and log fields may change between 0.x releases without a deprecation cycle, and
each change lands in the reference page that owns the fact.
