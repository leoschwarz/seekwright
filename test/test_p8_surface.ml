(* P8: the frozen surface's last data block — the usage-journal field sets.
   [ocaml-tools/surface.ml] prints {!Seekwright.Server.journal_fields}; this
   suite pins that list against a real journal: one recorder with a real
   [history_path], one line per kind (success and failure, so the optional
   keys appear), and the union of keys per [tool] line kind, sorted, compared
   to the data. A field renamed in [usage.ml] therefore fails here, and a
   field added there fails the surface golden. *)

module Server = Seekwright.Server
module Usage = Seekwright.Usage
module A = Alcotest
open Test_support

let now () = 1_700_000_000.0

let root = "p8-surface-journal"

let read_lines path =
  read_file path |> String.split_on_char '\n' |> List.filter (fun line -> line <> "")

(* Union of the keys each [tool] kind's lines carry, sorted by kind — the shape
   {!Server.journal_fields} is printed in. *)
let journal_keys_by_kind lines =
  let add map line =
    let json = Yojson.Safe.from_string line in
    match json with
    | `Assoc fields -> (
        match List.assoc_opt "tool" fields with
        | Some (`String kind) ->
            let keys = List.sort compare (List.map fst fields) in
            let merged =
              match List.assoc_opt kind map with
              | Some existing -> List.sort compare (existing @ keys)
              | None -> keys
            in
            (* dedup the union *)
            let rec dedup = function
              | a :: (b :: _ as rest) -> if a = b then dedup rest else a :: dedup rest
              | rest -> rest
            in
            (kind, dedup merged) :: List.remove_assoc kind map
        | _ -> map)
    | _ -> map
  in
  List.sort compare (List.fold_left add [] lines)

let the_journal_fields_match_the_pin _ =
  (try Unix.mkdir root 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let file = Filename.concat root "usage.jsonl" in
  (try Sys.remove file with _ -> ());
  Eio_main.run @@ fun env ->
  let path =
    List.fold_left (fun acc part -> Eio.Path.(acc / part)) (Eio.Stdenv.fs env) [ root; "usage.jsonl" ]
  in
  let usage =
    match Usage.create ~now ~history_path:path () with
    | Ok u -> u
    | Error message -> A.failf "the journal did not open: %s" message
  in
  (* One successful and one failed line per kind, so the optional keys
     ([error], [run], [step], the token counts, [cost_usd]) all appear. *)
  Usage.record_search usage ~provider:"serper" ~ms:10 ~cost_usd:0.001 ~results:1 ~fell_back:false
    ~run:"run-1" ~step:1 ();
  Usage.record_search usage ~provider:"serper" ~ms:5 ~cost_usd:0.0 ~results:0 ~fell_back:false
    ~error:"ProviderError" ();
  Usage.record_fetch usage ~ms:20 ~chars:100 ~fallback:(Some "jina") ~cost_usd:0.002 ~run:"run-1"
    ~step:2 ();
  Usage.record_fetch usage ~ms:7 ~chars:0 ~fallback:None ~error:"FetchBlocked" ();
  Usage.record_answer usage ~run:"run-1" ~model:(Some "stub-model") ~depth:"brief" ~searches:2
    ~results:5 ~fetched:1 ~material_chars:900 ~prompt_tokens:(Some 120)
    ~completion_tokens:(Some 80) ~answer_chars:300 ~cited:2 ~cited_invalid:0 ~sources:2
    ~model_cost_usd:(Some 0.0004) ~ms:900 ();
  Usage.record_answer usage ~run:"run-2" ~model:None ~depth:"brief" ~searches:1 ~results:0
    ~fetched:0 ~material_chars:0 ~prompt_tokens:None ~completion_tokens:None ~answer_chars:0
    ~cited:0 ~cited_invalid:0 ~sources:0 ~model_cost_usd:None ~ms:50 ~error:"ProviderError" ();
  let actual = List.sort compare (journal_keys_by_kind (read_lines file)) in
  A.(check (list (pair string (list string)))) "journal fields per line kind"
    (List.sort compare Server.journal_fields)
    actual

let () =
  A.run "seekwright/p8-surface"
    [
      ( "journal",
        [ A.test_case "the journal field sets match the surface pin" `Quick the_journal_fields_match_the_pin ] );
    ]
