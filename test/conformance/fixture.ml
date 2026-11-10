(* The mcp-caps fixture for the official MCP conformance runner.

   Everything the runner scores goes through the capability layer's own path:
   [Tool.make] -> [Registry.add ~grant] -> [Server.of_registry] -> the mcp-kit
   Cohttp-Eio adapter. The declaration names are not ours to choose — the pinned
   runner asks each scenario's fixture tool by name (`test_simple_text`,
   `test_error_handling`), which is why this file is a fixture and not one of the
   examples. What a scenario reaches, and what it does not, is recorded in
   README.md next to it.

   Two kinds of registration are deliberately kept apart here:

   - capability-mediated tools, registered through [Mcp_caps.Registry];
   - the resources, resource template and prompts, registered directly on the
     [Mcp_kit.Server.t] that [Server.of_registry] returns. The layer has no
     [Registry.add] for those (plans/capability-gated-mcp-server.md §0,
     non-goals), and adding them to the returned value is the documented seam —
     see the last section of this file. A scenario that passes on them says
     something about mcp-kit and about the seam, not about a grant.

   [test_read_granted_file] is not reached by any official scenario. It is here
   because a fixture that only registers [~grant:()] tools would prove no more
   than [examples/caps_echo.exe] does: this one registers a tool with a real
   filesystem grant beside the scored pair, so [tools/list] is answered by a
   surface that mixes a powered tool with unpowered ones, and the pinned stdio
   transcript (see README.md, "The stdio half") reads a file through the grant.

   Run it:

   {v
   mkdir -p /tmp/conf-root && echo 'conformance note' > /tmp/conf-root/note.txt
   ./_build/default/test/conformance/fixture.exe --root /tmp/conf-root --http
   v}

   The first stdout line in HTTP mode is the loopback MCP URL, which is what the
   runner wrapper reads. Over stdio ([--stdio]) stdout carries protocol bytes
   only, and every note goes to stderr (§7). *)

module Authority = Mcp_caps.Authority
module Error = Mcp_caps.Error
module Policy = Mcp_caps.Policy
module Registry = Mcp_caps.Registry
module Server = Mcp_caps.Server
module Tool = Mcp_caps.Tool

(* --- the scored tools, through the layer ---------------------------------- *)

(* [tools-call-simple-text] asks for a tool named [test_simple_text] that takes
   no arguments and answers text. An empty input object is the schema mcp-kit
   accepts for a call that sends no [arguments] at all, and it is the same one
   [ping] uses in [examples/read_source.ml]. *)
let test_simple_text =
  Tool.make
    ~description:"Return one fixed line of text."
    ~input_schema:(Mcp_kit.Schema.object_ ~properties:[] ~required:[] ())
    ~decode:(fun _json -> Ok ())
    ~run:(fun () () -> Ok (Tool.Output.text "This is a simple text response for testing."))
    "test_simple_text"

(* [tools-call-error] expects a tool failure, which in this layer is a [run]
   that answers [Error _]. What reaches the wire is [Mcp_kit.Tool.error_text]
   built from [Error.render] — an [isError] tool result, never a JSON-RPC error
   (plans/capability-gated-mcp-server.md §3). *)
let test_error_handling =
  Tool.make
    ~description:"Always fail, with a message safe to show a model."
    ~input_schema:(Mcp_kit.Schema.object_ ~properties:[] ~required:[] ())
    ~decode:(fun _json -> Ok ())
    ~run:
      (fun () () ->
        Error (Error.make Error.Failed ~message:"This tool intentionally returns an error for testing"))
    "test_error_handling"

(* [server-stateless] asks for a tool that completes without emitting a log
   notification. There is nothing to gate here — the point is what the handler
   does *not* do — so it is a plain [~grant:()] tool, and it is the one
   [server-stateless] check this fixture can answer at all: the other four of
   that scenario need the diagnostic tools of MRTR elicitation
   (`test_missing_capability`, `test_streaming_elicitation`), which need an
   input-required result, and `Tool.Output` has none (§3). *)
let test_logging_tool =
  Tool.make
    ~description:"Complete without sending a logging notification."
    ~input_schema:(Mcp_kit.Schema.object_ ~properties:[] ~required:[] ())
    ~decode:(fun _json -> Ok ())
    ~run:(fun () () -> Ok (Tool.Output.text "logging disabled"))
    "test_logging_tool"

(* Two more unscored-at-this-revision diagnostics, both of which ask something
   about a *schema* rather than about a result, which is exactly what this layer
   hands to mcp-kit unchanged.

   [http-custom-header-server-validation]: a property annotated
   [x-mcp-header] makes the adapter demand an [Mcp-Param-greeting] header that
   matches the argument, so a declaration routed through [Registry.add] tightens
   the wire contract on its own. [test/test_http_transport.ml] pins the same
   mechanism in-process; this is the same fact through the pinned runner.

   [json-schema-2020-12]: the runner's own Draft 2020-12 document — [$schema],
   [$defs] with an [$anchor], a local [$ref], an enum, [allOf]/[anyOf],
   [if]/[then]/[else] and [additionalProperties: false] — must survive
   [Tool.make] -> [Server.of_registry] -> [Mcp_kit.Tool.make] and be evaluated
   by mcp-kit's vendored engine. A layer that rewrote or narrowed a declared
   schema fails this scenario. *)
let test_custom_header =
  Tool.make
    ~description:"Answer once the Greeting custom header matches its argument."
    ~input_schema:
      (Mcp_kit.Schema.object_
         ~properties:
           [
             ( "greeting",
               `Assoc
                 [
                   ("type", `String "string");
                   ("x-mcp-header", `String "Greeting");
                 ] );
           ]
         ~required:["greeting"] ())
    ~decode:(Mcp_kit.Tool.Arg.string "greeting")
    ~run:(fun () greeting ->
      Ok (Tool.Output.text (Printf.sprintf "custom-header-ok greeting=%s" greeting)))
    "test_custom_header"

let json_schema_2020_12_tool =
  let input_schema =
    `Assoc
      [
        ("$schema", `String "https://json-schema.org/draft/2020-12/schema");
        ( "$defs",
          `Assoc
            [
              ( "address",
                `Assoc
                  [
                    ("$anchor", `String "addressDef");
                    ("type", `String "object");
                    ( "properties",
                      `Assoc
                        [
                          ("street", `Assoc [ ("type", `String "string") ]);
                          ("city", `Assoc [ ("type", `String "string") ]);
                        ] );
                  ] );
            ] );
        ("type", `String "object");
        ( "properties",
          `Assoc
            [
              ("name", `Assoc [ ("type", `String "string") ]);
              ("address", `Assoc [ ("$ref", `String "#/$defs/address") ]);
              ( "contactMethod",
                `Assoc
                  [
                    ("type", `String "string");
                    ("enum", `List [ `String "phone"; `String "email" ]);
                  ] );
              ("phone", `Assoc [ ("type", `String "string") ]);
              ("email", `Assoc [ ("type", `String "string") ]);
            ] );
        ( "allOf",
          `List
            [
              `Assoc
                [
                  ( "anyOf",
                    `List
                      [
                        `Assoc [ ("required", `List [ `String "phone" ]) ];
                        `Assoc [ ("required", `List [ `String "email" ]) ];
                      ] );
                ];
            ] );
        ( "if",
          `Assoc
            [
              ( "properties",
                `Assoc [ ("contactMethod", `Assoc [ ("const", `String "phone") ]) ] );
              ("required", `List [ `String "contactMethod" ]);
            ] );
        ("then", `Assoc [ ("required", `List [ `String "phone" ]) ]);
        ("else", `Assoc [ ("required", `List [ `String "email" ]) ]);
        ("additionalProperties", `Bool false);
      ]
  in
  Tool.make
    ~description:"Draft 2020-12 input schema, handed through unchanged."
    ~input_schema
    ~decode:(fun _json -> Ok ())
    ~run:(fun () () -> Ok (Tool.Output.text "ok"))
    "json_schema_2020_12_tool"

(* Not scored by any official scenario: the powered neighbour. One subtree, one
   path argument, and the read is an [Authority.Fs] operation, so it is the line
   in this file that shows a grant in a real [tools/list]. *)
let test_read_granted_file =
  Tool.make
    ~description:"Read note.txt from the root this fixture was started with."
    ~input_schema:
      (Mcp_kit.Schema.object_
         ~properties:[("path", Mcp_kit.Schema.string ())]
         ~required:["path"]
         ())
    ~decode:(fun json ->
      match Mcp_kit.Tool.Arg.string "path" json with
      | Ok path -> Ok path
      | Error message -> Error message)
    ~run:(fun grant path ->
      match Authority.Fs.read_file grant path with
      | Ok content -> Ok (Tool.Output.text content)
      | Error error -> Error error)
    "test_read_granted_file"

let note line = prerr_endline ("conformance-fixture: " ^ line)

(* The body bound is the adapter's; naming it keeps the pin in this tree
   (§7). *)
let max_request_body = 1_048_576

let loopback = "127.0.0.1"

type transport = Transport_stdio | Transport_http of int option

let usage () =
  note "usage: fixture --root <directory> [--stdio | --http [<port>]]";
  exit 2

(* [--http] with no port asks the kernel for one and announces the URL on
   stdout, which is what the wrapper reads; a fixed port is for driving the
   fixture by hand. *)
let port_of = function
  | None -> Transport_http None
  | Some text -> (
      match int_of_string_opt text with
      | Some port when port > 0 && port < 65_536 -> Transport_http (Some port)
      | _ ->
          note (Printf.sprintf "--http: %S is not a port number" text);
          exit 2)

let cli () =
  match Array.to_list Sys.argv with
  | [] | [ _ ] -> usage ()
  | _ :: rest -> begin
      match
        let root = ref None and transport = ref Transport_stdio in
        let rec walk = function
          | [] -> ()
          | "--root" :: value :: tl ->
              root := Some value;
              walk tl
          | "--stdio" :: tl -> walk tl
          | [ "--http" ] -> transport := port_of None
          | [ "--http"; text ] -> transport := port_of (Some text)
          | flag :: _ when String.starts_with ~prefix:"--http=" flag ->
              let prefix = String.length "--http=" in
              transport :=
                port_of (Some (String.sub flag prefix (String.length flag - prefix)))
          | _ -> usage ()
        in
        walk rest;
        (!root, !transport)
      with
      | None, _ -> usage ()
      | Some root, transport -> (root, transport)
    end

let build ~sw env root =
  let ( let* ) = Result.bind in
  let ( >>= ) = Result.bind in
  let invalid message = Error (Server.Invalid_declaration message) in
  let* confinement =
    match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) root with
    | Ok confinement -> Ok confinement
    | Error error -> invalid (Error.render error)
  in
  let grant =
    Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement
  in
  let* registry =
    Registry.add Registry.empty test_simple_text ~grant:()
    >>= (fun registry -> Registry.add registry test_error_handling ~grant:())
    >>= (fun registry -> Registry.add registry test_logging_tool ~grant:())
    >>= (fun registry -> Registry.add registry test_custom_header ~grant:())
    >>= (fun registry -> Registry.add registry json_schema_2020_12_tool ~grant:())
    >>= (fun registry -> Registry.add registry test_read_granted_file ~grant)
    |> Result.map_error (fun (Registry.Duplicate_tool name) -> Server.Duplicate_tool name)
  in
  List.iter (fun entry -> note ("serves " ^ Registry.entry_name entry)) (Registry.entries registry);
  note ("test_read_granted_file is confined to " ^ root);
  Server.of_registry ~name:"mcp-caps-conformance" ~version:"0.1.0" registry

(* --- what the layer does not register ------------------------------------ *)

(* A resource is a static declaration, so there is no operation to gate, and
   [Registry] has no [add_resource] (plans/capability-gated-mcp-server.md §0).
   The plan's answer is that the adapter returns an [Mcp_kit.Server.t] precisely
   so an application can add these itself; this is that seam, and it is what the
   [resources-*], [caching] and [prompts-*] scenarios of the pinned run reach.
   Names and URIs are the runner's fixture contract, not a design choice. *)
(* One-pixel PNG, used as the binary resource body and as the image message of
   [test_prompt_with_image]. The runner decodes it, so it has to be a real PNG. *)
let test_png_base64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

let static_text_resource =
  Mcp_kit.Resource.make
    ~description:"Static text for conformance"
    ~mime_type:"text/plain"
    ~uri:"test://static-text"
    ~name:"Static text"
    [
      Mcp_kit.Resource.Text
        {
          uri = "test://static-text";
          mime_type = Some "text/plain";
          text = "This is the content of the static text resource.";
        };
    ]

let static_binary_resource =
  (* [resources-read-binary] checks the field is there and decodable. *)
  Mcp_kit.Resource.make
    ~description:"Static binary for conformance"
    ~mime_type:"image/png"
    ~uri:"test://static-binary"
    ~name:"Static binary"
    [
      Mcp_kit.Resource.Blob
        {
          uri = "test://static-binary";
          mime_type = Some "image/png";
          blob = test_png_base64;
        };
    ]

(* The one path component between the two fixed halves is the template's
   variable; [resources-templates-read] and [caching] read it back. *)
let template_resource =
  Mcp_kit.Resource_template.make
    ~uri_template:"test://template/{id}/data"
    ~name:"Template data"
    ~description:"Parameterized test resource"
    ~mime_type:"text/plain"
    (fun uri ->
      let prefix = "test://template/" and suffix = "/data" in
      let prefix_length = String.length prefix in
      let suffix_length = String.length suffix in
      let uri_length = String.length uri in
      if
        uri_length <= prefix_length + suffix_length
        || not (String.starts_with ~prefix uri)
        || not (String.ends_with ~suffix uri)
      then Mcp_kit.Resource_template.Unmatched
      else
        let id =
          String.sub uri prefix_length (uri_length - prefix_length - suffix_length)
        in
        if String.contains id '/' then Mcp_kit.Resource_template.Failed
        else
          Mcp_kit.Resource_template.Matched
            [
              Mcp_kit.Resource.Text
                {
                  uri;
                  mime_type = Some "text/plain";
                  text = "Template resource for id " ^ id;
                };
            ])

let simple_prompt =
  Mcp_kit.Prompt.make
    ~description:"Simple conformance prompt"
    "test_simple_prompt"
    (fun _args ->
      Ok
        {
          Mcp_kit.Prompt.description = None;
          messages =
            [
              Mcp_kit.Prompt.text Mcp_kit.Prompt.User "This is a simple prompt for testing.";
            ];
        })

(* [prompts-get-with-args] supplies both arguments; [completion-complete]
   exercises the argument's completion callback, which is why [arg1] answers
   only values prefixed the way the scenario prefixes its query. *)
let prompt_with_arguments =
  Mcp_kit.Prompt.make
    ~description:"Parameterized conformance prompt"
    ~arguments:
      [
        Mcp_kit.Prompt.argument ~required:true "arg1";
        Mcp_kit.Prompt.argument ~required:true "arg2";
      ]
    ~complete:(fun request ->
      if request.Mcp_kit.Completion.name = "arg1" then
        Ok
          Mcp_kit.Completion.
            {
              values =
                (if String.starts_with ~prefix:request.value "test" then
                   [ "test-value"; "test-example" ]
                 else []);
              total = None;
              has_more = false;
            }
      else Error Mcp_kit.Completion.Invalid_params)
    "test_prompt_with_arguments"
    (fun args ->
      match
        (Mcp_kit.Prompt.Arg.string "arg1" args, Mcp_kit.Prompt.Arg.string "arg2" args)
      with
      | Ok arg1, Ok arg2 ->
          Ok
            {
              Mcp_kit.Prompt.description = None;
              messages =
                [
                  Mcp_kit.Prompt.text Mcp_kit.Prompt.User
                    (Printf.sprintf "Prompt with arguments: arg1='%s', arg2='%s'" arg1
                       arg2);
                ];
            }
      | Error message, _ | _, Error message -> Error message)

(* [prompts-get-with-image] and [prompts-get-embedded-resource] ask for prompt
   messages carrying an image and an embedded resource — content types of the
   prompt surface, which the capability layer does not touch, so again the
   direct seam. [test_prompt_with_embedded_resource] resolves only the one URI
   the scenario supplies and refuses every other: a prompt that read an
   arbitrary caller URI would be the server authorising a read silently. *)
let prompt_with_image =
  Mcp_kit.Prompt.make
    ~description:"Image conformance prompt"
    "test_prompt_with_image"
    (fun _args ->
      Ok
        {
          Mcp_kit.Prompt.description = None;
          messages =
            [
              Mcp_kit.Prompt.image Mcp_kit.Prompt.User ~mime_type:"image/png"
                ~data:test_png_base64;
              Mcp_kit.Prompt.text Mcp_kit.Prompt.User "This prompt includes an image.";
            ];
        })

let prompt_with_embedded_resource =
  Mcp_kit.Prompt.make
    ~description:"Embedded resource conformance prompt"
    ~arguments:[Mcp_kit.Prompt.argument ~required:true "resourceUri"]
    "test_prompt_with_embedded_resource"
    (fun args ->
      match Mcp_kit.Prompt.Arg.string "resourceUri" args with
      | Ok "test://example-resource" ->
          Ok
            {
              Mcp_kit.Prompt.description = None;
              messages =
                [
                  Mcp_kit.Prompt.resource Mcp_kit.Prompt.User
                    (Mcp_kit.Resource.Text
                       {
                         uri = "test://example-resource";
                         mime_type = Some "text/plain";
                         text = "Embedded resource content for testing.";
                       });
                  Mcp_kit.Prompt.text Mcp_kit.Prompt.User
                    "Please process the embedded resource above.";
                ];
            }
      | Ok _ -> Error "resource URI not allowed"
      | Error message -> Error message)

let add_resource server resource =
  match Mcp_kit.Server.add_resource server resource with
  | Ok server -> server
  | Error _ -> failwith "duplicate conformance resource"

let add_prompt server prompt =
  match Mcp_kit.Server.add_prompt server prompt with
  | Ok server -> server
  | Error _ -> failwith "duplicate conformance prompt"

let add_resource_template server template =
  match Mcp_kit.Server.add_resource_template server template with
  | Ok server -> server
  | Error _ -> failwith "duplicate conformance resource template"

let extend_with_mcp_kit_registrations server =
  let server = add_resource server static_text_resource in
  let server = add_resource server static_binary_resource in
  let server = add_resource_template server template_resource in
  let server = add_prompt server simple_prompt in
  let server = add_prompt server prompt_with_arguments in
  let server = add_prompt server prompt_with_image in
  add_prompt server prompt_with_embedded_resource

let serve_http ~sw env server port_request =
  let socket =
    Eio.Net.listen ~backlog:128 ~sw env#net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port_request))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> assert false
  in
  (* Origin protection is the adapter's, and the allowlist is browser
     protection, not authentication (§7). The fixture's own loopback origin is
     what upstream's fixture allows too, so a browser request from the page the
     runner serves is ordinary traffic and anything else is 403. *)
  let allowed_origins = [ Printf.sprintf "http://%s:%d" loopback port ] in
  let handler =
    Mcp_kit_cohttp_eio.handler ~max_body_size:max_request_body ~allowed_origins server
  in
  (* In HTTP mode stdout is not the protocol channel, so the URL it announces is
     how the wrapper learns the ephemeral port. *)
  Printf.printf "http://%s:%d/mcp\n%!" loopback port;
  stdout |> flush;
  Cohttp_eio.Server.run
    ~on_error:(function
      | Mcp_kit_cohttp_eio.Rejected_origin -> note "origin rejected"
      | exn -> note ("connection: " ^ Printexc.to_string exn))
    socket handler

let () =
  let root, transport = cli () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match build ~sw env root with
  | Error (Server.Duplicate_tool name) -> note ("duplicate tool: " ^ name)
  | Error (Server.Invalid_declaration message) -> note message
  | Ok server -> (
      let server = extend_with_mcp_kit_registrations server in
      match transport with
      | Transport_stdio -> Mcp_kit_stdio.run_channels server stdin stdout
      | Transport_http port_request -> serve_http ~sw env server
                                        (match port_request with Some port -> port | None -> 0))
