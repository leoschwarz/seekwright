(* M0 ships the interface only. Each constructor refuses rather than returning a
   grant, so a caller cannot get an unconstrained one from a tree that has not
   built the confinement yet. See policy.mli for what each milestone owes. *)

type endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
}

let unimplemented feature milestone section =
  Error
    (Error.make Error.Unavailable
       ~message:
         (feature ^ " is implemented at " ^ milestone ^ " (plans/capability-gated-mcp-server.md "
        ^ section ^ ")"))

let with_root ~sw:_ _parent _name =
  unimplemented "Policy.with_root" "M1" "§4"

let with_endpoints ~sw:_ ~net:_ ~clock:_ ~max_response_bytes:_ _endpoints =
  unimplemented "Policy.with_endpoints" "M3" "§5"

let with_public_web ~sw:_ ~net:_ ~clock:_ ~max_response_bytes:_ () =
  unimplemented "Policy.with_public_web" "M3" "§5"
