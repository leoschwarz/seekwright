(* A grant carries no power that its holder can take apart or copy. The grant
   type is abstract in [Authority.mli] and its constructors are not in the
   signature, so a module outside [mcp-caps] can neither build one nor pattern
   match its way to the confinement inside it
   (plans/capability-gated-mcp-server.md §4).

   Expected: no [Fs] constructor for the grant type. *)

let contents (grant : Mcp_caps.Authority.fs Mcp_caps.Authority.t) =
  match grant with
    Mcp_caps.Authority.Fs confinement -> confinement
