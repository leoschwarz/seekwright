(* The raw filesystem operation, reached past the grant.

   [Policy_fs] is where [read_file] and [list_dir] actually live, and it is one of
   the library's private modules: the package ships no interface for it, so this
   line — the bypass F1.2 exists to close, a file read with no grant, no audit
   line and no bound — has no name to be written with at all. Inside the library
   the same call is [Authority.Fs.read_file], which can only be reached with a
   grant of the right kind. *)
let read_file decision path =
  Mcp_caps.Policy_fs.read_file decision path
