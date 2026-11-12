(* What a grant does to the serving path — and what a test can and cannot fake.

   Four things are pinned here:

   - a tool the registry never registered is not served at all, so "this server
     has no filesystem" is a property of the registry, not of a runtime check;
   - the grant, not the tool value, decides what a read reaches: one
     [read_source] declaration under two roots answers for its own root and
     cannot reach the other;
   - a refusal comes back through the transport as a tool result — [isError]
     with a [denied: …] line — not as a JSON-RPC failure (§3);
   - [Registry.add] and [Server.of_registry] never look inside a grant, so a
     test can register an in-memory stand-in where production puts a subtree.

   That last point is also the honest limit of faking in this layer: there is no
   fake [Authority.Fs.t], because [Policy_fs.t] is abstract and only
   [Policy.with_root] builds one. That is the design working, not an oversight,
   and it is why the confinement itself is tested against a real backend in
   test_authority_fs.ml while what is tested here is the plumbing around it. *)

module Authority = Mcp_caps.Authority
module Error = Mcp_caps.Error
module Policy = Mcp_caps.Policy
module Registry = Mcp_caps.Registry
module Server = Mcp_caps.Server
module Tool = Mcp_caps.Tool
open Test_support

let path_schema =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc [ ("path", `Assoc [ ("type", `String "string") ]) ]);
      ("required", `List [ `String "path" ]);
    ]

let empty_schema =
  `Assoc [ ("type", `String "object"); ("properties", `Assoc []); ("required", `List []) ]

let read_source =
  Tool.make
    ~description:"Read a file under the root this server was given."
    ~input_schema:path_schema
    ~decode:(fun json ->
      match json with
      | `Assoc [("path", `String path)] -> Ok path
      | _ -> Error "path must be a string")
    ~run:(fun grant path ->
      match Authority.Fs.read_file grant path with
      | Ok content -> Ok (Tool.Output.text content)
      | Error error -> Error error)
    "read_source"

let ping =
  Tool.make
    ~description:"Say pong."
    ~input_schema:empty_schema
    ~decode:(fun _json -> Ok ())
    ~run:(fun () () -> Ok (Tool.Output.text "pong"))
    "ping"

let root_a = Filename.temp_dir "mcp-caps-a" ""
let root_b = Filename.temp_dir "mcp-caps-b" ""

let in_dir dir name = Filename.concat dir name

let write dir name contents =
  let channel = open_out (in_dir dir name) in
  output_string channel contents;
  close_out channel

let () =
  write root_a "answer.md" "from A\n";
  Unix.symlink "/etc/passwd" (in_dir root_a "escape");
  (* The file that exists only next door: the test for whether one grant can
     see past its own root by name. *)
  write root_b "answer.md" "from B\n";
  write root_b "secret.md" "not yours\n"

(* The switch has to outlive the server for the same reason the transport loop
   does in production (§7): the subtree handle is registered on it, and every
   dispatch below does real I/O inside this loop. *)
let with_grant ~root f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) root with
  | Error error -> Alcotest.failf "with_root %s: %s" root (Error.render error)
  | Ok confinement -> f (Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement)

let with_two_grants f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let open_root root =
    match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) root with
    | Ok confinement -> Ok (Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement)
    | Error error -> Error (Printf.sprintf "with_root %s: %s" root (Error.render error))
  in
  match (open_root root_a, open_root root_b) with
  | Ok grant_a, Ok grant_b -> f grant_a grant_b
  | Error message, _ | _, Error message -> Alcotest.fail message

let server_of_server_error = function
  | Ok server -> server
  | Error (Server.Duplicate_tool name) -> Alcotest.failf "unexpected duplicate: %s" name
  | Error (Server.Invalid_declaration message) ->
      Alcotest.failf "invalid declaration: %s" message

let served_fs ~grant =
  match Registry.add Registry.empty read_source ~grant with
  | Ok registry -> Server.of_registry ~name:"test" ~version:"0" registry |> server_of_server_error
  | Error (Registry.Duplicate_tool name) -> Alcotest.failf "unexpected duplicate: %s" name

let served_ping_only () =
  match Registry.add Registry.empty ping ~grant:() with
  | Ok registry -> Server.of_registry ~name:"test" ~version:"0" registry |> server_of_server_error
  | Error (Registry.Duplicate_tool name) -> Alcotest.failf "unexpected duplicate: %s" name

let dispatch server line =
  match Mcp_kit.Server.dispatch_string server line with
  | Some response -> Yojson.Safe.from_string response
  | None -> `Null

let call server path =
  dispatch server
    (Printf.sprintf
       {|{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_source","arguments":{"path":%S}}}|}
       path)

let listed server =
  Yojson.Safe.to_string (dispatch server {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}|})

(* A tool result, as the caller sees it: [isError] and the one text block. A
   JSON-RPC error (no [result] at all) is reported as [None]. *)
let answer response =
  match response with
  | `Assoc fields -> (
      match List.assoc_opt "result" fields with
      | Some result ->
          let is_error =
            match result with
            | `Assoc fields -> (
                match List.assoc_opt "isError" fields with
                | Some (`Bool value) -> value
                | _ -> false)
            | _ -> false
          in
          let text =
            match result with
            | `Assoc fields -> (
                match List.assoc_opt "content" fields with
                | Some (`List (`Assoc block :: _)) -> (
                    match List.assoc_opt "text" block with
                    | Some (`String text) -> text
                    | _ -> "")
                | _ -> "")
            | _ -> ""
          in
          Some (is_error, text)
      | None -> None)
  | _ -> None

let show = function Some (is_error, text) -> Printf.sprintf "isError=%b %S" is_error text | None -> "<jsonrpc error>"

(* A server built without the filesystem grant offers no filesystem tool, and
   asking for one by name leaks nothing about what the operator has. *)
let a_registry_without_a_grant_does_not_serve_the_tool () =
  let server = served_ping_only () in
  Alcotest.(check bool) "read_source is not advertised" false
    (contains ~haystack:(listed server) ~needle:"read_source");
  Alcotest.(check bool) "ping is advertised" true (contains ~haystack:(listed server) ~needle:"ping");
  let response = Yojson.Safe.to_string (call server "answer.md") in
  (* mcp-kit owns the JSON-RPC error for a name it does not offer; what the
     layer has to guarantee is that no file content and no root path ride along
     with it. *)
  Alcotest.(check bool) "the call is answered as a JSON-RPC error" true
    (contains ~haystack:response ~needle:"\"error\"" && not (contains ~haystack:response ~needle:"\"result\""));
  Alcotest.(check bool) "nothing about the root leaks: " false
    (contains ~haystack:response ~needle:"from A" || contains ~haystack:response ~needle:root_a)

let one_grant_reads_its_own_root () =
  with_grant ~root:root_a (fun grant ->
    match answer (call (served_fs ~grant) "answer.md") with
    | Some (false, "from A\n") -> ()
    | answer -> Alcotest.failf "expected A's file, got %s" (show answer))

let two_grants_do_not_share_a_view () =
  (* One [read_source] declaration, two roots: each server answers its own file,
     so the power is in the registration line and not in the tool. *)
  with_two_grants (fun grant_a grant_b ->
    let server_a = served_fs ~grant:grant_a in
    let server_b = served_fs ~grant:grant_b in
    match (answer (call server_a "answer.md"), answer (call server_b "answer.md")) with
    | Some (false, "from A\n"), Some (false, "from B\n") -> ()
    | (answer_a, answer_b) ->
        Alcotest.failf "expected A then B, got %s and %s" (show answer_a) (show answer_b))

let a_sibling_root_is_not_readable () =
  (* [secret.md] exists under root B and not under root A. Under A the name is
     simply not there — and the refusal says nothing about root B. *)
  with_grant ~root:root_a (fun grant ->
    match answer (call (served_fs ~grant) "secret.md") with
    | Some (true, text) ->
        Alcotest.(check bool) "unavailable" true (String.starts_with ~prefix:"unavailable:" text);
        Alcotest.(check bool) ("no leak of the other root: " ^ text) false
          (contains ~haystack:text ~needle:"not yours");
        Alcotest.(check bool) ("no leak of a real path: " ^ text) false (contains ~haystack:text ~needle:root_b)
    | answer -> Alcotest.failf "expected a refusal, got %s" (show answer))

let a_path_cannot_walk_to_a_sibling () =
  (* The shape a caller writes when it hopes the server will normalise for it.
     It is refused at the boundary, and the message carries neither root path. *)
  with_grant ~root:root_a (fun grant ->
    let sibling = Filename.concat (Filename.dirname root_a) (Filename.basename root_b) in
    List.iter
      (fun path ->
        match answer (call (served_fs ~grant) path) with
        | Some (true, text) ->
            Alcotest.(check bool) "invalid or denied" true
              (String.starts_with ~prefix:"invalid:" text || String.starts_with ~prefix:"denied:" text);
            Alcotest.(check bool) ("no leak of a real path: " ^ text) false (contains ~haystack:text ~needle:root_b);
            Alcotest.(check bool) ("no leak of the root: " ^ text) false (contains ~haystack:text ~needle:root_a)
        | answer -> Alcotest.failf "%S expected a refusal, got %s" path (show answer))
      [ "../" ^ Filename.basename root_b ^ "/secret.md"; sibling ^ "/secret.md"; "notes/../../secret.md" ])

(* A refusal at the boundary arrives as a tool result with the stable kind
   prefixed, which is the projection §3 promises: the model sees [denied:], and
   no backend detail or native path with it. *)
let a_symlink_escape_refuses_through_the_transport () =
  with_grant ~root:root_a (fun grant ->
    match answer (call (served_fs ~grant) "escape") with
    | Some (true, text) ->
        Alcotest.(check bool) "denied" true (String.starts_with ~prefix:"denied:" text);
        Alcotest.(check bool) ("no passwd content: " ^ text) false (contains ~haystack:text ~needle:"root:");
        Alcotest.(check bool) ("no native path: " ^ text) false (contains ~haystack:text ~needle:root_a)
    | answer -> Alcotest.failf "expected denied, got %s" (show answer))

(* A test-local grant: an association list standing in for a subtree. The point
   is not that it behaves like a filesystem — it is that nothing between
   [Registry.add] and the transport cares what the grant's type is, which is
   what lets the tool be tested without a loop and without a directory. *)
module Fake_fs = struct
  type t = (string * string) list

  let read t path =
    match List.assoc_opt path t with
    | Some content -> Ok content
    | None -> Error (Error.make Error.Unavailable ~message:(path ^ ": not in the fake root"))
end

let fake_read_source =
  Tool.make
    ~description:"Read from whatever root this server was given."
    ~input_schema:path_schema
    ~decode:(fun json ->
      match json with
      | `Assoc [("path", `String path)] -> Ok path
      | _ -> Error "path must be a string")
    ~run:(fun grant path ->
      match Fake_fs.read grant path with
      | Ok content -> Ok (Tool.Output.text content)
      | Error error -> Error error)
    "read_source"

let a_test_can_register_an_in_memory_grant () =
  let fake_root : Fake_fs.t = [ ("answer.md", "from memory\n") ] in
  let registry =
    match Registry.add Registry.empty fake_read_source ~grant:fake_root with
    | Ok registry -> registry
    | Error (Registry.Duplicate_tool name) -> Alcotest.failf "unexpected duplicate: %s" name
  in
  let server = Server.of_registry ~name:"test" ~version:"0" registry |> server_of_server_error in
  match (answer (call server "answer.md"), answer (call server "escape")) with
  | Some (false, "from memory\n"), Some (true, text) ->
      Alcotest.(check bool) "unavailable" true (String.starts_with ~prefix:"unavailable:" text)
  | answer_a, answer_b ->
      Alcotest.failf "expected the fake root's file and a refusal, got %s and %s"
        (show answer_a) (show answer_b)

let () =
  Alcotest.run "mcp-caps/grant-wiring"
    [
      ( "serving",
        [
          Alcotest.test_case "a registry without a grant does not serve the tool" `Quick
            a_registry_without_a_grant_does_not_serve_the_tool;
          Alcotest.test_case "a test can register an in-memory grant" `Quick
            a_test_can_register_an_in_memory_grant;
        ] );
      ( "reach",
        [
          Alcotest.test_case "one grant reads its own root" `Quick one_grant_reads_its_own_root;
          Alcotest.test_case "two grants do not share a view" `Quick two_grants_do_not_share_a_view;
          Alcotest.test_case "a sibling root is not readable" `Quick a_sibling_root_is_not_readable;
          Alcotest.test_case "a path cannot walk to a sibling" `Quick a_path_cannot_walk_to_a_sibling;
          Alcotest.test_case "a symlink escape is denied through the transport" `Quick
            a_symlink_escape_refuses_through_the_transport;
        ] );
    ]
