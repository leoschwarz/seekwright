# The OCaml image

One `Containerfile.ocaml`, one image, one binary. The Python artifact keeps its
own `Containerfile` during the transition; the two share the operational
conventions an operator already knows — UID 10001, `SEEKWRIGHT_CONFIG`, a busybox
`HEALTHCHECK` on `/healthz` — so one bind mount and one probe config serve both.

## Building it

```bash
VERSION="$(dune build version.txt >/dev/null; cat _build/default/version.txt)"
DOCKER_BUILDKIT=1 docker build \
  -f Containerfile.ocaml \
  --build-arg SEEKWRIGHT_VERSION="$VERSION" \
  --build-arg SEEKWRIGHT_REVISION="$(git rev-parse HEAD)" \
  -t seekwright-ocaml:dev .
```

BuildKit selects **`Containerfile.ocaml.dockerignore`** automatically, because it
looks for `<dockerfile>.dockerignore` before `.dockerignore`. That matters here
more than usual: the context this build needs is `lib/`, `bin/`, the two `.opam`
manifests with their locks, and the dune files — while the Python build's
`.containerignore` drops exactly those, and this one drops `src/` in return. The
suites (`test/`, `live/`), the repo instruments (`ocaml-tools/`) and every prose
tree stay outside the context, so nothing test-only can reach a published image.
The context this build sends is **18 kB** (measured:
`transferring context: 18.39kB`), against the checkout's full size.

podman needs the flag spelled out, because its default ignore file is
`.containerignore` — the Python build's:

```bash
podman build --format docker -f Containerfile.ocaml \
  --ignorefile Containerfile.ocaml.dockerignore \
  --build-arg SEEKWRIGHT_VERSION="$VERSION" -t seekwright-ocaml:dev .
```

`--format docker` is not cosmetic: podman's default OCI format ignores the
`HEALTHCHECK` instruction, so the image would carry no probe.

## What the build does, and why each part is there

**Base: `alpine:3.22`, both stages.** The scan gate refuses CRITICAL/HIGH with
`--ignore-unfixed=false`, and the Debian `trixie-slim` base measured several HIGH
findings with no fix released (util-linux, zlib, perl). `alpine:3.22` measured
zero at that severity. The builder is Alpine too, not a Debian compiler image:
the executable is musl-linked, so a glibc builder would produce a binary this
runtime cannot `exec`.

**Dependencies come from the committed lock files.** `seekwright.opam.locked` and
`mcp-caps.opam.locked` are installed with `opam install --deps-only --locked`,
against the opam-repository snapshot they were resolved against
(`SEEKWRIGHT_OPAM_REPOSITORY`, pinned to a commit in the URL). One row is
rewritten, and the rewrite is guarded:

- The locks were exported from this host's `default` switch, which opam created
  from the distribution compiler, so they pin `ocaml-system 5.3.0`. A container
  builds its own musl compiler, which opam calls `ocaml-base-compiler`.
- The build therefore rewrites that one row, refuses if the row is not there to
  rewrite, and then rewrites it *back* and `cmp`s against the committed file. If a
  future lock drifts, or the `sed` stops matching, the build fails instead of
  quietly resolving 100 packages freely.
- `--no-depexts` skips opam's system-package name matching: the `apk` line installs
  the C libraries the `conf-*` packages probe, and those packages then check for
  themselves, which is the stronger test.

**The apk line is the toolchain the manifests need**: `gmp-dev` (zarith),
`pkgconfig`, `liburing-dev` and `linux-headers` — `uring`'s vendored liburing
headers include `linux/swab.h`, which musl does not ship, so that one missing
package fails the dependency build. None of it reaches the runtime layer.

**Version labels are checked, not trusted.** `SEEKWRIGHT_VERSION` must equal
`dune-project`'s `(version …)`; the build stage compares them and fails if the
`--build-arg` disagrees with the tree it is reading. `Version.mcp_server`
(`0.1.0`) is deliberately never the label: that is the MCP `serverInfo` identity,
not the release. See `plans/infra-setup.md`'s F9.1 section for the one-owner rule.

## What the image contains

| Layer content | Value |
| --- | --- |
| Runtime packages | `gmp` (zarith's C stub) and `ca-certificates` (the trust store `ca-certs` reads) — the names `ldd` printed in the build stage, and nothing else: `libgmp.so.10` plus musl, no `liburing` (the `uring` binding links statically) |
| Binaries | `/usr/local/bin/seekwright` only. No `seekwright-live`, no sources, no tests, no compiler, no opam, no dune |
| Binary size | **16,539,864 bytes** (15.8 MiB) after `strip`, from 28,705,688 bytes before it; `file` reports a stripped PIE, dynamically linked against `/lib/ld-musl-x86_64.so.1` and `libgmp.so.10` |
| Image size | **37,293,789 bytes unpacked** (8.97 MB base + 1.7 MB apk + 16.6 MB binary layer), **9,961,989 bytes** as `docker save \| gzip -1` |
| User | `seekwright`, uid and gid **10001**, group made explicitly: busybox `adduser -S` alone puts a system user in `nogroup` |
| Working directory | `/var/lib/seekwright`, `0755`, owned `10001:10001` — the mount point for the two opt-in writers |
| Environment | `SEEKWRIGHT_CONFIG=/etc/seekwright/config.toml`; `/etc/seekwright` itself is **not** in the image |
| `ENTRYPOINT` | `["seekwright"]` — arguments go straight to the server |
| `HEALTHCHECK` | busybox `wget -q -O /dev/null http://127.0.0.1:8000/healthz` |

The config file is not baked in: it names providers and never holds a key, so
bind-mount it. Keys come from the environment only, so a container that gets keys
from a secret store needs no volume at all.

## Running it

```bash
# loopback HTTP on the host, keyless providers only — no secrets, no keys
docker run --rm -p 127.0.0.1:8000:8000 seekwright-ocaml:dev --http --host 0.0.0.0

# a keyed provider, and a journal
docker run --rm -p 127.0.0.1:8000:8000 \
  -e SEEKWRIGHT_EXA_API_KEY \
  -v "$PWD/config:/etc/seekwright:ro" \
  -v seekwright-journal:/var/lib/seekwright \
  seekwright-ocaml:dev --http --host 0.0.0.0
```

**`--host 0.0.0.0` is what makes the published port reachable.** The default bind
is loopback, and inside a container that is the container's own loopback: without
the flag the server starts, the image's `HEALTHCHECK` goes `healthy` (the probe
runs in the container's network namespace, where it is reachable), and every
request from the host through `-p` is refused. Bind address is the access control
here — the listener has no auth — so the image does not decide it for you.
`--allowed-host` adds names to the Host allowlist when you publish the port under
another name; a `421 Invalid Host header` means a name is missing there, not that
the check should go away. `/healthz` is deliberately outside that allowlist so a
kubelet probe with the pod IP in `Host` works, and it stays secret-free for that
reason.

With no config file the image starts on the keyless three and says so on stderr:

```
INFO startup providers="exa:free,parallel:free,freeserp" unsupported=null \
  default_provider=null providers_defaulted=true fetch=true \
  fetch_extractor="stdlib" fetch_primary="http" agent=null
```

`GET /healthz` then answers `{"status":"ok","providers":["exa:free","parallel:free",
"freeserp"],"default_provider":null,"uptime_s":4}`, and a REST call that names a
provider this build did not compile is a 400 that lists what it did:

```bash
curl -s -X POST http://127.0.0.1:8000/api/v1/search \
  -H 'content-type: application/json' \
  -d '{"query":"anything","provider":"no-such-provider"}'
# {"error":"Provider 'no-such-provider' is not enabled on this server.
#  Available: exa:free, parallel:free, freeserp. Retry with one of those."}
```

Stdio works the same way: `docker run -i --rm seekwright-ocaml:dev` speaks MCP on
stdin/stdout with the keyless defaults, and EOF closes it. The startup line above
is the only thing it writes to stderr; stdout stays the JSON-RPC channel.

`SIGTERM` drains: `docker stop` on a running server logs `INFO http.stopping
grace_seconds=10.0` and the container exits **0**, so a rollout waits for in-flight
calls rather than cutting them.

### Mounts, and what happens when one is not writable

Two keys opt into writing, and each owns one path under `/var/lib/seekwright` in
this image:

```toml
default_provider = "freeserp"

[providers]
[providers.freeserp]
enabled = true

[dashboard]
history_path = "/var/lib/seekwright/usage.jsonl"

[fetch]
cache_dir = "/var/lib/seekwright/cache"
```

```bash
docker run --rm -v "$PWD/config:/etc/seekwright:ro" \
  -v seekwright-state:/var/lib/seekwright seekwright-ocaml:dev --check
```

`--check` reads the mounted file through `SEEKWRIGHT_CONFIG`, reports the names it
built and the cache it opened, and dials nothing that bills. It is the rehearsal
for the mount: the cache directory is created (`0700`) by the process, and the
journal file is opened at startup — `Usage.create` opens it precisely so an
unwritable bind mount fails at boot rather than on the first append. So with
`history_path` set and no writable mount:

```
seekwright: not writable: /var/lib/seekwright/usage.jsonl (io)     # exit 1
```

and `--check` says the same about the cache in its report
(`cache … UNAVAILABLE: the writable root … could not be created as a directory`)
and also exits 1. A mounted directory has to be writable by **10001:10001**; a
named volume gets that from the image's own `install -d`.

Without either key the process writes nothing, so the root filesystem can be
read-only:

```bash
docker run --rm --read-only --tmpfs /tmp -p 127.0.0.1:8000:8000 \
  seekwright-ocaml:dev --http --host 0.0.0.0
```

Add a writable mount only where you configured a path to write.

## Scanning it

The gate is what CI enforces (`.github/workflows/ocaml-image.yml`):

```bash
trivy image --severity CRITICAL,HIGH --ignore-unfixed=false seekwright-ocaml:dev
```

Measured on `seekwright-ocaml:dev` built from `254f122` with trivy 0.76.2: **0
findings at CRITICAL/HIGH**, and one at MEDIUM across all severities — `zlib
1.3.2-r1`, `CVE-2026-4738`, whose fix version is `1.4-r0`, newer than what the
`alpine:3.22.8` tag carries. That is the shape of this gate: the CRITICAL/HIGH rung
is empty, so a finding at that severity is a reason to move the base pin, not to
add an exception.

`--ignore-unfixed` stays off. An unfixed CRITICAL/HIGH is a fact about the image
you are shipping, and the fix is a base-pin bump in the same change.

Two limits of that scan are worth knowing before you rely on it:

- It covers the **18-package Alpine layer** — the alpine base, `musl`,
  `apk-tools`, openssl's `libcrypto3`/`libssl3`, `zlib`, `gmp`, `ca-certificates`
  and the busybox utilities — which is where CVE findings live in an image like
  this one, and where the whole report came from.
- It does **not** cover the OCaml dependency graph. trivy has no parser for opam
  or for the committed `*.opam.locked` files; measured with trivy 0.76.2, an
  `fs` scan of this checkout reads `test/conformance/package-lock.json` and
  `uv.lock` and reports no OCaml package at all. The reproducibility control for
  the dependency set is therefore the lock files plus the pinned repository
  snapshot, which is also why an upgrade lands as a lock refresh in one commit.

When the base grows a finding, the change is a `FROM alpine:3.22.x` pin bump (or a
newer branch once it scans clean), the runtime apk line re-checked against
`ldd`, and a re-scan in the same pull request.

## What the image job asserts

`.github/workflows/ocaml-image.yml` builds the image, scans it, and then runs the
container as shipped — the point being that a green `dune runtest` says nothing
about a musl-linked binary inside a layer with two libraries. Each step is a
contract about the running image:

| Assertion | Why it is there |
| --- | --- |
| `id -u` and `id -g` are 10001 | `USER` and the explicit group took effect |
| `--help` prints `seekwright: unknown flag --help` and exits 2 | the usage stance survives packaging; there is no help screen to drift |
| stdio `initialize` then `tools/list` names `search`, `fetch` and `answer` | the three tools are registered in the shipped binary, with the 17-name provider enum in their schemas |
| `GET /healthz` answers 200 with `status`, `providers` and `uptime_s` | the HTTP path and its health route work in the runtime layer |
| `POST /api/v1/search` with an unknown provider answers 400 naming it | the REST projection is wired and its refusal lists this build's names |
| `docker stop` exits 0 after `INFO http.stopping` | SIGTERM drains rather than cutting |
| `--read-only --tmpfs /tmp` serves `/healthz` | the no-writes default holds in a hardened container |
| a mounted `/etc/seekwright` config plus a `/var/lib/seekwright` volume passes `--check`, then the journal file and cache directory exist | the documented first-run path is tested, not described |
| `ldd` names only `libgmp.so.10` and musl, and no `ocaml`/`opam`/`dune`/`gcc`/`as`, no `/src`, `/opam`, `/app` | the runtime layer is the artifact plus the libraries it needs |

Every one of these ran against the image built on this branch and passed; the CI
job is the same sequence.

## Upgrades and rollback

The image is tagged by `org.opencontainers.image.version`, which the build
guarantees equals `dune-project`'s version, and by
`org.opencontainers.image.revision`, which is the commit you passed. Rollback is
"run the previous tag": nothing migrates, there is no state to roll forward —
the journal is append-only JSONL and the cache is disposable, so an older binary
can read both. A `--check` against the candidate config before the swap is the
whole rehearsal: it exits non-zero on anything this build cannot honour, including
a provider whose key is missing and a cache root it cannot create. One caveat on
that rehearsal: a deployment whose only enabled names are MCP-only free providers
exits 1 from `--check` for having no probe to run, which is not a reason the
server would not start — see `ocaml-docs/configuration.md`, "Flags, combination
guards, exit codes".
