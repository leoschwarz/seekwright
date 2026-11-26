(* The live drivers' readiness answer: the body their modern `server/discover`
   probe got back really is a JSON-RPC result for the request they sent, not an
   error body, an HTML refusal page, or a proxy's apology.

   Silent by design — the driver calls this once per readiness attempt, so the
   exit code is the whole answer and a printed line would be 100 lines of noise
   around one real failure. A document it cannot read is a failed attempt, which
   is also what the driver's previous reader did; the driver's own error line,
   with the HTTP status beside it, is what names the problem. *)

module C = Compare_common

let () =
  let args = C.parse_args ~program:"readiness_check" ~spec:[ ("response", true) ] () in
  let answers =
    match try Some (C.read_json (C.opt_exn args "response")) with C.Bad _ -> None with
    | None -> false
    | Some document -> (
        match (C.assoc_get document "jsonrpc", C.assoc_get document "id") with
        | Some (`String version), Some (`String id) -> (
            version = "2.0" && id = "readiness"
            && match C.assoc_get document "result" with Some (`Assoc _) -> true | _ -> false)
        | _ -> false)
  in
  if not answers then exit 1
