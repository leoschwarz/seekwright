(* The public policy surface: the filesystem entry point is Policy_fs's, and
   what is left here is the endpoint vocabulary the M3 network constructors will
   use. Splitting the confinement record into policy_fs.ml is what keeps
   [Authority.Fs.of_confinement] able to name the witness type without a module
   cycle; see policy_fs.mli. *)

let with_root = Policy_fs.with_root

let default_max_read_bytes = Policy_fs.default_max_read_bytes
let default_max_entries = Policy_fs.default_max_entries

type endpoint = {
  scheme : [ `Http | `Https ];
  host : string;
  port : int option;
}

let with_endpoints ~sw:_ ~net:_ ~clock:_ ~max_response_bytes:_ _endpoints =
  Error
    (Error.make Error.Unavailable
       ~message:
         "Policy.with_endpoints is implemented at M3 (plans/capability-gated-mcp-server.md §5)")

let with_public_web ~sw:_ ~net:_ ~clock:_ ~max_response_bytes:_ () =
  Error
    (Error.make Error.Unavailable
       ~message:"Policy.with_public_web is implemented at M3 (plans/capability-gated-mcp-server.md §5)")
