(* The page cache on the serving path: what changes about a fetch the {i engine}
   runs once [fetch.cache_dir] names a directory.

   [test_page_cache.ml] pins the entry format, the three ceilings, the TTL and the
   window cut against a real grant. This suite pins what sits above that — the
   {!Engine.Fetch.Cache} seam [Factory.build_page_cache] builds — because the rules
   it has to hold are rules about a {i fetch}, not about a file:

   - the guardrail answers before the directory does, with a warm entry and without
     one alike, which is why [preflight] is a field of the seam rather than a step
     a caller may skip when it expects a hit;
   - one cold fill per key: the call that dispatched is reported as a dispatch and
     every read that reached the entry instead is dispatch-free, which is the
     answer [fetch.ok]'s [cached] gives and the reason a priced rung stays unbilled
     on a cached page;
   - each rung keeps its own entry, because the same URL through two providers is
     two different extractions;
   - an image page bypasses the store, and a fill that failed or could not be
     stored leaves nothing behind, so the next call dispatches again — a cache that
     cannot keep a page is never an error to the caller holding it;
   - the directory the config names is created or refused when the cache is built,
     never quietly skipped;
   - with [cache_dir] unset the seam is absent, every read dispatches and [cached]
     stays [false] — the path that ran before F7 and still runs by default.

   The pages come from stub fetchers, so nothing here reaches a provider or a key.
   The address rule is the one thing a case cannot stub out, and the case that
   needs a refusal asks for a loopback {i literal}: [Policy_net.vet_public_host]
   answers an IP literal from the address rule alone, with no lookup, so the suite
   stays hermetic either way. *)

module Config = Seekwright.Config
module Engine = Seekwright.Engine
module Factory = Seekwright_factory.Factory
module Fetcher = Seekwright_fetch.Fetcher
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Usage = Seekwright.Usage
module A = Alcotest
open Test_support

(* One fixed instant for both clocks: [retrieved_at] is then a fact to assert on,
   every [ms] field is exactly [0], and the cache's TTL clock is the engine's. *)
let clock () = 1768478400.
let now () = 1768478400.

let url = "https://example.com/article"

(* Marked, so the case that asks whether a page's text reached a log line or a
   journal entry has something to look for; long enough to clear
   [fetch.min_text_chars], which every success case has to. *)
let marker = "PAGE-CACHE-SENTINEL"

let page_text =
  marker ^ " The body every case here reads through the seam, long enough that the \
            engine does not mistake it for the nav stub a rendered page leaves \
            behind, and long enough that a window of it is a different string from \
            the whole of it."

let page_len = String.length page_text

(* {1 The stub fetchers, the log capture, and the journal read} *)

(* [test_fetch_engine.ml]'s duck-typed stub, local again: a cache case has to count
   dispatches per rung, and the [cached] flag is only meaningful against a count.
   [fails] counts down dispatches that answer with a provider failure. [park] runs
   at the head of every dispatch and is how the singleflight cases hold one fill
   open: the seam's rules are about calls that are in flight {i at the same time},
   and a stub that signals when it enters and waits until it is released is what
   makes that an arrangement rather than a race. *)
type fetcher_stub = {
  name : string;
  calls : int ref;
  asked : (int * Engine.Fetch.cap) list ref;
  cost_per_1k : float option;
  text : string;
  image : Engine.Fetch.image option;
  fails : int ref;
  park : unit -> unit;
}

let stub ?(name = "http") ?(fails = 0) ?(park = fun () -> ()) ?(cost_per_1k = None)
    ?(text = page_text) ?image () =
  { name; calls = ref 0; asked = ref []; cost_per_1k; text; image; fails = ref fails; park }

let make_fetcher (s : fetcher_stub) : Engine.Fetch.fetcher =
  let unavailable = Engine.Fetch.Provider (Provider.provider_error ~provider:s.name "HTTP 503") in
  {
    Engine.Fetch.name = s.name;
    cost_per_1k = s.cost_per_1k;
    fetch =
      (fun ~url:target ~offset ~max_chars ->
        s.park ();
        incr s.calls;
        s.asked := !(s.asked) @ [ (offset, max_chars) ];
        if !(s.fails) > 0
        then (
          decr s.fails;
          Error unavailable)
        else
          match s.image with
          | Some image ->
            Ok
                {
                  Engine.Fetch.url = target;
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
                  Engine.Fetch.url = target;
                  title = Some "A Page";
                  text = s.text;
                  content_type = Some "text/html";
                  status_code = 200;
                  truncated = false;
                  total_chars = String.length s.text;
                  path_addressable = false;
                  image = None;
                });
    aclose = (fun () -> ());
  }

(* The smallest readers stub that keeps [fetch] addressable: no case here asks for
   [query] or [path], and the readers' own grammar is pinned beside the readers. *)
let readers : Engine.Fetch.Readers.t =
  {
    Engine.Fetch.Readers.parse_path = (fun _selector -> Ok ());
    render_schema = (fun _text -> None);
    select_paths = (fun ~text:_ ~path:_ ~max_chars:_ -> ([], 0));
    select_passages = (fun ~text:_ ~query:_ ~max_chars:_ -> ([], 0));
  }

type captured = { event : string; fields : (string * Yojson.Safe.t) list }

let sink lines : Engine.log =
  fun _level event fields -> lines := !lines @ [ { event; fields } ]

let get key = function
  | `Assoc fields -> (try List.assoc key fields with Not_found -> `Null)
  | _ -> `Null

let items = function `List xs -> xs | _ -> []
let str = function `String s -> s | `Null -> "" | v -> Yojson.Safe.to_string v

let number = function
  | `Int n -> n
  | `Float f -> int_of_float f
  | v -> A.failf "not a count: %s" (Yojson.Safe.to_string v)

let is_null = (( = ) `Null)
let say = function Some s -> s | None -> ""

let field fields name = get name (`Assoc fields)

(* [fetch.ok]'s [cached] flag, in call order: what the operator reads, and what the
   journal prices by. *)
let cached_flags lines =
  List.filter_map
    (fun (c : captured) ->
      if c.event = "fetch.ok" then Some (field c.fields "cached" = `Bool true) else None)
    !lines

let render_line c = c.event ^ "|" ^ String.concat "|" (List.map (fun (k, v) -> k ^ "=" ^ str v) c.fields)

(* Every log line and the whole journal: what [no page text leaves the process] is
   checked against. [logging.log_content] is off in the fixture, which is the
   shipped default, and this is the assertion that makes the default mean
   something. *)

(* {1 The fixture: a config that names a cache directory, and the engine over it} *)

(* The fixture's wall clock on the board, so a stub can answer slowly the way a
   slow provider does. *)
type board = {
  engine : Engine.Fetch.t;
  lines : captured list ref;
  usage : Usage.t;
  cache_dir : string;
  stats : unit -> int * int;
  sleep : float -> unit;
}

(* The directory read back through the same reader [--check] uses, so an entry
   count in a case is a measurement rather than a claim. *)
let entries board = fst (board.stats ())
let body_bytes board = snd (board.stats ())

(* Every log line and the whole journal: what [no page text leaves the process] is
   checked against. [logging.log_content] is off in the fixture, which is the
   shipped default, and this is the assertion that makes that default mean
   something. *)
let rendered board =
  String.concat "|" (List.map render_line !(board.lines))
  ^ "|"
  ^ Yojson.Safe.to_string (Usage.snapshot board.usage)

(* [min_text_chars] drops to [1] here on purpose: the empty-page gate is
   [test_fetch_engine.ml]'s subject, and a windowed read in this suite is
   deliberately shorter than the shipped gate. Every other fetch key is the
   default, so the ceilings the cases assert on are the configured ones.

   [allow_private_addresses] is on unless the case is about the address rule: the
   seam's preflight vets the host, and the switch is what keeps that vet from
   asking a resolver about a made-up name. *)
let with_board
    ?(allow_private = true)
    ?(max_text_chars = 40_000)
    ?(cache_max_entry_bytes = Config.default_fetch_config.Config.cache_max_entry_bytes)
    ?cache_dir
    ?(fallbacks = [])
    local
    f =
  let base = Config.default_fetch_config in
  let dir =
    match cache_dir with Some existing -> existing | None -> Filename.temp_dir "seekwright-fetch-cache" ""
  in
  let fetch =
    {
      base with
      Config.enabled = true;
      extractor = "stdlib";
      max_text_chars;
      min_text_chars = 1;
      allow_private_addresses = allow_private;
      cache_dir = Some dir;
      cache_max_entry_bytes;
    }
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let mono_clock = Eio.Stdenv.mono_clock env in
  let fs = Eio.Stdenv.fs env in
  match Config.resolve ~fetch () with
  | Error message -> A.failf "the fixture config was refused: %s" message
  | Ok config -> (
      match Factory.build_page_cache ~sw ~net:env#net ~mono_clock ~now ~fs config with
      | Error message -> A.failf "build_page_cache refused the fixture: %s" message
      | Ok None -> A.failf "the fixture set cache_dir, so the seam must exist"
      | Ok cache -> (
          match Usage.create ~now () with
          | Error message -> A.failf "an in-memory recorder cannot fail: %s" message
          | Ok usage -> (
              let lines = ref [] in
              match
                Engine.Fetch.create config (make_fetcher local) ~readers ?cache ~usage
                  ~log:(sink lines) ~fallbacks:(List.map make_fetcher fallbacks) ~clock ~now ()
              with
              | Error message -> A.failf "the engine refused the fixture: %s" message
              | Ok engine ->
                f
                  {
                    engine;
                    lines;
                    usage;
                    cache_dir = dir;
                    stats =
                      (fun () ->
                        match Factory.page_cache_stats ~sw ~mono_clock ~fs config with
                        | Ok (Some figures) -> figures
                        | Ok None -> A.fail "the fixture set cache_dir, so the directory exists"
                        | Error message -> A.failf "page_cache_stats: %s" message);
                    sleep = (fun seconds -> Eio.Time.sleep (Eio.Stdenv.clock env) seconds);
                  })))

let served board ?offset ?provider target =
  match Engine.Fetch.fetch board.engine ?offset ?provider target with
  | Ok response -> response
  | Error (Engine.Fetch.Refused sentence) -> A.failf "the fetch was refused: %s" sentence
  | Error (Engine.Fetch.Failed sentence) -> A.failf "the fetch failed: %s" sentence

let refused board ?offset ?provider target =
  match Engine.Fetch.fetch board.engine ?offset ?provider target with
  | Ok response -> A.failf "expected a refusal, got a page: %s" (say response.Model.notice)
  | Error (Engine.Fetch.Refused sentence) -> sentence
  | Error (Engine.Fetch.Failed sentence) -> A.failf "expected a refusal, got a failure: %s" sentence

let failed board ?offset ?provider target =
  match Engine.Fetch.fetch board.engine ?offset ?provider target with
  | Ok response -> A.failf "expected a failure, got a page: %s" (say response.Model.notice)
  | Error (Engine.Fetch.Refused sentence) -> A.failf "expected a failure, got a refusal: %s" sentence
  | Error (Engine.Fetch.Failed sentence) -> sentence

let recent board = items (get "recent" (Usage.snapshot board.usage))

(* {1 One cold fill per key} *)

let the_call_that_filled_dispatched_and_the_next_one_did_not () =
  let local = stub () in
  with_board local (fun board ->
      ignore (served board url);
      A.(check int "the first read dispatched" 1 !(local.calls));
      ignore (served board url);
      A.(check int "the second read reached the directory, not the origin" 1 !(local.calls));
      A.(check (list bool) "the fill is a dispatch, the follower is dispatch-free"
           [ false; true ]
           (cached_flags board.lines));
      A.(check int "one entry" 1 (entries board));
      A.(check int "whose body is the whole extraction" page_len (body_bytes board));
      (* The other half of the rule: a cached read puts no page text in the line
         the operator reads or the journal the dashboard reads. *)
      excludes "no page text reaches the log or the journal" marker (rendered board))

let a_windowed_read_stores_the_whole_page_and_serves_only_its_window () =
  (* The fill dispatches uncapped at offset 0 — that is what lets one entry answer
     every later window — while each call serves only the window it asked for. *)
  let local = stub () in
  with_board ~max_text_chars:60 local (fun board ->
      let first = served board ~offset:20 url in
      A.(check (list (pair int string)) "the fill asked for the whole page at offset zero"
           [ (0, "uncapped") ]
           (List.map
              (fun (offset, cap) ->
                ( offset,
                  match cap with
                  | Engine.Fetch.Uncapped -> "uncapped"
                  | Engine.Fetch.Default -> "configured limit"
                  | Engine.Fetch.Limit n -> string_of_int n ))
              !(local.asked)));
      let window, more = Fetcher.window_text page_text ~offset:20 ~max_chars:60 in
      A.(check bool "the page has more after this window" true more);
      A.(check string "and the window is the same cut a live read makes" window
           (say first.Model.text));
      A.(check int "the fill is the only dispatch" 1 !(local.calls));
      ignore (served board ~offset:80 url);
      A.(check int "a second window did not dispatch" 1 !(local.calls));
      A.(check (list bool) "the filling window was a dispatch, the one after it was not"
           [ false; true ]
           (cached_flags board.lines));
      A.(check int "one entry holds the whole page" page_len (body_bytes board)))

(* A [park] hook that makes the first dispatch of a stub answer [seconds] late, so
   the other callers of one cold key arrive while that fill is open.

   A sleep on the fixture's clock rather than a promise: a follower's lookup of the
   entry is a read through the fs grant, and in Eio that is itself a suspension, so
   nothing orders the two calls against each other. Holding the fill open longer
   than a lookup takes does, by a wide margin — and the rule under test is which
   path a follower takes, not how the scheduler interleaves two microseconds. *)
let hold_first_dispatch ?(seconds = 0.2) () =
  let remaining = ref seconds in
  let clock = ref (fun (s : float) -> A.failf "no clock wired in to hold %f seconds" s) in
  let park () =
    let hold = !remaining in
    if hold > 0. then (
      remaining := 0.;
      !clock hold)
  in
  (park, clock)

let three_readers_of_one_cold_key_fill_it_once () =
  (* Singleflight, from the acceptance list: three callers at one cold key while
     the fill is still open, and between them they dispatch once.

     The assertions are about the totals rather than about which caller won: one
     dispatch, one entry, one [cached=false] line and two [cached=true] lines.
     Which fiber leads is the scheduler's, and the rule has to hold either way. *)
  let park, clock = hold_first_dispatch () in
  let local = stub ~park () in
  with_board local (fun board ->
      clock := board.sleep;
      let answers = Array.make 3 (None : string option) in
      Eio.Fiber.all
        [
          (fun () -> answers.(0) <- (served board url).Model.text);
          (fun () -> answers.(1) <- (served board url).Model.text);
          (fun () -> answers.(2) <- (served board url).Model.text);
        ];
      (* [Eio.Fiber.all] has joined the three by here, so the counts are counts of
         finished calls. *)
      A.(check int "three reads, one dispatch" 1 !(local.calls));
      A.(check int "one entry" 1 (entries board));
      A.(check (array (option string)) "every caller got the whole page"
           (Array.make 3 (Some page_text))
           answers);
      (* Which of the three writes its [fetch.ok] line first is the scheduler's —
         the leader looks its own window back up out of the entry it just wrote,
         and a lookup is a filesystem read. So this asserts the multiset: one line
         says it dispatched, two say they did not. *)
      A.(check (list bool) "one fill and two followers" [ false; true; true ]
           (List.sort Stdlib.compare (cached_flags board.lines))))

(* {1 Rungs, and the price of a cached page} *)

let each_rung_has_its_own_entry () =
  let local = stub () in
  let named = stub ~name:"jina" () in
  with_board ~fallbacks:[ named ] local (fun board ->
      ignore (served board url);
      ignore (served board ~provider:"jina" url);
      A.(check int "the local reader dispatched once" 1 !(local.calls));
      A.(check int "the named rung dispatched once of its own" 1 !(named.calls));
      A.(check int "two rungs, two entries" 2 (entries board));
      ignore (served board url);
      ignore (served board ~provider:"jina" url);
      A.(check int "neither repeat reached its origin" 1 !(local.calls));
      A.(check int "nor did the named one" 1 !(named.calls));
      A.(check (list bool) "both repeats are dispatch-free" [ false; false; true; true ]
           (cached_flags board.lines)))

let a_cached_page_of_a_priced_rung_is_unbilled () =
  (* The journal rule the acceptance names: [cost_usd] absent means "nothing was
     spent", so a cached read of a paid route carries no cost whatever that route
     charges, and the total stays at the one call that was made. *)
  let local = stub () in
  let paid = stub ~name:"scrappa" ~cost_per_1k:(Some 0.30) () in
  with_board ~fallbacks:[ paid ] local (fun board ->
      ignore (served board ~provider:"scrappa" url);
      (match recent board with
      | [ first ] ->
          A.(check string "the rung that dispatched is named" "scrappa"
               (str (get "fallback" first)));
          A.(check bool "and its call is priced" false (is_null (get "cost_usd" first)))
      | many -> A.failf "expected one journal entry, got %d" (List.length many));
      ignore (served board ~provider:"scrappa" url);
      A.(check int "the priced rung dispatched once in total" 1 !(paid.calls));
      A.(check (list bool) "the second read is dispatch-free" [ false; true ]
           (cached_flags board.lines));
      (* The journal's [recent] list is newest first. *)
      (match recent board with
      | [ latest; first ] ->
          A.(check string "the cached read still names its rung" "scrappa"
               (str (get "fallback" latest)));
          A.(check bool "with no cost on the line" true (is_null (get "cost_usd" latest)));
          A.(check string "and the call that dispatched still carries its price" "scrappa"
               (str (get "fallback" first)))
      | many -> A.failf "expected two journal entries, got %d" (List.length many));
      let totals = get "totals" (Usage.snapshot board.usage) in
      A.(check int "both reads are counted as fetches" 2 (number (get "fetches" totals)));
      A.(check int "and the money total covers one priced call" 1
           (number (get "priced_fetches" totals))))

(* {1 What the store never holds} *)

let an_image_page_bypasses_the_store () =
  let local =
    stub ~image:({ Engine.Fetch.media_type = "image/png"; body = "\x89PNG\x0d\x0a\x1a\nbytes" }) ()
  in
  with_board local (fun board ->
      let first = served board url in
      ignore (served board url);
      A.(check bool "the image is carried both times" true (first.Model.image <> None));
      A.(check int "an image dispatches every time" 2 !(local.calls));
      A.(check (list bool) "and is never dispatch-free" [ false; false ] (cached_flags board.lines));
      A.(check int "no entry was written" 0 (entries board)))

let a_page_over_the_entry_cap_is_served_and_stays_uncached () =
  (* The runtime store failure the plan names: the page arrived, the cache would
     not take it, and the caller still has a page. It is not an error, and it does
     not become one on the next call — which dispatches again. *)
  let local = stub () in
  with_board ~cache_max_entry_bytes:32 local (fun board ->
      let first = served board url in
      A.(check string "the oversized page is served whole" page_text (say first.Model.text));
      ignore (served board url);
      A.(check int "so every read of it dispatches" 2 !(local.calls));
      A.(check (list bool) "and none is reported cached" [ false; false ] (cached_flags board.lines));
      A.(check int "and the directory holds nothing" 0 (entries board)))

let a_failed_fill_leaves_nothing_behind () =
  (* A failure is not a thing to store. The next call dispatches again, and that
     one succeeds and is served normally. *)
  let local = stub ~fails:1 () in
  with_board local (fun board ->
      let sentence = failed board url in
      includes "the caller is told what failed" "HTTP 503" sentence;
      A.(check int "the failed fill dispatched" 1 !(local.calls));
      A.(check int "and stored nothing" 0 (entries board));
      let second = served board url in
      A.(check int "the next call dispatches again" 2 !(local.calls));
      A.(check string "and serves the page" page_text (say second.Model.text));
      A.(check (list bool) "and the one line it logged is not a cached read" [ false ]
           (cached_flags board.lines));
      A.(check int "the failure is journaled as an error, not a fetch" 1
           (List.length (List.filter (fun c -> c.event = "fetch.failed") !(board.lines)))))

let waiters_on_a_failed_fill_all_get_that_failure () =
  (* The singleflight half of the same rule: callers parked on a fill inherit the
     one failure their leader saw instead of each dispatching its own, and the
     directory stays empty. Every caller hears the same sentence, which is what
     makes it one failure rather than three attempts that happened to fail alike. *)
  let park, clock = hold_first_dispatch () in
  let local = stub ~fails:1 ~park () in
  with_board local (fun board ->
      clock := board.sleep;
      let sentences = Array.make 3 "" in
      let call i =
        match Engine.Fetch.fetch board.engine url with
        | Ok _ -> sentences.(i) <- "a page"
        | Error (Engine.Fetch.Refused sentence) -> sentences.(i) <- sentence
        | Error (Engine.Fetch.Failed sentence) -> sentences.(i) <- sentence
      in
      Eio.Fiber.all [ (fun () -> call 0); (fun () -> call 1); (fun () -> call 2) ];
      A.(check int "three callers, one dispatch" 1 !(local.calls));
      A.(check (array string) "one failure, handed to all three"
           (Array.make 3 sentences.(0))
           sentences);
      includes "and the sentence says what failed" "HTTP 503" sentences.(0);
      A.(check int "and nothing was stored" 0 (entries board)))

(* {1 The directory is created or refused, and the guardrail answers first} *)

let an_unusable_cache_dir_is_a_refusal_not_a_miss () =
  (* Startup half of the F7 contract: [cache_dir] is the operator's word, so a
     directory this process cannot create is a refusal the builder returns, not a
     cache that silently never fills. The parent here is a regular file. *)
  let blocker = Filename.temp_file "seekwright-not-a-directory" "" in
  let base = Config.default_fetch_config in
  let fetch = { base with Config.enabled = true; cache_dir = Some (blocker ^ "/pages") } in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let mono_clock = Eio.Stdenv.mono_clock env in
  let fs = Eio.Stdenv.fs env in
  match Config.resolve ~fetch () with
  | Error message -> A.failf "the fixture config was refused: %s" message
  | Ok config -> (
      match Factory.build_page_cache ~sw ~net:env#net ~mono_clock ~now ~fs config with
      | Ok Some _ -> A.fail "an unopenable cache_dir built a cache"
      | Ok None -> A.fail "a set cache_dir built no cache"
      | Error message ->
          (* [--check] reads the same directory and reports the same reason, which
             is why the row counts as a problem rather than printing zeroes. *)
          check_bool "the refusal says something" true (String.length message > 0);
          match Factory.page_cache_stats ~sw ~mono_clock ~fs config with
          | Ok _ -> A.fail "the diagnosis invented figures for a directory it cannot open"
          | Error stats_message ->
              check_string "and [--check] reports the same reason" message stats_message)

let a_refused_url_is_refused_with_a_warm_entry () =
  (* Seed the entry, then ask the same directory for the same URL under the address
     rule that refuses it. The entry is there — the seed counted it — and the answer
     is still the guardrail's, because [preflight] is part of the seam rather than
     a step the caller may skip when it expects a hit. *)
  let target = "http://127.0.0.1:9/article" in
  let seed = stub () in
  with_board ~allow_private:true seed (fun board ->
      ignore (served board target);
      A.(check int "the seed dispatched once" 1 !(seed.calls));
      A.(check int "and left one entry behind" 1 (entries board));
      let dir = board.cache_dir in
      let guarded = stub () in
      with_board ~allow_private:false ~cache_dir:dir guarded (fun board ->
          let sentence = refused board target in
          includes "the address rule answers before the directory does" "not a public address"
            sentence;
          A.(check int "and nothing was dispatched" 0 !(guarded.calls));
          A.(check int "the warm entry is still there, which is the point" 1 (entries board))))

let no_cache_directory_means_every_read_dispatches () =
  (* The default path, and the one that ran before F7: no seam, so [cached] is
     [false] on every line and there is no directory to report. *)
  let local = stub () in
  let base = Config.default_fetch_config in
  let fetch = { base with Config.cache_dir = None } in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let mono_clock = Eio.Stdenv.mono_clock env in
  let fs = Eio.Stdenv.fs env in
  match Config.resolve ~fetch () with
  | Error message -> A.failf "the fixture config was refused: %s" message
  | Ok config -> (
      match Factory.build_page_cache ~sw ~net:env#net ~mono_clock ~now ~fs config with
      | Error message -> A.failf "build_page_cache on an unset cache_dir: %s" message
      | Ok Some _ -> A.fail "an unset cache_dir built a seam"
      | Ok None ->
          (match Factory.page_cache_stats ~sw ~mono_clock ~fs config with
          | Ok None -> ()
          | Ok Some _ -> A.fail "an unset cache_dir has no directory to report"
          | Error message -> A.failf "page_cache_stats on an unset cache_dir: %s" message);
          let lines = ref [] in
          match Usage.create ~now () with
          | Error message -> A.failf "an in-memory recorder cannot fail: %s" message
          | Ok usage -> (
              match
                Engine.Fetch.create config (make_fetcher local) ~readers ~usage ~log:(sink lines)
                  ~clock ~now ()
              with
              | Error message -> A.failf "the engine refused the fixture: %s" message
              | Ok engine ->
                  ignore (Engine.Fetch.fetch engine url);
                  ignore (Engine.Fetch.fetch engine url);
                  A.(check int "every read dispatched" 2 !(local.calls));
                  A.(check (list bool) "and [cached] stays false" [ false; false ]
                    (cached_flags lines))))

let () =
  A.run "fetch cache"
    [
      ( "one cold fill per key",
        [
          A.test_case "the fill dispatches, the follower does not" `Quick
            the_call_that_filled_dispatched_and_the_next_one_did_not;
          A.test_case "a windowed read stores the whole page" `Quick
            a_windowed_read_stores_the_whole_page_and_serves_only_its_window;
          A.test_case "three readers of one cold key fill it once" `Quick
            three_readers_of_one_cold_key_fill_it_once;
        ] );
      ( "rungs and prices",
        [
          A.test_case "each rung has its own entry" `Quick each_rung_has_its_own_entry;
          A.test_case "a cached page of a priced rung is unbilled" `Quick
            a_cached_page_of_a_priced_rung_is_unbilled;
        ] );
      ( "what the store never holds",
        [
          A.test_case "an image page bypasses the store" `Quick an_image_page_bypasses_the_store;
          A.test_case "a page over the entry cap stays uncached" `Quick
            a_page_over_the_entry_cap_is_served_and_stays_uncached;
          A.test_case "a failed fill leaves nothing behind" `Quick a_failed_fill_leaves_nothing_behind;
          A.test_case "waiters on a failed fill all get that failure" `Quick
            waiters_on_a_failed_fill_all_get_that_failure;
        ] );
      ( "the directory, and the guardrail",
        [
          A.test_case "an unusable cache dir is a refusal, not a miss" `Quick
            an_unusable_cache_dir_is_a_refusal_not_a_miss;
          A.test_case "a refused URL is refused with a warm entry" `Quick
            a_refused_url_is_refused_with_a_warm_entry;
          A.test_case "no cache_dir keeps every read dispatching" `Quick
            no_cache_directory_means_every_read_dispatches;
        ] );
    ]
