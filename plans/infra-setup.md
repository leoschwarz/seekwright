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

## Notes for the port

- mcp-kit 0.2.0 requires OCaml >= 5.1 and dune >= 3.11 — satisfied.
- Constrain every mcp-kit component to `= 0.2.0` in `dune-project`. An opam
  switch pin, if needed, is a separate environment operation, not a dune stanza.
- M0–M2 need no OCaml TLS stack: inbound TLS belongs to the gateway. M3's
  outbound `Net` authority does need verified HTTPS and adds `tls-eio` and
  `ca-certs`; the current package set is therefore not sufficient for M3.
