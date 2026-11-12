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

let healthz app =
  let built = Engine.Search.providers app.search in
  json_response 200
    (`Assoc
       [
         ("status", `String "ok");
         (* The dispatchable set, not the configured one: a name this build has
            no adapter for is not a provider it has, and the startup warning
            is where the operator reads that. *)
         ("providers", `List (List.map (fun name -> `String name) built));
         ( "default_provider",
           (match app.config.Config.default_provider with
           | Some name when List.mem name built -> `String name
           | _ -> `Null) );
         ( "uptime_s",
           `Int (int_of_float (app.mono_now () -. app.started_at)) );
       ])

let api_search app body =
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

let api_fetch app body =
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

let api_answer app body =
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

let handle_custom app ~meth ~path ~host ~origin ~body =
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
      match (meth, path) with
      | "GET", "/healthz" -> healthz app
      | "POST", "/api/v1/search" -> api_search app body
      | "POST", "/api/v1/fetch" -> api_fetch app body
      | "POST", "/api/v1/answer" -> api_answer app body
      | "GET", "/dashboard" when dashboard_enabled app ->
          { status = 200; headers = html_content; body = Dashboard_html.dashboard_html }
      | "GET", "/dashboard/data" when dashboard_enabled app -> dashboard_data app
      | "GET", "/dashboard/metrics" when dashboard_enabled app -> dashboard_metrics app
      | _, path when List.mem path (custom_paths app) ->
          text_response 405 "Method Not Allowed"
      | _ -> text_response 404 "Not Found"

(* {1 Serving} *)

(* A tap on the accepted socket: every byte read through it is also recorded,
   so a request whose head has been read can be replayed for the mcp-kit
   handler, whose connection-level callback insists on reading the request
   itself. *)
module Tap = struct
  type t = {
    flow : Eio.Flow.two_way_ty Eio.Resource.t;
    recorded : Buffer.t;
  }

  let read_methods : t Eio.Flow.read_method list = []

  let single_read t buf =
    let n = Eio.Flow.single_read t.flow buf in
    if n > 0 then
      Buffer.add_string t.recorded (Cstruct.to_string (Cstruct.sub buf 0 n));
    n
end

(* The replay source: the recorded head first, then the socket itself. *)
module Replay = struct
  type t = {
    mutable prefix : string;
    flow : Eio.Flow.two_way_ty Eio.Resource.t;
  }

  let read_methods : t Eio.Flow.read_method list = []

  let single_read t buf =
    if t.prefix = "" then Eio.Flow.single_read t.flow buf
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
let custom_handler app =
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
        let response = handle_custom app ~meth ~path ~host ~origin ~body:raw in
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

let addr_of_host ~net host =
  match Ipaddr.of_string host with
  | Ok ip -> Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets ip)
  | Error _ -> (
      match Eio.Net.getaddrinfo_stream ~service:"" net host with
      | `Tcp (addr, _) :: _ -> addr
      | _ -> failwith ("seekwright: cannot resolve bind address " ^ host))

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

(* [http] 6.3 has no phrase for 421 and answers the decimal code in its place;
   the refusal this module writes says [Misdirected Request], as Python's does. *)
let reason_phrase status =
  let phrase = Http.Status.reason_phrase_of_code status in
  if phrase <> string_of_int status then phrase
  else match status with 421 -> "Misdirected Request" | _ -> phrase

(* A text refusal's exact bytes, with the length computed from the body it
   writes: the transport below this point writes its own framing, so a
   hand-counted [content-length] would be a protocol lie the first time a
   sentence changed. *)
let http_text_response status body =
  Printf.sprintf
    "HTTP/1.1 %d %s\r\ncontent-type: text/plain\r\ncontent-length: %d\r\nconnection: close\r\n\r\n%s"
    status (reason_phrase status) (String.length body) body

let run_health_monitor (health : health) ~(config : Config.t)
    ~(sleep : unit -> unit) =
  let tick () =
    Health.run_probes config ~built:health.built ~table:health.probes
      ~net:health.net health.board
  in
  (* Sleep first, as [HealthMonitor.run] does: a start does not spend a probe
     before the first interval. The fiber is a child of the listener's switch,
     so cancelling that switch is the stop. *)
  let rec loop () =
    sleep ();
    tick ();
    loop ()
  in
  loop ()

let serve_http ~env ~sw app server ~host ~port =
  let addr = addr_of_host ~net:(env#net) host in
  let socket = Eio.Net.listen ~backlog:128 ~sw env#net (`Tcp (addr, port)) in
  (match app.health with
  | Some health when app.config.Config.search.Config.health_interval_seconds > 0.0 ->
      let interval =
        app.config.Config.search.Config.health_interval_seconds
      in
      Eio.Fiber.fork ~sw (fun () ->
        run_health_monitor health ~config:app.config
          ~sleep:(fun () -> Eio.Time.Mono.sleep env#mono_clock interval))
  | _ -> ());
  let handler =
    Mcp_kit_cohttp_eio.handler ~max_body_size
      ~allowed_origins:(origin_allowlist app.allowed_hosts)
      server
  in
  let stop, _resolve = Eio.Promise.create () in
  let on_error = function
    | Mcp_kit_cohttp_eio.Rejected_origin ->
        prerr_endline "seekwright: origin rejected"
    | exn -> prerr_endline ("seekwright: connection: " ^ Printexc.to_string exn)
  in
  let custom = custom_handler app in
  Eio.Net.run_server ~stop ~on_error socket
  @@ fun sock peer ->
  Eio.Switch.run @@ fun conn_sw ->
  (* The tap records every byte read through [ic], so the request line this
     loop consumes can be replayed for whichever handler takes the
     connection. *)
  let recorded = Buffer.create 8192 in
  let tap_handler = Eio.Flow.Pi.source (module Tap) in
  let tapped : Eio.Flow.source_ty Eio.Resource.t =
    (Eio.Resource.T ({ Tap.flow = (sock :> Eio.Flow.two_way_ty Eio.Resource.t); recorded }, tap_handler)
      :> Eio.Flow.source_ty Eio.Resource.t)
  in
  let ic = Eio.Buf_read.of_flow ~max_size:max_int tapped in
  Eio.Buf_write.with_flow sock @@ fun oc ->
  (* Peek the request line and the header block, then hand the whole
     connection — replayed from the tap — to the mcp-kit handler for [/mcp] or
     to the custom-route handler for everything else. Each driver loops
     keep-alive itself, so the first request decides the connection. The Host
     allowlist is applied here, in the surrounding route, because the mcp-kit
     adapter owns Origin but not Host (plans/capability-gated-mcp-server.md
     §7); [/healthz] is exempt. *)
  let rec peek_headers acc =
    match Eio.Buf_read.line ic with
    | exception End_of_file -> List.rev acc
    | "" | "\r" -> List.rev acc
    | line -> peek_headers (line :: acc)
  in
  match Eio.Buf_read.line ic with
  | exception End_of_file -> ()
  | request_line ->
      let headers = headers_of_lines (peek_headers []) in
      let path = path_of_request_line request_line in
      let host = Http.Header.get headers "host" in
      let replay () =
        let replay_handler = Eio.Flow.Pi.source (module Replay) in
        let replay : Eio.Flow.source_ty Eio.Resource.t =
          ( Eio.Resource.T
              ({ Replay.prefix = Buffer.contents recorded; flow = (sock :> Eio.Flow.two_way_ty Eio.Resource.t) }, replay_handler)
            :> Eio.Flow.source_ty Eio.Resource.t )
        in
        Eio.Buf_read.of_flow ~max_size:max_int replay
      in
      if not (host_gate app ~path ~host) then
        Eio.Buf_write.string oc (http_text_response 421 "Invalid Host header")
      else if path = "/mcp" then
        Cohttp_eio.Server.callback handler (conn_sw, peer) (replay ()) oc
      else Cohttp_eio.Server.callback custom (conn_sw, peer) (replay ()) oc

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
