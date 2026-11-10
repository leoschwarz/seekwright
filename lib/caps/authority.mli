(** Capability grants: the value a tool is handed, and the only way it can do I/O.

    This is the layer's whole claim (plans/capability-gated-mcp-server.md §1). A
    tool's [run] receives a ['caps Authority.t]; the phantom kind says which
    power it is, and every operation is a method on that value rather than a
    global. [t] is abstract with no exposed constructor, so ordinary safe OCaml
    cannot mint a grant or widen one — the boundary is design-time and audit,
    not a sandbox: nothing here stops tool code from calling [Unix], [Sys], or
    a network library directly, and no claim stronger than that is made
    (§0, "Threat-model boundary").

    A tool needing two powers uses a product, e.g. [Authority.Fs.t *
    Authority.Net.t]; there is deliberately no "union of all powers" grant.
    Grants are server-lifetime values: the [Eio.Switch.t] that owns their
    resources must enclose server construction and the transport loop (§1). *)

type fs
type net

type _ t

module Fs : sig
  type nonrec t = fs t

  val read_file : ?max_bytes:int -> t -> string -> (string, Error.t) result
  val list_dir : ?max_entries:int -> t -> string -> (string list, Error.t) result
end

module Net : sig
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

  val request :
    ?max_response_bytes:int -> t -> request -> (response, Error.t) result
end
