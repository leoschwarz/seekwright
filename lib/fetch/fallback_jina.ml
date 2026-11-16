module Caps = Mcp_caps

let jina_reader_endpoint = "https://r.jina.ai/"

(* The reader's [text/plain] body is [Key: value] lines, one literal
   [Markdown Content:] line, and the page. The marker test lowercases the
   text before the first colon, so the comparison value is that line
   lowercased — [JINA_CONTENT_MARKER] in the oracle. *)
let content_marker = "markdown content"

(* [partition ":"], the Python method: the separator is dropped and a line
   without one is the whole line with an empty value. *)
let partition line =
  match String.index_opt line ':' with
  | Some i -> (String.sub line 0 i, String.sub line (i + 1) (String.length line - i - 1))
  | None -> (line, "")

let lower_strip = function
  | "" -> ""
  | s -> Utf8.to_string (Utf8.ascii_lower (Utf8.of_string s))

let split_reader_body body =
  let lines = List.map Utf8.to_string (Utf8.splitlines (Utf8.of_string body)) in
  let marker =
    let rec go index = function
      | [] -> None
      | line :: rest ->
          let name, value = partition line in
          if lower_strip (Utf8.strip name) = content_marker
          then Some (index, value)
          else go (index + 1) rest
    in
    go 0 lines
  in
  match marker with
  | None ->
      (* No marker: the whole body is the page, headers empty — a service
         answering with unlabeled markdown is still a usable read. *)
      ([], body)
  | Some (index, value) ->
      let before, after =
        let rec go n acc = function
          | [] -> (List.rev acc, [])
          | x :: tl -> if n = 0 then (List.rev acc, x :: tl) else go (n - 1) (x :: acc) tl
        in
        (* Headers come from the lines above the marker; the page starts at
           [index + 1], because the marker line itself is dropped and only its
           tail becomes the page's first line. *)
        match go index [] lines with
        | before, _marker :: rest -> (before, rest)
        | before, [] -> (before, [])
      in
      let headers =
        List.filter_map
          (fun line ->
            (* Only lines that carry a separator are headers at all. *)
            if String.exists (fun c -> c = ':') line then
              let key, value = partition line in
              Some (lower_strip (Utf8.strip key), Utf8.strip value)
            else None)
          before
      in
      (* Anything after the marker on its own line is the page's first line,
         not a header; a blank remainder contributes no line. *)
      let first =
        let v = Utf8.strip value in
        if v = "" then [] else [ v ]
      in
      (headers, String.concat "\n" (first @ after))

type 'tag config = {
  net : Fallback.net;
  target : 'tag Remote_target.t;
  max_text_chars : int;
  user_agent : string;
}

let fetch cfg raw ~offset ~max_chars =
  match Remote_target.check cfg.target raw with
  | Error message -> Error (Fallback.Url_blocked message)
  | Ok target -> (
      (* The endpoint and the target concatenate as plain text in the oracle;
         parsing the result is what keeps the grant's [uri] a [Uri.t] without
         re-encoding the target the caller wrote. *)
      let uri = Uri.of_string (jina_reader_endpoint ^ target) in
      let request : Caps.Authority.Net.request = {
        meth = `GET;
        uri;
        headers = [ ("Accept", "text/markdown"); ("User-Agent", cfg.user_agent) ];
        body = None;
      } in
      match cfg.net.request ~max_response_bytes:None request with
      | Error caps_error -> Error (Fallback.transport_error caps_error)
      | Ok response -> (
          (* Free, but metered by IP: a burst shares one window with every
             other caller behind this address. *)
          if response.Caps.Authority.Net.status = 402 || response.Caps.Authority.Net.status = 429
          then
            Error (Fallback.Quota "rate limited")
            (* 401/403 included, and not read as an auth failure: this
               fallback sends no credential, so a rejection is the service
               refusing this address or target. *)
          else if response.status >= 400 then
            Error (Fallback.Failed (Printf.sprintf "HTTP %d" response.status))
          else
            let header_block, text = split_reader_body response.body in
            (* The two placeholder bodies the service returns when it has
               no page for us are read as *found nothing* — the same fact
               an extraction under [fetch.min_text_chars] means, which is
               what lets the next fallback fire. They are a statement
               about the read, not a length, and the title survives. *)
            let stripped = Utf8.strip text in
            let text =
              if
                String.starts_with ~prefix:"Loading..." stripped
                || String.starts_with ~prefix:"Please enable JavaScript" stripped
              then
                ""
              else text
            in
            let find key = List.assoc_opt key header_block in
            (* Python's [source or url] and [title or None]: an empty string
               from the reader is no value at all. *)
            let source =
              match find "url source" with Some s when s <> "" -> s | _ -> target
            in
            let title =
              match find "title" with Some t when t <> "" -> Some t | _ -> None
            in
            Ok
              (Fallback.windowed text ~url:source ~max_text_chars:cfg.max_text_chars ~offset
                 ~max_chars ~title ~status_code:200))
          )
