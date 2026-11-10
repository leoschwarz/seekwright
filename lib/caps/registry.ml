(* The grant and the decoder are closed here, so an entry's handler is
   monomorphic in JSON: no existential packaging is needed to keep one tool's
   input type from meeting another's. *)
type entry = {
  name : string;
  title : string option;
  description : string option;
  input_schema : Yojson.Safe.t;
  output_schema : Yojson.Safe.t option;
  call : Yojson.Safe.t -> (Tool.Output.t, Error.t) result;
}

type t = entry list

type add_error = Duplicate_tool of string

let empty = []

let entry_of tool ~grant =
  {
    name = Tool.name tool;
    title = Tool.title tool;
    description = Tool.description tool;
    input_schema = Tool.input_schema tool;
    output_schema = Tool.output_schema tool;
    call =
      (fun json ->
        match Tool.decode tool json with
        | Error message -> Error (Error.make Error.Invalid ~message)
        | Ok input -> Tool.run tool grant input);
  }

let add registry tool ~grant =
  let name = Tool.name tool in
  if List.exists (fun existing -> String.equal existing.name name) registry then
    Error (Duplicate_tool name)
  else Ok (registry @ [ entry_of tool ~grant ])

let entries registry = registry

let find registry name =
  List.find_opt (fun entry -> String.equal entry.name name) registry

let entry_name entry = entry.name
let entry_title entry = entry.title
let entry_description entry = entry.description
let entry_input_schema entry = entry.input_schema
let entry_output_schema entry = entry.output_schema
let entry_call entry = entry.call
