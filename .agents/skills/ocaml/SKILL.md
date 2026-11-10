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
- `Schema.t` is a plain alias for `Yojson.Safe.t`, so a schema can be written by
  hand or built with `Schema.object_ ~properties ~required ()`.
- Handler errors: return `Ok (Tool.text …)` for success, `Ok (Tool.error_text
  …)` for a tool failure (arrives as `isError: true`), and reserve the handler's
  `Error` channel for JSON-RPC-level problems. A result that does not match the
  advertised `output_schema` comes back as a JSON-RPC error, not a tool error.
- Transports: `Mcp_kit_stdio.run_channels server stdin stdout` (stdio, line
  delimited, creates its own session, stops at EOF),
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

## Verified building the M0 workspace (2026-11-10)

`dune-project`, `lib/caps/`, `examples/{echo,caps_echo}.ml`, `test/` build and
pass; both echo servers answer `initialize` → `notifications/initialized` →
`tools/call` and a modern `server/discover` + `_meta` call over stdio.

- **Dune derives the wrapped module from `(name)`, not `(public_name)`.**
  `(library (name caps) (public_name mcp-caps))` gives `Caps`. `Mcp_caps` needs
  `(name mcp_caps)`.
- With one `(package)` stanza, dune requires the package name to equal the
  project `(name)`; with two stanzas (`mcp-caps`, `seekwright`) that check is
  off. A package with no stanzas attached yet (the `seekwright` placeholder)
  needs `(allow_empty)`.
- Don't write `(dune (>= 3.11))` in `(depends)`: dune adds the constraint from
  `(lang dune 3.11)` and the result is `"dune" {>= "3.11" & >= "3.11"}`.
- `(deps (glob_files ../lib/caps/*.ml))` — one atom, not a list — puts the
  library sources in a test's sandbox; a `(test)` action's cwd is its own
  directory, so it reads them as `../lib/caps/…`.
- The dev profile treats warnings as errors: an unused variable, an unused
  value not in the `.mli`, or an unused operator binding fails the build.
- **OCaml 5.3.0 has no `Result.Syntax`.** Use `let ( let* ) = Result.bind` and
  `let ( >>= ) = Result.bind` in the module that needs them.
- `Mcp_kit.Schema.check_input_schema` only rejects a schema *document* that is
  not a JSON object: `{"type":"string"}` passes it. `Schema.require_input_object`
  is the one that insists the root describes an object, and it **raises**
  `Invalid_argument` — catch it and turn it into a value when validating a
  declaration. `Schema.empty_object` is `{"type":"object","properties":{}}`, so
  it survives that check.
- `Server.add_tool`'s error has four constructors (`Duplicate_tool` plus three
  more), so a match on it needs a fallthrough case.
- An MCP tool name that reaches `Server.of_registry` must be a usable string;
  the layer accepts `[A-Za-z0-9-_.:]`, which covers `backend:flavour` provider
  names.
- Provenance to recheck before any mcp-kit upgrade: the opam-repository entry
  for `mcp-kit.0.2.0` names Mathias Bourgoin (Nomadic Labs) and
  `gitlab.com/nomadic-labs/ai-harness/ocaml-mcp`, and that is the archive the
  checksum pins — but the tree inside that archive describes itself as "Epure
  Team" / `github.com/epure-team/mcp-kit` (see its `dune-project` and the
  installed `lib/mcp-kit/opam`). Unexplained; worth an upstream question.

## Verified fixing the caps review (2026-11-10)

- A UTF-8 truncation cut is decided from the first **excluded** byte, not the
  last included one: if `text.[off]` is a continuation byte, back up to that
  character's lead byte and return its index (exclusive). `Error.sanitize` does
  this; a test that inspects the last byte after the appended `"..."` is
  vacuous, so validate the prefix with a real UTF-8 decoder instead.
- In an alcotest test's dune sandbox, `Sys.readdir "../lib/caps"` lists exactly
  the `.ml` files copied by `(deps (glob_files ../lib/caps/*.ml))`; that lets a
  source guard walk every sibling and exempt only `server.ml`, instead of
  hardcoding a module list. `Filename.check_suffix ".ml"` does not match `.mli`.
