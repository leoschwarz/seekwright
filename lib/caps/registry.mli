(** Tool registry pairing tools with capability grants.
    Tools with heterogeneous grants and input types are stored as uniform entries
    by closing over the grant and input decoder. *)

type t

type add_error = Duplicate_tool of string

type entry

val empty : t

val add :
  t -> ('caps, 'input) Tool.t -> grant:'caps -> (t, add_error) result
(** [add registry tool ~grant] closes [grant] over the tool's [run]. A
    no-capability tool passes [~grant:()]. Names are unique; a duplicate is
    refused rather than shadowing the first tool. Declaration validity
    (schema shape, an empty name) is [Server.of_registry]'s, not this module's. *)

val entries : t -> entry list
(** In registration order. *)

val find : t -> string -> entry option

val entry_name : entry -> string
val entry_title : entry -> string option
val entry_description : entry -> string option
val entry_input_schema : entry -> Yojson.Safe.t
val entry_output_schema : entry -> Yojson.Safe.t option

val entry_call :
  entry -> Yojson.Safe.t -> (Tool.Output.t, Error.t) result
(** Validate-and-run: [decode] first, then the handler with its grant. A decoder
    failure becomes [Error.Invalid], so it reaches the caller as an MCP tool
    result with [isError], never as a JSON-RPC transport failure. *)
