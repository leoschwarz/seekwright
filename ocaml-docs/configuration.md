# Configuration (OCaml port)

Everything the server reads comes from one TOML file plus `SEEKWRIGHT_*`
environment variables. There is no other configuration channel: no command-line
config, no runtime reload, no per-call credential.

The frozen list of every key, in its table, is printed by
`ocaml-tools/surface.ml` and pinned by `ocaml-tools/surface.expected`: **49
section keys over 6 tables, 12 per-provider keys, 9 top-level keys**. That
golden is diffed against the Python tree's `docs/reference/surface.md` body by a
`runtest` rule, so the two deployments cannot drift apart silently. This page
explains what the keys *do*; the golden is what they *are*.

## Where the file lives

1. `$SEEKWRIGHT_CONFIG` if set — the path the container image sets by default.
2. Otherwise `~/.config/seekwright/config.toml`.

A file that does not exist is not an error: the process runs on defaults, which
means the keyless providers, the `stdlib` reader, `fetch` enabled, agent mode
off, no journal, no cache. A file that does not *parse*, or that names a
provider or key this port cannot honour, is a startup failure: the message names
the table and the key.

A minimal file:

```toml
default_provider = "exa:free"   # top-level, so it has to precede every table

[providers."exa:free"]
enabled = true

[providers.freeserp]
enabled = true
```

A provider entry is a table, not a boolean: `[providers] exa = true` is refused
with `providers.exa: expected a table, found a boolean`.

`[providers."exa:free"]` must be quoted when you configure the flavoured name
itself — a bare `exa:free` is not a TOML bare key. (`Config.key_name` strips one
matched pair of quotes on read, which is what makes a quoted flavoured key
round-trip.)

## Credentials, and only credentials, come from the environment

`SEEKWRIGHT_<BACKEND>_API_KEY`, named for the **backend** segment:
`SEEKWRIGHT_EXA_API_KEY` serves both `exa` and `exa:free`, because `:` is not
legal in a POSIX variable name. Agent mode reads
`SEEKWRIGHT_AGENT_API_KEY`. `algolia` additionally reads `app_id` and `index`
from `[providers.algolia]`, and `searxng` reads `url` from `[providers.searxng]`
— the environment is never a source for those two (see
`ocaml-docs/live-tests.md`, which is the only place they appear as fixtures).

Nothing else is read from the environment except two operational variables:
`SEEKWRIGHT_CONFIG` (the path above) and `SSL_CERT_FILE`, which the `ca-certs`
library honours when locating a trust store (see `ocaml-docs/egress.md`).

## Providers are opt-in; the empty set is the keyless set

`config.KEYLESS_PROVIDERS` on this port is `exa:free`, `parallel:free` and
`freeserp` — the names that reach their endpoint anonymously, with no account,
key or card. A config that enables nothing resolves to those three, and both the
startup line and `--check` say so out loud. An enabled provider whose key is
missing is **startup-fatal**; `searxng` is gated on its config `url` instead.
`anysearch` needs nothing and is still explicit-only.

What `--check` reports is the *built* set, not the configured one:

```
  enabled   exa:free, parallel:free, search1api
  effective exa:free, parallel:free, search1api
  built     exa:free, parallel:free
  untested  search1api is untested on this port: …
  search1api not built on this port
```

`built` is what the process can dispatch; a name in `enabled` but not `built`
here means the credential to construct it was absent. `untested` names enabled
names whose live verification against the real endpoint has never run in this
build — a reachability probe is not one, and a name leaves that line only when
a live run has passed (see `ocaml-docs/live-tests.md`).

## The ladders, and what is refused

`default_provider` and `permitted_providers` are top-level keys;
`[search] fallback` and `[search] free_fallback` are the two ladders;
`[search] health_*` drives the health board that gates a name out of the
*fallbacks* only. `search(provider=…)` names are checked against the effective
set (`enabled ∩ permitted`); a named provider is terminal — no ladder behind it.
Nothing infers a provider from the query.

`[fetch] primary` and `[fetch] fallback` choose the read route and its walk.
`[fetch] fallback` may name only rows in `KNOWN_FALLBACKS` (`crawl4ai`, `jina`,
`scrappa`, `tavily`, `linkup`), each at most once, and at most one billable
name, last — the validator reads each row's `billable` flag rather than a
hard-coded name. `[fetch] auto_fallback` is **off** by default: the primary's
refusal names the ladder rather than spending a second vendor. Agent mode passes
`auto_fallback = true` for the pages it reads.

`[fetch] extractor` accepts **`stdlib` only** on this port. `trafilatura` is a
Python-only registry member, so naming it is a config error at load rather than
a surprise at first fetch; the reasoning is in `config.known_extractors`.

Two `[logging]` keys are read but deliberately **not honoured**, and setting
them to a non-default value is refused at load:

- `logging.library_level` — "there is no uvicorn here, so no uvicorn loggers to
  hold down";
- `logging.access_log` — the same reason for uvicorn's per-request line.

The rest of `[logging]` (`level`, `format`, `log_content`, `log_queries`) works
as the Python tree documents: logs go to **stderr** only, and stdout is the
JSON-RPC channel under stdio.

`[fetch] cache_dir` and `[dashboard] history_path` are the only two keys that
make this process write anything. See [`privacy.md`](privacy.md).

## Flags, combination guards, exit codes

Ten server flags, all of them in the golden: `--check --live --json --metrics
--http --host --port --allowed-host --log-level --log-format`. The guards:
`--live` only with `--check`; `--json` only with `--metrics`;
`--host`/`--port`/`--allowed-host` only with `--http`; and `--metrics` is its own
mode, refused beside `--check`, `--live`, `--http`, `--host`, `--port` or
`--allowed-host` because it reports and exits. `--log-level` takes one of loguru's seven upper-case levels (`TRACE DEBUG INFO
SUCCESS WARNING ERROR CRITICAL`); `--log-format` takes `text` or `json`. Signals (SIGTERM/SIGINT) are
handled on the HTTP path only.

| Exit | Meaning |
| --- | --- |
| 0 | success, or an HTTP server that drained on a signal |
| 1 | config error, a refused flag combination, or a startup refusal (an enabled provider with no key, a refused key, an unbuilt name) |
| 2 | usage error: an unknown flag or verb. Note there is **no `--help` and no `--version`**; `seekwright --help` prints `seekwright: unknown flag --help` and exits 2 |

### `--check` dials, and `--check --live` bills

`--check` is a diagnosis, and it is a **network** operation: after printing the
five provider sets (enabled, effective, built, unsupported, untested) it runs a
keyless readiness probe against every built name that has one — a bodyless GET —
and never sends a key on that path. The two anonymous MCP rows, `exa:free` and
`parallel:free`, have no probe in this build and each prints `no connectivity
probe`: their readiness is the MCP handshake at warmup, which the probe
vocabulary cannot express. So expect DNS and egress to the providers you enabled
to work when you run it (see [`egress.md`](egress.md)).

`--check --live` then adds **one real search per ready permitted provider** — the
one path on this port that bills. Each row carries the per-1k figure
`[providers.*] cost_per_1k` corrects, or `unbilled` for a name that cannot
charge, so probing the free half is safe and the keyed half is not free.

The exit code counts problems, and the counting is per row: a name this binary
does not carry at all, a probe that comes back as anything but reachable, an
`[fetch] primary` route the deployment's gates do not build, an enabled
`[agent]` block missing its endpoint or model, an uncreatable
`[fetch] cache_dir`, an extractor library that is not installed. Two rows are
deliberately **not** counted: a name this port builds but has no probe for,
which is a hole in the diagnosis rather than a fault in the config; and an
enabled name the binary carries that this deployment could not build for want of
a key. Both print a row — `no connectivity probe` and `not built on this port`
respectively — and neither moves the exit code. **What that means before you
make `--check` a deployment gate**: a keyless MCP-only deployment, `exa:free`
and `parallel:free` and nothing else, prints `no connectivity probe` for both
names, prints a `probes` line naming them, prints no `no providers ready`
sentence, and exits **0** — the same config boots and serves. The `no providers
ready -- searches would fail until configured` sentence and exit 1 still fire
where a build or a probe actually failed: `test/check_unreachable.expected`
(a probed name found down) and `test/check_probe_gap.expected` (an unprobed
built name beside a probed name found down) pin both halves, and both dial only
a closed loopback port. The startup verdict and `GET /healthz` are the authority
on whether the process serves; treat `--check`'s exit code as "the config names
something this binary cannot honour, or a probe failed".

### Caps, agent mode, and what is not honoured

`[policy]` holds the three figures that bound a response's size and duration:
`max_snippet_chars`, `max_result_text_chars` and `provider_timeout_seconds`. A
result carries `snippet` **or** `text`, never both, and the length a cap
discarded rides its own `search.cap` log event rather than the response.

`[agent]` is off by default (`enabled = false`). Turning it on needs the model's
`base_url` and `model` in config and `SEEKWRIGHT_AGENT_API_KEY` in the
environment; the retrieval plan is fixed and the model never chooses what gets
searched, so the per-call ceiling (`max_cost_usd`, the `max_output_tokens_*` and
`max_material_chars` figures) is arithmetic, not accounting. Its contract is the
Python tree's `docs/reference/agent-mode.md`, which this port implements.


## Client verbs

`search`, `fetch`, `answer` are also client verbs that call a deployment's REST
projection (`--server`, default `http://127.0.0.1:8000`). They read no config,
build no provider and need no key:

```bash
seekwright search "OCaml 5.3 released" --provider exa:free --max-results 5 --json
seekwright fetch https://example.com --query "status code"
seekwright answer "what changed in Dune 3.21" --depth quick
```

Their flags are the tool parameters one-for-one (`--recency`,
`--include-domain`, `--exclude-domain`, `--language`,
`--safe-search`/`--no-safe-search`, `--offset`, `--path`, `--structure`,
`--extra-query`, `--depth`), plus `--json` and `--server`.
