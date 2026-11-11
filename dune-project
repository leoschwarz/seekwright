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
  ; M3: the network grant. These are library dependencies of mcp-caps itself,
  ; not test-only: outbound https behind a Net grant is the library's job
  ; (plans/capability-gated-mcp-server.md §5, "an http-only implementation is not
  ; a completed M3"). The versions are the ones the switch carries
  ; (plans/infra-setup.md), chosen as "at least" rather than exact pins because
  ; unlike mcp-kit none of them owns a wire contract we reproduce.
  (cohttp-eio
   (>= 6.0))
  (http
   (>= 6.0))
  (ipaddr
   (>= 5.5))
  (domain-name
   (>= 0.4))
  (tls
   (>= 2.0))
  (tls-eio
   (>= 2.0))
  (ca-certs
   (>= 1.0))
  (mirage-crypto-rng
   (>= 1.5))
  ; Installing a random generator is the application's job, and doing it uses the
  ; [mirage-crypto-rng.unix] findlib library inside the package above; that is
  ; why the library itself only names the package, never the unix sublibrary
  ; (§5, policy_net.ensure_rng).
  (alcotest
   :with-test)))

; The port's own package stanza. It carries the P1 router and the P2 wire
; library in one library; it depends on mcp-caps rather than the other way
; round, which is what keeps dropping the capability layer a seekwright-side
; change. The router itself stays stdlib-only via the ocamldep pin in test/dune.
(package
 (name seekwright)
 (synopsis "An MCP server fronting web-search providers behind one tool surface")
 (depends
  (ocaml
   (>= 5.1))
  mcp-caps
  (yojson
   (>= 3.0.0))
  (alcotest
   :with-test)))
