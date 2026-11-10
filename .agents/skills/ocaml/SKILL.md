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
Added for M1: `eio_main` 1.6 (see the M1 section; test and example only).

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
- `Server.t` is an immutable record (`info`, four registration lists, the
  subscription support and hub): safe to share across concurrent clients, cheap
  to copy. `add_*` returns a copy that shares the hub; only `create` allocates
  one. Sessions are per connection **only where something builds one** — stdio's
  `run_channels` does, the Cohttp-Eio adapter does not (M2 section below).
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

## Verified building M1 (2026-11-10)

- `Eio_main` is its **own** opam package (`eio_main` 1.6, which brings
  `eio_linux`, `eio_posix`, `iomux`, `uring`); `eio` alone does not provide it.
  `EIO_BACKEND=linux|io-uring|posix` picks the loop, and unset or `""` means
  "linux, else posix". OCaml 5.3.0 has `Unix.putenv` but **no** `Sys.putenv` and
  no `unsetenv` anywhere, so a test that wants "unset" puts `""`.
- Confined-path behaviour, same on both runners: under an
  `Eio.Path.open_subtree` handle, a `..` component, an absolute component, a
  symlink pointing out of the root, and a symlinked directory out of the root all
  raise `Eio.Io (Fs.E (Fs.Permission_denied …))` (on the linux runner that is
  `openat2` RESOLVE_BENEATH). A symlink that stays inside resolves normally and
  reads fine. `Eio.Path.kind ~follow:true` reports a missing path — including a
  dangling symlink — as the `Not_found` **value**, not an exception; a read of a
  directory raises a plain `Eio.Io` from the flow layer.
- Bounded reads: `Eio.Buf_read.of_flow flow ~max_size:(limit + 1)` with
  `Buf_read.take_all` raises `Eio.Buf_read.Buffer_limit_exceeded` and never
  allocates past the limit; `Eio.Path.load` allocates the whole file.
  `Eio.Path.with_dir_entries` hands a `Seq`, so an entry ceiling bounds what is
  allocated, not only what is reported; `Eio.Path.read_dir` builds the whole list.
- Cancellation is control flow, not a failure: re-raise `Eio.Cancel.Cancelled`
  and `Eio.Exn.Multiple` at any boundary that otherwise maps `Eio.Io` onto a
  domain error type.
- The loop contract in one line: a grant's subtree handle belongs to the loop
  that opened it, so the transport runs inside `Eio_main.run` under the same
  `Eio.Switch.t` — `examples/read_source.ml`. `Mcp_kit_stdio.run_channels` reads
  OCaml channels synchronously, so it parks that loop; fine for one stdio client.
- `authority.mli` cannot name the confinement witness if that record lives in
  `policy.mli`, because `policy.mli` names `Authority.Net.t`: dune reports
  "dependency cycle between … `Policy.intf` / `Authority.intf`". Put the record in
  its own module (`policy_fs.ml`) with an abstract `t` and let
  `Authority.Fs.of_confinement` take it.
- A GADT branch nothing constructs is warning 37, which the dev profile turns
  into an error. Omit the branch: with no `Net` constructor at all, no `Net`
  grant exists anywhere — a stronger statement than a stub constructor.
- Negative compilation on dune 3.24 at `(lang dune 3.11)`: there is no
  `expect_test` stanza and `(test (name X))` insists that module `X` exists, so
  use a `(rule … (with-accepted-exit-codes (not (or 0)) (with-outputs-to X.out
  (run sh -c "set -o pipefail; ocamlfind ocamlc … 2>&1 | sed -n
  '/^findlib:/d;p'"))))` plus `(rule (alias runtest) (action (diff X.expected
  X.out)))`, and `dune promote` (it promotes one mismatched file per run).
  `grep -v` is the wrong filter there: it exits 1 when it filtered every line,
  which reads as a compiler failure on a clean run. `ocamlc -c dir/x.mli` writes
  the `.cmi` **next to the input**, so copy the interfaces into the rule's own
  directory first, and note `ocamlc` compiles its file arguments left to right —
  the interface list must be in dependency order. `(var …)` needs a newer
  `(lang dune)` than 3.11, so a repeated dep list is the only option here.
- In a `dune-project` `(package (depends …))` entry at `(lang dune 3.11)`, a
  dependency takes a version constraint **or** a flag like `:with-test`, not both:
  `(eio_main (>= 1.6) :with-test)`, `(eio_main (:with-test (>= 1.6)))` and the
  other orderings all fail with "Atom or quoted string expected".
- Seen once: after `dune promote`, a stale `_build` made the diff rule fail with
  "File ….expected should be deleted". `rm -rf _build` and re-run before chasing it.

## Verified building M2 (2026-11-10)

Serving plain HTTP on loopback needs nothing new installed: `mcp-kit-cohttp-eio`
0.2.0, `cohttp-eio`/`http` 6.3.0 and `uri` were already in the switch, and
`tls-eio`/`ca-certs` are only for **outbound** HTTPS (M3). `http` is its own
findlib package, so a stanza that touches `Http.Header` / `Http.Status` asks for
`http` by name next to `cohttp-eio`.

Wiring, from `examples/read_source.ml`:

- `Mcp_kit_cohttp_eio.handler ~max_body_size ~allowed_origins ?clock server`
  returns a `Cohttp_eio.Server.t`; run it with
  `Cohttp_eio.Server.run ~stop ~on_error socket handler`. `handler` raises
  `Invalid_argument` at construction if `max_body_size < 1` or `= max_int`, or if
  the server has HTTP subscriptions enabled and no `~clock` was given.
- Ephemeral loopback: `Eio.Net.listen ~backlog:128 ~sw env#net
  (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))`, then `Eio.Net.listening_addr socket`
  to read the port back. `~backlog` is a **mandatory** labelled argument.
- `Cohttp_eio.Server.run` returns only once its `~stop` promise is filled, and
  filling it waits for open connections to finish; `Eio.Switch.run` waits for
  every fiber registered on it. A test that forks a listener must stop it with
  that promise before its switch body returns, or the suite hangs instead of
  failing.
- Client: `Cohttp_eio.Client.make ~https:None env#net` — `~https` is a required
  labelled argument, not an optional one. One socket per call, closed with the
  switch handed to the call. Request and response bodies are `Cohttp_eio.Body.t`
  = `Eio.Flow.source_ty Eio.Resource.t`: `Body.of_string` out,
  `Eio.Buf_read.(take_all (of_flow …))` back in; `Http.Status.to_int` for the code.

What the adapter owns — verified through it in `test/test_http_transport.ml`, so
do not re-implement any of it:

- Body bound: `Buf_read.of_flow ~max_size:(max_body_size + 1)` plus a length
  check → 413 with an empty body, and the oversized body is never parsed.
- A request is "modern" if it carries `MCP-Protocol-Version`, or calls
  `server/discover`, or has an `io.modelcontextprotocol/*` key in `params._meta`.
  Modern requests need `Content-Type: application/json` and an `Accept` naming
  both `application/json` and `text/event-stream`, plus `MCP-Protocol-Version` ==
  `params._meta["io.modelcontextprotocol/protocolVersion"]`, `Mcp-Method` == the
  JSON-RPC method, and `Mcp-Name` == `params.name` for `tools/call`,
  `prompts/get` and `resources/read`. A mismatch is 400 with JSON-RPC -32020, a
  missing protocol block is -32602, and a *tool* refusal is a result so it stays
  a 200. A schema property annotated `x-mcp-header` must also arrive as
  `Mcp-Param-<name>` matching the argument — derived from the input schema, so a
  schema change can tighten the wire contract on its own.
- `GET`, `DELETE` and every other method are 405. An `Origin` header that is not
  in `~allowed_origins` (default: none) gets 403 and then the adapter raises
  `Rejected_origin` after flushing, so the connection closes without reading the
  body: expect it in `on_error`, do not log it as a fault. A request with no
  `Origin` at all is ordinary non-browser traffic.
- HTTP dispatch is stateless: `dispatch_string` for a legacy body,
  `dispatch_http_json_frames` for a modern one, never `create_session`.
  `Server.session` is `{ server; mutable phase }` — unsynchronised, so never
  share one across connections. Consequence: the legacy initialize/initialized
  gate exists only over stdio (`run_channels` builds the session), and over HTTP
  a `tools/list` before `initialize` is answered.
- Framing differences to expect in a transcript: a legacy notification is no line
  on stdio and an empty 204 over HTTP; a modern request with no frames is 202.

Per-connection servers (the M2 spike behind `plans/capability-gated-mcp-server.md`
§7): `handler` closes over one `Mcp_kit.Server.t` and its cohttp callback
discards `_conn`, so mcp-kit cannot vary a server per client. No mcp-kit change
is needed either: `Cohttp_eio.Server.callback : t -> IO.conn -> IO.ic -> IO.oc ->
unit` is public and is the per-connection driver `Server.run` calls, so an
application that accepts with `Eio.Net.run_server` itself chooses which handler
value owns the connection (`one_listener_can_route_connections_to_different_grants`
— one socket, two servers, two filesystem grants). At accept time the only fact
about the caller is its peer address, so per-*request* authority would mean
re-entering the adapter's validation, and `Mcp_kit.Server.t` copies are cheap
(immutable record; `Server.of_registry` is a fold of `add_tool`, no I/O).

Odds and ends: OCaml 5.3 has no `String.drop`; `Atomic.set t v` takes the atomic
first; Eio 1.6's `Promise` has `await` and `await_exn` but no `await_ok`; dune's
dev profile turns warning 69 (`unused-field`) into an error, so a test harness
must not carry a record field only its wrapper reads.
