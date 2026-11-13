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
open Test_support

let kind_testable =
  Alcotest.testable
    (fun ppf kind -> Format.pp_print_string ppf (Error.kind_to_string kind))
    ( = )

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
    false (contains ~haystack:(Error.message error) ~needle:root);
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

(* The written root: the same confinement, opened for the operations a server that
   does its own storing needs. It gets its own fixture tree rather than a directory
   inside [root]: the read suite asserts [root]'s exact listing, and a write suite
   that added entries there would make one suite's pass depend on another's having
   run first. The escape fixtures are the same shapes, rebuilt here. *)
let write_root = Filename.temp_dir "mcp-caps-fs-write" ""

let wpath name = Filename.concat write_root name

let write_out name contents =
  let channel = open_out (wpath name) in
  output_string channel contents;
  close_out channel

let () =
  Unix.mkdir (wpath "sub") 0o755;
  Unix.mkdir (wpath "notes") 0o755;
  write_out "sub/small.txt" "0123456789\n";
  write_out "notes/answer.md" "the answer is 42\n";
  Unix.symlink "/etc" (wpath "out-dir");
  Unix.symlink "/etc/passwd" (wpath "escape")

let write_sub = wpath "sub"

let starting_with prefix names =
  List.filter
    (fun name ->
      let n = String.length prefix in
      String.length name >= n && String.sub name 0 n = prefix)
    names

(* [dir] is the absolute path an operator would write: the operator's path is not
   itself confined, it is what defines the confinement. *)
let with_written_grant ?max_read_bytes ?max_write_bytes ?max_entries ?backend dir f =
  let previous = Option.value ~default:"" (Sys.getenv_opt "EIO_BACKEND") in
  Unix.putenv "EIO_BACKEND" (Option.value ~default:"" backend);
  Fun.protect
    ~finally:(fun () -> Unix.putenv "EIO_BACKEND" previous)
    (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      match
        Policy.with_written_root ?max_read_bytes ?max_write_bytes ?max_entries ~sw
          ~parent:(Eio.Stdenv.fs env)
          dir
      with
      | Error error -> Alcotest.failf "with_written_root %s failed: %s" dir (Error.render error)
      | Ok decision ->
          f (Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) decision))

let listing grant prefix =
  match Authority.Fs.list_dir grant "" with
  | Ok names -> starting_with prefix names
  | Error error -> [ Error.render error ]

(* A written root is created when it is missing — the operator's [cache_dir] case.
   The directory is removed first with [Unix]: this is a fixture, and what is under
   test is what the grant does with a directory that is not there. Reopening the
   same path is [~exists_ok]'s other half: a restart must not fail on the server's
   own cache. *)
let a_written_root_creates_and_reopens_its_directory () =
  let made = wpath "made-by-the-grant" in
  (try Unix.rmdir made with Unix.Unix_error _ -> ());
  Alcotest.(check bool) "the directory does not exist yet" false (Sys.file_exists made);
  with_written_grant made (fun grant ->
    Alcotest.(check bool) "the grant created it" true (Sys.file_exists made);
    check_list (`Names []) grant "");
  with_written_grant made (fun grant -> check_list (`Names []) grant "")

(* {1 The writes}

   Each case is one function, and the backend is its argument, so the same table
   can be asked of both loop runners. *)

let a_write_lands_and_reads_back backend =
  with_written_grant ~backend write_sub (fun grant ->
    match Authority.Fs.atomic_write grant ~path:"body.txt" ~contents:"first\n" with
    | Error error -> Alcotest.failf "write failed: %s" (Error.render error)
    | Ok () -> check_read (`Content "first\n") grant "body.txt")

(* The claim atomic replacement is bought for: a reader never sees a partial file,
   and the name that holds the payload on the way there is not the name it reads.
   [rename] is what makes that true, so the check is that the only name under that
   prefix in the directory is the target. *)
let a_rewrite_leaves_no_temporary_file backend =
  with_written_grant ~backend write_sub (fun grant ->
    ignore (Authority.Fs.atomic_write grant ~path:"rewrite.txt" ~contents:"first");
    ignore (Authority.Fs.atomic_write grant ~path:"rewrite.txt" ~contents:"second");
    check_read (`Content "second") grant "rewrite.txt";
    Alcotest.(check (list string)) "no temp name left" [ "rewrite.txt" ] (listing grant "rewrite"))

(* The mode is read with [Unix] because the claim is about the file the kernel
   created, which is what a server restarted into this directory would find. *)
let a_new_file_is_not_world_readable backend =
  with_written_grant ~backend write_sub (fun grant ->
    ignore (Authority.Fs.atomic_write grant ~path:"private.txt" ~contents:"x");
    let info = Unix.stat (wpath "sub/private.txt") in
    Alcotest.(check int) "mode" 0o600 (info.Unix.st_perm land 0o777))

let a_write_past_the_ceiling_is_refused backend =
  with_written_grant ~backend ~max_write_bytes:8 write_sub (fun grant ->
    match Authority.Fs.atomic_write grant ~path:"over.txt" ~contents:"0123456789" with
    | Ok () -> Alcotest.fail "an over-ceiling write succeeded"
    | Error error ->
        Alcotest.(check kind_testable) "kind" Error.Denied (Error.kind error);
        check_message error)

let a_refused_write_leaves_nothing_behind backend =
  with_written_grant ~backend write_sub (fun grant ->
    Alcotest.(check (list string)) "no over.txt, no temp of one" [] (listing grant "over"))

let a_caller_may_lower_the_write_ceiling backend =
  with_written_grant ~backend write_sub (fun grant ->
    match Authority.Fs.atomic_write ~max_bytes:4 grant ~path:"clamped.txt" ~contents:"0123456789" with
    | Ok () -> Alcotest.fail "a write over the caller's ceiling succeeded"
    | Error error ->
        Alcotest.(check kind_testable) "kind" Error.Denied (Error.kind error);
        Alcotest.(check (list string)) "and it created nothing" [] (listing grant "clamped"))

let a_write_may_not_escape_the_root backend =
  with_written_grant ~backend write_sub (fun grant ->
    match Authority.Fs.atomic_write grant ~path:"../escape.txt" ~contents:"x" with
    | Ok () -> Alcotest.fail "a write escaped the root"
    | Error error ->
        Alcotest.(check kind_testable) "kind" Error.Invalid (Error.kind error);
        Alcotest.(check bool) "nothing was written outside" false (Sys.file_exists (wpath "escape.txt")))

let a_write_through_a_symlink_out_of_the_root_is_denied backend =
  with_written_grant ~backend write_root (fun grant ->
    match Authority.Fs.atomic_write grant ~path:"out-dir/escaped.txt" ~contents:"x" with
    | Ok () -> Alcotest.fail "a write followed a symlink out of the root"
    | Error error ->
        Alcotest.(check kind_testable) "kind" Error.Denied (Error.kind error);
        Alcotest.(check bool) "nothing landed in /etc" false (Sys.file_exists "/etc/escaped.txt"))

let unlink_removes_and_is_idempotent backend =
  with_written_grant ~backend write_sub (fun grant ->
    ignore (Authority.Fs.atomic_write grant ~path:"gone.txt" ~contents:"x");
    match Authority.Fs.unlink grant "gone.txt" with
    | Error error -> Alcotest.failf "unlink failed: %s" (Error.render error)
    (* The second removal is the one eviction races need: the entry is already
       gone, and that is success rather than a failure to report. *)
    | Ok () ->
        match Authority.Fs.unlink grant "gone.txt" with
        | Error error -> Alcotest.failf "unlink of a missing path failed: %s" (Error.render error)
        | Ok () -> check_read (`Kind Error.Unavailable) grant "gone.txt")

let unlink_may_not_escape_the_root backend =
  with_written_grant ~backend write_sub (fun grant ->
    match Authority.Fs.unlink grant "../notes/answer.md" with
    | Ok () -> Alcotest.fail "unlink escaped the root"
    | Error error ->
        Alcotest.(check kind_testable) "kind" Error.Invalid (Error.kind error);
        Alcotest.(check bool) "the fixture is still there" true
          (Sys.file_exists (wpath "notes/answer.md")))

let stat_reports_size_and_access_time backend =
  with_written_grant ~backend write_sub (fun grant ->
    ignore (Authority.Fs.atomic_write grant ~path:"stat.txt" ~contents:"0123456789");
    match Authority.Fs.stat grant "stat.txt" with
    | Ok info ->
        Alcotest.(check int) "size" 10 info.Authority.Fs.size_bytes;
        (* [atime] is the mount's, so the claim here is only that it is a number
           the eviction pass can rank entries by. *)
        Alcotest.(check bool) "access time is a number" true (info.Authority.Fs.accessed_at > 0.)
    | Error error -> Alcotest.failf "stat failed: %s" (Error.render error))

let stat_of_a_missing_path_is_unavailable backend =
  with_written_grant ~backend write_sub (fun grant ->
    match Authority.Fs.stat grant "no-such-entry" with
    | Ok _ -> Alcotest.fail "stat of a missing path succeeded"
    | Error error -> Alcotest.(check kind_testable) "kind" Error.Unavailable (Error.kind error))

(* The read-only half, which is the shape every tool-facing grant has: the write
   operations are in the interface and they refuse. The [Denied] has to arrive
   before any file is created — a root that ends up with a [.tmp] in it after a
   refused write is a root whose read-only claim did not hold. *)
let a_read_only_root_refuses_every_write backend =
  with_grant ~backend (fun grant ->
    List.iter
      (fun (label, call) ->
        match call grant with
        | Ok () -> Alcotest.failf "a read-only root allowed %s" label
        | Error error ->
            Alcotest.(check kind_testable) (label ^ ": kind") Error.Denied (Error.kind error))
      [
        ("atomic_write", fun g -> Authority.Fs.atomic_write g ~path:"notes/nope.txt" ~contents:"x");
        ("unlink", fun g -> Authority.Fs.unlink g "notes/answer.md");
      ];
    check_list (`Names [ "answer.md"; "plain.txt" ]) grant "notes")

let stat_and_the_reads_work_through_a_read_only_root backend =
  with_grant ~backend (fun grant ->
    match Authority.Fs.stat grant "small.txt" with
    | Ok info -> Alcotest.(check int) "size" 11 info.Authority.Fs.size_bytes
    | Error error -> Alcotest.failf "stat failed: %s" (Error.render error))

(* {1 The ranges} *)

(* The window is the reason [read_range] exists: the grant answers with the bytes
   it was asked for, from an offset, and says whether more follows. *)
let read_range_reads_a_window_not_the_file backend =
  with_written_grant ~backend write_sub (fun grant ->
    ignore (Authority.Fs.atomic_write grant ~path:"window.txt" ~contents:"0123456789abcdefghij");
    match Authority.Fs.read_range ~max_bytes:4 grant ~offset:3 "window.txt" with
    | Ok (content, more) ->
        Alcotest.(check string) "window" "3456" content;
        Alcotest.(check bool) "more follows" true more
    | Error error -> Alcotest.failf "read_range failed: %s" (Error.render error))

let read_range_at_the_end_of_the_file_says_so backend =
  with_written_grant ~backend write_sub (fun grant ->
    ignore (Authority.Fs.atomic_write grant ~path:"tail.txt" ~contents:"01234");
    match Authority.Fs.read_range ~max_bytes:16 grant ~offset:2 "tail.txt" with
    | Ok (content, more) ->
        Alcotest.(check string) "window" "234" content;
        Alcotest.(check bool) "nothing follows" false more
    | Error error -> Alcotest.failf "read_range failed: %s" (Error.render error))

let read_range_past_the_end_is_an_empty_window backend =
  with_written_grant ~backend write_sub (fun grant ->
    ignore (Authority.Fs.atomic_write grant ~path:"short.txt" ~contents:"abc");
    match Authority.Fs.read_range ~max_bytes:16 grant ~offset:99 "short.txt" with
    | Ok (content, more) ->
        Alcotest.(check string) "window" "" content;
        Alcotest.(check bool) "nothing follows" false more
    | Error error -> Alcotest.failf "read_range failed: %s" (Error.render error))

(* The clamp, not a refusal: a range read whose ask is wider than the grant gets
   the grant's width and the [more] flag, because the caller asked for a window and
   this is a window. [read_file] on the same file refuses. *)
let read_range_clamps_to_the_grants_ceiling backend =
  with_written_grant ~backend ~max_read_bytes:8 write_sub (fun grant ->
    match Authority.Fs.read_range grant ~offset:0 "small.txt" with
    | Ok (content, more) ->
        Alcotest.(check string) "window" "01234567" content;
        Alcotest.(check bool) "more follows" true more
    | Error error -> Alcotest.failf "read_range failed: %s" (Error.render error))

(* The clamp is not a whole-file read in disguise: a 16-byte ask on a file four
   thousand times that wide allocates 16 bytes. *)
let a_window_costs_the_window_not_the_file backend =
  with_written_grant ~backend write_sub (fun grant ->
    ignore (Authority.Fs.atomic_write grant ~path:"big_window.txt" ~contents:(String.make 4096 'x'));
    match Authority.Fs.read_range ~max_bytes:16 grant ~offset:100 "big_window.txt" with
    | Ok (content, more) ->
        Alcotest.(check int) "window bytes" 16 (String.length content);
        Alcotest.(check bool) "more follows" true more
    | Error error -> Alcotest.failf "read_range failed: %s" (Error.render error))

let read_range_refuses_the_shapes_read_file_refuses backend =
  with_written_grant ~backend write_root (fun grant ->
    List.iter
      (fun (name, expected) ->
        match Authority.Fs.read_range grant ~offset:0 name with
        | Ok (content, _) -> Alcotest.failf "read_range %S succeeded (%S)" name content
        | Error error ->
            Alcotest.(check kind_testable) (name ^ ": " ^ Error.render error) expected (Error.kind error))
      [
        ("../etc/passwd", Error.Invalid);
        ("/etc/passwd", Error.Invalid);
        ("escape", Error.Denied);
        ("missing", Error.Unavailable);
        ("notes", Error.Invalid);
      ])

let write_cases backend =
  List.map
    (fun (title, case) ->
      Alcotest.test_case (Fmt.str "%s (%s backend)" title backend) `Quick (fun () -> case backend))
    [
      ("a write lands and reads back", a_write_lands_and_reads_back);
      ("a rewrite leaves no temporary file", a_rewrite_leaves_no_temporary_file);
      ("a new file is not world-readable", a_new_file_is_not_world_readable);
      ("a write past the ceiling is refused", a_write_past_the_ceiling_is_refused);
      ("a refused write leaves nothing behind", a_refused_write_leaves_nothing_behind);
      ("a caller may lower the write ceiling", a_caller_may_lower_the_write_ceiling);
      ("a write may not escape the root", a_write_may_not_escape_the_root);
      ("a write through a symlink out of the root is denied", a_write_through_a_symlink_out_of_the_root_is_denied);
      ("unlink removes, and is idempotent", unlink_removes_and_is_idempotent);
      ("unlink may not escape the root", unlink_may_not_escape_the_root);
      ("stat reports size and access time", stat_reports_size_and_access_time);
      ("stat of a missing path is Unavailable", stat_of_a_missing_path_is_unavailable);
      ("a read-only root refuses every write", a_read_only_root_refuses_every_write);
      ("a read-only root still reads and stats", stat_and_the_reads_work_through_a_read_only_root);
      ("read_range reads a window, not the file", read_range_reads_a_window_not_the_file);
      ("read_range at the end of the file says so", read_range_at_the_end_of_the_file_says_so);
      ("read_range past the end is an empty window", read_range_past_the_end_is_an_empty_window);
      ("read_range clamps to the grant's ceiling", read_range_clamps_to_the_grants_ceiling);
      ("a window costs the window, not the file", a_window_costs_the_window_not_the_file);
      ("read_range refuses what read_file refuses", read_range_refuses_the_shapes_read_file_refuses);
    ]

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
      ( "write (io_uring backend)", write_cases "linux" );
      ( "write (posix backend)", write_cases "posix" );
      ( "construction",
        [
          Alcotest.test_case "a missing root is refused" `Quick a_missing_root_is_refused;
          Alcotest.test_case "a file is not a root" `Quick a_file_is_not_a_root;
          Alcotest.test_case "a non-positive ceiling is refused" `Quick
            a_non_positive_ceiling_is_refused_at_construction;
          Alcotest.test_case "a written root creates and reopens its directory" `Quick
            a_written_root_creates_and_reopens_its_directory;
        ] );
    ]
