(* Writing the bounds record by hand.

   Every field of the record the operations run inside, spelled out: the point of
   the negative-compilation pin F1.2 asks for is that this is not expressible
   outside the library, so "which bounds did this operation run under" always has
   an answer in the code. *)
let forged =
  {
    Mcp_caps.Controls.log = None;
    operation_timeout = Eio.Time.Timeout.none;
    budget = None;
  }
