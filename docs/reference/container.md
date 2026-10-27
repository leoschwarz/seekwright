# Running in a container

The image serves the HTTP transport so one long-lived process backs every client
on the host or the VPN, rather than each client spawning its own. It runs stdio
too — the entry point is the same CLI — but the reason to build this is `--http`.

Read [deploying.md](deploying.md) first if you are about to expose it: there is no
authentication, on purpose. Serving both tools from one container means
internet-wide egress; [deploying.md](deploying.md) is the two-role shape this
repository ships.

## What the release publishes

A release publishes two artifacts: the wheel as an asset of the GitHub Release the tag
names, and the image at `ghcr.io/leoschwarz/seekwright:<tag>`. Neither exists until a
`v*` tag is pushed, so the commands below build rather than pull, and the
[quickstart](../quickstart.md) documents the clone as the install path.

Two names, and only two. The git tag is `v0.1.0`, and the release run names the
image after that ref verbatim, so the published image tag is `v0.1.0` too. The
version the build carries is `0.1.0`: `pyproject.toml`'s `[project] version`, the
`Containerfile`'s `image.version` label and the User-Agent's, all three checked
against each other by `tests/repo/test_packaging.py`. The `container` job of
`.github/workflows/ci.yml` builds this `Containerfile` at every push to `main` and
runs `--help` inside the result under the unqualified tag `seekwright:ci`, which
names no registry and cannot be pushed. The build is amd64 only. What the release
run does with the image and the wheel is [publishing.md](publishing.md),
maintainer-only.

Multi-stage: `uv sync --locked --no-dev --extra trafilatura` resolves into a
virtualenv on `python:3.14-slim`, and only that virtualenv crosses into the
runtime stage. No compiler is installed — every locked dependency ships a cp314
manylinux wheel, `lxml` included. Read the image size off a build of your own; it
moves with every dependency bump.

The explicit `--extra trafilatura` is load-bearing: `--no-dev` skips the dev
group, which is what pulls in the default extraction backend through the project's
own extra, so without it `fetch` fails at startup for want of a library. The
library-free alternative, `fetch.extractor = "stdlib"`, reads no PDF and keeps the
chrome its skip list does not name, so the image stays on the default name. See
[configuration.md](configuration.md).

Two details that are load-bearing rather than stylistic:

- `--no-editable`. uv installs the project editable by default, leaving the
  virtualenv pointing at `/app/src`, which does not exist in the runtime stage —
  the entry point then dies on `ModuleNotFoundError`.
- `README.md` is copied into the build stage because `pyproject.toml` declares
  `readme = "README.md"`; without it the build fails on metadata.

## Build

```bash
podman build -t seekwright:dev --build-arg SEEKWRIGHT_REVISION="$(git rev-parse HEAD)" .
```

Docker does not find `Containerfile` on its own — that is podman's name for the
file — so name it:

```bash
docker build -f Containerfile -t seekwright:dev \
  --build-arg SEEKWRIGHT_REVISION="$(git rev-parse HEAD)" .
```

`SEEKWRIGHT_REVISION` is the commit you are building from; it lands in the
image's `org.opencontainers.image.revision` label. Passing nothing still builds,
with the label empty — which is what the publish run's revision read-back fails
on. Read the label back with:

```bash
docker image inspect --format \
  '{{index .Config.Labels "org.opencontainers.image.revision"}}' seekwright:dev
```

## Configuration

The image sets `SEEKWRIGHT_CONFIG=/etc/seekwright/config.toml` and
expects you to mount a file there. Nothing is baked in: the config names which
providers are enabled, and that is the operator's choice, not the image's.

```bash
mkdir -p ~/deploy/seekwright
cat > ~/deploy/seekwright/config.toml <<'EOF'
[providers.serper]
enabled = true
EOF
chmod 644 ~/deploy/seekwright/config.toml
```

`chmod 644` is not sloppiness: under rootless podman the container's uid 10001
maps to a subuid, so a `0600` file owned by you is unreadable inside. Relaxing it
is safe because **the config file holds no secrets by design** — API keys come from
the environment and never from TOML ([configuration.md](configuration.md)).

Use a dedicated directory rather than `~/.config/seekwright`: the `:Z` mount
option below relabels its target for SELinux.

## Verify before exposing

```bash
podman run --rm \
  -v ~/deploy/seekwright/config.toml:/etc/seekwright/config.toml:ro,Z \
  -e SEEKWRIGHT_SERPER_API_KEY \
  seekwright:dev --check
```

`--check` costs nothing: it proves the config parses, the keys are present and
the providers are reachable. `--check --live` additionally bills one search per
provider.

## Run

```bash
podman run -d --name seekwright \
  -p 192.0.2.10:8000:8000 \
  -v ~/deploy/seekwright/config.toml:/etc/seekwright/config.toml:ro,Z \
  -e SEEKWRIGHT_SERPER_API_KEY \
  seekwright:dev --http --host 0.0.0.0 --allowed-host 192.0.2.10:8000
```

Three flags, each doing something you cannot skip:

- `-p <addr>:8000:8000` — **this is the access control.** Publishing on one
  specific address rather than bare `-p 8000:8000` keeps the endpoint on a single
  interface (the mesh/VPN interface, say) instead of on every interface the host
  has. Nothing authenticates the listener and every call it serves is billed.
- `--host 0.0.0.0` — binds inside the container's own namespace, not the exposure
  decision; the `-p` address is. The CLI default is `127.0.0.1`, unreachable from
  outside the container.
- `--allowed-host` — FastMCP keeps DNS-rebinding protection on with a
  loopback-only Host allowlist, so a server on a routable address answers `421
  Invalid Host header` until you name what clients will send. Give the `host:port`
  exactly as clients write it, or a `name:*` pattern for any port; repeat the flag
  for several names. Behind a reverse proxy, name the public hostname.

## Registering with a client

The remote block is the stdio block with a `url` in place of `command`/`args`/`env`
— the path is `/mcp`, and it carries no `env` because the client no longer
launches the process: keys live with the container.
[configuration.md](configuration.md) §"Registering with an MCP client" has both
blocks and the client-specific variants, and it is where they are maintained.

## Calling it from a script: the REST routes

The same listener serves `search`, `fetch` and `answer` as plain JSON, so a shell
script, a cron job or a service that does not speak JSON-RPC can drive this
container without an MCP client:

```bash
curl -s http://192.0.2.10:8000/api/v1/search \
  -H 'content-type: application/json' \
  -d '{"query": "python asyncio tutorial", "max_results": 3}'
```

All three are `POST`s under `/api/v1/`, `application/json` in and out, and they
come with the transport — `--http` is the switch, with no config key. They sit
**behind the same Host/Origin allowlist as `/mcp`**, so a name that is not in
`--allowed-host` answers `421 Invalid Host header` here exactly as it does there.
Unlike `/healthz` they carry data and spend money, which is why they get no
exemption. The wheel's own client is the same three operations as `seekwright
search` / `fetch` / `answer` with `--server <url>`, so an installed machine needs
no `curl` and no key of its own. Request shapes, status codes and CLI flags are
[public-api.md](public-api.md)'s; the frozen list is [surface.md](surface.md)'s.

**Nothing authenticates these routes either** — REST is a second encoding on the
same listener, not a second listener with a weaker boundary.

## Logs and health

Everything goes to **stderr**, so `podman logs` has it. Set JSON in the mounted
config — the default is `text`, which suits a terminal rather than a log store:

```toml
[logging]
format = "json"
```

One line per call, with the fields worth aggregating on:

```json
{"ts":"…","level":"INFO","event":"search.ok","provider":"exa","results":5,"cost_usd":0.007,"ms":842}
{"ts":"…","level":"WARNING","event":"exa.escalated","reason":"rate limited","cooldown_s":60.0}
```

`exa.escalated` followed by a run of `exa.cooldown` is the one to alert on: the
free tier failing and the API key paying for it, which nothing else tells you
before the invoice. `fetch.fallback` means a billed Scrappa page, and
`fetch.fallback_failed` means one you were billed for that returned nothing.

Query text is **not** logged by default — only a length and a hash prefix — and
neither is what the provider returned. `log_queries` opts into the first,
`log_content` into the second, which adds a `search.result` line per hit and a
`fetch.content` line per page: turn it on to debug and off after. See
[configuration.md](configuration.md) for the rest of the `[logging]` keys.

`GET /healthz` is served under `--http` only:

```console
$ curl -s localhost:8000/healthz
{"status":"ok","providers":["exa:free","serper"],"default_provider":"serper","uptime_s":1841}
```

Three things to know:

- **It is not behind the `Host` allowlist**, so a probe needs no `--allowed-host`
  entry: an orchestrator probes with the pod IP in `Host`, which can never be
  listed.
- **It never goes unhealthy because a provider is down**, so use it for
  readiness. A 503 means the process is shutting down — conflating a provider
  outage with process health would restart a pod that was working.
- **The image's `HEALTHCHECK` needs `--format docker`.** Podman's default OCI
  output drops it (`HEALTHCHECK is not supported for OCI image format and will be
  ignored`, and `podman inspect --format '{{.HealthCheck}}'` returns `<nil>`), so
  build with `--format docker` if you want it:

  ```bash
  podman build --format docker -t seekwright:dev .
  podman inspect seekwright:dev --format '{{.HealthCheck.Test}}'
  ```

  Kubernetes ignores the instruction either way and needs its own probe stanza
  against `/healthz`. Give a liveness probe a generous `failureThreshold`: all
  it proves is that the event loop is still turning.

## The usage dashboard

`GET /dashboard` serves a self-contained HTML page and `GET /dashboard/data` the
same numbers as JSON, both gated by `[dashboard] enabled` and both existing only
under `--http`. **They sit behind the `Host` allowlist, unlike `/healthz`**: a
browser must reach them under a name in `--allowed-host`, and the bind address
without a matching entry answers `421 Invalid Host header`. Nothing authenticates
them, so protect them exactly as you protect `/mcp` beyond loopback. What the
page, the two data routes and the journal hold is [metrics.md](metrics.md)'s.

What the container adds is the mount. History comes from the append-only usage
journal, so a volume is what makes it survive a container recreate — a volume that
breaks *after* startup is logged once (`dashboard.journal_error`) and then ignored,
so it can never fail a billed call:

```yaml
    volumes:
      - ./config.toml:/etc/seekwright/config.toml:ro
      - ./state:/var/lib/seekwright
```

```toml
[dashboard]
history_path = "/var/lib/seekwright/usage.jsonl"
```

**The mount has to be writable by uid 10001.** The image runs as `seekwright`
(uid 10001) and creates no such directory, so the startup check's own open fails
and exits 1 with
`seekwright: dashboard.history_path: not writable: <path> ([Errno 13] Permission denied: …)`.
Pre-create the *file* world-writable — appending needs write on the file, not the
directory, so this works under rootful and rootless docker alike:

```bash
mkdir -p ~/deploy/seekwright/state
touch ~/deploy/seekwright/state/usage.jsonl
chmod 666 ~/deploy/seekwright/state/usage.jsonl
```

(Or match the uid: `podman unshare chown 10001:10001 ~/deploy/seekwright/state`.)

## Things that will surprise you

- **`fetch` refuses VPN and container addresses.** `fetcher.resolve_public()`
  rejects private ranges, and the CGNAT range `100.64.0.0/10` a host-mesh VPN counts
  as private to Python's `ipaddress`. So the service is reachable *at* such an address
  while being unable to fetch one. That is the SSRF guard working as specified — see
  [fetch-safety.md](fetch-safety.md) — but it means fetching a sibling container
  by name will not work either.
- **The server exits at startup, loudly, on a bad config.** No providers
  enabled, or an enabled provider with no API key, is a `SystemExit` before the
  listener opens. `podman logs` has the message; the container will not sit
  there half-working.
- **One upstream session is shared by every request.** That is the point of the
  process-level context, and `ExaMcpProvider` is built for it. A `startup` event
  per search in the logs means the shared context has been broken —
  `tests/test_server.py::TestSharedContext` is the guard.
- **`--check` writes its report to stdout; everything else is stderr.** The two
  are kept apart because under stdio stdout is the JSON-RPC channel, so a log
  line on it corrupts the protocol. If you ever see this server write to stdout
  while serving, that is a bug.
## The build toolchain

`uv` does the building twice over, from two files. `uv_build` in `pyproject.toml`
is the PEP 517 backend that produces the wheel; the `ghcr.io/astral-sh/uv` image
this Containerfile starts from is the uv that runs it. One toolchain, pinned to
one version (`0.12.3`), with `tests/repo/test_packaging.py` failing if the image
tag stops matching the requirement's lower bound.

The lower bound is the field that matters. `uv build` and `uv sync` warn when
the `uv_build` range excludes the uv running them:

```console
$ uv build
warning: `build_system.requires = ["uv_build>=0.11.25,<0.12.0"]` does not contain the current uv version 0.12.3
```

Bump the two together and deliberately: the upper bound is what keeps a future uv
from changing the backend under a release.

## Bumping the version

`seekwright.__version__` — the literal in `src/seekwright/__init__.py` — is the
single source; the `fetch` User-Agent default
(`seekwright/<version> (+<repo>)`) is built from it at import. Two files cannot
read it and therefore carry a copy:

- `pyproject.toml`'s `[project] version`: `uv_build` requires a static version
  and rejects `dynamic = ["version"]` outright.
- this image's `org.opencontainers.image.version` label: a `LABEL` cannot read
  Python at build time.

So a release bumps three files, in this order:

```bash
$EDITOR src/seekwright/__init__.py    # the source
$EDITOR pyproject.toml Containerfile  # the two copies
uv lock                               # uv.lock records the project's own version
uv run pytest tests/repo/test_packaging.py
```

`tests/repo/test_packaging.py` is the guard: it fails if the three disagree, if
the User-Agent or any page in `docs/`/README quotes another version, or if the
User-Agent names `seekwright.dev` again. `uv lock` is not optional —
`[[package]] name = "seekwright"` in `uv.lock` carries the version too, and the
image resolves with `--locked`, so a skipped re-lock fails in the container build
rather than in review.

