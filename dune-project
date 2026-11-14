(lang dune 3.11)

(name seekwright)

; F9.1's one version owner. [lib/version.ml] is generated from this field and
; the generated opam files carry it; [dune build version.txt] prints it for a
; release or image label that cannot read a dune file. Do not spell the number
; anywhere else — the metadata suite reads this line and compares it with the
; two libraries' constants.
(version 0.1.1)

(generate_opam_files true)

; [LICENSE] is Apache-2.0; the packages' generated opam files and their
; [org.opencontainers.image.licenses] label have to say the same. The MIT
; notices under [test/conformance/] belong to the copied upstream fixtures and
; stay separate.
(license Apache-2.0)

; Project-level contact fields are generated into both opam files. They are
; declared once here so the two packages cannot disagree, and opam lint's
; missing-field diagnostics stay clean.
(authors "Leonardo Schwarz <mail@leoschwarz.com>")
(maintainers "Leonardo Schwarz <mail@leoschwarz.com>")
(homepage "https://github.com/leoschwarz/seekwright")
(bug_reports "https://github.com/leoschwarz/seekwright/issues")

(package
 (name mcp-caps)
 (synopsis "Capability-gated tool registration for OCaml MCP servers")
 (description
  "A small layer over mcp-kit: tools declare the authority their operations need, registration supplies an abstract grant of exactly that type, and policy constructors own filesystem and network confinement.")
 (depends
  ; 5.3.0 is what CI builds and what [plans/infra-setup.md] records as the
  ; switch. The tree is not tested on an older compiler, so the declared floor
  ; is the tested one rather than mcp-kit's own 5.1.
  (ocaml
   (>= 5.3.0))
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
  ; dependency entry takes one atom, so the exact pin and the test-only flag are
  ; one [(and …)] form: every mcp-kit component carries [= 0.2.0], because
  ; mcp-kit-cohttp-eio is built against the same wire contract as mcp-kit and a
  ; drift between them is an API mismatch, not a normal upgrade.
  (mcp-kit-cohttp-eio
   (and
    (= 0.2.0)
    :with-test))
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
  ; The tested compiler, as in [mcp-caps] above.
  (ocaml
   (>= 5.3.0))
  mcp-caps
  ; P4: the provider adapters. [uri] names the endpoint each adapter dials and is
  ; also what the [Net] grant's request carries; [mcp-caps] is the grant itself.
  (uri
   (>= 4.0))
  (yojson
   (>= 3.0.0))
  ; P3: the config file's format. The parser is stdlib-only in the Python tree
  ; ([tomllib]); OCaml needs the library.
  (toml
   (>= 7.0))
  ; P5: [digestif] is hashlib.sha256 for the engine's [qhash] correlation
  ; handle, and [eio] the journal appends and the backfill read through
  ; ([Usage.backfill]). Both are library dependencies the opam file has to
  ; carry or a bare `opam install seekwright` builds nothing.
  (digestif
   (>= 1.2))
  (eio
   (>= 1.6))
  ; P8: the server module and the binary. Every mcp-kit component is pinned
  ; exactly, as in mcp-caps, because they share an API generation; [eio_main] is
  ; a real dependency now (bin/ runs the loop the grants are opened on), and
  ; [mirage-crypto-rng] is what bin/ installs a generator from — the library
  ; itself only detects its absence.
  (mcp-kit
   (= 0.2.0))
  (mcp-kit-cohttp-eio
   (= 0.2.0))
  (cohttp-eio
   (>= 6.0))
  (http
   (>= 6.0))
  (cstruct
   (>= 6.0))
  (ipaddr
   (>= 5.5))
  (eio_main
   (>= 1.6))
  (mirage-crypto-rng
   (>= 1.5))
  (alcotest
   :with-test)
  ; F3.3: the property runs under [test/differential/]. Test-only, so a bare
  ; [opam install seekwright] does not pull a generator engine; the two packages
  ; cost about 5 MB installed and add no transitive dependency this tree does not
  ; already carry (dune, alcotest, base-unix). The decision and its measurement
  ; are in plans/seekwright-ocaml-port.md §F3.3 and test/differential/README.md.
  (qcheck-core
   :with-test)
  (qcheck-alcotest
   :with-test)))
