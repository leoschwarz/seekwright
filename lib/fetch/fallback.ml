module Caps = Mcp_caps
module Utf8 = Seekwright_text.Utf8

type error = Url_blocked of string | Rejected of string | Quota of string | Failed of string

type page = Seekwright_wire.Page.page

type net = {
  request :
    max_response_bytes:int option ->
    Caps.Authority.Net.request ->
    (Caps.Authority.Net.response, Caps.Error.t) result;
}

let of_grant grant =
  {
    request =
      (fun ~max_response_bytes request ->
        Caps.Authority.Net.request ?max_response_bytes grant request);
  }

(* Timeout maps to "request timed out", all other grant errors to "network error". *)
let transport_error error =
  match Mcp_caps.Error.kind error with
  | Mcp_caps.Error.Timeout -> Failed "request timed out"
  | _ -> Failed "network error"

let malformed () = Failed "malformed JSON response"

(* Each vendor's own status reading, in the order it wants the codes tested: the codes
   it answers and the fact each one means. The [Failed "HTTP n"] catch-all is not a
   vendor fact — every reader refuses a 4xx or 5xx it has not named — so it lives here
   once, and a rule only supplies the sentence a named code earns. *)
type status_rule = (int list * error) list

let status_error (response : Caps.Authority.Net.response) rule =
  let status = response.Caps.Authority.Net.status in
  match List.find_opt (fun (codes, _) -> List.mem status codes) rule with
  | Some (_, error) -> Some error
  | None when status >= 400 -> Some (Failed (Printf.sprintf "HTTP %d" status))
  | None -> None

(* The ceiling is the grant's: every fallback reads a vendor API body, and none has a
   reason to raise what the deployment configured. *)
let send net request =
  match net.request ~max_response_bytes:None request with
  | Error caps_error -> Error (transport_error caps_error)
  | Ok response -> Ok response

module Json = struct
  let decode_object body =
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error _ -> Error (malformed ())
    | `Assoc _ as value -> Ok value
    | _ -> Error (malformed ())

  let field key = function
    | `Assoc members -> ( try List.assoc key members with Not_found -> `Null)
    | _ -> `Null

  let string_field key value = match field key value with `String s -> Some s | _ -> None

  let int_field key value = match field key value with `Int n -> Some n | _ -> None

  let list_field key value = match field key value with `List items -> Some items | _ -> None

  let is_false = ( = ) (`Bool false)
end

(* Send, classify, decode — the tail the JSON readers repeated. The body is parsed only
   for a response the rule accepted, so a vendor's HTML error page is answered with its
   status sentence and not with a JSON error. *)
let send_json net rule request =
  match send net request with
  | Error error -> Error error
  | Ok response -> (
      match status_error response rule with
      | Some error -> Error error
      | None -> Json.decode_object response.Caps.Authority.Net.body)

let or_string a b =
  match a with
  | Some s when s <> "" -> Some s
  | _ -> ( match b with Some s when s <> "" -> Some s | _ -> None)

let windowed text ~url ~max_text_chars ~offset ~max_chars ~title ~status_code =
  let window, truncated =
    Fetcher.window_text text ~offset ~max_chars:(Fetcher.resolved_cap max_text_chars max_chars)
  in
  {
    Seekwright_wire.Page.url;
    title;
    text = window;
    content_type = None;
    status_code;
    truncated;
    total_chars = Utf8.count text;
    path_addressable = false;
    image = None;
  }
