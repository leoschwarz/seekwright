module Caps = Mcp_caps

type error =
  | Url_blocked of string
  | Rejected of string
  | Quota of string
  | Failed of string

type page = Seekwright_wire.Page.page

type net = {
  request :
    max_response_bytes:int option ->
    Caps.Authority.Net.request ->
    (Caps.Authority.Net.response, Caps.Error.t) result
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

module Json = struct
  let decode_object body =
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error _ -> Error (malformed ())
    | (`Assoc _ as value) -> Ok value
    | _ -> Error (malformed ())

  let field key = function
    | `Assoc members -> (try List.assoc key members with Not_found -> `Null)
    | _ -> `Null

  let string_field key value =
    match field key value with `String s -> Some s | _ -> None

  let int_field key value =
    match field key value with `Int n -> Some n | _ -> None

  let list_field key value =
    match field key value with `List items -> Some items | _ -> None

  let is_false = (( = ) (`Bool false))
end

let or_string a b =
  match a with
  | Some s when s <> "" -> Some s
  | _ -> (match b with Some s when s <> "" -> Some s | _ -> None)

let windowed text ~url ~max_text_chars ~offset ~max_chars ~title ~status_code =
  let window, truncated =
    Fetcher.window_text text ~offset ~max_chars:(Fetcher.resolved_cap max_text_chars max_chars)
  in
  { Seekwright_wire.Page.
    url;
    title;
    text = window;
    content_type = None;
    status_code;
    truncated;
    total_chars = Utf8.count text;
    path_addressable = false;
    image = None;
  }
