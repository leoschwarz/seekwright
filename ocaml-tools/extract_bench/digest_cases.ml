(* The F6.2 identity check: one line per corpus case with a digest of what the
   port's backend answers, so a change to the shared plumbing can be shown to
   leave the answer byte-identical rather than merely "still passing". *)

module S = Seekwright_fetch_stdlib.Stdlib
module E = Seekwright_fetch.Extractor
module M = Extract_metrics

let digest s = Digest.to_hex (Digest.string s)

let time ~name f =
  let best = ref max_float in
  let sink = ref 0 in
  for _ = 1 to 5 do
    let t0 = Sys.time () in
    (match f () with
    | n -> sink := !sink + n
    | exception _ -> ());
    best := Float.min !best (Sys.time () -. t0)
  done;
  Printf.printf "%-34s %8.1f ms   (sink %d)\n" name (!best *. 1000.0) !sink

let read path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let chars_of r = String.length r.E.text

let phases path =
  let body = read path in
  let plain = Some "text/plain; charset=utf-8" in
  let html = Some "text/html; charset=utf-8" in
  Printf.printf "bytes=%d\n" (String.length body);
  time ~name:"decode only" (fun () -> String.length (E.decode body html));
  time ~name:"extract as plain text" (fun () -> chars_of (S.extract body plain));
  time ~name:"normalise only (decoded, plain)" (fun () -> chars_of (E.normalise (E.decode body html) None));
  time ~name:"extract as html" (fun () -> chars_of (S.extract body html))

let digests dir =
  List.iter
    (fun (c : M.case) ->
      match S.extract c.body c.content_type with
      | r ->
          Printf.printf "%-26s text=%s chars=%d title=%s\n" c.M.id
            (digest r.E.text) r.E.total_chars
            (match r.E.title with Some t -> digest t | None -> "-")
      | exception E.Extraction_failed m ->
          Printf.printf "%-26s refusal=%s\n" c.M.id m)
    (Extract_metrics.load_cases dir)

(* [--check <corpus> <parity-file>] is a gate rule: the same digests, compared
   with a checked-in file rather than printed. A backend edit that changes what a
   page answers fails here even when every bar still passes, which is what a bar
   cannot do — a bar is a floor on recall, and this is the byte. *)
let check_parity dir file =
  let expected =
    let ic = open_in file in
    let rec go acc =
      match input_line ic with
      | line -> go (line :: acc)
      | exception End_of_file -> List.rev acc
    in
    go []
  in
  let got =
    let lines = ref [] in
    List.iter
      (fun (c : M.case) ->
        match S.extract c.body c.content_type with
        | r ->
            lines
              := Printf.sprintf "%-26s text=%s chars=%d title=%s" c.M.id
                   (digest r.E.text) r.E.total_chars
                   (match r.E.title with Some t -> digest t | None -> "-")
                 :: !lines
        | exception E.Extraction_failed m ->
            lines := Printf.sprintf "%-26s refusal=%s" c.M.id m :: !lines)
      (Extract_metrics.load_cases dir);
    List.rev !lines
  in
  let differs =
    List.filteri
      (fun i line -> i >= List.length expected || List.nth expected i <> line)
      got
  in
  let missing = List.length expected - List.length got in
  if differs = [] && missing <= 0 then 0
  else (
    List.iter (fun line -> prerr_endline ("parity drift: " ^ line)) differs;
    if missing > 0 then
      prerr_endline
        (Printf.sprintf "parity drift: %d recorded line(s) no longer produced" missing);
    prerr_endline
      (Printf.sprintf
         "%s no longer matches the recorded extraction digests: the backend's answer \
          changed, and the recorded file has to be re-generated in the same change"
         file);
    1)

let () =
  match Array.to_list Sys.argv with
  | [ _; "--phases"; path ] -> phases path
  | [ _; "--digest"; dir ] -> digests dir
  | [ _; "--check-parity"; dir; file ] -> exit (check_parity dir file)
  | _ ->
      prerr_endline
        "usage: digest_cases --phases <file> | --digest <corpus-dir> | --check-parity \
         <corpus-dir> <parity-file>";
      exit 2
