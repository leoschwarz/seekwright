# Port plans — ocaml-port branch

This directory is the planning area for the OCaml port. It is the **only** place
port plans live; everything else in the repo belongs to the Python seekwright.

## What is what

| Path | Belongs to | Rule for port work |
|---|---|---|
| `plans/` (this directory) | the OCaml port | the working documents — edit these freely while planning |
| `AGENTS.md`, `docs/`, `VISION.md`, `src/`, `tests/`, `tools/`, `pyproject.toml`, … | the Python seekwright | **read-only oracle** — read them, never edit them for the port |
| `dune-project`, `lib/`, `bin/`, `test/` (when they appear at root) | the OCaml port | implementation lands here per `project-structure.md` |

## Rules

- `VISION.md` stays the spec for both implementations; if a port decision seems
  to conflict with it, the conflict is raised in `plans/`, not resolved by editing
  `VISION.md`.
- The three documents here are living drafts: `capability-gated-mcp-server.md`
  (the mcp-caps layer and its planned fallback to mcp-kit), `seekwright-ocaml-port.md`
  (the P1–P8 port plan), `project-structure.md` (layout and naming, root layout
  decided, packages `mcp-caps` and `seekwright`).
- When a plan is implemented and the code settles, the plan is updated in the
  same change — plans must not drift from the tree they describe.
- Nothing in `plans/` is shipped: like the Python `tools/` and `skills/`, it is
  excluded from any package build.
