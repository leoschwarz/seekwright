(* The client verbs: argument scan (in {!Seekwright.Cli_extract}), request
   bodies, the injected [post] seam, status handling and the human
   rendering. All moved out of [bin/main.ml] so the rendering and the status
   sentences are testable without a socket; [bin/main.ml] keeps the real
   poster and the streams. *)

module Model = Seekwright.Model

type post = path:string -> string -> (int * string, string) result

type rendered =
  | R_search of Model.search_response
  | R_fetch of Model.fetch_response
  | R_answer of Model.answer_response

type verb =
  | Search
  | Fetch
  | Answer

let verb_of_string = function
  | "search" -> Some Search
  | "fetch" -> Some Fetch
  | "answer" -> Some Answer
  | _ -> None

(* The Python joins the server URL to the route after dropping one trailing
   "/": [http://host:8000/] and [http://host:8000] post to the same path. *)
let strip_trailing_slash url =
  let n = String.length url in
  if n > 0 && url.[n - 1] = '/' then String.sub url 0 (n - 1) else url

let error_message status text =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error _ ->
      Printf.sprintf "HTTP %d%s" status (if text = "" then "" else ": " ^ String.trim text)
  | json -> (
      match
        (match json with
        | `Assoc fields -> ( match List.assoc_opt "error" fields with Some (`String m) -> Some m | _ -> None)
        | _ -> None)
      with
      | Some message -> Printf.sprintf "HTTP %d: %s" status message
      | _ ->
          Printf.sprintf "HTTP %d%s" status
            (if String.trim text = "" then "" else ": " ^ String.trim text))

(* {1 Human rendering} *)

let human_lines response =
  match response with
  | R_search sresp ->
      [
        "seekwright search";
        "=================";
        Printf.sprintf "query     %s" sresp.Model.query;
        Printf.sprintf "provider  %s" sresp.Model.provider;
        Printf.sprintf "results   %d" (List.length sresp.Model.results);
      ]
      @ (if sresp.Model.results = [] then [ ""; "no results" ] else [])
      @ List.concat_map
          (fun (index, (result : Model.result)) ->
            let content =
              match result.Model.snippet with Some s -> Some s | None -> result.Model.text
            in
            [
              "";
              Printf.sprintf "%d. %s" (index + 1) result.Model.title;
              Printf.sprintf "   %s" result.Model.url;
            ]
            @ (match content with
              | Some text -> List.map (fun line -> "   " ^ line) (String.split_on_char '\n' text)
              | None -> []))
          (List.mapi (fun i r -> (i, r)) sresp.Model.results)
      @ (match sresp.Model.notice with
        | Some notice -> [ ""; Printf.sprintf "notice: %s" notice ]
        | None -> [])
  | R_fetch fresp ->
      [ "seekwright fetch"; "================"; Printf.sprintf "url       %s" fresp.Model.url ]
      @ (if fresp.Model.requested_url <> fresp.Model.url then
           [ Printf.sprintf "requested %s" fresp.Model.requested_url ]
         else [])
      @ (match fresp.Model.title with Some title -> [ Printf.sprintf "title     %s" title ] | None -> [])
      @ (match fresp.Model.total_chars with
        | Some total ->
            [ Printf.sprintf "chars     %d%s" total (if fresp.Model.truncated then ", truncated" else "") ]
        | None -> [])
      @ (match fresp.Model.image with
        | Some image ->
            [
              Printf.sprintf "image     %s, %d bytes (base64 in --json)"
                (Option.value ~default:"" fresp.Model.content_type)
                image.Model.byte_count;
            ]
        | None -> [])
      @ (match fresp.Model.text with
        | Some text when text <> "" -> "" :: String.split_on_char '\n' text
        | _ -> [])
      @ (match fresp.Model.matches with
        | Some matches ->
            List.concat_map
              (fun (match_ : Model.fetch_match) ->
                [ ""; Printf.sprintf "match at %d:" match_.Model.offset ]
                @ String.split_on_char '\n' match_.Model.text)
              matches
        | None -> [])
      @ (match fresp.Model.notice with
        | Some notice -> [ ""; Printf.sprintf "notice: %s" notice ]
        | None -> [])
  | R_answer aresp ->
      [
        "seekwright answer";
        "==================";
        Printf.sprintf "query     %s" aresp.Model.query;
        Printf.sprintf "model     %s" aresp.Model.model;
        Printf.sprintf "depth     %s"
          (match aresp.Model.depth with Model.Brief -> "brief" | Model.Report -> "report");
        Printf.sprintf "searches  %d" aresp.Model.searches;
        Printf.sprintf "fetched   %d" aresp.Model.fetched;
      ]
      @ (match aresp.Model.truncated with
        | Some true -> [ "the answer stopped at the model's output cap and is cut short" ]
        | _ -> [])
      @ [ ""; aresp.Model.answer; "" ]
      @ (if aresp.Model.sources = [] then [ "sources   none cited" ]
         else
           Printf.sprintf "sources   %d" (List.length aresp.Model.sources)
           :: List.concat_map
                (fun (index, (source : Model.answer_source)) ->
                  [
                    Printf.sprintf "%d. %s" (index + 1) source.Model.source_title;
                    Printf.sprintf "   %s" source.Model.source_url;
                    Printf.sprintf "   via %s" source.Model.source_provider;
                  ])
                (List.mapi (fun i s -> (i, s)) aresp.Model.sources))
      @ (match aresp.Model.notice with
        | Some notice -> [ ""; Printf.sprintf "notice: %s" notice ]
        | None -> [])

(* {1 The verb run} *)

let decode verb text =
  let open Yojson.Safe in
  match verb with
  | Search -> (
      match Model.search_response_of_yojson (from_string text) with
      | Ok response -> Some (R_search response)
      | Error _ -> None)
  | Fetch -> (
      match Model.fetch_response_of_yojson (from_string text) with
      | Ok response -> Some (R_fetch response)
      | Error _ -> None)
  | Answer -> (
      match Model.answer_response_of_yojson (from_string text) with
      | Ok response -> Some (R_answer response)
      | Error _ -> None)

let model_name = function
  | Search -> "SearchResponse"
  | Fetch -> "FetchResponse"
  | Answer -> "AnswerResponse"

let route_of_verb = function Search -> "search" | Fetch -> "fetch" | Answer -> "answer"

(* [json] is the verb's own [--json] flag, read from the scan rather than passed
   in: the binary dispatches a verb and never spells one of its flags. *)
let run : post:post -> verb:verb -> argv:string list -> (string option, string * int) result =
 fun ~post ~verb ~argv ->
  match Cli_extract.scan_args argv with
  | Error sentence -> Error (sentence, 2)
  | Ok scanned -> (
      (* The request models are the validators: a body that fails validation
         is the Python's usage error, exit 2. *)
      let body_result : (Yojson.Safe.t, string) result =
        match verb with
        | Search -> Cli_extract.search_body scanned
        | Fetch -> Cli_extract.fetch_body scanned
        | Answer -> Cli_extract.answer_body scanned
      in
      match body_result with
      | Error sentence -> Error (sentence, 2)
      | Ok body ->
          let json = Cli_extract.flag_bool scanned "--json" in
          let server =
            match Cli_extract.flag_one scanned "--server" with
            | Some url -> strip_trailing_slash url
            | None -> "http://127.0.0.1:8000"
          in
          match post ~path:(server ^ "/api/v1/" ^ route_of_verb verb) (Yojson.Safe.to_string body) with
          | Error sentence -> Error (sentence, 1)
          | Ok (status, text) ->
              if status <> 200 then Error (error_message status text, 1)
              else if json then Ok (Some text)
              else (
                match decode verb text with
                | None -> Error ("the response is not a " ^ model_name verb, 1)
                | Some response -> Ok (Some (String.concat "\n" (human_lines response))))
      )
