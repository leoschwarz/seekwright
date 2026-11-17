(** The black-box harness for suites that run [../bin/main.exe] as a child process: a scratch
    loopback port, the child's environment, and the bounded waits a socket test needs. Nothing here
    dials a billed endpoint — every address is 127.0.0.1.

    [?config] on the two [spawn]s is the [SEEKWRIGHT_CONFIG] the child sees. The parent's own value
    is always stripped, so a developer's shell cannot decide what a suite asserts, and naming a path
    that does not exist is how a suite pins that a verb reads no config at all. *)

val sleep : float -> unit

val free_port : unit -> int
(** A port the kernel picked on the loopback interface, released before it is returned; the suites
    that use it bind it immediately after. *)

val sockaddr : int -> Unix.sockaddr
val write_all : Unix.file_descr -> string -> unit

val read_all : ?deadline:float -> label:string -> Unix.file_descr -> string
(** [read_all ?deadline ~label fd] reads until the peer closes. [deadline] defaults to three seconds
    from now, and the label names what the caller was waiting for. *)

val connect_when_listening : deadline:float -> int -> Unix.file_descr
(** Poll [connect] until it succeeds, then hand over the socket. A listener that never comes up is a
    failed case, not a silent skip. *)

val wait_until_refused : deadline:float -> int -> unit
(** Poll until [connect] is refused. Connections accepted on the way there are closed without a
    word, so the probe never becomes work the process under test waits for. *)

val wait_for_exit : deadline:float -> int -> Unix.process_status
(** [WNOHANG] polling; a child that outlives the deadline is killed and the case fails, which is
    what keeps a hung server from hanging the suite. *)

type spawned = { pid : int; out : Unix.file_descr; err : Unix.file_descr }

val spawn : ?config:string -> argv:string list -> unit -> int
(** Run [../bin/main.exe] with [argv] appended, stdin and both outputs on [/dev/null]. The trailing
    [()] is what lets the implementation look at [config] as an option. *)

val spawn_captured : ?config:string -> argv:string list -> unit -> spawned
(** The same, with the outputs on pipes the caller reads. stdin stays on [/dev/null]. *)
