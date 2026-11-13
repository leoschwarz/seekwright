(* The raw network operation, reached past the grant.

   [Policy_net] has to stay in the package's interface — [request], [response] and
   [endpoint] are the records a [Net] call is written in — so this call is sealed
   one step further in: its [~controls] argument has the type of the bounds record
   a grant carries, and that record's module is private, so no consumer can name a
   value for it. The bounds are what make the operation an audited, bounded,
   budgeted one; an operation without them is not offered. *)
let request decision request =
  Mcp_caps.Policy_net.request ~controls:() decision request
