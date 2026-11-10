---
name: ocaml
description: Load this skill for any OCaml work on the ocaml-port branch — workspace layout, toolchain gotchas, mcp-kit 0.2.0 API, and the plans that steer the port. Read it before writing OCaml here, and append anything new you verify.
---

# OCaml on the ocaml-port branch

This branch ports seekwright to OCaml (see the branch notice in `AGENTS.md`).
The plans in `plans/` steer the work; this skill is the verified toolchain and
API knowledge so agents don't rediscover it. **Append what you verify** — keep
it factual, dated, and short.

## Environment (verified 2026-11-10, Debian 13, vps-01)

- Every new shell: `eval $(opam env --switch=default)`
- `opam init` already created the `default` switch with `ocaml-system.5.3.0`.
  Do NOT run `opam switch create 5.3` — it fails; use the `default` switch, or
  `opam switch create <name> ocaml.5.3.0` for a compiled switch.
- OCaml 5.3.0, dune 3.24.2.
- Full setup/repro steps and gotchas: `plans/infra-setup.md`.

## Installed opam packages

`dune mcp-kit mcp-kit-eio mcp-kit-cohttp-eio mcp-kit-ppx eio cohttp-eio yojson
uri alcotest logs toml` — all at mcp-kit 0.2.0 / cohttp(-eio) 6.3.0 / yojson 3.0.0.

Gotcha: **`mcp-kit-stdio` is not an opam package.** The stdio adapter ships
inside `mcp-kit` as the findlib library `mcp-kit.stdio` (module
`Mcp_kit_stdio`). Transport packages that exist separately: `mcp-kit-eio`,
`mcp-kit-cohttp-eio`, `mcp-kit-ppx`.

## mcp-kit 0.2.0 API (verified against the README and installed .mli)

- Build a server: `Mcp_kit.Server.create ~name ~version ()`, then add tools
  with `Mcp_kit.Server.add_tool server tool` (returns a result).
- Make a tool: `Mcp_kit.Tool.make ~description ~input_schema name handler`;
  input is JSON-Schema-validated before the handler runs. PPX alternative:
  `mcp-kit-ppx` with `ppx_deriving_yojson`/`ppx_deriving_jsonschema`.
- Transports: `Mcp_kit_stdio.run_channels server` (stdio),
  `Mcp_kit_cohttp_eio.handler server` (Streamable HTTP; wire it into a
  cohttp-eio route yourself), `Mcp_kit_eio.run_flow` (raw Eio flow).
- One server value serves concurrent clients; sessions are per connection.
- Outbound HTTPS (needed for provider calls at M3) additionally needs
  `tls-eio` and `ca-certs` (see `plans/infra-setup.md`).

## Workspace layout (decided in plans/project-structure.md)

- Root dune workspace. Packages: `mcp-caps` (library in `lib/caps/`, wrapped
  module `Mcp_caps`) and `seekwright` (later, depends on `mcp-caps`).
  Generated `*.opam` files are committed, never hand-edited.
- `examples/` holds demo servers (echo first); `bin/main.ml` is reserved for
  the future `seekwright` executable; `test/` mirrors `lib/`.
- The Python tree (`src/`, `docs/`, `tools/`, …) is a read-only oracle. Never
  edit it on this branch. Dune ignores directories without `dune` files.
- Every module gets an `.mli`. Abstract types with no constructors are how
  `lib/caps/authority.mli` makes grants unforgeable — don't expose constructors.

## Conventions

- Plans are living documents: update the relevant `plans/` file in the same
  commit when code settles differently.
- Commit style: one lowercase line, area first (`plans: …`, `caps: …`).
- Verify with `eval $(opam env --switch=default) && dune build && dune runtest`
  from the repo root before reporting done.
