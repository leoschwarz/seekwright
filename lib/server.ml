(* The MCP server: three tools, both transports, and the HTTP custom routes.
   Port of [src/seekwright/server.py]. See [server.mli] for the shape; the
   notes below are the port-specific decisions.

   The tools are declared through the capability layer and registered with the
   app as their grant: the app carries the engines, and the engines hold the
   endpoint-scoped [Net] grants the factory gave each provider adapter, so the
   registration line is where "which tool may reach what" is read. Providers
   themselves are never registered as tools.

   Per-parameter [description] prose from the Python tool signatures is not
   reproduced: prose is not part of the frozen surface (AGENTS.md), and the
   tool-level descriptions — the model-facing copy that matters — are carried
   verbatim from [Prompts]. The parameter names, order, types and constraints
   are the contract and are built from the same tables {!tools_surface}
   exposes, so [ocaml-tools/surface.ml] prints what the wire carries.

   Over MCP, failures travel through [Mcp_caps.Error] and arrive as a tool
   result with [isError] and the kind-prefixed sentence; over REST the same
   sentence goes back bare in [{error: message}] with the 400/502/404/421
   split the projection owns. *)

module Caps = Mcp_caps
module Error = Caps.Error
module Registry = Caps.Registry
module Server = Caps.Server
module Tool = Caps.Tool

let ( >>= ) = Result.bind

(* {1 Schemas} *)

let obj ?(additional = true) properties required =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("required", `List (List.map (fun name -> `String name) required));
      ("additionalProperties", `Bool (not additional));
    ]

let str ?min ?max () =
  let bounds =
    (match min with Some n -> [("minLength", `Int n)] | None -> [])
    @ (match max with Some n -> [("maxLength", `Int n)] | None -> [])
  in
  `Assoc (("type", `String "string") :: bounds)

let int ?min ?max ?default () =
  let bounds =
    (match min with Some n -> [("minimum", `Int n)] | None -> [])
    @ (match max with Some n -> [("maximum", `Int n)] | None -> [])
    @ (match default with Some n -> [("default", `Int n)] | None -> [])
  in
  `Assoc (("type", `String "integer") :: bounds)

let bool ?default () =
  `Assoc
    (("type", `String "boolean")
    :: (match default with Some b -> [("default", `Bool b)] | None -> []))

let enum values =
  `Assoc
    [
      ("type", `String "string");
      ("enum", `List (List.map (fun v -> `String v) values));
    ]

let string_list ?max_items () =
  `Assoc
    [
      ("type", `String "array");
      ("items", str ());
      (match max_items with
      | Some n -> ("maxItems", `Int n)
      | None -> ("maxItems", `Int 20));
    ]

let provider_enum = enum Config.known_providers
let recency_enum = enum [ "day"; "week"; "month"; "year" ]

(* The parameter tables, in the frozen declaration order. Each entry is the
   name plus the property schema the wire carries; [tools_surface] reads the
   names off these tables, so the manifest and the schema cannot drift. *)
let search_properties =
  [
    ("query", str ~min:2 ~max:400 ());
    ("provider", provider_enum);
    ("mode", enum [ "free" ]);
    ("max_results", int ~min:1 ~max:20 ~default:5 ());
    ("include_domains", string_list ~max_items:20 ());
    ("exclude_domains", string_list ~max_items:20 ());
    ("recency", recency_enum);
    ("language", str ~min:2 ~max:2 ());
    ("safe_search", bool ());
  ]

let fetch_properties =
  [
    ("url", str ~min:8 ~max:2048 ());
    ("offset", int ~min:0 ());
    ("query", str ~min:2 ~max:400 ());
    ("path", str ~min:1 ~max:400 ());
    ("provider", str ());
    ("structure", bool ~default:false ());
  ]

let answer_properties =
  [
    ("query", str ~min:2 ~max:400 ());
    ( "extra_queries",
      `Assoc
        [
          ("type", `String "array");
          ("items", str ~min:2 ~max:400 ());
          ("maxItems", `Int 2);
        ] );
    ("depth", enum [ "brief"; "report" ]);
    ("provider", provider_enum);
    ("include_domains", string_list ~max_items:20 ());
    ("exclude_domains", string_list ~max_items:20 ());
    ("recency", recency_enum);
    ("language", str ~min:2 ~max:2 ());
    ("safe_search", bool ());
  ]

(* The response schemas: the wire models as objects. Only the fields the
   encoders always emit are [required]; an absent optional field is omitted,
   never null, so the schema never contradicts the encoder. *)
let result_schema =
  obj
    ~additional:false
    [
      ("title", str ());
      ("url", str ());
      ("snippet", str ());
      ("text", str ());
      ("text_truncated", bool ());
      ("published_date", str ());
      ("score", `Assoc [("type", `String "number")]);
    ]
    [ "title"; "url" ]

let search_response_schema =
  obj
    ~additional:false
    [
      ("query", str ());
      ("provider", str ());
      ("results", `Assoc [("type", `String "array"); ("items", result_schema)]);
      ("answer", str ());
      ("retrieved_at", str ());
      ("notice", str ());
    ]
    [ "query"; "provider"; "results" ]

let fetch_response_schema =
  obj
    ~additional:false
    [
      ("url", str ());
      ("requested_url", str ());
      ("title", str ());
      ("text", str ());
      ("content_type", str ());
      ("status_code", int ());
      ("retrieved_at", str ());
      ("truncated", bool ());
      ("total_chars", int ());
      ("offset", int ());
      ( "matches",
        `Assoc
          [
            ("type", `String "array");
            ( "items",
              obj ~additional:false
                [("offset", int ()); ("text", str ())]
                [ "offset"; "text" ] );
          ] );
      ( "image",
        obj ~additional:false
          [("byte_count", int ()); ("base64", str ())]
          [ "byte_count"; "base64" ] );
      ("notice", str ());
    ]
    [ "url"; "requested_url"; "truncated" ]

let answer_response_schema =
  obj
    ~additional:false
    [
      ("query", str ());
      ("answer", str ());
      ( "sources",
        `Assoc
          [
            ("type", `String "array");
            ( "items",
              obj ~additional:false
                [("title", str ()); ("url", str ()); ("provider", str ())]
                [ "title"; "url"; "provider" ] );
          ] );
      ("model", str ());
      ("depth", enum [ "brief"; "report" ]);
      ("searches", int ());
      ("fetched", int ());
      ("retrieved_at", str ());
      ("truncated", bool ());
      ("notice", str ());
    ]
    [ "query"; "answer"; "sources"; "model"; "depth"; "searches"; "fetched" ]

(* {1 The tools} *)

type health = {
  board : Health.t;
  built : Config.name list;
  probes : (Config.name * Health.probe_spec) list;
  net : Provider.Net.t;
}

type app = {
  config : Config.t;
  search : Engine.Search.t;
  usage : Usage.t;
  fetch : Engine.Fetch.t option;
  agent : Agent.t option;
  started_at : float;
  mono_now : unit -> float;
  allowed_hosts : string list;
  health : health option;
}

let fetch_disabled =
  "This server has the fetch tool disabled; use `search` instead."

let agent_disabled =
  "This server has agent mode disabled; use `search` or `fetch` instead."

let mode_of (mode : Model.mode option) : Router.search_mode option =
  match mode with None -> None | Some Model.Free -> Some Router.Free

let search_query_of (req : Model.search_request) : Model.search_query =
  {
    Model.query = req.Model.query;
    max_results = req.Model.max_results;
    include_domains = Option.value ~default:[] req.Model.include_domains;
    exclude_domains = Option.value ~default:[] req.Model.exclude_domains;
    country = None;
    language = req.Model.language;
    recency = req.Model.recency;
    safe_search = req.Model.safe_search;
  }

let output_of json = Tool.Output.text ~structured_content:json (Yojson.Safe.pretty_to_string json)

let search_tool =
  Tool.make
    ~title:"Web Search"
    ~description:Prompts.search_description
    ~output_schema:search_response_schema
    ~input_schema:(obj ~additional:false search_properties [ "query" ])
    ~decode:Model.search_request_of_yojson
    ~run:(fun app req ->
      match
        Engine.Search.search app.search
          ?provider:req.Model.provider
          ?mode:(mode_of req.Model.mode)
          (search_query_of req)
      with
      | Ok response -> Ok (output_of (Model.search_response_to_yojson response))
      | Error (Engine.Search.Refused message) ->
          Error (Error.make Error.Invalid ~message)
      | Error (Engine.Search.Failed message) ->
          Error (Error.make Error.Failed ~message))
    "search"

let fetch_tool =
  Tool.make
    ~title:"Fetch Page Text"
    ~description:Prompts.fetch_description
    ~output_schema:fetch_response_schema
    ~input_schema:(obj ~additional:false fetch_properties [ "url" ])
    ~decode:Model.fetch_request_of_yojson
    ~run:(fun app req ->
      match app.fetch with
      | None -> Error (Error.make Error.Invalid ~message:fetch_disabled)
      | Some engine -> (
          match
            Engine.Fetch.fetch engine
              ?offset:req.Model.offset
              ?query:req.Model.query
              ?path:req.Model.path
              ~structure:req.Model.structure
              ?provider:req.Model.provider
              req.Model.url
          with
          | Ok response ->
              (* The caps layer's [Tool.Output] has no image block (a declared
                 v1 gap), so an image answer rides inside the JSON projection,
                 exactly as the REST route carries it. *)
              Ok (output_of (Model.fetch_response_to_yojson response))
          | Error (Engine.Fetch.Refused message) ->
              Error (Error.make Error.Invalid ~message)
          | Error (Engine.Fetch.Failed message) ->
              Error (Error.make Error.Failed ~message)))
    "fetch"

let answer_tool =
  Tool.make
    ~title:"Answer a Question"
    ~description:Prompts.answer_description
    ~output_schema:answer_response_schema
    ~input_schema:(obj ~additional:false answer_properties [ "query" ])
    ~decode:Model.answer_request_of_yojson
    ~run:(fun app req ->
      match app.agent with
      | None -> Error (Error.make Error.Invalid ~message:agent_disabled)
      | Some agent -> (
          match
            Agent.answer agent
              ~query:req.Model.query
              ?extra_queries:req.Model.extra_queries
              ?depth:req.Model.depth
              ?provider:req.Model.provider
              ?include_domains:req.Model.include_domains
              ?exclude_domains:req.Model.exclude_domains
              ?recency:req.Model.recency
              ?language:req.Model.language
              ?safe_search:req.Model.safe_search
              ()
          with
          | Ok response -> Ok (output_of (Model.answer_response_to_yojson response))
          | Error message -> Error (Error.make Error.Failed ~message)))
    "answer"

let registry app =
  Registry.add Registry.empty search_tool ~grant:app
  >>= (fun registry -> Registry.add registry fetch_tool ~grant:app)
  >>= (fun registry -> Registry.add registry answer_tool ~grant:app)

let mcp_server app =
  registry app
  |> Result.map_error (fun (Registry.Duplicate_tool name) -> Server.Duplicate_tool name)
  >>= Server.of_registry ~name:"seekwright" ~version:"0.1.0"

(* {1 The Host guard} *)

let loopback = [ "localhost"; "127.0.0.1"; "::1" ]

let host_allowlist extra =
  let seed =
    loopback @ List.map (fun h -> h ^ ":*") loopback @ [ "[::1]:*" ]
  in
  seed @ extra

let is_host_allowed entries host =
  let host = String.lowercase_ascii host in
  List.exists
    (fun entry ->
      let entry = String.lowercase_ascii entry in
      if entry = host then true
      else if
        String.length entry > 2
        && String.sub entry (String.length entry - 2) 2 = ":*"
      then
        let prefix = String.sub entry 0 (String.length entry - 2) in
        let n = String.length prefix in
        host = prefix
        || (String.length host > n
           && String.sub host 0 n = prefix
           && host.[n] = ':' )
      else false)
    entries

let origin_allowlist extra =
  List.concat_map
    (fun host -> [ "http://" ^ host; "https://" ^ host ])
    (loopback @ extra)

(* The one Host decision both layers use. [/healthz] is outside the allowlist —
   a kubelet probes with the pod IP in [Host] — and a missing [Host] is refused
   like an unlisted one. *)
let host_gate app ~path ~host =
  path = "/healthz"
  ||
  match host with
  | Some h -> is_host_allowed (host_allowlist app.allowed_hosts) h
  | None -> false

(* {1 The custom routes} *)

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

let json_content = [ ("content-type", "application/json") ]
let text_content = [ ("content-type", "text/plain; charset=utf-8") ]
let html_content = [ ("content-type", "text/html; charset=utf-8") ]

let json_response status json =
  { status; headers = json_content; body = Yojson.Safe.to_string json }

let error_response status message =
  json_response status (`Assoc [ ("error", `String message) ])

let text_response status body = { status; headers = text_content; body }

let max_body_size = 1_048_576

let parse_json_body body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message -> Error ("Body is not valid JSON: " ^ message)
  | `Assoc _ as json -> Ok json
  | _ -> Error "Body must be a JSON object."

(* The oracle's stopping sentences: [{"status": "stopping"}] for the three
   operational GETs, and the REST surface's error shape for a projection call
   that arrived while the listener was draining. Both are content-free. *)
let stopping_message = "The server is stopping; retry shortly."

let stopping_response () =
  json_response 503 (`Assoc [ ("status", `String "stopping") ])

let stopping_error () = error_response 503 stopping_message

let healthz app ~stopping =
  if stopping then stopping_response ()
  else
    let built = Engine.Search.providers app.search in
    json_response 200
      (`Assoc
         [
           ("status", `String "ok");
           (* The dispatchable set — the engine's built registry, the one set
              every route resolves against — not the configured one: a name
              this build has no adapter for either refused startup
              ([Seekwright_factory.startup_verdict]) or was skipped by name
              under the implicit keyless default. [/healthz] answers what
              serves searches, never what a file asked for. *)
           ("providers", `List (List.map (fun name -> `String name) built));
           ( "default_provider",
             (match app.config.Config.default_provider with
             | Some name when List.mem name built -> `String name
             | _ -> `Null) );
           ( "uptime_s",
             `Int (int_of_float (app.mono_now () -. app.started_at)) );
         ])

let api_search app ~stopping body =
  if stopping then stopping_error ()
  else
  match parse_json_body body with
  | Error message -> error_response 400 message
  | Ok json -> (
      match Model.search_request_of_yojson json with
      | Error message -> error_response 400 ("Invalid request: " ^ message ^ ".")
      | Ok req -> (
          match
            Engine.Search.search app.search
              ?provider:req.Model.provider
              ?mode:(mode_of req.Model.mode)
              (search_query_of req)
          with
          | Ok response -> json_response 200 (Model.search_response_to_yojson response)
          | Error (Engine.Search.Refused message) -> error_response 400 message
          | Error (Engine.Search.Failed message) -> error_response 502 message))

let api_fetch app ~stopping body =
  if stopping then stopping_error ()
  else
  match app.fetch with
  | None -> error_response 404 fetch_disabled
  | Some engine -> (
      match parse_json_body body with
      | Error message -> error_response 400 message
      | Ok json -> (
          match Model.fetch_request_of_yojson json with
          | Error message -> error_response 400 ("Invalid request: " ^ message ^ ".")
          | Ok req -> (
              match
                Engine.Fetch.fetch engine
                  ?offset:req.Model.offset
                  ?query:req.Model.query
                  ?path:req.Model.path
                  ~structure:req.Model.structure
                  ?provider:req.Model.provider
                  req.Model.url
              with
              | Ok response ->
                  json_response 200 (Model.fetch_response_to_yojson response)
              | Error (Engine.Fetch.Refused message) -> error_response 400 message
              | Error (Engine.Fetch.Failed message) -> error_response 502 message)))

let api_answer app ~stopping body =
  if stopping then stopping_error ()
  else
  match app.agent with
  | None -> error_response 404 agent_disabled
  | Some agent -> (
      match parse_json_body body with
      | Error message -> error_response 400 message
      | Ok json -> (
          match Model.answer_request_of_yojson json with
          | Error message -> error_response 400 ("Invalid request: " ^ message ^ ".")
          | Ok req -> (
              (* The provider pin is refused before any dispatch, as the 400
                 the request deserves — the walk would swallow it. *)
              match Engine.Search.resolve app.search req.Model.provider with
              | Error message -> error_response 400 message
              | Ok _ -> (
                  match
                    Agent.answer agent
                      ~query:req.Model.query
                      ?extra_queries:req.Model.extra_queries
                      ?depth:req.Model.depth
                      ?provider:req.Model.provider
                      ?include_domains:req.Model.include_domains
                      ?exclude_domains:req.Model.exclude_domains
                      ?recency:req.Model.recency
                      ?language:req.Model.language
                      ?safe_search:req.Model.safe_search
                      ()
                  with
                  | Ok response ->
                      json_response 200 (Model.answer_response_to_yojson response)
                  | Error message -> error_response 502 message))))

let dashboard_enabled app = app.config.Config.dashboard.Config.enabled

let dashboard_data app = json_response 200 (Usage.snapshot app.usage)

let dashboard_metrics app =
  match Usage.snapshot app.usage with
  | `Assoc fields -> (
      match List.assoc_opt "endpoints" fields with
      | Some endpoints -> json_response 200 endpoints
      | None -> json_response 200 `Null)
  | _ -> json_response 200 `Null

let custom_paths app =
  [ "/healthz"; "/api/v1/search"; "/api/v1/fetch"; "/api/v1/answer" ]
  @ (if dashboard_enabled app then [ "/dashboard"; "/dashboard/data"; "/dashboard/metrics" ] else [])

(* Every custom-route answer crosses this boundary before the transport frames
   it. A head wider than [Http_head.response_head_limit] is replaced by a bounded
   500 rather than written: the route projection is the one place a header could
   ever stop being a constant, and a caller-shaped header value must not be able
   to decide how much this process allocates or sends. No route in the tree
   reaches the ceiling today, which is the point of measuring it here. *)
let bounded_response response =
  match
    Http_head.response_head ~status:response.status ~headers:response.headers
      ~body_length:(String.length response.body) ()
  with
  | Ok _ -> response
  | Error Http_head.Response_head_too_large ->
      { status = 500; headers = text_content; body = "" }

let route_custom ?(stopping = fun () -> false) app ~meth ~path ~host ~origin
    ~body =
  if String.length body > max_body_size then
    { status = 413; headers = text_content; body = "" }
  else
    (* [/healthz] is outside the allowlist; everything else is guarded. *)
    let origin_ok =
      match origin with
      | None -> true
      | Some o -> List.mem o (origin_allowlist app.allowed_hosts)
    in
    if not (host_gate app ~path ~host) then
      text_response 421 "Invalid Host header"
    else if path <> "/healthz" && not origin_ok then
      text_response 403 "Invalid Origin header"
    else
      let is_stopping = stopping () in
      match (meth, path) with
      | "GET", "/healthz" -> healthz app ~stopping:is_stopping
      | "POST", "/api/v1/search" -> api_search app ~stopping:is_stopping body
      | "POST", "/api/v1/fetch" -> api_fetch app ~stopping:is_stopping body
      | "POST", "/api/v1/answer" -> api_answer app ~stopping:is_stopping body
      | "GET", "/dashboard" when dashboard_enabled app ->
          { status = 200; headers = html_content; body = Dashboard_html.dashboard_html }
      | "GET", "/dashboard/data" when dashboard_enabled app ->
          if is_stopping then stopping_response () else dashboard_data app
      | "GET", "/dashboard/metrics" when dashboard_enabled app ->
          if is_stopping then stopping_response () else dashboard_metrics app
      | _, path when List.mem path (custom_paths app) ->
          text_response 405 "Method Not Allowed"
      | _ -> text_response 404 "Not Found"

let handle_custom ?stopping app ~meth ~path ~host ~origin ~body =
  bounded_response (route_custom ?stopping app ~meth ~path ~host ~origin ~body)

(* {1 Serving} *)

(* The replay source: the exact head bytes already consumed from the socket,
   then [rest] — a reader that still holds whatever the head parser read ahead
   plus the socket itself. The head is replayed because the transport's
   connection callback insists on reading the request it is handed; wrapping the
   original reader with [Eio.Buf_read.as_flow] rather than copying it is what
   keeps the replay from becoming a second, unbounded recording of the
   connection. *)
module Replay = struct
  type t = {
    mutable prefix : string;
    rest : Eio.Flow.source_ty Eio.Resource.t;
  }

  let read_methods : t Eio.Flow.read_method list = []

  let single_read t buf =
    if t.prefix = "" then Eio.Flow.single_read t.rest buf
    else
      let n = min (String.length t.prefix) (Cstruct.length buf) in
      Cstruct.blit_from_string t.prefix 0 buf 0 n;
      t.prefix <-
        (if n >= String.length t.prefix then ""
         else String.sub t.prefix n (String.length t.prefix - n));
      n
end

(* The custom routes as a cohttp server of their own: its connection driver
   parses the request, so this callback gets the parsed head and the body
   flow, and answers through the response it returns. *)
let custom_handler ?stopping app =
  Cohttp_eio.Server.make
    ~callback:(fun _conn req body ->
      let raw =
        Eio.Buf_read.(take_all (of_flow body ~max_size:(max_body_size + 1)))
      in
      if String.length raw > max_body_size then
        Cohttp_eio.Server.respond_string ~status:`Request_entity_too_large ~body:"" ()
      else
        let meth = Http.Method.to_string (Http.Request.meth req) in
        let path = Uri.path (Uri.of_string (Http.Request.resource req)) in
        let headers = Http.Request.headers req in
        let host = Http.Header.get headers "host" in
        let origin = Http.Header.get headers "origin" in
        let response =
          handle_custom ?stopping app ~meth ~path ~host ~origin ~body:raw
        in
        Cohttp_eio.Server.respond_string
          ~headers:(Http.Header.of_list response.headers)
          ~status:(Http.Status.of_int response.status)
          ~body:response.body
          ())
    ()

(* The request line's path: [METHOD SP resource SP version]. *)
let path_of_request_line line =
  match String.split_on_char ' ' line with
  | _meth :: resource :: _ -> (
      match String.index_opt resource '?' with
      | Some q -> String.sub resource 0 q
      | None -> resource)
  | _ -> "/"

type serve_error =
  | Bind_address_unresolved
  | Listener_unavailable

(* The two startup failures are values with a constant classification, not an
   exception: the address may carry the operator's host and a bind failure may
   carry a socket fact, and neither belongs in a log line or a sentence. *)
let serve_error_kind = function
  | Bind_address_unresolved -> "bind_address_unresolved"
  | Listener_unavailable -> "listener_unavailable"

let addr_of_host ~net host : (Eio.Net.Ipaddr.v4v6, serve_error) result =
  match Ipaddr.of_string host with
  | Ok ip -> Ok (Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets ip))
  | Error _ -> (
      match Eio.Net.getaddrinfo_stream ~service:"" net host with
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception _ -> Error Bind_address_unresolved
      | `Tcp (addr, _) :: _ -> Ok addr
      | _ -> Error Bind_address_unresolved)

(* The replayed head arrives as lines, not as an [Http.Header]; fold it through
   the same header type so the transport's [Host] read is not a hand-rolled
   prefix test. A line without a colon is not a header and is dropped. *)
let headers_of_lines lines =
  List.fold_left
    (fun headers line ->
      match String.index_opt line ':' with
      | None -> headers
      | Some at ->
          let name = String.trim (String.sub line 0 at) in
          let value =
            String.trim
              (String.sub line (at + 1) (String.length line - at - 1))
          in
          if name = "" then headers else Http.Header.add headers name value)
    (Http.Header.init ()) lines

(* A text refusal's exact bytes. The head comes from [Http_head.response_head],
   which computes [content-length] from the body it writes and refuses a head
   wider than the outbound ceiling, so the arithmetic is never restated beside
   the format string. The 500 arm is unreachable behind this fixed header set;
   it is here so that a future caller with a wider header list gets a bounded
   answer instead of an unbounded write. *)
let http_text_response status body =
  match
    Http_head.response_head ~status
      ~headers:[ ("content-type", "text/plain") ]
      ~body_length:(String.length body) ()
  with
  | Ok head -> head ^ body
  | Error Http_head.Response_head_too_large ->
      "HTTP/1.1 500 Internal Server Error\r\ncontent-type: text/plain\r\n\
       content-length: 0\r\nconnection: close\r\n\r\n"

(* The head-read bound. A connection whose head has not arrived inside this is
   refused rather than waited on, so a peer that trickles a byte at a time
   cannot hold a connection open indefinitely. The clock is the caller's: the
   listener hands in its monotonic clock, and a test hands in one it controls,
   so the decision is taken by the timeout and not by elapsed wall time. *)
let request_head_timeout_seconds = 10.0

let head_rejected log kind =
  log Config.Log_info "http.head_rejected" [ ("kind", `String kind) ]

let write_text flow status sentence =
  Eio.Buf_write.with_flow flow @@ fun oc ->
  Eio.Buf_write.string oc (http_text_response status sentence)

(* Discard whatever the peer still sends, up to the head timeout. *)
let drain flow =
  let buffer = Cstruct.create 4096 in
  let rec loop () =
    match Eio.Flow.single_read flow buffer with
    | 0 -> ()
    | _ -> loop ()
    | exception End_of_file -> ()
  in
  loop ()

(* A bounded refusal, then a clean close.

   The peer may still be sending the head this refused — an over-cap head is
   refused at the ceiling, so there is always at least the offending byte
   unread. Closing a socket with unread input makes the kernel answer with RST,
   and an RST can discard the refusal still queued in the send buffer. Reading
   the remainder first (bounded by the same timeout the head had) lets the peer
   receive the refusal and then see a clean close. The read is abandoned at the
   timeout, so a peer that refuses to stop sending costs one timeout, not an
   unbounded drain. *)
let refuse ~clock flow status sentence =
  write_text flow status sentence;
  ignore
    (Eio.Time.Timeout.run
       (Eio.Time.Timeout.seconds clock request_head_timeout_seconds)
       (fun () ->
         drain flow;
         Ok ()))

(* One accepted connection: read the request head under the ceiling and the
   timeout, answer a bounded refusal for what cannot be read, and otherwise hand
   the replayed connection to the mcp-kit handler for [/mcp] or to
   {!handle_custom} for everything else. Each driver loops keep-alive itself, so
   the first request decides the connection. The Host allowlist is applied here,
   in the surrounding route, because the mcp-kit adapter owns Origin but not
   Host (plans/capability-gated-mcp-server.md §7); [/healthz] is exempt.

   Every refusal carries [connection: close] and the connection ends with this
   function, so a peer's next request arrives on a fresh connection — which is
   what makes an over-cap head cost one connection and not the listener. *)
let serve_connection ?stopping ~clock ~log ~app ~server ~flow ~peer () =
  Eio.Switch.run @@ fun conn_sw ->
  let reader = Http_head.request_reader flow in
  match
    Eio.Time.Timeout.run
      (Eio.Time.Timeout.seconds clock request_head_timeout_seconds)
      (fun () -> Ok (Http_head.read_request_head reader))
  with
  | Error `Timeout ->
      head_rejected log "timeout";
      refuse ~clock flow 408 "Request Timeout"
  | Ok (Error Http_head.Client_closed) -> ()
  | Ok (Error Http_head.Request_head_too_large) ->
      head_rejected log "too_large";
      refuse ~clock flow 431 "Request Header Fields Too Large"
  | Ok (Error Http_head.Malformed_request_head) ->
      head_rejected log "malformed";
      refuse ~clock flow 400 "Bad Request"
  | Ok (Ok (head, raw)) ->
      let headers = headers_of_lines head.Http_head.header_lines in
      let path = path_of_request_line head.Http_head.request_line in
      let host = Http.Header.get headers "host" in
      if not (host_gate app ~path ~host) then
        refuse ~clock flow 421 "Invalid Host header"
      else
        let replay : Eio.Flow.source_ty Eio.Resource.t =
          ( Eio.Resource.T
              ( { Replay.prefix = raw; rest = Eio.Buf_read.as_flow reader },
                Eio.Flow.Pi.source (module Replay) )
            :> Eio.Flow.source_ty Eio.Resource.t )
        in
        let replay_reader = Http_head.request_reader replay in
        let handler =
          if path = "/mcp" then
            Mcp_kit_cohttp_eio.handler ~max_body_size
              ~allowed_origins:(origin_allowlist app.allowed_hosts)
              server
          else custom_handler ?stopping app
        in
        (match
           Eio.Buf_write.with_flow flow @@ fun oc ->
           Cohttp_eio.Server.callback handler (conn_sw, peer) replay_reader oc
         with
        | () -> ()
        | exception Eio.Buf_read.Buffer_limit_exceeded ->
            (* A later request on this keep-alive connection brought a head
               wider than the ceiling. Nothing was written for it yet, so it
               gets the same bounded refusal the first request would have
               got. *)
            head_rejected log "too_large";
            refuse ~clock flow 431 "Request Header Fields Too Large")

let run_health_monitor (health : health) ~(config : Config.t)
    ~(sleep : unit -> unit) =
  let tick () =
    Health.run_probes config ~built:health.built ~table:health.probes
      ~net:health.net health.board
  in
  (* Sleep first, as [HealthMonitor.run] does: a start does not spend a probe
     before the first interval. The fiber is a child of the listener's switch
     and [serve_http] gives it its own cancellation context, so a stop aborts a
     probe already in flight instead of waiting for its timeout. *)
  let rec loop () =
    sleep ();
    tick ();
    loop ()
  in
  loop ()

(* The bounded drain. A stop is a request to stop accepting; the connection
   fibers already accepted are allowed this many seconds to finish before they
   are cancelled, which is what keeps a hung handler from holding the process
   open forever. The number is a constant because the frozen ten server flags
   have no place to carry it and the operator's config has no key for it in the
   oracle either; a future key would move one binding. *)
let drain_grace_seconds = 10.0

type lifecycle =
  | Drained
  | Grace_expired

(* Raised into the connection switch at the grace ceiling, and by the accept
   loop when accepting itself fails. Both are caught inside [serve_http], so
   they never reach a caller. *)
exception Drain_forced

exception Listener_failed of exn

let serve_http ~env ~sw ~log app server ~host ~port ~stop
    ?(grace_seconds = drain_grace_seconds) () =
  match addr_of_host ~net:(env#net) host with
  | Error error ->
      log Config.Log_warning "http.listen_failed"
        [ ("kind", `String (serve_error_kind error)) ];
      Error error
  | Ok addr -> (
      match Eio.Net.listen ~backlog:128 ~sw env#net (`Tcp (addr, port)) with
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception _ ->
          let error = Listener_unavailable in
          log Config.Log_warning "http.listen_failed"
            [ ("kind", `String (serve_error_kind error)) ];
          Error error
      | socket ->
          (* The one fact every custom route reads while draining. It is set
             before the accept loop is told to stop, so a keep-alive request
             that arrives during the drain sees "stopping" rather than a route
             that would spend money. *)
          let stopping = Atomic.make false in
          (* The health fiber is a child of the app switch like the listener,
             but it owns its own cancellation context: a probe in flight when
             the stop arrives must be aborted, not waited for. Its context and
             completion are captured now so the drain can cancel and join it. *)
          let health =
            match app.health with
            | Some health
              when app.config.Config.search.Config.health_interval_seconds > 0.0
              ->
                let interval =
                  app.config.Config.search.Config.health_interval_seconds
                in
                let ready, resolve_ready = Eio.Promise.create () in
                let done_ =
                  Eio.Fiber.fork_promise ~sw (fun () ->
                    Eio.Cancel.sub (fun health_ctx ->
                      Eio.Promise.resolve resolve_ready health_ctx;
                      run_health_monitor health ~config:app.config
                        ~sleep:(fun () ->
                          Eio.Time.Mono.sleep env#mono_clock interval)))
                in
                Some (ready, done_)
            | _ -> None
          in
          let stop_health () =
            match health with
            | None -> ()
            | Some (ready, done_) ->
                let health_ctx = Eio.Promise.await ready in
                Eio.Cancel.cancel health_ctx (Failure "shutdown");
                (match Eio.Promise.await done_ with
                | Ok () | Error (Eio.Cancel.Cancelled _) -> ()
                | Error _ -> ())
          in
          let listener_error exn =
            log Config.Log_warning "http.listener_error"
              [ ("kind", `String (Log.classify_exn exn)) ];
            Error Listener_unavailable
          in
          (* Every connection failure is one fixed event with a bounded
             classification: a rejected Origin is an expected refusal at INFO,
             anything else is a WARNING. Neither arm renders the exception. *)
          let on_error = function
            | Mcp_kit_cohttp_eio.Rejected_origin ->
                log Config.Log_info "http.origin_rejected"
                  [ ("kind", `String "rejected_origin") ]
            | exn ->
                log Config.Log_warning "http.connection_error"
                  [ ("kind", `String (Log.classify_exn exn)) ]
          in
          (* The accept loop is our own rather than [Eio.Net.run_server]'s
             because a stop must also close the listening socket: leaving it
             open would queue further connects through the drain, and "another
             connection attempt is refused" is part of the contract. The loop
             gets its own cancellation context, so ending it never touches the
             connections already running; those live in one switch, which the
             grace ceiling fails as a unit. *)
          let outcome =
            let connections = ref 0 in
            let idle = Eio.Condition.create () in
            let connection_finished () =
              decr connections;
              if !connections = 0 then Eio.Condition.broadcast idle
            in
            let wait_idle () =
              Eio.Condition.loop_no_mutex idle (fun () ->
                  if !connections = 0 then Some () else None)
            in
            let forced = ref false in
            let serve () =
              Eio.Switch.run @@ fun conn_sw ->
                let accept_ctx, resolve_accept_ctx = Eio.Promise.create () in
                let accept_done =
                  Eio.Fiber.fork_promise ~sw (fun () ->
                    Eio.Cancel.sub (fun ctx ->
                      Eio.Promise.resolve resolve_accept_ctx ctx;
                      let rec accept () =
                        let flow, peer = Eio.Net.accept ~sw:conn_sw socket in
                        incr connections;
                        Eio.Fiber.fork ~sw:conn_sw (fun () ->
                          Fun.protect ~finally:connection_finished (fun () ->
                            try
                              serve_connection
                                ~stopping:(fun () -> Atomic.get stopping)
                                ~clock:env#mono_clock ~log ~app ~server
                                ~flow:
                                  (flow
                                    :> Eio.Flow.two_way_ty Eio.Resource.t)
                                ~peer ()
                            with
                            | Eio.Cancel.Cancelled _ as exn -> raise exn
                            | exn -> on_error exn));
                        accept ()
                      in
                      accept ()))
                in
                match
                  Eio.Fiber.first
                    (fun () ->
                      Eio.Promise.await stop;
                      `Stopped)
                    (fun () ->
                      match Eio.Promise.await accept_done with
                      | Ok () -> `Accept_ended
                      | Error (Eio.Cancel.Cancelled _ as exn) -> raise exn
                      | Error exn -> `Accept_failed exn)
                with
                | `Accept_failed exn ->
                    Atomic.set stopping true;
                    Eio.Net.close socket;
                    stop_health ();
                    raise (Listener_failed exn)
                | `Stopped | `Accept_ended ->
                    Atomic.set stopping true;
                    log Config.Log_info "http.stopping"
                      [ ("grace_seconds", `Float grace_seconds) ];
                    (* Stop accepting, then close the socket: the accept fiber
                       no longer sits in [accept], so the close cannot race the
                       resource it is registered with. *)
                    (try
                       Eio.Cancel.cancel
                         (Eio.Promise.await accept_ctx)
                         (Failure "shutdown")
                     with Invalid_argument _ -> ());
                    (match Eio.Promise.await accept_done with
                    | Ok () | Error (Eio.Cancel.Cancelled _) -> ()
                    | Error exn -> raise (Listener_failed exn));
                    Eio.Net.close socket;
                    stop_health ();
                    let drain =
                      Eio.Time.Timeout.run
                        (Eio.Time.Timeout.seconds env#mono_clock grace_seconds)
                        (fun () ->
                          wait_idle ();
                          Ok ())
                    in
                    (match drain with
                    | Ok () -> `Drained
                    | Error `Timeout ->
                        forced := true;
                        Eio.Switch.fail conn_sw Drain_forced;
                        (* The failure above cancels this body's context too
                           (it is a fiber of the switch), so the join has to
                           run protected: it is cleanup, not work the
                           cancellation should pre-empt. *)
                        Eio.Cancel.protect wait_idle;
                        log Config.Log_warning "http.drain_forced"
                          [ ("grace_seconds", `Float grace_seconds) ];
                        `Forced)
            in
            match serve () with
            | `Drained -> Ok Drained
            | `Forced -> Ok Grace_expired
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception Drain_forced when !forced -> Ok Grace_expired
            | exception Listener_failed exn -> listener_error exn
            | exception exn -> listener_error exn
          in
          outcome)

(* {1 The frozen surface data} *)

let params properties = List.map fst properties

let tools_surface =
  [
    ("answer", params answer_properties);
    ("fetch", params fetch_properties);
    ("search", params search_properties);
  ]

let rest_routes =
  [
    ( "POST",
      "/api/v1/answer",
      "AnswerRequest",
      List.sort compare (params answer_properties) );
    ( "POST",
      "/api/v1/fetch",
      "FetchRequest",
      List.sort compare (params fetch_properties) );
    ( "POST",
      "/api/v1/search",
      "SearchRequest",
      List.sort compare (params search_properties) );
  ]

let operational_routes =
  [
    ("GET", "/dashboard");
    ("GET", "/dashboard/data");
    ("GET", "/dashboard/metrics");
    ("GET", "/healthz");
  ]

let cli_verbs = [ "answer"; "fetch"; "search" ]

(** {1 The server flags} *)

type flag_arity =
  | Boolean
  | Value

type server_flag = {
  name : string;
  arity : flag_arity;
  repeats : bool;
  key : string;
}

let server_flag_table =
  [
    { name = "--check"; arity = Boolean; repeats = false; key = "check" };
    { name = "--live"; arity = Boolean; repeats = false; key = "live" };
    { name = "--metrics"; arity = Boolean; repeats = false; key = "metrics" };
    { name = "--json"; arity = Boolean; repeats = false; key = "json" };
    { name = "--http"; arity = Boolean; repeats = false; key = "http" };
    { name = "--host"; arity = Value; repeats = false; key = "host" };
    { name = "--port"; arity = Value; repeats = false; key = "port" };
    {
      name = "--allowed-host";
      arity = Value;
      repeats = true;
      key = "allowed_host";
    };
    { name = "--log-level"; arity = Value; repeats = false; key = "log_level" };
    {
      name = "--log-format";
      arity = Value;
      repeats = false;
      key = "log_format";
    };
  ]

(* The frozen manifest's list is derived, so the name the manifest advertises
   and the name the parser accepts are one fact. *)
let server_flags =
  List.map (fun (flag : server_flag) -> flag.name) server_flag_table

let flag_spec name =
  List.find_opt (fun (flag : server_flag) -> flag.name = name) server_flag_table

(* The keys [Usage] writes on each journal line kind, sorted. Pinned against a
   real journal by test/test_p8_surface.ml. *)
let journal_fields =
  [
    ( "search",
      [
        "cost_usd"; "error"; "fell_back"; "ms"; "provider"; "results"; "run"; "step"; "tool"; "ts";
      ] );
    ( "fetch",
      [ "chars"; "cost_usd"; "error"; "fallback"; "ms"; "run"; "step"; "tool"; "ts" ] );
    ( "answer",
      [
        "answer_chars"; "cited"; "cited_invalid"; "completion_tokens"; "depth"; "error"; "fetched";
        "material_chars"; "model"; "model_cost_usd"; "ms"; "prompt_tokens"; "results"; "run";
        "searches"; "sources"; "tool"; "ts";
      ] );
  ]
