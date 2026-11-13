(** The HTTP serving loop's shutdown: signals in, one lifecycle result out.

    [bin/main.ml] owns the [Eio_main] loop and the app switch; this module owns
    the part between them — the SIGINT/SIGTERM handler, the one stop promise it
    fills, and the order in which the listener, the health monitor and the
    built providers are shut down. It is a library so the order is testable
    without sending a process a signal: a caller may hand in a stop promise and
    drive the same path.

    {1 The signal path}

    A signal handler may not touch an [Eio.Promise] directly, and it must not
    do work: both handlers write one byte to a self-pipe and nothing else. One
    watcher fiber waits on the pipe's read end and fills the stop promise the
    first time a byte arrives. A second signal is ignored — the process is
    already stopping — and neither handler formats, allocates a line or logs,
    so a signal cannot corrupt the protocol stream or a log line.

    {1 The order}

    [Server.serve_http] owns the drain: it stops accepting, marks the custom
    routes stopping, aborts the health fiber and waits for accepted connections
    under a bounded grace. When it returns (or fails to start), this module
    runs [close] exactly once — the built providers' [aclose], assembled by the
    caller because the app does not carry its construction graph — restores the
    previous signal handlers and closes the self-pipe. Only after that does the
    caller's app switch end, which is what makes "grants last as long as the
    providers they belong to" true rather than incidental. *)

(** {1 Serving} *)

val run_http :
  env:< net : _ Eio.Net.t; fs : _ Eio.Path.t; mono_clock : _ Eio.Time.Mono.t; .. > ->
  sw:Eio.Switch.t ->
  log:Seekwright.Log.log ->
  app:Seekwright.Server.app ->
  server:Mcp_kit.Server.t ->
  host:string ->
  port:int ->
  close:(unit -> unit) ->
  ?grace_seconds:float ->
  ?stop:unit Eio.Promise.t ->
  unit ->
  (Seekwright.Server.lifecycle, Seekwright.Server.serve_error) result
(** Serve until a stop is observed, then drain and close.

    Without [?stop] this installs SIGINT and SIGTERM handlers through a
    self-pipe and restores the previous handlers on the way out. With [?stop]
    the caller already holds the stop input (a test, or a caller that has its
    own trigger), so no process signal handler is installed — the drain,
    close and cleanup path is otherwise identical.

    [close] runs exactly once on every exit path, including a bind failure and
    a cancellation from an enclosing switch, and runs after the listener has
    joined its connections but before [sw] ends. [grace_seconds] defaults to
    {!Seekwright.Server.drain_grace_seconds}.

    A cancellation arriving from the enclosing switch is re-raised, never
    turned into a [serve_error]; [Error] carries only the listener's own
    startup failure. *)
