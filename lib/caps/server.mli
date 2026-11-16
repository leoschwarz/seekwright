(** Adapts the capability tool registry to an [Mcp_kit.Server.t].
    Validates declarations at startup, maps tool failures to [isError] responses,
    and isolates mcp-kit dependencies to this module. *)

type build_error =
  | Duplicate_tool of string
  | Invalid_declaration of string

val of_registry :
  name:string -> version:string -> Registry.t -> (Mcp_kit.Server.t, build_error) result
(** [of_registry ~name ~version registry] validates declarations (name, input schema,
    output schema) and constructs the MCP server. Tool errors are returned as
    MCP tool results with [is_error: true]. *)
