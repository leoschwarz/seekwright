module Caps = Mcp_caps

let scrappa_scraper_endpoint = "https://scrappa.co/api/web-scraper"

type config = {
  net : Fallback.net;
  check : Remote_target.check;
  max_text_chars : int;
  api_key : string;
}

(* 401/403 is the key; 402 and 429 are the credit line and the burst, read the same
   way, because this vendor bills by scrape. *)
let rule : Fallback.status_rule =
  [
    ([ 401; 403 ], Fallback.Rejected "authentication rejected (check API key)");
    ([ 402; 429 ], Fallback.Quota "rate limited or out of credits");
  ]

let to_page cfg target body ~offset ~max_chars =
  (* [site_status_code] is the {i origin's} status, distinct from Scrappa's
     own — a 404 page scraped successfully is a successful API call and a
     failed fetch, and the same rule as the local reader's applies: an error
     page's body is not content. *)
  if Fallback.Json.is_false (Fallback.Json.field "success" body) then
    Error (Fallback.Failed "scraper reported failure")
  else
    let status_code =
      match Fallback.Json.int_field "site_status_code" body with Some n -> n | None -> 200
    in
    if status_code >= 400 then Error (Fallback.Failed (Printf.sprintf "HTTP %d" status_code))
    else
      let data = Fallback.Json.field "data" body in
      let title =
        match Fallback.Json.string_field "title" data with
        | Some s when s <> "" -> Some s
        | _ -> None
      in
      let text =
        match Fallback.Json.string_field "body_text" data with Some s -> s | None -> ""
      in
      let url =
        match
          Fallback.or_string
            (Fallback.Json.string_field "final_url" body)
            (Fallback.Json.string_field "url" body)
        with
        | Some s -> s
        | None -> target
      in
      Ok
        (Fallback.windowed text ~url ~max_text_chars:cfg.max_text_chars ~offset ~max_chars ~title
           ~status_code)

let fetch cfg raw ~offset ~max_chars =
  match cfg.check raw with
  | Error message -> Error (Fallback.Url_blocked message)
  | Ok target -> (
      let uri =
        Uri.add_query_params'
          (Uri.of_string scrappa_scraper_endpoint)
          [ ("url", target); ("javascript", "1"); ("include_html", "0") ]
      in
      let request : Caps.Authority.Net.request =
        { meth = `GET; uri; headers = [ ("x-api-key", cfg.api_key) ]; body = None }
      in
      match Fallback.send_json cfg.net rule request with
      | Error error -> Error error
      | Ok body -> to_page cfg target body ~offset ~max_chars)
