(** Capability grants: phantom-typed I/O tokens passed to tool handlers.
    Operations are methods on ['kind Authority.t]; grants are abstract and cannot
    be forged or widened. Grants carry bounded execution controls (audit logging,
    operation timeout, operation budget) configured via decorators. *)

type fs
type net

type _ t

module Fs : sig
  type nonrec t = fs t

  val of_confinement : mono_clock:_ Eio.Time.Mono.t -> Policy_fs.t -> t
  (** [of_confinement ~mono_clock decision] wraps a filesystem confinement decision
      in a grant with default operation timeout. *)

  val read_file : ?max_bytes:int -> t -> string -> (string, Error.t) result
  (** [read_file ?max_bytes t path] reads a root-relative path. [max_bytes] may
      lower the grant ceiling, never raise it; files exceeding it return [Denied].
      Missing path returns [Unavailable]; non-regular file returns [Invalid]. *)

  val list_dir : ?max_entries:int -> t -> string -> (string list, Error.t) result
  (** [list_dir ?max_entries t path] lists sorted entry names in a root-relative
      directory; [""] is root. Exceeding [max_entries] returns [Denied]. *)

  val read_range :
    ?max_bytes:int -> t -> offset:int -> string -> (string * bool, Error.t) result
  (** [read_range ?max_bytes t ~offset path] reads at most [max_bytes] starting at
      byte [offset] and returns [(data, has_more)]. Offsets at or past EOF return
      [("", false)]. *)

  type entry_info = {
    size_bytes : int;
    accessed_at : float;
  }

  val stat : t -> string -> (entry_info, Error.t) result
  (** [stat t path] returns size and last-access time without reading file contents. *)

  val atomic_write :
    ?max_bytes:int -> t -> path:string -> contents:string -> (unit, Error.t) result
  (** [atomic_write ?max_bytes t ~path ~contents] writes [contents] via temporary file
      and atomic rename (mode 0o600). Over-ceiling payloads return [Denied].
      Read-only roots return [Denied]. *)

  val unlink : t -> string -> (unit, Error.t) result
  (** [unlink t path] removes [path] inside root; idempotent if already missing. *)
end

module Net : sig
  type nonrec t = net t

  type method_ = Policy_net.method_

  type request = Policy_net.request = {
    meth : method_;
    uri : Uri.t;
    headers : (string * string) list;
    body : string option;
  }

  type response = Policy_net.response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }

  val of_confinement : mono_clock:_ Eio.Time.Mono.t -> Policy_net.t -> t
  (** [of_confinement ~mono_clock decision] wraps an endpoint policy decision in a
      grant with default operation timeout. *)

  val request :
    ?max_response_bytes:int -> t -> request -> (response, Error.t) result
  (** [request ?max_response_bytes t req] executes a bounded HTTP exchange against
      vetted endpoints. [max_response_bytes] may lower the ceiling; over-ceiling
      responses return [Denied]. Redirects (3xx) are returned, never followed. *)
end

val with_log : sink:(Event.t -> unit) -> 'kind t -> 'kind t
(** [with_log ~sink grant] attaches an audit sink recording one [Event.t] per operation. *)

val with_operation_timeout : Eio.Time.Timeout.t -> 'kind t -> 'kind t
(** [with_operation_timeout timeout grant] sets the per-operation timeout bound. *)

val with_operation_budget : Budget.t -> 'kind t -> 'kind t
(** [with_operation_budget budget grant] attaches a caller-owned operation counter;
    refuses with [Denied] when spent. *)
