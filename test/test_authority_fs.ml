(* The filesystem grant, against a real backend.

   Two different things are under test and they are not interchangeable:

   - the API boundary: which path shapes are refused before any I/O, with which
     [Error.t] kind, and what a message is allowed to contain;
   - the confinement: that a path which does reach the backend cannot leave the
     subtree. That half is [openat2] semantics — the backend opens with
     RESOLVE_BENEATH — so it is tested by asking the real kernel, on both
     backends [Eio_main] picks: io_uring and posix.

   The fixture tree is built once in a temp directory with the plain stdlib and
   [Unix]. That is allowed here and not in [lib/caps]: the source guard is about
   the library, and a test setting up its own fixtures is not the library. *)

module Authority = Mcp_caps.Authority
module Error = Mcp_caps.Error
module Policy = Mcp_caps.Policy

let kind_testable =
  Alcotest.testable
    (fun ppf kind -> Format.pp_print_string ppf (Error.kind_to_string kind))
    ( = )

let contains text needle =
  let n = String.length text and m = String.length needle in
  let rec from i =
    if i + m > n then false
    else if String.sub text i m = needle then true
    else from (i + 1)
  in
  from 0

let root = Filename.temp_dir "mcp-caps-fs" ""

let path name = Filename.concat root name

let write name contents =
  let channel = open_out (path name) in
  output_string channel contents;
  close_out channel

let () =
  Unix.mkdir (path "notes") 0o755;
  write "notes/answer.md" "the answer is 42\n";
  write "notes/plain.txt" "plain\n";
  write "small.txt" "0123456789\n";
  (* One byte past the grant's default ceiling: the read has to be refused
     without the file ever being buffered. *)
  write "big.txt" (String.make (Policy.default_max_read_bytes + 1) 'x');
  Unix.symlink "/etc/passwd" (path "escape");
  Unix.symlink "/etc" (path "out-dir");
  Unix.symlink "notes/answer.md" (path "inner");
  Unix.symlink "notes" (path "inner-dir");
  Unix.symlink "nothing-here" (path "broken")

(* Each case runs its own loop and its own switch, so a case cannot inherit
   another case's handle. [backend] picks the Eio loop runner, which is how the
   same table is asked of io_uring and of posix: [Eio_main.run] reads
   [$EIO_BACKEND], and [Some ""] is its "choose for me" case, which is how an
   unset variable is put back. *)
let with_grant ?max_read_bytes ?max_entries ?backend f =
  let previous = Option.value ~default:"" (Sys.getenv_opt "EIO_BACKEND") in
  Unix.putenv "EIO_BACKEND" (Option.value ~default:previous backend);
  Fun.protect
    ~finally:(fun () -> Unix.putenv "EIO_BACKEND" previous)
    (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      match Policy.with_root ?max_read_bytes ?max_entries ~sw ~parent:(Eio.Stdenv.fs env) root with
      | Error error -> Alcotest.failf "with_root %s failed: %s" root (Error.render error)
      | Ok confinement -> f (Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement))

(* The same, for the cases where construction is expected to refuse. *)
let with_root_result ?max_read_bytes ?max_entries ~name f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  f (Policy.with_root ?max_read_bytes ?max_entries ~sw ~parent:(Eio.Stdenv.fs env) name)

let check_message error =
  (* A tool result is one line handed to a model, and it must not say where the
     operator's root actually is: that is the server's layout, not the caller's. *)
  Alcotest.(check bool)
    ("the message does not name the real root: " ^ Error.message error)
    false (contains (Error.message error) root);
  Alcotest.(check bool)
    ("the message is one line: " ^ Error.render error)
    true
    (String.for_all (fun char -> Char.code char <> 10 && Char.code char <> 13) (Error.render error))

let check_read expectation ?max_bytes grant path =
  match (Authority.Fs.read_file ?max_bytes grant path, expectation) with
  | Ok content, `Content expected -> Alcotest.(check string) "content" expected content
  | Ok content, `Kind kind ->
      Alcotest.failf "read %S succeeded (%S), expected %s" path content (Error.kind_to_string kind)
  | Error error, `Kind expected ->
      Alcotest.(check kind_testable) (Error.render error) expected (Error.kind error);
      check_message error
  | Error error, `Content expected ->
      Alcotest.failf "read %S failed: %s, expected %S" path (Error.render error) expected

let check_list expectation ?max_entries grant path =
  match (Authority.Fs.list_dir ?max_entries grant path, expectation) with
  | Ok names, `Names expected -> Alcotest.(check (list string)) "names" expected names
  | Ok names, `Kind kind ->
      Alcotest.failf "list %S succeeded (%s), expected %s" path
        (String.concat "," names)
        (Error.kind_to_string kind)
  | Error error, `Kind expected ->
      Alcotest.(check kind_testable) (Error.render error) expected (Error.kind error);
      check_message error
  | Error error, `Names expected ->
      Alcotest.failf "list %S failed: %s, expected %s" path (Error.render error)
        (String.concat "," expected)

(* Every shape here is one a caller can type. The expectations separate the
   refusals that are the API's (Invalid, before any I/O) from the ones the
   backend's confinement produces (Denied), because a reader has to be able to
   tell the two apart — and the Denied rows are the ones that would be a
   vulnerability if the grant were built any other way. *)
let path_shapes =
  [
    ("notes/answer.md", `Content "the answer is 42\n", "a file under the root");
    ("notes/plain.txt", `Content "plain\n", "a file in a subdirectory");
    ( "inner-dir/answer.md",
      `Content "the answer is 42\n",
      "through a symlinked directory that stays inside the root" );
    ("inner", `Content "the answer is 42\n", "a symlink that stays inside the root");
    ( "../../etc/passwd",
      `Kind Error.Invalid,
      "the lexical escape — refused at the boundary, before the backend" );
    ("../etc/passwd", `Kind Error.Invalid, "a .. at the start");
    ("notes/../notes/answer.md", `Kind Error.Invalid, "a .. component in the middle");
    ("./notes/answer.md", `Kind Error.Invalid, "a leading . component");
    ("notes/./answer.md", `Kind Error.Invalid, "a . component in the middle");
    ("notes//answer.md", `Kind Error.Invalid, "an empty component");
    ("notes/", `Kind Error.Invalid, "a trailing slash is an empty component");
    ("/etc/passwd", `Kind Error.Invalid, "an absolute path");
    ("note\000s", `Kind Error.Invalid, "a control character in a component");
    ( "escape",
      `Kind Error.Denied,
      "a symlink out of the root — the backend refuses it, no lexical check involved" );
    ( "out-dir/resolv.conf",
      `Kind Error.Denied,
      "a symlinked directory out of the root, reached through a component" );
    ("broken", `Kind Error.Unavailable, "a symlink that resolves to nothing under the root");
    ("missing", `Kind Error.Unavailable, "no such file");
    ("notes/missing", `Kind Error.Unavailable, "no such file in a real directory");
    ("notes", `Kind Error.Invalid, "a directory is not readable as a file");
    ("", `Kind Error.Invalid, "the root itself is a directory");
    ("big.txt", `Kind Error.Denied, "a file over the grant's byte ceiling");
  ]

let read_cases_for_backend backend =
  List.map
    (fun (path, expectation, _why) ->
      Alcotest.test_case (Fmt.str "%s (%s backend)" path backend) `Quick (fun () ->
        with_grant ~backend (fun grant -> check_read expectation grant path)))
    path_shapes

let over_the_grants_ceiling () =
  with_grant ~max_read_bytes:8 (fun grant -> check_read (`Kind Error.Denied) grant "small.txt")

let a_caller_lowers_the_ceiling () =
  with_grant (fun grant ->
    check_read (`Kind Error.Denied) ~max_bytes:5 grant "small.txt")

let a_caller_cannot_raise_the_ceiling () =
  (* 11 bytes fits in the caller's ask and not in the grant's, so the clamp is
     what decides — and it must clamp down. *)
  with_grant ~max_read_bytes:8 (fun grant ->
    check_read (`Kind Error.Denied) ~max_bytes:4096 grant "small.txt")

let a_callers_ask_that_fits_reads () =
  (* The other half of the clamp: an ask under the grant's ceiling that the file
     also fits is an ordinary read. *)
  with_grant (fun grant ->
    check_read (`Content "the answer is 42\n") ~max_bytes:64 grant "notes/answer.md")

let listing_the_root () =
  with_grant (fun grant ->
    check_list
      (`Names [ "big.txt"; "broken"; "escape"; "inner"; "inner-dir"; "notes"; "out-dir"; "small.txt" ])
      grant "")

let listing_a_subdirectory () =
  with_grant (fun grant -> check_list (`Names [ "answer.md"; "plain.txt" ]) grant "notes")

let listing_through_an_inside_symlink () =
  with_grant (fun grant -> check_list (`Names [ "answer.md"; "plain.txt" ]) grant "inner-dir")

let listing_refuses_an_escape () =
  with_grant (fun grant -> check_list (`Kind Error.Denied) grant "out-dir")

let listing_stops_at_its_ceiling () =
  with_grant ~max_entries:2 (fun grant -> check_list (`Kind Error.Denied) grant "")

let a_caller_lowers_the_entry_ceiling () =
  with_grant (fun grant -> check_list (`Kind Error.Denied) ~max_entries:1 grant "notes")

let listing_a_file () =
  with_grant (fun grant -> check_list (`Kind Error.Invalid) grant "small.txt")

let listing_a_missing_path () =
  with_grant (fun grant -> check_list (`Kind Error.Unavailable) grant "missing")

let a_missing_root_is_refused () =
  with_root_result ~name:(Filename.concat root "no-such-directory") (function
    | Ok _ -> Alcotest.fail "a missing root should not produce a grant"
    | Error error -> Alcotest.(check kind_testable) "kind" Error.Unavailable (Error.kind error))

let a_file_is_not_a_root () =
  with_root_result ~name:(path "small.txt") (function
    | Ok _ -> Alcotest.fail "a file should not produce a subtree grant"
    | Error error -> Alcotest.(check kind_testable) "kind" Error.Unavailable (Error.kind error))

let a_non_positive_ceiling_is_refused_at_construction () =
  with_root_result ~max_entries:0 ~name:root (function
    | Ok _ -> Alcotest.fail "a zero entry ceiling should not produce a grant"
    | Error error -> Alcotest.(check kind_testable) "kind" Error.Invalid (Error.kind error))

let () =
  Alcotest.run "mcp-caps/authority-fs"
    [
      ( "read (io_uring backend)",
        read_cases_for_backend "linux"
        @ [
            Alcotest.test_case "a caller may lower the byte ceiling" `Quick
              a_caller_lowers_the_ceiling;
            Alcotest.test_case "a caller may not raise it" `Quick a_caller_cannot_raise_the_ceiling;
            Alcotest.test_case "the grant's own ceiling binds it" `Quick over_the_grants_ceiling;
            Alcotest.test_case "an ask the file fits is an ordinary read" `Quick
              a_callers_ask_that_fits_reads;
          ] );
      ( "read (posix backend)",
        (* The same table asked of the other loop runner: the escape refusals come
           from the backend, so a claim about them is only worth what the backends
           it was checked against say. *)
        read_cases_for_backend "posix" );
      ( "list",
        [
          Alcotest.test_case "the root lists its entries" `Quick listing_the_root;
          Alcotest.test_case "a subdirectory lists" `Quick listing_a_subdirectory;
          Alcotest.test_case "an inside symlinked directory lists" `Quick
            listing_through_an_inside_symlink;
          Alcotest.test_case "a symlinked directory out of the root is denied" `Quick
            listing_refuses_an_escape;
          Alcotest.test_case "the entry ceiling binds the listing" `Quick
            listing_stops_at_its_ceiling;
          Alcotest.test_case "a caller may lower the entry ceiling" `Quick
            a_caller_lowers_the_entry_ceiling;
          Alcotest.test_case "a file is not a directory" `Quick listing_a_file;
          Alcotest.test_case "a missing directory" `Quick listing_a_missing_path;
        ] );
      ( "construction",
        [
          Alcotest.test_case "a missing root is refused" `Quick a_missing_root_is_refused;
          Alcotest.test_case "a file is not a root" `Quick a_file_is_not_a_root;
          Alcotest.test_case "a non-positive ceiling is refused" `Quick
            a_non_positive_ceiling_is_refused_at_construction;
        ] );
    ]
