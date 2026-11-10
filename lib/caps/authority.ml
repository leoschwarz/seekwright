(** The abstract representation behind ['kind Authority.t].

    M0 carries the interface only: the operations below answer
    [Error Unavailable] rather than performing I/O, so nothing in this tree can
    yet be mistaken for a working grant. [Fs] arrives at M1 and [Net] at M3
    (plans/capability-gated-mcp-server.md §4, §5). *)

type fs
type net

type _ t

module Fs = struct
  type nonrec t = fs t

  let unimplemented feature milestone =
    Error
      (Error.make Error.Unavailable
         ~message:(feature ^ " is implemented at " ^ milestone))

  let read_file ?max_bytes:_ _t _path = unimplemented "Authority.Fs.read_file" "M1"
  let list_dir ?max_entries:_ _t _path = unimplemented "Authority.Fs.list_dir" "M1"
end

module Net = struct
  type nonrec t = net t

  type method_ = [ `GET | `POST | `PUT | `PATCH | `DELETE ]

  type request = {
    meth : method_;
    uri : Uri.t;
    headers : (string * string) list;
    body : string option;
  }

  type response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }

  let request ?max_response_bytes:_ _t _request =
    Error
      (Error.make Error.Unavailable
         ~message:"Authority.Net.request is implemented at M3")
end
