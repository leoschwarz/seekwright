(* The same filesystem read with the module {e in} scope.

   The name is the first line of defence, and it holds for a consumer of the
   installed package but not for a stanza next door in this workspace: dune files
   a private module's interface under [.private/], out of an installed consumer's
   search path, yet its own build still resolves it — [private_modules] is not a
   workspace wall. So the operation is sealed on its argument as well, and this
   snippet pins that seal where the name is available: [Policy_fs] is in scope
   here (the compile rules build its interface directly), and the call still fails
   because [~controls] wants a [Controls_raw.t] and nothing in reach produces one.

   That is why the bounds record has no interface file: with no [.mli], what
   reaches a consumer is what [ocamlc -i] infers, and the package ships neither.
   In a running program the only [Controls_raw.t] is the one inside a grant, and
   the only way to hold a grant is [Authority]. *)
let read_file confinement path =
  Policy_fs.read_file ~controls:() confinement path
