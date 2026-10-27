# The public API

What this server's callers may depend on, what they may not, and which of the
three surfaces is the contract. The tool, the REST projection and the CLI client
ship in the same wheel.

The request side of each surface -- tool arguments, REST route body keys, CLI
verbs, server flags, provider names, config keys -- is read out of the tree and
checked in at [surface.md](surface.md). CI re-prints and diffs that list and
exits 1 on drift, or on a manifest with no marker line, and 2 when it is absent.

## The contract is three operations, not three surfaces

The contract is `search`, `fetch` and `answer`: their inputs, their outputs, and
the prose an error carries; everything else is an encoding of it. `answer`'s own
contract prose — parameters, `AnswerResponse`, the failure table — is
[agent-mode.md](agent-mode.md)'s.

| Surface | What it is |
|---|---|
| **MCP** | The canonical encoding. `stdio` by default; streamable HTTP at `/mcp` under `--http`. The schema is generated from the decorated signatures in `server.py`, and the response models are `models.SearchResponse` / `models.FetchResponse` / `models.AnswerResponse`. |
| **REST** | The same three operations projected onto plain JSON, on the same listener, so a caller that is not an MCP client — a shell script, `curl`, a Go program, the CLI below — need not speak JSON-RPC. An encoding, not a capability. |
| **CLI** | A client of the REST projection, and nothing else: every flag maps to a field of one of the three request shapes. |

The rule that keeps them one contract: **the REST request body is the tool's
parameter set, and the REST response body is the tool's response model.** No field
exists in one encoding that the other lacks, and no REST-only operation is
invented. When the two disagree, the tool surface is wrong.

| Operation | Input | Output |
|---|---|---|
| `search` | `query` (2–400 chars); `provider`?; `mode`? (`free`; not with `provider`); `max_results` (1–20, default 5); `include_domains`? (≤20); `exclude_domains`? (≤20); `recency`? (`day`\|`week`\|`month`\|`year`); `language`? (ISO 639-1, two letters); `safe_search`? (bool) | `SearchResponse` |
| `fetch` | `url` (8–2048 chars, absolute `http(s)`); `offset`? (≥0); `query`? (2–400); `path`? (1–400, e.g. `$.items[*].name` — one part of a JSON document, named by the caller); `provider`? (free text — a fetch provider this server runs; there is no name for the local reader, so omitting it is the default route, the local reader unless `fetch.primary` names a provider) | `FetchResponse` (`image` when the resource is an image and `fetch.allow_images` is on — the bytes unextracted, which is why that field is a body and not a `snippet`) |
| `answer` | `query` (2–400 chars) and the `search`-shaped filters, plus `extra_queries`? (≤2, each 2–400) and `depth`? (`brief`\|`report`) — the parameter table is [agent-mode.md](agent-mode.md)'s | `AnswerResponse` |

`models.SearchQuery` also carries `country`, which no tool parameter exposes; it
stays off the public API until one does, so the encodings cannot drift.

`fetch` names **one axis at a time**: `query` selects passages, `path` selects
inside a JSON document, `offset` pages through the page. More than one is a `400`,
not a precedence: the order the server applied them would become contract, and no
caller can read an order off the two operations. A selection is bounded by
`fetch.max_match_chars` and reports what the bound cut; `offset` continues a text
response that came back `truncated`.

An image is the one place the two encodings of a `fetch` carry a body
differently, because only one has a place for bytes. Over MCP it arrives as an
image content block beside the JSON, and `image` is left out of the JSON projection
so the picture is not billed twice. Over REST it arrives as `image.base64` inside
`FetchResponse`, `content_type` naming its media type and `image.byte_count` its
decoded size. Adding `image` is the "adding a response field" case below, so the
path version does not move.

### Versioning rule

- The three operations are unversioned and stable — the README's standing promise
  that "the `search` and `fetch` surfaces are the contract and are meant to stay
  stable", with `answer` joining them. Tool and parameter names do not change.
- The REST encoding carries its version in the path: `/api/v1/…`.
- **Breaking** — a new path version: removing or renaming a response field,
  adding a required request field, changing what an existing field means, or
  changing what a status code means.
- **Not breaking** — same version: adding an optional request field, or a
  response field. A consumer must ignore unknown fields, and `models.WireModel`
  omits absent ones rather than sending `null`, so a new optional field is
  invisible until it is set.
- **Outside the contract, free to change in any 0.x release**: config keys, the
  provider set, log field names, `/healthz`, `/dashboard` — the README's 0.x
  rule, unchanged.

## The REST projection

Served by `--http`, on the same listener as `/mcp`.

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/api/v1/search` | the `search` tool's parameters | `200` + `SearchResponse` |
| POST | `/api/v1/fetch` | the `fetch` tool's parameters | `200` + `FetchResponse` |
| POST | `/api/v1/answer` | the `answer` tool's parameters | `200` + `AnswerResponse` |

All three are POSTs, `application/json` in and out. `fetch` is a POST rather than
`GET /api/v1/fetch?url=…` because a URL a model chose off a third-party page is
the same sensitivity class as a query, as `engine.py`'s `_log_for` argues for the
log line: a query string lands in every access and proxy log on the path, and a
body does not.

All three routes sit **behind the same Host/Origin allowlist as `/mcp`**: the
`_guard` `/dashboard` uses. They carry data and spend money, so they do not get
`/healthz`'s deliberate exemption from DNS-rebinding protection, which exists for a
kubelet probe whose `Host` is a pod IP.

There is **no separate config key**: the routes are part of the HTTP transport, so
the switch is `--http` itself, plus the bind address.

### Status codes

| Status | When |
|---|---|
| `200` | the operation produced a response — including zero results, and including a response whose `notice` reports an ignored filter or a dropped citation |
| `400` | the body does not validate; `provider` names one this deployment does not serve, or is omitted with no default configured on a deployment that has a name which can bill; `fetch` names a fetch provider this server did not build (`FetchEngine.resolve`, which names the ones it did); `fetch` is given more than one of `query`, `path` and `offset`, or a `path` the tree's grammar cannot read; a guardrail refuses the URL as written (`UrlBlocked`, before any request is in flight — the guardrails that fire once one is, a redirect hop included, are `502`) |
| `404` | the operation is not served here — `[fetch] enabled = false`, or `[agent] enabled = false` |
| `502` | the operation was dispatched and failed upstream: provider error, quota exhausted, timeout, extraction failure — on the answer route, either phase, retrieval or the model call, with the message naming which |
| `503` | the process is stopping (`_shared` is gone), the same signal `/healthz` gives |
| `421` | the request never reached the operation: FastMCP's DNS-rebinding protection refused its `Host` header, and the body is `Invalid Host header` as plain text, not the `error` object below. Loopback is always allowed; a call from another machine names its address with `--allowed-host` (see "Reaching a deployment on another host") |

The error body is `{"error": "<message>"}` — the same message the MCP tool hands
the model. The caller-facing prose is part of the contract: a caller has to
recover in one call, which is a property of the sentence, not of the exception
type. Never a traceback, never an exception object.

The 400/502 split is the one distinction the REST layer needs and the tool layer
does not draw. `SearchFailed` and `FetchFailed` each cover both a refusal and a
dispatch failure, and the tool hands both back as one sentence because a model can
act on either without knowing which. REST has to tell "refused before dispatch"
from "failed after dispatch", so the two refusals carry their own subclasses.
`engine.SearchRefused` is the `400` — a name this deployment does not serve, `mode`
and `provider` together, a `mode="free"` route that cannot serve.
`engine.FetchRefused` likewise: a contradictory request, an unreadable `path`, the
URL-level `UrlBlocked` refusal (the only guardrail that fires before a request is
in flight). Everything else is a `502`.

The answer route reaches the same split: its one guardrail refusal is a `provider`
pin, asked for before dispatch through `SearchEngine.resolve`, so it is a `400`;
retrieval and the model call both leave as an `AgentFailed`, a `502`.

### Auth: none, and single-operator by construction

The REST API does not imply auth, and does not change who the listener is for.
`/mcp` settled it first: HTTP is a second transport whose only boundary is the
network — no token, no OAuth, the bind address and published port the whole access
control story, which is why `--host` defaults to `127.0.0.1`. A REST route on the
same listener inherits that exactly and offers nothing `/mcp` does not already
offer the same reachable set.

What *would* be a reversal is making the REST API multi-user. The gate is
**auth** on the listener, which sits on ROADMAP's deliberately-not list — not a
spend/call ceiling: ROADMAP §5's ledger is declined and was never the gate. A
per-caller budget needs auth *and* a ceiling; a route that cannot bill needs
neither. So:

- **The REST API is single-operator.** One deployment, one operator's provider
  keys, one operator's bill: no caller identity, no per-caller quota or budget, no
  audit trail keyed to a caller.
- **Multi-user REST is gated**, on a separate decision to add auth — and, if
  per-caller budgets are wanted, on a ceiling not being built either.

REST is a second way to drive one operator's deployment, not a first step toward
hosting one for others.

## The CLI client

`seekwright search …`, `seekwright fetch …` and `seekwright answer …`:
subcommands of the existing entry point, in Python, in this package.

```
seekwright search --server URL QUERY
    [--provider P] [--max-results N]
    [--include-domain D]... [--exclude-domain D]...
    [--recency day|week|month|year] [--language CODE]
    [--safe-search|--no-safe-search] [--json]
seekwright fetch --server URL URL
    [--query Q] [--offset N] [--path P] [--provider P] [--json]
seekwright answer --server URL QUERY
    [--depth brief|report] [--extra-query Q]... [--provider P]
    [--include-domain D]... [--exclude-domain D]...
    [--recency day|week|month|year] [--language CODE]
    [--safe-search|--no-safe-search] [--json]
```

`--server` defaults to `http://127.0.0.1:8000` — the address `--http` binds by
default, so the two halves line up with no configuration. Default output is for a
person; `--json` prints the response body verbatim, so it pipes into `jq`. Exit
codes follow `--check`'s convention: `0` on success, `1` on an error the server
returned, `2` on a usage error.

### Reaching a deployment on another host

Supported: the deployment holds the config, the provider keys and the bill, and
the calling machine holds none. `--server` takes the base URL of any reachable
`--http` listener, and nothing client-side changes for a remote one. Two server-side
things change, both the `--http` decisions a networked MCP client already needs:

- the listener is bound to an interface the caller can route to — `--host
  0.0.0.0` inside a container, where the published address decides who reaches
  it;
- the host the caller sends in its `Host` header is named in `--allowed-host`,
  which adds to FastMCP's loopback-only allowlist. A trailing `:*` matches any
  port, e.g. `--allowed-host 192.0.2.10:*`.

An unlisted name is refused with `421 Invalid Host header` before the route body
runs; the client passes that sentence to stderr and exits `1`. It is the first
failure a remote caller meets, and it is a server-side flag, not a client bug.

Auth is still nothing — the reachable set is the access control — so a listener on
a routable address deserves the care that boundary asks for. [container.md](container.md)
§"Calling it from a script: the REST routes" drives the same three routes with
`curl`, for a machine that installs no Python and no wheel.

Constraints on the implementation:

- The bare invocation and every existing flag — `--check`, `--live`, `--metrics`
  (and its `--json` companion), `--http`, `--host`, `--port`, `--allowed-host`,
  `--log-level`, `--log-format` — keep working unchanged; a bare `seekwright` still
  runs the stdio server.
- The CLI never runs the engine in-process, never reads `[providers]`, and never
  touches a provider API key: keys, config and spend all live on the server.
- Its request and response types are `models.py`'s, imported rather than
  re-declared, so the client cannot drift from the contract.

## What is not in the public API

The omissions are decisions.

- **No auth, no tokens, no OAuth, no per-caller identity, no quotas or
  budgets.** Auth is the gate anything per-caller would need first; ROADMAP's
  deliberately-not list holds it, and §5's ceiling was never the gate.
- **No multi-user anything**: no tenancy, no per-key accounting, no
  caller-attributed audit.
- **No cache** — no cache endpoints, headers or semantics. Every `search`
  reaches a provider, because a stale answer to a freshness question is not one.
- **No routing or provider-selection endpoint.** Nothing infers a provider from a
  query or picks the cheapest for the caller: the caller names one or takes the
  default. Where every enabled name cannot bill and no default is set, the free set
  serves the search — a ceiling of zero, not a choice made for the caller. An
  inferred route bills a price the caller never named; a `/api/v1/route` or a
  `strategy` field on the search body is that reversal.
- **No configuration or provider management.** Nothing over HTTP reads or writes
  the config, enables a provider, or lists which keys are present. Config is a file
  the server reads at startup, and providers are explicit opt-in — except that a
  config enabling nothing resolves to the three keyless names.
- **No `cost_usd` on the wire.** The caller is not the party paying
  (`models.py`); spend goes to the operator through the log line and dashboard.
- **No API-key passthrough.** A caller cannot supply a provider key; keys come
  from the server's environment only.
- **`/healthz`, `/dashboard`, `/dashboard/data` and `/dashboard/metrics` are
  operator surfaces, not public API.** They are unversioned, exist only under
  `--http`, and may change or disappear in any release; `/healthz` is deliberately
  outside the Host allowlist so a kubelet probe whose `Host` is a pod IP reaches
  it. The field schema behind the dashboard's two data routes is
  [metrics.md](metrics.md)'s.
- **No new operations.** The operation set is exactly `search`, `fetch` and
  `answer`, the guard that keeps "a REST API" from becoming "a second product". A
  fourth operation is a product decision, not an API design; the third was that
  decision, and its contract is [agent-mode.md](agent-mode.md).
- **No streaming, no async jobs, no webhooks, no long-poll.** `fetch`'s `offset`
  and `query` are the only paging there is.
- **No stable config schema.** Config keys are 0.x and change without a
  deprecation cycle (README).

## Compatibility and migration

**Nothing is deprecated and nothing is removed.** The REST projection is additive.

- **MCP is unchanged.** Nothing on the MCP side moves with the REST projection:
  tool names, parameters, response models, annotations, the stdio default and every
  existing `mcpServers` block are untouched. The MCP surface's own change — `answer`
  joining its tools — is [agent-mode.md](agent-mode.md)'s.
- **`--http` is unchanged for existing clients.** `/mcp` keeps its behaviour, its
  statelessness, its Host/Origin allowlist and its `421` semantics; three routes
  join the same app behind the same `_guard`, `/healthz` keeps its exemption, and
  the dashboard's routes stay where they are.
- **Nothing moves to the REST API.** The dashboard keeps reading the process
  recorder, `/healthz` keeps its shape, and the log events keep their names and
  fields.
- **What an operator should know before upgrading:** with `--http` on, a caller who
  can reach `/mcp` can now also POST three JSON endpoints. Same three operations,
  same spend, same reachable set — but one fewer protocol to implement, so a
  listener on a routable address deserves the care the no-auth boundary already
  asks for.
