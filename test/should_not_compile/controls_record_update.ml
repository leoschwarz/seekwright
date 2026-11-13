(* Updating a bounds record a function was handed.

   The update form is the other half of the same claim: even a value whose type
   one could name cannot be widened, relaxed or silenced by a call site. Nothing
   in [mcp-caps] takes a bounds record, so there is nothing here to update — the
   grant's own decorators are the only way any bound changes. *)
let silence controls = { controls with Mcp_caps.Controls.log = None }
