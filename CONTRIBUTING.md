# Contributing to seekwright

seekwright is an MCP server that fronts web-search providers behind one
normalised `search`/`fetch` surface, with `answer` as its third, opt-in tool.
Those three surfaces are the contract; the provider set and the config keys are
not, and may change between 0.x releases. There is no changelog: each change
lands in the `ocaml-docs/` page that owns the fact, beside the reasoning it
rests on.

Bug reports, provider adapters, documentation corrections and small behaviour
fixes are all welcome. [`AGENTS.md`](AGENTS.md) is the source of truth for how
this repository is written; this file is the shorter path to the same
conventions, plus the commands CI runs.

## Where to send what

- **Bugs and feature requests** — the issue tracker at
  <https://github.com/leoschwarz/seekwright/issues>. The bug template asks for
  the output of `seekwright --check`, which is the first thing anyone will need.
- **Security problems** — not the tracker. [SECURITY.md](SECURITY.md) says what
  is in scope and where to report it privately.
- **Code and documentation** — a pull request. `main` is protected, so work on
  a branch and never push or force-push to it. The gate a change has to pass is
  the block of commands below; a PR body says what changed, why, and which of
  those checks were run with their real output.

The **first line of the PR body** names the issue the change resolves,
verbatim: `Fixes #<N>`, or `Part of #<N> - ` followed by the part it lands when
the issue stays open. `<N>` is the issue number; the rest of the body is the
evidence.

## Set up

OCaml 5.3.0 and dune ≥ 3.11, from the pin in `.github/workflows/ci-ocaml.yml`.
The dependency inventory is the two `.opam` manifests; the toolchain and the API
facts a build already proved are in [`.agents/skills/ocaml/SKILL.md`](.agents/skills/ocaml/SKILL.md).

```bash
git clone https://github.com/leoschwarz/seekwright.git
cd seekwright
opam install . --deps-only --with-test --with-doc -y
```

`libgmp-dev` is required: zarith, reached through `tls → mirage-crypto-pk`,
links `-lgmp`. No API key is needed for the default suite: keys are opt-in per
provider, and the live harness refuses to run without an explicit opt-in.

`ocamlformat` 0.29.0 is the pinned formatter (`.ocamlformat`). It is a dev tool
and not a package dependency, so it is its own install step:
`opam install ocamlformat -y`.

## The gate a change has to pass

These are the commands CI runs, in order
(`.github/workflows/ci-ocaml.yml`), and the ones to run before opening a pull
request:

```bash
dune build @fmt           # the tree as the pinned formatter would write it
dune build @install       # the executables, the images' input, version.txt
dune runtest --force      # the suites, the property tests, and every pin
dune build @doc
```

`@fmt` is the fourth command: the tree is formatted with the ocamlformat version pinned
in `.ocamlformat`, and dune's own formatter over the stanzas. CI refuses a file the
formatter would rewrite, so a formatter bump lands as one reformat commit and a change
never carries style churn beside itself.

`dune runtest` is where the frozen facts live, not beside them. It re-renders
the surface manifest and diffs it against `ocaml-tools/surface.expected`; it
re-renders the five model-facing prompts and the dashboard page and diffs them
against their `.expected` files in `ocaml-tools/`; it re-renders the Squid egress
host lists from the provider and fetch-fallback rows and diffs them against
`deploy/compose/generated/`; it re-reads the parity matrix in
`test/differential/matrix/` and refuses a row that names no consumer on this
port; and it compiles the refusal cases in `test/should_not_compile/`, which are
expected to fail. A frozen name moves by changing the code, promoting the pin and
saying why in the PR body:

```bash
dune runtest ocaml-tools --auto-promote   # refresh a pin you meant to move
```

CI also builds the container image and smokes it. Reproduce that locally before a
packaging change:

```bash
VERSION="$(dune build version.txt >/dev/null; cat _build/default/version.txt)"
docker build -f Containerfile.ocaml --build-arg SEEKWRIGHT_VERSION="$VERSION" \
  -t seekwright:dev .
```

The build stage refuses a version label that does not equal `dune-project`'s;
`Containerfile.ocaml`, `dune-project` and the `seekwright.opam` version are one
agreement, and a disagreement fails `test/test_metadata.ml`.

## Tests

The default suite is hermetic — no network, no keys, no billing:

```bash
dune runtest --force
```

The live harness hits real provider endpoints and never runs by default:

```bash
dune build @install
_build/default/live/main.exe --list                                    # dials nothing
SEEKWRIGHT_LIVE_TESTS=1 _build/default/live/main.exe freeserp          # keyless, free
SEEKWRIGHT_LIVE_TESTS=1 _build/default/live/main.exe anysearch         # keyless, free
SEEKWRIGHT_LIVE_TESTS=1 _build/default/live/main.exe fetch:local       # offline fetch arm
SEEKWRIGHT_LIVE_TESTS=1 _build/default/live/main.exe exa              # billed: needs a key
```

Two traps worth knowing. `exa:free` is a **provider**, not a case: the free
names get the bare provider selector, and `--list` prints what each case will and
will not dial. And a provider's free tier is an account quota, not an exemption —
`tavily`, `tinyfish` and `algolia` need a key like any other provider. The
harness's own contract (`live/test_live_cases.ml`) runs under `dune runtest` and
dials nothing; `ocaml-docs/live-tests.md` is the operator's page.

Where a test belongs:

- `test/` mirrors `lib/`: one module per module it exercises, named after it
  (`test_router.ml` ↔ `lib/router.ml`), with the adapter suites beside it.
- `test/support/` holds the stubs — one module per test double, including the
  `mcp-kit` client and transport doubles the session suites drive.
- `test/differential/` is the behaviour baseline: the ten areas' golden files,
  the property tests over the routing and selection rules, and the parity matrix.
  A golden pins what the server does; changing one is a contract change and the
  PR body carries the reason.
- `test/should_not_compile/` pins what must fail to build — the capability
  bypasses and the private-boundary hops, each with its `.expected` message.
- A contract a *model* reads back (a tool description, a refusal sentence a
  caller acts on) goes in the surface pin or the differential golden, not only
  in a unit test.

## Conventions

The whole list is in [`AGENTS.md`](AGENTS.md); the comment rules are
[`.agents/skills/comment-discipline/SKILL.md`](.agents/skills/comment-discipline/SKILL.md)
and the toolchain facts are
[`.agents/skills/ocaml/SKILL.md`](.agents/skills/ocaml/SKILL.md). The ones that
catch people:

- **Every interface is an `.mli`.** A module's surface is what its signature
  says; a helper that has no place in it stays private.
- **Comments state a constraint the code cannot state** — a pin, an ordering, a
  name that has to match another file. No banners, no region labels, no prose
  that restates the statement below it.
- **Nothing cites a line number**, in code, in a comment or in a page: the
  number moves the next time the file is edited and no check notices. Name the
  symbol (`Registry.rows`, `known_fetch_fallbacks`, `validate_logging_on_this_port`)
  or the page and its section.
- **Never let a secret reach a log line.** No exception object is logged: adapters
  sanitise what they raise, and the message that leaves is the one that is safe.
  A log message is a constant dotted event name; values go through the field list,
  so a value reaches a line only by being named.
- **Caller and provider content rides its own event** (`search.result`,
  `search.answer`, `fetch.content`), never extra fields on `search.ok` or
  `fetch.ok` — `max_results` is chosen by the calling model and must not decide
  how long a log line gets.
- **An unhonourable constraint must be reported, not dropped.** An adapter that
  cannot apply a filter the caller passed names it in the result's `notice`;
  silence there is a silently dropped filter.
- **Unset fields must not reach a caller as `null`.** The wire models serialise
  with the absent-field rule; a new wire model inherits it.

## Documentation

Docs live with the reason for a thing, not next to it, and
[`ocaml-docs/`](ocaml-docs/) is the whole tree: `configuration.md` and
A docs change gets the same review as a code change: `test/test_config.ml` loads
`ocaml-docs/reference-config.md`'s TOML example and Secrets block, and the role
tables of `ocaml-docs/deploying.md`, through the real loader — so a page cannot
offer a key or a table the parser refuses. The key counts themselves are frozen:
`ocaml-tools/surface.expected` pins 49 section keys over 6 tables and 12
per-provider keys, and the frozen-vocabulary cases near the end of
`test_config.ml` write the known names out rather than recomputing them, so a
widened set fails there before it reaches a reviewer.
authorised it (`plans/`).

A docs change gets the same review as a code change: `test/test_config.ml` loads
the configuration reference's example through the real loader and pins the
key/section vocabulary of every page against the parser's own tables, so those
pages cannot drift from what the code accepts.

## Adding a provider

The checklist is longer than this section, and the row is the contract: a name
exists once every one of these moves together, and the gate refuses a partial
wiring.

1. Write the inventory entry first — endpoint, request and response shapes,
   billing model, env var, gotchas — in `ocaml-docs/` and the matrix row, so
   review checks the code against the doc rather than the other way round.
2. Add the `Registry.rows` row: the name (`backend` or `backend:flavour`), its
   endpoint shape (`Fixed_uri`, `Url_override`, `Url_required`, `Algolia_index`),
   its credential rule, its cost model and its live status.
3. Write the adapter in `lib/providers/`, with a module comment stating the
   billing model and why this endpoint.
4. Add its row to `test/differential/matrix/providers.tsv`, pointing at the suite
   that pins its parsing and request shape, and write that suite with a sample
   payload copied from the documented response — including the case where an
   error body carries the API key and must not reach the message.
5. Add its live case to `live/cases.ml`, and say on `ocaml-docs/live-tests.md`
   whether it has run.
6. Run `dune runtest`: the surface manifest gains the name, the egress lists gain
   its host, and the frozen-vocabulary cases notice the widened sets. Promote the
   pins the change is supposed to move.

## Licence

[Apache-2.0](LICENSE). By contributing you agree your contribution is licensed
under it — clause 5 of the licence covers contributions submitted for inclusion
unless you explicitly state otherwise.
