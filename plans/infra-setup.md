# Dev environment / infra setup — ocaml-port

Status: verified on this machine (vps-01, Debian 13 "trixie", x86_64), 2026-11-10.
Recreate from scratch with the steps below. The CI lane (F0.2) is at the end.

## System packages (apt)

```bash
sudo apt-get install opam build-essential patch m4 bubblewrap unzip libssl-dev
```

`build-essential`/`patch`/`m4` are needed to compile packages from source;
`bubblewrap` lets opam sandbox builds. gcc/make/curl/git/pkg-config were
already present.

## opam and the compiler switch

```bash
opam init            # creates the 'default' switch with ocaml-system 5.3.0
opam update          # refresh the package repository (was already current)
eval $(opam env --switch=default)
```

Gotchas hit on first run:

- `opam init` **already creates a `default` switch** (with the system compiler,
  `ocaml-system.5.3.0`). Do not run `opam switch create 5.3` — that fails with
  "No compiler matching `5.3' found" because the argument must be a compiler
  *package* (`ocaml.5.3.0` / `ocaml-variants.…`), not a version. Either use the
  `default` switch as-is, or create a proper one with
  `opam switch create ocaml53 ocaml.5.3.0`.
- `opam env` must be re-evaluated in every new shell:
  `eval $(opam env --switch=default)`.

## OCaml packages installed (opam, default switch)

```bash
opam install -y dune mcp-kit mcp-kit-eio mcp-kit-cohttp-eio mcp-kit-ppx \
  eio cohttp-eio yojson uri alcotest logs toml
```

Verified installed versions: `mcp-kit` **0.2.0** (+ `mcp-kit-eio`,
`mcp-kit-cohttp-eio`, `mcp-kit-ppx` 0.2.0), `dune` 3.24.2, OCaml 5.3.0,
`yojson` 3.0.0, `cohttp`/`cohttp-eio` 6.3.0, plus transitive deps (ppxlib
0.39.0, ppx_deriving_yojson 3.10.0, ppx_deriving_jsonschema 0.0.4, …).

**`mcp-kit-stdio` is NOT a separate opam package** — `opam install
mcp-kit-stdio` fails with "No package named mcp-kit-stdio found". The stdio
adapter ships inside `mcp-kit` itself as the findlib library `mcp-kit.stdio`
(module `Mcp_kit_stdio`). The transport packages that do exist separately:
`mcp-kit-eio`, `mcp-kit-cohttp-eio`, `mcp-kit-ppx`.

`ocamlfind list | grep -i mcp` after install:

```
mcp-kit             0.2.0
mcp-kit-cohttp-eio  0.2.0
mcp-kit-eio         0.2.0
mcp-kit-ppx         0.2.0
mcp-kit.jsonschema-core        0.2.0
mcp-kit.jsonschema-validation  0.2.0
mcp-kit.stdio       0.2.0
```

## `eio_main`, installed for M1 (2026-11-10)

```bash
opam install -y eio_main     # 1.6; pulled in eio_linux, eio_posix, iomux, uring
```

- `eio` 1.6 is the library; **`Eio_main` is its own opam package** and is not
  pulled in by `eio`. Findlib name `eio_main`, module `Eio_main`.
- `Eio_main.run` chooses the loop from `$EIO_BACKEND`: `linux` or `io-uring` →
  `eio_linux` (needs `io_uring`; this machine has it, and it is the runner that
  opens subtree children with `openat2` RESOLVE_BENEATH), `posix` → `eio_posix`,
  unset **or the empty string** → linux with a posix fallback. An unrecognised
  value raises `Unknown Eio backend`, and OCaml 5.3.0 has no `Sys.putenv` or
  `Sys.unsetenv` at all (`Unix.putenv` exists, `unsetenv` does not), so a test
  that wants to restore "unset" sets `EIO_BACKEND=""`.
- Only `examples/` and the filesystem suite ask for it. `dune-project` declares
  `(eio_main :with-test)`: `Eio_main`'s own interface says a library must not
  call `run`, so `mcp-caps` stays loop-agnostic and the application owns the loop
  (plans/capability-gated-mcp-server.md §6, §7).
- `unix` is deliberately **not** in `(depends)`: it ships with the compiler and
  there is no opam package by that name to resolve, so the test stanzas ask for
  it in `test/dune` and the generated `mcp-caps.opam` stays installable.

## Nothing new for M2 (2026-11-10)

Streamable HTTP on loopback was already installable from the M0 package set:
`mcp-kit-cohttp-eio` 0.2.0 needs no TLS stack, and `cohttp-eio` pulls `http`
(v6.3.0) and `ipaddr` in as its own dependencies. `dune-project` now names
`mcp-kit-cohttp-eio`, `cohttp-eio` and `http` as `(… :with-test)` for
`mcp-caps`, because the example and the HTTP suite are the only stanzas that
link a transport (plans/capability-gated-mcp-server.md §7, §10) — and at
`(lang dune 3.11)` a dependency entry takes a flag or a version constraint, not
both, so these carry no `= 0.2.0` and ride the switch.

## TLS stack for M3 (2026-11-10)

```bash
opam install -y --assume-depexts tls-eio ca-certs
```

Installed into the `default` switch: `tls-eio 2.1.5`, `tls 2.1.5`,
`ca-certs 1.0.3`, `x509 1.2.0`, `mirage-crypto-pk 2.4.1`,
`mirage-crypto-rng 2.4.1`, `zarith 1.14`, plus `asn1-combinators 0.3.3`,
`digestif 1.4.2`, `eqaf 0.10`, `kdf 1.1.2`. `ipaddr 5.6.2`, `domain-name 0.5.0`
and `http`/`cohttp-eio 6.3.0` were already in the M2 set.

- **`--assume-depexts` is required on this machine.** `zarith` and `tls` ask opam
  for GMP through depext, and `sudo` here needs a password, so opam's own depext
  pass fails the install. The packages themselves are fine; only the automatic
  system-package step is unavailable.
- **GMP was placed by hand, not by the package manager.** `libgmp-dev` is absent
  and uninstallable without root:
  1. download the `libgmp-dev` `.deb` into `/tmp/opencode/gmp` (no install);
  2. `dpkg -x libgmp-dev_*.deb /home/leo/.local/opt/gmp-dev`;
  3. the tree's `libgmp.so` symlink dangled, so it was repointed at the runtime
     library that *is* present, `/usr/lib/x86_64-linux-gnu/libgmp.so.10`;
  4. a hand-written `gmp.pc` lives in
     `/home/leo/.local/opt/gmp-dev/usr/lib/x86_64-linux-gnu/pkgconfig/`.
- **Every build in this switch needs that tree on the search path**, or zarith
  fails to link (and with it `mcp-caps`, `tls` and the net suite):

  ```bash
  eval $(opam env --switch=default --set-switch)
  export CPATH=/home/leo/.local/opt/gmp-dev/usr/include:/home/leo/.local/opt/gmp-dev/usr/include/x86_64-linux-gnu
  export LIBRARY_PATH=/home/leo/.local/opt/gmp-dev/usr/lib/x86_64-linux-gnu
  export PKG_CONFIG_PATH=/home/leo/.local/opt/gmp-dev/usr/lib/x86_64-linux-gnu/pkgconfig
  ```

  A CI image that can install `libgmp-dev` properly needs none of this.
- `Mirage_crypto_rng_unix.use_default ()` — the call that installs a random
  generator, which `Policy_net` requires before it will build an https-capable
  grant — comes from the `mirage-crypto-rng.unix` findlib library inside the
  `mirage-crypto-rng` package above, so no extra opam package. Examples and tests
  link it; `mcp-caps` does not, because it pulls stdlib `unix`
  (plans/capability-gated-mcp-server.md §10).
- Nothing was added for *inbound* TLS: the transport stays loopback cleartext and
  `tls-eio` is used on the client side only (`Tls_eio.client_of_flow`).

## Notes for the port

- Provenance to recheck before trusting a version further (seen 2026-11-10): the
  opam-repository entry for `mcp-kit.0.2.0` names Mathias Bourgoin (Nomadic
  Labs) and `gitlab.com/nomadic-labs/ai-harness/ocaml-mcp`, and the checked
  archive is that project's `v0.2.0` tag — but the tree inside it describes
  itself as "Epure Team" / `github.com/epure-team/mcp-kit` (its own
  `dune-project`, and the `opam` file installed under `lib/mcp-kit/`). The
  checksum is fine; the self-description is unexplained. Ask upstream before an
  upgrade widens the trust boundary.
- mcp-kit 0.2.0 requires OCaml >= 5.1 and dune >= 3.11 — satisfied.
- Constrain every mcp-kit component to `= 0.2.0` in `dune-project`. An opam
  switch pin, if needed, is a separate environment operation, not a dune stanza.
- M0–M2 needed no OCaml TLS stack: inbound TLS belongs to the gateway. M3's
  outbound `Net` authority does, and the stack is now installed — see "TLS stack
  for M3" above, including the `--assume-depexts` and GMP notes the build depends
  on. An `http`-only `Net` would not be a completed M3
  (plans/capability-gated-mcp-server.md §5).

## Gotcha: libgmp for zarith/tls-eio (2026-11-10)

M3 pulled in `tls-eio`/`ca-certs` → `zarith`, whose C stub links `-lgmp`.
The box has the runtime `libgmp.so.10` but not the dev symlink, and there is
no sudo. Fix without root: `mkdir -p ~/.local/lib && ln -s
/usr/lib/x86_64-linux-gnu/libgmp.so.10 ~/.local/lib/libgmp.so` and build with
`LIBRARY_PATH=$HOME/.local/lib:$LIBRARY_PATH` (or install `libgmp-dev` via
apt when root is available).

## Node 22 for the M4 conformance run (2026-11-11)

No new OCaml packages: M4 adds no library dependency, only the official
`@modelcontextprotocol/conformance@0.2.0-alpha.11` runner under
`test/conformance/node_modules/`, rendered from the committed
`package-lock.json` by `npm ci --prefix test/conformance --ignore-scripts`
(the runner's own `postinstall` is not run — the pinned package needs no build).

The system `node` is v20.19.2 and **cannot run that runner**: it imports
`globSync` from `fs`, which Node 20 does not export, so it dies at import with a
`SyntaxError` that reads like a broken install rather than a version problem.
`test/conformance/run_live.sh` gates the version and says so. Node 22 without
root, verified:

```sh
cd ~/.local/opt
curl -sfLO https://nodejs.org/dist/v22.23.4/node-v22.23.4-linux-x64.tar.xz
tar -xf node-v22.23.4-linux-x64.tar.xz && mv node-v22.23.4-linux-x64 node22
export PATH="$HOME/.local/opt/node22/bin:$PATH"   # node v22.23.4, npm 10.9.9
```

The live job also needs outbound HTTPS to `registry.npmjs.org` (the `npm ci`) and
nothing else: the fixture listens on an OS-assigned loopback port and the runner
connects to it, so no scenario reaches the public internet. `run_live.sh` records
`node-version.txt`, `npm-version.txt` and `runner-version.txt` in its output
directory beside the raw results. See `test/conformance/README.md` for what the
run is and what it measured.

## CI: the OCaml gate (2026-11-12, F0.2)

`.github/workflows/ci-ocaml.yml` is a separate workflow, not a job inside
`ci.yml`, so the Python lanes keep their current behaviour and a change to one
cannot silently drop the other. It runs on pull requests, pushes to `main` and
`ocaml-port`, and manual dispatch — the `ocaml-port` trigger is what stops the
working branch looking green because `ci.yml` names only `main`.

Its steps, in order:

1. `sudo apt-get install -y libgmp-dev`. zarith's C stub (via `tls` →
   `mirage-crypto-pk`) links `-lgmp`. A machine with a real `libgmp-dev` needs
   none of the local GMP exports above.
2. `actions/cache` restores the local switch `_opam` with the key
   `opam-<runner.os>-<compiler>-<hash(dune-project, *.opam)>`, prefix-restoring
   the compiler when the manifests changed. The key names the compiler and the
   committed manifests, **not** the opam-repository head: a repository snapshot
   that moves is not a dependency change and would make the cache key claim a
   reproducibility it does not have. The trade-off (documented in
   `ocaml/setup-ocaml`'s own caching warning) is that a restored switch can hold
   package versions resolved earlier; `opam install --deps-only` still runs and
   re-resolves from the current repository, and only the compiler and already
   installed packages are reused. Delete the cache or bump `OCAML_COMPILER` when
   that is not wanted.
3. `ocaml/setup-ocaml` pinned to the commit `v3.9.1` resolved to, with
   `ocaml-compiler: "5.3.0"` (exact, not `5.3.x`, which would take whatever
   patch release opam-repository currently carries) and `cache: false` so the
   explicit step above is the only cache.
4. `opam install . --deps-only --with-test --with-doc -y`. `--with-test` supplies
   alcotest/eio_main; `--with-doc` supplies `odoc`, which `dune build @doc`
   requires. Locally that is `opam install odoc`.
5. The ordinary gate from `AGENTS.md` verbatim: `dune build @install`,
   `dune runtest --force`, `dune build @doc`. `dune runtest` also runs the
   negative-compilation pins in `test/should_not_compile/` and the
   `ocaml-tools/` surface and embedded-resource diffs, so those need no separate
   step.
6. `astral-sh/setup-uv` (same pinned SHA as `ci.yml`) and the three read-only
   Python checks: `uv lock --check`, `uv sync`, then
   `uv run python -m tools.surface --check`, `tools.value_sets --check` and
   `tools.egress_lists --check`. Python lint/type/test stay in `ci.yml`.

No step sets `SEEKWRIGHT_LIVE_TESTS`, so no live or billed call is reachable
from this workflow.

### Pin verification (2026-11-12)

The setup action is `ocaml/setup-ocaml`; `actions/setup-ocaml` does not exist.

```sh
curl -sS https://api.github.com/repos/ocaml/setup-ocaml/git/ref/tags/v3.9.1
# refs/tags/v3.9.1 -> ff66428f72b64472e749b22e0ad4dded4b2ddca6, type: commit
# (lightweight tag: no annotated-tag hop through /git/tags/<sha>)
curl -sS https://api.github.com/repos/actions/cache/git/ref/tags/v6.1.0
# refs/tags/v6.1.0 -> 55cc8345863c7cc4c66a329aec7e433d2d1c52a9, type: commit
```

A bump repeats those calls for the new tag, rewrites the SHA in the workflow
and its comment, and records the new tag/date here.

### Local `dune build @doc` needs `odoc`

`dune build @doc` fails with `Program odoc not found in the tree or in PATH` on a
switch without it. `opam install odoc` is the fix. If `odoc-parser` then fails
with `Unbound module "Stream"`, the system `camlp-streams` (Debian ships it
without `.cmi` files) is shadowing the switch's copy in findlib's path; install
with the switch's lib path first:

```sh
OCAMLPATH=$HOME/.opam/default/lib opam install odoc
```

Both were hit on this machine on 2026-11-12; the CI runner is a fresh switch and
needs neither workaround.

## F9.1 packaging metadata, the dependency lock, and mcp-kit provenance (2026-11-14)

**One version owner.** `dune-project`'s `(version 0.1.1)` is the release
version. Dune generates `lib/version.ml` from `%{version:seekwright}` (the rule
is in `lib/dune`; the reviewed half is `lib/version.mli`), and the generated
opam files take their `version:` from the same field. `dune build version.txt`
prints it for a release script or an image label that cannot read a dune file,
and the root `@version` alias depends on that file. The value matches the
Python oracle's `seekwright.__version__`, so the User-Agent is the same string
on both implementations. Nothing else in the tree spells the release number:
`Config.default_user_agent` reads `Version.user_agent`, and
`lib/fetch/fetcher.ml`'s literal is pinned equal by `test/test_metadata.ml`
rather than edited (that layer is outside F9.1's ownership).

`Version.mcp_server` is deliberately a separate value (`0.1.0`). The MCP
`serverInfo` version is protocol identity, the Python server lets FastMCP
supply it rather than `seekwright.__version__`, and `bin/smoke.expected` plus
the conformance transcripts pin it. Moving it would be an identity change, not
a release bump; the metadata suite refuses to let the two values collapse into
one.

**Licence and contact fields.** `(license Apache-2.0)` matches `LICENSE`, and
`dune-project` now carries `(authors …)`, `(maintainers …)`, `(homepage …)` and
`(bug_reports …)` once, so both generated manifests say the same thing and
`opam lint` passes with no missing-field diagnostics. The MIT notices under
`test/conformance/` stay separate: they cover copied upstream fixtures, not
this project's code.

**Floors and pins.** The declared compiler floor is `(>= 5.3.0)` — the compiler
CI builds and this switch runs (`ocaml-system.5.3.0`). The tree is not tested on
an older compiler, so the floor is the tested version, not mcp-kit's own 5.1.
Every mcp-kit component is exact: `mcp-kit = 0.2.0` and
`mcp-kit-cohttp-eio = 0.2.0` in both packages. The `mcp-caps` entry spells the
test-only transport as `(and (= 0.2.0) :with-test)`, because at `(lang dune
3.11)` a dependency entry takes one atom and a constraint plus a flag as two
atoms is rejected. An mcp-kit upgrade therefore moves every component and the
lock together.

**The lock.** `opam lock .` (opam 2.3.0, repository `https://opam.ocaml.org`,
snapshot stamp `a5eaafdc34c654a11462c864b3a55621e68e9ae3`) writes
`mcp-caps.opam.locked` and `seekwright.opam.locked`. Resolution was checked
from an empty switch (`f9-1-resolve`), both with and without the lock:

```sh
opam install --switch=f9-1-resolve --dry-run --deps-only \
  --with-test --with-doc . --working-dir                 # 104 installations
opam install --switch=f9-1-resolve --dry-run --deps-only \
  --with-test --with-doc --locked . --working-dir        # 102 installations
```

Both resolutions succeed; the dry run stops at its confirmation prompt (exit
10), which is not a resolution failure. The unlocked run picks the newest
compiler the floor allows (`ocaml-base-compiler 5.4.1`), while the locked run
resolves `ocaml-system 5.3.0` — the exact compiler the gate was run on. That is
the point of the lock and also its limit:

- **The lock records this host's switch, not a cross-platform build plan.** It
  names `ocaml-system 5.3.0` because the `default` switch was created from the
  system compiler; a lock exported on a CI runner or on a switch created with
  `ocaml-base-compiler` would name that package instead. Host-only entries
  (`conf-gmp`, `conf-pkg-config`) and the local GMP tree below are likewise
  this machine's arrangement, not a production claim. A lock is refreshed by
  `opam lock .` on the switch whose combination was tested, and committed with
  the dependency change that motivated it.
- The locked build has not been installed under a *fresh* compiler from the
  lock alone on this host; what was verified is the resolution above plus the
  working-dir reinstall under the tested compiler.

**`opam install . --with-test` is blocked by pre-existing package
attribution, not by this task.** The generated opam files run
`dune build -p <package> @runtest`, and `-p` restricts the build to one
package. The tree's test stanzas are not package-attributed, so the filtered
build reaches for stanzas in directories F9.1 does not own and fails:

```
File "bin/dune", lines 41-54: Error: No rule found for bin/main.exe
Error: Conflict between the following libraries:
- "mcp-caps" in _build/default/lib/caps
- "mcp-caps" in /home/leo/.opam/default/lib/mcp-caps
  -> required by library "seekwright.fetch" …
```

Fixing that means adding `(package …)`/`(modules …)` attribution across `bin/`,
`test/log_guard/`, `test/differential/`, `live/` and `ocaml-tools/` — outside
the F9.1 ownership boundary and a tree-wide dune change, not a metadata fix. It
is recorded here so the next packaging task starts from the real error rather
than rediscovering it. The equivalent install was verified instead:

- `opam reinstall . --working-dir --with-doc -y` rebuilt `mcp-caps` and
  `seekwright` at 0.1.1 from the working tree and installed both;
- the installed `seekwright` binary, run from outside the checkout with a
  config naming only the `stdlib` extractor, returned byte-identical stdout to
  `bin/smoke.expected` for `initialize` + `tools/list` (serverInfo version
  `0.1.0`) and byte-identical stderr to `bin/smoke_notes.expected`;
- no request left the machine: the smoke script stops before any tool call, so
  no provider endpoint was reached and no key was read.

**mcp-kit provenance, resolved enough to keep the pin.** The opam-repository
entry for `mcp-kit.0.2.0` names Mathias Bourgoin (Nomadic Labs) and
`gitlab.com/nomadic-labs/ai-harness/ocaml-mcp`; the archive it checks is that
project's `v0.2.0` tag (sha256
`43c8319a13be91e323ae952a71ab673533fb3295886029eed9d81e5828de5ef7`). The tree
inside that archive describes itself as "Epure Team" and
`github.com/epure-team/mcp-kit`, which 404s. `epure-team` is a real GitHub
organisation, and Mathias Bourgoin is a contributor to `epure-team/cabal`; the
same maintainer publishes from two homes, and the URL the package declares
about itself is not public. That is a naming/provenance wrinkle, not a
checksum or ownership change, so the candidate stays pinned at `0.2.0` with
the caveat recorded. An upgrade that widens the trust boundary still needs an
upstream answer first, as the earlier note says.


