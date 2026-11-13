(* The live harness's front door: the gate, the one-selector rule, and the
   process's exit status. Everything a run decides lives in [Live_harness];
   this file owns the streams and the two refusals that must happen before any
   network construction exists.

   [--list] and [--help] are hermetic: they print the inventory and dial
   nothing, so they do not need the gate. A run does. *)

module Cases = Live_harness.Cases
module Runner = Live_harness.Runner

let gate_variable = "SEEKWRIGHT_LIVE_TESTS"

let gate_is_set () =
  match Sys.getenv_opt gate_variable with Some "1" -> true | _ -> false

let refuse_gate () =
  prerr_endline
    ("seekwright-live: refusing to run: " ^ gate_variable
   ^ " is not \"1\".");
  prerr_endline "";
  prerr_endline "A live run reaches a real provider endpoint and may spend money.";
  prerr_endline "Set the gate and name exactly one case, for example:";
  prerr_endline "  SEEKWRIGHT_LIVE_TESTS=1 seekwright-live freeserp";
  exit 2

let refuse_usage message =
  prerr_endline ("seekwright-live: " ^ message);
  prerr_endline "";
  prerr_endline Cases.usage;
  exit 2

let list_lines () =
  let header =
    Printf.sprintf "%-20s %-11s %-9s %-52s %s" "case" "build" "ocaml" "cost" "needs"
  in
  let row selector =
    let build =
      match Cases.build_status selector with
      | Cases.Runnable -> "runnable"
      | Cases.Deferred wave -> "deferred " ^ wave
    in
    let ocaml =
      match Cases.live_status selector with `Tested -> "tested" | `Untested -> "untested"
    in
    Printf.sprintf "%-20s %-11s %-9s %-52s %s" (Cases.name selector) build ocaml
      (Cases.cost_prose selector)
      (String.concat ", " (Cases.needs selector))
  in
  header
  :: List.map row Cases.all
  @ [
      "";
      "runnable means this build carries the adapter, not that a live run has passed.";
      "A run needs " ^ gate_variable ^ "=1 and exactly one case from this list.";
    ]

let () =
  (* The port's TLS stack needs a generator installed by the application, as
     bin/main.ml does. Nothing is dialled by --list, but installing it is cheap
     and keeps the run path free of a branch. *)
  Mirage_crypto_rng_unix.use_default ();
  let arguments = List.tl (Array.to_list Sys.argv) in
  match arguments with
  | [ "--help" ] | [ "-h" ] -> print_endline Cases.usage
  | [ "--list" ] -> List.iter print_endline (list_lines ())
  | [] ->
      prerr_endline "seekwright-live: no case was named.";
      prerr_endline "";
      prerr_endline "The default is no provider, not every configured one.";
      prerr_endline "";
      prerr_endline Cases.usage;
      exit 2
  | [ spelling ] ->
      if not (gate_is_set ()) then refuse_gate ();
      (match Cases.parse spelling with
      | Error message -> refuse_usage message
      | Ok selector ->
          let status =
            Eio_main.run @@ fun env ->
            Eio.Switch.run @@ fun sw ->
            Runner.run ~env ~sw ~selector ~emit:print_endline
          in
          flush stdout;
          exit (Runner.status_exit status))
  | _ -> refuse_usage "exactly one case is accepted; this harness has no all-providers mode"
