# Dev environment / infra setup — ocaml-port

Status: verified on this machine (vps-01, Debian 13 "trixie", x86_64), 2026-11-10.
Recreate from scratch with the steps below.

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
- M0–M2 need no OCaml TLS stack: inbound TLS belongs to the gateway. M3's
  outbound `Net` authority does need verified HTTPS and adds `tls-eio` and
  `ca-certs`; the current package set is therefore not sufficient for M3.
