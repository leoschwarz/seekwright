# `mcp-caps`

A small OCaml library on top of [mcp-kit](https://opam.ocaml.org/packages/mcp-kit/):
a tool declares the authority its operations need, registration supplies an
abstract **grant** of exactly that type, and policy constructors own filesystem
and network confinement. It is not another MCP implementation — protocol,
schema validation, transports and the wire contract stay mcp-kit's.

```ocaml
(* under the switch that owns the grant, as examples/read_source.ml does *)
match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) "/srv/src" with
| Error error -> Error error
| Ok confinement ->
    let grant =
      Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement
    in
    Registry.add Registry.empty read_source ~grant
```

`examples/read_source.ml` (filesystem), `examples/gated_search.ml` (network),
`examples/caps_echo.ml` (no power at all, `~grant:()`) and
`test/conformance/fixture.ml` are the four worked servers; every fact below was
verified through one of them or through a test named beside it.

## The guarantee, stated exactly

**A tool cannot invoke `Authority` operations without a grant of the right kind,
and widening those operations is visible at registration.** `Authority._ t` is
abstract with no exposed constructor, its phantom kind (`fs`, `net`) is what
`Registry.add ~grant` matches a tool's `'caps` against, and each kind has one
public producer of the confinement decision behind it: `Policy.with_root` for
`Fs`, `Policy.with_endpoints` / `Policy.with_public_web` for `Net`. `test/should_not_compile/` holds thirteen fixtures whose compiler diagnostics are
pinned, so "register without a grant", "register with the wrong kind",
"pattern-match a grant open", "build the confinement record yourself", "register
the decision instead of the grant", "return an `Mcp_kit.Tool.result`", "call the
raw filesystem or network operation" and "write the bounds record an operation
takes" are type errors on this compiler, not conventions. One of them,
`grant_path.ml`, is the positive half: the intended grant path still type-checks
for a consumer of the installed package, so those twelve refusals close the
bypass without breaking the seam.

The low-level layer is sealed two ways, because its records are not equally
shareable:

- `policy_fs` and `controls_raw` are dune `private_modules`, so `dune build
  @install` files their interfaces under `.private/` and out of a consumer's
  search path: `Mcp_caps.Policy_fs.read_file` — a file read with no grant, no
  bound and no audit line — fails to resolve for anyone using the installed
  `mcp-caps`. That boundary is what `should_not_compile/` mirrors. Inside this
  checkout it is a rule rather than a compiler error, because dune's own build
  does resolve a private module and no dune field stops it (`root_module` aliases
  a library's *dependencies*, not its own modules); `test_caps_audit.ml`'s
  "nothing outside caps names the sealed layer" is the guard that keeps the rule.
- The operations are sealed on their argument as well, which holds in both views:
  each takes `controls:Controls_raw.t`, a record with no interface file and no
  producer outside `Authority`, so `raw_fs_call_needs_bounds.ml` fails even with
  `Policy_fs` in scope. In a running program the only bounds record is the one
  inside a grant.
- `policy_net` stays public: its `request`, `response`, `method_` and `endpoint`
  records are the vocabulary a `Net` call is written in, and a private module's
  records cannot be built or read by an installed consumer — hiding the module
  broke the *intended* grant path in the first probe of that shape. What seals
  its `request` is the `controls:Controls_raw.t` argument, whose type cannot be
  named.

**This is not a sandbox for arbitrary OCaml.** Nothing here stops tool code from
calling `Unix`, `Sys`, `Eio`, a C binding, `Obj.magic` or an HTTP library
directly; abstract types bind only code that respects the interfaces. The claim
is design-time and audit — a reader who wants to know what a tool may touch finds
one `Registry.add ~grant` line per tool — and it is the claim
`plans/capability-gated-mcp-server.md` §0 makes. Anyone who wants "a tool cannot
perform I/O" has to build that out of process isolation, not out of this module.

## Grants are retained, not consumed

OCaml 5.3 has no linear, affine or uniqueness types in the compiler, so a grant
handed to `run` can be captured in a closure, stored, and used later — including
from another fiber, and after the tool call that received it has returned. What
still applies to a retained grant is its own bounds: the operation timeout, the
byte and entry ceilings, the address policy, and the caller-supplied
`Budget.t` that `Authority.with_operation_budget` spends. What does **not**
exist in v1:

- **revocation.** A grant is a server-lifetime value. There is no way to take a
  power back once registered.
- **a per-request or per-plan grant.** Registration closes over one grant value.
  A per-request factory needs an mcp-kit hook for building a server per session
  or per request; mcp-kit 0.2.0's HTTP adapter has none, and its `session` value
  is unsynchronised mutable state that must not be shared across connections
  (§7's spike, pinned by `test/test_http_transport.ml`). Per-*connection*
  authority is available today without any upstream change — one listener per
  policy, or eight lines of accept loop over `Cohttp_eio.Server.callback` — and
  it is keyed on transport-level identity, never on the request.
- **a per-request budget inside a grant.** That would be a server-lifetime
  budget wearing a per-request name, so the counter is the caller's
  (`Budget.make n`) and the grant only spends it.

OxCaml's uniqueness and locality modes are a different language's answer to this
and are out of scope, not a substitute for the missing lifecycle hook.

## Dropping the layer

If the capability layer does not earn its keep, delete `registry.ml`, `policy.ml`
and `server.ml` and bind tools to mcp-kit directly: `examples/echo.ml` is that
server, kept runnable on purpose, and `Mcp_caps.Server.of_registry` returns a
plain `Mcp_kit.Server.t`, so resources, prompts and subscriptions — which
`Registry` does not cover — are already added by calling mcp-kit on the value the
adapter hands back (that is what `test/conformance/fixture.ml` does). Transports,
the protocol baseline and the Eio lifecycle contract are unaffected by that
choice: they were never the layer's.

## API, with where each part is verified

| Module | Surface | Verified by |
|---|---|---|
| `Tool` | `make ?title ?description ?output_schema ~input_schema ~decode ~run name`; `Output.text ?structured_content` | `test_tool.ml`, `test_server.ml` |
| `Registry` | `empty`, `add ~grant` (`Duplicate_tool`), `entries`, `find`, `entry_*` accessors | `test_registry.ml`, `test_grant_wiring.ml` |
| `Server` | `of_registry ~name ~version` → `(Mcp_kit.Server.t, build_error)`; validates every declaration before returning | `test_server.ml`, conformance run |
| `Authority.Fs` | `of_confinement ~mono_clock`, `read_file ?max_bytes`, `list_dir ?max_entries` | `test_authority_fs.ml` (both Eio runners), `test_grant_wiring.ml` |
| `Authority.Net` | `of_confinement ~mono_clock`, `request ?max_response_bytes` with `request`/`response` records | `test_authority_net.ml` (21 cases) |
| `Authority` decorators | `with_log ~sink`, `with_operation_timeout`, `with_operation_budget` — generic over `'kind` | `test_authority_net.ml`, `test_authority_fs.ml`, `test_caps_budget.ml` |
| `Policy` | `with_root`, `with_endpoints`, `with_public_web`, the `endpoint` record, the three default ceilings | the two authority suites |
| `Error` | `kind` (`Denied`/`Invalid`/`Unavailable`/`Timeout`/`Failed`), sanitized `message`, `render` | `test_error.ml` |
| `Event` | one bounded, content-free audit record: operation, outcome, optional byte count, ≤`max_notes` notes | `test_event.ml`, `test_caps_audit.ml` |
| `Budget` | the caller-owned counter: `make`, `limit`, `remaining`, atomic `take` | `test_caps_budget.ml` |

`Policy_fs` and `Controls_raw` are in the table's last column for a reason: they
are the layer's inside, not its surface. The bounds record is applied by
`Controls_raw.run`, the one place the budget is spent, the timeout is applied and
the audit event is written, so no operation can be bounded differently from its
siblings by forgetting a line of its own — and no consumer can choose its own
bounds, because there is no value of that type to pass. An application that wants
audited grants takes the decorators: `Authority.with_log ~sink grant` (one
`Event.t` per operation), and the application owns where the line goes.

The core modules import no `mcp-kit` at all — `test_core_no_mcp_kit.ml` walks the
library's sources to keep that true — so the layer stays separable from the
library it adapts.

## The contract an application owns

`mcp-caps` never calls `Eio_main.run`: a grant's resources belong to the loop
that opened them, so **the transport loop runs inside `Eio_main.run`, under the
same `Eio.Switch.t` that owns the grants**. `Mcp_kit_stdio.run_channels` and
`Mcp_kit_cohttp_eio.handler` are both fine there and both shown in the examples.
Startup problems go to stderr and a nonzero exit, because stdout is the JSON-RPC
channel. Body limits, routing-header checks and Origin protection are mcp-kit's
adapter's, not this layer's; an inbound `Host` allowlist and inbound TLS are
application or gateway policy.

## Conformance status

`test/conformance/README.md` records the live run against the official
`@modelcontextprotocol/conformance@0.2.0-alpha.11` server suite: the
capability-backed fixture passes **19 of the 37 required 2026-07-28 scenarios**,
with the other 18 classified check-by-check as gaps in this library's declared
v1 surface; mcp-kit's own fixture, run through the same wrapper in the same
switch, passes **37 of 37**, which is what makes the 19 a statement about the
layer rather than about the setup. The official runner has no stdio mode, so the
stdio half is pinned in-tree by `test/conformance/dune`.

## Versions

`mcp-kit` is pinned exactly at `0.2.0` in `dune-project` — it is pre-1.0 and it
owns the wire contract, so recheck the public interfaces and the conformance
evidence before any bump. OCaml >= 5.1, dune >= 3.11. The library links
`cohttp-eio`, `http`, `ipaddr`, `domain-name`, `tls`, `tls-eio`, `ca-certs` and
`mirage-crypto-rng` for its outbound `Net` grant, and deliberately not
`mirage-crypto-rng.unix` (it pulls stdlib `unix`): installing a random generator
is the application's job, and `Policy_net.ensure_rng` fails grant construction if
none is installed.
