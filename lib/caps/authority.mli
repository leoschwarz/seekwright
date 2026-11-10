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
    resources must enclose server construction and the transport loop (§1).

    {1 Where a grant comes from}

    [Policy.with_root] is the only producer of an [Fs] grant. It hands back a
    [Policy_fs.t] — the confinement decision, with the subtree handle inside it
    — and [Fs.of_confinement] wraps that decision in the grant type a tool is
    registered with. The split is not decoration: an abstract type's
    constructors cannot cross a module boundary, so "one public producer" is
    enforced by making every other path need a value that only [Policy] can
    make. [test/should_not_compile] pins exactly that.

    {1 Running the operations: the Eio contract}

    Every operation is Eio direct style (§6), so it must run inside the Eio
    event loop whose environment opened the grant, in a fiber of that loop.
    mcp-kit 0.2.0's classic tool handler is a synchronous function, so it gets
    that context from the application: the transport loop is started inside
    [Eio_main.run], under the same [Eio.Switch.t] that owns the grants
    (§7) — [examples/read_source.ml] is the worked example.

    Two alternatives were rejected. [Eio_main.run] inside the handler would put
    a second loop around a handle opened by the first: [Eio] resources belong to
    the environment that created them, and [Eio_main] states in its own
    interface that a library [must not] call [run]. A private loop owned by each
    grant — a background domain that the handler posts work to — works from any
    context, but it adds a cross-domain handoff and a second confinement story,
    and it is unnecessary: putting the transport under the grant's loop already
    gives the handler a fiber. *)

type fs
type net

type _ t

module Fs : sig
  type nonrec t = fs t

  val of_confinement : Policy_fs.t -> t
  (** [of_confinement decision] turns a confinement decision — the opened
      subtree and its ceilings — into a grant. This is not a way to build a
      grant: [Policy_fs.t] is abstract and [Policy.with_root] is the only thing
      that returns one, so the audit answer to "who gave this tool the
      filesystem" is one grep, and [test/should_not_compile] holds the line. *)

  val read_file : ?max_bytes:int -> t -> string -> (string, Error.t) result
  (** [read_file ~max_bytes t path] reads a root-relative path. [path] must be
      relative to the grant's root: an absolute path, [".."], ["."] and empty
      components are [Error Invalid], refused before any I/O. That check is for
      a clear API; the confinement is [Eio.Path.open_subtree], which also stops
      symlinks and component-replacement races from leaving the root (§4).

      [max_bytes] may lower the grant's ceiling, never raise it. A file larger
      than the ceiling is [Denied] rather than truncated, and it is refused
      without being buffered in full. A missing path is [Unavailable]; a
      directory or a non-regular file is [Invalid]. *)

  val list_dir : ?max_entries:int -> t -> string -> (string list, Error.t) result
  (** [list_dir ~max_entries t path] lists a directory's entry names, sorted,
      with the same path rules as [read_file]. [""] is the root itself. The
      listing is counted as it streams, so [max_entries] bounds what is
      allocated, not only what is reported; going over is [Denied]. *)
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
  (** Implemented at M3 (§5). It answers [Error Unavailable] until then, rather
      than returning an unconfined response, because a stub that worked would be
      a wider grant than the operator configured. *)
end
