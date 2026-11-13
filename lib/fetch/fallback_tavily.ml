(* Tavily extract. fallback.mli owns what every remote fallback shares; this
   file is the extract endpoint's request shape, its three status arms, and
   the empty-[results] reading that keeps the walk going. *)

module Caps = Mcp_caps

let tavily_extract_endpoint = "https://api.tavily.com/extract"

type 'tag config = {
  net : Fallback.net;
  target : 'tag Remote_target.t;
  max_text_chars : int;
  api_key : string;
  timeout_seconds : float;
}

let to_page cfg target body ~offset ~max_chars =
  (* [results[]] holds one entry per URL that succeeded; an HTTP 200 with an
     empty [results] array is the vendor's way of saying every URL failed.
     That is *found nothing*, the same fact Jina's placeholder bodies mean,
     so the walk continues rather than the fallback failing. *)
  let entry =
    match Fallback.Json.list_field "results" body with
    | Some ((`Assoc _ as first) :: _) -> first
    | _ -> `Assoc []
  in
  let text =
    match Fallback.Json.string_field "raw_content" entry with Some s -> s | None -> ""
  in
  (* The entry's own landing URL when the vendor names one; this fallback
     sends one URL, so the array order does not matter. *)
  let url =
    match Fallback.Json.string_field "url" entry with Some s when s <> "" -> s | _ -> target
  in
  Ok
    (Fallback.windowed text ~url ~max_text_chars:cfg.max_text_chars ~offset ~max_chars
       (* Extract reports no title, and inventing one out of the markdown's
          first heading would be a guess the caller cannot tell from the
          page's own title. *)
       ~title:None ~status_code:200)

let fetch cfg raw ~offset ~max_chars =
  match Remote_target.check cfg.target raw with
  | Error message -> Error (Fallback.Url_blocked message)
  | Ok target -> (
      let body =
        Yojson.Safe.to_string
          (`Assoc
             [
               ("urls", `List [ `String target ]);
               (* The form the ladder wants; the vendor's other answer is
                  plain text. *)
               ("format", `String "markdown");
               (* [basic] for the reason the search adapter gives for
                  [search_depth]: the dearer depth doubles the credit. *)
               ("extract_depth", `String "basic");
               (* The vendor's own bound on the extraction, held inside its
                  1–60 s range; the client's bound is the grant's. *)
               ("timeout", `Float (Float.min 60.0 (Float.max 1.0 cfg.timeout_seconds)));
             ])
      in
      let request : Caps.Authority.Net.request = {
        meth = `POST;
        uri = Uri.of_string tavily_extract_endpoint;
        headers = [ ("Authorization", "Bearer " ^ cfg.api_key) ];
        body = Some body;
      } in
      match cfg.net.request ~max_response_bytes:None request with
      | Error caps_error -> Error (Fallback.transport_error caps_error)
      | Ok response -> (
          if response.Caps.Authority.Net.status = 401
          || response.Caps.Authority.Net.status = 403
          then
            Error (Fallback.Rejected "authentication rejected (check API key)")
            (* 432 is this vendor's monthly-credits-exhausted code and 429
               its short-term limit, the same reading the search adapter on
               this key takes. *)
          else if response.status = 429 || response.status = 432 then
            Error (Fallback.Quota "rate limited or out of credits")
          else if response.status >= 400 then
            Error (Fallback.Failed (Printf.sprintf "HTTP %d" response.status))
          else
            match Fallback.Json.decode_object response.Caps.Authority.Net.body with
            | Error error -> Error error
            | Ok body -> to_page cfg target body ~offset ~max_chars))
