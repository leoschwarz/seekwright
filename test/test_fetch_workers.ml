(* The fetch path with its extraction off the loop: the port of
   tests/fetch/test_fetch_guardrails.py's [TestExtractionTime] — the parse that
   holds the loop open, the overrunning parse refused with the deadline
   sentence, and the chain budget answering when no parse deadline is set.
   Same loopback fixture and [Policy.with_endpoints] grant as
   [test_fetch_http.ml], with the pool from [test_extract_pool.ml] wired into
   the fetcher exactly as the factory wires it ([~workers] beside
   [~parse_timeout_seconds], chain budget twice the per-request timeout).

   Deferred with PDF support (F6.2): the oracle's shared-content-stream PDF,
   the real-input case where parse work scales with the page count rather
   than the bytes. This port ships no PDF backend, so the grind stands in,
   and the type the fixture serves ([application/pdf]) keeps the oracle's
   input class visible in the refusal sentence. *)

module F = Seekwright_fetch.Fetcher
module E = Seekwright_fetch.Extractor
module K = Seekwright_fetch.Extract_pool
module Caps = Mcp_caps

module Policy = Caps.Policy
module Authority = Caps.Authority
module Error = Caps.Error

module A = Alcotest

let main_domain = Domain.self ()

(* The [TestExtractionTime] grinder: [busy] burns the core like a CPU loop,
   otherwise it waits on a timer like a parse that has lost the plot;
   [release] frees a grind the deadline abandoned, so [close] never waits for
   a parse the case already refused. State is [Atomic] because the backend
   closure is shared into the worker domains. *)
type grinder = {
  stop : bool Atomic.t;
  busy : bool Atomic.t;
  seconds : float Atomic.t;
  last_domain : Domain.id Atomic.t;
}

let make_grinder () =
  {
    stop = Atomic.make false;
    busy = Atomic.make false;
    seconds = Atomic.make 0.5;
    last_domain = Atomic.make main_domain;
  }

let release (g : grinder) = Atomic.set g.stop true

let grinder_backend (g : grinder) =
  {
    E.name = "grinding";
    supported_types = E.pdf_types;
    extract = (fun _body _content_type ->
      Atomic.set g.last_domain (Domain.self ());
      let deadline = Unix.gettimeofday () +. Atomic.get g.seconds in
      while Atomic.get g.stop = false && Unix.gettimeofday () < deadline do
        if Atomic.get g.busy then () else Unix.sleepf 0.01
      done;
      { E.text = "extracted"; title = None; total_chars = 9; path_addressable = false });
  }

(* The oracle's [_pdf_routes]: one route, answered as a PDF — a body far under
   the download cap, because the axis under test is time, not size. *)
let pdf_body = "%PDF-1.4\nnot a real document\n%%EOF\n"

let fixture _conn _request _body =
  Cohttp_eio.Server.respond_string
    ~headers:(Http.Header.of_list [ ("content-type", "application/pdf") ])
    ~status:`OK ~body:pdf_body ()

(* One case: the fixture, the grant pinned to it, the grinder, and the pool —
   built into the fetcher and closed as the factory does. [~parse_timeout] is
   handed to [Fetcher.make] beside [~workers]; the case that sets no parse
   deadline is the chain-budget position, where the whole-request bound is
   the only one.

   The pool is closed with the grinder released first: [close] waits for
   running jobs, and a case that refused a 5s grind must not wait it out. *)
let with_worker_fetch ?parse_timeout ?(busy = false) ?(grind = 0.5)
    ?(workers = 1) f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let socket =
        Eio.Net.listen ~backlog:16 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
      in
      let port =
        match Eio.Net.listening_addr socket with
        | `Tcp (_, port) -> port
        | `Unix path -> A.failf "unix socket fixture: %s" path
      in
      let server = Cohttp_eio.Server.make ~callback:fixture () in
      let stop, fill_stop = Eio.Promise.create () in
      let stopped, fill_stopped = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect
          ~finally:(fun () -> Eio.Promise.resolve fill_stopped ())
          (fun () -> Cohttp_eio.Server.run ~stop ~on_error:(fun _exn -> ()) socket server));
      let g = make_grinder () in
      Atomic.set g.busy busy;
      Atomic.set g.seconds grind;
      Fun.protect
        ~finally:(fun () ->
          Eio.Promise.resolve fill_stop ();
          Eio.Promise.await stopped)
        (fun () ->
          match
            Policy.with_endpoints ~sw ~net:env#net ~max_response_bytes:16_000_000
              [ { Policy.scheme = `Http; host = "127.0.0.1"; port = Some port } ]
          with
          | Error error -> A.failf "with_endpoints: %s" (Error.render error)
          | Ok decision -> (
              match
                K.make ~workers
                  ~net:env#net
                  ~mono_clock:(Eio.Stdenv.mono_clock env)
                  ~dir:(Filename.get_temp_dir_name ())
                  ~extractor:(grinder_backend g) ()
              with
              | Error message -> A.failf "extract pool: %s" message
              | Ok pool ->
                  Fun.protect
                    ~finally:(fun () ->
                      release g;
                      K.close pool)
                    (fun () ->
                      let net =
                        Authority.Net.of_confinement
                          ~mono_clock:(Eio.Stdenv.mono_clock env) decision
                      in
                      let fetcher =
                        F.make ~net ~extractor:(grinder_backend g) ~workers:pool
                          ?parse_timeout_seconds:parse_timeout ()
                      in
                      f fetcher port g (Eio.Stdenv.clock env)
                        (Eio.Stdenv.mono_clock env))))))

let doc_url port = Printf.sprintf "http://127.0.0.1:%d/doc" port

let render (error : F.error) =
  match error with
  | F.Refusal (F.Url_blocked m | F.Redirect_blocked m | F.Blocked m) -> "refusal: " ^ m
  | F.Failed m -> "failed: " ^ m

(* The oracle's [test_extraction_holds_the_event_loop_open]: half a second of
   another domain's arithmetic is ~50 loop ticks, so a loop held open by the
   parse reads near zero. The page still arrives, and the grind ran on a
   worker domain, not the loop's. *)
let test_extraction_holds_the_loop_open () =
  with_worker_fetch ~busy:true ~grind:0.5 ~parse_timeout:2.0
    (fun fetcher port g clock _mono ->
      let ticks = ref 0 in
      Eio.Switch.run (fun sw ->
        let answer = ref None in
        Eio.Fiber.fork ~sw (fun () ->
          answer := Some (F.fetch fetcher (doc_url port) ~offset:0 ~max_chars:None));
        while !answer = None do
          incr ticks;
          Eio.Time.sleep clock 0.01
        done;
        match !answer with
        | Some (Ok page) ->
            A.(check string "page text" "extracted" page.F.text);
            if !ticks < 10 then
              A.failf "the loop only ticked %d times during the parse" !ticks;
            A.(check bool "extraction ran off the loop's domain" true
                (Atomic.get g.last_domain <> main_domain))
        | Some (Error e) -> A.failf "fetch: %s" (render e)
        | None -> A.failf "the fetching fiber never answered"))

(* The oracle's [test_an_overrunning_parse_comes_back_as_a_refusal], exact
   sentence included: [parse_timeout_seconds] is [fetch.timeout_seconds], so
   the remedy named in the sentence is the key the operator raises.
   [Refusal Blocked] is the non-retryable shape — a parse that ran too long on
   these bytes will run too long again, and this is not a network fault. The
   elapsed window is the oracle's: the parse deadline decides, not the 5s
   grind and not the chain budget of twice the timeout sitting behind it. *)
let test_an_overrunning_parse_is_a_refusal () =
  let budget = 0.4 in
  with_worker_fetch ~grind:5.0 ~parse_timeout:budget
    (fun fetcher port _g _clock mono ->
      let started = Unix.gettimeofday () in
      let result =
        F.fetch fetcher (doc_url port) ~offset:0 ~max_chars:None
          ~chain_timeout:(Eio.Time.Timeout.seconds mono (2.0 *. budget))
      in
      let elapsed = Unix.gettimeofday () -. started in
      (match result with
      | Error (F.Refusal (F.Blocked message)) ->
          A.(
            check string "the deadline sentence"
              "cannot extract text: application/pdf extraction did not finish \
               within 0.4 seconds; raise fetch.timeout_seconds to allow a \
               longer parse"
              message)
      | Error e -> A.failf "expected a refusal, got: %s" (render e)
      | Ok _ -> A.failf "an overrunning parse returned a page");
      if elapsed < 0.35 || elapsed >= 0.75 then
        A.failf "returned in %.2fs: expected the 0.4s parse deadline, not the \
                 5s grind or the 0.8s chain budget" elapsed)

(* No parse deadline set, and the chain budget alone cuts the request: the
   whole-exchange bound the factory builds (twice [fetch.timeout_seconds], the
   oracle's [asyncio.timeout] around the redirect chain) reaches the parse
   too, and it answers as the fetch failure the request window already
   produces. *)
let test_a_chain_budget_cuts_an_unbounded_parse () =
  with_worker_fetch ~grind:5.0 (fun fetcher port _g _clock mono ->
    let started = Unix.gettimeofday () in
    let result =
      F.fetch fetcher (doc_url port) ~offset:0 ~max_chars:None
        ~chain_timeout:(Eio.Time.Timeout.seconds mono 0.4)
    in
    let elapsed = Unix.gettimeofday () -. started in
    (match result with
    | Error (F.Failed "request timed out") -> ()
    | Error e -> A.failf "expected the chain timeout failure, got: %s" (render e)
    | Ok _ -> A.failf "a 5s parse arrived inside a 0.4s chain budget");
    if elapsed < 0.35 || elapsed >= 0.9 then
      A.failf "returned in %.2fs: expected the 0.4s chain budget" elapsed)

(* The in-time parse comes back through the socket whole: the pool is not a
   deadline that only refuses. *)
let test_an_in_time_parse_returns_the_page () =
  with_worker_fetch ~grind:0.1 ~parse_timeout:2.0
    (fun fetcher port _g _clock _mono ->
      match F.fetch fetcher (doc_url port) ~offset:0 ~max_chars:None with
      | Ok page -> A.(check string "page text" "extracted" page.F.text)
      | Error e -> A.failf "fetch: %s" (render e))

let () =
  A.run "fetch_workers"
    [
      ("extraction time", [
        A.test_case "a parse off the loop leaves it beating" `Quick
          test_extraction_holds_the_loop_open;
        A.test_case "an overrunning parse comes back as a refusal" `Quick
          test_an_overrunning_parse_is_a_refusal;
        A.test_case "a chain budget cuts an unbounded parse" `Quick
          test_a_chain_budget_cuts_an_unbounded_parse;
        A.test_case "an in-time parse returns the page" `Quick
          test_an_in_time_parse_returns_the_page;
      ]);
    ]
