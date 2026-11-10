(** The only module in the layer that knows mcp-kit.

    Keeping mcp-kit behind this one module is what lets the registry, policy and
    authority core stay mcp-independent (and what makes the plan's fallback —
    binding tools to mcp-kit directly — a change on the application side
    only). Transports are deliberately absent: an application picks stdio, Eio
    flow, or Cohttp-Eio and puts the transport loop under the same
    [Eio.Switch.t] that owns the grants (§7). *)

type build_error =
  | Duplicate_tool of string
  | Invalid_declaration of string

val of_registry :
  name:string -> version:string -> Registry.t -> (Mcp_kit.Server.t, build_error) result
(** [of_registry ~name ~version registry] validates every declaration — a name
    that is not a usable identifier-shaped string, an input schema that is not an
    object, an output schema the local validator rejects — and only then returns
    a server. A declaration bug is a startup failure; it must never be paid per
    request, and no entry may be dropped on the way in.

    An entry's [Error.t] becomes an MCP tool result with [isError] set, using
    only [Error.message]; mcp-kit keeps ownership of JSON-RPC errors and of
    output-schema contract errors (§3). *)
