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
Added for M3: `tls-eio`/`tls` 2.1.5, `ca-certs` 1.0.3, `x509` 1.2.0,
`mirage-crypto-rng`/`mirage-crypto-pk` 2.4.1, `zarith` 1.14 — library
dependencies of `mcp-caps` now, and see the M3 section for the GMP/`PATH` dance
they need on this machine.

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

## Verified building M3 (2026-11-10)

The network grant (`lib/caps/policy_net.ml`) and its suite
(`test/test_authority_net.ml`) are the source of every fact in this section.

Environment — **every build shell needs this**, or zarith (pulled by `tls`) fails
to link. `libgmp-dev` is absent and `sudo` needs a password, so GMP lives in
`~/.local/opt/gmp-dev` (see the "TLS stack for M3" section of
`plans/infra-setup.md`):

```bash
eval $(opam env --switch=default --set-switch)
export CPATH=/home/leo/.local/opt/gmp-dev/usr/include:/home/leo/.local/opt/gmp-dev/usr/include/x86_64-linux-gnu
export LIBRARY_PATH=/home/leo/.local/opt/gmp-dev/usr/lib/x86_64-linux-gnu
export PKG_CONFIG_PATH=/home/leo/.local/opt/gmp-dev/usr/lib/x86_64-linux-gnu/pkgconfig
```

Install was `opam install -y --assume-depexts tls-eio ca-certs` (`--assume-depexts`
because opam's depext pass wants root). Versions now in the switch: `tls-eio` and
`tls` 2.1.5, `ca-certs` 1.0.3, `x509` 1.2.0, `mirage-crypto-{rng,pk}` 2.4.1,
`zarith` 1.14, `ipaddr` 5.6.2, `domain-name` 0.5.0.

### cohttp-eio's client, when you supply the connection

- `Cohttp_eio.Client.make_generic : (sw:Eio.Switch.t -> Uri.t ->
  [> Eio.Resource.close_ty ] Eio.Flow.two_way) -> t`. The `Uri.t` is handed to
  *your* connector, so a connector that ignores it and returns the socket it
  already vetted is the whole DNS-rebinding fix — the client never resolves the
  name again. `Client.call client ~sw ~headers ?body meth uri` then writes that
  URI on that socket. `set_proxies` is process-global and only feeds `make`, so a
  `make_generic` client ignores it.
- The connector's return type is spelled `[ Eio.Flow.two_way_ty |
  Eio.Resource.close_ty ] Eio.Resource.t` in a **type declaration**: `Eio`'s
  `two_way` alias cannot be applied to a row there (its own row is bound by an
  `as` pattern), and `Eio.Resource.t` is contravariant in the tag row, so an open
  row in the declaration is rejected. cohttp-eio's own `client.ml` spells it the
  same way. Both an `Eio.Net` stream socket and a `Tls_eio` flow then reach it
  with `(x :> connection)`.
- Response **headers** are read by cohttp-eio at `Buf_read.of_flow
  ~max_size:max_int` — the body ceiling is ours, the header block is only
  timeout-bounded. That is a known limit, recorded in `policy_net.mli`.
- Server side, for a fixture: `Cohttp_eio.Server.make ~callback ()` with
  `callback : conn -> Http.Request.t -> Body.t -> response IO.t`,
  `conn = Eio.Switch.t * Eio.Net.Sockaddr.stream`. `Http.Request.t` carries
  `resource` (path **and** query) and no assembled URI — a `Location` has to be
  built from the `Host` header. `Http.Method.to_string` takes the concrete
  `Http.Method.t` (no coercion needed).

### TLS (client side only)

- `Ca_certs.authenticator ()` → `(authenticator, [> `Msg of string]) result`;
  `Tls.Config.client ~authenticator ()` → `(config, [> `Msg of string]) result`;
  `Tls_eio.client_of_flow config ~host:(`host name) flow` / `~ip:(`ip addr)`.
  Never `accept_any`. Build the config once, at grant construction, so a missing
  trust store is a startup failure.
- **The RNG is process-global and must be installed by the application**
  (`Mirage_crypto_rng_unix.use_default ()`, from the `mirage-crypto-rng.unix`
  findlib library inside the `mirage-crypto-rng` package). `tls` throws
  `Mirage_crypto_rng.No_default_generator` at *handshake* time, not at
  `Tls.Config.client`, so the check has to call
  `Mirage_crypto_rng.default_generator ()` — `try Ok () with
  No_default_generator` is dead code that looks like a guard.
- `mirage-crypto-rng.unix` pulls stdlib `unix`, so it belongs in example and test
  stanzas, never in `mcp-caps` (`test/test_core_no_mcp_kit.ml` guards that).

### Eio 1.6 network and time

- A scripted `Eio.Net.t` for tests: `Eio.Net.Pi.network (module M)` where `M`
  declares **`type tag = [ `Generic ]`** — `type tag = unit` produces
  `[ `Network | `Platform of unit ] r`, which fails the
  `[> [> `Generic ] ty]` constraint the real API expects. `connect` can raise
  instead of returning a socket, which is how a test proves both "refused, so no
  I/O" and "allowed, and here is the address it asked for".
- `Eio.Net.getaddrinfo_stream net ~service host` never returns `[]` — an
  unknown name raises `Address_lookup_failed`. Answers carry
  `Eio.Net.Ipaddr.v4v6`; go through `Ipaddr` with
  `Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets ip)` and back.
- `Eio.Time.Timeout.run` widens the body's error row with `` `Timeout ``, which
  cannot unify with an abstract error channel, so the shared wrapper uses
  `Timeout.run_exn` and turns `Eio.Time.Timeout` back into a classified error.
  `Eio.Cancel.Cancelled` is a *different* exception and keeps propagating, which
  is what "cancellation must not become a provider failure" needs.
- Timeouts are measured on a monotonic clock: `Eio.Time.Mono.t`,
  `Eio.Stdenv.mono_clock env`, `Eio.Time.Timeout.seconds clock s`.
- `Eio.Promise.create ()` returns `(t, u)`, not `(u, t)`: `Cohttp_eio.Server.run
  ~stop` wants the `t`, `Eio.Promise.resolve` takes the `u`, `await` the `t`.
  Getting it backwards is a type error that reads like a naming problem.

### ipaddr and the address table

- `Ipaddr.is_global` is **not** the public-web policy: it calls `fc00::/7`,
  `128.0.0.0/16`, the whole of `0.0.0.0/8` and the three TEST-NET blocks global.
  `Policy_net.special_use` is the RFC 6890 table that closes those gaps.
- A prefix test over `Ipaddr.to_octets` needs the mask on the **high** bits of
  the partial octet: `(0xff lsl (8 - rest)) land 0xff`. `lsr` silently allows
  half the range — `fd12:3456::1` got through `fc00::/7` until the test table
  caught it, so keep one row per boundary (`fc00::1` *and* `fd12:3456::1`).

### OCaml 5.3 stdlib, again

- No `String.rsplit2` (that's `CCStrings`); no `Atomic.modify` (5.5) — a
  compare-and-set loop. `String.index_from_opt` is what you want for "last
  colon in a Host header" on 5.3.
- `Alcotest.fail` takes optional `~here`/`~pos`, so `Format.kasprintf
  Alcotest.fail fmt` does not typecheck; wrap it:
  `Format.kasprintf (fun message -> Alcotest.fail message) fmt`.
- The dev profile's warning 69 (`unused-field`) kills a test fixture record whose
  fields only the wrapper reads — so make the assertions read them
  (`method_`, `host`, `body_bytes` in the net fixture).

## Verified fixing the M3 address-policy gap (2026-11-11)

- `Ipaddr.is_global` (ipaddr 5.6.2) returns **true** for these IPv6 literals even
  though their low 32 bits name a private/link-local IPv4 destination:
  `64:ff9b::a9fe:a9fe` and `64:ff9b::10.0.0.1` (NAT64 well-known, RFC 6052),
  `64:ff9b:1::a9fe:a9fe` (NAT64 local-use, RFC 8215), and `::ffff:0:7f00:1`
  (IPv4-translated, RFC 2765's `0::ffff:0:a.b.c.d`). `Policy_net.special_use`
  now carries `64:ff9b::/96`, `64:ff9b:1::/48` and `::ffff:0:0:0/96`.
- IPv4-*mapped* is different: `is_global` computes scope from the embedded v4, so
  `::ffff:127.0.0.1` is non-global while `::ffff:93.184.216.34` is global. The
  mapped range needs no blanket row; the translated prefix gets no such
  treatment, which is why it needs one.
- The RFC prefixes are easy to mistype because the textual forms differ by one
  group: mapped `::ffff:0:0/96` is octets `00*10 ff ff`, while translated is
  `::ffff:0:0:0/96` = `00*8 ff ff 00 00`; `::ffff:0:7f00:1` matches only the
  latter. Both spellings parse in ipaddr.
- `Uri.host` strips the brackets from an IPv6 literal
  (`http://[64:ff9b::1]/` → `64:ff9b::1`), so a bracketed-literal URL reaches
  `Policy_net.resolve` as the bare address and a scripted `Eio.Net.t` can answer
  it under that bare key.
