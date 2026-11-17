module Caps = Mcp_caps

let crawl4ai_crawl_path = "/crawl"

type config = {
  net : Fallback.net;
  check : Remote_target.check;
  max_text_chars : int;
  base_url : string;
  token : string option;
}

(* The operator's own service refusing the token this deployment configured is a
   different fix than a vendor key, so the sentence names the key. *)
let rule : Fallback.status_rule =
  [ ([ 401; 403 ], Fallback.Rejected "authentication rejected (check fetch.crawl4ai_token)") ]

(* Built per request rather than parked on the client: a credential that only
   exists at the call site cannot ride along on any other request this client
   makes — and an empty token is no token ([if self._token:]). *)
let headers token =
  match token with Some t when t <> "" -> [ ("Authorization", "Bearer " ^ t) ] | _ -> []

let to_page cfg target body ~offset ~max_chars =
  (* The envelope's [success] is the service's: false means the crawl never
     ran. [results] then carries the crawl's own per-URL outcome. *)
  if Fallback.Json.is_false (Fallback.Json.field "success" body) then
    Error (Fallback.Failed "crawler reported failure")
  else
    match Fallback.Json.list_field "results" body with
    | None | Some [] -> Error (Fallback.malformed ())
    | Some (first :: _) -> (
        match first with
        | `Assoc _ as result ->
            if Fallback.Json.is_false (Fallback.Json.field "success" result) then
              (* The renderer's own reason when it has one; the bare sentence
                 when it does not. *)
              let message = Fallback.Json.string_field "error_message" result in
              match message with
              | Some m when m <> "" -> Error (Fallback.Failed m)
              | _ -> Error (Fallback.Failed "crawl failed")
            else
              (* [status_code] is the origin's, on the Scrappa rule: an error
                 page rendered successfully is still a failed fetch. *)
              let status_code =
                match Fallback.Json.int_field "status_code" result with Some n -> n | None -> 200
              in
              if status_code >= 400 then
                Error (Fallback.Failed (Printf.sprintf "HTTP %d" status_code))
              else
                (* Older server lines sent [markdown] as a string, newer ones
                   a result dict: accept both, prefer [raw_markdown]. *)
                let text =
                  match Fallback.Json.field "markdown" result with
                  | `Assoc _ as markdown -> (
                      match Fallback.Json.string_field "raw_markdown" markdown with
                      | Some s -> s
                      | None -> "")
                  | `String s -> s
                  | _ -> ""
                in
                let metadata = Fallback.Json.field "metadata" result in
                let title =
                  match Fallback.Json.string_field "title" metadata with
                  | Some s when s <> "" -> Some s
                  | _ -> None
                in
                let url =
                  match
                    Fallback.or_string
                      (Fallback.Json.string_field "redirected_url" result)
                      (Fallback.Json.string_field "url" result)
                  with
                  | Some s -> s
                  | None -> target
                in
                Ok
                  (Fallback.windowed text ~url ~max_text_chars:cfg.max_text_chars ~offset ~max_chars
                     ~title ~status_code)
        | _ -> Error (Fallback.malformed ()))

(* The oracle's [__init__] right-strips the base URL, so the crawl path
   concatenates without a doubled slash whatever the operator wrote. *)
let rstrip_slashes url =
  let n = String.length url in
  if n > 0 && url.[n - 1] = '/' then (
    let last = ref n in
    while !last > 0 && url.[!last - 1] = '/' do
      decr last
    done;
    String.sub url 0 !last)
  else url

let fetch cfg raw ~offset ~max_chars =
  match cfg.check raw with
  | Error message -> Error (Fallback.Url_blocked message)
  | Ok target -> (
      let uri = Uri.of_string (rstrip_slashes cfg.base_url ^ crawl4ai_crawl_path) in
      let body =
        Yojson.Safe.to_string
          (`Assoc
             [
               ("urls", `List [ `String target ]);
               ("browser_config", `Assoc []);
               ("crawler_config", `Assoc []);
             ])
      in
      let request : Caps.Authority.Net.request =
        { meth = `POST; uri; headers = headers cfg.token; body = Some body }
      in
      match Fallback.send_json cfg.net rule request with
      | Error error -> Error error
      | Ok body -> to_page cfg target body ~offset ~max_chars)
