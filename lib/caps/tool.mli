(** Tool definition: metadata, typed JSON input decoder, and grant-gated handler. Input JSON is
    decoded into a typed value before invoking [run] with the grant. *)

module Output : sig
  type t

  val text : ?structured_content:Yojson.Safe.t -> string -> t
  (** Ordered text, plus optional structured content for a tool that declared an [output_schema].
      Rich content (image, audio, embedded resource) waits for a concrete use case; until then
      nothing in the core leaks an mcp-kit result type. *)

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
(** [run] is public so a test can drive a tool without a transport. Going through MCP is
    [Server.of_registry] plus an entry from [Registry.entries]. *)
