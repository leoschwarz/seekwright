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

    [Policy.with_root] is the only producer of an [Fs] grant and
    [Policy.with_endpoints] / [Policy.with_public_web] the only producers of a
    [Net] one. Each hands back a confinement decision — [Policy_fs.t],
    [Policy_net.t] — and [of_confinement] wraps that decision in the grant type
    a tool is registered with. The split is not decoration: an abstract type's
    constructors cannot cross a module boundary, so "one public producer" is
    enforced by making every other path need a value that only [Policy] can
    make. [test/should_not_compile] pins exactly that.

    The two kinds are sealed by different mechanisms, because their records are
    not equally shareable. [Policy_fs] is one of the library's
    [private_modules]: its name is not installed with the package, so the raw
    filesystem operations are not reachable from outside at all. [Policy_net]
    cannot be private — [request], [response] and [endpoint] are the records a
    [Net] call is written in, and a private module's records cannot be built or
    read by an installed consumer — so its [request] is sealed on its
    [~controls] argument, whose type [Controls_raw.t] is private in turn. Both
    seals, and the grant path they leave open, are pinned in
    [test/should_not_compile].

    {1 Running the operations: the Eio contract}

    Every operation is Eio direct style (§6), so it must run inside the Eio
    event loop whose environment opened the grant, in a fiber of that loop.
    mcp-kit 0.2.0's classic tool handler is a synchronous function, so it gets
    that context from the application: the transport loop is started inside
    [Eio_main.run], under the same [Eio.Switch.t] that owns the grants
    (§7) — [examples/read_source.ml] and [examples/gated_search.ml] are the
    worked examples.

    Two alternatives were rejected. [Eio_main.run] inside the handler would put
    a second loop around a handle opened by the first: [Eio] resources belong to
    the environment that created them, and [Eio_main] states in its own
    interface that a library [must not] call [run]. A private loop owned by each
    grant — a background domain that the handler posts work to — works from any
    context, but it adds a cross-domain handoff and a second confinement story,
    and it is unnecessary: putting the transport under the grant's loop already
    gives the handler a fiber.

    {1 Bounds that apply to every kind}

    A grant also carries a bounds record — [Controls_raw.t], a module with no
    name outside this library: the audit sink, the per-operation time bound and
    the operation budget ({!val:with_operation_budget}). [with_log],
    [with_operation_timeout] and [with_operation_budget] below are generic over
    ['kind] — they change that part of the grant and nothing else, so they apply
    to a filesystem grant and a network grant alike (§3, §6). Each grant is built
    with a bound already in it: [of_confinement] installs its kind's default
    operation timeout, and the three decorators are the only way to change it.
    There is no [~controls] to pass and no record to write: the type of that
    record belongs to a private module, so nothing outside [lib/caps] can hand a
    grant a bounds set chosen somewhere else, and the raw operations in
    [Policy_fs] and [Policy_net] — which take one — have no argument to be called
    with. An operation that does not go through a decorated grant is an operation
    this layer does not offer. *)

type fs
type net

type _ t

module Fs : sig
  type nonrec t = fs t

  val of_confinement : mono_clock:_ Eio.Time.Mono.t -> Policy_fs.t -> t
  (** [of_confinement ~mono_clock decision] turns a confinement decision — the
      opened subtree and its ceilings — into a grant. This is not a way to build
      a grant: [Policy_fs.t] is abstract, [Policy_fs] is a private module, and
      [Policy.with_root] is the only thing that returns one, so the audit answer
      to "who gave this tool the filesystem" is one grep, and
      [test/should_not_compile] holds the line.

      [mono_clock] is what the operation bound is measured on: a wall clock that
      steps (an NTP correction, a VM resume) would otherwise lengthen or shorten
      every deadline at once. The grant carries [Policy_fs]'s default operation
      bound and no audit sink; there is no [~controls] to pass, because no value
      of that type exists outside a grant. Bounds are changed only by the three
      decorators below — [with_operation_timeout Eio.Time.Timeout.none] is how an
      operator asks for an unbounded grant, and [with_log] is how it asks for an
      audited one. *)

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

  type method_ = Policy_net.method_
  (** [ `GET | `POST | `PUT | `PATCH | `DELETE ]. *)

  (* Destructive aliases: the grant's request type {e is} the one [Policy_net]
     checks — a restated record would be a second nominal type, and the request a
     caller built for this grant would not be it — while the field list here is
     what lets a caller write [Authority.Net.meth] rather than reaching past the
     grant into [Policy_net] for the labels. *)
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
  (** [of_confinement ~mono_clock decision] wraps the endpoint decision — the
      allowlisted destinations, the byte ceiling and the TLS configuration — in a
      grant. Not a way to build a grant: [Policy.with_endpoints] and
      [Policy.with_public_web] are the only producers of [Policy_net.t].

      The grant carries [Policy_net]'s default whole-operation bound (DNS,
      connect, TLS, headers and body together) and no audit sink, and no
      [~controls] can be passed to change that: see {!val:Fs.of_confinement}. The
      TLS configuration is not added here: it lives inside [decision], because
      reading the trust anchors is part of deciding whether this grant can speak
      https at all (§5). *)

  val request :
    ?max_response_bytes:int -> t -> request -> (response, Error.t) result
  (** One bounded HTTP exchange, and the only way a tool can reach a network.
      The guarantees are [Policy_net]'s, in one line each here:

      - the (scheme, host, effective port) must be one the grant allows,
        decided before any DNS query is sent;
      - the connection goes to one of the vetted answers for that name, so the
        HTTP client cannot resolve it again behind the check (DNS rebinding);
      - https speaks TLS with the endpoint's own name, against the system trust
        anchors — verification is never bypassed;
      - a 3xx is returned, never followed, and a [Location] this grant would
        refuse is itself a [Denied];
      - the response body is streamed against min(grant, caller) bytes and is
        [Denied] rather than truncated.

      [max_response_bytes] lowers the grant's ceiling, never raises it. A
      request body or header the authority owns (Host, Content-Length,
      Transfer-Encoding, Connection, Upgrade) is [Invalid]. *)
end

val with_log : sink:(Event.t -> unit) -> 'kind t -> 'kind t
(** [with_log ~sink grant] reports every operation of [grant] to [sink] — one
    bounded, content-free [Event.t] per operation (§6). The application owns the
    sink, so it owns where the line goes: [examples/gated_search.ml] writes it
    to stderr, because stdout is the protocol channel. *)

val with_operation_timeout : Eio.Time.Timeout.t -> 'kind t -> 'kind t
(** One bound per operation, not one per grant or per tool call: an [analyzer]
    that makes four requests gets four bounds (§6). [Eio.Time.Timeout.none]
    removes it. *)

val with_operation_budget : Budget.t -> 'kind t -> 'kind t
(** [with_operation_budget budget grant] spends the {b caller's} counter once per
    operation and refuses with [Denied] once it is spent, doing no I/O at all on
    a refused call.

    This is the one budget shape this layer can honestly offer: the counter is
    created by the code that wants a ceiling — per request, per plan — so its
    scope is that code's, while the grant stays a server-lifetime value (§6
    refuses a counter {b inside} a grant, because that would be a
    server-lifetime budget wearing a per-request name). Retaining the result
    keeps spending the same counter; that is the point of it. *)
