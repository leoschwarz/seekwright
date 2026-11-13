(* The confinement witness, built by hand — the way [Authority.Fs.of_confinement]
   could be turned from a wrapper into a constructor if a caller could make one:
   it needs a [Policy_fs.t], and the only thing that returns one is
   [Policy.with_root], which is the call that opens the subtree with
   [Eio.Path.open_subtree].

   Expected: [Mcp_caps.Policy_fs] has no name in the package. [lib/caps/dune] puts
   the module in [private_modules], so [dune build @install] ships no interface for
   it and the record's fields cannot even be asked for — the reason this snippet
   printed a field error before the module was made private, and a stronger fact
   now. Inside the library the type is still abstract ([type t] in
   [policy_fs.mli]), so no sibling module builds one either, and [mint_grant] pins
   the other half: the grant itself has no constructor. There is no way to point a
   grant at a directory the operator did not open
   (plans/capability-gated-mcp-server.md §4, and F1.2 of
   [plans/ocaml-finalisation.md] for the private-modules shape). *)

let forged : Mcp_caps.Policy_fs.t =
  { Mcp_caps.Policy_fs.root = (); max_read_bytes = 1; max_entries = 1 }

let grant = Mcp_caps.Authority.Fs.of_confinement forged
