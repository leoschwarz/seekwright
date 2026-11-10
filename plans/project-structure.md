# Project structure — ocaml-port branch

Status: draft, v1 (root layout decided). The Python tree stays in the checkout but
is inert: dune ignores directories without `dune` files, so `src/`, `tests/`,
`tools/` are simply not part of the OCaml workspace. The workspace root is the
repo root, containing two libraries.

## Why this shape

- **One workspace, two libraries.** `mcp-caps` is the reusable capability layer
  (the thing future MCP servers build on); `seekwright` is the port that depends
  on it. Separate public libraries means the fallback from the capability plan —
  binding tools to `mcp-kit` directly — is a change inside `seekwright` only, and
  `mcp-caps` remains usable on its own.
- **Root layout.** The branch's purpose is the port, so the OCaml workspace
  occupies the root; the Python files remain for reference and as the
  differential oracle but are not built. No promotion step is needed later.
- **The library boundary is the audit surface.** `Registry.add ~grant` lives in
  `mcp-caps`; only `bin/main.ml` (and tests) construct grants. That keeps
  "which tool may do what I/O" greppable in one file.

## Tree

```
├── dune-project                 # (lang dune 3.x); generates the two .opam files
├── mcp-caps.opam                # generated: mcp-kit, eio, yojson, uri; M3 adds HTTP/TLS deps
├── seekwright.opam              # generated: deps = mcp-caps, cohttp-eio, toml, uri, ...
├── dune                         # root: (dirs lib bin tools test plans) — _build ignored
├── lib/
│   ├── caps/                    # public library mcp-caps (wrapped as Mcp_caps)
│   │   ├── dune                 # (library (name mcp_caps) (public_name mcp-caps)
│   │   │                        #   (libraries eio mcp-kit uri yojson)) — no dependency on seekwright
│   │   ├── error.ml / .mli      # structured, safely renderable failures
│   │   ├── event.ml / .mli      # bounded, content-free policy audit events
│   │   ├── authority.ml / .mli  # '_kind t plus Fs/Net operations; Proc deferred
│   │   ├── tool.ml / .mli       # ('caps, 'input) Tool.t, schema + decode + Output.t
│   │   ├── registry.ml / .mli   # add ~grant — the only place a grant meets a tool
│   │   ├── policy.ml / .mli     # with_root, with_endpoints, with_public_web,
│   │   │                        #   with_operation_timeout, with_log
│   │   ├── policy_net.ml / .mli # private checked DNS/connect/redirect/response bounds
│   │   └── server.ml / .mli     # the one module that knows mcp-kit:
│   │                            #   Registry.t -> Mcp_kit.Server.t; transports in apps
│   ├── router.ml / .mli         # P1: pure routing, ported 1:1 from src/seekwright/router.py
│   ├── model.ml / .mli          # P2: wire records + Yojson encoders (WireModel rule:
│   │                            #   unset fields never serialize)
│   ├── sanitize.ml / .mli       # P2: U+200B escape pass; reversible/idempotent/deterministic
│   ├── config.ml / .mli         # P3: TOML config + SEEKWRIGHT_* env secrets
│   ├── provider.ml / .mli       # P4: module type S (the adapter contract)
│   ├── providers/               # one module per adapter, seventeen names
│   ├── engine.ml / .mli         # P5: SearchEngine / FetchEngine over router
│   ├── health.ml / .mli         # circuit breaker + probe
│   ├── usage.ml / .mli          # in-memory aggregate + JSONL journal writer fiber
│   ├── log.ml / .mli            # dotted event names, bound fields, stderr only
│   ├── agent.ml / .mli          # P7: fixed plan + exactly one model call
│   └── fetch/
│       ├── fetcher.ml           # P6: HttpFetcher behind a validated Net grant
│       ├── extractor.ml         # backend module type + KNOWN_EXTRACTORS
│       ├── extractors/stdlib.ml # HTML via a parser lib; claims no PDF
│       ├── jsondoc.ml           # JSON rendering, path grammar, render_schema
│       └── tabledoc.ml          # CSV into jsondoc's line grammar
├── bin/
│   ├── dune                     # (executable (name main) (public_name seekwright)
│   │                            #   (libraries seekwright mcp-caps mcp-kit.stdio ...))
│   └── main.ml                  # the audit surface: one Registry.add line per tool,
│                                #   grant named; stdio vs cohttp-eio dispatch
├── tools/
│   └── surface.ml               # prints the frozen surface manifest from the tree;
│                                #   diffed against the Python tools/surface.py output
└── test/
    ├── dune                     # alcotest suites, one per lib module
    ├── router/                  # ported tests/test_router.py — first differential proof
    ├── should_not_compile/      # missing/wrong grant and external Fs constructor;
    │                            #   compilation must fail with the expected diagnostic
    ├── differential/            # recorded Python request/response corpus + replayer
    └── live/                    # keyless live tests behind a *_LIVE_TESTS gate
```

## Conventions carried over from the Python tree

- **Module-per-concern, tests mirror modules** (`test/router/` ↔ `lib/router.ml`),
  same as `tests/` mirrors `src/seekwright/`.
- **Interfaces everywhere** (`.mli` per module): the abstract-type trick in
  `authority.mli` is the whole capability claim, and every other module gets an
  interface so the public surface is deliberate, not incidental.
- **Opam files are generated by dune** from `dune-project`, never hand-edited;
  every mcp-kit component has an exact `= 0.2.0` dependency constraint there.
  Opam switch pins are separate environment operations, not dune stanzas.
- **Root `.gitignore` gains `_build/`**; `*.opam` is *not* ignored (generated
  opam files are committed, standard dune practice). The Python-side guards
  (`tools/`, `tests/repo/`) still scan the root and are not run on this branch;
  if one ever scans the new OCaml tree, that is a deliberate PR.
- **CI**: not in v1. When added, the gate mirrors the Python one — build, test
  (including should-not-compile), surface-manifest diff, mcp-kit conformance
  scenarios, keyless live tests.

## Naming (opam/dune conventions)

Two packages, named the way the ecosystem names them — lowercase, hyphenated,
one `public_name` per package:

| Package (opam name) | Wrapped module | Contents |
|---|---|---|
| `mcp-caps` | `Mcp_caps` | the reusable capability layer (authority, policy, tool, registry, server) |
| `seekwright` | `Seekwright` | the port: router, models, providers, engines, fetch, agent |

Mechanics: `dune-project` carries one `(package (name mcp-caps) …)` and one
`(package (name seekwright) …)` stanza (with their `synopsis`/`depends`); each
library attaches to its package via `(library (public_name mcp-caps))` /
`(public_name seekwright)`, and dune generates `mcp-caps.opam` /
`seekwright.opam` from those stanzas — the `.opam` files are committed but never
hand-edited. The executable is `(executable (public_name seekwright))`, so the
installed binary is `seekwright`, matching the Python entry point. Inside
`seekwright`, code refers to the layer as `Mcp_caps.Registry` etc.; the layer
never refers back, which is what keeps the fallback (dropping the layer) a
`seekwright`-side change.

Verified at M0, three mechanics details the sketch above leaves open:
dune derives the wrapped module from the library's `(name)`, not its
`public_name`, so the layer needs `(name mcp_caps)` to be `Mcp_caps`; with a
single `(package)` stanza dune requires it to equal the project `(name)`, which
the two stanzas above sidestep; and the `seekwright` package needs
`(allow_empty)` until P1 attaches its first library to it.

`mcp-caps` is the public name future MCP servers will depend on, so it is the
one name worth getting right; `mcp-kit` sets the local precedent (hyphenated,
short, noun). Alternatives considered: `mcp-policy`, `capmcp` — rejected as
either too generic or against the hyphenation norm.

## Open structural questions

1. Whether `tools/surface.ml` should emit the exact format `tools/surface.py`
   prints (so the manifests diff clean) or its own format with a mapping —
   prefer exact-format, decide at P8.
2. The tree above puts `tools/surface.ml` in the same root directory as the
   frozen Python `tools/` (`surface.py`, `egress_lists.py`, `value_sets.json`).
   The branch notice makes that directory read-only, so the OCaml instrument
   cannot land there without editing the oracle. Decide at P8: give it its own
   directory, fold it into `bin/`, or leave the Python one as the only printer
   and diff against its output. Found at M0, where the collision was harmless
   because dune ignores a directory with no `dune` file in it.
