module Output = struct
  type t = { text : string; structured_content : Yojson.Safe.t option }

  let text ?structured_content text_content =
    { text = text_content; structured_content }

  let text_of t = t.text
  let structured_content t = t.structured_content
end

type ('caps, 'input) t = {
  name : string;
  title : string option;
  description : string option;
  input_schema : Yojson.Safe.t;
  output_schema : Yojson.Safe.t option;
  decode : Yojson.Safe.t -> ('input, string) result;
  run : 'caps -> 'input -> (Output.t, Error.t) result;
}

let make ?title ?description ?output_schema ~input_schema ~decode ~run name =
  { name; title; description; input_schema; output_schema; decode; run }

let name t = t.name
let title t = t.title
let description t = t.description
let input_schema t = t.input_schema
let output_schema t = t.output_schema
let decode t = t.decode
let run t = t.run
