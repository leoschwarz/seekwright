# Capability-Gated MCP Server: OCaml 5 Plan

Status: revised implementation plan, v2. The API details below were checked against
locally installed mcp-kit 0.2.0 and Eio 1.6, not just the upstream README.

## 0. Framing, scope, and fallback

This layer is partly a learning exercise — a first OCaml MCP server — and its
success shape is a **library others can build MCP servers on**, not a one-off.
Keep the registry/policy core free of mcp-kit imports, with mcp-kit behind one
adapter module. If the capability layer does not earn its keep, drop
`registry.ml`/`policy.ml` and bind tools to mcp-kit directly, keeping the
transports and protocol baseline. M0 deliberately proves that direct path first.

There is a maintained OCaml MCP library: `mcp-kit` by Mathias Bourgoin at
Nomadic Labs (GitLab), MIT licensed, opam 0.2.0, published 2026-11-07
([package](https://opam.ocaml.org/packages/mcp-kit/0.2.0/),
[README](https://gitlab.com/nomadic-labs/ai-harness/ocaml-mcp/-/blob/v0.2.0/README.md),
checked 2026-11-10). It supports the 2026-07-28 request model and the
2025-11-25 initialization lifecycle, ships stdio, Eio-flow and Cohttp-Eio
adapters, compiles JSON Schema 2020-12 locally, and has a PPX for typed tool
declarations. Its recorded full-fixture result is 37 passes / 0 failures / 0
inconclusive scenarios.

The task is therefore to write the capability layer, not another protocol or
transport implementation.

**Goal.** Tools declare the authority their capability-mediated operations need;
registration supplies an abstract grant of exactly that type. Policy constructors
own filesystem and network confinement. The mcp-kit adapter closes each tool
handler over its grant and delegates protocol handling, schema validation,
transports, and wire conformance to mcp-kit.

**Threat-model boundary.** This is a design-time and audit guarantee for trusted
OCaml tool implementations using `mcp-caps`, not a sandbox. It does not stop tool
code from calling `Unix`, `Sys`, Eio, a C binding, `Obj.magic`, or a network
library directly. Abstract types make grants unforgeable only in ordinary safe
OCaml that respects the interfaces. No claim of "a tool cannot perform I/O" is
valid without that qualification. The guarantee is narrower and useful: a tool
cannot invoke **`Authority` operations** without a suitable grant, and widening
those operations is visible at registration.

**Non-goals for v1.** Protocol implementation, new transports, JSON Schema,
OAuth/authentication, caller identity, per-client authority, per-request quotas,
resources/prompts/subscriptions in `Registry`, custom effect handlers, and
sandboxing arbitrary tool code. Resources/prompts/subscriptions remain available
by adding them directly to the `Mcp_kit.Server.t` returned by the adapter.
`Proc` is deferred until a real caller needs it; seekwright's v1 does not.

## 1. Architecture and ownership

```
mcp-kit-cohttp-eio ─┐
mcp-kit.stdio ──────┼─→ Mcp_kit.Server.t ←── Server (the only mcp-kit adapter)
mcp-kit-eio ────────┘                              ↑
                                      one existential registered entry per tool
                                                   │
                                      Tool.run applied to grant : 'caps
                                                   │
                     Policy constructors ─→ 'caps Authority.t
                                                   │
                                    Fs | Net (closed authority kinds in v1)
```

`Registry.add` is the only core operation that pairs a grant with a tool. The
registry stores an existential record containing mcp-independent tool metadata
and a JSON handler already closed over that grant. This is why differently typed
tools coexist without `Obj.magic`, casts, or a universal authority value. The
server adapter folds those entries into mcp-kit declarations.

A tool requiring two grants uses an ordinary product such as
`Authority.Fs.t * Authority.Net.t` as its `'caps`; do not add a "union of all
powers" grant.

In v1, grants are **server-lifetime values**. Their resource-owning `Switch.t`
must enclose server construction and the transport loop. A server value may serve
concurrent clients, so policy implementations must not use unsynchronized mutable
per-request state. Concurrent calls sharing a grant must also share only the
intended confinement policy.

## 2. Layout

Root dune workspace (decided in `project-structure.md`); `mcp-caps` is the
reusable package, `seekwright` comes later and depends on it:

```
dune-project                     # package stanzas; exact mcp-kit dependency constraints
mcp-caps.opam                    # generated, committed, never hand-edited
lib/caps/                        # (library (name caps) (public_name mcp-caps)) → Mcp_caps
  error.ml / .mli                # structured, safely renderable failures
  event.ml / .mli                # bounded, content-free policy audit events
  authority.ml / .mli            # 'kind t plus Fs/Net operations; implementation closed
  tool.ml / .mli                 # metadata, typed input decoder, Output.t
  registry.ml / .mli             # existential entries; add ~grant
  policy.ml / .mli               # confined Fs/Net constructors and generic decorators
  policy_net.ml / .mli           # private DNS/connect/redirect/response-bound machinery
  server.ml / .mli               # the only module importing Mcp_kit
examples/
  dune
  echo.ml                        # direct fallback baseline, retained through M4
  caps_echo.ml                   # registry echo with ~grant:(); built at M0
  main.ml                        # registry echo + gated read_source; the audit surface
test/
  dune                           # alcotest suites
  should_not_compile/            # checked negative-compilation cases
  conformance/                   # live official-runner fixture and result comparator
```

The core modules must not import `Mcp_kit`; a dependency test or simple source
guard enforces this. The package still depends on mcp-kit for `Server`, but the
core remains algorithmically and source-level separable. Transports belong in
examples/applications, not in `Registry` or `Server`.

Error mapping lives at two boundaries:

- decoder failures and `Error.t` from `run` become MCP tool results with
  `isError = true`, never JSON-RPC transport failures;
- malformed declarations/duplicates fail server construction;
- mcp-kit retains ownership of JSON-RPC errors and output-schema contract errors.

`Error.t` must carry a stable kind (`Denied | Invalid | Unavailable | Timeout |
Failed`) and a sanitized message. Do not expose raw exceptions, backtraces,
headers, credentials, response bodies, or local variable values in it.

## 3. Core API

Use a phantom kind on one abstract authority representation so decorators can be
generic without pretending that `'a -> 'a` can wrap arbitrary OCaml values:

```ocaml
(* authority.mli *)
type fs
type net

type _ t

module Fs : sig
  type nonrec t = fs t

  val read_file : ?max_bytes:int -> t -> string -> (string, Error.t) result
  val list_dir : ?max_entries:int -> t -> string -> (string list, Error.t) result
end

module Net : sig
  type nonrec t = net t

  type method_ = [ `GET | `POST | `PUT | `PATCH | `DELETE ]
  type request = {
    meth : method_;
    uri : Uri.t;
    headers : (string * string) list;
    body : string option;
  }
  type response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }

  val request :
    ?max_response_bytes:int -> t -> request -> (response, Error.t) result
end
```

The implementation uses a GADT or equivalent private record for the `fs`/`net`
operations plus a shared controls record. Every operation goes through that
controls record. Generic policy decorators preserve `'kind`; there is no public
`with_deadline : float -> 'a -> 'a`, which could not inspect or wrap an arbitrary
value and would be an unimplementable API.

Tool input and output are explicit. The former plan's arbitrary result type could
not be serialized by `Server`, and its string-to-string validator did not provide
a decoded value to `run`:

```ocaml
(* tool.mli *)
module Output : sig
  type t
  val text : ?structured_content:Yojson.Safe.t -> string -> t
end

type ('caps, 'input) t

val make :
  ?title:string ->
  ?description:string ->
  ?output_schema:Yojson.Safe.t ->
  input_schema:Yojson.Safe.t ->
  decode:(Yojson.Safe.t -> ('input, string) result) ->
  run:('caps -> 'input -> (Output.t, Error.t) result) ->
  string ->
  ('caps, 'input) t
```

mcp-kit validates the input JSON Schema before invoking the adapter handler, then
`decode` produces the typed application input. `Output` is deliberately small in
v1: ordered text plus optional structured content. Add an mcp-independent rich
content constructor only with a concrete image/audio/resource use case; do not
leak `Mcp_kit.Tool.result` through the core just to avoid that future addition.
When `output_schema` is present, the adapter supplies `structuredContent` and
mcp-kit validates it. A schema/result mismatch is a server contract failure, not
a caller-denial result.

Registration is explicit and fallible:

```ocaml
(* registry.mli *)
type t
type add_error = Duplicate_tool of string

val empty : t
val add :
  t -> ('caps, 'input) Tool.t -> grant:'caps -> (t, add_error) result
```

No-capability tools use `~grant:()`. The `'caps` existential is packed only after
the grant and tool have been paired; it must not escape into the registry type.

Verified at M0: once `add` closes the grant *and* the decoder over `run`, the
stored entry needs no existential packaging at all — its handler is
`Yojson.Safe.t -> (Tool.Output.t, Error.t) result`, a type that mentions no
application type. `registry.mli` keeps `entry` abstract and exposes `entry_call`
plus the metadata accessors, which is all `Server` needs. A decoder refusal
after the schema passed becomes `Error.Invalid`, so it reaches the caller as a
tool result with `isError`, never as a JSON-RPC failure.

```ocaml
(* server.mli *)
type build_error =
  | Duplicate_tool of string
  | Invalid_declaration of string

val of_registry :
  name:string -> version:string -> Registry.t ->
  (Mcp_kit.Server.t, build_error) result
```

`Server.of_registry` validates all declarations before returning a usable server.
It must not silently drop an invalid entry or turn startup declaration bugs into
per-request errors. The adapter maps `Output.text` to `Mcp_kit.Tool.text` plus
`structured_content`, and maps `run` errors to `Mcp_kit.Tool.error_text` using
only the sanitized message.

Verified at M0: `Mcp_kit.Schema.check_input_schema` only rejects a schema
*document* that is not a JSON object, so `{"type":"string"}` passes it.
`Schema.require_input_object` is the check that insists the root describes an
object, and it raises `Invalid_argument` — declaration validation catches that
and returns `Invalid_declaration` rather than letting the exception escape.
mcp-kit keeps the output-schema contract: a result that does not match an
advertised `output_schema` is a JSON-RPC error, not an `isError` result.

## 4. Filesystem policy: real confinement, not string normalisation

`Policy.with_root` does **not** chroot the process. It opens an Eio subtree and
returns an `fs Authority.t` whose every operation stays on that handle:

```ocaml
val with_root :
  sw:Eio.Switch.t -> _ Eio.Path.t -> string ->
  (fs Authority.t, Error.t) result
```

Open for M1, noticed at M0: `authority.mli` deliberately exports no constructor,
and dune shows a module nothing beyond its siblings' `.mli` files, so `Policy`
cannot build the value `Authority` keeps abstract. Decide this before writing
`with_root`. The candidates are (a) construct the grants inside `authority.ml`
and re-export the constructors from `policy.ml`, or (b) expose one clearly
labelled constructor on `Authority` that takes the subtree handle — the handle
is what confines the grant, so passing it in cannot widen one. Anything reachable
by `Policy` is reachable by a caller, so this is a choice between two audit
stories, not a free option.

The base path is operator-supplied (typically under `Eio.Stdenv.fs env`). Open it
with `Eio.Path.open_subtree ~sw` and keep the switch alive for the server. Tool
paths are root-relative; reject absolute paths and `..` for a clear API, but do
not rely on lexical normalisation for security. `Eio.Path.open_subtree`, not
`realpath`/string prefix checks, is what prevents `..`, symlinks, and component
replacement races from escaping the subtree. Never convert the confined path to
a native string and pass it to `Unix` or another string-based filesystem API.

Reads are streamed with a policy maximum and stop before allocating beyond the
limit; `Eio.Path.load` and a `stat` size check alone are not sufficient. A caller
`max_bytes`/`max_entries` may lower, never raise, the grant's configured ceiling.
Normalize expected Eio/Unix failures at this boundary into sanitized `Error.t`
values; cancellation exceptions must propagate through Eio rather than being
converted into ordinary provider failures.

Security tests include internal symlinks, symlinks escaping the root, symlinked
parent directories, absolute paths, `..`, over-limit files, and repeated
rename/symlink replacement during reads. Passing only lexical `../../etc/passwd`
tests is not an escape-proof filesystem implementation.

## 5. Network policy: connection, redirect, and resource bounds

`Net` is a bounded HTTP authority, not just a string-to-string `get`. It supports
the methods, headers, and optional request bodies provider adapters need.
Constructors are explicit about the two different trust models:

```ocaml
type endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
}

val with_endpoints :
  sw:Eio.Switch.t -> net:_ Eio.Net.t -> clock:_ Eio.Time.clock ->
  max_response_bytes:int -> endpoint list ->
  (net Authority.t, Error.t) result

val with_public_web :
  sw:Eio.Switch.t -> net:_ Eio.Net.t -> clock:_ Eio.Time.clock ->
  max_response_bytes:int -> unit ->
  (net Authority.t, Error.t) result
```

`with_endpoints` is for operator-selected vendor/self-hosted endpoints and pins
scheme, normalized host, and effective port. In seekwright those sets are derived
from enabled providers, never exposed as a second egress config file.
`with_public_web` is for `fetch`: HTTP(S) only, no userinfo, only globally
routable unicast IP destinations, with loopback/private/link-local/multicast/
unspecified/special-use addresses, IPv4-mapped IPv6 variants, and non-default or
explicitly disallowed ports denied according to one documented policy.

For both constructors:

- Resolve and validate on each new connection. Pass one of those **same vetted
  IP addresses** to `Eio.Net.connect`; checking DNS and then letting Cohttp
  resolve the hostname again leaves a DNS-rebinding race.
- Use `Cohttp_eio.Client.make_generic` with that checked connector. Preserve the
  original hostname for HTTP `Host` and TLS SNI/certificate hostname verification.
  Never bypass certificate verification, and do not honor proxy settings that
  could move the actual destination outside the checked connector.
- Disable automatic redirects in v1. Return a 3xx response or a policy denial;
  any later redirect-following helper must re-enter the same URI/DNS/connect
  checks per hop, have a hop cap, and must not forward credentials to a new
  origin.
- Treat caller `max_response_bytes` as a further restriction, not an override.
  Stream with a hard decoded-byte cap and abort when it is exceeded; a
  `Content-Length` precheck is only an optimization.
- Apply a total operation timeout with `Eio.Time.Timeout`, covering DNS, connect,
  TLS, headers, and body. Use the per-request `Switch.t` required by Cohttp-Eio
  and close flows/resources on every result path.
- Reject malformed/header-injection values. Never log authorization/cookie/proxy
  headers, request or response bodies, URI userinfo, or query strings.

Outbound HTTPS is not supplied by an inbound TLS gateway. M3 must add and pin an
OCaml TLS implementation (`tls-eio`) and certificate roots (`ca-certs`), or keep
HTTPS unimplemented and fail construction loudly; an `http`-only implementation
is not a completed M3 and cannot serve seekwright's providers.

Unit tests use real loopback endpoints for the fixed-endpoint policy, a mock or
vendored DNS/connect layer for deterministic rebinding/IP tests, oversized and
chunked bodies, slow headers/bodies under a mock clock where possible, redirect
chains, and credential/redaction cases. Public-web tests must not depend on the
machine's actual resolver or the public internet.

## 6. Decorators, effects, and retention limits

Use Eio direct style and structured concurrency. mcp-kit 0.2.0 classic tool
handlers are synchronous `Yojson.Safe.t -> (result, string) result`; Eio's direct
style lets an authority operation perform bounded I/O in the calling fiber.
There is no `Lwt`/async result in the core API.

v1 provides only decorators with well-defined scope:

```ocaml
val with_operation_timeout :
  Eio.Time.Timeout.t -> 'kind Authority.t -> 'kind Authority.t

val with_log :
  sink:(Event.t -> unit) -> 'kind Authority.t -> 'kind Authority.t
```

Verified at M0: these two decorators are declared when they are implemented, not
before. An endo-function on an abstract grant can always be written as the
identity, so a stub would compile, match the signature, and promise a bound it
never applies.

An operation timeout is not a whole-tool deadline: several sequential operations
each get their own bound. `Event.t` contains constant operation names and bounded
metadata, never secrets or content; the application supplies the stderr sink.
Do not add a generic operation budget until there is a genuine request/factory
scope. A counter stored in a server-lifetime grant is a server-lifetime budget,
not a per-request one.

Do not introduce an `Effect.Deep` test handler: plain closure calls perform no
custom effect to intercept. Tests use recording sinks and deterministic network/
filesystem fixtures. If custom effects are reconsidered later, their cancellation,
one-shot continuation, typed-error, and composition semantics need a separate
design.

Grants can be retained in closures by trusted tool code and used later or from
another fiber. Operation timeouts still apply after retention, but v1 does not
revoke per-request authority or impose per-request budgets because registration
closes over one server-lifetime grant and mcp-kit owns its sessions internally.
Per-session/request grant factories require an mcp-kit request-construction hook
and a real use case; they are not promised by this plan. OxCaml uniqueness and
locality modes are out of scope, not a substitute for that missing lifecycle.

## 7. Transport and lifecycle contract

Verified mcp-kit 0.2.0 entry points:

```ocaml
Mcp_kit_stdio.run_channels server stdin stdout
Mcp_kit_cohttp_eio.handler ~max_body_size:1_048_576 server
```

The stdio adapter needs channels. The HTTP adapter returns a `Cohttp_eio.Server.t`
callback to pass to `Cohttp_eio.Server.run`; it is not a runnable server by
itself. The example must put transport construction and the server loop under the
same outer `Switch.run` that owns grant resources. Startup/declaration failures
go to stderr with a nonzero exit; stdio carries only protocol bytes.

The Cohttp-Eio adapter already bounds request bodies (default 1 MiB), validates
modern Streamable HTTP routing headers, and handles Origin checks. Pin the body
limit explicitly in the example. Inbound `Host` policy is application/gateway
code, not the outbound `Net` authority; inspect the request at the surrounding
Cohttp route when seekwright ports its Host allowlist.

mcp-kit 0.2.0's HTTP adapter dispatches on the shared server and does not expose
a callback to build authority per session. This is compatible with v1's
server-lifetime policy. Cancellation notifications and arbitrary handler
cancellation are not threaded through classic tool callbacks either, so only
Eio cancellation plus authority operation bounds may be claimed; no whole-handler
cancellation guarantee.

## 8. Testing and acceptance

### Core and capability tests

- **Tool adaptation.** Input schema failure, decoder failure after schema
  success, successful structured output, output-schema mismatch, duplicate tool,
  invalid declaration, and sanitized `run` error each have the MCP behavior
  specified above.
- **Grant isolation.** Two tools with the same input but different roots receive
  only their own data under interleaved calls. An unregistered tool cannot be
  called through MCP. This tests closure packing; it does not replace type tests.
- **Backend substitution.** Use two temporary roots, or an implementation-only
  test backend below the public `.mli`, to produce identical output with distinct
  fixtures. Public fake constructors must not weaken the external capability
  boundary.
- **Filesystem security.** The escape, race, byte/entry-bound, and error contracts
  in section 4.
- **Network security.** The DNS/connection-binding, TLS, redirect, timeout,
  bounded-streaming, header, and redaction contracts in section 5.
- **Concurrency.** Interleaved HTTP requests cannot mix grants, output, policy
  counters (if added later), or log events. One denied/slow/timed-out operation
  does not poison another request.

### Negative compilation that cannot pass for the wrong reason

`test/should_not_compile/` contains at least:

- `Registry.add registry read_source` with no `~grant`;
- `Registry.add registry read_source ~grant:net` with the wrong authority kind;
- an attempted external constructor for `Authority.Fs.t`;
- an attempt to call a core tool with an mcp-kit result or to bypass its decoder.

Each fixture has an expected compiler-diagnostic snapshot. The test fails if
compilation succeeds **or** fails with an unrelated error; merely using a dune
rule with "any nonzero exit means pass" is inadequate because missing modules and
syntax errors would make a false-positive test. Positive interface compilation
must run first. Bare `let _ = Tools.read_source` is valid OCaml and is not a
negative case.

### Wire tests and official conformance

- Replay modern requests over stdio and real loopback HTTP: modern request
  dispatch, `tools/list`, `tools/call`, decoder/tool errors, unknown tools,
  concurrent calls, and clean EOF. Compare JSON semantics rather than unrelated
  transport framing bytes.
- Include the legacy initialize/initialized lifecycle if the example advertises
  it, and test body-size/routing-header boundaries through the actual HTTP
  adapter.
- Pin `@modelcontextprotocol/conformance@0.2.0-alpha.11` and Node 22 for the live
  job. Record the exact scenario IDs and results, fail on runner errors, and
  compare against a checked-in baseline with no unexpected missing/extra IDs.
- The mcp-kit 37/37 result belongs to its full conformance fixture, including
  features outside `mcp-caps` v1. Do not claim 37/37 for an echo/read-source
  server. Report the scenarios applicable to this fixture, with explicit
  exclusions; a separate upstream smoke run may verify the development setup.

## 9. Milestones

Every milestone runs `opam exec -- dune build @install` and
`opam exec -- dune runtest`; later milestones retain all earlier tests.

| | Deliverable | Exit criterion |
|---|---|---|
| M0 | Workspace + direct mcp-kit echo over stdio | Exact `mcp-kit` constraints resolve; modern discover/list/call and legacy initialize/initialized/call transcripts work through a real client or Inspector; no capability code yet |
| M1 | Core `Error`/`Tool`/`Registry`/`Server`, `Fs`, `with_root`, echo + `read_source` | Core has no mcp-kit imports; typed decode/output/error tests pass; filesystem escape/race/bounds tests pass; negative compilation checks diagnostics, not just exit status |
| M2 | Same registry over Cohttp-Eio loopback | Same semantic tool transcript over stdio and HTTP; body/routing-header bounds exercised; resource lifetime and concurrent-client tests pass |
| M3 | `Net`, endpoint/public-web policies, operation timeout, logging | DNS-to-connect binding and HTTPS verification tests pass; redirect/body/time bounds hold; no unimplemented HTTPS path is called complete |
| M4 | Reusable docs, examples, pinned live conformance | Installable public interfaces documented; threat boundary and grant retention stated; exact applicable scenario baseline green; fallback still builds as an M0-style example |

**M0 landed 2026-11-10.** `dune-project` (two package stanzas; `seekwright` is
`(allow_empty)` until P1), `lib/caps/` carrying the §3 signatures — `Authority`
and `Policy` answer `Error Unavailable` naming the milestone that implements
them, rather than handing back an unconstrained grant — `examples/echo.ml`
(direct mcp-kit, the fallback path) and `examples/caps_echo.ml` (the same tool
through `Registry.add ~grant:()` and `Server.of_registry`), and six alcotest
suites. Both echo paths answer the legacy
`initialize` / `notifications/initialized` / `tools/list` / `tools/call`
transcript and a modern `server/discover` + `_meta` call over stdio; a rejected
input arrives as `isError`, an unknown tool as a JSON-RPC error. The core
signatures were built alongside M0 rather than at M1, so M1's own exit criterion
(typed decode/output/error behaviour, `Fs`, `with_root`, `read_source`) is still
open.

Implementation order inside M1 is core-with-echo first, then `Fs`; this isolates
existential/adapter type errors from filesystem security errors. `Proc` is a
post-M4 addition with executable allowlisting, no shell, explicit environment,
working-directory policy, stdin/stdout/stderr caps, timeout, and process-group
cleanup. Do not add it speculatively.

## 10. Dependency and compatibility policy

Use OCaml >= 5.1, dune >= 3.11, and exact `= 0.2.0` dependencies for every
mcp-kit component in `dune-project`. Verified at M0: the stdio adapter is the
`mcp-kit.stdio` findlib library shipped inside the `mcp-kit` package, not an opam
package of its own, so the exact `mcp-kit` constraint is what pins it, and an
executable asks for it with `(libraries mcp-kit.stdio)`. Dune package constraints pin the dependency
version; an opam switch pin is a separate environment operation, not a dune
stanza. Keep the installed core/adapter versions in lockstep. Recheck the public
interfaces and conformance evidence before any upgrade rather than accepting a
pre-1.0 minor bump silently.

Initial dependencies: `mcp-kit`, `eio`, `yojson`, `uri`, `alcotest` (tests), and
the Cohttp-Eio transport only in examples/applications. M3 adds `cohttp-eio` to
`mcp-caps`, `ipaddr` for address classification, `tls-eio`, and `ca-certs`.
Avoid a logging-framework dependency by exposing the bounded `Event.t` sink.
TLS for inbound HTTP remains gateway/application policy; that does not remove
the outbound HTTPS requirement above.

`plans/infra-setup.md` records the current M0–M2 environment and the additional
M3 TLS requirement. Package constraints belong in `dune-project`; setup
instructions record the verified switch separately.

## 11. The honest comparison to the Flix version

The Flix spec's "it does not compile otherwise" is a type-and-effect claim
through higher-order code. This plan gets a narrower first half: capability API
misuse fails to type-check, authority constructors centralize confinement, and
registration makes widening visible. It explicitly does not track arbitrary
effects, revoke retained grants, or sandbox malicious tool code. That boundary
belongs in the README and API docs so the useful guarantee is not oversold.
