(* The shared half of a remote fetch fallback. fallback.mli states the shape;
   this file is only what the five vendors cannot each own for themselves: the
   transport rows, the envelope guards, and the windowing every [_to_page]
   ends with. *)

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
(** A record field cannot carry an optional argument, so the seam takes
    [max_response_bytes] explicitly; production passes it through to the
    grant, and a fallback passes [None] unless it has a reason to lower the
    grant's byte ceiling. *)

let of_grant grant =
  {
    request =
      (fun ~max_response_bytes request ->
        Caps.Authority.Net.request ?max_response_bytes grant request);
  }

(* The two httpx rows. [Timeout] is the grant's whole-operation bound firing;
   anything else the grant answers with — a refused connection, a name that
   did not resolve, a TLS handshake that failed — is the [HTTPError] row,
   because the contract has no finer wording and the grant's message may name
   the peer. *)
let transport_error error =
  match Mcp_caps.Error.kind error with
  | Mcp_caps.Error.Timeout -> Failed "request timed out"
  | _ -> Failed "network error"

let malformed () = Failed "malformed JSON response"

module Json = struct
  (* [Yojson.Safe.from_string] raises [Json_error] on a non-JSON body and
     happily accepts a bare scalar; both are the same wire failure, and the
     [Json_error] value is dropped rather than quoted — it can echo a slice
     of the body. *)
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
    (* Python's [isinstance(status, int)]: a JSON float in a status field is
       not a status, it is drift, and drift drops the field. *)
    match field key value with `Int n -> Some n | _ -> None

  let list_field key value =
    match field key value with `List items -> Some items | _ -> None

  let is_false = (( = ) (`Bool false))
end

(* The field names [field]/[string_field]/… shadow the record labels only
   inside this module; callers spell [Json.field]. *)

let windowed text ~url ~max_text_chars ~offset ~max_chars ~title ~status_code =
  let window, truncated =
    Fetcher.window_text text ~offset ~max_chars:(Fetcher.resolved_cap max_text_chars max_chars)
  in
  { Seekwright_wire.Page.
    url;
    title;
    text = window;
    (* A vendor returns markdown or prose, never a media type for the page;
       claiming [text/html] would be a guess, and the field is surfaced, never
       dispatched on. *)
    content_type = None;
    status_code;
    truncated;
    (* Python's [len(text)] — a codepoint count, like every offset this path
       carries. [String.length] would make [total_chars] disagree with the
       offsets [window_text] reports as soon as the page is not ASCII. *)
    total_chars = Utf8.count text;
    (* The envelope is parsed here and never leaves, so a [path] handed to
       this route could only select inside the vendor's response, not inside
       the page the caller named. *)
    path_addressable = false;
    image = None;
  }
