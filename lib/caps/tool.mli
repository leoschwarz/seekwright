(** A tool: metadata, a typed input decoder, and a handler that needs a grant.

    The plan's shape (plans/capability-gated-mcp-server.md §3): mcp-kit validates
    the input JSON Schema, [decode] turns validated JSON into the application's
    own input type, and [run] is applied to that plus the grant the tool was
    registered with. Keeping [decode] explicit is what makes "the schema passed
    but the value was not what we wanted" a testable case — it becomes an
    [Error.Invalid] tool result, not a JSON-RPC failure. *)

module Output : sig
  type t

  val text : ?structured_content:Yojson.Safe.t -> string -> t
  (** Ordered text, plus optional structured content for a tool that declared an
      [output_schema]. Rich content (image, audio, embedded resource) waits for
      a concrete use case; until then nothing in the core leaks an mcp-kit
      result type. *)

  val text_of : t -> string
  val structured_content : t -> Yojson.Safe.t option
end

type ('caps, 'input) t

val make :
  ?title:string ->
  ?description:string ->
  ?output_schema:Yojson.Safe.t ->
  input_schema:Yojson.Safe.t ->
  decode:(Yojson.Safe.t -> ('input, string) result) ->
  run:('caps -> 'input -> (Output.t, Error.t) result) ->
  string ->
  ('caps, 'input) t

val name : ('caps, 'input) t -> string
val title : ('caps, 'input) t -> string option
val description : ('caps, 'input) t -> string option
val input_schema : ('caps, 'input) t -> Yojson.Safe.t
val output_schema : ('caps, 'input) t -> Yojson.Safe.t option

val decode : ('caps, 'input) t -> Yojson.Safe.t -> ('input, string) result
val run : ('caps, 'input) t -> 'caps -> 'input -> (Output.t, Error.t) result
(** [run] is public so a test can drive a tool without a transport. Going
    through MCP is [Server.of_registry] plus an entry from [Registry.entries]. *)
