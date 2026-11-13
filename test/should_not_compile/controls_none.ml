(* The silent controls a grant used to accept at construction.

   [Controls.none] — silent, unbounded, uncounted — was how an operator asked for
   a grant that reports nothing and stops for nothing. It is gone: the bounds
   record's module is private, and the only way to change a grant's bounds is
   [Authority]'s three decorators on the grant itself. An unbounded grant is still
   expressible, as [Authority.with_operation_timeout Eio.Time.Timeout.none grant],
   and it is then visibly a decision about that grant rather than a record anyone
   can hand to any operation. *)
let silent = Mcp_caps.Controls.none
