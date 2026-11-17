---
name: ocaml
description: Load this skill for any OCaml work on the ocaml-port branch — the verified toolchain, mcp-kit 0.2.0 API, workspace layout, and the gotchas that already cost a build. Read it before writing OCaml here. It is a reference, not a changelog.
---

# OCaml on the ocaml-port branch

Verified toolchain and API facts for this branch. The plans are the authority for
*what* to build; this file records only what a build already proved. Milestone
history (which phase landed, what the suite counted, what the runner scored) lives
in `plans/seekwright-ocaml-port.md` and `plans/capability-gated-mcp-server.md` —
see "How to append" at the end.

One implementation lives here: the dune workspace (`lib/`, `bin/`, `test/`,
`live/`, `ocaml-tools/`, `examples/`). Dune ignores the directories without
`dune` files — `plans/`, `ocaml-docs/`, `deploy/` — which is why a rule that
reads one of them has to name it in `(deps …)`.

## Environment (verified 2026-11-10, Debian 13, vps-01)

- Every new shell: `eval $(opam env --switch=default)`.
- The `default` switch already exists (`ocaml-system.5.3.0`). Do **not** run
  `opam switch create 5.3` — it wants a compiler package, not a version. OCaml
  5.3.0, dune 3.24.2.
- Anything linking zarith (so `tls`, `mcp-caps`) needs GMP on the search path:
  `libgmp-dev` is absent and `sudo` needs a password. Every build shell:

  ```bash
  eval $(opam env --switch=default --set-switch)
  export CPATH=/home/leo/.local/opt/gmp-dev/usr/include:/home/leo/.local/opt/gmp-dev/usr/include/x86_64-linux-gnu
  export LIBRARY_PATH=/home/leo/.local/opt/gmp-dev/usr/lib/x86_64-linux-gnu
  export PKG_CONFIG_PATH=/home/leo/.local/opt/gmp-dev/usr/lib/x86_64-linux-gnu/pkgconfig
  ```

  The variable names are `CPATH`/`LIBRARY_PATH`/`PKG_CONFIG_PATH`, not `GMP_H`/`GMP_L`
  — wrong names pass small builds and fail linking a zarith target. A local
  `~/.local/lib` holding a `libgmp.so` symlink is an alternative `LIBRARY_PATH`
  for linking. CI installs `libgmp-dev` and needs none of this.
- Full setup, the Node 22 install and the CI lane: `plans/infra-setup.md`.

## Installed opam packages

Verified against `opam list` on 2026-11-13 (switch `default`):

`mcp-kit` 0.2.0 (+ `mcp-kit-eio`, `mcp-kit-cohttp-eio`, `mcp-kit-ppx` 0.2.0),
`eio`/`eio_main`/`eio_linux`/`eio_posix` 1.6, `cohttp`/`cohttp-eio`/`http` 6.3.0,
`yojson` 3.0.0, `uri` 4.4.0, `toml` 7.1.0, `alcotest` 1.9.1, `logs` 0.10.0,
`tls`/`tls-eio` 2.1.5, `ca-certs` 1.0.3, `x509` 1.2.0, `mirage-crypto*` 2.4.1,
`zarith` 1.14, `ipaddr` 5.6.2, `qcheck-core`/`qcheck-alcotest` 0.91,
`digestif` 1.4.2, `odoc` 3.2.2, `ocamlfind` 1.9.8, `dune` 3.24.2.

- **`mcp-kit-stdio` is not an opam package.** The stdio adapter is the findlib
  library `mcp-kit.stdio` (module `Mcp_kit_stdio`) inside `mcp-kit` itself.
  Separate transport packages: `mcp-kit-eio`, `mcp-kit-cohttp-eio`, `mcp-kit-ppx`.
- `Eio_main` is its own opam package; `eio` alone does not provide it. `http` is
  its own findlib package (ask for it beside `cohttp-eio` if you touch
  `Http.Header`/`Http.Status`). `unix` ships with the compiler and is never an
  opam dependency.
- `qcheck-*` and `eio_main` are `:with-test` in `dune-project`; `odoc` supplies
  `dune build @doc`.
- Provenance to recheck before an upgrade: the opam entry names Nomadic Labs and
  `gitlab.com/nomadic-labs/ai-harness/ocaml-mcp`, while the pinned archive's tree
  says "Epure Team" / `github.com/epure-team/mcp-kit`. Unexplained. (2026-11-10)
- `opam install ocamlformat` needs `OCAMLPATH=$HOME/.opam/default/lib`. The host
  ships a findlib dir `/usr/lib/x86_64-linux-gnu/ocaml/5.3.0/camlp-streams` holding
  only a `META` and `camlp_streams.cma`, which shadows the switch's `camlp-streams`,
  and `ocamlformat-lib`'s vendored odoc-parser then dies on `Unbound module
  "Stream"`. (2026-11-17)
- An aborted `opam install` can leave the switch short of a package the gate needs:
  one such abort took `odoc` out and `dune build @doc` answered `Program odoc not
  found`. Re-check `@doc` after any opam transaction that fails. (2026-11-17)

## mcp-kit 0.2.0 API (verified against the installed `.mli`, 2026-11-13)

- Server: `Mcp_kit.Server.create ?title ?instructions ?subscriptions ~name
  ~version ()`, then `add_tool`/`add_tools`, `add_resource`/`add_resources`,
  `add_resource_template`/`add_resource_templates`, `add_prompt`/`add_prompts`.
  Every `add_*` is `t -> X -> (t, add_error) result`, so it composes with
  `let s = … in`, not `|>`. `add_error` has exactly four constructors
  (`Duplicate_tool` and three siblings), so a match needs a fallthrough case.
- Tool: `Mcp_kit.Tool.make ?title ?description ?input_schema ?output_schema name
  handler` — `description` and both schemas are **optional** labels. `handler :
  Yojson.Safe.t -> (result, string) Stdlib.result`; input is JSON-Schema
  validated before it runs.
- **Rich content exists in the installed 0.2.0.** `Tool.image_content ~mime_type
  ~data`, `Tool.audio_content`, `Tool.resource_content` build validated
  `content` blocks; `Tool.image`/`audio`/`resource` return a one-block `result`;
  `Tool.make_with_progress` and `Tool.make_interactive` exist too. The earlier
  skill's "`Tool.Output` has no rich content" claim is **wrong** — what is
  missing on this port is the mcp-caps `Tool.Output` adapter, not mcp-kit
  (`plans/ocaml-finalisation.md` §1).
- Results: `Ok (Tool.text …)` succeeds, `Ok (Tool.error_text …)` is a tool
  failure (`isError: true`), and the handler's `Error` channel is for
  JSON-RPC-level problems. A result that does not match the advertised
  `output_schema` arrives as a JSON-RPC error, not a tool error.
- `Schema.t = Yojson.Safe.t`; `Schema.object_ ?description ?properties ?required
  ?additional_properties ()`; `Schema.empty_object` is
  `{"type":"object","properties":{}}`. `Schema.check_input_schema` only rejects a
  schema *document* that is not a JSON object — `{"type":"string"}` passes it
  (probed 2026-11-13). `Schema.require_input_object` is the root-object check and
  it **raises** `Invalid_argument`; catch it to return a value.
- Transports: `Mcp_kit_stdio.run_channels server stdin stdout` (line-delimited,
  builds its own session, stops at EOF); `Mcp_kit_eio.run_flow server ~input
  ~output`; `Mcp_kit_cohttp_eio.handler ?allowed_origins ?max_body_size ?clock
  server` returns a `Cohttp_eio.Server.t` to pass to `Cohttp_eio.Server.run`.
  Handler arguments are **optional** (default: no allowed origins, 1 MiB body);
  it raises `Invalid_argument` at construction for `max_body_size < 1` or
  `= max_int`, or for an HTTP-subscription server without `~clock`.
- `Server.t` is an immutable record (`info`, the tool/resource/template/prompt
  lists, subscriptions and hub). Copies are cheap and share the hub; only
  `create` allocates one. Sessions are per connection **only where something
  builds one** — `run_channels` does, the Cohttp-Eio adapter does not.
- `Mcp_caps.Server.of_registry ~name ~version` is **this repo's** wrapper, not
  mcp-kit's: it folds `add_tool`, validates each schema and refuses a name
  outside 1–128 bytes of `[A-Za-z0-9-_.:]` (which covers `backend:flavour`).

## Workspace layout (plans/project-structure.md)

- Root dune workspace, packages `mcp-caps` and `seekwright`. Generated `*.opam`
  files are committed, never hand-edited.
- Library direction is fixed: `mcp-caps → seekwright →
  seekwright.providers`/`seekwright.fetch`. `lib/fetch/extractors/` is its own
  stanza (`seekwright.fetch.stdlib`). A factory that builds adapters cannot live
  in `lib/`; it would close the cycle.
- `lib/caps/` holds `Mcp_caps`; `lib/providers/`, `lib/fetch/` mirror it.
  `bin/main.ml` is the executable, `test/` mirrors `lib/`, `ocaml-tools/` holds
  tree-reading instruments, `test/differential/` and `test/conformance/` are
  their own suites, `examples/` the demo servers.
- Every module gets an `.mli`. An abstract type with no constructors is how
  `lib/caps/authority.mli` keeps grants unforgeable — do not expose constructors.
- `lib/caps/dune` keeps `policy_fs` and `controls_raw` in `private_modules`, and
  `controls_raw.ml` has no interface: the raw-bounds record has no name outside
  the library. Preserve that boundary. (2026-11-13)

## Conventions

- Plans are living documents: when code settles differently, update the plan in
  the same commit.
- Commits: one lowercase line, area first (`plans: …`, `caps: …`, `skills: …`).
- Gate before reporting done: `eval $(opam env --switch=default) && dune build
  @install && dune runtest --force && dune build @doc`.
- Formatting is pinned by `.ocamlformat` (ocamlformat 0.29.0, `margin = 100`,
  spacing options that preserve the tree's blank lines): run
  `ocamlformat --inplace` over the files you touched. No gate target runs it.
- The twenty-point review checklist and its examples live in
  `plans/reviews/2026-11-12-style-review.md` §3; the correctness findings in
  `plans/reviews/2026-11-12-quality-review.md`. Use those, not a copy here.

## Verified gotchas

Each entry cost a build; one or two lines, dated. Group by the tool that bit.

### Dune and dune-project

- **Dune derives the wrapped module from `(name)`, not `(public_name)`**:
  `(name caps) (public_name mcp-caps)` gives `Caps`; `Mcp_caps` needs `(name
  mcp_caps)`. (2026-11-10)
- With one `(package)` stanza its name must equal the project `(name)`; two
  stanzas turn that check off, and an unattached placeholder package needs
  `(allow_empty)`. (2026-11-10)
- Don't write `(dune (>= 3.11))` in `(depends)` — dune already adds it from
  `(lang dune 3.11)` and the result is a duplicated constraint. (2026-11-10)
- A `(depends)` entry takes a version constraint **or** a flag such as
  `:with-test`, never both: `(eio_main (>= 1.6) :with-test)` is
  "Atom or quoted string expected". (2026-11-10)
- **`(include_subdirs …)` is not a library field on dune 3.24** ("Unknown
  field"), and `(include_subdirs qualified)` is rejected beside a sibling
  directory with its own stanza. A subdirectory needs its own
  `(library (name …) (public_name …))` stanza. (2026-11-12)
- A library whose `public_name` extends a package's name attaches to that
  package automatically; `dune build @install` then regenerates the `.opam` in
  the source tree. Commit the diff, never hand-edit. (2026-11-13)
- `(deps (glob_files ../lib/caps/*.ml))` is one atom, not a list, and puts those
  sources in the test's sandbox. A rule's cwd is `_build/default/<dir>`, so it
  reads them as `../lib/caps/…`. (2026-11-10)
- **A test's cwd is `_build/default/<dir>`, not the source directory.** Suites
  that read repo files need them in `(deps …)` and the `../` path; running the
  built exe from the repo root fails exactly those cases. (2026-11-11)
- Source-reading guards (`Sys.readdir "../lib/providers"`) work only under
  `dune runtest`; under `dune exec` the sandbox is absent and they raise
  `Sys_error`. `dune exec` also re-roots CWD at the workspace root, so
  `corpus/`/`golden/` reads fail. Run from `_build/default/test/…` instead.
  (2026-11-11, 2026-11-13)
- **`test/router_dependencies.expected` is a mechanical re-pin.** A module added
  under `lib/` adds ocamldep lines: `dune runtest test` then `dune promote test`.
  `ocamldep` in `test/dune` needs `-I ../lib` or every cross-module line is
  empty and the pin is vacuous. It can be stale on the branch base — check
  `git show HEAD:test/router_dependencies.expected` before blaming your change.
  (2026-11-11, 2026-11-12)
- `dune promote` promotes only what a **runtest** diff flagged (a bare
  `dune build <target>` says "Nothing to promote"), one mismatched file per run,
  and the result lands read-only. A stale `_build` can report "File ….expected
  should be deleted": `rm -rf _build` and re-run. (2026-11-10, 2026-11-11)
- `(var …)` needs a newer `(lang dune)` than 3.11; repeat the dependency list.
  (2026-11-10)
- Negative-compilation pin, condensed: there is no `expect_test` stanza and
  `(test (name X))` insists the module exists, so use a `(rule …
  (with-accepted-exit-codes (not (or 0)) (with-outputs-to X.out (run sh -c
  "set -o pipefail; ocamlfind ocamlc … 2>&1 | sed -n '/^findlib:/d;p'"))))` plus
  a runtest diff rule. Use `sed -n '/^findlib:/d;p'`, not `grep -v`: grep exits 1
  when it filters every line, which reads as a compiler failure. `ocamlc -c
  dir/x.mli` writes the `.cmi` **next to the input**, so copy interfaces into the
  rule's directory first, in dependency order (arguments compile left to right).
  (2026-11-10)
- A `should_not_compile` `.expected` quotes the snippet's own source line, so
  reformatting a snippet re-pins its diagnostic: the 2026-11-17 formatting sweep
  moved five of the fourteen and left the tree red on them. `dune runtest
  --force` is what exposes that — a plain run reuses a cached `.out` for a rule
  whose inputs dune considers unchanged, so three of the five stayed hidden until
  a library change invalidated them. (2026-11-17)
- In a transcript rule, `with-outputs-to` merges stdout and stderr; a stdio
  fixture's startup notes then land in the protocol. Split with
  `with-stdout-to` + `with-stderr-to` and pin both. (2026-11-11)

### Warning-as-error traps (the dev profile)

- Unused variables, unused values missing from the `.mli`, and unused operator
  bindings fail the build. Warning 32/69 (`unused-field`) kills a fixture helper
  or a `mutable` field no case assigns: move fixture state to `ref` fields
  (`calls`, `kwargs`) and delete helpers kept "for symmetry". (2026-11-10,
  2026-11-11)
- Warning 37: a GADT branch nothing constructs is an error. Omit the branch —
  with no constructor at all, no such grant can exist, which is stronger than a
  stub. (2026-11-10)
- Warning 39: `let rec` whose only recursion is in an inner loop. Drop the outer
  `rec`. (2026-11-11)
- Warning 21: a `failwith`/`exit 1` arm followed by `;` and more statements.
  End the branch with it as the last expression, or put the shared check first.
  (2026-11-11, 2026-11-12)
- Warning 50: a `(** … *)` that follows an item is ambiguous. Put the doc
  **before** the `val`/item, with a blank line. (2026-11-12)

### OCaml 5.3 stdlib

- No `Result.Syntax`. The tree's convention is one spelling: `let ( let* ) = Result.bind`
  at module level for result chains, nested `match` where each level maps to a
  different status. No `>>=`.
- A literal `(*` inside a comment body opens a nested comment; prose that mentions
  it (e.g. naming the `let*` binding) silently swallows text until a matching `*)`.
- Missing and often missed: `String.rsplit2`, `String.drop`,
  `String.split_on_str`, `String.prefix`, `String.is_suffix`,
  `String.contains_substring`, `String.index_opt ~sub`, `List.last`,
  `Option.value_exn`, `Int64.sign`, `Atomic.incr`, `Atomic.modify` (5.5),
  `Sys.putenv`, `unsetenv`. Existing: `String.starts_with`/`ends_with`,
  `String.index_from_opt`, `List.filter_map`, `Option.get`. (2026-11-10 →
  2026-11-12)
- An `Atomic` max tracker is `Atomic.fetch_and_add` plus a compare-and-set loop;
  `Atomic.set` takes the atomic first. (2026-11-10, 2026-11-13)
- There is no `unsetenv`; `Unix.putenv name ""` is the workaround, sound here
  only because config reads `""` as absent (as Python's `os.environ.get(...) or
  None` does). A test wanting "unset" sets `EIO_BACKEND=""`. (2026-11-11)
- `Float.class` is a **syntax error** (`class` is a keyword). Compare with
  `Float.is_nan` and `Float.equal v Float.infinity`. (2026-11-11)
- `!s.field` parses as `(!s).field`; write `!(s.kwargs)` for a ref field.
  `incr s.calls` is fine. (2026-11-11)
- `match … | _ -> ();` inside a sequence puts everything after the `;` in the
  last arm — `|` binds looser than `;`. Parenthesise a `match` used as a
  statement. (2026-11-11)
- A dangling `else` after an `if` that carries a comment binds to the inner
  `if`; wrap each arm in `begin … end`. (2026-11-12)
- `raise Exit` inside a helper needs its own `try … with Exit`; it does not stop
  at the `let` that calls the helper. (2026-11-12)
- A local type named `result` shadows `Stdlib.result`; spell
  `(x, string) Stdlib.result` in the `.mli`. `Result.bind` still resolves.
  (2026-11-11)
- Optional-argument traps, all of them: `?x` whose declared type is an option
  arrives wrapped again (`bool option option`) — port `bool | None` as a
  **mandatory** labelled `bool option` instead; `?x` without a default takes the
  bare value, so a field typed `image option` is passed `~image:{…}` and a field
  typed `string option` takes `~title:None`; forwarding writes `?notice`, not
  `~notice`; a trailing `()` after optional args is consumed by the definition,
  so call sites write `f ~a:x ()`, never `f ~a:x () ()`. (2026-11-11, 2026-11-12)
- A hand-rolled substring scan with `if i + m > n then true` flips every
  negative assertion; the past-the-end base case is `false`. (2026-11-12)
- Opening a module can steal binder names: under `open Logs`, `fun level event
  fields -> …` binds `fields` to `Logs.String.fields`. Alias (`module LS =
  Logs.String`). (2026-11-11)
- Don't `open Alcotest` in a suite that reads `Yojson` loosely: local
  `int`/`bool`/`str` readers shadow its testables. Use `let check_string =
  A.(check string)` and `A.failf`. (2026-11-11)
- `Alcotest.fail` takes `~here`/`~pos`, so `Format.kasprintf Alcotest.fail fmt`
  does not typecheck; wrap it as `Format.kasprintf (fun m -> Alcotest.fail m)`.
  `Alcotest.float` takes the absolute error positionally (`A.float 1e-9`, no
  `~abs_tol`). (2026-11-10, 2026-11-11)
- alcotest 1.9.1 idioms: `Alcotest.testable fmt equal` takes two arguments (no
  name label); cases are ``Alcotest.test_case "label" `Quick fn``; suites are
  `(string * unit test list)`, so concat built suites with `@ [ … ]`; there is no
  `Alcotest.run ~exn_exit_code`; re-run one suite as
  `./_build/default/test/x.exe test "<suite>"`. (2026-11-11)
- Record-field ambiguity (`Model.result` and `Model.fetch_response` both carry
  `text`/`url`, `Policy_net` declares `body`/`headers` on request and response):
  annotate the binding — `((r : Model.result), _)`,
  `let body_of (request : Caps.Authority.Net.request) = …`. (2026-11-11)

### JSON (yojson 3.0.0)

- `Yojson.Safe.t` is `Null | Bool | Int | Intlit | Float | String | Assoc |
  List` — **`Intlit`, not `Tuple`/`Variant`**. Treat `Intlit` as an integer.
  (2026-11-11)
- `Yojson.Safe.from_string` accepts bare scalars and arrays (`[]`, `null`, `42`,
  `"x"`), so a "decodes to an object" guard is load-bearing; it **raises**
  `Yojson.Json_error` on empty/truncated input, so decode is `try … with` into
  the caller's error row. (2026-11-11)
- A decoder inferred without an argument annotation narrows to
  ``[< … > `Assoc ]`` in the generated signature and stops matching
  `Yojson.Safe.t -> …`. Annotate the argument `(json : Yojson.Safe.t)` and all
  shared helpers. (2026-11-11)
- pydantic's default-vs-null rule needs two decoders: a field declared `int = 5`
  treats absent as the default and explicit `null` as an error; only `Optional`
  maps `null` to `None`. One shared `opt_*` helper silently accepts bodies
  pydantic refuses. (2026-11-11)
- Python's `len`/`s[:n]` are codepoint-indexed: length caps, clipping and
  citation slices count codepoints, not bytes. A byte guard passes a fixture
  whose byte *and* character counts both exceed the cap and still slices at the
  wrong place when only bytes exceed it — pin the straddling rows.
  (2026-11-11)

### TOML (toml 7.1.0)

- `Toml.Parser.from_string : string -> (Toml.Types.value, string) result`;
  constructors are `TBool | TInt | TFloat | TString | TDate | TArray | TTable`.
- **`Table.Key.to_string` re-quotes a non-bare key**: `[providers."exa:free"]`
  comes back as `"exa:free"` *with* quotes, and nothing is escaped inside them.
  Strip exactly one matched pair (`Config.key_name`); reading it verbatim turns
  every flavoured provider into an unknown-provider error. (2026-11-11)
- The `toml` array is typed where `tomllib`'s is not: `["serper", 3]` is a parse
  error here, a `string_type` error in Python. Two more accepted divergences: a
  TOML integer above `int64` and a decimal string above `int63`. All three are
  named in `test_config.ml`'s header. (2026-11-11)
- pydantic's lax scalar coercion was measured, not guessed: `int` accepts
  `" 400 "`, `"+7"`, `"1_000"`, `"500.0"` but not `"1."`, `"1e2"`, `"0x10"`;
  `bool` accepts the twelve spellings `true/t/yes/y/on/1` and
  `false/f/no/n/off/0` case-insensitively with **no trimming**; TOML numbers 0/1
  coerce too. Typing scalars straight into fields refuses an operator's
  `max_chars = "400"`. (2026-11-11)

### Eio 1.6

- `EIO_BACKEND=linux|io-uring|posix` picks the loop; unset or `""` means "linux,
  else posix". An unknown value raises. (2026-11-10)
- Under `Eio.Path.open_subtree`, a `..`, an absolute component, and a symlink
  (file or directory) pointing out of the root all raise
  `Eio.Io (Fs.E (Fs.Permission_denied …))`; a symlink that stays inside reads
  fine. `Eio.Path.kind ~follow:true` reports a missing path — including a
  dangling symlink — as the `Not_found` **value**, not an exception.
  (2026-11-10)
- `Buf_read.of_flow flow ~max_size:(limit + 1)` + `take_all` raises
  `Eio.Buf_read.Buffer_limit_exceeded` and never allocates past the limit;
  `Eio.Path.load` allocates the whole file. `take` returns `string`, not bytes;
  there is no `Impossible`; short reads raise `End_of_file`. (2026-11-10,
  2026-11-13)
- `Eio.Path.with_dir_entries` hands a `Seq` (an entry ceiling bounds allocation);
  `Eio.Path.read_dir` builds the whole list. (2026-11-10)
- Write with `Eio.Buf_write.with_flow`; `Eio.Flow.write` is cstruct-based and
  won't take a `string` list. (2026-11-13)
- Cancellation is control flow: re-raise `Eio.Cancel.Cancelled` and
  `Eio.Exn.Multiple` at any boundary mapping `Eio.Io` to a domain error.
  (2026-11-10)
- `Eio.Time.Timeout.run` widens the error row with `` `Timeout `` and cannot
  unify with an abstract channel; use `Timeout.run_exn` and classify the
  exception. `Cancel.Cancelled` is a different exception and keeps propagating.
  (2026-11-10)
- `Eio.Promise.create ()` returns `(t, u)`, not `(u, t)`: `Server.run ~stop`
  wants the `t`, `resolve` the `u`, `await` the `t`. (2026-11-10)
- **`Eio.Semaphore.acquire` leaks a permit when a parked fiber is cancelled.**
  A pool that cancels queue-waiters shrinks its own budget and dead-locks the
  next case. Safe shape: `Eio.Cancel.protect (fun () -> acquire permits)`, then
  `Eio.Fiber.check ()` **inside** the `Fun.protect` that releases it (before it,
  the check leaks the just-taken permit), timeout only around the work.
  (2026-11-13)
- Eio flow types are parameterised by the backend's resource tag and a record
  cannot carry an existential (`_` is rejected in a declaration). Parameterise
  the record and hide the tags behind a single-constructor GADT
  (`type t = T : ('tag, 'clock) pool -> t`), as `policy_net.ml` does. Wildcards
  are fine in `val`, not in a record declaration. (2026-11-13)
- `Eio.Io` has arity 2 (`err * context`); `Eio.Net.connect` takes `~sw`.
  (2026-11-13)
- A scripted `Eio.Net.t` is `Eio.Net.Pi.network (module M)` with
  **``type tag = [ `Generic ]``**; `type tag = unit` fails the real API's row
  constraint. A `connect` that raises proves "refused, so no I/O". (2026-11-10)
- `Eio.Net.getaddrinfo_stream` never returns `[]`; an unknown name raises
  `Address_lookup_failed`. Answers are `Ipaddr.v4v6`; round-trip through
  `Ipaddr` with `Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets ip)` and back.
  (2026-11-10)
- `Eio.Stdenv.t` is not a named type: spell env parameters as open object types
  (`net : [> [> `Generic ] Eio.Net.ty] Eio.Resource.t; fs : Eio.Fs.dir_ty
  Eio.Path.t; mono_clock : [> Eio.Time.Mono.ty] Eio.Resource.t; ..`).
  `Mono.now` returns `Mtime.t`: `Int64.to_float (Mtime.to_uint64_ns m) /. 1e9`.
  Accepted sockets need `(sock :> Eio.Flow.two_way_ty Eio.Resource.t)`.
  (2026-11-12)
- `Domain.spawn` needs `unit -> 'a`: wrap a labelled partial application that
  already returns `unit` as `(fun () -> worker …)`. Main-domain exit terminates
  the process even with live domains, so an un-joined pool cannot keep a dying
  test alive. (2026-11-13)
- **`Unix.file_descr`s are process-wide under `Domain.spawn`.** An fd handed to
  a spawned domain must be closed exactly once in total; a second close lands on
  whatever another domain has reused and kills its socket (observed as an accept
  loop missing its quit sentinel and a hung `Domain.join`). For a readiness
  handshake, the worker closes the write-end and always writes a byte before it
  can die; the parent closes only the read-end. (2026-11-13)
- A bound AF_UNIX socket answers `connect` only after `Unix.listen` (bind alone
  leaves connects refused and `accept` a hot-spinning `EINVAL`). Paths are
  limited to 107 chars; `bind`'s mode comes from the umask, so `chmod 0o600`.
  (2026-11-13)

### HTTP (cohttp-eio 6.3.0)

- ``Eio.Net.listen ~backlog:128 ~sw env#net (`Tcp (…, 0))`` — `~backlog` is
  **mandatory** — then `Eio.Net.listening_addr` reads the port back.
  (2026-11-10)
- `Cohttp_eio.Server.run ~stop ~on_error socket handler` returns only once
  `~stop` is filled, and filling it waits for open connections; `Eio.Switch.run`
  waits for every fiber. A forked listener must be stopped before the switch
  body returns, or the suite hangs instead of failing. (2026-11-10)
- `Cohttp_eio.Server.make ~callback ()` with
  `callback : conn -> Http.Request.t -> Body.t -> response IO.t`,
  `conn = Eio.Switch.t * Eio.Net.Sockaddr.stream`. `callback` is public, so an
  application that accepts with `Eio.Net.run_server` itself can route each
  connection to a different server value (one socket, two servers, two grants).
  `handler` closes over one `Server.t` and discards `_conn`, so mcp-kit alone
  cannot vary a server per client. (2026-11-10)
- `Http.Request.t` carries `resource` (path **and** query), no assembled URI — a
  `Location` must be built from `Host`. `Http.Method.to_string` takes the
  concrete `Http.Method.t`. (2026-11-10)
- Client: `Cohttp_eio.Client.make ~https:None env#net` — `~https` is **required**
  (an option), not optional. `Client.make_generic : (sw:Switch.t -> Uri.t -> …)
  -> t` hands the URI to *your* connector, so a connector returning an already
  vetted socket is the whole DNS-rebinding fix; `set_proxies` only feeds `make`.
  Bodies are `Body.t`; read them back with
  `Eio.Buf_read.(take_all (of_flow …))`, and use `Http.Status.to_int`. The
  connector return type is written
  `[ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t` in a type
  declaration — `Eio.two_way` cannot be applied to a row there.
  (2026-11-10)
- cohttp-eio reads response **headers** at `Buf_read.of_flow ~max_size:max_int`:
  the body ceiling is ours, the header block is only timeout-bounded.
  (2026-11-10)
- `Uri.resolve : string -> t -> t -> t` is `resolve scheme base rel`. Uri 4.4
  has no `Uri.Query` module: build with `Uri.with_query u [("q", ["x"])]`
  (values are `string list`), read with `Uri.query`/`Uri.get_query_param`.
  (2026-11-11/12)
- `Uri.host` strips the brackets from an IPv6 literal
  (`http://[64:ff9b::1]/` → `64:ff9b::1`). (2026-11-11)

### TLS and addresses

- `Ca_certs.authenticator ()` and `Tls.Config.client ~authenticator ()` return
  results; ``Tls_eio.client_of_flow config ~host:(`host name) flow`` (or `~ip`).
  Never `accept_any`; build the config once at grant construction so a missing
  trust store is a startup failure. (2026-11-10)
- **The RNG is process-global and the application must install it**
  (`Mirage_crypto_rng_unix.use_default ()` from the `mirage-crypto-rng.unix`
  findlib library). TLS throws `No_default_generator` at *handshake*, not at
  `Tls.Config.client`, so a startup check must call
  `Mirage_crypto_rng.default_generator ()`; `try Ok () with
  No_default_generator` is dead code that looks like a guard. `bin/main.ml` calls
  `use_default` before flag parsing. (2026-11-10, 2026-11-12)
- `mirage-crypto-rng.unix` pulls stdlib `unix`, so it belongs in example and
  test stanzas, never in `mcp-caps` (`test/test_core_no_mcp_kit.ml` guards it).
  (2026-11-10)
- **`Ipaddr.is_global` is not the public-web policy**: it calls `fc00::/7`,
  `128.0.0.0/16`, all of `0.0.0.0/8` and the TEST-NET blocks global.
  `Policy_net.special_use` is the RFC 6890 table that closes those gaps.
  (2026-11-10)
- `is_global` (ipaddr 5.6.2) still returns **true** for NAT64 and
  IPv4-translated literals (`64:ff9b::a9fe:a9fe`, `64:ff9b:1::…`,
  `::ffff:0:7f00:1`), whose low 32 bits name a private IPv4 destination;
  `special_use` carries `64:ff9b::/96`, `64:ff9b:1::/48` and `::ffff:0:0:0/96`.
  IPv4-*mapped* (`::ffff:a.b.c.d`) is already scoped from the embedded v4 and
  needs no row; the *translated* prefix does. Mapped is
  `00*10 ff ff`, translated is `00*8 ff ff 00 00` — one group apart.
  (2026-11-11)
- A prefix test over `Ipaddr.to_octets` needs the mask on the **high** bits of
  the partial octet: `(0xff lsl (8 - rest)) land 0xff`. `lsr` silently allows
  half the range (`fd12:3456::1` through `fc00::/7`), so keep one row per
  boundary. (2026-11-10)

### mcp-kit wire behaviour — do not re-implement

- Body bound: `max_body_size` → 413 with an empty body; the oversized body is
  never parsed. (2026-11-10)
- A request is "modern" if it carries `MCP-Protocol-Version`, calls
  `server/discover`, or has an `io.modelcontextprotocol/*` key in `params._meta`.
  Modern requests need `Content-Type: application/json` and an `Accept` naming
  both `application/json` and `text/event-stream`, plus protocol-version,
  `Mcp-Method` and `Mcp-Name` headers matching the body. A mismatch is 400 with
  JSON-RPC -32020; a missing protocol block is -32602; a *tool* refusal stays a
  200. An `x-mcp-header` property must also arrive as `Mcp-Param-<name>`.
  (2026-11-10)
- `GET`, `DELETE` and every other method are 405. A disallowed `Origin` gets 403
  and then `Rejected_origin` reaches `on_error` after flushing; expect it, don't
  log it as a fault. No `Origin` at all is ordinary non-browser traffic.
  (2026-11-10)
- HTTP dispatch is stateless (`dispatch_string`, `dispatch_http_json_frames`),
  never `create_session`. `Server.session` is `{ server; mutable phase }`,
  unsynchronised — never share one. So the legacy initialize gate exists only
  over stdio; over HTTP `tools/list` before `initialize` is answered.
  (2026-11-10)
- Framing: a legacy notification is no line on stdio and an empty 204 over HTTP;
  a modern request with no frames is 202. (2026-11-10)
- mcp-kit 0.2.0 answers `prompts/list` and `resources/list` with empty arrays but
  does not add `prompts`/`resources` to the `server/discover` capabilities, so a
  server declaring neither is internally inconsistent on the wire
  (`sep-2575-server-declares-prompts-in-discover`). Not fixable in `lib/`.
  (2026-11-13)

### Conformance runner

- The scenarios are **not in the opam package**. Clone the tag the switch
  installs: `git clone --branch v0.2.0
  https://gitlab.com/nomadic-labs/ai-harness/ocaml-mcp`. The scored fixture
  (`test/conformance/server.ml`), the 37 frozen IDs
  (`requirements-2026-07-28-server.txt`), the comparator and the pinned
  `@modelcontextprotocol/conformance@0.2.0-alpha.11` are there. (2026-11-11)
- `conformance server` takes `--url` and nothing else — **no stdio mode**; a
  stdio claim must be in-tree. Node >= 22: the system Node 20 dies at import
  with `fs does not provide an export named 'globSync'`, which reads like a
  broken install. Node 22.23.4 lives under `~/.local/opt/node22`.
  (2026-11-11)
- `--requirements 2026-07-28` runs 50 scenarios: 37 scored plus 13 unscored. A
  pass requires no `FAILURE` or `WARNING` in its `checks.json`. (2026-11-11)
- The comparator demands `run-date-utc.txt`, `server-commit.txt`,
  `runner-version.txt`, `node-version.txt`, `npm-version.txt`,
  `required-command.txt` and `working-tree-status.txt` in the output directory,
  or every scenario is *inconclusive*. (2026-11-11)
- **Declaration names are the runner's contract** (`test_simple_text`,
  `json_schema_2020_12_tool`, `test://static-text`, …): a scenario that cannot
  find its declaration reports `unknown tool:`/`unknown prompt:` even when the
  behaviour is fine. An ordinary three-tool server therefore scores **8/37**
  without doing anything; the port's scores live in
  `plans/seekwright-ocaml-port.md` §7 and §16. (2026-11-11, 2026-11-13)
- `compare_results.py`'s `exact()` treats a repeated ID as a duplicate even when
  both sides repeat it; runner check IDs repeat, so compare Counters.
  (2026-11-13)

### Tests, shell and git

- A source-text needle must not quote a line break or a paren: `ocamlformat`
  wraps long calls and docks the closing `)` with a space. `Test_support`'s
  `source_includes`/`source_excludes`/`source_count_occurrences` match with
  whitespace collapsed; a needle that ends in `)` still fails. (2026-11-17)
- `test_usage.exe` writes a cwd-relative `usage-journal/` that is not in
  `.gitignore`; delete it before committing. (2026-11-11)
- `pkill -f <pattern>` matches the `bash -c` line carrying the pattern and kills
  your own shell (exit 143, no output). Kill by PID, or match
  `/proc/<pid>/exe`. (2026-11-11)
- `git rebase --continue` still opens an editor for an unchanged message; a
  non-tty run dies. Use `GIT_EDITOR=true git rebase --continue`. (2026-11-11)
- Deterministic QCheck: `QCheck_alcotest.to_alcotest ~rand:(Random.State.make
  [|seed; salt|])` with explicit `~count` and `~long:false` bypasses
  `QCHECK_SEED`/`QCHECK_COUNT`/`QCHECK_LONG`; without `~rand` the gate depends on
  the developer's shell. (2026-11-13)

## How to append

- One dated line (or two) per newly verified fact, in the matching subsection.
  State the constraint, not the story.
- If a fact is **milestone-sized** — a phase landed, a suite count moved, a
  conformance number changed — it goes where that phase is owned:
  `plans/seekwright-ocaml-port.md` §4 (P1–P8) or §9–§22 (F-phases);
  `plans/capability-gated-mcp-server.md` §5–§9 for the caps layer. This file
  gets at most a pointer.
- If a line no longer changes a decision, delete it. A reference that only grows
  stops being read.
