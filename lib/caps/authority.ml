(** The abstract grant type, and the operations that ride on it.

    [Fs.t] is [Policy.fs_grant] wrapped in the phantom kind, and the two
    operations are one line each: what a grant can do is decided when it is
    built, in [policy.ml], which is where an audit starts (§2, §4). See
    authority.mli for why the type stays constructor-free and for the Eio
    context the operations need. *)

type fs
type net

(* There is no [Net] branch yet, and that is the point: with no constructor, no
   value of type [net Authority.t] exists anywhere, so no tool can be
   registered with a power this tree cannot build. M3 adds the branch beside
   [Fs]'s when [Policy] can produce one (§5). *)
type _ t = Fs : Policy_fs.t -> fs t

module Fs = struct
  type nonrec t = fs t

  let of_confinement decision = Fs decision

  let read_file ?max_bytes (Fs grant) path = Policy_fs.read_file ?max_bytes grant path
  let list_dir ?max_entries (Fs grant) path = Policy_fs.list_dir ?max_entries grant path
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
