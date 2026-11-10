type build_error =
  | Duplicate_tool of string
  | Invalid_declaration of string

let ( >>= ) = Result.bind

(* An MCP tool name is what a caller types, so it has to survive being echoed
   into a prompt and matched byte for byte. The character set is the conservative
   one: the names the frozen surface carries (search, fetch, answer) plus the
   `backend:flavour` spelling provider names use. *)
let max_name_bytes = 128

let name_is_usable name =
  let usable char =
    match Char.code char with
    | c when c >= 48 && c <= 57 -> true (* 0-9 *)
    | c when c >= 65 && c <= 90 -> true (* A-Z *)
    | c when c >= 97 && c <= 122 -> true (* a-z *)
    | _ -> List.mem char [ '-'; '_'; '.'; ':' ]
  in
  String.length name > 0 && String.length name <= max_name_bytes && String.for_all usable name

let schema_error ~name errors =
  Invalid_declaration
    (name ^ ": " ^ Mcp_kit.Schema.validation_errors_to_string ~root:name errors)

(* Verified against mcp-kit 0.2.0: [check_input_schema] only rejects a schema
   document that is not a JSON object, so {"type":"string"} passes it.
   [require_input_object] is the entry point that insists the root describes an
   object — and it raises, which is why declaration checking turns it back into
   a value. *)
let input_schema entry =
  try Ok (Mcp_kit.Schema.require_input_object (Registry.entry_input_schema entry))
  with Invalid_argument message ->
    Error (Invalid_declaration (Registry.entry_name entry ^ ": " ^ message))

(* Tool-originated failures are MCP results with isError set; the left channel
   of a handler result belongs to mcp-kit and is only for contract failures, so
   an Error.t from run never becomes a JSON-RPC error (§3). Only the sanitized
   message crosses: Error.render is the whole rendering, with no exception,
   backtrace, header or body behind it. *)
let mcp_tool entry input_schema output_schema =
  let handler json =
    match Registry.entry_call entry json with
    | Ok output ->
        Ok
          {
            Mcp_kit.Tool.content = [ Mcp_kit.Tool.Text (Tool.Output.text_of output) ];
            is_error = false;
            structured_content = Tool.Output.structured_content output;
          }
    | Error error -> Ok (Mcp_kit.Tool.error_text (Error.render error))
  in
  Mcp_kit.Tool.make
    ?title:(Registry.entry_title entry)
    ?description:(Registry.entry_description entry)
    ~input_schema
    ?output_schema
    (Registry.entry_name entry)
    handler

(* Every declaration problem is reported here, at construction, so a startup bug
   is never paid per request and no entry can be dropped on the way in. *)
let checked_tool entry =
  let name = Registry.entry_name entry in
  if not (name_is_usable name) then
    Error
      (Invalid_declaration
         (Printf.sprintf "%S is not a usable tool name (1-%d bytes of [A-Za-z0-9-_.:])" name
            max_name_bytes))
  else
    match input_schema entry with
    | Error error -> Error error
    | Ok input_schema -> (
        match Mcp_kit.Schema.check_input_schema input_schema with
        | Error errors -> Error (schema_error ~name errors)
        | Ok () -> (
            match Registry.entry_output_schema entry with
            | Some output_schema -> (
                match Mcp_kit.Schema.check_supported output_schema with
                | Error errors -> Error (schema_error ~name errors)
                | Ok () -> Ok (mcp_tool entry input_schema (Some output_schema)))
            | None -> Ok (mcp_tool entry input_schema None)))

let add_all server tools =
  List.fold_left
    (fun built tool ->
      built >>= fun server ->
      match Mcp_kit.Server.add_tool server tool with
      | Ok server -> Ok server
      | Error (Mcp_kit.Server.Duplicate_tool name) -> Error (Duplicate_tool name)
      | Error _ -> Error (Invalid_declaration (Mcp_kit.Tool.name tool ^ " could not be registered")))
    (Ok server)
    tools

let of_registry ~name ~version registry =
  let ( let* ) = Result.bind in
  let* tools =
    List.fold_left
      (fun built entry -> built >>= fun tools -> checked_tool entry >>= fun tool -> Ok (tools @ [ tool ]))
      (Ok [])
      (Registry.entries registry)
  in
  add_all (Mcp_kit.Server.create ~name ~version ()) tools
