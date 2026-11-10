(lang dune 3.11)

(name seekwright)

(generate_opam_files true)

(license MIT)

(package
 (name mcp-caps)
 (synopsis "Capability-gated tool registration for OCaml MCP servers")
 (description
  "A small layer over mcp-kit: tools declare the authority their operations need, registration supplies an abstract grant of exactly that type, and policy constructors own filesystem and network confinement.")
 (depends
  (ocaml
   (>= 5.1))
  ; mcp-kit is pinned exactly: it is pre-1.0 and owns the wire contract
  ; (plans/capability-gated-mcp-server.md §10). The stdio adapter is the
  ; mcp-kit.stdio findlib library inside this same package.
  (mcp-kit
   (= 0.2.0))
  (eio
   (>= 1.6))
  (yojson
   (>= 3.0.0))
  (uri
   (>= 4.0))
  ; The loop runner is only needed by the examples and the filesystem tests: the
  ; library itself stays loop-agnostic, because Eio_main's own interface says a
  ; library must not call run (plans/capability-gated-mcp-server.md §6). Its
  ; version travels with [eio]'s constraint above — this dune lang will not put a
  ; constraint and a flag on the same dependency. unix is deliberately not
  ; listed: it ships with the compiler, and no opam package of that name
  ; resolves.
  (eio_main
   :with-test)
  ; M2: the Streamable HTTP transport, like the loop runner, is linked only by
  ; the examples and the tests — never by mcp-caps itself, which stays a library
  ; an application puts its own transport around (§7, §10). At this dune lang a
  ; package dependency entry takes a version constraint or a flag, never both, so
  ; these ride the switch's pins (plans/infra-setup.md) rather than a "= 0.2.0"
  ; here; the exact pin that matters is mcp-kit's own, above.
  (mcp-kit-cohttp-eio
   :with-test)
  (cohttp-eio
   :with-test)
  (http
   :with-test)
  (alcotest
   :with-test)))

; The port's own package stanza. It has no library attached yet: seekwright
; arrives at P1 with lib/router.ml (plans/project-structure.md), and it depends
; on mcp-caps rather than the other way round, which is what keeps dropping the
; capability layer a seekwright-side change.
(package
 (name seekwright)
 (allow_empty)
 (synopsis "An MCP server fronting web-search providers behind one tool surface")
 (depends
  (ocaml
   (>= 5.1))
  mcp-caps))
