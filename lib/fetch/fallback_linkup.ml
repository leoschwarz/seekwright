module Caps = Mcp_caps

let linkup_fetch_endpoint = "https://api.linkup.so/v1/fetch"

type config = {
  net : Fallback.net;
  check : Remote_target.check;
  max_text_chars : int;
  api_key : string;
}

(* A spent account and a burst share 429 here, as the search adapter on this key reads
   it; Linkup's 402 belongs to the keyless x402 lane this tree never enters. *)
let rule : Fallback.status_rule =
  [
    ([ 401; 403 ], Fallback.Rejected "authentication rejected (check API key)");
    ([ 429 ], Fallback.Quota "rate limited or out of credits");
  ]

let to_page cfg target body ~offset ~max_chars =
  (* [markdown] is the field the service always returns, and an empty one is
     a page it could not read — the near-empty class [fetch.min_text_chars]
     refuses, so the walk goes on to the next fallback. *)
  let text = match Fallback.Json.string_field "markdown" body with Some s -> s | None -> "" in
  Ok
    (Fallback.windowed text ~url:target ~max_text_chars:cfg.max_text_chars ~offset
       ~max_chars
         (* The payload carries no page title: [favicon], [contentType] and the
          typed [data] are the other fields, and none of them is a title. *)
       ~title:None ~status_code:200)

let fetch cfg raw ~offset ~max_chars =
  match cfg.check raw with
  | Error message -> Error (Fallback.Url_blocked message)
  | Ok target -> (
      let body =
        Yojson.Safe.to_string
          (`Assoc
             [
               ("url", `String target);
               (* [renderJs] sent [true] rather than left at the vendor's
                  default, because a fallback that does not render is a worse
                  local reader. *)
               ("renderJs", `Bool true);
               (* [standard]: [pro] is a price cliff. *)
               ("mode", `String "standard");
               (* Sent [false] so a vendor-side default change cannot buy
                  bytes this ladder has no path for. *)
               ("extractImages", `Bool false);
               ("includeRawHtml", `Bool false);
               ("includeRawContent", `Bool false);
             ])
      in
      let request : Caps.Authority.Net.request =
        {
          meth = `POST;
          uri = Uri.of_string linkup_fetch_endpoint;
          headers = [ ("Authorization", "Bearer " ^ cfg.api_key) ];
          body = Some body;
        }
      in
      match Fallback.send_json cfg.net rule request with
      | Error error -> Error error
      | Ok body -> to_page cfg target body ~offset ~max_chars)
