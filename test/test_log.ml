(* The log sink has one owner; this suite is the fact that it does.

   Style review M1: [Engine], [Usage] and [Health] each declared their own
   [type log = Config.log_level -> string -> (string * Yojson.Safe.t) list ->
   unit]. Four copies of one contract is four places to change, and the change
   that matters — a fourth parameter, say a run id — fails in the {i caller} that
   builds the sink rather than in the module that owns the shape. [Log] now
   declares the type and the other three alias it, so one function satisfies all
   four at once.

   Two pins, because an alias is invisible at runtime. The first is a
   compile-time one: one [Log.sink] value annotated at each module's name, which
   stops building the moment a module goes back to spelling an arrow of its own
   (an arrow type is structural, so this is the strongest thing the type checker
   can say about it). The second reads the interfaces, in the manner of
   [test_core_no_mcp_kit.ml]: the arrow appears in exactly one [*.mli] and the
   other three say they alias it. A type name is not visible at runtime, so the
   source is the only place the {i one declaration} can be pinned. *)

module Config = Seekwright.Config
module Log = Seekwright.Log
module Engine = Seekwright.Engine
module Health = Seekwright.Health
module Model = Seekwright.Model
module Usage = Seekwright.Usage
module A = Alcotest
open Test_support

(* {2 The compile-time pin} *)

let configured_sink : Log.log = Log.sink (Log.make Config.default_logging_config)

(* One function value, four annotations. Each line is the fact P8 relies on: the
   server builds one sink and hands it to all of them. *)
let the_sink_serves_the_engine : Engine.log = configured_sink
let the_sink_serves_the_board : Health.log = configured_sink
let the_sink_serves_the_recorder : Usage.log = configured_sink

(* And back the other way: a function written against one module's name is
   accepted where another's is asked for, so neither module can widen the shape
   without the others noticing at build time. *)
let engine_sink_serves_the_board : Engine.log -> Health.log = Fun.id
let board_sink_serves_the_recorder : Health.log -> Usage.log = Fun.id
let recorder_sink_serves_log : Usage.log -> Log.log = Fun.id

let test_the_sink_type_pin_compiles () =
  (* Nothing runs: the fact is that this module builds. Naming the pins in a
     case is what keeps one of them from being quietly deleted. *)
  ignore the_sink_serves_the_engine;
  ignore the_sink_serves_the_board;
  ignore the_sink_serves_the_recorder;
  ignore engine_sink_serves_the_board;
  ignore board_sink_serves_the_recorder;
  ignore recorder_sink_serves_log

(* {2 The source pin} *)

let read path =
  if not (Sys.file_exists path) then
    A.failf "%s is missing from the test sandbox (test/dune declares it)" path;
  read_file path

(* The arrow, in the exact spelling the four copies had. *)
let the_arrow = "Config.log_level -> string -> (string * Yojson.Safe.t) list -> unit"
let the_alias = "type log = Log.log"

let interfaces = [ "log.mli"; "engine.mli"; "health.mli"; "usage.mli" ]

let test_the_arrow_type_is_declared_once () =
  List.iter
    (fun name ->
      (* test/dune puts the library's interfaces in the sandbox; without them
         this suite would pass by reading nothing. *)
      let path = Filename.concat "../lib" name in
      let source = read path in
      let aliased = name <> "log.mli" in
      A.(check int) (name ^ (if aliased then " aliases the sink" else " owns the sink"))
        (if aliased then 1 else 0)
        (count_occurrences ~haystack:source ~needle:the_alias);
      A.(check int)
        (name ^ " spells the arrow " ^ if aliased then "nowhere" else "exactly once")
        (if aliased then 0 else 1)
        (count_occurrences ~haystack:source ~needle:the_arrow))
    interfaces

let test_the_owner_declares_no_siblings () =
  (* The owner stays the owner: [log.mli] must not name the modules that alias
     it, which is how the dependency would turn around and make [Log] the caller
     of its own type. *)
  let source = read (Filename.concat "../lib" "log.mli") in
  List.iter
    (fun name ->
      A.(check int) ("log.mli mentions " ^ name ^ " nowhere") 0
        (count_occurrences ~haystack:source ~needle:(name ^ ".")))
    [ "Engine"; "Health"; "Usage"; "Provider" ]

(* {2 What the alias has to preserve } *)

let test_the_board_hands_its_levels_and_fields_to_the_sink () =
  (* The behaviour the alias carries unchanged: a module calling a sink passes a
     level, a constant dotted event name, and every value as a named field. *)
  let seen = ref [] in
  let capture : Health.log =
    fun level event fields -> seen := (level, event, fields) :: !seen
  in
  let board =
    Health.create ~now:(fun () -> 0.0) ~failure_threshold:2 ~cooldown_seconds:60.0 ~log:capture ()
  in
  Health.record_failure board ~reason:"the endpoint refused" "exa" ();
  A.(check int) "a first failure says nothing yet" 0 (List.length !seen);
  Health.record_failure board ~reason:"the endpoint refused" "exa" ();
  match !seen with
  | [ (level, event, fields) ] ->
      A.(check string) "the event name" "health.open" event;
      A.(check string) "the level is Config's spelling" "INFO" (Config.show_log_level level);
      A.(check bool) "the provider rode as a field" true (List.mem_assoc "provider" fields);
      A.(check bool) "and so did the reason" true (List.mem_assoc "reason" fields)
  | lines -> A.failf "expected one line, saw %d" (List.length lines)

let test_one_function_records_from_the_engine_and_the_board () =
  (* The fact P8 stands on, run rather than compiled: one capture function,
     built against [Log]'s name, is what the search engine and the health board
     both call. Two sinks that merely look alike would pass the annotations
     above and still leave the server writing its lines in two places. *)
  let seen = ref [] in
  let capture : Log.log =
    fun level event fields ->
      seen := (Config.show_log_level level, event, List.map fst fields) :: !seen
  in
  let board =
    Health.create ~now:(fun () -> 0.0) ~failure_threshold:1 ~cooldown_seconds:60.0 ~log:capture ()
  in
  Health.record_failure board ~reason:"the endpoint refused" "exa" ();
  (* An engine refuses a name this deployment does not serve, and the refusal is
     exactly a call to the sink: [search.rejected], warning, named fields. *)
  let config = Config.default in
  let engine =
    Engine.Search.create config [] ~clock:(fun () -> 0.0) ~now:(fun () -> 0.0) ~log:capture ()
  in
  let query =
    {
      Model.query = "anything";
      max_results = 5;
      include_domains = [];
      exclude_domains = [];
      country = None;
      language = None;
      recency = None;
      safe_search = None;
    }
  in
  (match Engine.Search.search engine ~provider:"nosuchprovider" query with
  | Error (Engine.Search.Refused _) -> ()
  | Ok _ -> A.fail "an empty registry answered a search"
  | Error (Engine.Search.Failed message) -> A.failf "a refusal became a failure: %s" message);
  let events = List.rev (List.map (fun (_level, event, _fields) -> event) !seen) in
  A.(check (list string)) "both modules wrote through it"
    [ "health.open"; "search.rejected" ]
    events;
  (* And the field discipline survives the trip: a constant dotted name, every
     value a named field. *)
  let field_names event =
    match List.find_opt (fun (_level, name, _fields) -> name = event) !seen with
    | Some (_level, _name, fields) -> fields
    | None -> A.failf "no %s line reached the sink" event
  in
  A.(check bool) "the health line names its provider" true
    (List.mem "provider" (field_names "health.open"));
  A.(check bool) "and the engine line names what was asked for" true
    (List.mem "requested" (field_names "search.rejected"))

let () =
  A.run "log"
    [
      ( "one sink type",
          [
            A.test_case "the sink type pin compiles" `Quick test_the_sink_type_pin_compiles;
            A.test_case "the arrow type is declared once" `Quick test_the_arrow_type_is_declared_once;
            A.test_case "the owner mentions no siblings" `Quick test_the_owner_declares_no_siblings;
            A.test_case "the board hands its levels and fields to the sink" `Quick
              test_the_board_hands_its_levels_and_fields_to_the_sink;
            A.test_case "one function records from the engine and the board" `Quick
              test_one_function_records_from_the_engine_and_the_board;
          ] )
    ]
