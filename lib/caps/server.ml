type build_error =
  | Duplicate_tool of string
  | Invalid_declaration of string

let ( let* ) = Result.bind

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

(* [require_input_object] raises on non-object root schema; caught and returned as Error. *)
let input_schema entry =
  try Ok (Mcp_kit.Schema.require_input_object (Registry.entry_input_schema entry))
  with Invalid_argument message ->
    Error (Invalid_declaration (Registry.entry_name entry ^ ": " ^ message))

(* Tool errors return Ok error_text with isError: true; never JSON-RPC Error. *)
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
      let* server = built in
      match Mcp_kit.Server.add_tool server tool with
      | Ok server -> Ok server
      | Error (Mcp_kit.Server.Duplicate_tool name) -> Error (Duplicate_tool name)
      | Error _ -> Error (Invalid_declaration (Mcp_kit.Tool.name tool ^ " could not be registered")))
    (Ok server)
    tools

let of_registry ~name ~version registry =
  let* tools =
    List.fold_left
      (fun built entry ->
        let* tools = built in
        let* tool = checked_tool entry in
        Ok (tools @ [ tool ]))
      (Ok [])
      (Registry.entries registry)
  in
  add_all (Mcp_kit.Server.create ~name ~version ()) tools
