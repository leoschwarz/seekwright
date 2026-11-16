(** The package version, generated from [dune-project]. *)

val package : string
(** The release version from [dune-project], e.g. ["0.1.1"]. *)

val project_url : string
(** The project URL the User-Agent names for contact. *)

val user_agent : string
(** [seekwright/<package> (+<project_url>)], the [fetch.user_agent] default. *)

val mcp_server : string
(** The MCP [serverInfo] version reported to clients. This is a protocol-visible
    identity distinct from the package release version. *)
