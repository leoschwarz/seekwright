(* The raw filesystem {e write}, reached past the grant.

   F1.2's seal is usually quoted for reads, and the page cache puts the same claim
   on the other half of the API: a write that leaves the confinement, or that
   nobody audited, is a way for a tool to edit the operator's disk. The write
   operations live in [Policy_fs] beside the read ones and are private for the
   same reason, but the module name is not the only line of defence — inside this
   workspace dune still resolves a private module — so the seal is the [~controls]
   argument, whose type no code outside [lib/caps] can produce. This snippet is
   [raw_fs_call_needs_bounds] for the write side: the module is in scope, the
   call is well-typed in every other way, and it still has no bounds record to
   pass. *)
let write_file confinement path contents =
  Policy_fs.atomic_write ~controls:() confinement ~path ~contents
