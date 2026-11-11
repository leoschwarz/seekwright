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

## Verified running M4 conformance (2026-11-11)

Where mcp-kit's official compliance scenarios actually live — **not in the opam
package**: the installed `lib/mcp-kit/` ships library sources and no test suite.
They are in the repo, so clone the tag the switch installs
(`git clone --branch v0.2.0 https://gitlab.com/nomadic-labs/ai-harness/ocaml-mcp`,
archive `sha256=43c8319a13be91e323ae952a71ab673533fb3295886029eed9d81e5828de5ef7`):

- `test/conformance/server.ml` (+ `multiple_inputs_fixture.ml`,
  `multi_round_fixture.ml`) — the fixture the runner scores;
- `test/conformance/requirements-2026-07-28-server.txt` — the 37 frozen scenario
  IDs; `expected-failures-2026-07-28-server.json` was empty at that tag, which is
  where the plan's "37/37" figure comes from;
- `test/conformance/compare_results.py`, `package.json` (pins
  `@modelcontextprotocol/conformance@0.2.0-alpha.11`), and
  `scripts/run_live_mcp_conformance.sh` — the wrapper and the fail-closed gate.

Runner facts, all verified by running it:

- `conformance server` takes `--url` and nothing else: **no stdio mode**. A stdio
  conformance claim has to be in-tree (see `test/conformance/dune`).
- Node >= 22. The system `node` 20.19.2 dies at import —
  `The requested module 'fs' does not provide an export named 'globSync'` — which
  looks like a broken install, not a version problem. Node 22.23.4 as a tarball
  under `~/.local/opt/node22` works; see `plans/infra-setup.md`.
- `--requirements 2026-07-28` runs 50 scenarios: the 37 scored plus **13
  unscored** (ten `tasks-*` extension, plus the `json-schema-2020-12`,
  `http-header-validation` and `http-custom-header-server-validation` pending
  set). A scenario counts as a pass only when no check in its `checks.json` is
  `FAILURE` or `WARNING`.
- The comparator is strict in ways that surprise: it demands
  `run-date-utc.txt`, `server-commit.txt`, `runner-version.txt`,
  `node-version.txt`, `npm-version.txt`, `required-command.txt` and
  `working-tree-status.txt` in the output directory or every scenario is
  *inconclusive*; it fails on a baseline entry whose check now passes (stale);
  and baseline causes are only `sdk_protocol_defect | fixture_gap | runner_issue
  | unsupported_feature | unresolved`, with `reason` mandatory and `evidence`
  mandatory for `unresolved`.
- Declaration names are the runner's contract: `test_simple_text`,
  `test_error_handling`, `test_logging_tool`, `test_custom_header`,
  `json_schema_2020_12_tool`, `test_prompt_with_image`,
  `test_prompt_with_embedded_resource`, `test://static-text`,
  `test://template/{id}/data` … A scenario that cannot find its declaration fails
  with `unknown tool:` / `unknown prompt:` even when the behaviour is fine. So an
  ordinary server scores **8/37** without implementing anything relevant —
  `tools-list`, `resources-list`, `prompts-list`, `caching`,
  `sep-2164-resource-not-found`, `server-sse-multiple-streams`,
  `input-required-result-unsupported-methods` and
  `input-required-result-validate-input` all validate an *empty* list.
- A caps-declared schema reaches the wire unchanged, and that is measurable: the
  runner's Draft 2020-12 document (`$schema`, `$defs`/`$anchor`, `$ref`,
  `allOf`, `if`/`then`/`else`, `additionalProperties: false`) passes all eight of
  its checks, and an `x-mcp-header` annotation on a property passes all ten of
  `http-custom-header-server-validation`, through `Tool.make` → `Registry.add` →
  `Server.of_registry`.
- Control run, so the numbers mean something: mcp-kit's own fixture, copied
  unmodified into a scratch dune project and built against this switch's
  installed mcp-kit 0.2.0, scores **37 pass / 0 fail / 0 inconclusive** through
  our wrapper. Our `test/conformance/fixture.ml` scores **19 / 18 / 0**, all 18
  classified as v1 surface gaps (`Tool.Output` has no rich content, no progress,
  no input-required result; `Registry` has no interactive tools).

Build and dune details:

- The control project needs the two fixture *libraries* beside `server.exe`; a
  root `dune` and a `fixture/dune` that both declare `multi_round_fixture` fail
  with "Library with name … is already defined" — keep one stanza file.
- In a transcript rule, `with-outputs-to` merges stdout and stderr, so a stdio
  fixture's startup notes land in the protocol transcript. Split them with
  `with-stdout-to` + `with-stderr-to` and pin both by diff.
- `dune promote` only promotes what a **runtest** diff flagged: after a bare
  `dune build <target>` it says "Nothing to promote". Run
  `dune runtest <dir>` first, then `dune promote`. A promoted file lands
  read-only, so a `cp` over it fails with EACCES.
- `Mcp_kit.Server.add_resource` / `add_prompt` / `add_resource_template` all take
  `t -> X -> (t, _) result`, so they compose as `let server = add_resource server r
  in …`, not with `|>`.
- Environment hazard for cleanup commands here: `pkill -f <pattern>` matches the
  `bash -c` line that carries the pattern, so it kills your own shell (exit 143,
  no output). Kill by PID, or match `/proc/<pid>/exe` instead.

## Verified building P2 — wire models and sanitize (2026-11-11)

`lib/{model,sanitize}.ml{,i}` and `test/test_{model,sanitize}.ml` build and pass
(24 + 18 alcotest cases). Facts worth not rediscovering:

- **`Yojson.Safe.t` in yojson 3.0.0 has `\`Intlit`, not `\`Tuple`/`\`Variant`.**
  Its constructors are `Null | Bool | Int | Intlit | Float | String | Assoc |
  List`; an exhaustive match copied from an older yojson example fails with
  "The second variant type does not allow tag(s) `Tuple`". Treat `Intlit` as an
  integer in a type-error describer.
- **A local type named `result` shadows Stdlib's `result` in a module.** A `.mli`
  line `Yojson.Safe.t -> (result, string) result` then fails with "type
  constructor result expects 0 argument(s)"; spell the builtin
  `(x, string) Stdlib.result` instead. `Result.bind` still resolves to the
  stdlib module.
- **A JSON decoder inferred without an argument annotation narrows to a
  polymorphic-variant subtype** (`[< ... > \`Assoc ]`) in the generated
  signature, so it no longer matches `Yojson.Safe.t -> …`. Annotate the decoder
  argument `(json : Yojson.Safe.t)` (and the shared `as_assoc`/`json_kind`
  helpers) before matching; inference then keeps the closed type.
- **`let rec` whose only recursion is inside an inner loop is warning 39**
  ("unused rec flag"), an error in the dev profile; use `let f … = … let rec
  loop` and drop the outer `rec`.
- **Attaching the first library regenerates the opam file.** With
  `(generate_opam_files true)`, adding `lib/dune` with `(library (name
  seekwright) (public_name seekwright))`, removing `(allow_empty)` from the
  `seekwright` package and listing the new deps (`yojson`, `alcotest
  :with-test`) in that package's `(depends)` makes `dune build` rewrite
  `seekwright.opam` in the source tree (committed, never hand-edited).
  `LIBRARY_PATH=$HOME/.local/lib` is enough to link the whole tree on this
  machine (the GMP symlink lives there).
- **Pinning a golden oracle string in an OCaml test:** embed it in a `{|…|}`
  quoted literal (terminates only at `|}`; check that no `|}` occurs) and assert
  `Digest.to_hex (Digest.string payload) = "<python md5>"`. Python's `len()` is
  codepoints while `String.length` is bytes, so a length assertion would not
  catch a transposition of the multibyte characters.
- **pydantic's default-vs-null rule needs two decoders.** A field declared
  `int = 5` / `bool = False` treats absent as the default and an explicit
  `null` as an error; only an `Optional` field maps `null` to `None`. Sharing
  one `opt_*` helper for both silently accepts bodies pydantic refuses.
- The sanitizer's `{1,64}` ceilings are counted in **codepoints**, so a
  byte-wise scan diverges on multibyte token names (`▁` is three bytes): both
  angle passes advance with a UTF-8 `next_index`. `<|…|>` content excludes only
  ASCII `< > | \n`, so a fullwidth `｜` is ordinary content inside the ASCII
  shape; the fullwidth shape excludes both bars.

## Verified building P3 — TOML config and validation (2026-11-11)

`lib/config.ml{,i}` and `test/test_config.ml` build and pass (170 alcotest cases,
against 145 `def test_...` in `tests/test_config.py`: the `parametrize` families
are lists expanded by the runner, so a moved name fails one case in each tree).
Facts worth not rediscovering:

- **`toml` 7.1.0's parser and key printer.** `Toml.Parser.from_string : string ->
  (Toml.Types.value, string) result`; the value constructors are `TBool | TInt |
  TFloat | TString | TDate | TArray | TTable`. `Toml.Types.Table.fold` hands over
  `Table.Key.t`, and `Key.to_string` **re-quotes a non-bare key** — `[providers."exa:free"]`
  comes back as `"exa:free"` with the quotes. The library escapes nothing inside
  those quotes, so stripping exactly one matched pair at each end recovers the
  name (`Config.key_name`). Reading `Key.to_string` verbatim turns every flavoured
  provider into an unknown-provider error.
- **The `toml` array is typed; `tomllib`'s is not.** `fallback = ["serper", 3]`
  is a TOML *parse* error in OCaml where pydantic reaches a `string_type` error on
  element 1. Both refuse; the sentence differs. Same for a TOML integer above
  `int64` (parse error) and a decimal string above `int63` (this build refuses,
  Python carries the big int). These three are the accepted divergences and are
  named in the test module's header.
- **pydantic 2.14.3's lax scalar coercion is worth porting, and was measured
  rather than guessed** (`uv run python` over the real models): `int` takes
  `TInt`, `TBool`, an integral `TFloat`, and a string read as `" 400 "`, `"+7"`,
  `"1_000"`, `"500.0"` — and refuses `"1."`, `"1e2"`, `"0x10"`, non-ASCII digits,
  and anything past `int63`. `float` takes those plus `inf`/`+Infinity`/`nan` in
  any case and `1_0.5`/`1e_2`, refusing `x`-hex and an underscore not between
  digits. `bool` takes `TBool`, the numbers 0 and 1 (also `0.0`/`1.0`), and the
  twelve spellings `true/t/yes/y/on/1` and `false/f/no/n/off/0`,
  case-insensitively, with **no trimming** (`" true "` is refused). A port that
  types TOML scalars straight into fields refuses an operator's `max_chars = "400"`.
- **`permitted_providers` and a provider name print different sets.** The
  provider-name refusal lists the 17 providers; the permission-set refusal lists
  those **plus** the fetch-only names it has to vouch for (`jina`), sorted. One
  sentence constant reused for both fails the second.
- **alcotest 1.9.1 idioms:** `Alcotest.testable fmt equal` takes *two* arguments
  (no name label); cases are `Alcotest.test_case "label" `Quick fn` — the older
  `test `Quick, fn` tuple form does not exist, and a `(label, test)` tuple is not a
  `unit test`. Suites are `(string * unit test list)`, so concatenating built
  suites needs `@ [ cases … ]`, not `@ cases …`. `Alcotest.run` has no
  `~exn_exit_code` here. To re-run one suite: `./_build/default/test/x.exe test
  "<suite name>"` (a bare positional argument is read as a command).
- **A test's cwd is `_build/default/<dir>`, not the source directory.** A suite
  that reads repo files needs them in `(deps ../docs/reference/configuration.md …)`
  and the path `../docs/…`; running the built exe from the repo root instead makes
  exactly those cases fail, which looks like a port bug and is not one.
- **`Float.class` is a syntax error** — `class` is a keyword, so the accessor
  parses as module-then-keyword. Compare with `Float.is_nan` and
  `Float.equal v Float.infinity` instead (or `Float."class"`).
- **There is no `unsetenv` in the stdlib**; `Unix.putenv name ""` is the
  workaround, and it is sound here only because `Config.api_key` reads `""` as
  absent the way Python's `os.environ.get(...) or None` does.
- **`test/router_dependencies.expected` is a mechanical re-pin.** Any module added
  to `lib/` adds two `ocamldep` lines; `dune promote test/` fixes it. It was stale
  at `7fa7a5c` (only the `router` lines, though `model.ml` and `sanitize.ml` were
  already in the tree), so `dune runtest` failed on P3's checkout before any P3
  code was involved — check `git show HEAD:test/router_dependencies.expected`
  before reading a red runtest as your own breakage.
- **The differential harness works and is worth re-running.** With
  `/tmp/opencode/{gencases.py,oracle.py,dump.ml,compare.py}`:
  `python3 gencases.py` (102 files in `/tmp/opencode/cases`), then *both* drivers
  take the case paths as argv —
  `uv run python oracle.py $(ls /tmp/opencode/cases/*.toml | sort) > py.out`, and
  `ocamlfind ocamlopt -package toml -linkpkg -I _build/default/lib
  -I _build/default/lib/.seekwright.objs/byte _build/default/lib/seekwright.cmxa
  -o dump dump.ml && ./dump $(ls /tmp/opencode/cases/*.toml | sort) > ocaml.out`,
  then `python3 compare.py`. It caught three real port bugs here (the quoted
  table key, an unsorted `enabled_providers`, and the whole lax-scalar question).
  Current: 99/102 agree, the 3 flagged being the parser divergences above.

## Verified building P4 — provider contract + keyless adapters (2026-11-11)

`lib/provider.ml{,i}`, `lib/providers/{freeserp,anysearch}.ml{,i}` and
`test/test_{provider,freeserp,anysearch,provider_contract}.ml` build and pass
(23 + 38 + 33 + 4 alcotest cases). Facts worth not rediscovering:

- **`lib/providers/` is its own library**, `(name seekwright_providers) (public_name
  seekwright.providers)` → `Seekwright_providers.Freeserp`. A
  `(include_subdirs qualified)` in `lib/dune` is rejected with "cannot be used
  in the same directory as directories with dune rules" as soon as a sibling
  (`lib/caps/`) has a stanza, and even without one, a qualified subdir of a
  *public* library must be `(package seekwright)` — which then makes its module
  path `Seekwright.Providers.Freeserp` and puts it in the `seekwright` package
  where P5's factory needs to depend *back* on it. Keep the separate stanza;
  dependency direction is `mcp-caps → seekwright → seekwright.providers`.
- **Adapters → `seekwright` means P5's factory cannot be `lib/factory.ml`**: a
  factory that builds adapters closes the cycle. It needs its own library.
- `lib/dune` gained `(libraries mcp-caps uri yojson)`; `dune build` regenerated
  `seekwright.opam` with `"uri" {>= "4.0"}` after `dune-project`'s `seekwright`
  package gained `(uri (>= 4.0))`. `dune-project` takes `(uri (>= 4.0))` — a
  version constraint and `:with-test` cannot share an entry (M1 note still holds).
- **An optional labelled argument whose declared type is an option gets wrapped
  again**, so `?language:bool option` reaches the implementation as
  `bool option option` and every call site would have to write
  `~language:(Some (Some true))`. Python's `language: bool | None = None` ports
  as a **mandatory labelled arg** `language:bool option` — the caller still
  writes `~language:None` for "not answered", which keeps the same visibility
  the four required buckets have.
- **A trailing `()` after optional args is unit-dropped.** `let f ?a ?b () = …`
  is called `f ~a:x ()`, never `f ~a:x () ()` — the extra unit gives "This
  argument cannot be applied without label". Same for a fixture builder with a
  `?query:` optional: `search_of ()`, not `search_of () ()`.
- **`Policy_net` declares `body` *and* `headers` on both `request` and
  `response`**, so `request.body` in a function whose argument is not annotated
  fails with "Unbound record field". Annotate the binding:
  `let body_of (request : Caps.Authority.Net.request) = …` and the labels resolve
  for the rest of the body.
- **Uri 4.4 has no `Uri.Query` module** for what adapters need: use
  `Uri.with_query u [("q", ["x"])]` (values are `string list`), `Uri.query`,
  `Uri.get_query_param`. A query built with `Uri.with_query` round-trips through
  `Uri.to_string` with the same ordering.
- **`Yojson.Safe.from_string` accepts bare scalars and arrays** — `[]`, `null`,
  `42`, `"a string"` all parse — so a "decodes to a non-object" guard is
  load-bearing, not a formality; and it *raises* `Yojson.Json_error` on empty or
  truncated input, so decode is `try … with Json_error` and the caller's error
  row, never a `result` returning `Ok`.
- **`Alcotest.float` takes the absolute error positionally**: `A.float 1e-9`,
  there is no `~abs_tol` (its signature is `float : float -> float testable`).
- **OCaml 5.3 has `Option.get`, not `Option.value_exn`.** `Int64.sign` is also
  absent; compare against `0L`.
- Source-reading tests (the "every adapter on disk is driven" guard, the
  source-discipline guard) only work under `dune runtest`: the `(deps
  (glob_files ../lib/providers/*.ml))` sandbox is what makes `Sys.readdir
  "../lib/providers"` resolve, and `dune exec test/x.exe` fails with
  `Sys_error("../lib/providers: No such file or directory")`. Do not chase that
  as a bug.
- Date arithmetic without a `unix` dependency: days-since-civil is Hinnant's
  `civil_from_days` (~15 lines), and a pinned clock fixture makes the assertion
  exact. `now () = 1_700_000_000.` → `2023-11-14`, and the Python-verified
  recency starts are day `2023-11-13`, week `2023-11-07`, month `2023-10-15`,
  year `2022-11-14`.
- **`test/router_dependencies.expected` was stale on the branch base** (P2 added
  `model`/`provider`-era modules without re-pinning), so `dune runtest` failed
  before P4 started. `dune runtest test` then `dune promote test`; the pin now
  lists `model`, `provider`, `router`, `sanitize` and keeps
  `../lib/router.cmi :` dependency-free.

## Verified fixing the P4 clip (2026-11-11)

`Provider.clip`'s fast-path guard was `String.length text <= limit`, a byte
length against a codepoint cap; it is now `codepoint_count text <= limit`.
Measured over the review's 209-pair differential corpus
(`/tmp/opencode/p4diff/py.py` against `truncate_snippet`/`truncate_text`): 8
mismatches before, 0 after.

- **The mismatch only exists where the two lengths straddle the cap**: bytes
  `> limit` while codepoints `<= limit`. A fixture whose byte *and* character
  counts both exceed the limit never reaches the bug — the pre-existing
  `the_cap_counts_characters_not_bytes` ("éééé éééé" at 5) is exactly that, so
  it passed with the guard broken. Pin the straddle explicitly; the crossing
  rows now live in `test_provider.ml` as `the_crossing_pairs_match_the_oracle`
  (plus an ASCII `ascii_caps_match_the_oracle` for the boundary/rstrip rules).
- The eight rows, as the oracle answers them (text, limit): `"héllo. x"` 8,
  `"éabcd"` 5, `"naïve café. next sentence here"` 30,
  `"日本語のテキストです。次"` 12/20/30, `"emoji 😀 test"` 12, 30×`"é"` 30 — all
  returned whole, `cut = false`. A byte guard sliced at a boundary (the first
  row) or appended `"…"` (the rest).
- Consequence worth naming in P5/P6: `truncate_text`'s `cut` flag (what a caller
  uses to decide whether `fetch` is worth it) was *true* for an uncut page, so
  this was a correctness bug on the flag as well as the text.
- **`git rebase --continue` still wants a commit message editor** once conflicts
  are resolved and staged, even when the message is unchanged: a non-tty run
  dies with `problem with the editor 'editor'`. Use
  `GIT_EDITOR=true git rebase --continue`.
- Rebasing P4 onto P3 conflicted in four files, all mechanical: `lib/dune`
  (libraries union → `mcp-caps toml uri yojson`), `test/dune` (keep the P3
  `test_config` stanza *and* the P4 suites), `test/router_dependencies.expected`
  (ocamldep order: `config, model, provider, router, sanitize`) and this file
  (both dated sections). `dune-project` auto-merged (both `(toml …)` and
  `(uri …)` under `seekwright`), and a plain `dune build` regenerated
  `seekwright.opam` with both — never hand-edit it.
- After the rebase `dune runtest` is green at config 170, provider 25, freeserp
  38, anysearch 33, provider-contract 4; no `dune promote` needed once the pin
  above is right.

## Verified porting P5 (2026-11-11)

`lib/engine.ml` (Search + Fetch), `lib/health.ml`, `lib/usage.ml` and their
alcotest suites. Gate: `dune build` clean, `dune runtest --force` green —
22 suites, engine 82, fetch engine 73, usage 65, health 26 cases.

Three real bugs in `lib/`, each found by a ported case rather than by review:

- **`match … | _ -> ();` inside a sequence swallows the statements after it.**
  `|` binds looser than `;`, so `match x with A -> foo () | _ -> (); bar ();`
  puts `bar ()` in the last arm. `Usage.fold_days` had this and never set the
  endpoint's `last_seen`/`last_at`. Parenthesise a `match` that is a statement:
  `(match … with …)`.
- **A dict-assignment helper has to insert, not only overwrite.** `Usage.set`
  rebuilt the association list from the keys it already had, so the *first*
  write of a new key was dropped — invisible while every fixture pre-seeded it.
  Python's `d[key] = value` appends; the helper now does.
- **Binding log fields is not emitting an event.** `Engine.Search.log_ok` built
  the `search.ok` field list and returned it without an `emit`, so the event did
  not exist. It also has to return the *base* bound fields, not the extended
  ones — that is what keeps `search.cap`/`search.result`/`search.answer`
  carrying only provider/qlen/qhash.

OCaml traps, all paid for:

- `!s.field` parses as `(!s).field`. For a ref inside a record write
  `!(s.kwargs)`; `incr s.calls` is fine.
- An optional argument **without a default takes the bare value**, so the type
  in the signature is what you pass, wrapped: `?image` over a field typed
  `image : image option` wants `~image:{ … }`, not `~image:(Some …)`. A field
  that is itself `string option` (like `title`) then takes `~title:None`.
- Opening a module can steal your binder names. With `open Logs`, the sink
  `fun level event fields -> …` parsed `fields` as the value
  `Logs.String.fields`, and the error was the cryptic "This function has type
  `string -> Yojson.Safe.t list` but it is given an argument of type
  `(string * 'a) list`". Alias instead (`module LS = Logs.String`).
- Don't `open Alcotest` in a suite that reads `Yojson` loosely: the local
  readers named `int`/`bool`/`str` shadow the testables `check` needs. The
  pattern the P4/P5 suites use is local aliases — `let check_string =
  A.(check string)` — plus `A.failf`.
- `String.split_on_str`, `String.prefix`, `String.is_suffix` and
  `String.index_opt ~sub` are not in this stdlib. `test_engine.ml` carries
  `find_sub_from ?start`, `is_prefix`, `is_suffix`; `test_fetch_engine.ml` adds
  `split_on_string`.
- Warning 21 (non-returning statement): a `failwith` arm followed by `;` and
  more checks. Put the shared check before the `match`.
- Warnings 32/69 are errors here: an unused fixture helper or a `mutable`
  record field no case assigns fails the build. Stub state that only the
  fixture mutates belongs in `ref` fields (`calls`, `kwargs`), and unused
  helpers get deleted rather than kept for symmetry.
- A fixture with only optional arguments still needs a trailing positional
  `()`, and every call site pays it: `make_engine ~local:(stub ()) ()`.

Fetch fixture shape, for whoever wires the real readers in P6:

- `Engine.Fetch.create` returns a `result` (Python's constructor `ValueError`
  for a `fetch.primary` this deployment did not build), so the fixture fails
  the test on `Error`; `~readers` is mandatory, and the suite hands a stub.
- The stub `Readers` owns the *budget* arithmetic the engine only reports:
  sections are filled in order and the walk **stops at the first section that
  does not fit** (the rest are the count in the notice), and a subtree block
  over budget is offered a line at a time. Without those two rules the
  "larger than the selection budget" and "selection budget … reached"
  sentences cannot be tested before `jsondoc` exists.
- `test_usage.exe` writes its journal fixtures into a cwd-relative
  `usage-journal/`; it is not in `.gitignore`, so delete it before committing.
- `test/dune` takes one stanza per exe; the fetch suite needs only
  `seekwright yojson alcotest` (no adapters, no network, no `unix`).

## Verified fixing the P5 review findings (2026-11-11)

The P5 review's CRITICAL: `Engine.Search` composed the zero-results notice
with the first attempt's name; Python passes `result.provider`, so after a
fallback walk the sentence must name the fallback that served. The call site
now passes `outcome.Provider.provider`, pinned by a regression case (fallback
serves zero results → the notice names the fallback) that fails on the old
line. The review's three suggestions: `dune-project` now declares `digestif`
and `eio` (the opam file regenerates from it — never hand-edit);
`ocamldep` in `test/dune` needs `-I ../lib` to resolve sibling modules at
all, without which the router pin was vacuous (every cross-module line was
empty); and the `structure=true` fetch path got its engine-half coverage in
`test_fetch_engine.ml` via a `schema_readers` stub, including that a
structure read never escalates to the fallback ladder over emptiness.
