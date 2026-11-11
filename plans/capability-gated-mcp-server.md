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
  policy_fs.ml / .mli            # Fs grant impl (Eio.Path.open_subtree confinement) — M1
  policy_net.ml / .mli           # Net grant impl: allowlist, vetted connect, redirect refusal — M3
  budget.ml / controls.ml        # deadline/budget/log wrappers — M3
  README.md                      # library docs: real guarantees + grant-retention limit — M4
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

  val of_confinement : Policy_fs.t -> t
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

`Policy.with_root` does **not** chroot the process. It opens an Eio subtree, and
the grant built from that decision keeps every operation on the handle:

```ocaml
(* policy_fs.mli — the confinement decision, abstract outside its module *)
val with_root :
  sw:Eio.Switch.t ->
  ?max_read_bytes:int -> ?max_entries:int ->
  parent:_ Eio.Path.t -> string -> (t, Error.t) result
```

```ocaml
(* authority.mli — the value a tool is registered with *)
val of_confinement : Policy_fs.t -> Fs.t
val read_file : ?max_bytes:int -> Fs.t -> string -> (string, Error.t) result
val list_dir : ?max_entries:int -> Fs.t -> string -> (string list, Error.t) result
```

Landed 2026-11-10 as a third shape of candidate (a), forced by a cycle: the
confinement record (the subtree handle plus the two ceilings) lives in
`lib/caps/policy_fs.ml`, `t` abstract, and `Policy.with_root` re-exports it,
because `policy.mli` already names `Authority.Net.t` for the M3 constructors
while `authority.mli` has to name the witness for `of_confinement`. `policy_net.ml`
was private-to-`Policy` at M0 for the same reason. `Authority.Fs.of_confinement`
is the one labelled seam, and it is not a way to build a grant: the only producer
of a `Policy_fs.t` is `Policy.with_root`. Candidate (b) — a public constructor
over a subtree handle — compiles just as well and moves the audit question from
"who called `Policy.with_root`" to "who ever got an `Eio.Path.t`"; with the
witness abstract the audit answer is one grep, which is what
`test/should_not_compile/` holds open. Either way this is a design-time and audit
boundary, not a sandbox (§0).

Read at M3: the `Net` branch arrived with the same seam —
`Authority.Net.of_confinement ~mono_clock ?controls decision` — and `Authority`'s
`_ t` is a GADT over two empty-variant kind tags (`fs`, `net`) with `Fs`/`Net`
submodules whose `t` is `nonrec`. The grant's `request`/`response` records are
*destructive* aliases of `Policy_net`'s (`type request = Policy_net.request = {…}`):
a restated record would be a second nominal type, and a value built for one would
not be accepted by the other's operations. `confinement_is_not_a_grant.ml` is the
new guard: registering the decision rather than the grant is a type error.

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

**Landed 2026-11-10, in two shapes.** The constructors take no clock and return
the confinement *decision* — `(Policy_net.t, Error.t)`, exactly the `with_root`
shape §4 settled — because the monotonic clock belongs to the grant, not to the
allowlist: `Authority.Net.of_confinement ~mono_clock` is where the clock and the
kind's default per-operation bound enter, and `Eio.Time.Timeout.t` measures a
deadline on a monotonic clock so an NTP step or a VM resume cannot move every
deadline at once. A `clock:_ Eio.Time.clock` argument on the constructor would
have put a wall clock in a value whose only use for it is a timeout. `Policy_net.t`
is an existential (`T : 'tag confinement -> t`) because `Eio.Net.t` is
parameterised by the backend's resource tag, which a record type cannot bind.

The two constructors are two *trust models*, not two spellings of one check, and
that asymmetry is deliberate (§5's "one documented policy" is two documented
policies): `with_endpoints` pins **names**, so an operator who lists
`searxng.internal` or `127.0.0.1` has decided that destination is reachable and
this layer's job is only to make the connection really go to what that name
resolves to — which is how a self-hosted provider on a private network works at
all, and why a loopback test server is an ordinary `with_endpoints` fixture.
`with_public_web` decides **addresses**: every answer must be globally routable
unicast, outside `Policy_net.special_use`. `Ipaddr.is_global` alone is not that
policy — it calls `fc00::/7`, `128.0.0.0/16`, the whole of `0.0.0.0/8` and the
TEST-NET blocks global — so the table is hand-rolled over RFC 6890 and
`to_octets`, and the IPv6 unique-local row is what proved the table's prefix mask
keeps the *high* bits of the partial octet (`fd12:3456::1` was being allowed).

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
  (Read at M3: the body cap is exact — `Eio.Buf_read.of_flow ~max_size:(limit+1)`,
  refused rather than truncated, no `Content-Length` consulted. The response
  *header* block is the one bound in `Net` that is timeout-bounded rather than
  byte-bounded: `Cohttp_eio.Client` reads it at `max_size:max_int`, and closing
  that gap means capping at the flow level. Recorded in `policy_net.mli` as a
  known limit rather than fixed by patching upstream in a milestone that did not
  ask for it.)
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

**Read at M3, resolved.** What landed is the shape that sentence permits and not
the one it refuses: `Authority.with_operation_budget : Budget.t -> 'kind t ->
'kind t` where `Budget.t` is an atomic counter the *caller* makes (`Budget.make n`)
and hands over, so the thing that runs out has the caller's scope while the grant
stays a server-lifetime value carrying no counter of its own. It is spent once per
operation and a spent budget refuses with `Denied` before any I/O, which is what
makes the ceiling observable at the far end. What the counter bounds is the
*count* of operations, never their cost: a 1-byte read and a 1 MiB read each spend
one. Still not built, and still needing the mcp-kit request hook §7 says is
missing: a per-request or per-plan *factory* that hands a tool a fresh grant.
`examples/gated_search.exe --max-calls N` is the honest demo of a counter whose
scope is the process, and it prints that scope at startup rather than implying a
per-request one.

The three decorators are generic over `['kind]` because a grant is a confinement
decision *plus* a shared `Controls.t` (the sink, the timeout, the budget); they are
declared in `Authority`, beside the grant type they rewrite, for the reason §6
gives — an endo-function on an abstract grant that returns its argument compiles
and promises nothing — and `Policy` deliberately does not re-export them. Every
`Fs` and `Net` operation runs inside `Controls.run`, the one place the budget is
spent, the timeout applied and the audit event written, so no operation can be
bounded differently from its siblings by a forgotten line. `of_confinement`
installs the kind's default bound (5 s for `Fs`, 15 s for `Net`) unless the
application supplies `~controls`; `~controls:Controls.none` is how an operator
asks for an unbounded grant.

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
and a real use case; they are not promised by this plan. (Read at M2: the
per-connection half is available without any mcp-kit change, through
`Cohttp_eio.Server.callback`; the per-request half is not — see the M2 spike in
§7.) OxCaml uniqueness and locality modes are out of scope, not a substitute for
that missing lifecycle.

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

Verified at M1 in `examples/read_source.ml`: `Eio_main.run`, then
`Eio.Switch.run`, the grant opened on that switch, and
`Mcp_kit_stdio.run_channels server stdin stdout` inside it — which is what gives
mcp-kit's synchronous classic handler a fiber to do I/O in. `mcp-caps` itself
never calls `Eio_main.run`: `Eio_main`'s interface says a library must not, and a
second loop cannot own a handle the first opened. "The transport runs under the
switch that owns the grants" is therefore an application-side contract, stated in
`authority.mli` rather than enforced by the layer.

The Cohttp-Eio adapter already bounds request bodies (default 1 MiB), validates
modern Streamable HTTP routing headers, and handles Origin checks. Pin the body
limit explicitly in the example. Inbound `Host` policy is application/gateway
code, not the outbound `Net` authority; inspect the request at the surrounding
Cohttp route when seekwright ports its Host allowlist.

Verified through the real adapter at M2 rather than read off the mli, and
exercised by `test/test_http_transport.ml`, so none of it gets re-written here:
a body over `~max_body_size` is a 413 with an empty body and is never parsed; a
`~max_body_size` outside `1 … pred max_int` is an `Invalid_argument` at handler
construction. A modern request needs `Content-Type: application/json` and an
`Accept` that names both `application/json` and `text/event-stream`, plus
`MCP-Protocol-Version` equal to `params._meta["io.modelcontextprotocol/protocolVersion"]`,
`Mcp-Method` equal to the JSON-RPC method, and `Mcp-Name` equal to `params.name`
for `tools/call`, `prompts/get` and `resources/read`; a mismatch is HTTP 400 with
JSON-RPC -32020 and a missing protocol block is -32602, while a tool refusal is a
result and stays a 200. A schema property annotated `x-mcp-header` must also
arrive as an `Mcp-Param-<name>` header matching the argument — the adapter
derives that check from the input schema, so a widened schema can tighten the
wire contract with no server-code change. `GET`, `DELETE` and every other method
are 405. An `Origin` header is refused 403 unless it is in `~allowed_origins`
(default: none), the connection is then closed with `Rejected_origin` reported to
`Cohttp_eio.Server.run`'s `on_error`, and a request that sends no `Origin` is
unaffected — the allowlist is browser protection, not authentication, which is
where the Python server's Host allowlist stands too. A server with HTTP
subscriptions enabled needs a `~clock` or handler construction raises, and that
clock is also what drives 15-second SSE keepalives.

mcp-kit 0.2.0's HTTP adapter dispatches on the shared server and does not expose
a callback to build authority per session. This is compatible with v1's
server-lifetime policy. Cancellation notifications and arbitrary handler
cancellation are not threaded through classic tool callbacks either, so only
Eio cancellation plus authority operation bounds may be claimed; no whole-handler
cancellation guarantee.

**M2 spike (resolved 2026-11-10): can a `Server.t` be built per connection, so a
grant could vary per client?** Read from the installed 0.2.0 sources, and now
pinned by `test/test_http_transport.ml`:

- Not through mcp-kit. `Mcp_kit_cohttp_eio.handler ~max_body_size server` closes
  over one `Mcp_kit.Server.t` chosen at handler-construction time, and the cohttp
  callback it builds is `fun _conn request body -> …` — the connection argument
  is discarded, so there is no per-connection hook, let alone a per-request one.
- Nothing about the type forbids per-connection construction. `Mcp_kit.Server.t`
  is an immutable record (`info`, the four registration lists, `subscriptions`,
  `subscription_hub`); `add_*` returns a copy, and only `create` allocates a hub,
  which copies share. `Server.of_registry` is a fold of `add_tool`, so it costs
  list appends and no I/O — cheap for a tool surface this size, and still a cost
  per accepted connection.
- The hook exists one layer down, and using it reimplements nothing.
  `Cohttp.Generic.Server.S` exports `callback : t -> IO.conn -> IO.ic -> IO.oc ->
  unit IO.t`, which is the per-connection driver `Cohttp_eio.Server.run` hands a
  connection to. An application that runs its own accept loop — `Eio.Net.run_server`,
  which `Server.run` wraps thinly — can choose which `handler` value owns that
  connection. `one_listener_can_route_connections_to_different_grants` does
  exactly that: one listening socket, two servers, two filesystem grants, one
  connection each, and the library still owns the body bound, the routing
  headers, and the Origin check.
- What that choice cannot be based on is the request. At accept time the only
  fact about the caller is its address, so per-client authority is
  per-connection authority keyed on transport-level identity — a port per
  policy, a TLS client certificate, or a header a gateway adds, which would mean
  parsing the request before the adapter does. Deciding it per tool-call would
  mean duplicating the adapter's validation, and the paragraph above refuses
  that.
- The reason no per-connection state exists today is that the HTTP path is
  stateless: the adapter dispatches legacy bodies with `Server.dispatch_string`
  and modern ones with `dispatch_http_json_frames`, both on the shared value, and
  never calls `create_session`. A `session` is `{ server; mutable phase }` —
  unsynchronised mutable state, so it must never be shared across connections;
  stdio's `run_channels` makes exactly one per call, which is why the legacy
  initialize/initialized lifecycle is enforced over stdio and absent over HTTP
  (`stdio_enforces_the_legacy_lifecycle_and_http_does_not`).
- So v1 keeps server-lifetime grants, and the honest way to vary them today is
  one listener per policy. The upstream ask, if per-client authority ever becomes
  a goal rather than a non-goal (§0), is a `handler` that takes the server as
  `conn -> request -> Mcp_kit.Server.t` or exposes its callback so an application
  can compose per-connection dispatch without re-writing the validation. Revisit
  at M3, where the `Net` grant makes caller identity concrete.

## 8. Testing and acceptance

### Core and capability tests

- **Tool adaptation.** Input schema failure, decoder failure after schema
  success, successful structured output, output-schema mismatch, duplicate tool,
  invalid declaration, and sanitized `run` error each have the MCP behavior
  specified above.
- **Grant isolation.** Two tools with the same input but different roots receive
  only their own data under interleaved calls. An unregistered tool cannot be
  called through MCP. This tests closure packing; it does not replace type tests.
  M1 has this as `test/test_grant_wiring.ml`: one `read_source` declaration
  registered under two temporary roots answers each root's own file, refuses the
  other root's file with `unavailable:` and a path walk to a sibling with
  `invalid:`/`denied:`, and a registry built with only `~grant:()` does not
  advertise or serve `read_source` at all (the call comes back as a JSON-RPC
  error naming nothing).
- **Backend substitution.** Use two temporary roots, or an implementation-only
  test backend below the public `.mli`, to produce identical output with distinct
  fixtures. Public fake constructors must not weaken the external capability
  boundary. Landed 2026-11-10: that implementation-only backend is deliberately
  unavailable at the `Fs` level — there is no fake `Authority.Fs.t`, because
  `Policy_fs.t` is abstract and only `Policy.with_root` returns one, which is the
  boundary doing its job rather than an oversight. What M1 substitutes instead is
  (i) the real backend under two roots, and (ii) an in-memory grant of the
  *test's own* type registered through the same `Registry.add` path, which pins
  that nothing between `Registry.add` and the transport inspects a grant.
- **Filesystem security.** The escape, race, byte/entry-bound, and error contracts
  in section 4. M1 has `test/test_authority_fs.ml`: one table of path shapes run
  against both loop runners `Eio_main` picks (`EIO_BACKEND=linux`, the
  `openat2`/RESOLVE_BENEATH path, and `EIO_BACKEND=posix`), covering `..`,
  absolute paths, empty and `.` components, control characters, a symlink out of
  the root, a symlinked directory out of the root, a dangling symlink, symlinks
  that stay inside, the byte ceiling (over-limit files refused without being
  buffered) and the entry ceiling (counted while streaming). The
  rename/symlink-replacement race in section 4 is **not** tested at M1: the
  confinement is at open time, per component, so a rename between the kind check
  and the open cannot widen a grant, and no deterministic in-repo test for the
  race is claimed.
- **Network security.** The DNS/connection-binding, TLS, redirect, timeout,
  bounded-streaming, header, and redaction contracts in section 5.
- **Concurrency.** Interleaved HTTP requests cannot mix grants, output, policy
  counters (if added later), or log events. One denied/slow/timed-out operation
  does not poison another request. M2 has the grant-sharing half of this:
  `concurrent_clients_do_not_mix_answers` runs a read and a refusal
  simultaneously on one listener with one grant, and each answer stays itself;
  `two_listeners_do_not_share_a_grant` and
  `one_listener_can_route_connections_to_different_grants` pin which shapes do
  and do not vary a grant. The slow/timed-out half waits for M3, where the
  timeouts live.

### Negative compilation that cannot pass for the wrong reason

`test/should_not_compile/` contains at least:

- `Registry.add registry read_source` with no `~grant`;
- `Registry.add registry read_source ~grant:net` with the wrong authority kind;
- an attempted external constructor for `Authority.Fs.t`;
- an attempt to call a core tool with an mcp-kit result or to bypass its decoder.

Landed 2026-11-10, five fixtures, each with its diagnostic pinned:
`no_grant_label.ml` (the first bullet), `grant_type_mismatch.ml` (the second —
with `~grant:()`, since there is no `Net` grant to pass until M3, and the
property is the same: one tool's power cannot be swapped for another kind),
`mint_grant.ml` (pattern-matching the grant type to reach the confinement inside
it), `forge_confinement.ml` (a record with `Policy_fs`'s own field names, which
is still not a `Policy_fs.t`), and `mcp_kit_result.ml` (a tool returning
`Mcp_kit.Tool.result`, which is not a `Tool.Output.t`). The **decoder half of the
fourth bullet is not expressible** through the public interface and is not
pretended at: `Registry.entry_call` always decodes, and `Tool.run` taking the
already-decoded input is the documented test seam, not a route a server can be
built on; the "core never mentions mcp-kit" half is guarded by
`test/test_core_no_mcp_kit.ml`.

Each fixture has an expected compiler-diagnostic snapshot. The mechanism is a
dune rule per fixture with `(with-accepted-exit-codes (not (or 0)) …)` writing
the diagnostic to `<name>.out`, and one `(alias runtest)` rule `(diff …)`-ing it
against `<name>.expected`, so a snippet that starts compiling fails on its exit
code and a snippet that fails for a different reason fails on the diff;
`dune promote` re-blesses. The snippets are type-checked by a plain
`ocamlfind ocamlc` over `lib/caps`'s interfaces rather than by a dune stanza —
a stanza that does not compile fails the build instead of reporting a diff — and
the snapshots are the diagnostics of this compiler (5.3.0), so an OCaml upgrade
re-blesses them deliberately. The positive half runs first: the interface
compile is a dependency of every fixture, so a missing module or a syntax error
cannot be mistaken for the expected refusal. Bare `let _ = Tools.read_source` is
valid OCaml and is not a negative case.

### Wire tests and official conformance

- Replay modern requests over stdio and real loopback HTTP: modern request
  dispatch, `tools/list`, `tools/call`, decoder/tool errors, unknown tools,
  concurrent calls, and clean EOF. Compare JSON semantics rather than unrelated
  transport framing bytes.
- Include the legacy initialize/initialized lifecycle if the example advertises
  it, and test body-size/routing-header boundaries through the actual HTTP
  adapter.

Landed at M2: the seven-body legacy transcript is replayed over a stdio session
and over a loopback HTTP POST and compared as JSON (every answer byte-identical;
the notification is the only divergence — no line on stdio, an empty 204 over
HTTP), a modern `tools/call` is replayed over both with the routing headers the
adapter requires, and the body-size, `MCP-Protocol-Version`/`Mcp-Method`/
`Mcp-Name`, `Content-Type`/`Accept`, Origin and method boundaries are exercised
through the adapter rather than around it. Still open here: the decoder/tool-error
and unknown-tool cases over HTTP (pinned at M1 through the in-process dispatch),
clean-EOF behaviour, and the pinned official runner, which stays M4.
- Pin `@modelcontextprotocol/conformance@0.2.0-alpha.11` and Node 22 for the live
  job. Record the exact scenario IDs and results, fail on runner errors, and
  compare against a checked-in baseline with no unexpected missing/extra IDs.
- The mcp-kit 37/37 result belongs to its full conformance fixture, including
  features outside `mcp-caps` v1. Do not claim 37/37 for an echo/read-source
  server. Report the scenarios applicable to this fixture, with explicit
  exclusions; a separate upstream smoke run may verify the development setup.

Landed at M4, 2026-11-11, in `test/conformance/` and recorded in its `README.md`.
The pinned runner is `@modelcontextprotocol/conformance@0.2.0-alpha.11` under Node
22.23.4 (`plans/infra-setup.md`), and the 37-ID required manifest in
`requirements-2026-07-28-server.txt` is checked against
`conformance list --server --requirements 2026-07-28` before any scenario runs.
`run_live.sh` fails closed on missing, extra or duplicate IDs, on a runner error,
on an unexpected failure and on a stale baseline entry, and keeps the raw
`checks.json` per scenario.

The measured numbers, with the control run beside them because a number with no
control is not evidence:

| server | `--requirements 2026-07-28` |
|---|---|
| `test/conformance/fixture.ml` — six tools through `Registry.add`/`Server.of_registry`, resources/prompts through the direct seam | **19 pass / 18 fail / 0 inconclusive** |
| mcp-kit v0.2.0's own conformance fixture, built against this switch's mcp-kit 0.2.0 | **37 pass / 0 fail / 0 inconclusive** |
| `examples/read_source.exe`, `examples/gated_search.exe` as shipped | 8 pass / 29 fail each |

The 18 failures are classified check-by-check in
`expected-failures-2026-07-28-server.json`, and all of them name a v1 surface
this plan declares rather than a mcp-kit defect: rich tool content and progress
(`Tool.Output`, §3), and the SEP-2322 interactive-tool / `server-stateless`
diagnostics, which need an input-required result and per-request capability state
(§0 non-goals, §3, §6). The two shipped-example rows are the reason a fixture is
needed: all eight of their passes are scenarios that need no named declaration —
an empty `resources/list` validates — so they measure nothing about the layer.
The 13 scenarios the same command runs but does not score:
`http-header-validation`, `http-custom-header-server-validation` and
`json-schema-2020-12` now pass against the fixture — the last two are the most
useful unscored checks for this layer, because both are about a declared input
schema surviving `Tool.make` → `Registry.add` → `Server.of_registry` byte for
byte — and nine of the ten `tasks-*` extension scenarios fail for the fixture and for
upstream's fixture alike.
**The official runner has no stdio mode**: `conformance server` takes `--url`
and nothing else. The stdio half is therefore in-tree — `transcript.jsonl` of the
runner's own bodies replayed through `fixture.exe --stdio`, blessed as a diff of
both streams in `test/conformance/dune` — and it transfers to the HTTP run only
because `same_transcript_stdio_and_http` pins the two transports' answers as
byte-identical. Four fixture gaps found this way were closed in the same branch
(two prompts, `test_logging_tool`, and the two schema-declaration tools), which
moved the required tally from 17 to 19.

## 9. Milestones

Every milestone runs `opam exec -- dune build @install` and
`opam exec -- dune runtest`; later milestones retain all earlier tests.

| | Deliverable | Exit criterion |
|---|---|---|
| M0 | Workspace + direct mcp-kit echo over stdio | Exact `mcp-kit` constraints resolve; modern discover/list/call and legacy initialize/initialized/call transcripts work through a real client or Inspector; no capability code yet |
| M1 | Core `Error`/`Tool`/`Registry`/`Server`, `Fs`, `with_root`, echo + `read_source` | Core has no mcp-kit imports; typed decode/output/error tests pass; filesystem escape/race/bounds tests pass; negative compilation checks diagnostics, not just exit status |
| M2 | Same registry over Cohttp-Eio loopback | Same semantic tool transcript over stdio and HTTP; body/routing-header bounds exercised; resource lifetime and concurrent-client tests pass |
| M3 | `Net`, endpoint/public-web policies, operation timeout, logging | DNS-to-connect binding and HTTPS verification tests pass; redirect/body/time bounds hold; no unimplemented HTTPS path is called complete |
| M4 | Reusable docs, examples, pinned live conformance | Installable public interfaces documented; threat boundary and grant retention stated; exact applicable scenario baseline green; fallback still builds as an M0-style example. Landed 2026-11-11 — see the M4 note below and `test/conformance/README.md` |

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
signatures were built alongside M0 rather than at M1, so the core half of M1's
exit criterion (typed decode/output/error behaviour) was already met when M1
began; `Fs`, `with_root` and `read_source` were its own work.

**M1 landed 2026-11-10.** `lib/caps/policy_fs.ml` holds the confinement — the
subtree handle from `Eio.Path.open_subtree` plus the two ceilings — behind an
abstract `t`; `Policy.with_root` is the only producer and `Authority.Fs` the only
consumer (`read_file`, `list_dir`). Ceilings default to 65 536 read bytes and 200
directory entries; a caller `max_bytes`/`max_entries` clamps down, an operator
non-positive value is `Error Invalid` at construction, and going over either is
`Denied` rather than a truncated answer — an over-limit file is refused without
being buffered in full (`Buf_read.of_flow ~max_size`), and a directory listing is
counted while it streams (`Eio.Path.with_dir_entries`). `Eio` failures are mapped
once: `Not_found` → `Unavailable`, `Permission_denied`/`Symlink`/`File_too_large`
→ `Denied`, other `Eio.Io` → `Failed`, and `Cancel.Cancelled` / `Exn.Multiple`
propagate; no message carries the operator's root or `Eio`'s native path.
`Authority`'s GADT has no `Net` branch at all yet, so no `Net` grant exists
anywhere to register a tool with. `examples/read_source.ml` is the audit surface
(`ping` with `~grant:()`, `read_source` with the one subtree) and the worked Eio
contract: `Eio_main.run` → `Eio.Switch.run` → grant → `Server.of_registry` →
`Mcp_kit_stdio.run_channels`. Checked over stdio: an in-root read answers its
content, `path="escape"` (a symlink to `/etc/passwd`) answers `denied:`, and
`path="../../etc/passwd"` and `path="/etc/passwd"` answer `invalid:`; startup
notes go to stderr. `eio_main` 1.6 (with `eio_posix`/`eio_linux`) is now installed
in the `default` switch and declared `(eio_main :with-test)` — the examples and
the filesystem suite own a loop, the library does not. Tests: eight alcotest
suites (87 cases, the filesystem table run against both `EIO_BACKEND=linux` and
`EIO_BACKEND=posix`) plus the five negative-compilation fixtures above.

Implementation order inside M1 was core-with-echo (M0) and then `Fs`, which did
isolate the existential/adapter type errors from the filesystem ones. `Proc` is a
post-M4 addition with executable allowlisting, no shell, explicit environment,
working-directory policy, stdin/stdout/stderr caps, timeout, and process-group
cleanup. Do not add it speculatively.

**M2 landed 2026-11-10.** `examples/read_source.ml` now speaks two transports
from one `build`: stdio by default, Streamable HTTP on loopback with `--http
[<port>]`, where the listener is registered on the same `Eio.Switch.t` that owns
the subtree, `Mcp_kit_cohttp_eio.handler ~max_body_size` is wired in with the
body limit named in the example (1 MiB, the library default, pinned so an
upstream default change becomes a visible diff), and `on_error` renders
`Rejected_origin` as a named stderr event rather than an exception dump. The
same seven legacy JSON-RPC bodies answered byte-identically over both
transports, run against the binary and asserted in
`test/test_http_transport.ml` (`same_transcript_stdio_and_http`); the
initialized notification is the only divergence — no line on stdio, an empty
204 over HTTP — and it is framing. A modern `tools/call` answers the same JSON
over both once the HTTP routing headers are supplied
(`a_modern_call_answers_the_same_way_over_both_transports`).
`test/test_http_transport.ml` is the tree's only cohttp-eio listener and client
(ephemeral loopback port, `Eio.Net.listening_addr` to learn it, `~stop` promise
to close it, because `Eio.Switch.run` waits for the fibers it registered): 11
cases, covering the two-transcript parity, the adapter's body bound (413, empty
body, nothing parsed), its routing-header checks (400 with JSON-RPC -32020 on a
wrong `Mcp-Method`), its Origin allowlist (403, `Rejected_origin` in `on_error`,
and 405 rather than 403 once the Origin is listed) and method gate, two
listeners with two roots that cannot see each other's file, concurrent clients
on one listener that do not mix answers, and — for the open question in §7 —
one listening socket that hands different connections to different grants
through `Cohttp_eio.Server.callback`. mcp-kit owns every one of those checks;
the layer adds none of them. `dune-project` gains
`mcp-kit-cohttp-eio`, `cohttp-eio` and `http` as `:with-test` package
dependencies, matching how `eio_main` is handled: transports belong to
examples and tests, never to `mcp-caps` (§10). Neither inbound TLS nor a wider
Host allowlist belongs to the example; both stay gateway/application policy,
and seekwright's Host port is P8 work at the surrounding route.

**M3 landed 2026-11-10.** `lib/caps/policy_net.ml` holds the network confinement
behind an abstract existential `t`, with `Policy.with_endpoints` and
`Policy.with_public_web` the only producers and `Authority.Net` the only consumer
(`request`, one bounded HTTP exchange). An endpoint is matched as
(scheme, normalised host, effective port) *before* any name is looked up, so an
unlisted host costs no resolver traffic; `with_endpoints` normalises the list and
refuses a duplicate or a case-collision at construction rather than applying a
first-match rule. `Eio.Net.getaddrinfo_stream` answers the listed name, every
answer is filtered (`with_public_web` by the RFC 6890 table above), and
`Eio.Net.connect` is then called with one of **those vetted addresses**; the
`Cohttp_eio.Client.make_generic` connector ignores the URI it is handed and
returns that already-checked socket, so the client has no way to resolve the name
a second time — the DNS-rebinding fix §5 names, and
`connect_uses_the_vetted_answer` is the test that says so (one query per request,
and the connect's address is the vetted one). HTTPS is implemented, not stubbed:
`tls-eio` over the vetted flow with `ca-certs` as the trust anchor store and the
endpoint's own name as the peer name, so SNI and certificate hostname
verification stay on; both the trust store and `Mirage_crypto_rng` are read at
*construction*, so a deployment that cannot find them fails there instead of
holding a grant whose https path throws (§5). Installing a generator remains the
application's job, and `mirage-crypto-rng.unix` is therefore not linked into
`mcp-caps`: it pulls stdlib `unix`, which `test_core_no_mcp_kit` keeps out. One
`Eio.Switch.t` per operation closes the socket on every result path, including
when the byte ceiling or the timeout unwinds out of it. Redirects are never
followed; a 3xx whose `Location` names a target this grant would refuse is itself
`Denied`, naming only the target's host, because a `Location` can carry a query
string. The response body is streamed against `min(grant, caller)` bytes with
`Eio.Buf_read` and refused rather than truncated, with `Content-Length` trusted in
neither direction. Request headers and bodies are validated before they leave:
`host`, `content-length`, `transfer-encoding`, `connection`, `upgrade` and
`keep-alive` are the authority's, so a caller setting one is `Invalid`, and a name
or value that could split a request is `Invalid` without quoting the value.
`examples/gated_search.ml` is the network audit surface — `search_web` (the
operator's endpoint) and `fetch_url` (caller-chosen destination, same grant), both
registered with one `Net` grant through `Registry.add ~grant`. Checked over stdio
against a loopback target: the search answers with the authority's own `Host`
header, an in-list `fetch_url` is served, `http://localhost:8099/` answers
`denied:` because `localhost` is not the listed name, `http://169.254.169.254/…`
answers `denied:` before any lookup, and `--max-calls 2` answers `denied:` on the
third call with no I/O at all; every call leaves one line on stderr
(`caps.net.request ok bytes=120 status=200`) and none on stdout.
`test/test_authority_net.ml` is 20 cases over two fixtures: a real
`Cohttp_eio.Server` on loopback, which is where a round trip, the chunked-body
ceiling, a 3xx, an owned header and a cancelled wait are observable, and a
scripted `Eio.Net.Pi.network` whose `connect` raises `Simulated` carrying the
address it was asked for, which is the only way to prove the address binding and
that a refusal sends nothing at all. Nothing in the suite touches a real provider
or the machine's resolver (§5). `Authority`'s GADT now has both branches (`fs`,
`net`), and the grant's request/response types are destructive aliases of
`Policy_net`'s so a caller writes `Authority.Net.meth` without reaching past the
grant. `test/should_not_compile/` gained `confinement_is_not_a_grant.ml`
(registering the decision instead of the grant) and `grant_type_mismatch.ml` now
passes a real `Authority.Net.t` to an `Fs` tool. Ten alcotest suites, 118 cases,
plus the six negative-compilation fixtures.

**M4 landed 2026-11-11.** Two documents and one live run. `lib/caps/README.md` is
the library's own front door: the guarantee in one sentence and its boundary
stated as plainly as §0 states it (capability-mediated operations only; nothing
here stops tool code calling `Unix`, `Eio`, a C binding or `Obj.magic`), the
grant-retention limitation as a section of its own — OCaml 5.3 has no linear or
uniqueness types, so a grant captured in a closure stays usable, and v1 offers no
revocation, no per-request grant and no budget inside a grant, only the caller's
`Budget.t` — the fallback path (§0's "bind tools to mcp-kit directly", with
`examples/echo.exe` as the runnable proof and `Server.of_registry`'s
`Mcp_kit.Server.t` as the seam for resources and prompts), and the API table with
the suite that verifies each module.
`test/conformance/` is the pinned live conformance job described in §8: the
official runner at `0.2.0-alpha.11` under Node 22.23.4, this plan's 37-ID
manifest, mcp-kit's comparator and wrapper reused so the numbers are comparable
to its records, and a fail-closed gate over a per-check baseline. Real numbers,
control first: **mcp-kit v0.2.0's own fixture 37/37 through this wrapper** (so
the setup is not the variable), **the capability-backed fixture 19 pass /
18 fail / 0 inconclusive** with every failure classified as a declared v1 surface
gap, and **`examples/read_source.exe` and `examples/gated_search.exe` 8/37 each**
— eight passes that need no named declaration, which is why a fixture, not the
examples, is what measures the layer. Unscored-but-measured: `http-header-validation`,
`http-custom-header-server-validation` and `json-schema-2020-12` all pass, the
last two added during M4 because both ask whether a declared input schema reaches
mcp-kit unchanged, and nine of the ten `tasks-*` extension scenarios fail for our fixture (one reports all checks skipped)
and upstream's alike. Two findings to keep: **the official runner has no stdio
mode**, so the stdio evidence is the pinned transcript rule in
`test/conformance/dune` plus the transport-parity test, and four fixture gaps
found by running the suite were closed in this branch (two prompts,
`test_logging_tool`, and the two schema tools), which is the difference between
17 and 19. Ten alcotest suites and 119 cases still pass, the six
negative-compilation fixtures still refuse with their pinned diagnostics, and the
stdio transcript plus its stderr notes are blessed diffs.

**Open at M3: `Server.profile` is not an enforcement point.** Verified against
0.2.0's sources, `Capabilities.profile` has three members (`stdio`, `http`,
`net`), `Server.profile` narrows them — and the profile only ever reaches the
client through `server_capabilities` (`server.ml`'s `?profile`, defaulting to
`Profile.default`, and `Server.Stdio.serve ~profile`). `Tool.Registry.add` keeps
`permanent` and a closure and never consults a profile, and nothing in `Tool`,
`Handler` or `Server` rejects a registration outside it. So a `Net` grant is
scoped by the confinement and the grant wrappers, not by the profile: passing
`~profile` to a server that then registers a networked tool is a promise to the
client that the server does not keep. `Capability_set.of_list ["net"]` has no
validator either — the profile names the transports it will *try* to serve
(`net` is not one of them), it does not authorise a capability — and a name in
`Server.Flags.custom` is simply never advertised, not an error. Two options, both
for M5 rather than M3: the server filters registrations against its profile, or
the profile stops advertising what the process has not registered and the flags
are validated. Nothing here is a bug in mcp-kit — it is a field with no
consumer, and seekwright is the first caller to care.

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
the Cohttp-Eio transport only in examples/applications. M3 added to `mcp-caps`
itself: `cohttp-eio` and `http` (the message model and the client whose connector
the policy supplies), `ipaddr` and `domain-name` (the address and hostname
decisions), `tls`, `tls-eio` and `ca-certs` (outbound https — the outbound half is
ours even when an inbound TLS gateway is someone else's), and `mirage-crypto-rng`,
named only to *detect* a missing generator at construction. Those carry `>=`
constraints rather than exact pins: unlike mcp-kit, none of them owns a wire
contract this tree reproduces, so the version that travels is the switch's
(`plans/infra-setup.md`), and `mirage-crypto-rng.unix` — the sublibrary that would
actually install one — is deliberately absent from the library because it pulls
stdlib `unix`. Avoid a logging-framework dependency by exposing the bounded
`Event.t` sink. TLS for inbound HTTP remains gateway/application policy; that does
not remove the outbound HTTPS requirement above.

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
