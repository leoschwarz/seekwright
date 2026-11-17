(* See the interface. The split between this library and {!Test_support} is the
   link closure: nothing here is usable without the server, and the [mcp-caps]
   suites must not need the server to get a substring search. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider

let test_key = "test-key"

let query ?(text = "q") ?(max_results = 5) ?(include_domains = []) ?(exclude_domains = []) ?country
    ?language ?recency ?safe_search () : Model.search_query =
  {
    Model.query = text;
    max_results;
    include_domains;
    exclude_domains;
    country;
    language;
    recency;
    safe_search;
  }

let response ~status ~body = { Caps.Authority.Net.status; headers = []; body }

type egress = {
  mutable one : Caps.Authority.Net.request option;
  mutable many : Caps.Authority.Net.request list;
}

let net egress handler =
  ({
     Provider.Net.request =
       (fun request ->
         egress.one <- Some request;
         egress.many <- request :: egress.many;
         handler request);
   }
    : Provider.Net.t)

let recording handler =
  let egress = { one = None; many = [] } in
  (net egress handler, fun () -> List.rev egress.many)

let answered ~status ~body =
  let egress = { one = None; many = [] } in
  ( net egress (fun _ -> Ok (response ~status ~body)),
    fun () ->
      match egress.one with
      | Some request -> request
      | None -> Alcotest.failf "the adapter dialed nothing" )

let refusing kind ~message =
  net { one = None; many = [] } (fun _ -> Error (Caps.Error.make kind ~message))

let ok_search adapter q =
  match Provider.search adapter q with
  | Ok outcome -> outcome
  | Error failure -> Alcotest.failf "the search failed: %s" (Provider.render_error failure)

let drive adapter sent q =
  (* The order is the point: a tuple's components are evaluated right-to-left,
     so writing [(ok_search adapter q, sent ())] reads the egress before the
     search has dialed anything. *)
  let outcome = ok_search adapter q in
  (outcome, sent ())

let json_object text =
  match Yojson.Safe.from_string text with
  | `Assoc _ as json -> json
  | _ -> Alcotest.failf "the fixture is not an object"

let body_of (request : Caps.Authority.Net.request) =
  match request.Caps.Authority.Net.body with
  | Some text -> Yojson.Safe.from_string text
  | None -> Alcotest.failf "the request carried no body"

let body_field name (request : Caps.Authority.Net.request) =
  match Provider.Json.field name (body_of request) with
  | `String value -> Some value
  | `Int value -> Some (string_of_int value)
  | `Null -> None
  | other -> Some (Yojson.Safe.to_string other)

let has_body_field name (request : Caps.Authority.Net.request) =
  match Provider.Json.members (body_of request) with
  | Some fields -> List.mem_assoc name fields
  | None -> false

let params (request : Caps.Authority.Net.request) = Uri.query request.Caps.Authority.Net.uri

let param (request : Caps.Authority.Net.request) name =
  Uri.get_query_param request.Caps.Authority.Net.uri name

let has_param (request : Caps.Authority.Net.request) name =
  List.exists (fun (key, _) -> key = name) (params request)
