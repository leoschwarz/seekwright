(* Engine.Fetch: the route, the notices, the escape pass, and what the operator and
   the dashboard get out of a page read. Ported case for case from
   [tests/fetch/test_fetch_engine.py].

   Two families of the Python suite are deliberately not ported, and both are
   pinned elsewhere rather than dropped:

   - the cases that [patch] a jsondoc or tabledoc function ([select_passages],
     [select_paths], [parse_path], [render_schema], [render_table]) and assert on
     the arguments the patched function was handed.  The document readers are P6,
     so the portable half here is a test-local [Readers] stub that owns only the
     engine's facts: the per-section character budget, the dropped-section count,
     offsets that index the whole rendering rather than the window, and the
     refusal of a selector that cannot be addressed.  The line grammar itself
     stays pinned where it lives.

   - the module-shape assertions of [tests/fetch/test_engine_structure.py] (no
     FastMCP import, no cache, the shared httpx client, the never-callable
     [_read_page], and the discipline that no test patches a read method).  The
     OCaml counterpart of the import guards is the [lib/dune] dependency pin that
     [test/router_dependencies.ml] already checks; the rest is Python-only
     structure. *)

module Caps = Mcp_caps
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Router = Seekwright.Router
module Sanitize = Seekwright.Sanitize
module Usage = Seekwright.Usage
module A = Alcotest

let zwsp = Sanitize.zwsp

(* Both clocks are the same fixed instant, so [retrieved_at] is a fact to assert
   on and every [ms] field is exactly [0]. *)
let clock () = 1768478400.
let now () = 1768478400.

(* {1 Reads}

   [Usage.snapshot] is a [Yojson.Safe.t] and the log capture is a field list;
   these are the loose reads the Python suite gets from dicts. *)
let get key = function
  | `Assoc fields -> (try List.assoc key fields with Not_found -> `Null)
  | _ -> `Null

let items = function `List xs -> xs | _ -> []
let str = function `String s -> s | `Null -> "" | v -> Yojson.Safe.to_string v

let int = function
  | `Int n -> n
  | `Float f -> int_of_float f
  | v -> A.failf "not a count: %s" (Yojson.Safe.to_string v)

let bool = function `Bool b -> b | v -> A.failf "not a flag: %s" (Yojson.Safe.to_string v)
let is_null = (( = ) `Null)

let money label expected = function
  | `Int n -> A.(check (float 1e-9) label (float_of_int n) expected)
  | `Float f -> A.(check (float 1e-9) label f expected)
  | v -> A.failf "%s: not a money figure: %s" label (Yojson.Safe.to_string v)

let find_sub_from ?(start = 0) text needle =
  let needle_length = String.length needle in
  let haystack_length = String.length text in
  let rec go index =
    if index + needle_length > haystack_length
    then None
    else if String.sub text index needle_length = needle
    then Some index
    else go (index + 1)
  in
  go start

let includes label needle text =
  match find_sub_from text needle with
  | Some _ -> ()
  | None -> A.failf "%s: the text did not contain %S\n     it was: %S" label needle text

let excludes label needle text =
  match find_sub_from text needle with
  | None -> ()
  | Some _ -> A.failf "%s: the text contained %S, and must not\n     it was: %S" label needle text

let say = function Some s -> s | None -> ""

let check_string = A.(check string)
let check_int = A.(check int)
let check_bool = A.(check bool)
let check_opt_string = A.(check (option string))
let check_strings = A.(check (list string))
let check_ints = A.(check (list int))
let check_opt_int = A.(check (option int))

let is_prefix prefix text =
  let length = String.length prefix in
  String.length text >= length && String.sub text 0 length = prefix

(* {1 The page and the fetcher stub}

   Python's [StubFetcher] is a duck-typed object, and [Engine.Fetch.fetcher] is a
   record of the same four fields, so the stub is a mutable record plus the
   [make_fetcher] that turns one into what the engine holds.  [calls] and
   [kwargs] are the two reads the Python suite uses to see the route: how many
   dispatches a call made, and what each was asked for. *)

let url = "https://example.com/article"

(* Long enough to clear [fetch.min_text_chars]: a good page has to look like one,
   or every success case here would be the empty-extraction case. *)
let page_text =
  "The page body. Every fetch test that means to exercise a successful extraction"
  ^ " uses this string, so it has to be long enough that the engine does not"
  ^ " mistake it for the nav stub a JavaScript-rendered page leaves behind."
  ^ " Anything shorter is the empty case, which has its own tests."

let page_len = String.length page_text

type fetcher_stub = {
  name : string;
  calls : int ref;
  kwargs : (int * Engine.Fetch.cap) list ref;
  cost_per_1k : float option;
  text : string;
  landed : string option;
  title : string option;
  content_type : string option;
  path_addressable : bool;
  image : Engine.Fetch.image option;
  fail : Engine.Fetch.fetch_error option;
}

let stub ?(name = "fetch") ?fail ?(cost_per_1k = None) ?(text = page_text) ?landed
    ?(title = Some "A Page") ?(content_type = Some "text/html") ?(path_addressable = false) ?image () =
  {
    name;
    calls = ref 0;
    kwargs = ref [];
    cost_per_1k;
    text;
    landed;
    title;
    content_type;
    path_addressable;
    image;
    fail;
  }

let make_fetcher (s : fetcher_stub) : Engine.Fetch.fetcher =
  {
    Engine.Fetch.name = s.name;
    cost_per_1k = s.cost_per_1k;
    fetch =
      (fun ~url:target ~offset ~max_chars ->
        incr s.calls;
        s.kwargs := !(s.kwargs) @ [ (offset, max_chars) ];
        match s.fail with
        | Some error -> Error error
        | None ->
          (* An image page carries no text and no title: its type is the image's
             own, which is what the body's bytes agreed with. *)
          (match s.image with
          | Some image ->
            Ok
                {
                  Engine.Fetch.url = (match s.landed with Some u -> u | None -> target);
                  title = None;
                  text = "";
                  content_type = Some image.media_type;
                  status_code = 200;
                  truncated = false;
                  total_chars = 0;
                  path_addressable = false;
                  image = Some image;
                }
          | None ->
            Ok
              {
                Engine.Fetch.url = (match s.landed with Some u -> u | None -> target);
                title = s.title;
                text = s.text;
                content_type = s.content_type;
                status_code = 200;
                truncated = false;
                total_chars = String.length s.text;
                path_addressable = s.path_addressable;
                image = None;
              });
        );
    aclose = (fun () -> ());
  }

(* {1 The document readers, as a test stub}

   [jsondoc] and [tabledoc] are P6, and their grammar has its own suite where it
   lives.  What this suite owns is the engine's half of a selection: that the
   budget bounds the response and not the read, that a caller's offsets index the
   whole rendering, and which sentence a request that cannot be honoured comes
   back with.  A case that wants an answer of its own sets [spans], [passages] or
   [bad_path] on the stub; every other case gets the generic behaviour below,
   which is the paragraph- and line-level arithmetic the Python fixtures were
   built to exercise. *)

(* [render_json] of [{{"total": 2, "query": "json path expressions", "items":
   [{{"id": 1, "name": "alpha", "language": "Python", "url":
   "https://example.test/alpha"}}, {{"id": 2, "name": "beta", "language": "Rust",
   "url": "https://example.test/beta"}}]}}, written out by hand for the same
   reason the reader is a stub: this is the text the engine selects over.  The
   document is long enough that its rendering clears [fetch.min_text_chars]: a
   small one here would be tested as the empty-page case. *)
let rendered =
  "$.total  2\n\
   $.query  \"json path expressions\"\n\
   $.items  array(2)\n\
   $.items[0]  object(4)\n\
   $.items[0].id  1\n\
   $.items[0].name  \"alpha\"\n\
   $.items[0].language  \"Python\"\n\
   $.items[0].url  \"https://example.test/alpha\"\n\
   $.items[1]  object(4)\n\
   $.items[1].id  2\n\
   $.items[1].name  \"beta\"\n\
   $.items[1].language  \"Rust\"\n\
   $.items[1].url  \"https://example.test/beta\""

(* A rendering line's path: everything up to the two spaces that precede its
   value. *)
let line_path line =
  match find_sub_from line "  " with Some i -> String.sub line 0 i | None -> line

let split_on_string separator text =
  (* [String.split_on_char] has no substring twin; this is the split the passage
     sections need. *)
  let seplen = String.length separator in
  let rec go offset acc =
    match find_sub_from text ~start:offset separator with
    | Some i -> go (i + seplen) (String.sub text offset (i - offset) :: acc)
    | None -> List.rev (String.sub text offset (String.length text - offset) :: acc)
  in
  if seplen = 0 then [ text ] else go 0 []

let lines_with_offsets text =
  let rec go offset acc = function
    | [] -> List.rev acc
    | line :: rest -> go (offset + String.length line + 1) ((offset, line) :: acc) rest
  in
  go 0 [] (String.split_on_char '\n' text)

(* A rendering line is inside [node]'s subtree when it is the node's own line or
   a child path of it. *)
let in_subtree node lp =
  let nlen = String.length node in
  lp = node
  || (String.length lp > nlen
      && String.sub lp 0 nlen = node
      && (lp.[nlen] = '.' || lp.[nlen] = '['))

(* A selector is one node, or, written with [*], a family of lines. *)
let path_matches selector lp =
  match find_sub_from selector "[*]" with
  | Some i ->
    let head = String.sub selector 0 i in
    let tail = String.sub selector (i + 3) (String.length selector - i - 3) in
    let ll = String.length lp in
    ll >= String.length head + String.length tail
    && String.sub lp 0 (String.length head) = head
    && String.sub lp (ll - String.length tail) (String.length tail) = tail
  | None -> selector = lp

let sections_at text ~max_chars selector =
  let lines = lines_with_offsets text in
  let matched =
    List.filter (fun (_offset, line) -> path_matches selector (line_path line)) lines
  in
  if matched = []
  then []
  else if find_sub_from selector "[*]" <> None
  then matched
  else
    List.flatten
      (List.map
         (fun (offset, line) ->
           let node = line_path line in
           let rec take acc = function
             | [] -> List.rev acc
             | (other, later) :: rest ->
                 if other < offset
                 then take acc rest
                 else if line_path later = node || in_subtree node (line_path later)
                 then take ((other, later) :: acc) rest
                 else List.rev acc
           in
           let block = take [] lines in
           let body = String.concat "\n" (List.map snd block) in
           (* A subtree that does not fit the budget whole is offered a line at a
              time, so a caller still gets what fits and the count of what did
              not is the number the budget notice reports. *)
           if String.length body <= max_chars || List.length block <= 1
           then [ (offset, body) ]
           else block)
         matched)

let within_sections sections budget =
  (* Fill the budget in order and count what was cut: the two numbers the budget
     notices report. *)
  let used = ref 0 in
  let kept = ref [] in
  let dropped = ref 0 in
  let stop = ref false in
  List.iter
    (fun (offset, body) ->
      if !stop
      then dropped := !dropped + 1
      else if !used + String.length body <= budget
      then begin
        used := !used + String.length body;
        kept := !kept @ [ (offset, body) ]
      end
      else begin
        stop := true;
        dropped := !dropped + 1
      end)
    sections;
  (!kept, !dropped)

let paragraphs text =
  (* One section per blank-line-separated block, each carrying its offset into
     the whole text: what [extractors.base] hands [select_passages] and what the
     walrus fixtures are built so that each match sits in its own. *)
  let rec go offset acc = function
    | [] -> List.rev acc
    | para :: rest ->
        let length = String.length para in
        go (offset + length + 2) ((offset, para) :: acc) rest
  in
  go 0 [] (split_on_string "\n\n" text)

let terms_match query text =
  let lower = String.lowercase_ascii text in
  List.exists
    (fun term -> term <> "" && find_sub_from lower term <> None)
    (String.split_on_char ' ' (String.lowercase_ascii query))

let doc_readers : Engine.Fetch.Readers.t =
  {
    Engine.Fetch.Readers.parse_path =
      (fun selector ->
        (* A filter expression is not in the grammar, and a caller that asks for
           one is refused before a byte is fetched. *)
        if find_sub_from selector "[?(" <> None
        then Error "a filter is not a path this server can read"
        else Ok ());
    (* [doc_readers] renders no schema: the shape grammar is a [render_schema]
       question pinned with the readers that build it, so the [structure] cases
       below hand the engine [schema_readers] instead. *)
    render_schema = (fun _text -> None);
    select_paths =
      (fun ~text ~path ~max_chars -> within_sections (sections_at text ~max_chars path) max_chars);
    select_passages =
      (fun ~text ~query ~max_chars ->
        within_sections
          (List.filter (fun (_offset, body) -> terms_match query body) (paragraphs text))
          max_chars);
  }

(* {1 The log capture, and the engine fixture}

   The injected sink replaces loguru's [log_records]: an event is a name and its
   bound fields, which pins the field set exactly because an unexpected field is
   a list entry rather than an attribute on an object. *)

(* The level is captured too: an event that moved off its level is as much a
   contract change as a field that moved. *)
type captured = { level : Config.log_level; event : string; fields : (string * Yojson.Safe.t) list }

let sink lines : Engine.log =
  fun level event fields -> lines := !lines @ [ { level; event; fields } ]

let levels lines name =
  List.filter_map (fun (c : captured) -> if c.event = name then Some c.level else None) !lines

let level_of lines name =
  match levels lines name with
  | [ level ] -> level
  | many -> A.failf "expected one %s event, got %d" name (List.length many)

let events lines name =
  List.filter_map (fun (c : captured) -> if c.event = name then Some c.fields else None) !lines

let event lines name =
  match events lines name with
  | [ only ] -> only
  | many -> A.failf "expected exactly one %s, got %d" name (List.length many)

let field fields name = get name (`Assoc fields)

let level_name = function
  | Config.Log_debug -> "DEBUG"
  | Config.Log_info -> "INFO"
  | Config.Log_warning -> "WARNING"
  | Config.Log_error -> "ERROR"
  | Config.Log_critical -> "CRITICAL"
  | Config.Log_trace -> "TRACE"
  | Config.Log_success -> "SUCCESS"

let check_level label expected actual =
  check_string label (level_name actual) (level_name expected)

(* [Usage.create] can refuse for the two journal checks a server makes before it
   is ready to serve; an in-memory recorder cannot fail. *)
let recorder () =
  match Usage.create ~now () with
  | Ok usage -> usage
  | Error message -> A.failf "an in-memory recorder cannot fail: %s" message

type board = {
  engine : Engine.Fetch.t;
  lines : captured list ref;
  local : fetcher_stub;
  fallbacks : fetcher_stub list;
  usage : Usage.t option;
}

(* [make_engine]'s mirror: a config whose [fetch] section is the case's, the local
   reader as the primary route, and the built fallbacks behind it.  The provider
   block is the implicit keyless set: this suite never dispatches a search
   provider, and [Config] needs a non-empty set to resolve. *)
let make_engine ?(fetch = Config.default_fetch_config)
    ?(logging = Config.default_logging_config) ?usage ?(readers = doc_readers) ?(fallbacks = [])
    ?(local = stub ()) () =
  let lines = ref [] in
  let config =
    match Config.resolve ~fetch ~logging () with
    | Ok config -> config
    | Error message -> A.failf "the fixture config was refused: %s" message
  in
  let usage = Option.map (fun (u : Usage.t) -> u) usage in
  match
    Engine.Fetch.create config (make_fetcher local) ~readers ?usage
      ~log:(sink lines) ~fallbacks:(List.map make_fetcher fallbacks) ~clock ~now ()
  with
  | Error message -> A.failf "the engine refused the fixture: %s" message
  | Ok engine ->
    { engine; lines; local; fallbacks; usage }

let ok board = event board.lines "fetch.ok"
let recent board = items (get "recent" (Usage.snapshot (Option.value ~default:(recorder ()) board.usage)))
let one_recent board =
  match recent board with
  | [ entry ] -> entry
  | many -> A.failf "expected one usage entry, got %d" (List.length many)

(* Answers and failures.  The Python suite reads [str(exc.value)] on both sides of
   [pytest.raises]; here the refusal and the failure are returned values whose
   payload is that same sentence, and the two channels stay apart because the REST
   projection reports them as 400 and 502. *)
let served board ?offset ?query ?path ?(structure = false) ?provider ?auto_fallback ?run ?step target =
  match Engine.Fetch.fetch board.engine ?offset ?query ?path ~structure ?provider ?auto_fallback ?run ?step target with
  | Ok response -> response
  | Error (Engine.Fetch.Refused sentence) -> A.failf "the fetch was refused: %s" sentence
  | Error (Engine.Fetch.Failed sentence) -> A.failf "the fetch failed: %s" sentence

let refused board ?offset ?query ?path ?(structure = false) ?provider target =
  match Engine.Fetch.fetch board.engine ?offset ?query ?path ~structure ?provider target with
  | Ok response -> A.failf "expected a refusal, got a page: %s" (say response.Model.notice)
  | Error (Engine.Fetch.Refused sentence) -> sentence
  | Error (Engine.Fetch.Failed sentence) -> A.failf "expected a refusal, got a failure: %s" sentence

let failed board ?offset ?query ?path ?provider ?auto_fallback ?run ?step target =
  match Engine.Fetch.fetch board.engine ?offset ?query ?path ?provider ?auto_fallback ?run ?step target with
  | Ok response -> A.failf "expected a failure, got a page: %s" (say response.Model.notice)
  | Error (Engine.Fetch.Failed sentence) -> sentence
  | Error (Engine.Fetch.Refused sentence) -> A.failf "expected a failure, got a refusal: %s" sentence

(* {1 TestSuccess} *)

let one_kwargs board name =
  let found =
    List.filter (fun (s : fetcher_stub) -> s.name = name) (board.local :: board.fallbacks)
  in
  match found with
  | [] -> A.failf "no fetcher named %s in this fixture" name
  | [ fetcher ] -> !(fetcher.kwargs)
  | many -> A.failf "%d fetchers named %s" (List.length many) name

let check_kw board name ~(offset : int) ~(max_chars : Engine.Fetch.cap) =
  match one_kwargs board name with
  | [ seen ] ->
    check_int (name ^ " offset") offset (fst seen);
    (match (snd seen, max_chars) with
    | Engine.Fetch.Default, Engine.Fetch.Default -> ()
    | Engine.Fetch.Uncapped, Engine.Fetch.Uncapped -> ()
    | Engine.Fetch.Limit a, Engine.Fetch.Limit b -> check_int (name ^ " max_chars") a b
    | _, _ -> A.failf "%s was asked for %s, not %s" name
        (match snd seen with
        | Engine.Fetch.Default -> "the configured limit"
        | Engine.Fetch.Uncapped -> "no limit"
        | Engine.Fetch.Limit n -> string_of_int n)
        (match max_chars with
        | Engine.Fetch.Default -> "the configured limit"
        | Engine.Fetch.Uncapped -> "no limit"
        | Engine.Fetch.Limit n -> string_of_int n))
  | many -> A.failf "expected one dispatch to %s, got %d" name (List.length many)

let page_text_is_returned () =
  let board = make_engine () in
  let r = served board url in
  check_string "text" page_text (say r.Model.text);
  check_opt_string "title" (Some "A Page") r.Model.title;
  check_int "status_code" 200 (Option.value ~default:0 r.Model.status_code);
  check_bool "retrieved_at" true (r.Model.retrieved_at <> None);
  check_opt_string "notice" None r.Model.notice

let requested_url_is_always_reported () =
  (* A caller that cannot see a redirect happened cannot judge the content. *)
  let local = stub ~landed:"https://example.com/article-final" () in
  let r = served (make_engine ~local ()) url in
  check_string "requested_url" url r.Model.requested_url;
  check_string "url" "https://example.com/article-final" r.Model.url

let every_call_fetches () =
  let local = stub () in
  let board = make_engine ~local () in
  ignore (served board url);
  ignore (served board url);
  check_int "calls" 2 !(local.calls)

(* {1 TestFailure} *)

let failure_raises () =
  let local = stub ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"fetch" "503")) () in
  let message = failed (make_engine ~local ()) url in
  includes "the retry sentence" "Retry shortly" message

let blocked_url_does_not_advise_a_retry () =
  (* A guardrail refusal will refuse again; saying retry invites a loop.  The
     configured ladder is the case that let the loop back in: with the walk
     withheld the failure appends the configured names as something to retry on,
     and every remote fallback runs the same SSRF check, so the retry that
     sentence names is refused by construction.  A guardrail refusal leaves no
     choice to hand back: its reason already says what was refused, and the
     message ends there whether or not a ladder is configured. *)
  List.iteri
    (fun rung ladder ->
      let local = stub ~fail:(Engine.Fetch.Fetch_blocked "private address") () in
      let fetch =
        {
          Config.default_fetch_config with
          Config.fallback = (if rung = 0 then None else Some [ "scrappa" ]);
        }
      in
      let board = make_engine ~fetch ~local ~fallbacks:ladder () in
      let message = failed board url in
      check_string "the message ends at the reason" "Fetch failed - fetch: private address." message;
      excludes "no invitation to retry" "Retry" message;
      excludes "no ladder offered" "Other configured fetch providers" message)
    [ []; [ stub ~name:"scrappa" () ] ]

(* {1 TestEmptyExtraction} *)

let empty_text_is_reported_not_raised () =
  let r = served (make_engine ~local:(stub ~text:"" ()) ()) url in
  check_string "text" "" (say r.Model.text);
  includes "the shell diagnosis" "JavaScript-rendered" (say r.Model.notice)

(* {1 TestQueryTargeting} *)

let walrus_first = "The walrus lives in the arctic. " ^ String.make 1600 'x'
let walrus_second = "The walrus eats clams. " ^ String.make 1600 'y'

let query_fetches_uncapped () =
  let local = stub () in
  let board = make_engine ~local () in
  ignore (served board ~query:"walrus" url);
  check_kw board "fetch" ~offset:0 ~max_chars:Engine.Fetch.Uncapped

let query_returns_matches_with_absolute_offsets () =
  (* The pads push each matching paragraph into its own section, and the
     zero-score filler between the matches keeps them separate. *)
  let text = walrus_first ^ "\n\n" ^ walrus_second in
  let r = served (make_engine ~local:(stub ~text ()) ()) ~query:"walrus" url in
  check_bool "a matches response never also carries the page" true (r.Model.text = None);
  check_int "total_chars" (String.length text) (Option.value ~default:0 r.Model.total_chars);
  match r.Model.matches with
  | None -> failwith "expected matches"
  | Some found ->
    check_ints "offsets" [ 0; String.length walrus_first + 2 ]
      (List.map (fun (m : Model.fetch_match) -> m.Model.offset) found);
    List.iter
      (fun (m : Model.fetch_match) ->
        includes "the match carries the term" "walrus" m.Model.text;
        check_string "a match's offset must locate its own text"
          (String.sub text m.Model.offset (String.length m.Model.text))
          m.Model.text)
      found

let query_with_no_hits_says_so_and_leaves_text_unset () =
  let r = served (make_engine ()) ~query:"zzzqqq" url in
  check_bool "matches is an empty list" true (r.Model.matches = Some []);
  check_bool "text unset" true (r.Model.text = None);
  includes "the no-hit sentence" "none of the query terms appear" (say r.Model.notice);
  includes "and the way out" "fetch without `query`" (say r.Model.notice)

let query_over_budget_reports_dropped_sections () =
  let paras =
    List.init 3 (fun i -> "Walrus " ^ string_of_int i ^ ". " ^ String.make 1600 'x')
  in
  let text = String.concat "\n\n" paras in
  let board =
    make_engine ~fetch:{ Config.default_fetch_config with Config.max_match_chars = 2000 }
      ~local:(stub ~text ()) ()
  in
  let r = served board ~query:"walrus" url in
  check_bool "text unset" true (r.Model.text = None);
  (match r.Model.matches with
  | None -> failwith "expected matches"
  | Some found -> check_int "one section fit" 1 (List.length found));
  includes "the budget sentence"
    "passage budget (2000 chars) reached; 2 more matching section(s) not returned"
    (say r.Model.notice)

let query_on_an_unreadable_page_keeps_the_shell_diagnosis () =
  let r = served (make_engine ~local:(stub ~text:"" ()) ()) ~query:"walrus" url in
  check_bool "no matches, not an empty selection" true (r.Model.matches = None);
  includes "the shell diagnosis" "JavaScript-rendered" (say r.Model.notice);
  excludes "and not a no-hit sentence" "none of the query terms" (say r.Model.notice)

(* {1 TestJsonPathTargeting}

   [path] reads one part of a JSON document instead of the document.  The grammar
   and the selection arithmetic are pinned in the document-reader suite; what is
   pinned here is the engine's half: that a selection is uncapped at the fetcher
   and bounded in the response, that the offsets a caller gets index the whole
   rendering, and which sentence a request that cannot be honoured comes back
   with. *)

let json () =
  (* [path_addressable] is what the real fetcher carries out of an extraction
     that rendered a structure; a stub that left it out would be testing the
     notice for a page with no structure. *)
  stub ~text:rendered ~title:None ~content_type:(Some "application/json") ~path_addressable:true ()

let a_path_fetches_uncapped () =
  (* The budget bounds the response, not the document read to select from it. *)
  let local = json () in
  let board = make_engine ~local () in
  ignore (served board ~path:"$.total" url);
  check_kw board "fetch" ~offset:0 ~max_chars:Engine.Fetch.Uncapped

let a_path_returns_the_subtree_at_an_offset_into_the_rendering () =
  let r = served (make_engine ~local:(json ()) ()) ~path:"$.items[1]" url in
  check_bool "a matches response never also carries the page" true (r.Model.text = None);
  check_int "total_chars" (String.length rendered) (Option.value ~default:0 r.Model.total_chars);
  match r.Model.matches with
  | Some [ span ] ->
    check_bool "the subtree starts at its own line" true
      (is_prefix "$.items[1]  object(4)" span.Model.text);
    check_string "the offset indexes the whole rendering"
      (String.sub rendered span.Model.offset (String.length span.Model.text))
      span.Model.text;
    excludes "and holds only that element" "$.items[0]" span.Model.text
  | Some many -> A.failf "expected one match, got %d" (List.length many)
  | None -> failwith "expected matches"

let a_wildcard_path_returns_one_match_per_element () =
  let r = served (make_engine ~local:(json ()) ()) ~path:"$.items[*].name" url in
  check_strings "one span per element"
    [ "$.items[0].name  \"alpha\""; "$.items[1].name  \"beta\"" ]
    (match r.Model.matches with
    | Some found -> List.map (fun (m : Model.fetch_match) -> m.Model.text) found
    | None -> []);
  let at line =
    match find_sub_from rendered line with
    | Some offset -> offset
    | None -> A.failf "the rendering does not carry %s" line
  in
  check_ints "and their offsets index the whole rendering"
    [ at "$.items[0].name  \"alpha\""; at "$.items[1].name  \"beta\"" ]
    (match r.Model.matches with
    | Some found -> List.map (fun (m : Model.fetch_match) -> m.Model.offset) found
    | None -> [])

let a_path_that_matches_nothing_says_the_structure_is_one_away () =
  let r = served (make_engine ~local:(json ()) ()) ~path:"$.nope" url in
  check_bool "text unset" true (r.Model.text = None);
  check_bool "matches is an empty list" true (r.Model.matches = Some []);
  includes "the way to the structure" "without `path`" (say r.Model.notice)

let a_path_on_a_page_with_no_structure_returns_the_page () =
  (* The request only means something about JSON; the page is still the answer. *)
  let r = served (make_engine ()) ~path:"$.items" url in
  check_string "the page" page_text (say r.Model.text);
  check_bool "no matches" true (r.Model.matches = None);
  includes "the constraint is named" "not one this server could read" (say r.Model.notice)

let a_page_whose_text_happens_to_start_with_a_dollar_is_still_a_page () =
  (* A Makefile is a routine fetch target on a code host, and its text begins
     [$ make all].  Reading "is this a document" off the first character answered
     that page with [matches: []] and a sentence asserting it was a JSON document
     with nothing at that path, which withheld a page the caller had already been
     billed for. *)
  let page =
    stub ~text:("$ make all\n" ^ String.concat "" (List.init 20 (fun _ -> "# build every target in the directory\n")))
      ~title:None ~content_type:(Some "text/plain") ()
  in
  let r = served (make_engine ~local:page ()) ~path:"$.src" url in
  check_bool "the page comes back" true (r.Model.text <> None);
  check_bool "the page begins as it was written" true
    (is_prefix "$ make all" (say r.Model.text));
  check_bool "no matches" true (r.Model.matches = None);
  includes "the constraint is named" "not one this server could read" (say r.Model.notice)

let a_json_claim_on_a_body_that_is_not_a_document_says_which () =
  let stub_page =
    (* A malformed body long enough not to read as the empty-page case. *)
    stub ~text:("{\"total\": 2,, \"items\": [" ^ String.concat "" (List.init 8 (fun _ -> "\"a very long record that goes on and on\", ")) ^ "]}")
      ~title:None ~content_type:(Some "application/json") ()
  in
  let r = served (make_engine ~local:stub_page ()) ~path:"$.total" url in
  check_bool "the body is what a caller can act on" true (r.Model.text <> None);
  includes "and the constraint is named" "not one this server could read" (say r.Model.notice)

let a_selection_cut_before_its_first_span_says_so () =
  (* A budget too small for the smallest match is a cut answer, not a no-match. *)
  let board =
    make_engine ~fetch:{ Config.default_fetch_config with Config.max_match_chars = 20 }
      ~local:(json ())  ()
  in
  let r = served board ~path:"$.items[0]" url in
  check_bool "nothing was returned" true (r.Model.matches = Some []);
  includes "the budget is what cut it" "larger than the selection budget" (say r.Model.notice);
  excludes "and it is not called a no-match" "nothing in this document matches" (say r.Model.notice)

let a_path_over_budget_reports_what_was_cut_and_how_to_narrow_it () =
  let board =
    make_engine ~fetch:{ Config.default_fetch_config with Config.max_match_chars = 60 }
      ~local:(json ())  ()
  in
  let r = served board ~path:"$.items" url in
  (match r.Model.matches with
  | Some found when found <> [] ->
    check_bool "every span fits the budget" true
      (List.for_all (fun (m : Model.fetch_match) -> String.length m.Model.text <= 60) found)
  | _ -> failwith "expected spans within the budget");
  includes "the budget sentence" "selection budget (60 chars) reached" (say r.Model.notice);
  includes "and how to narrow it" "narrower `path`" (say r.Model.notice)

let a_path_selects_nothing_on_an_unreadable_page () =
  (* The empty-shell diagnosis outranks a structural no-match, as with [query]. *)
  let r = served (make_engine ~local:(stub ~text:"" ()) ()) ~path:"$.items" url in
  includes "the shell diagnosis" "JavaScript-rendered" (say r.Model.notice)

let a_path_with_a_query_is_refused () =
  check_string "one axis at a time" "pass `path`, `query` or `offset`, one at a time"
    (refused (make_engine ~local:(json ()) ()) ~query:"alpha" ~path:"$.items" url)

let a_path_with_an_offset_is_refused () =
  check_string "one axis at a time" "pass `path`, `query` or `offset`, one at a time"
    (refused (make_engine ~local:(json ()) ()) ~offset:40 ~path:"$.items" url)

let an_unreadable_path_is_refused_before_anything_is_fetched () =
  (* A selector nobody can read must not cost a fetch, let alone a fallback
     credit. *)
  let local = json () in
  let board = make_engine ~local () in
  includes "the refusal names the parameter" "`path` is not readable"
    (refused board ~path:"$.items[?(@.id)]" url);
  check_int "nothing was fetched" 0 !(local.calls)

(* {1 TestStructureReads}

   The engine's half of [tests/fetch/test_engine_structure.py]: that a shape
   read replaces the page's text with the schema before the escape pass, that it
   reads the whole document, that it never escalates to the fallback ladder over
   emptiness, and that it refuses to share an axis with a drill. The shape
   grammar itself is P6 and stays pinned with the readers that build it, so the
   schema text here is a stand-in for what [render_schema] would render. *)

let schema =
  "$.total  number\n\
   $.query  string\n\
   $.items  array(2)\n\
   $.items[*].id  number\n\
   $.items[*].name  string"

let schema_readers : Engine.Fetch.Readers.t =
  { doc_readers with render_schema = (fun _text -> Some schema) }

let a_structure_read_returns_the_schema_not_the_page () =
  let board = make_engine ~readers:schema_readers ~local:(json ()) () in
  let r = served board ~structure:true url in
  check_opt_string "the shape replaces the page" (Some schema) r.Model.text;
  check_bool "no matches ride a shape read" true (r.Model.matches = None);
  excludes "no values ride a shape read" "\"alpha\"" (say r.Model.text)

let a_structure_read_fetches_uncapped () =
  (* A selection is one whole read; the budget bounds the response, not the fetch. *)
  let board = make_engine ~readers:schema_readers ~local:(json ()) () in
  ignore (served board ~structure:true url);
  check_kw board "fetch" ~offset:0 ~max_chars:Engine.Fetch.Uncapped

let a_tiny_structure_page_is_answered_without_a_walk () =
  (* The emptiness gate is about a JS shell, not a small but real document: a
     structure read of a page rendering below [fetch.min_text_chars] is a
     deliberate read of the shape and must not bill a fallback over emptiness,
     even with the walk asked for. *)
  let tiny = "$.n  1" in
  let local =
    stub ~text:tiny ~content_type:(Some "application/json") ~path_addressable:true ()
  in
  let ladder = stub ~name:"crawl4ai" ~text:"the ladder served prose instead" () in
  let fetch = { Config.default_fetch_config with min_text_chars = String.length tiny + 1 } in
  let board = make_engine ~fetch ~readers:schema_readers ~local ~fallbacks:[ ladder ] () in
  let r = served board ~structure:true ~auto_fallback:true url in
  check_int "the ladder was never dialed" 0 !(ladder.calls);
  check_opt_string "the shape is the answer" (Some schema) r.Model.text;
  excludes "no shell diagnosis" "JavaScript" (say r.Model.notice)

let a_structure_read_on_a_page_with_no_structure_returns_the_page () =
  let board = make_engine ~local:(stub ()) () in
  let r = served board ~structure:true url in
  check_opt_string "the whole page" (Some page_text) r.Model.text;
  includes "the constraint is named"
    "`structure` reports a JSON or CSV table's shape, and this page is not one"
    (say r.Model.notice)

let a_structure_read_with_a_query_is_refused_before_anything_is_fetched () =
  let local = stub () in
  let board = make_engine ~local () in
  includes "one axis at a time" "pass `structure` alone"
    (refused board ~structure:true ~query:"walrus" url);
  check_int "nothing was fetched" 0 !(local.calls)

let a_structure_read_with_a_path_is_refused_before_anything_is_fetched () =
  let local = stub () in
  let board = make_engine ~local () in
  includes "one axis at a time" "pass `structure` alone"
    (refused board ~structure:true ~path:"$.items" url);
  check_int "nothing was fetched" 0 !(local.calls)

let a_structure_read_with_an_offset_is_refused_before_anything_is_fetched () =
  let local = stub () in
  let board = make_engine ~local () in
  includes "one axis at a time" "pass `structure` alone"
    (refused board ~structure:true ~offset:8 url);
  check_int "nothing was fetched" 0 !(local.calls)

(* {1 TestOffsetPaging} *)

let offset_is_forwarded_to_the_fallback () =
  let local = stub () in
  let board = make_engine ~local () in
  let r = served board ~offset:100 url in
  check_kw board "fetch" ~offset:100 ~max_chars:Engine.Fetch.Default;
  check_opt_int "offset" (Some 100) r.Model.offset

let past_end_returns_a_notice_and_no_ladder () =
  let usage = recorder () in
  let local = stub () in
  let board = make_engine ~usage ~local () in
  let r = served board ~offset:(page_len + 5) url in
  check_string "text" "" (say r.Model.text);
  includes "the past-end sentence" "past the end" (say r.Model.notice);
  check_int "total_chars" page_len (Option.value ~default:0 r.Model.total_chars);
  check_opt_int "offset" (Some (page_len + 5)) r.Model.offset;
  check_int "a refetch of a known-readable page must not bill a fallback" 1 !(local.calls);
  (* A served call on both surfaces: the operator's line and the journal the
     dashboard counts from. *)
  check_int "one fetch.ok" 1 (List.length (events board.lines "fetch.ok"));
  check_int "chars" page_len (int (field (ok board) "chars"));
  check_bool "fell_back" false (bool (field (ok board) "fell_back"));
  let entry = one_recent board in
  check_string "tool" "fetch" (str (get "tool" entry));
  check_int "chars" page_len (int (get "chars" entry));
  check_bool "fallback is None" true (is_null (get "fallback" entry))

let query_and_offset_together_are_refused () =
  includes "the one-axis refusal" "not both"
    (refused (make_engine ()) ~offset:10 ~query:"some terms" url)

let offset_zero_stays_unset_on_the_response () =
  check_bool "offset unset" true ((served (make_engine ()) url).Model.offset = None)

let a_short_tail_window_gets_no_empty_diagnosis () =
  (* A few characters at the end of a page are a tail, not a JS shell. *)
  let local = stub () in
  let r = served (make_engine ~local ()) ~offset:(page_len - 3) url in
  check_opt_string "no notice" None r.Model.notice;
  check_int "one fetch" 1 !(local.calls)

(* {1 TestSpecialTokenEscaping}

   The page leaves escaped, counted on [fetch.ok].  The escape lands where every
   fallback's output converges — after the ladder, in the engine — so no fallback
   has to remember it, and the coordinates downstream (empty check, passage
   selection, past-end, the journal's chars) all read the same escaped text. *)

let ok_sanitize board = int (field (ok board) "sanitized")

let page_text_is_escaped_and_counted () =
  let board = make_engine ~local:(stub ~text:"the page says <|endoftext|> and nothing else" ()) () in
  let r = served board url in
  check_string "the token is split"
    ("the page says <" ^ zwsp ^ "|endoftext|> and nothing else")
    (say r.Model.text);
  check_int "and counted" 1 (ok_sanitize board)

let the_title_is_escaped_too () =
  let board =
    make_engine ~local:(stub ~text:page_text ~title:(Some "a title with [INST] in it") ()) ()
  in
  let r = served board url in
  check_string "the title is split" ("a title with [" ^ zwsp ^ "INST] in it") (say r.Model.title);
  check_int "and counted" 1 (ok_sanitize board)

let a_clean_page_counts_zero () =
  let board = make_engine () in
  ignore (served board url);
  check_int "nothing to escape" 0 (ok_sanitize board)

let a_past_end_response_escapes_the_title_and_counts () =
  let board = make_engine ~local:(stub ~title:(Some "a title with [INST] in it") ()) () in
  let r = served board ~offset:(page_len + 5) url in
  check_string "no text" "" (say r.Model.text);
  check_string "the title still travels, escaped"
    ("a title with [" ^ zwsp ^ "INST] in it")
    (say r.Model.title);
  includes "the past-end sentence" "past the end" (say r.Model.notice);
  check_int "and counted" 1 (ok_sanitize board)

let query_matches_are_escaped_in_escaped_space () =
  (* A token in a matching passage does not move the coordinate system: offsets
     still locate their own text, measured in the escaped page. *)
  let first = "The walrus lives in <|arctic|>. " ^ String.make 1600 'x' in
  let second = "The walrus eats clams. " ^ String.make 1600 'y' in
  let board = make_engine ~local:(stub ~text:(first ^ "\n\n" ^ second) ()) () in
  let r = served board ~query:"walrus" url in
  check_bool "text unset" true (r.Model.text = None);
  check_int "total_chars" (String.length first + String.length second + 2)
    (Option.value ~default:0 r.Model.total_chars);
  let escaped_first = "The walrus lives in <" ^ zwsp ^ "|arctic|>. " ^ String.make 1600 'x' in
  let escaped_page = escaped_first ^ "\n\n" ^ second in
  let found =
    match r.Model.matches with
    | Some found -> found
    | None -> A.failf "expected matches"
  in
  check_int "the escape is counted once for the page" 1 (ok_sanitize board);
  match found with
  | [ one; two ] ->
    check_ints "offsets in the escaped page" [ 0; String.length escaped_first + 2 ]
      [ one.Model.offset; two.Model.offset ];
    check_bool "the match carries the escaped token" true
      (is_prefix ("The walrus lives in <" ^ zwsp ^ "|arctic|>.") one.Model.text);
    excludes "and never the raw token" "<|arctic|>" one.Model.text;
    List.iter
      (fun (m : Model.fetch_match) ->
        check_string "the offset locates its own text, in the same escaped space"
          (String.sub escaped_page m.Model.offset (String.length m.Model.text))
          m.Model.text)
      [ one; two ]
  | many -> A.failf "expected two matches, got %d" (List.length many)

(* {1 TestObservability} *)

let a_url_is_logged_when_queries_are_opted_in () =
  let board = make_engine ~logging:{ Config.default_logging_config with Config.log_queries = true } () in
  ignore (served board url);
  check_string "the URL is repr'd, not bare" ("'" ^ url ^ "'") (str (field (ok board) "url"))

let an_empty_page_logs_the_empty_event () =
  let board = make_engine ~local:(stub ~text:"" ()) () in
  ignore (served board url);
  check_int "chars" 0 (int (field (event board.lines "fetch.empty") "chars"))

let a_readable_page_does_not_log_the_empty_event () =
  let board = make_engine () in
  ignore (served board url);
  check_bool "no empty event" true ([] = events board.lines "fetch.empty")

let a_failure_logs_its_reason_and_retryability () =
  let board = make_engine ~local:(stub ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"fetch" "503")) ()) () in
  ignore (failed board url);
  let fields = event board.lines "fetch.failed" in
  check_string "reason" "503" (str (field fields "reason"));
  check_level "a failure is levelled a warning" Config.Log_warning (level_of board.lines "fetch.failed");
  check_bool "retryable" true (bool (field fields "retryable"));
  check_bool "ms is a count" true (int (field fields "ms") >= 0)

let matches_replace_the_page_in_the_content_log () =
  let board =
    make_engine
      ~logging:{ Config.default_logging_config with Config.log_content = true }
      ~local:(stub ~text:(walrus_first ^ "\n\n" ^ walrus_second) ())
      ()
  in
  ignore (served board ~query:"walrus" url);
  let fields = event board.lines "fetch.content" in
  (* The join is what the caller got; [safe] reprs it onto the line, and repr
     renders the separator between matches as two escaped newlines. *)
  check_string "the matches, not the page"
    ("'" ^ walrus_first ^ "\\n\\n" ^ walrus_second ^ "'")
    (str (field fields "text"))
(* {1 TestUsageRecording}

   The dashboard's fetch half: chars and the fallback that served them. *)

let a_success_records_chars_and_no_fallback () =
  let board = make_engine ~usage:(recorder ()) () in
  ignore (served board url);
  let entry = one_recent board in
  check_string "tool" "fetch" (str (get "tool" entry));
  check_int "chars" page_len (int (get "chars" entry));
  check_bool "fallback is None" true (is_null (get "fallback" entry));
  check_bool "error is None" true (is_null (get "error" entry))

let a_failure_records_the_class_and_no_chars () =
  let board =
    make_engine ~usage:(recorder ())
      ~local:(stub ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"fetch" "503")) ())
      ()
  in
  ignore (failed board url);
  let entry = one_recent board in
  check_string "error" "ProviderError" (str (get "error" entry));
  check_int "chars" 0 (int (get "chars" entry));
  check_bool "fallback is None" true (is_null (get "fallback" entry))

let a_blocked_fetch_records_the_block_class () =
  let board =
    make_engine ~usage:(recorder ())
      ~local:(stub ~fail:(Engine.Fetch.Fetch_blocked "private address") ()) ()
  in
  ignore (failed board url);
  check_string "error" "FetchBlocked" (str (get "error" (one_recent board)))

let a_past_end_offset_records_the_call_it_billed () =
  (* A past-end offset is served: the page was fetched to learn its length. *)
  let board = make_engine ~usage:(recorder ()) () in
  ignore (served board ~offset:(page_len + 5) url);
  let entry = one_recent board in
  check_string "tool" "fetch" (str (get "tool" entry));
  check_int "chars" page_len (int (get "chars" entry));
  check_bool "fallback is None" true (is_null (get "fallback" entry));
  check_bool "error is None" true (is_null (get "error" entry))

(* {1 TestImagePages}

   The engine's half of an image fetch: carried, journaled, left alone.  The bytes
   themselves are the fetcher's business; what is pinned here is the shape of the
   decision around them: the base64 and the size reach the caller, no text field
   is filled, the ladder is never asked, and the operator's line says how many
   bytes left the process. *)

let image_url = "https://img.test/a.png"
let image_body = "\x89PNG\r\n\x1a\na png body"
let image_body_len = String.length image_body
let image_stub () =
  stub ~image:({ Engine.Fetch.media_type = "image/png"; body = image_body }) ()

let the_image_is_carried_and_the_text_fields_stay_unset () =
  let r = served (make_engine ~local:(image_stub ()) ()) image_url in
  check_bool "an image travels" true (r.Model.image <> None);
  (match r.Model.image with
  | Some image ->
    check_int "byte_count" image_body_len image.Model.byte_count;
    check_string "the bytes arrive whole" "iVBORw0KGgphIHBuZyBib2R5" image.Model.base64
  | None -> ());
  check_opt_string "content_type" (Some "image/png") r.Model.content_type;
  check_bool "text unset" true (r.Model.text = None);
  check_bool "matches unset" true (r.Model.matches = None);
  check_bool "total_chars unset" true (r.Model.total_chars = None);
  check_bool "not truncated" false r.Model.truncated

let the_notice_names_the_type_and_the_size () =
  let r = served (make_engine ~local:(image_stub ()) ()) image_url in
  check_bool "there is a notice" true (r.Model.notice <> None);
  includes "the type and the size"
    ("image/png image of " ^ string_of_int image_body_len ^ " bytes returned as image bytes")
    (say r.Model.notice)

let the_ladder_is_never_asked_for_an_image () =
  (* A renderer and a scraper billed to find prose in a photograph: the failure
     mode.  The emptiness gate that escalates reads an image's empty text as the
     JavaScript-shell symptom unless the image is checked for first. *)
  let fallback = stub () in
  let board = make_engine ~local:(image_stub ()) ~fallbacks:[ fallback ] () in
  let r = served board image_url in
  check_int "an image page has nothing for a fallback to fix" 0 !(fallback.calls);
  check_bool "the image still travels" true (r.Model.image <> None)

let an_offset_past_the_end_of_nothing_addresses_nothing () =
  (* Paging has no coordinate system here, and the image still arrives. *)
  let r = served (make_engine ~local:(image_stub ()) ()) ~offset:4000 image_url in
  check_bool "the image travels" true (r.Model.image <> None);
  check_bool "no offset" true (r.Model.offset = None);
  check_bool "no matches" true (r.Model.matches = None)

let the_call_is_journaled_as_a_call_with_no_text_chars () =
  let board = make_engine ~usage:(recorder ()) ~local:(image_stub ()) () in
  ignore (served board image_url);
  let entry = one_recent board in
  check_string "tool" "fetch" (str (get "tool" entry));
  check_int "chars" 0 (int (get "chars" entry));
  check_bool "fallback is None" true (is_null (get "fallback" entry));
  check_bool "error is None" true (is_null (get "error" entry))

let the_size_that_left_the_process_rides_fetch_ok () =
  let board = make_engine ~local:(image_stub ()) () in
  ignore (served board image_url);
  check_int "bytes" image_body_len (int (field (ok board) "bytes"))

let a_text_page_binds_no_image_field_at_all () =
  let board = make_engine () in
  ignore (served board url);
  check_bool "no bytes field" true (not (List.mem_assoc "bytes" (ok board)))

(* {1 TestImagesInAgentMode}

   An [answer] walk reads text, so an image it meets is named, not carried. *)

let the_bytes_are_left_out_and_the_notice_says_why () =
  let r = served (make_engine ~local:(image_stub ()) ()) ~run:"run-1" ~step:1 image_url in
  check_bool "no bytes travel" true (r.Model.image = None);
  check_bool "there is a notice" true (r.Model.notice <> None);
  includes "and it says why" "`answer` builds its material from text" (say r.Model.notice)

let the_fetch_is_still_journaled () =
  (* The request went out, so the journal sees it, whether or not the bytes
     travel. *)
  let board = make_engine ~usage:(recorder ()) ~local:(image_stub ()) () in
  ignore (served board ~run:"run-1" ~step:1 image_url);
  let entry = one_recent board in
  check_string "tool" "fetch" (str (get "tool" entry));
  check_int "chars" 0 (int (get "chars" entry))

(* {1 TestTheRouteAsksForTheWalk}

   [fetch.auto_fallback] is off, so an interactive read stops and reports.  The
   [answer] plan has no caller between its steps to act on a list of names, so it
   asks for the walk on the call it makes: flipping the default must not quietly
   make [answer] read less on JavaScript-heavy sites.  The ask is an argument on
   [fetch], not a reading of the [run]/[step] journal fields, which are
   observability and must not become load-bearing. *)

let rendered_by_fallback =
  "The text a browser sees, served by the fallback the plan walked to. " ^ "The text a browser sees, served by the fallback the plan walked to. "
  ^ "The text a browser sees, served by the fallback the plan walked to. "
  ^ "The text a browser sees, served by the fallback the plan walked to. "

let blocked_local () =
  stub ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"fetch" "HTTP 403")) ()

let a_call_can_ask_for_the_walk_the_key_withholds () =
  let local = blocked_local () in
  let fallback = stub ~name:"crawl4ai" ~text:rendered_by_fallback () in
  let board = make_engine ~local ~fallbacks:[ fallback ] () in
  let response = served board ~auto_fallback:true url in
  check_string "the walked page" rendered_by_fallback (say response.Model.text);
  check_ints "one dispatch each" [ 1; 1 ] [ !(local.calls); !(fallback.calls) ]

let the_journal_fields_alone_never_open_the_walk () =
  (* An [answer] line on the journal is not itself the ask for the walk. *)
  let local = blocked_local () in
  let fallback = stub ~name:"crawl4ai" ~text:rendered_by_fallback () in
  let board = make_engine ~local ~fallbacks:[ fallback ] () in
  ignore (failed board ~run:"run-1" ~step:1 url);
  check_int "run/step stay observability" 0 !(fallback.calls)

let the_key_still_walks_everything_that_does_not_override () =
  (* On is the operator half of the switch, and it needs no per-call ask. *)
  let local = blocked_local () in
  let fallback = stub ~name:"crawl4ai" ~text:rendered_by_fallback () in
  let board =
    make_engine ~fetch:{ Config.default_fetch_config with Config.auto_fallback = true }
      ~local ~fallbacks:[ fallback ] ()
  in
  let response = served board url in
  check_string "the walked page" rendered_by_fallback (say response.Model.text);
  check_ints "one dispatch each" [ 1; 1 ] [ !(local.calls); !(fallback.calls) ]

(* {1 TestNamedProvider}

   [fetch(provider=...)]: one named route, and one refusal sentence.  A name may
   come from anywhere, the three ways a name cannot serve collapse into a single
   refusal raised before anything is dispatched, and the sentence names what *is*
   available. *)

let served_by_named =
  String.concat ""
    (List.init 8 (fun _ -> "Served by the named provider, not by the local reader. "))

let a_named_provider_serves_the_page_and_nothing_else_is_tried () =
  (* No local read first and no walk behind it: one attempt, as named.  This is
     [search]'s "a price named is a price paid", and it is what makes [provider]
     a cost knob rather than only a retry knob. *)
  let local = stub () in
  let fallback = stub ~name:"crawl4ai" ~text:served_by_named () in
  let board = make_engine ~local ~fallbacks:[ fallback ] () in
  let response = served board ~provider:"crawl4ai" url in
  check_string "the named route served it" served_by_named (say response.Model.text);
  check_ints "one attempt, as named" [ 0; 1 ] [ !(local.calls); !(fallback.calls) ]

let the_named_fallback_is_the_fallback_the_call_is_journalled_to () =
  (* The journal prices the page against the name the caller chose. *)
  let fallback = stub ~name:"crawl4ai" ~text:served_by_named () in
  let board = make_engine ~usage:(recorder ()) ~fallbacks:[ fallback ] () in
  ignore (served board ~provider:"crawl4ai" url);
  let entry = one_recent board in
  check_string "fallback" "crawl4ai" (str (get "fallback" entry));
  check_bool "error is None" true (is_null (get "error" entry))

let a_named_provider_that_fails_does_not_walk_the_others () =
  (* The failure stays the named provider's own.  Walking behind a named route
     would bill a second name the caller never chose, and would hide which one
     failed. *)
  let local = stub () in
  let named =
    stub ~name:"scrappa"
      ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"scrappa" "rate limited")) ()
  in
  let other = stub ~name:"crawl4ai" () in
  let board = make_engine ~local ~fallbacks:[ other; named ] () in
  let message = failed board ~provider:"scrappa" url in
  check_ints "nothing else was tried" [ 0; 1; 0 ] [ !(local.calls); !(named.calls); !(other.calls) ];
  includes "the failure names who failed" "scrappa: rate limited" message

let an_unknown_name_is_refused_before_anything_is_dispatched () =
  let local = stub () in
  let fallback = stub ~name:"crawl4ai" () in
  let board = make_engine ~local ~fallbacks:[ fallback ] () in
  let message = refused board ~provider:"scraper" url in
  check_ints "nothing was dispatched" [ 0; 0 ] [ !(local.calls); !(fallback.calls) ];
  includes "the refusal" "Fetch provider 'scraper' is not enabled on this server." message;
  includes "and names what is" "Available: crawl4ai." message;
  includes "and the way out" "omit `provider` to read the page locally" message

let a_search_name_is_refused_with_the_fetch_list () =
  (* [serper] is a provider name and not a fetch name: the two sets have
     different membership, and the list handed to a caller that named one of the
     wrong set is the fetch list. *)
  let board = make_engine ~fallbacks:[ stub ~name:"scrappa" () ] () in
  includes "the fetch list" "Available: scrappa." (refused board ~provider:"serper" url)

let no_configured_provider_says_so_rather_than_listing_nothing () =
  let message = refused (make_engine ()) ~provider:"crawl4ai" url in
  includes "the empty-list sentence" "No other fetch provider is configured on this server." message;
  excludes "and never a blank list" "Available:" message

let the_three_ways_a_name_cannot_serve_refuse_alike () =
  (* Unknown to the registry, never built for want of a key or a URL, and
     excluded by the permission set: the engine sees the built names and nothing
     else, so one sentence answers all three. *)
  let board = make_engine ~fallbacks:[ stub ~name:"crawl4ai" () ] () in
  let refusal name =
    match Engine.Fetch.resolve board.engine (Some name) with
    | Ok _fetched -> A.failf "expected a refusal for %s, got a fetcher" name
    | Error sentence -> sentence
  in
  let unknown = refusal "scraper" and unbuilt = refusal "scrappa" in
  check_string "one sentence, one name changed"
    (String.concat "scrappa" (split_on_string "scraper" unknown))
    unbuilt

(* {1 TestPrimaryRoute}

   [fetch.primary]: the operator choosing which route an unnamed fetch leads
   with.  The key exists because the local read leaves this server's own IP and a
   plain HTTP client, which more bot walls recognise than a provider's network.
   With a fallback as primary, the local read is not a last resort hiding behind
   the walk: it is gone from the unnamed route, and the walk behind the primary is
   the ladder minus the primary, so no name is tried twice. *)

let primary_text =
  String.concat ""
    (List.init 8 (fun _ -> "Served by the configured primary route, not by this server. "))

let behind_primary =
  String.concat ""
    (List.init 8 (fun _ -> "Rendered by the fallback behind the primary route. "))

let the_named_primary_serves_and_the_local_reader_is_never_dialed () =
  (* The whole point of the key: the page never leaves this server's own IP. *)
  let local = stub () in
  let primary = stub ~name:"jina" ~text:primary_text () in
  let board =
    make_engine ~fetch:{ Config.default_fetch_config with Config.primary = "jina" }
      ~local ~fallbacks:[ primary ] ()
  in
  let response = served board url in
  check_string "the primary served it" primary_text (say response.Model.text);
  check_ints "the local reader was never dialed" [ 0; 1 ] [ !(local.calls); !(primary.calls) ];
  check_opt_string "a primary that works is not a fallback event" None response.Model.notice

let the_primary_is_the_route_the_call_is_journalled_to () =
  (* A page the primary served is attributed to it, so its price can land.  Same
     rule as a named route and a walked one: the journal names the route that
     made the call, and only the local reader journals nothing. *)
  let primary = stub ~name:"jina" ~text:primary_text () in
  let board =
    make_engine ~usage:(recorder ())
      ~fetch:{ Config.default_fetch_config with Config.primary = "jina" }
      ~fallbacks:[ primary ] ()
  in
  ignore (served board url);
  let entry = one_recent board in
  check_string "fallback" "jina" (str (get "fallback" entry));
  check_bool "error is None" true (is_null (get "error" entry))

let a_failing_primary_walks_the_ladder_behind_it_once () =
  (* The walk is the ladder minus the primary: [jina] is tried once, not twice. *)
  let local = stub () in
  let primary =
    stub ~name:"jina"
      ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"jina" "HTTP 403")) ()
  in
  let behind = stub ~name:"scrappa" ~text:behind_primary () in
  let board =
    make_engine
      ~fetch:
        {
          Config.default_fetch_config with
          Config.primary = "jina";
          fallback = Some [ "jina"; "scrappa" ];
          auto_fallback = true;
        }
      ~local ~fallbacks:[ primary; behind ] ()
  in
  let response = served board url in
  check_string "the rung behind served it" behind_primary (say response.Model.text);
  check_ints "jina tried once" [ 0; 1; 1 ] [ !(local.calls); !(primary.calls); !(behind.calls) ];
  check_string "the walk is told" "jina failed (HTTP 403); refetched via scrappa"
    (say response.Model.notice)

let a_failing_primary_with_the_walk_off_offers_the_ladder_only () =
  (* The withheld walk hands over the names, and the primary is not among them:
     offering the route that just failed would send the caller back to the
     provider the operator already watched fail. *)
  let primary =
    stub ~name:"jina"
      ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"jina" "HTTP 403")) ()
  in
  let behind = stub ~name:"scrappa" ~text:behind_primary () in
  let board =
    make_engine
      ~fetch:
        { Config.default_fetch_config with Config.primary = "jina"; fallback = Some [ "jina"; "scrappa" ] }
      ~fallbacks:[ primary; behind ] ()
  in
  let message = failed board url in
  includes "the ladder is offered" " Other configured fetch providers: scrappa." message;
  (match find_sub_from message "Other configured" with
  | Some i -> excludes "and the primary is not in it" "jina" (String.sub message i (String.length message - i))
  | None -> A.failf "the message offered no ladder: %s" message);
  check_int "nothing was walked" 0 !(behind.calls)

let a_nearly_empty_primary_names_itself_and_offers_the_ladder () =
  (* The emptiness sentence names the route that ran, not "the local fetcher". *)
  let primary = stub ~name:"jina" ~text:"nav only" () in
  let behind = stub ~name:"crawl4ai" ~text:behind_primary () in
  let board =
    make_engine
      ~fetch:
        {
          Config.default_fetch_config with
          Config.primary = "jina";
          fallback = Some [ "jina"; "crawl4ai" ];
        }
      ~fallbacks:[ primary; behind ] ()
  in
  let response = served board url in
  includes "the emptiness names the route" "Almost no readable text came back from `jina`."
    (say response.Model.notice);
  includes "and offers the ladder" "Other configured fetch providers: crawl4ai."
    (say response.Model.notice)

let the_primary_can_still_be_named_by_a_caller () =
  (* Naming the route a server already leads with is not a refusal: the built
     fallbacks are what [resolve] offers, primary included, and a caller asking
     for it gets the one attempt it asked for. *)
  let primary = stub ~name:"jina" ~text:primary_text () in
  let board =
    make_engine ~fetch:{ Config.default_fetch_config with Config.primary = "jina" }
      ~fallbacks:[ primary ] ()
  in
  let response = served board ~provider:"jina" url in
  check_string "the primary served it" primary_text (say response.Model.text);
  check_int "one attempt" 1 !(primary.calls)

let the_refusal_names_the_default_route_not_a_local_read () =
  (* With a provider leading, omitting [provider] is not a local read: the local
     reader has no name a caller can ask for, so the sentence has to describe the
     route rather than promise a page read no parameter reaches. *)
  let board =
    make_engine
      ~fetch:{ Config.default_fetch_config with Config.primary = "jina"; fallback = Some [ "jina" ] }
      ~fallbacks:[ stub ~name:"jina" () ] ()
  in
  includes "the default route, not a local read"
    "or omit `provider` to use this server's default route."
    (refused board ~provider:"scraper" url)

let a_primary_this_engine_was_not_handed_refuses_construction () =
  (* The defensive twin of the startup refusal: silently reading locally instead
     would dial from this server's own IP against a config that said not to. *)
  let config =
    match
      Config.resolve ~fetch:{ Config.default_fetch_config with Config.primary = "jina" } ()
    with
    | Ok config -> config
    | Error message -> A.failf "the fixture config was refused: %s" message
  in
  match
    Engine.Fetch.create config (make_fetcher (stub ())) ~readers:doc_readers ~fallbacks:[] ~clock
      ~now ()
  with
  | Ok _ -> A.failf "a primary nobody built cannot be a route"
  | Error sentence -> includes "the refusal says what is missing" "which this deployment did not build" sentence

(* {1 The ladder walk bills the answering fallback}

   A walk that spends two attempts prices the page at the fallback that answered.
   The figure on the line is read off the fallback object that served the page,
   never off the ladder's first fallback or off the single [fetch.cost_per_1k]:
   that is what keeps the price honest once the ladder holds more than one priced
   fallback. *)

let walk_board usage fallbacks =
  (* The local reader fails, so every case here reaches the ladder, and the walk
     is asked for on the config half of the switch. *)
  make_engine ~usage ~fetch:{ Config.default_fetch_config with Config.auto_fallback = true }
    ~local:(stub ~name:"local"
              ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"fetch" "HTTP 403")) ())
    ~fallbacks ()

let a_walk_bills_the_fallback_that_answered () =
  (* Two priced fallbacks, two different figures: the line carries the second
     one. *)
  let tried = stub ~name:"scrappa" ~cost_per_1k:(Some 0.30)
    ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"fetch" "HTTP 403")) ()
  in
  let answered = stub ~name:"priced-two" ~cost_per_1k:(Some 1.60) () in
  let board = walk_board (recorder ()) [ tried; answered ] in
  ignore (served board url);
  let json = Usage.snapshot (Option.value ~default:(recorder ()) board.usage) in
  let entry = one_recent board in
  check_string "fallback" "priced-two" (str (get "fallback" entry));
  money "cost_usd" 0.0016 (get "cost_usd" entry);
  let totals = get "totals" json in
  check_int "fetch_pages_via_fallback" 1 (int (get "fetch_pages_via_fallback" totals));
  check_int "priced_fetches" 1 (int (get "priced_fetches" totals));
  money "fetch_cost_usd" 0.0016 (get "fetch_cost_usd" totals)

let a_walk_past_a_free_fallback_bills_the_priced_one () =
  let tried = stub ~name:"jina"
    ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"fetch" "HTTP 403")) ()
  in
  let answered = stub ~name:"scrappa" ~cost_per_1k:(Some 0.30) () in
  let board = walk_board (recorder ()) [ tried; answered ] in
  ignore (served board url);
  let entry = one_recent board in
  check_string "fallback" "scrappa" (str (get "fallback" entry));
  money "cost_usd" 0.0003 (get "cost_usd" entry)

let a_walk_answered_by_a_free_fallback_bills_nothing () =
  (* The priced fallback that was tried and failed is not the one that billed. *)
  let tried = stub ~name:"scrappa" ~cost_per_1k:(Some 0.30)
    ~fail:(Engine.Fetch.Provider (Provider.provider_error ~provider:"fetch" "HTTP 403")) ()
  in
  let answered = stub ~name:"crawl4ai" () in
  let board = walk_board (recorder ()) [ tried; answered ] in
  ignore (served board url);
  let json = Usage.snapshot (Option.value ~default:(recorder ()) board.usage) in
  let entry = one_recent board in
  check_string "fallback" "crawl4ai" (str (get "fallback" entry));
  check_bool "no cost on the line" true (is_null (get "cost_usd" entry));
  let totals = get "totals" json in
  check_bool "fetch_cost_usd is None" true (is_null (get "fetch_cost_usd" totals));
  check_int "priced_fetches" 0 (int (get "priced_fetches" totals))

(* {1 The suite} *)

let () =
  A.run
    "fetch engine"
    [
      ( "success"
      , [
          A.test_case "page text is returned" `Quick page_text_is_returned;
          A.test_case "requested url is always reported" `Quick requested_url_is_always_reported;
          A.test_case "every call fetches" `Quick every_call_fetches;
        ] );
      ( "failure"
      , [
          A.test_case "failure raises" `Quick failure_raises;
          A.test_case "blocked url does not advise a retry" `Quick blocked_url_does_not_advise_a_retry;
        ] );
      ( "empty extraction"
      , [ A.test_case "empty text is reported not raised" `Quick empty_text_is_reported_not_raised ] );
      ( "query targeting"
      , [
          A.test_case "query fetches uncapped" `Quick query_fetches_uncapped;
          A.test_case "query returns matches with absolute offsets" `Quick query_returns_matches_with_absolute_offsets;
          A.test_case "query with no hits says so and leaves text unset" `Quick query_with_no_hits_says_so_and_leaves_text_unset;
          A.test_case "query over budget reports dropped sections" `Quick query_over_budget_reports_dropped_sections;
          A.test_case "query on an unreadable page keeps the shell diagnosis" `Quick query_on_an_unreadable_page_keeps_the_shell_diagnosis;
        ] );
      ( "json path targeting"
      , [
          A.test_case "a path fetches uncapped" `Quick a_path_fetches_uncapped;
          A.test_case "a path returns the subtree at an offset into the rendering" `Quick a_path_returns_the_subtree_at_an_offset_into_the_rendering;
          A.test_case "a wildcard path returns one match per element" `Quick a_wildcard_path_returns_one_match_per_element;
          A.test_case "a path that matches nothing says the structure is one away" `Quick a_path_that_matches_nothing_says_the_structure_is_one_away;
          A.test_case "a path on a page with no structure returns the page" `Quick a_path_on_a_page_with_no_structure_returns_the_page;
          A.test_case "a page whose text happens to start with a dollar is still a page" `Quick a_page_whose_text_happens_to_start_with_a_dollar_is_still_a_page;
          A.test_case "a json claim on a body that is not a document says which" `Quick a_json_claim_on_a_body_that_is_not_a_document_says_which;
          A.test_case "a selection cut before its first span says so" `Quick a_selection_cut_before_its_first_span_says_so;
          A.test_case "a path over budget reports what was cut and how to narrow it" `Quick a_path_over_budget_reports_what_was_cut_and_how_to_narrow_it;
          A.test_case "a path selects nothing on an unreadable page" `Quick a_path_selects_nothing_on_an_unreadable_page;
          A.test_case "a path with a query is refused" `Quick a_path_with_a_query_is_refused;
          A.test_case "a path with an offset is refused" `Quick a_path_with_an_offset_is_refused;
          A.test_case "an unreadable path is refused before anything is fetched" `Quick an_unreadable_path_is_refused_before_anything_is_fetched;
        ] );
      ( "structure reads"
      , [
          A.test_case "a structure read returns the schema not the page" `Quick a_structure_read_returns_the_schema_not_the_page;
          A.test_case "a structure read fetches uncapped" `Quick a_structure_read_fetches_uncapped;
          A.test_case "a tiny structure page is answered without a walk" `Quick a_tiny_structure_page_is_answered_without_a_walk;
          A.test_case "a structure read on a page with no structure returns the page" `Quick a_structure_read_on_a_page_with_no_structure_returns_the_page;
          A.test_case "a structure read with a query is refused before anything is fetched" `Quick a_structure_read_with_a_query_is_refused_before_anything_is_fetched;
          A.test_case "a structure read with a path is refused before anything is fetched" `Quick a_structure_read_with_a_path_is_refused_before_anything_is_fetched;
          A.test_case "a structure read with an offset is refused before anything is fetched" `Quick a_structure_read_with_an_offset_is_refused_before_anything_is_fetched;
        ] );
      ( "offset paging"
      , [
          A.test_case "offset is forwarded to the fallback" `Quick offset_is_forwarded_to_the_fallback;
          A.test_case "past end returns a notice and no ladder" `Quick past_end_returns_a_notice_and_no_ladder;
          A.test_case "query and offset together are refused" `Quick query_and_offset_together_are_refused;
          A.test_case "offset zero stays unset on the response" `Quick offset_zero_stays_unset_on_the_response;
          A.test_case "a short tail window gets no empty diagnosis" `Quick a_short_tail_window_gets_no_empty_diagnosis;
        ] );
      ( "special token escaping"
      , [
          A.test_case "page text is escaped and counted" `Quick page_text_is_escaped_and_counted;
          A.test_case "the title is escaped too" `Quick the_title_is_escaped_too;
          A.test_case "a clean page counts zero" `Quick a_clean_page_counts_zero;
          A.test_case "a past end response escapes the title and counts" `Quick a_past_end_response_escapes_the_title_and_counts;
          A.test_case "query matches are escaped in escaped space" `Quick query_matches_are_escaped_in_escaped_space;
        ] );
      ( "observability"
      , [
          A.test_case "a url is logged when queries are opted in" `Quick a_url_is_logged_when_queries_are_opted_in;
          A.test_case "an empty page logs the empty event" `Quick an_empty_page_logs_the_empty_event;
          A.test_case "a readable page does not log the empty event" `Quick a_readable_page_does_not_log_the_empty_event;
          A.test_case "a failure logs its reason and retryability" `Quick a_failure_logs_its_reason_and_retryability;
          A.test_case "matches replace the page in the content log" `Quick matches_replace_the_page_in_the_content_log;
        ] );
      ( "usage recording"
      , [
          A.test_case "a success records chars and no fallback" `Quick a_success_records_chars_and_no_fallback;
          A.test_case "a failure records the class and no chars" `Quick a_failure_records_the_class_and_no_chars;
          A.test_case "a blocked fetch records the block class" `Quick a_blocked_fetch_records_the_block_class;
          A.test_case "a past end offset records the call it billed" `Quick a_past_end_offset_records_the_call_it_billed;
        ] );
      ( "image pages"
      , [
          A.test_case "the image is carried and the text fields stay unset" `Quick the_image_is_carried_and_the_text_fields_stay_unset;
          A.test_case "the notice names the type and the size" `Quick the_notice_names_the_type_and_the_size;
          A.test_case "the ladder is never asked for an image" `Quick the_ladder_is_never_asked_for_an_image;
          A.test_case "an offset past the end of nothing addresses nothing" `Quick an_offset_past_the_end_of_nothing_addresses_nothing;
          A.test_case "the call is journaled as a call with no text chars" `Quick the_call_is_journaled_as_a_call_with_no_text_chars;
          A.test_case "the size that left the process rides fetch ok" `Quick the_size_that_left_the_process_rides_fetch_ok;
          A.test_case "a text page binds no image field at all" `Quick a_text_page_binds_no_image_field_at_all;
        ] );
      ( "images in agent mode"
      , [
          A.test_case "the bytes are left out and the notice says why" `Quick the_bytes_are_left_out_and_the_notice_says_why;
          A.test_case "the fetch is still journaled" `Quick the_fetch_is_still_journaled;
        ] );
      ( "the route asks for the walk"
      , [
          A.test_case "a call can ask for the walk the key withholds" `Quick a_call_can_ask_for_the_walk_the_key_withholds;
          A.test_case "the journal fields alone never open the walk" `Quick the_journal_fields_alone_never_open_the_walk;
          A.test_case "the key still walks everything that does not override" `Quick the_key_still_walks_everything_that_does_not_override;
        ] );
      ( "the ladder walk bills the answering fallback"
      , [
          A.test_case "a walk bills the fallback that answered" `Quick a_walk_bills_the_fallback_that_answered;
          A.test_case "a walk past a free fallback bills the priced one" `Quick a_walk_past_a_free_fallback_bills_the_priced_one;
          A.test_case "a walk answered by a free fallback bills nothing" `Quick a_walk_answered_by_a_free_fallback_bills_nothing;
        ] );
      ( "named provider"
      , [
          A.test_case "a named provider serves the page and nothing else is tried" `Quick a_named_provider_serves_the_page_and_nothing_else_is_tried;
          A.test_case "the named fallback is the fallback the call is journalled to" `Quick the_named_fallback_is_the_fallback_the_call_is_journalled_to;
          A.test_case "a named provider that fails does not walk the others" `Quick a_named_provider_that_fails_does_not_walk_the_others;
          A.test_case "an unknown name is refused before anything is dispatched" `Quick an_unknown_name_is_refused_before_anything_is_dispatched;
          A.test_case "a search name is refused with the fetch list" `Quick a_search_name_is_refused_with_the_fetch_list;
          A.test_case "no configured provider says so rather than listing nothing" `Quick no_configured_provider_says_so_rather_than_listing_nothing;
          A.test_case "the three ways a name cannot serve refuse alike" `Quick the_three_ways_a_name_cannot_serve_refuse_alike;
        ] );
      ( "primary route"
      , [
          A.test_case "the named primary serves and the local reader is never dialed" `Quick the_named_primary_serves_and_the_local_reader_is_never_dialed;
          A.test_case "the primary is the route the call is journalled to" `Quick the_primary_is_the_route_the_call_is_journalled_to;
          A.test_case "a failing primary walks the ladder behind it once" `Quick a_failing_primary_walks_the_ladder_behind_it_once;
          A.test_case "a failing primary with the walk off offers the ladder only" `Quick a_failing_primary_with_the_walk_off_offers_the_ladder_only;
          A.test_case "a nearly empty primary names itself and offers the ladder" `Quick a_nearly_empty_primary_names_itself_and_offers_the_ladder;
          A.test_case "the primary can still be named by a caller" `Quick the_primary_can_still_be_named_by_a_caller;
          A.test_case "the refusal names the default route not a local read" `Quick the_refusal_names_the_default_route_not_a_local_read;
          A.test_case "a primary this engine was not handed refuses construction" `Quick a_primary_this_engine_was_not_handed_refuses_construction;
        ] );
    ]
