(* The confinement witness is abstract, and that is what makes
   [Authority.Fs.of_confinement] not a way to build a grant: it needs a
   [Policy_fs.t], and the only thing that returns one is [Policy.with_root],
   which is the call that opens the subtree with [Eio.Path.open_subtree].

   Expected: the fields below are not fields of [Policy_fs.t] — writing a
   record with the confinement record's own shape does not produce one, so
   there is no way to point a grant at a directory the operator did not open
   (plans/capability-gated-mcp-server.md §4). *)

let forged : Mcp_caps.Policy_fs.t =
  { Mcp_caps.Policy_fs.root = (); max_read_bytes = 1; max_entries = 1 }

let grant = Mcp_caps.Authority.Fs.of_confinement forged
