(* The disk page cache: the entry format, the three bounds, and the window cut.

   Port of [tests/fetch/test_page_cache.py], with two additions the port itself
   makes necessary:

   - the window is cut by [Fetcher.window_text], the same function a live read
     uses, where the oracle mirrors that cut as [_cut] because it may not import
     [fetcher]. So the parity sweep asks the two paths for the same window instead
     of pinning a mirror against a copy — and it includes a body far larger than
     the streaming chunk, which is where a chunked walk goes wrong on its own;
   - the LRU order is carried in the sidecar, not in the body's atime
     ([Page_cache.mli]). [a_hit_touches_the_sidecar_not_the_body] pins
     exactly that: a hit leaves the body's inode and mtime alone and moves [accessed].

   Every case runs against a real temp directory and a real [Authority.Fs] grant —
   the cache has no other way to reach a filesystem — and against an injected
   clock, so TTL and eviction order are asserted as exact numbers. Nothing here
   reaches a provider: the pages are written by [put], which is what the engine
   hands the cache after a live fetch. *)

module Authority = Mcp_caps.Authority
module Error = Mcp_caps.Error
module Policy = Mcp_caps.Policy
module Fetcher = Seekwright_fetch.Fetcher
module Page_cache = Seekwright_fetch.Page_cache

(* The oracle's per-entry cap, also the grant ceiling these cases open with: a
   grant ceiling below the entry cap would make the cache refuse its own entries,
   which is a wiring fact worth pinning in the one place a cache is built. *)
let entry_cap = 33_554_432

(* The cache's clock, shared by the cases and advanced by the ones whose subject
   is time. A page's [created] is this clock, and so is a hit's [accessed]. *)
let clock = ref 1_000.0

let now () = !clock

let url path = "https://example.com" ^ path

let page ?(title = Some "a title") ?(content_type = Some "text/html") ?(status_code = 200)
    ?(path_addressable = false) ?(url = url "/a") text : Page_cache.cached_page =
  {
    Page_cache.url;
    title;
    text;
    content_type;
    status_code;
    path_addressable;
    total_chars = String.length text;
    truncated = false;
  }

let entry_text = function Some (e : Page_cache.cached_page) -> Some e.text | None -> None

type harness = { cache : Page_cache.t; fs : Authority.Fs.t; dir : string }

(* A cache over a fresh directory and a fresh grant, with the ceilings a case
   names. [max_read_bytes] and [max_write_bytes] sit at the entry cap unless the
   case lowers them, so the cache's own ceilings are the only bound a case has to
   reason about. *)
let with_cache ?max_bytes ?max_entry_bytes ?ttl_seconds () f =
  let dir = Filename.temp_dir "seekwright-page-cache" "" in
  (* The grant's ceilings are the defaults plus the floor a windowed read needs;
     the cache's own ceilings are what a case lowers, so a case reasons about one
     bound rather than two. *)
  let ceiling = Stdlib.max entry_cap 65_536 in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match
    Policy.with_written_root ~sw ~max_read_bytes:ceiling ~max_write_bytes:ceiling ~max_entries:1_000
      ~parent:(Eio.Stdenv.fs env) dir
  with
  | Error error -> Alcotest.failf "with_written_root: %s" (Error.render error)
  | Ok confinement ->
      let fs = Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement in
      let cache = Page_cache.create ?max_bytes ?max_entry_bytes ?ttl_seconds ~fs ~now () in
      f { cache; fs; dir }

(* The cache's own two file names, reached through the same grant the cache
   speaks: a case that corrupts or half-writes an entry does it the way the server
   would, and a case that asks what an entry weighs reads it back off the same
   handle. *)
let body_name name = name ^ ".body"
let meta_name name = name ^ ".meta.json"

let read_through h name =
  match Authority.Fs.read_file h.fs name with Ok text -> Some text | Error _ -> None

let write_through h name contents =
  match Authority.Fs.atomic_write h.fs ~path:name ~contents with
  | Error error -> Alcotest.failf "writing %s: %s" name (Error.render error)
  | Ok () -> ()

let remove_through h name =
  match Authority.Fs.unlink h.fs name with
  | Error error -> Alcotest.failf "unlinking %s: %s" name (Error.render error)
  | Ok () -> ()

(* One number out of the sidecar, read the way the cache's own eviction pass
   reads it: a field name, then the JSON number until the next comma or brace.
   A missing or malformed field is a failure of the case, not a miss: this helper
   only runs where the case has just asked for a number the cache wrote. *)
let meta_field meta key =
  let field = "\"" ^ key ^ "\":" in
  match Test_support.find_sub ~haystack:meta ~needle:field () with
  | None -> Alcotest.failf "no %S in the sidecar: %s" key meta
  | Some start ->
      let from = start + String.length field in
      let stop =
        let rec go i =
          if i >= String.length meta then i
          else
            match meta.[i] with
            | ',' | '}' | ']' | ' ' -> i
            | _ -> go (i + 1)
        in
        go from
      in
      try float_of_string (String.sub meta from (stop - from))
      with Failure _ -> Alcotest.failf "bad %S in the sidecar: %s" key meta

let the_key_is_the_rungs_and_the_urls_hash () =
  (* The digests are the oracle's, computed over ["http\0" ^ url] and
     ["tavily\0" ^ url]: the key is the pair, hashed so a model-supplied URL never
     becomes a path. *)
  Alcotest.(check string)
    "the local reader's entry"
    "1f2fddb7f8b5ae44d895fa8edf4875cd156f2f5305c222b24bb00f9324937217"
    (Page_cache.entry_name ~rung:"http" ~url:(url "/a"));
  Alcotest.(check string)
    "a fallback's entry is a different file"
    "3551e6c6a413d4e406496f9c152b638ed920c4059d4418465a2d8e07e9bff1cb"
    (Page_cache.entry_name ~rung:"tavily" ~url:(url "/a"))

let rungs_do_not_share_an_entry () =
  with_cache () (fun h ->
      ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/a") ~page:(page "local text"));
      ignore (Page_cache.put h.cache ~rung:"tavily" ~url:(url "/a") ~page:(page "vendor text"));
      Alcotest.(check (option string)) "the local read keeps its own answer" (Some "local text")
        (entry_text (Page_cache.get h.cache ~rung:"http" ~url:(url "/a")));
      Alcotest.(check (option string)) "the vendor keeps its own answer" (Some "vendor text")
        (entry_text (Page_cache.get h.cache ~rung:"tavily" ~url:(url "/a"))))

let a_stored_page_reads_back_whole () =
  with_cache () (fun h ->
      Alcotest.(check bool) "the store succeeds" true
        (Page_cache.put h.cache ~rung:"http" ~url:(url "/a")
           ~page:(page ~title:(Some "Ünicode tıtle") ~content_type:(Some "application/json")
                    ~status_code:201 ~path_addressable:true "{\"a\":1}\n"));
      match Page_cache.get h.cache ~rung:"http" ~url:(url "/a") with
      | None -> Alcotest.fail "the entry is a miss"
      | Some (entry : Page_cache.cached_page) ->
          Alcotest.(check string) "url" (url "/a") entry.url;
          Alcotest.(check (option string)) "title" (Some "Ünicode tıtle") entry.title;
          Alcotest.(check string) "text" "{\"a\":1}\n" entry.text;
          Alcotest.(check (option string)) "content type" (Some "application/json") entry.content_type;
          Alcotest.(check int) "status" 201 entry.status_code;
          Alcotest.(check bool) "path addressable" true entry.path_addressable;
          Alcotest.(check int) "total chars" 8 entry.total_chars;
          Alcotest.(check bool) "a full entry is not truncated" false entry.truncated)

let an_absent_entry_is_a_miss () =
  with_cache () (fun h ->
      Alcotest.(check bool) "get" false
        (Page_cache.get h.cache ~rung:"http" ~url:(url "/nothing") <> None);
      Alcotest.(check bool) "get_window" false
        (Page_cache.get_window h.cache ~rung:"http" ~url:(url "/nothing") ~offset:0 ~max_chars:10 <> None))

let an_expired_entry_is_a_miss_and_its_files_go () =
  with_cache ~ttl_seconds:60.0 () (fun h ->
      ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/a") ~page:(page "some text"));
      let name = Page_cache.entry_name ~rung:"http" ~url:(url "/a") in
      clock := !clock +. 61.0;
      Alcotest.(check bool) "the expired entry is a miss" false
        (Page_cache.get h.cache ~rung:"http" ~url:(url "/a") <> None);
      Alcotest.(check bool) "the body went with it" false (read_through h (body_name name) <> None);
      Alcotest.(check bool) "the sidecar went with it" false (read_through h (meta_name name) <> None))

let a_corrupt_sidecar_is_a_miss () =
  with_cache () (fun h ->
      ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/a") ~page:(page "some text"));
      let name = Page_cache.entry_name ~rung:"http" ~url:(url "/a") in
      write_through h (meta_name name) "{\"created\": not json at all";
      Alcotest.(check bool) "a sidecar that does not parse is absent" false
        (Page_cache.get h.cache ~rung:"http" ~url:(url "/a") <> None);
      (* A sidecar of the wrong shape is the same miss: the read paths treat a
         foreign file as an absent one rather than serving a page built out of
         nothing. *)
      write_through h (meta_name name) "{\"created\": 1000, \"total_chars\": \"nine\"}";
      Alcotest.(check bool) "a foreign shape is a miss too" false
        (Page_cache.get h.cache ~rung:"http" ~url:(url "/a") <> None);
      (* And a body that is not UTF-8 at all is a miss, whatever its sidecar
         says — the fault that reads as [UnicodeDecodeError] in the oracle. *)
      write_through h (meta_name name) "{\"created\": 1000, \"total_chars\": 3, \"url\": \"x\"}";
      write_through h (body_name name) "\xff\xfe broken bytes";
      Alcotest.(check bool) "an undecodable body is a miss" false
        (Page_cache.get h.cache ~rung:"http" ~url:(url "/a") <> None))

let half_an_entry_is_a_miss () =
  with_cache () (fun h ->
      let a = Page_cache.entry_name ~rung:"http" ~url:(url "/a") in
      write_through h (body_name a) "a body with no sidecar";
      Alcotest.(check bool) "a body alone is a miss" false
        (Page_cache.get h.cache ~rung:"http" ~url:(url "/a") <> None);
      Alcotest.(check bool) "and it is a miss for the windowed path too" false
        (Page_cache.get_window h.cache ~rung:"http" ~url:(url "/a") ~offset:0 ~max_chars:4 <> None);
      ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/b") ~page:(page "whole"));
      let b = Page_cache.entry_name ~rung:"http" ~url:(url "/b") in
      remove_through h (body_name b);
      Alcotest.(check bool) "a sidecar alone is a miss" false
        (Page_cache.get h.cache ~rung:"http" ~url:(url "/b") <> None))

(* A half write that survived a crash reads as a miss to the next process, which
   is the whole point of the pair going through a temporary name and a rename:
   nothing looks at a [.tmp] file. And an entry one process wrote is there for the
   next one: the cache is the directory, not the heap. *)
let a_restart_reads_the_directory_not_a_previous_process () =
  let dir = Filename.temp_dir "seekwright-page-cache-crash" "" in
  let body_only, durable =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    match Policy.with_written_root ~sw ~max_read_bytes:entry_cap ~max_write_bytes:entry_cap
            ~parent:(Eio.Stdenv.fs env) dir
    with
    | Error error -> Alcotest.failf "with_written_root: %s" (Error.render error)
    | Ok confinement ->
        let fs = Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement in
        let writer = Page_cache.create ~fs ~now () in
        let a = Page_cache.entry_name ~rung:"http" ~url:(url "/a") in
        (* The body landed; the sidecar's rename did not. *)
        (match Authority.Fs.atomic_write fs ~path:(body_name a) ~contents:"half a page" with
        | Ok () -> ()
        | Error error -> Alcotest.failf "%s" (Error.render error));
        ignore (Page_cache.put writer ~rung:"http" ~url:(url "/c") ~page:(page "durable"));
        (* A second value over the same directory is the process after the
           restart: it holds nothing of the first one's. *)
        let reader = Page_cache.create ~fs ~now () in
        ( Page_cache.get reader ~rung:"http" ~url:(url "/a") <> None,
          entry_text (Page_cache.get reader ~rung:"http" ~url:(url "/c")) )
  in
  Alcotest.(check bool) "the next process misses the half entry cleanly" false body_only;
  Alcotest.(check (option string)) "the next process finds the whole entry" (Some "durable") durable

let an_entry_over_the_entry_cap_is_never_stored () =
  with_cache ~max_entry_bytes:64 () (fun h ->
      Alcotest.(check bool) "the store refuses" false
        (Page_cache.put h.cache ~rung:"http" ~url:(url "/a") ~page:(page (String.make 65 'x')));
      Alcotest.(check (pair int int) "nothing was written") (0, 0) (Page_cache.stats h.cache);
      (* A page exactly at the cap is stored: the bound is "above", not "at". *)
      Alcotest.(check bool) "a page at the cap is stored" true
        (Page_cache.put h.cache ~rung:"http" ~url:(url "/b") ~page:(page (String.make 64 'x'))))

let the_directory_cap_evicts_the_least_recently_read () =
  (* Three entries of 100 bytes in a 260-byte directory. [a] is read after [b] is
     written, so [b] is the least recently read entry and the first to go; [c] and
     [a] survive, and the caller's own entry never evicts itself. *)
  with_cache ~max_bytes:260 () (fun h ->
      let text c = String.make 100 c in
      ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/a") ~page:(page (text 'a')));
      clock := !clock +. 1.0;
      ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/b") ~page:(page (text 'b')));
      clock := !clock +. 1.0;
      Alcotest.(check bool) "[a] is read, so it becomes the newest" true
        (Page_cache.get h.cache ~rung:"http" ~url:(url "/a") <> None);
      clock := !clock +. 1.0;
      ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/c") ~page:(page (text 'c')));
      let read path = entry_text (Page_cache.get h.cache ~rung:"http" ~url:(url path)) in
      Alcotest.(check (option string)) "the caller's own entry survived" (Some (text 'c'))
        (read "/c");
      Alcotest.(check (option string)) "the most recently read entry survived" (Some (text 'a'))
        (read "/a");
      Alcotest.(check (option string)) "the least recently read entry went" None (read "/b");
      Alcotest.(check (pair int int) "the directory is back inside its cap") (2, 200)
        (Page_cache.stats h.cache))

let a_hit_touches_the_sidecar_not_the_body () =
  (* The divergence pin. Eio has no [utimes], and a mount's [relatime] would not
     move the body's atime at cache timescales anyway, so the order lives in the
     sidecar's [accessed] and a hit rewrites only that half. *)
  with_cache () (fun h ->
      ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/a") ~page:(page "the body"));
      let name = Page_cache.entry_name ~rung:"http" ~url:(url "/a") in
      let body_path = Filename.concat h.dir (body_name name) in
      let meta_path = Filename.concat h.dir (meta_name name) in
      let body_before = Unix.stat body_path in
      let meta_before = Unix.stat meta_path in
      clock := !clock +. 30.0;
      Alcotest.(check bool) "the hit" true
        (Page_cache.get h.cache ~rung:"http" ~url:(url "/a") <> None);
      let body_after = Unix.stat body_path in
      Alcotest.(check bool) "the body is the same inode" true
        (body_before.Unix.st_ino = body_after.Unix.st_ino);
      Alcotest.(check bool) "the body was not rewritten" true
        (body_before.Unix.st_mtime = body_after.Unix.st_mtime);
      let meta_after = Unix.stat meta_path in
      (* The rewrite is pinned by the inode, not the timestamp: [atomic_write] places
         a new file, so a rewrite is a new inode, while a filesystem's timestamp
         granularity can leave two writes sharing an [st_mtime] and make the
         comparison flaky. The body's own inode is the other half — a body rewrite
         would replace that inode too. *)
      Alcotest.(check bool)
        (Printf.sprintf "the sidecar is a different inode (%d -> %d)"
           meta_before.Unix.st_ino meta_after.Unix.st_ino)
        true (meta_before.Unix.st_ino <> meta_after.Unix.st_ino);
      match read_through h (meta_name name) with
      | None -> Alcotest.fail "the sidecar vanished"
      | Some meta ->
          (* The clock the case set, read back off the sidecar rather than
             string-matched into it: [accessed] is what eviction ranks by, so its
             exact value is the pin. *)
          Test_support.check_number "accessed moved to the hit's clock" !clock
            (meta_field meta "accessed"))

(* The startup half of the rule, and the runtime one: a grant the operator opened
   read-only is not a cache, and [put] reports that as [false] — the caller
   degrades to a live fetch rather than failing the page. *)
let a_read_only_root_refuses_the_store () =
  let dir = Filename.temp_dir "seekwright-page-cache-readonly" "" in
  let stored =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    match Policy.with_root ~sw ~max_read_bytes:entry_cap ~parent:(Eio.Stdenv.fs env) dir with
    | Error error -> Alcotest.failf "with_root: %s" (Error.render error)
    | Ok confinement ->
        let fs = Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement in
        Page_cache.put (Page_cache.create ~fs ~now ()) ~rung:"http" ~url:(url "/a") ~page:(page "text")
  in
  Alcotest.(check bool) "the store refuses, and no page fails" false stored

(* A cached window is the window a live read serves, because it is the same
   function cutting it. The sweep covers a body larger than the streaming chunk
   and offsets past its end, which is where a chunked walk splits a codepoint. *)
let window_text = Alcotest.testable (fun ppf (text, more) ->
    Format.fprintf ppf "%S more=%b" text more) ( = )

let window_parity () =
  let build n seed =
    let buffer = Buffer.create (n + 16) in
    let alphabet = "abcdef ghij\n\n" in
    for i = 0 to n / 16 do
      Buffer.add_string buffer alphabet;
      Buffer.add_string buffer (Printf.sprintf "¶%d☃" (i + seed))
    done;
    Buffer.contents buffer
  in
  List.iter
    (fun text ->
      with_cache () (fun h ->
          ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/a") ~page:(page text));
          List.iter
            (fun max_chars ->
              List.iter
                (fun offset ->
                  let expected = Fetcher.window_text text ~offset ~max_chars in
                  match
                    Page_cache.get_window h.cache ~rung:"http" ~url:(url "/a") ~offset ~max_chars
                  with
                  | None ->
                      Alcotest.failf "a window of a stored page is a miss (offset %d, %d chars)"
                        offset max_chars
                  | Some (entry : Page_cache.cached_page) ->
                      Alcotest.(check window_text)
                        (Printf.sprintf "the window at offset %d, %d chars" offset max_chars)
                        expected (entry.text, entry.truncated);
                      Alcotest.(check int) "the total is the whole extraction"
                        (String.length text) entry.total_chars)
                [ 0; 1; 7; 33; 400; String.length text; String.length text + 500 ])
            [ 1; 5; 20; 300; 5_000; String.length text + 10 ];
          (* The whole-document read serves the entry entire, with no window
             finding: that is the path a [query] or [path] selection takes. *)
          match Page_cache.get h.cache ~rung:"http" ~url:(url "/a") with
          | None -> Alcotest.fail "the full entry is a miss"
          | Some (entry : Page_cache.cached_page) ->
              Alcotest.(check string) "the whole extraction" text entry.text;
              Alcotest.(check bool) "a full entry is not truncated" false entry.truncated))
    [ ""; "one short line"; "a ¶ b ☃ c ö d é"; build 400 0; build 5_000 7 ]

(* The RSS promise, measured rather than estimated, and measured in words because
   allocation is what a caller's memory follows: the [Gc] counters on each side of
   the read, with a [Gc.minor] to bring them up to date. Four assertions, each
   catching a different way the streaming could be fake:

   - a window at the front of a 6 MB body costs the window, not the document;
   - the same window costs the same words against a body four times as long, which
     a body-sized read cannot manage as the body grows;
   - the deep read at offset 200 000 costs the head it reads — [offset + max_chars
     + lookahead] codepoints, which [Fetcher.window_text] decodes — and not the
     body, and its window is byte-identical to the one a live read of the whole
     page cuts;
   - the whole-document read of that same entry, which does hold the body, costs a
     hundred times more than the front window.

   So the head, not the body, is what a paged read holds. The decode of the head is
   [Fetcher.window_text]'s own cost, the one every live window read pays too; it is
   not the cache re-reading the document. *)
let a_windowed_read_never_loads_the_whole_body () =
  let build lines =
    let buffer = Buffer.create (lines * 15) in
    for i = 1 to lines do
      Buffer.add_string buffer (Printf.sprintf "%06d ¶ line\n" i)
    done;
    Buffer.contents buffer
  in
  (* [words f] is the words [f] allocates, minor and major heap together. *)
  let words f =
    let sample () =
      Gc.minor ();
      let stat = Gc.quick_stat () in
      stat.Gc.minor_words +. stat.Gc.major_words
    in
    let before = sample () in
    let result = f () in
    result, sample () -. before
  in
  (* One body's costs and windows. [~live] also measures the live cut of the two
     windows — [Fetcher.window_text] over the whole body, which is what a live read
     of that page pays. It is the comparator that says a cached windowed read did not
     decode the document: the window's own decode is the live path's cost, shared. *)
  let measure ~live lines =
    with_cache () (fun h ->
        let body = build lines in
        ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/a") ~page:(page body));
        let read offset max_chars =
          match Page_cache.get_window h.cache ~rung:"http" ~url:(url "/a") ~offset ~max_chars with
          | None -> Alcotest.failf "the window at offset %d is a miss" offset
          | Some (entry : Page_cache.cached_page) -> (entry.text, entry.truncated)
        in
        let live_cut window =
          words (fun () -> Fetcher.window_text body ~offset:window ~max_chars:200)
        in
        let front, w_front = words (fun () -> read 0 200) in
        let deep, w_deep = words (fun () -> read 200_000 200) in
        let whole, w_full = words (fun () -> Page_cache.get h.cache ~rung:"http" ~url:(url "/a")) in
        let whole =
          match whole with Some (entry : Page_cache.cached_page) -> entry.text | None -> ""
        in
        let live_front, _ = if live then live_cut 0 else (("", false), 0.) in
        let live_deep, w_live = if live then live_cut 200_000 else (("", false), 0.) in
        ( String.length body,
          front,
          deep,
          live_front,
          live_deep,
          w_live,
          whole = body,
          w_front,
          w_deep,
          w_full ))
  in
  let ( short_len, short_front, short_deep, live_front, live_deep, live_words, whole_ok,
        front_words, deep_words, full_words ) =
    measure ~live:true 400_000
  in
  let ( long_len, long_front, long_deep, _, _, _, long_whole_ok, long_front_words, long_deep_words, _
        ) =
    measure ~live:false 1_200_000
  in
  Alcotest.(check bool) "the body is over 5 MB" true (short_len > 5_000_000);
  Alcotest.(check bool) "the other body is three times as long" true (long_len > short_len * 3);
  Alcotest.check window_text "the front window is the live window" live_front short_front;
  Alcotest.check window_text "the window at offset 200 000 is the live window" live_deep short_deep;
  Alcotest.check window_text "the same front window at either body length" short_front long_front;
  Alcotest.check window_text "the same window at offset 200 000 at either body length" short_deep
    long_deep;
  Alcotest.(check bool) "the whole entry is the whole extraction" true whole_ok;
  Alcotest.(check bool) "the long body's whole entry is its extraction too" true long_whole_ok;
  Alcotest.(check bool)
    (Printf.sprintf "the front window of a %d-byte body costs %.0f words, a rounding error next to \
                     the document" short_len front_words)
    true (front_words < float_of_int short_len /. 64.0);
  Alcotest.(check bool)
    (Printf.sprintf "the same window against a body three times as long costs %.0f words against %.0f: \
                     its cost follows the window, not the document" long_front_words front_words)
    true (long_front_words <= front_words *. 1.05);
  Alcotest.(check bool)
    (Printf.sprintf "the window at offset 200 000 costs %.0f words, under an eighth of the %.0f a live \
                     read of the same page pays for the same window" deep_words live_words)
    true (deep_words < live_words /. 8.0);
  Alcotest.(check bool)
    (Printf.sprintf "and the same window costs the same at either body length: %.0f against %.0f"
       long_deep_words deep_words)
    true (long_deep_words <= deep_words *. 1.5);
  Alcotest.(check bool)
    (Printf.sprintf "the whole-document read of the entry costs %.0f words against the body's %d bytes, \
                     and %.0f times the front window" full_words short_len
        (full_words /. front_words))
    true (full_words > float_of_int short_len /. 16.0 && full_words > front_words *. 4.0)

(* The chunked walk's own boundary case. The cache reads a body in 64 KiB pieces,
   and a codepoint that straddles a piece boundary is what a naive walk calls
   corrupt — the bug that would make a page with one accented character at the wrong
   byte impossible to read back from the cache for as long as it is cached. These
   bodies are built so the sequence across the first boundary is two, three and four
   bytes wide, and the sweep reads windows on both sides of it. *)
let a_window_across_a_chunk_boundary_is_still_the_live_window () =
  let boundary = 65_536 in
  List.iter
    (fun (lead, width) ->
      with_cache () (fun h ->
          let body =
            String.make (boundary - width) 'a' ^ lead ^ String.make 70_000 'b'
          in
          (* The lead starts [width] bytes before the boundary, so its last byte is
             the first byte of the second chunk. *)
          Alcotest.(check bool)
            (Printf.sprintf "the %d-byte %S straddles byte %d" width lead boundary)
            true
            (boundary - width < boundary && boundary < String.length body);
          ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/a") ~page:(page body));
          List.iter
            (fun max_chars ->
              List.iter
                (fun offset ->
                  match
                    Page_cache.get_window h.cache ~rung:"http" ~url:(url "/a") ~offset ~max_chars
                  with
                  | None ->
                      Alcotest.failf "the window at offset %d, %d chars is a miss" offset max_chars
                  | Some (entry : Page_cache.cached_page) ->
                      Alcotest.(check window_text)
                        (Printf.sprintf "the %d-byte window at offset %d, %d chars" width offset
                           max_chars)
                        (Fetcher.window_text body ~offset ~max_chars)
                        (entry.text, entry.truncated))
                [ boundary - width - 3; boundary - width; boundary - width + 1; boundary + 10 ])
            [ 1; 5; 200 ]))
    [ "é", 2; "☃", 3; "😀", 4 ]

let range a b = List.init (b - a + 1) (fun i -> i + a)

(* Eviction runs under the cache's own lock and every entry goes through a rename,
   so a reader racing a writer and an eviction sees either a whole entry or none —
   never a page out of two generations.

   The racing reads are allowed to miss: an entry may not be written yet, or the cap
   may take it again before the read lands, and a miss is a legitimate answer under
   a byte cap. What is not legitimate is a read that returns a page no live fetch of
   that URL would have returned. So the race's assertion is about what a read {i did}
   return, and the settled pass afterwards — [Fiber.all] has joined every fork by
   then, so the directory is at rest — pins that what the cap kept is exactly whole:
   the entries still on disk read back as the pages that were written. *)
let concurrent_reads_writes_and_evictions_agree () =
  let cap = 40_000 in
  let entry i = String.make 5_000 (Char.chr (97 + (i mod 26))) ^ string_of_int i in
  let window_of i = fst (Fetcher.window_text (entry i) ~offset:0 ~max_chars:4_000) in
  let keys = range 0 24 in
  let raced, whole, gone, partials, entries, bytes =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let dir = Filename.temp_dir "seekwright-page-cache-race" "" in
    match
      Policy.with_written_root ~sw ~max_read_bytes:entry_cap ~max_write_bytes:entry_cap
        ~max_entries:1_000 ~parent:(Eio.Stdenv.fs env) dir
    with
    | Error error -> Alcotest.failf "with_written_root: %s" (Error.render error)
    | Ok confinement ->
        let fs = Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement in
        (* The cap holds eight entries of 5 kB; twenty-five writers and twenty-five
           readers make the eviction pass run while it is being read. *)
        let cache = Page_cache.create ~max_bytes:cap ~fs ~now () in
        let raced = ref 0 and partials = ref 0 in
        let check i (found : Page_cache.cached_page) =
          (* A whole entry, or nothing: a read that saw half a page, or the bytes of
             two generations, would disagree with the cut a live read makes. *)
          if found.text <> window_of i then incr partials
        in
        Eio.Fiber.all
          (List.concat_map
             (fun i ->
               let key = url ("/" ^ string_of_int i) in
               [
                 (fun () ->
                   ignore (Page_cache.put cache ~rung:"http" ~url:key ~page:(page ~url:key (entry i))));
                 (fun () ->
                   (* One read per key, at an arbitrary point in the writes' and
                      evictions' progress: what it sees must be whole or absent. *)
                   match
                     Page_cache.get_window cache ~rung:"http" ~url:key ~offset:0 ~max_chars:4_000
                   with
                   | None -> ()
                   | Some (found : Page_cache.cached_page) ->
                       incr raced;
                       check i found);
               ])
             keys);
        (* At rest: the cap's survivors, read one by one, with the same window the
           live read of that page would cut. *)
        let whole = ref 0 and gone = ref 0 in
        List.iter
          (fun i ->
            match
              Page_cache.get_window cache ~rung:"http" ~url:(url ("/" ^ string_of_int i))
                ~offset:0 ~max_chars:4_000
            with
            | Some (found : Page_cache.cached_page) ->
                check i found;
                incr whole
            | None -> incr gone)
          keys;
        let entries, bytes = Page_cache.stats cache in
        (!raced, !whole, !gone, !partials, entries, bytes)
  in
  Alcotest.(check bool)
    (Printf.sprintf "no read saw a page out of two generations, of %d hits during the race and %d \
                     keys read at rest" raced (whole + gone))
    false (partials > 0);
  Alcotest.(check bool) "the cap kept entries: the settled directory has whole pages" true
    (whole > 0);
  Alcotest.(check int) "each key is either there whole or not at all" (List.length keys) (whole + gone);
  Alcotest.(check bool) "the eviction pass kept the directory inside its cap" true (bytes <= cap);
  Alcotest.(check bool) "and it left entries behind" true (entries > 0)

let stats_count_bodies () =
  with_cache () (fun h ->
      ignore (Page_cache.put h.cache ~rung:"http" ~url:(url "/a") ~page:(page "12345"));
      let b = Page_cache.entry_name ~rung:"http" ~url:(url "/b") in
      write_through h (body_name b) "an orphan body counts";
      let entries, bytes = Page_cache.stats h.cache in
      Alcotest.(check int) "bodies, whatever their sidecars" 2 entries;
      Alcotest.(check int) "the bytes are the bodies' own"
        (5 + String.length "an orphan body counts") bytes)

let stats_of_an_empty_directory () =
  with_cache () (fun h -> Alcotest.(check (pair int int) "nothing cached") (0, 0) (Page_cache.stats h.cache))

let () =
  let open Alcotest in
  run "page cache"
    [
      ( "the key",
        [
          test_case "a rung and a validated url" `Quick the_key_is_the_rungs_and_the_urls_hash;
          test_case "the local reader and a fallback never share an entry" `Quick
            rungs_do_not_share_an_entry;
        ] );
      ( "reads and misses",
        [
          test_case "a stored page reads back whole" `Quick a_stored_page_reads_back_whole;
          test_case "an absent entry is a miss" `Quick an_absent_entry_is_a_miss;
          test_case "an expired entry is a miss and its files go" `Quick
            an_expired_entry_is_a_miss_and_its_files_go;
          test_case "a corrupt sidecar is a miss" `Quick a_corrupt_sidecar_is_a_miss;
          test_case "half an entry is a miss" `Quick half_an_entry_is_a_miss;
          test_case "a restart reads the directory, not a previous process" `Quick
            a_restart_reads_the_directory_not_a_previous_process;
        ] );
      ( "the bounds",
        [
          test_case "an entry over the per-entry cap is never stored" `Quick
            an_entry_over_the_entry_cap_is_never_stored;
          test_case "the directory cap evicts the least recently read" `Quick
            the_directory_cap_evicts_the_least_recently_read;
          test_case "a hit touches the sidecar, not the body" `Quick
            a_hit_touches_the_sidecar_not_the_body;
          test_case "a read-only root refuses the store" `Quick a_read_only_root_refuses_the_store;
        ] );
      ( "the window",
        [
          test_case "a cached window is the window [window_text] cuts" `Quick window_parity;
          test_case "a windowed read never loads the whole body" `Quick
            a_windowed_read_never_loads_the_whole_body;
          test_case "a window across a chunk boundary is still the live window" `Quick
            a_window_across_a_chunk_boundary_is_still_the_live_window;
        ] );
      ( "concurrency",
        [
          test_case "reads, writes and evictions agree" `Quick
            concurrent_reads_writes_and_evictions_agree;
        ] );
      ( "diagnosis",
        [
          test_case "stats count bodies" `Quick stats_count_bodies;
          test_case "an empty directory reports nothing" `Quick stats_of_an_empty_directory;
        ] );
    ]
