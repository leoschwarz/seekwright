(* The operation budget is the one ceiling in this layer whose scope is the
   caller's rather than the grant's, and that distinction is the whole design
   (plans/capability-gated-mcp-server.md §6 refuses a counter inside a grant
   because a server-lifetime grant cannot hold a per-request limit). So the
   cases here are about the counter's arithmetic, its atomicity, and — most of
   all — whose ceiling it is.

   Two things are pinned that a naive counter gets wrong:

   - [take] is one step, so N fibers at the boundary cannot all be told yes.
     [Budget.take] uses a compare-and-set rather than an increment-plus-read for
     exactly this, so both a domain fan-out and a fiber fan-out are asked.
   - a refusal spends nothing and does no I/O. The proof is the error kind: a
     spent budget refuses with [Denied] and its own sentence even for an
     operation that would have failed some other way, which is only possible if
     the operation never started.

   And the scope claim, which is what the layer's docstring promises: the same
   budget shared across two grants counts both, and two budgets stay apart —
   so a caller can bound a plan without reaching into anyone else's. *)

module Caps = Mcp_caps
module A = Alcotest
open Test_support

module Authority = Caps.Authority
module Budget = Caps.Budget
module Error = Caps.Error
module Policy = Caps.Policy

(* ------------------------------------------------------------------ *)
(* the counter's own arithmetic                                         *)
(* ------------------------------------------------------------------ *)

let test_a_budget_spends_its_limit_and_no_more () =
  let budget = Budget.make 3 in
  A.(check int "the limit is what was asked for" 3 (Budget.limit budget));
  A.(check int "nothing is spent yet" 3 (Budget.remaining budget));
  (* sequenced, not a list literal: OCaml evaluates arguments right to left, and
     the order here is the claim *)
  let first = Budget.take budget in
  let second = Budget.take budget in
  let third = Budget.take budget in
  let fourth = Budget.take budget in
  A.(check (A.list A.bool) "the first three are granted, the fourth is not"
       [ true; true; true; false ] [ first; second; third; fourth ]);
  A.(check int "spent" 0 (Budget.remaining budget));
  A.(check int "the limit does not move when it is spent" 3 (Budget.limit budget));
  (* spent is spent: a refusal does not hand the operation back *)
  A.(check bool "a fourth call still refuses" false (Budget.take budget));
  A.(check int "and nothing changed" 0 (Budget.remaining budget))

(* A non-positive limit is kept as given rather than normalised, so a caller
   reading [limit] back sees the number it wrote, while [take] refuses it
   directly and [remaining] never reports a negative count. *)
let test_a_non_positive_budget_spends_nothing () =
  List.iter
    (fun limit ->
      let budget = Budget.make limit in
      check_int "the limit is reported as written" limit (Budget.limit budget);
      A.(check int "nothing may be spent" 0 (Budget.remaining budget));
      A.(check bool "every operation is refused" false (Budget.take budget));
      A.(check bool "again" false (Budget.take budget));
      A.(check int "and the count stays at zero rather than going negative" 0
           (Budget.remaining budget)))
    [ 0; -1; -100 ]

(* [remaining] is a snapshot, not a reservation: it reports what is available at
   the instant it reads, and [take] is the only step that reserves. This is the
   difference a caller has to know — read it, then act on it, and the number may
   already be gone. *)
let test_remaining_is_a_snapshot_not_a_reservation () =
  let budget = Budget.make 1 in
  A.(check int "one left" 1 (Budget.remaining budget));
  A.(check int "the snapshot again" 1 (Budget.remaining budget));
  ignore (Budget.take budget);
  A.(check int "spent after the reservation" 0 (Budget.remaining budget));
  (* sequenced, because the order is the claim: the first call reads a number
     that is no longer true by the time it acts on it, the second finds nothing *)
  let budget = Budget.make 1 in
  let snapshot_then_take () =
    let left = Budget.remaining budget in
    let spent_one = Budget.take budget in
    (left, spent_one)
  in
  let first = snapshot_then_take () in
  let second = snapshot_then_take () in
  A.(check (A.list A.(pair int bool)) "the snapshot can be stale, the reservation cannot"
       [ (1, true); (0, false) ] [ first; second ])

(* ------------------------------------------------------------------ *)
(* the counter is one step                                              *)
(* ------------------------------------------------------------------ *)

(* Domains, not fibers: [take] is stdlib [Atomic], so the race worth pinning is
   a real parallel one — N threads at the boundary, each racing to reserve the
   last operation. An increment-plus-read would let several pass the same check. *)
let test_a_budget_across_domains_spends_exactly_its_limit () =
  List.iter
    (fun limit ->
      let budget = Budget.make limit in
      let competitors = 32 in
      let granted =
        List.map Domain.join
        @@ List.init competitors
             (fun _ ->
               Domain.spawn
                 (fun () ->
                   let hits = ref 0 in
                   for _ = 1 to 20 do
                     if Budget.take budget then incr hits
                   done;
                   !hits))
      in
      let total = List.fold_left (+) 0 granted in
      check_int
        (Printf.sprintf "%d competitors, limit %d: exactly the limit is granted" competitors limit)
        limit total;
      A.(check int "and the counter is empty" 0 (Budget.remaining budget));
      A.(check int "the limit is untouched" limit (Budget.limit budget)))
    [ 1; 7; 32; 500 ]

(* The same shape over Eio fibers, because a grant is shared by the fibers of
   one request, and a budget carried by that grant sees them all: what is
   granted is what reaches the network. *)
let test_fibers_sharing_a_grant_are_granted_exactly_the_limit () =
  let limit = 6 in
  let fibers = 16 in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~backlog:32 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> A.failf "the fixture listener is not a TCP socket: %s" path
  in
  let arrived = ref 0 in
  let server =
    Cohttp_eio.Server.make
      ~callback:(fun _conn _request _body ->
        incr arrived;
        Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok" ())
      ()
  in
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
    (fun () ->
      match
        Policy.with_endpoints ~sw ~net:env#net ~max_response_bytes:1_000_000
          [ { Policy.scheme = `Http; host = "127.0.0.1"; port = Some port } ]
      with
      | Error error -> A.failf "with_endpoints: %s" (Error.render error)
      | Ok decision ->
          let budget = Budget.make limit in
          let grant =
            Authority.with_operation_budget budget
              (Authority.Net.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) decision)
          in
          (* [Eio.Fiber.all] runs its arguments concurrently in one switch, so
             every fiber reaches for the same counter at the same moment; the
             result of each call is parked in a reference because the combinators
             themselves hand back [unit]. *)
          let results = Array.make fibers (Ok { Authority.Net.status = 0; headers = []; body = "" }) in
          Eio.Fiber.all
            (List.mapi
               (fun index () ->
                 fun () ->
                   results.(index)
                   <- Authority.Net.request grant
                        {
                          meth = `GET;
                          uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/" port);
                          headers = [];
                          body = None;
                        })
               (List.init fibers (fun _ -> ())));
          let results = Array.to_list results in
          let successes =
            List.fold_left
              (fun acc result -> match result with Ok _ -> acc + 1 | Error _ -> acc)
              0 results
          in
          let refusals =
            List.fold_left
              (fun acc result ->
                match result with
                | Error error ->
                    A.(check string "a spent budget refuses" "denied"
                         (Error.kind_to_string (Error.kind error)));
                    includes "the refusal names the caller's ceiling" "operation budget"
                      (Error.message error);
                    acc + 1
                | Ok _ -> acc)
              0 results
          in
          A.(check int "exactly the limit reached the network" limit successes);
          A.(check int "the rest were refused" (fibers - limit) refusals);
          A.(check int "and the fixture saw exactly the granted count" limit !arrived);
          A.(check int "the counter is spent" 0 (Budget.remaining budget)))

(* ------------------------------------------------------------------ *)
(* whose ceiling it is                                                  *)
(* ------------------------------------------------------------------ *)

(* One budget, two grants: the caller's plan is what is bounded, whichever power
   the operations use. This is the shape an [answer] plan uses — its queries and
   its page reads together, against one ceiling. *)
let test_one_budget_spans_every_grant_it_is_attached_to () =
  let root = Filename.temp_dir "caps-budget-fs" "" in
  let write name contents =
    let channel = open_out (Filename.concat root name) in
    output_string channel contents;
    close_out channel
  in
  write "one.md" "first\n";
  write "two.md" "second\n";
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) root with
  | Error error -> A.failf "with_root: %s" (Error.render error)
  | Ok confinement ->
      let mono_clock = Eio.Stdenv.mono_clock env in
      let budget = Budget.make 3 in
      let first =
        Authority.with_operation_budget budget
          (Authority.Fs.of_confinement ~mono_clock confinement)
      in
      let second =
        Authority.with_operation_budget budget
          (Authority.Fs.of_confinement ~mono_clock confinement)
      in
      (* alternating, so neither grant can be quietly counting its own *)
      let calls =
        [
          (fun () -> Authority.Fs.read_file first "one.md");
          (fun () -> Authority.Fs.read_file second "two.md");
          (fun () -> Authority.Fs.read_file first "two.md");
          (fun () -> Authority.Fs.read_file second "one.md");
          (fun () -> Authority.Fs.read_file first "one.md");
        ]
      in
      let kinds =
        List.map
          (fun call ->
            match call () with
            | Ok _ -> "ok"
            | Error error -> Error.kind_to_string (Error.kind error))
          calls
      in
      A.(check (A.list A.string) "three granted across both grants, then refused"
           [ "ok"; "ok"; "ok"; "denied"; "denied" ] kinds);
      A.(check int "one counter, spent once" 0 (Budget.remaining budget))

(* Two budgets stay apart, and a grant keeps its own counter after a caller's is
   spent: the decorator does not mutate the grant it is given, so the caller's
   ceiling cannot leak into the next caller's. *)
let test_two_budgets_do_not_share_a_counter () =
  let root = Filename.temp_dir "caps-budget-fs2" "" in
  let channel = open_out (Filename.concat root "note.md") in
  output_string channel "note\n";
  close_out channel;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) root with
  | Error error -> A.failf "with_root: %s" (Error.render error)
  | Ok confinement ->
      let mono_clock = Eio.Stdenv.mono_clock env in
      let plain = Authority.Fs.of_confinement ~mono_clock confinement in
      let tight = Authority.with_operation_budget (Budget.make 1) plain in
      let loose = Authority.with_operation_budget (Budget.make 2) plain in
      let kinds grant =
        match Authority.Fs.read_file grant "note.md" with
        | Ok _ -> "ok"
        | Error error -> Error.kind_to_string (Error.kind error)
      in
      (* sequenced: the order of the calls is the claim, and OCaml evaluates
         arguments right to left *)
      let tight_first = kinds tight in
      let tight_second = kinds tight in
      let loose_first = kinds loose in
      let loose_second = kinds loose in
      let loose_third = kinds loose in
      A.(check (A.list A.string) "each grant spends its own counter"
           [ "ok"; "denied"; "ok"; "ok"; "denied" ]
           [ tight_first; tight_second; loose_first; loose_second; loose_third ]);
      A.(check string "and the undecorated grant is unbounded" "ok" (kinds plain));
      A.(check string "still unbounded after the others ran out" "ok" (kinds plain))

(* A refused call does no I/O at all. The proof is the kind: this path would
   have failed as [Unavailable] (no such file) or as a grant refusal (no such
   host), and instead it reports the budget's own sentence — which it could not
   do if the operation had run. *)
let test_a_spent_budget_refuses_without_running_the_operation () =
  let root = Filename.temp_dir "caps-budget-fs3" "" in
  let budget = Budget.make 0 in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) root with
  | Error error -> A.failf "with_root: %s" (Error.render error)
  | Ok confinement ->
      let grant =
        Authority.with_operation_budget budget
          (Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement)
      in
      (match Authority.Fs.read_file grant "no-such-file-at-all" with
      | Ok _ -> A.fail "the read ran"
      | Error error ->
          A.(check string "refused before the filesystem was touched" "denied"
               (Error.kind_to_string (Error.kind error)));
          includes "the sentence names the caller's ceiling" "operation budget of 0"
            (Error.message error);
          (* the refusal is about the count, never about the argument: a path is
             not something the audit trail and the tool result carry *)
          A.(check bool "the message does not name the path" false
               (contains ~haystack:(Error.message error) ~needle:"no-such-file-at-all"));
          A.(check bool "the message does not name the root" false
               (contains ~haystack:(Error.message error) ~needle:root)));
      (match Authority.Fs.list_dir grant "" with
      | Ok _ -> A.fail "the listing ran"
      | Error error ->
          A.(check string "the other operation of the same grant is refused too" "denied"
               (Error.kind_to_string (Error.kind error))));
      (* and a spent counter stays spent while the grant itself is fine: the
         same confinement, undecorated, still answers *)
      let plain = Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement in
      match Authority.Fs.list_dir plain "" with
      | Error error -> A.failf "the undecorated grant should answer: %s" (Error.render error)
      | Ok names -> A.(check (A.list A.string) "the confinement is unchanged" [] names)

(* Retaining the decorated grant is the point of the decorator: the same caller,
   the same counter, over every operation it goes on to do. *)
let test_a_decorated_grant_keeps_spending_the_same_counter () =
  let root = Filename.temp_dir "caps-budget-fs4" "" in
  for i = 1 to 4 do
    let channel = open_out (Filename.concat root (Printf.sprintf "n%d.md" i)) in
    output_string channel "x\n";
    close_out channel
  done;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Policy.with_root ~sw ~parent:(Eio.Stdenv.fs env) root with
  | Error error -> A.failf "with_root: %s" (Error.render error)
  | Ok confinement ->
      let budget = Budget.make 3 in
      let grant =
        Authority.with_operation_budget budget
          (Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement)
      in
      let kept = Authority.with_log ~sink:(fun _event -> ()) grant in
      let kinds paths =
        List.map
          (fun path ->
            match Authority.Fs.read_file kept path with
            | Ok _ -> "ok"
            | Error error -> Error.kind_to_string (Error.kind error))
          paths
      in
      A.(check (A.list A.string) "the retained grant spends the same counter"
           [ "ok"; "ok"; "ok"; "denied" ]
           (kinds [ "n1.md"; "n2.md"; "n3.md"; "n4.md" ]));
      A.(check int "and the budget sees all four calls, not the last one's" 0
           (Budget.remaining budget));
      ignore (kinds [ "n1.md" ])

(* A budget bounds the count of operations, never their cost — the docstring's
   claim, and the reason a per-operation ceiling cannot be the only bound on
   what a served request costs. *)
let test_a_budget_counts_operations_not_bytes () =
  let root = Filename.temp_dir "caps-budget-fs5" "" in
  let small = Filename.concat root "small.txt" in
  let big = Filename.concat root "big.txt" in
  let write path contents =
    let channel = open_out path in
    output_string channel contents;
    close_out channel
  in
  write small "x";
  write big (String.make (400 * 1024) 'x');
  let budget = Budget.make 2 in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  (* the grant's read ceiling is raised past both files: the point of the case is
     that the *count* runs out, not the byte ceiling *)
  match Policy.with_root ~sw ~max_read_bytes:1_000_000 ~parent:(Eio.Stdenv.fs env) root with
  | Error error -> A.failf "with_root: %s" (Error.render error)
  | Ok confinement ->
      let grant =
        Authority.with_operation_budget budget
          (Authority.Fs.of_confinement ~mono_clock:(Eio.Stdenv.mono_clock env) confinement)
      in
      match (Authority.Fs.read_file grant "small.txt", Authority.Fs.read_file grant "big.txt") with
      | Error error, _ | _, Error error -> A.failf "both reads are within their ceilings: %s" (Error.render error)
      | Ok small_text, Ok big_text ->
          A.(check int "one byte" 1 (String.length small_text));
          A.(check int "four hundred thousand bytes" (400 * 1024) (String.length big_text));
          A.(check int "and the budget spent two, because it counts calls" 0
               (Budget.remaining budget));
          A.(check bool "the third is refused whatever its size would have been" false
               (Budget.take budget))

(* ------------------------------------------------------------------ *)

let () =
  A.run "caps-budget"
    [
      ( "the counter",
        [
          A.test_case "a budget spends its limit and no more" `Quick
            test_a_budget_spends_its_limit_and_no_more;
          A.test_case "a non-positive budget spends nothing" `Quick
            test_a_non_positive_budget_spends_nothing;
          A.test_case "remaining is a snapshot, not a reservation" `Quick
            test_remaining_is_a_snapshot_not_a_reservation;
        ] );
      ( "atomicity",
        [
          A.test_case "a budget across domains spends exactly its limit" `Quick
            test_a_budget_across_domains_spends_exactly_its_limit;
          A.test_case "fibers sharing a grant are granted exactly the limit" `Quick
            test_fibers_sharing_a_grant_are_granted_exactly_the_limit;
        ] );
      ( "whose ceiling",
        [
          A.test_case "one budget spans every grant it is attached to" `Quick
            test_one_budget_spans_every_grant_it_is_attached_to;
          A.test_case "two budgets do not share a counter" `Quick
            test_two_budgets_do_not_share_a_counter;
          A.test_case "a spent budget refuses without running the operation" `Quick
            test_a_spent_budget_refuses_without_running_the_operation;
          A.test_case "a decorated grant keeps spending the same counter" `Quick
            test_a_decorated_grant_keeps_spending_the_same_counter;
          A.test_case "a budget counts operations, not bytes" `Quick
            test_a_budget_counts_operations_not_bytes;
        ] );
    ]
