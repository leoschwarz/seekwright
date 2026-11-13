(* Every operation that leaves the process is billed twice: once to the provider
   that serves it, and once to whoever reads the log afterwards. The second copy
   is attached in [Factory], because that is the one place a serving grant is
   built — wrapping at the grant rather than at each call site is what makes
   "every low-level operation is audited" true without a call-site survey that a
   later change can silently widen.

   What this suite pins, in order:

   - a granted network operation writes exactly one event, and a refused one
     writes exactly one too: a trail that records only successes cannot tell
     "we never asked" from "we asked and were refused";
   - what the line carries — an operation name, an outcome, a byte count and the
     operation's own bounded notes — and nothing that identifies the request.
     [Event.t] has no URL, header, body or query field to fill in, so the check
     is on the field set the sink renders, not on a scrubber; and the line goes
     to stderr, because descriptor 1 is the JSON-RPC channel under stdio;
   - that the probe path is covered too: [probe_net] is a grant like any other,
     so the readiness traffic the health monitor generates is on the trail;
   - the wiring count in the factory: one [Authority.Net.of_confinement] and one
     [Authority.with_log], so a second grant path cannot appear here without a
     red line;
   - that the sealing is real: [lib/caps/dune] keeps the raw modules private,
     the negative-compilation mirror agrees with that file, and no production
     module outside [lib/caps] names them. A consumer that could name
     [Policy_fs] or the bounds record could skip the grant, which is the whole
     claim this layer makes.

   No billed endpoint is involved: the fixtures are loopback listeners and a
   temp directory. *)

module Caps = Mcp_caps
module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Factory = Seekwright_factory.Factory
module A = Alcotest
open Test_support

module Authority = Caps.Authority
module Error = Caps.Error
module Event = Caps.Event
module Health = Seekwright.Health
module Log = Seekwright.Log
module Policy = Caps.Policy

(* ------------------------------------------------------------------ *)
(* the loopback fixture                                                 *)
(* ------------------------------------------------------------------ *)

let response_body = "four score and seven years ago"

(* The answer varies by route, so one listener serves the success case and the
   status case. A [404] is an answer, not a failure: it arrives as [Ok] with a
   status note, which is the distinction the audit line has to keep. *)
let fixture _conn request _body =
  let headers = Http.Header.of_list [ ("content-type", "text/plain; charset=utf-8") ] in
  match Http.Request.resource request with
  | "/missing" ->
      Cohttp_eio.Server.respond_string ~headers ~status:`Not_found ~body:"no such page" ()
  | _ -> Cohttp_eio.Server.respond_string ~headers ~status:`OK ~body:response_body ()

let endpoint port : Policy.endpoint =
  { Policy.scheme = `Http; host = "127.0.0.1"; port = Some port }

let page_request port : Authority.Net.request =
  {
    meth = `GET;
    uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/page" port);
    headers = [];
    body = None;
  }

(* One listener, one switch, one loop per case, torn down around the body — the
   shape test_fetch_http.ml uses, kept short because what is asserted here is
   what the grant records on the way out, not the exchange itself. *)
let with_fixture f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~backlog:16 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> A.failf "the fixture listener is not a TCP socket: %s" path
  in
  let server = Cohttp_eio.Server.make ~callback:fixture () in
  let stop, fill_stop = Eio.Promise.create () in
  let stopped, fill_stopped = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Promise.resolve fill_stopped ())
      (fun () -> Cohttp_eio.Server.run ~stop ~on_error:(fun _exn -> ()) socket server));
  Fun.protect
    ~finally:(fun () ->
      Eio.Promise.resolve fill_stop ();
      Eio.Promise.await stopped)
    (fun () -> f env sw port)

(* The sink under observation: a capturing list, because the assertion is about
   what the layer emits — where those events land is the application's choice,
   and [audit_sink] is pinned separately below. *)
let capture () =
  let events = ref [] in
  ((fun event -> events := event :: !events), fun () -> List.rev !events)

let factory_grant ~audit env sw port =
  match
    Factory.grant_of_endpoint ~sw ~net:env#net
      ~mono_clock:(Eio.Stdenv.mono_clock env) ~timeout_seconds:5.0 ~audit
      (endpoint port)
  with
  | Error message -> A.failf "the fixture grant was refused: %s" message
  | Ok grant -> grant

(* The same call with the sink left off, which is what [--check] does when it
   probes a deployment. Written as its own helper because [grant_of_endpoint]'s
   optional argument comes last, so a positional call cannot skip it. *)
let factory_grant_without_a_sink env sw port =
  match
    Factory.grant_of_endpoint ~sw ~net:env#net
      ~mono_clock:(Eio.Stdenv.mono_clock env) ~timeout_seconds:5.0 (endpoint port)
  with
  | Error message -> A.failf "the fixture grant was refused: %s" message
  | Ok grant -> grant

(* ------------------------------------------------------------------ *)
(* one event per operation                                              *)
(* ------------------------------------------------------------------ *)

let test_a_granted_operation_records_one_event () =
  let audit, events = capture () in
  with_fixture (fun env sw port ->
      let grant = factory_grant ~audit env sw port in
      match Authority.Net.request grant (page_request port) with
      | Error error -> A.failf "expected the fixture to answer, got %s" (Error.render error)
      | Ok response ->
          A.(check int "the fixture answered" 200 response.status);
          let recorded = events () in
          A.(check int "one event per operation" 1 (List.length recorded));
          let event = List.hd recorded in
          A.(check string "the operation is named by the layer" "net.request"
               (Event.operation event));
          A.(check string "the outcome is ok" "ok"
               (Event.outcome_to_string (Event.outcome event)));
          A.(check (A.option A.int) "the byte count is the body's size"
               (Some (String.length response_body)) (Event.bytes event));
          (* the operation's own note: a non-2xx that arrives is an ok transport
             outcome, so the line has to say which answer it was *)
          A.(check (A.list A.(pair string string)) "the notes are the operation's"
               [ ("status", "200") ] (Event.notes event)))

(* The bound is per operation and so is the line: a grant that makes four
   requests is four records, which is what makes a fan-out visible in the log. *)
let test_a_second_operation_records_a_second_event () =
  let audit, events = capture () in
  with_fixture (fun env sw port ->
      let grant = factory_grant ~audit env sw port in
      ignore (Authority.Net.request grant (page_request port));
      ignore (Authority.Net.request grant (page_request port));
      ignore (Authority.Net.request grant (page_request port)));
  A.(check int "three operations, three records" 3 (List.length (events ())));
  List.iter
    (fun event ->
      A.(check string "the same operation name each time" "net.request" (Event.operation event));
      A.(check string "each of them answered" "ok"
           (Event.outcome_to_string (Event.outcome event))))
    (events ())

let test_a_status_answer_records_its_status () =
  let audit, events = capture () in
  with_fixture (fun env sw port ->
      let grant = factory_grant ~audit env sw port in
      let off_list =
        { (page_request port) with
          uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/missing" port)
        }
      in
      match Authority.Net.request grant off_list with
      | Error error -> A.failf "expected a 404 answer, got %s" (Error.render error)
      | Ok response -> A.(check int "the fixture answered 404" 404 response.status));
  let recorded = events () in
  A.(check int "one event for the 404" 1 (List.length recorded));
  let event = List.hd recorded in
  A.(check string "an answer is an ok outcome" "ok"
       (Event.outcome_to_string (Event.outcome event)));
  A.(check (A.list A.(pair string string)) "the status note says which answer"
       [ ("status", "404") ] (Event.notes event));
  A.(check (A.option A.int) "the byte count is what arrived" (Some 12) (Event.bytes event))

(* A refusal inside the grant is the case the trail exists for: nothing reached
   the network, and only the record says so. The fetch stack's primary route is
   the public-web grant, so a loopback URL is refused by the grant itself. *)
let fetch_config () =
  match
    Config.resolve ~fetch:{ Config.default_fetch_config with Config.enabled = true } ()
  with
  | Error message -> A.failf "the fixture config was refused: %s" message
  | Ok config -> config

let test_a_refused_operation_records_one_event () =
  let audit, events = capture () in
  with_fixture (fun env sw port ->
      match
        Factory.build_fetch_stack ~sw ~net:env#net
          ~mono_clock:(Eio.Stdenv.mono_clock env) ~audit (fetch_config ())
      with
      | None -> A.fail "the fixture config left fetch disabled"
      | Some (Error message) -> A.failf "build_fetch_stack: %s" message
      | Some (Ok (primary, fallbacks)) ->
          A.(check int "v1 builds no fetch fallback" 0 (List.length fallbacks));
          (match
             primary.Engine.Fetch.fetch
               ~url:(Printf.sprintf "http://127.0.0.1:%d/page" port)
               ~offset:0 ~max_chars:Engine.Fetch.Default
           with
          | Ok page ->
              A.failf "the public-web grant fetched a loopback URL: %d"
                page.Engine.Fetch.status_code
          | Error reason ->
              A.(check bool "a private address is a policy refusal, not a failure" true
                   (match reason with
                   | Engine.Fetch.Url_blocked _ | Engine.Fetch.Redirect_blocked _
                   | Engine.Fetch.Fetch_blocked _ -> true
                   | Engine.Fetch.Provider _ -> false)));
          let recorded = events () in
          A.(check int "one event for the refusal" 1 (List.length recorded));
          let event = List.hd recorded in
          A.(check string "the operation is still named" "net.request" (Event.operation event));
          A.(check string "the outcome names the class" "failed:denied"
               (Event.outcome_to_string (Event.outcome event)));
          (* nothing is measured for a body that was never read, and no note is
             attached to a failure: the address that tripped the policy is not
             something the line may carry *)
          A.(check (A.option A.int) "a refusal measures nothing" None (Event.bytes event));
          A.(check (A.list A.(pair string string)) "a refusal carries no notes" []
               (Event.notes event)))

(* A grant built without a sink is a diagnostic grant — [--check] probing a
   deployment — and it still works: the sink is optional at the builder so that
   path can exist, while [build_app] always supplies it. *)
let test_a_grant_without_a_sink_records_nothing () =
  let audit, events = capture () in
  with_fixture (fun env sw port ->
      let grant = factory_grant_without_a_sink env sw port in
      match Authority.Net.request grant (page_request port) with
      | Error error -> A.failf "expected the fixture to answer, got %s" (Error.render error)
      | Ok response -> A.(check int "the unaudited grant still answers" 200 response.status));
  ignore audit;
  A.(check int "a diagnostic grant writes nothing" 0 (List.length (events ())))

(* The other kind reports its own name: an [Fs] grant wrapped in the same sink
   writes [fs.read_file] / [fs.list_dir], so the trail says which power was used
   and not only that something happened. *)
let test_a_filesystem_operation_records_its_own_name () =
  let root = Filename.temp_dir "caps-audit-fs" "" in
  let channel = open_out (Filename.concat root "note.md") in
  output_string channel "audited\n";
  close_out channel;
  let audit, events = capture () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) root with
  | Error error -> A.failf "with_root: %s" (Error.render error)
  | Ok confinement ->
      let grant =
        Authority.with_log ~sink:audit
          (Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement)
      in
      (match Authority.Fs.read_file grant "note.md" with
      | Error error -> A.failf "read_file: %s" (Error.render error)
      | Ok text -> A.(check string "the file was read" "audited\n" text));
      (match Authority.Fs.read_file grant "no-such-file" with
      | Ok _ -> A.fail "the missing file was read"
      | Error error -> A.(check string "the missing file is reported by kind" "unavailable"
                            (Error.kind_to_string (Error.kind error))));
      (match Authority.Fs.list_dir grant "" with
      | Error error -> A.failf "list_dir: %s" (Error.render error)
      | Ok names -> A.(check (A.list A.string) "the listing came back" [ "note.md" ] names));
      let recorded = events () in
      A.(check (A.list A.string) "one event per filesystem operation"
           [ "fs.read_file"; "fs.read_file"; "fs.list_dir" ]
           (List.map Event.operation recorded));
      A.(check string "a result is a result, whatever the kind" "failed:unavailable"
           (Event.outcome_to_string (Event.outcome (List.nth recorded 1))));
      A.(check (A.option A.int) "a read measures what it read" (Some 8)
           (Event.bytes (List.nth recorded 0)));
      (* a listing is counted, never quoted: the names in a directory are content *)
      A.(check (A.list A.(pair string string)) "a listing reports a count, not its names"
           [ ("entries", "1") ] (Event.notes (List.nth recorded 2)));
      A.(check bool "the rendered line carries no path" false
           (contains ~haystack:(Event.render (List.nth recorded 2)) ~needle:root))

(* ------------------------------------------------------------------ *)
(* what the line carries                                                *)
(* ------------------------------------------------------------------ *)

(* [audit_sink] through a capturing [Engine.log]: the field dictionary is pinned
   here without driving a socket, so a renamed or widened field set fails on the
   dictionary rather than in a deployment's log shipper. *)
let through_sink ?(bytes = None) ?(notes = []) ?(outcome = Event.Ok) operation =
  let lines = ref [] in
  let log level event fields = lines := (level, event, fields) :: !lines in
  let event = Event.make ~operation outcome in
  let event = match bytes with Some count -> Event.with_bytes count event | None -> event in
  let event = List.fold_left (fun acc (key, value) -> Event.add_note key value acc) event notes in
  Factory.audit_sink log event;
  match List.rev !lines with
  | [ (level, name, fields) ] -> (level, name, fields)
  | other -> A.failf "the sink wrote %d lines, expected 1" (List.length other)

let field_keys fields = List.sort compare (List.map fst fields)
let rendered fields =
  List.map
    (fun (key, value) -> Printf.sprintf "%s=%s" key (Yojson.Safe.to_string value))
    (List.sort (fun a b -> compare (fst a) (fst b)) fields)

let test_the_line_is_a_constant_event_with_a_fixed_field_set () =
  let level, name, fields =
    through_sink ~bytes:(Some 4096) ~notes:[ ("status", "200") ] "net.request"
  in
  A.(check string "the event name is a constant dotted name" "caps.operation" name);
  A.(check bool "an operation is logged at info" true (level = Config.Log_info));
  A.(check (A.list A.string) "the field set is fixed"
       [ "bytes"; "operation"; "outcome"; "status" ] (field_keys fields));
  A.(check (A.list A.string) "the values render as the dictionary says"
       [
         "bytes=4096";
         "operation=\"net.request\"";
         "outcome=\"ok\"";
         "status=\"200\"";
       ]
       (rendered fields))

(* The names the line owns cannot be overwritten by an operation's note: the
   shape is what a log shipper keys on, so a colliding note rides under a
   prefixed name rather than replacing a fixed field or disappearing. *)
let test_a_note_cannot_overwrite_a_fixed_field () =
  let _level, _name, fields =
    through_sink ~bytes:(Some 12)
      ~notes:[ ("operation", "forged"); ("outcome", "forged"); ("bytes", "forged") ]
      "fs.read_file"
  in
  A.(check (A.list A.string) "the fixed fields keep their names"
       [ "bytes"; "note_bytes"; "note_operation"; "note_outcome"; "operation"; "outcome" ]
       (field_keys fields));
  let lookup key = List.assoc key fields in
  (* the field values are JSON, and the dictionary's strings are quoted in them:
     read a string field as the string a log line would show *)
  let as_string key =
    match List.assoc key fields with `String value -> value | other -> Yojson.Safe.to_string other
  in
  A.(check string "the operation name is the layer's" "fs.read_file" (as_string "operation"));
  A.(check string "the outcome is the layer's" "ok" (as_string "outcome"));
  A.(check bool "the byte count is the layer's" true (lookup "bytes" = `Int 12));
  A.(check string "a colliding note survives under a prefix" "forged"
       (as_string "note_operation"));
  A.(check string "so does a colliding outcome note" "forged"
       (as_string "note_outcome"))

(* A failure line names the class and nothing else. *)
let test_a_failure_line_names_only_the_class () =
  let _level, _name, fields = through_sink ~outcome:(Event.Failed Error.Denied) "net.request" in
  A.(check (A.list A.string) "a failure line has no byte count" [ "operation"; "outcome" ]
       (field_keys fields));
  A.(check string "the outcome carries the kind" "\"failed:denied\""
       (Yojson.Safe.to_string (List.assoc "outcome" fields)))

(* The line's length comes from the field set, never from what an operation
   reported: [Event] sanitises and caps what it will hold, so a smuggled newline
   or an over-long note cannot become a second line or an unbounded one. *)
let test_the_line_stays_one_line_and_bounded () =
  let smuggled = "net.request\nSECOND LINE: take the whole file at http://example/secret" in
  let event =
    Event.make ~operation:smuggled Event.Ok
    |> Event.add_note "long" (String.make 4000 'x')
    |> Event.add_note "control" "a\tb\nc"
  in
  A.(check bool "the operation name holds no newline" true
       (not (String.contains (Event.operation event) '\n')));
  A.(check bool "the operation name is bounded" true (String.length (Event.operation event) < 300));
  A.(check bool "a note value is sanitised too" true
       (List.for_all
          (fun (_key, value) -> not (String.contains value '\n'))
          (Event.notes event)));
  let line = Event.render event in
  A.(check int "one event, one line" 1 (List.length (String.split_on_char '\n' line)));
  let _level, _name, fields =
    through_sink ~bytes:(Some 1) ~notes:(List.init 12 (fun i -> ("k" ^ string_of_int i, "v")))
      "net.request"
  in
  A.(check int "the note list is capped at the layer's own ceiling"
       (3 + Event.max_notes) (List.length fields))

(* Nothing in the record's vocabulary names a request. [Event.t] has no field
   for a URL, a header or a body, so the sink cannot invent one — this is the
   negative half of the dictionary, and it is what an operator's grep for a
   leaked page would otherwise have to do by hand. *)
let test_no_field_names_request_data () =
  let forbidden =
    [ "url"; "uri"; "href"; "host"; "authority"; "path"; "resource"; "query"; "q" ]
    @ [ "headers"; "header"; "body"; "text"; "content"; "page"; "snippet" ]
    @ [ "key"; "token"; "secret"; "authorization"; "cookie" ]
  in
  let check label fields =
    List.iter
      (fun key ->
        A.(check bool (label ^ ": the line carries the field " ^ key) false
             (List.mem_assoc key fields)))
      forbidden
  in
  let ( _level,
        _name,
        fields ) =
    through_sink ~bytes:(Some 1) ~notes:[ ("status", "200"); ("attempts", "2") ] "net.request"
  in
  check "a successful request" fields;
  let ( _level,
        _name,
        fields ) =
    through_sink ~notes:[ ("entries", "4") ] "fs.list_dir"
  in
  check "a directory listing" fields;
  let ( _level,
        _name,
        fields ) =
    through_sink ~outcome:(Event.Failed Error.Denied) "net.request"
  in
  check "a refusal" fields

(* The other provider-shaped path: [probe_net] is the seam the readiness probes
   use — [Provider.Net.of_grant] over a factory grant — and a probe is a network
   operation like any other, so it is recorded like one. This is also the case
   that shows the health monitor's traffic is audited on the serving path, since
   [build_app] hands that same seam the sink. *)
let test_a_probe_operation_is_audited () =
  let audit, events = capture () in
  with_fixture (fun env sw port ->
      let config =
        match
          Config.resolve
            ~providers:
              [ ("freeserp", { Config.default_provider_config with Config.enabled = true }) ]
            ()
        with
        | Error message -> A.failf "the fixture config was refused: %s" message
        | Ok config -> config
      in
      let url = Printf.sprintf "http://127.0.0.1:%d/probe" port in
      let table =
        [
          ( "freeserp",
            {
              Health.endpoint = Health.probe_endpoint_const url;
              headers = (fun _config _key -> []);
            } );
        ]
      in
      let net =
        Factory.probe_net ~sw ~net:env#net ~mono_clock:(Eio.Stdenv.mono_clock env)
          ~timeout_seconds:5.0 ~audit [ endpoint port ]
      in
      A.(check string "the probe reached the fixture" "reachable_no_key"
             (Health.show_outcome (Health.probe ~net ~table config "freeserp"))));
  let recorded = events () in
  A.(check int "a probe is one operation, one record" 1 (List.length recorded));
  A.(check string "the operation is the network one" "net.request"
       (Event.operation (List.hd recorded)));
  A.(check string "and it answered" "ok"
       (Event.outcome_to_string (Event.outcome (List.hd recorded))))

(* stdout is the JSON-RPC channel under stdio, so an audit line that reached it
   would corrupt the protocol. What the sink writes goes to stderr; this drives
   the real [Log] sink — not a capturing one — and reads the descriptor back. *)
let test_nothing_reaches_stdout () =
  let logger =
    Log.make { Config.default_logging_config with Config.level = Config.Log_info }
  in
  let audit = Factory.audit_sink (Log.sink logger) in
  let path = Filename.temp_file "caps-audit-stdout" ".txt" in
  with_fixture (fun env sw port ->
      let saved = Unix.dup Unix.stdout in
      let file =
        Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
      in
      Unix.dup2 file Unix.stdout;
      Unix.close file;
      Fun.protect
        ~finally:(fun () ->
          flush stdout;
          Unix.dup2 saved Unix.stdout;
          Unix.close saved)
        (fun () ->
          let grant = factory_grant ~audit env sw port in
          match Authority.Net.request grant (page_request port) with
          | Error error -> A.failf "expected the fixture to answer, got %s" (Error.render error)
          | Ok response -> A.(check int "the audited operation still answers" 200 response.status)));
  let captured = read_file path in
  A.(check string "descriptor 1 stayed empty" "" captured)

(* ------------------------------------------------------------------ *)
(* the wiring is single                                                 *)
(* ------------------------------------------------------------------ *)

let factory_source = read_file "../lib/factory/factory.ml"
let server_source = read_file "../lib/server.ml"
let main_source = read_file "../bin/main.ml"
let caps_dune = read_file "../lib/caps/dune"
let mirror_source = read_file "../test/should_not_compile/mcp_caps.ml"

(* One audit wrapper and one grant construction in the factory: the funnel every
   serving grant goes through. A second call to either is a second grant path,
   and a grant path outside the funnel is an un-audited one. *)
let test_the_factory_builds_grants_through_one_funnel () =
  A.(check int "one audit wrapper" 1
       (count_occurrences ~haystack:factory_source ~needle:"Authority.with_log"));
  A.(check int "one grant construction" 1
       (count_occurrences ~haystack:factory_source ~needle:"Authority.Net.of_confinement"));
  includes "the funnel is what the builders call"
    "grant_of_decision ~mono_clock ~timeout_seconds ?audit decision" factory_source;
  includes "build_app installs the sink" "let audit = audit_sink log in" factory_source;
  (* every public builder that can hand back a grant takes the sink and threads
     it to the funnel, so none of them can drop it on the way *)
  List.iter
    (fun call -> includes ("the sink reaches " ^ call) call factory_source)
    [
      "~audit config";
      "?audit adapter.endpoint";
      "?audit decision";
      "?audit endpoint)";
    ]

(* The layer's per-operation counter is a caller's ceiling. Server construction
   has no caller scope to attach one to, so a budget on the serving path is a
   server-lifetime limit wearing a request's name. Every mention of it in the
   factory is prose inside brackets, which is what makes this checkable: an
   unbracketed occurrence is a call. *)
let test_no_operation_budget_on_the_serving_path () =
  List.iter
    (fun (file, source) ->
      A.(check int (file ^ " mentions the budget only to refuse it")
             (count_occurrences ~haystack:source ~needle:"Authority.with_operation_budget")
             (count_occurrences ~haystack:source ~needle:"[Authority.with_operation_budget]"));
      A.(check int (file ^ " does not take a budget argument") 0
           (count_occurrences ~haystack:source ~needle:"?budget")))
    [ ("lib/factory/factory.ml", factory_source); ("lib/server.ml", server_source) ]

(* A grant built outside the factory is a grant outside the audit trail. These
   are the production modules that could build one. *)
let test_production_modules_obtain_grants_from_the_factory () =
  List.iter
    (fun (file, source) ->
      A.(check int (file ^ " does not construct a grant") 0
           (count_occurrences ~haystack:source ~needle:"of_confinement"));
      A.(check int (file ^ " does not wrap a grant") 0
           (count_occurrences ~haystack:source ~needle:"Authority.with_log")))
    [ ("lib/server.ml", server_source); ("bin/main.ml", main_source) ]

(* Nothing outside [lib/caps] may name the sealed layer: if a production module
   named the bounds record or the raw operations, a consumer could follow the
   reference to a type it can then build. *)
let test_nothing_outside_caps_names_the_sealed_layer () =
  List.iter
    (fun (file, source) ->
      List.iter
        (fun name ->
          A.(check int (file ^ " does not name " ^ name) 0
               (count_occurrences ~haystack:source ~needle:name)))
        [ "Policy_fs"; "Controls_raw" ])
    [
      ("lib/factory/factory.ml", factory_source);
      ("lib/factory/factory.mli", read_file "../lib/factory/factory.mli");
      ("lib/server.ml", server_source);
      ("bin/main.ml", main_source);
    ]

(* ------------------------------------------------------------------ *)
(* the sealing is real                                                  *)
(* ------------------------------------------------------------------ *)

(* Which modules a consumer can name is a property of this one configuration
   line, and only a change to it could widen the surface: reading the file is
   how the rule is checked without shipping an OCaml parser. The negative
   fixtures in [test/should_not_compile] are the proof; these two cases keep
   that proof honest. *)
let private_modules () =
  match
    List.find_opt (fun line -> contains ~haystack:line ~needle:"(private_modules")
      (String.split_on_char '\n' caps_dune)
  with
  | None -> A.fail "lib/caps/dune declares no private_modules"
  | Some line ->
      (* the s-expression's delimiters are not module names *)
      String.map (fun char -> if char = '(' || char = ')' then ' ' else char) (String.trim line)
      |> String.split_on_char ' '
      |> List.filter (fun word -> word <> "" && word <> "private_modules")

let test_caps_keeps_its_low_level_modules_private () =
  A.(check (A.list A.string) "the two modules the layer refuses to expose"
       [ "policy_fs"; "controls_raw" ] (private_modules ()));
  (* policy_net stays public on purpose: its records are the vocabulary a [Net]
     call is written in, and hiding it breaks the grant path rather than the
     bypass — see the comment in lib/caps/dune. What seals it is the [~controls]
     argument its operations take, whose type is the private module's. *)
  includes "policy_net's seal is its controls argument" "controls:Controls_raw.t ->"
    (read_file "../lib/caps/policy_net.mli")

(* The negative fixtures compile against a mirror of the package's public view.
   If that mirror fell behind [lib/caps/dune], the fixtures would be proving a
   surface the package no longer has — so the two are pinned against each other,
   and the mirror is pinned non-vacuous by the grant path it must keep. *)
let test_the_negative_fixture_mirror_matches_the_package () =
  List.iter
    (fun module_ ->
      let capitalised =
        String.concat "_" (List.map String.capitalize_ascii (String.split_on_char '_' module_))
      in
      excludes "the mirror exposes the same surface as the package" ("module " ^ capitalised)
        mirror_source)
    (private_modules ());
  includes "the mirror keeps the grant layer" "module Authority" mirror_source;
  includes "the mirror keeps the policy producers" "module Policy" mirror_source

(* ------------------------------------------------------------------ *)

let () =
  Mirage_crypto_rng_unix.use_default ();
  A.run "caps-audit"
    [
      ( "operations",
        [
          A.test_case "a granted operation records one event" `Quick
            test_a_granted_operation_records_one_event;
          A.test_case "a second operation records a second event" `Quick
            test_a_second_operation_records_a_second_event;
          A.test_case "a status answer records its status" `Quick
            test_a_status_answer_records_its_status;
          A.test_case "a refused operation records one event" `Quick
            test_a_refused_operation_records_one_event;
          A.test_case "a grant without a sink records nothing" `Quick
            test_a_grant_without_a_sink_records_nothing;
          A.test_case "a filesystem operation records its own name" `Quick
            test_a_filesystem_operation_records_its_own_name;
          A.test_case "a readiness probe is an audited operation" `Quick
            test_a_probe_operation_is_audited;
        ] );
      ( "the line",
        [
          A.test_case "the line is a constant event with a fixed field set" `Quick
            test_the_line_is_a_constant_event_with_a_fixed_field_set;
          A.test_case "a note cannot overwrite a fixed field" `Quick
            test_a_note_cannot_overwrite_a_fixed_field;
          A.test_case "a failure line names only the class" `Quick
            test_a_failure_line_names_only_the_class;
          A.test_case "the line stays one line and bounded" `Quick
            test_the_line_stays_one_line_and_bounded;
          A.test_case "no field names request data" `Quick
            test_no_field_names_request_data;
          A.test_case "descriptor 1 stays empty" `Quick
            test_nothing_reaches_stdout;
        ] );
      ( "the wiring",
        [
          A.test_case "the factory builds grants through one funnel" `Quick
            test_the_factory_builds_grants_through_one_funnel;
          A.test_case "no operation budget on the serving path" `Quick
            test_no_operation_budget_on_the_serving_path;
          A.test_case "production modules obtain grants from the factory" `Quick
            test_production_modules_obtain_grants_from_the_factory;
          A.test_case "nothing outside caps names the sealed layer" `Quick
            test_nothing_outside_caps_names_the_sealed_layer;
          A.test_case "caps keeps its low-level modules private" `Quick
            test_caps_keeps_its_low_level_modules_private;
          A.test_case "the negative fixture mirror matches the package" `Quick
            test_the_negative_fixture_mirror_matches_the_package;
        ] );
    ]
