# seekwright (OCaml port) — README

An MCP server that fronts web-search providers behind one normalised tool
surface, built as **one native executable**: 16.5 MB stripped (15.8 MiB), musl-
linked, on a 37 MB Alpine runtime layer that carries it plus two libraries. No
interpreter, no package manager state, no compiler at run time. Three tools —
`search`, `fetch`, `answer` — over the same config, routing and REST projection
as the Python implementation, on Alpine, as UID 10001.

This branch ports [seekwright](README.md) to OCaml; the Python tree in this
checkout is the reference implementation the port is built against. The port is
a **production candidate**: the F9.3 checklist and the parity declaration in
[`plans/seekwright-ocaml-port.md`](plans/seekwright-ocaml-port.md) record what
was verified, how, and at which commit. It is **not** full behavioural parity —
a fetched PDF has no reader on this port, and the extraction backend is not
`trafilatura` — so [`ocaml-docs/divergences.md`](ocaml-docs/divergences.md) stays
the first page an operator of the Python deployment should read. Turning the
candidate into a limited production release is a maintainer decision, not a
branch one.

[`VISION.md`](VISION.md) is the spec both implementations steer by, and
[`plans/seekwright-ocaml-port.md`](plans/seekwright-ocaml-port.md) is the
living plan for this one.

## The three tools

| Tool | What it does |
| --- | --- |
| `search` | one query to one provider, normalised results. Optional `mode="free"` restricts the route to providers that cannot bill |
| `fetch` | a URL in, extracted page text out, with `offset`, `query`, `path` and `structure` to read a long page several ways |
| `answer` | agent mode: server-built retrieval plan, one model call, validated citations. Off until `[agent] enabled = true` |

## Get it running

```bash
VERSION="$(dune build version.txt >/dev/null; cat _build/default/version.txt)"
docker build -f Containerfile.ocaml --build-arg SEEKWRIGHT_VERSION="$VERSION" \
  -t seekwright-ocaml .
docker run --rm -p 127.0.0.1:8000:8000 seekwright-ocaml --http --host 0.0.0.0
curl -s http://127.0.0.1:8000/healthz
```

That is the path this branch actually runs: with no config file the image starts
on the keyless providers (`exa:free`, `parallel:free`, `freeserp`) and answers
`{"status":"ok","providers":["exa:free","parallel:free","freeserp"],…}`. The
`--build-arg` is not decoration: the build stage refuses a version label that
does not equal `dune-project`'s. BuildKit picks up
`Containerfile.ocaml.dockerignore` by name, so the build context is 18 kB of OCaml
sources and nothing else.

`--host 0.0.0.0` is load-bearing **inside** the container: the default bind is
loopback, and a server bound to the container's own loopback publishes nothing —
`docker run -p …:8000:8000 … --http` starts healthy (the image's `HEALTHCHECK`
probes `/healthz` from inside the network namespace, where it is reachable) while
every curl from the host is refused. Publishing a port is the operator's decision;
the loopback default is what makes that decision visible. The whole container
guide — base pinning, CVE scanning, the `HEALTHCHECK` under podman, keys, the
config volume, and running on a read-only root — is
[`ocaml-docs/container.md`](ocaml-docs/container.md).

**From source** — OCaml 5.3.0, dune ≥ 3.11, and the packages the two manifests
declare:

```bash
eval $(opam env --switch=default --set-switch)      # this host's build env, plans/infra-setup.md
opam install . --deps-only --with-test --with-doc -y
dune build @install && dune runtest --force && dune build @doc
_build/install/default/bin/seekwright --check
```

`libgmp-dev` (or the GMP search-path workaround) is required: zarith, reached
through `tls → mirage-crypto-pk`, links `-lgmp`.

## Configure it

Config path: `$SEEKWRIGHT_CONFIG`, else `~/.config/seekwright/config.toml`.
Keys come from the environment only, always `SEEKWRIGHT_`-prefixed and named
for the backend (`SEEKWRIGHT_EXA_API_KEY` also serves `exa:free`). A provider is
a **table**, and a flavoured name has to be quoted because `:` ends a bare TOML
key:

```toml
default_provider = "exa:free"   # top-level, so it precedes every table

[providers."exa:free"]
enabled = true

[providers.freeserp]
enabled = true
```

An enabled name whose key is missing is a startup error, so only add a keyed
provider together with its `SEEKWRIGHT_*_API_KEY`. The keyless set — the names
that answer anonymously with no account, no key and no card — is `exa:free`,
`parallel:free` and `freeserp`; enabling nothing at all resolves to those three
rather than nothing. `[fetch]` needs no key. Everything the server reads is in
[`ocaml-docs/configuration.md`](ocaml-docs/configuration.md).

Then serve, or ask it directly:

```bash
seekwright --http --port 8000      # streamable HTTP at /mcp on 127.0.0.1:8000
seekwright                         # stdio MCP (the default transport)
seekwright --check                 # the config plus a keyless readiness probe of each name
seekwright search "OCaml 5.3 released" --provider exa:free --json
seekwright fetch https://example.com --query "status code"
```

`seekwright answer "what changed in Dune 3.21"` is the third verb; it answers
only once `[agent] enabled = true` and `SEEKWRIGHT_AGENT_API_KEY` are set, and
`seekwright --check --live` adds one **real** search per ready provider, so it
bills for anything that can. Note there is no `--help`: an unknown flag is exit
2, and this file is the usage prose.

## Where the detail lives

| Page | Covers |
| --- | --- |
| [`ocaml-docs/divergences.md`](ocaml-docs/divergences.md) | **read this first if you run the Python deployment** — what changed, what still works, and the one port-specific guardrail |
| [`ocaml-docs/configuration.md`](ocaml-docs/configuration.md) | every section and key, env-var names, the two refused keys, `--check`'s exit codes |
| [`ocaml-docs/container.md`](ocaml-docs/container.md) | building and running the image, scanning it, user and ownership, `HEALTHCHECK`, config volume |
| [`ocaml-docs/egress.md`](ocaml-docs/egress.md) | the exact outbound endpoint inventory, provider by provider and fallback by fallback, plus the no-proxy stance and the CA trust store |
| [`ocaml-docs/live-tests.md`](ocaml-docs/live-tests.md) | running the live harness against real providers, and its current coverage |
| [`ocaml-docs/testing.md`](ocaml-docs/testing.md) | the hermetic suite, the pinned diffs, and how the port is cross-checked against the Python implementation |
| [`ocaml-docs/privacy.md`](ocaml-docs/privacy.md) | what is stored, where, how to back it up or wipe it, and the dashboard, metrics and `--metrics` routes |
| [`plans/ocaml-finalisation.md`](plans/ocaml-finalisation.md) | what is done and what is left on this branch |

## Privacy, in one paragraph

No cache is used unless `[fetch] cache_dir` is set, and no journal is written
unless `[dashboard] history_path` is set; with neither key, one process writes
**nothing to disk at all**. Query text goes only to the provider that answers,
and provider responses are normalised and sanitised before they reach you.
Provider API keys are never sent to a third-party service other than the
provider's own endpoint. Details in [`ocaml-docs/privacy.md`](ocaml-docs/privacy.md).
