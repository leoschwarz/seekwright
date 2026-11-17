(* [Remote_target.make_check] is the gate the factory builds once and hands every remote
   fallback: [validate_url] first, then the public-address vet. The address sentences
   themselves are pinned in [test_authority_net] beside the vet; what this suite owns is
   the composition — the order, and which sentence each arm arrives with. *)

module Fix = Fallback_fixtures

let check =
  Seekwright_fetch.Remote_target.make_check ~private_web_allowed:false ~net:(Fix.scripted_net ())

let cases () =
  (* Both guards pass: the caller gets the normalised target back. *)
  (match check "https://public.test/page" with
  | Ok target -> Alcotest.(check string) "normalised" target "https://public.test/page"
  | Error message -> Alcotest.failf "a public target was refused: %s" message);
  (* The syntax arm first: a non-fetchable scheme never reaches the resolver,
     which is the sentence [request_guard.validate_url] writes — with the
     scheme through Python's [repr], so it arrives quoted. *)
  Alcotest.(check string)
    "scheme refused"
    (Result.get_error (check "ftp://public.test/x"))
    "scheme 'ftp' is not fetchable; only http and https are allowed";
  Alcotest.(check string)
    "credentials refused"
    (Result.get_error (check "https://u:p@public.test/x"))
    "URLs with embedded credentials are refused";
  (* The address arm: the vet's sentence arrives verbatim, loopback named —
     the operator's [fetch.allow_private_addresses] cannot reach here. *)
  Alcotest.(check string)
    "loopback refused"
    (Result.get_error (check "http://internal.test/x"))
    "internal.test resolves to a non-public address (127.0.0.1); fetching private, loopback and \
     link-local addresses is disabled";
  (* A name the resolver answers nothing for is the vet's other sentence. *)
  Alcotest.(check string)
    "unresolvable refused"
    (Result.get_error (check "https://nowhere.test/x"))
    "could not resolve nowhere.test";
  (* The IP-literal short circuit: no lookup, straight to the address rule. *)
  Alcotest.(check string)
    "literal loopback refused"
    (Result.get_error (check "http://127.0.0.1/x"))
    "127.0.0.1 is not a public address"

let () =
  Alcotest.run "remote_target"
    [ ("the composition", [ Alcotest.test_case "arms and order" `Quick cases ]) ]
