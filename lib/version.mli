(** The package's version, in the one place code can read it.

    [dune-project]'s [(version …)] is the owner: {!package} and {!user_agent}
    are generated from [{version:seekwright}] at build time, so a release bump
    is one line and a second literal cannot drift. The generated opam files
    take their [version:] from the same field, and [dune build version.txt]
    prints it for a release script or an image label that cannot read a dune
    file (F9.1).

    {!mcp_server} is deliberately not {!package}. The MCP [serverInfo] version
    is a protocol-visible identity, and the Python oracle lets FastMCP supply
    its own rather than [seekwright.__version__]; the conformance and stdio
    transcripts pin the value this port has always sent. It moves only with a
    deliberate identity change, and the goldens move in the same commit. *)

val package : string
(** The release version, verbatim from [dune-project], e.g. ["0.1.1"]. *)

val project_url : string
(** The project URL the User-Agent names for contact. *)

val user_agent : string
(** [seekwright/<package> (+<project_url>)], the [fetch.user_agent] default. *)

val mcp_server : string
(** The MCP [serverInfo] version ([Server.mcp_server] passes it to mcp-kit).
    A separate protocol value, not the package release. *)
