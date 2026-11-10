# Capability-Gated MCP Server: OCaml 5 Plan

Status: draft, v1. Iterate here before building.

## 0. Framing and fallback

This layer is partly a learning exercise — a first OCaml MCP server — and its
success shape is a **library others can build MCP servers on**, not a one-off.
So the design rule is: keep the registry/policy layer separable from `mcp-kit`,
with mcp-kit behind one adapter module. If the capability layer turns out not to
earn its keep, the exit is planned, not improvised: drop `registry.ml`/`policy.ml`
and bind tools to `mcp-kit` directly, keeping the transports and conformance
baseline. The milestones are sized so M0–M1 alone already produce a working
server, which is what makes that exit cheap at any point.

Correction that shapes the plan: there **is** a maintained OCaml MCP library —
`mcp-kit` by Mathias Bourgoin at Nomadic Labs (GitLab), MIT licensed, opam 0.2.0,
last activity 2026-11-07 ([opam](https://opam.ocaml.org/packages/mcp-kit/),
[README](https://gitlab.com/nomadic-labs/ai-harness/ocaml-mcp/-/raw/main/README.md),
retrieved 2026-11-10). It supports the 2026-07-28 request model, ships
`mcp-kit-stdio`, `mcp-kit-eio` and `mcp-kit-cohttp-eio` adapters, compiles JSON
Schema 2020-12 locally, has a PPX for typed tool declarations, and records 37
passes / 0 failures against the official compliance scenarios.

So the plan is not "write an MCP server in OCaml". It is "write the capability
layer that nobody has, on top of the transport and protocol that somebody does".

**Goal.** A policy layer over `mcp-kit` where a tool cannot perform I/O unless
the registry supplies an unforgeable grant, enforced by the module system rather
than by convention. Transport, protocol, schema validation and conformance come
from `mcp-kit`.

**Non-goals.** Protocol implementation. Transports. JSON Schema. OAuth (out of
scope, gateway). Resources, prompts, subscriptions (mcp-kit has them; we do not
gate them in v1).

## 1. Architecture

```
mcp-kit-cohttp-eio ─┐
mcp-kit-stdio ──────┼─→ mcp-kit Server ──→ Registry (ours)
mcp-kit-eio ────────┘                        │
                                             ↓ looked up at call
                                    ('caps, 'a) Tool.t
                                             │ applied to
                                        grant : 'caps
                                    built only by Policy
                                             │
                                     Fs | Net | Proc (abstract)
```

The registry is the only place where a grant is applied to a tool. One line per
tool, and the line names the grant.

## 2. Layout

Root dune workspace (decided in `project-structure.md`); `mcp-caps` is the
package, `seekwright` comes later and depends on it:

```
dune-project                     # (package (name mcp-caps) ...) — generates mcp-caps.opam
mcp-caps.opam                    # generated, committed, never hand-edited
lib/caps/                        # (library (name caps) (public_name mcp-caps)) → Mcp_caps
  error.ml / .mli                # Denied | Invalid | Failed
  authority.ml / .mli            # Fs, Net, Proc: abstract types, no constructors
  tool.ml / .mli                 # ('caps, 'a) Tool.t and make
  registry.ml / .mli             # add ~grant, uniform element type
  policy.ml / .mli               # with_root, with_host_allowlist, with_deadline, ...
  server.ml / .mli               # the only module that knows mcp-kit:
                                 #   Registry.t -> Mcp_kit.Server.t via Server.create/add_tool
examples/                        # demo server (echo, then gated read_source) —
                                 #   one Registry.add line per tool, the audit surface;
                                 #   bin/main.ml belongs to the seekwright package later
test/
  dune                           # alcotest suites
  should_not_compile/            # dune rules expecting failure
```

## 3. The capability model

`authority.mli` exports types with no constructors and functions that only
consume them. Nothing in the program can make an `Fs.t` except
`Policy.with_root`.

```ocaml
(* authority.mli *)
module Fs : sig
  type t
  (** Abstract. The only producer is [Policy.with_root]. *)

  val read_file : t -> string -> (string, Error.t) result
  val list_dir  : t -> string -> (string list, Error.t) result
end

module Net : sig
  type t
  val get : t -> Uri.t -> (string, Error.t) result
end

module Proc : sig
  type t
  val run : t -> string list -> (string, Error.t) result
end
```

A tool declares the authority it needs in its type:

```ocaml
(* tool.mli *)
type ('caps, 'a) t

val make :
  ?title:string ->
  description:string ->
  input:Yojson.Safe.t ->
  validate:(Yojson.Safe.t -> (string, string) result) ->
  run:('caps -> Yojson.Safe.t -> ('a, Error.t) result) ->
  string ->
  ('caps, 'a) t
```

Registration is the grant:

```ocaml
(* registry.mli *)
type t
val empty : t

val add : t -> ('caps, 'a) Tool.t -> grant:'caps -> t
(** ['caps] is instantiated per call, so tools with different authority
    coexist in one registry without the grants escaping. *)
```

Usage in the demo server under `examples/`, which is the audit surface:

```ocaml
let tools =
  Registry.empty
  |> Registry.add Tools.read_source
       ~grant:(Policy.with_root "/srv/project")
  |> Registry.add Tools.search_web
       ~grant:(Policy.with_host_allowlist [ "api.example.com" ])

let () =
  let server = Server.of_registry ~name:"example" ~version:"1.0" tools in
  match Sys.getenv_opt "MCP_TRANSPORT" with
  | Some "http" -> Mcp_kit_cohttp_eio.handler server  (* cohttp-eio route wiring *)
  | _ -> Mcp_kit_stdio.run_channels server
```

(Transport entry points verified against the mcp-kit 0.2.0 README:
`Mcp_kit.Server.create ~name ~version ()`, then `Mcp_kit.Server.add_tool`
per tool — `Server.of_registry` folds the registry over `add_tool`, closing
each tool's handler over its grant. Note the README's "a server value can
serve concurrent clients": per-session servers are open question 1 below.)

What this buys: a tool cannot read a file unless `Registry.add` was given an
`Fs.t`; you cannot obtain an `Fs.t` except through a policy constructor; widening
a tool's power is a visible edit to a `Registry.add` line.

What it does not buy (write this down rather than discover it): a tool handed an
`Fs.t` can retain it in a closure and use it later or from another fiber. OCaml
has no linear types, so "cannot call without a grant" is enforced but "cannot
hoard a grant" is not. Two partial mitigations: make every grant a wrapper that
checks a deadline and a per-request budget at each operation, and scope grants
per session rather than per process. Closing the hole properly is OxCaml's
uniqueness and locality modes — a larger commitment than this project warrants.

## 4. Where effects go, and where they don't

In v1, nowhere custom. Use Eio's structured concurrency for cancellation and
line-per-connection, and implement deadline, budget and logging as plain values
carried in the grant record. `Effect.Deep` is available and untyped; hand-rolling
a handler stack buys syntax, not guarantees, at the cost of one-shot continuation
discipline.

The one place a custom handler earns its keep is the test harness: an
`Effect.Deep` handler that intercepts grant operations to record a trace, so
"this tool tried to open `/etc/passwd` and was denied" becomes an assertion
rather than a mock.

## 5. Policy combinators

```ocaml
(* policy.mli *)
val with_root : string -> Authority.Fs.t
(** Chroots. [..] and absolute escapes rejected after normalisation. *)

val with_host_allowlist : string list -> Authority.Net.t
(** Scheme and host checked per request; redirects to unlisted hosts refused. *)

val with_deadline : float -> 'a -> 'a
(** Wraps any grant so each operation checks the clock. *)

val with_budget : int -> 'a -> 'a
(** Caps operations per grant instance. *)

val with_log : 'a -> 'a
(** Every operation to stderr. Never stdout. *)
```

Because every grant is an abstract record of closures, `with_deadline` and
`with_budget` are generic wrappers, not per-authority code.

## 6. Testing

- **Capability behaviour, alcotest.** `with_root "/tmp/x"` plus
  `read_file "../../etc/passwd"` returns `Denied`. Table-driven over path shapes.
- **Grant isolation.** Two registries, one with `Fs`, one without; assert the
  second cannot call a tool that needs it.
- **Handler swap.** Same tool, grant backed by a real root and by an in-memory
  fake; identical JSON out, different side effects.
- **Should-not-compile.** `test/should_not_compile/` holds snippets like
  `let _ = Tools.read_source` (unapplied) and `Registry.add r t` (missing
  `~grant`), with a dune rule that compiles each and expects failure. This is the
  only test that checks the actual claim.
- **Conformance.** Run the official scenarios against your binary and compare to
  mcp-kit's 37/37 baseline. Any regression is your layer, not theirs.

## 7. Milestones

| | Deliverable | Exit criterion |
|---|---|---|
| M0 | `mcp-kit` echo server on stdio | Inspector connects. Half a day, because the protocol is not yours. |
| M1 | `Authority.Fs` + `Policy.with_root` + `read_source` | Escape tests pass; the missing-grant snippet fails to compile |
| M2 | HTTP via `mcp-kit-cohttp-eio` | Same transcript over HTTP; confirm body bounds and routing headers are the library's |
| M3 | `Net`, `Proc`, wrappers, logging | Budget and deadline enforced under a looping client |
| M4 | Conformance + docs | 37/37 or better; README states the retention limitation |

## 8. Open questions as spikes

1. **Per-session grants (blocking M2).** The mcp-kit README states one server
   value serves concurrent clients, with a session per connection. If authority
   must vary per client, the `Mcp_kit.Server.t` must be built per connection,
   not per process. Spike this before M2 — the one item that can invalidate the
   design. (v1 does not need per-client authority: one deployment, one
   operator's keys — but the spike decides whether the library can ever offer
   it.)
2. **Context threading.** Whether `Registry` can be parameterised by a request
   context, or whether grant-fixing must happen at server construction.
3. **Inbound header access.** The host allowlist is outbound. If inbound `Host`
   rejection is also wanted, confirm the cohttp-eio adapter exposes headers.
4. **`mcp-kit` 0.2.0 API stability.** One maintainer, pre-1.0. Vendor or pin it.
5. **OxCaml modes**, only if grant retention turns out to matter in practice.

## 9. Dependencies

OCaml 5.1+ (mcp-kit's floor), dune, `mcp-kit` 0.2.0 (the stdio adapter ships
inside it as the `mcp-kit.stdio` library / `Mcp_kit_stdio` — it is **not** a
separate opam package), `mcp-kit-cohttp-eio` 0.2.0, `eio`, `cohttp-eio` 6.3.0,
`yojson`, `alcotest`, `logs`. Exact verified install: `plans/infra-setup.md`.
TLS is the gateway's job, which is also what mcp-kit's own docs recommend.

## 10. The honest comparison to the Flix version

The Flix spec said "it does not compile otherwise" and meant it in the
type-and-effect sense, including through higher-order code. This plan gets the
first half of that claim honestly, via abstraction, and explicitly gives up the
second half. If the second half is the thing that interested you, this plan will
feel like a compromise — and that is the correct feeling. If the first half plus
a maintained, conformance-tested protocol layer is enough, this is the version
that ships.
