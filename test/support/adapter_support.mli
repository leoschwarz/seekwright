(* The adapter suites' harness: the fake {!Seekwright.Provider.Net.t} every
   request-shape case dials, and the fixture readers those cases repeat. It is a
   library and not a module inside each suite for the same reason {!Test_support}
   is: a helper copied into fifteen files drifts in fifteen directions.

   Separate from {!Test_support} because this one links the server: the
   [mcp-caps] suites link the string helpers and must not pull [seekwright] into
   their link closure to get a substring search. *)

val test_key : string
(** The credential every adapter suite hands its adapter and no socket ever carries. A leak
    assertion looks for this string, so it is one name and not twelve spellings of it. *)

val query :
  ?text:string ->
  ?max_results:int ->
  ?include_domains:string list ->
  ?exclude_domains:string list ->
  ?country:string ->
  ?language:string ->
  ?recency:Seekwright.Model.recency ->
  ?safe_search:bool ->
  unit ->
  Seekwright.Model.search_query
(** The search request an adapter is driven with. [text] defaults to ["q"]: a suite names the query
    when the query is the claim, and [max_results] is 5 because every cap assertion then reads as a
    multiple of it. *)

val answered :
  status:int -> body:string -> Seekwright.Provider.Net.t * (unit -> Mcp_caps.Authority.Net.request)
(** [answered ~status ~body] answers every call with that status and body, and the reader is the
    last request dialed — [Alcotest.failf] when nothing was, which is a bug in the case rather than
    a vendor fact. *)

val recording :
  (Mcp_caps.Authority.Net.request -> (Mcp_caps.Authority.Net.response, Mcp_caps.Error.t) result) ->
  Seekwright.Provider.Net.t * (unit -> Mcp_caps.Authority.Net.request list)
(** [recording handler] dials [handler] per call and keeps every request in the order it was dialed
    — the shape a paged walk asserts on. *)

val response : status:int -> body:string -> Mcp_caps.Authority.Net.response
(** [response ~status ~body] is the canned answer, with no headers because no adapter reads one. *)

val refusing : Mcp_caps.Error.kind -> message:string -> Seekwright.Provider.Net.t
(** [refusing kind ~message] fails every dial, which is how the transport rows — operation bound,
    unreachable host, timeout — reach an adapter. *)

val ok_search :
  Seekwright.Provider.t -> Seekwright.Model.search_query -> Seekwright.Provider.outcome
(** [ok_search adapter q] is the outcome of a search that has to succeed: an [Error] fails the case
    with the rendered sentence, rather than a pattern match swallowing it. *)

val drive :
  Seekwright.Provider.t ->
  (unit -> Mcp_caps.Authority.Net.request) ->
  Seekwright.Model.search_query ->
  Seekwright.Provider.outcome * Mcp_caps.Authority.Net.request
(** [drive adapter sent q] runs the search and pairs its outcome with the
    request the adapter dialed. The order is the point: writing
    [(ok_search adapter q, sent ())] reads the egress before anything is dialed,
    because a tuple's components are evaluated right-to-left. *)

val json_object : string -> Yojson.Safe.t
(** [json_object text] is a fixture decoded as an object; anything else fails the case, so a
    malformed fixture cannot pass vacuously. *)

val body_of : Mcp_caps.Authority.Net.request -> Yojson.Safe.t
(** [body_of request] is the request body decoded. A request with no body fails the case: the
    adapters that send one always send one. *)

val body_field : string -> Mcp_caps.Authority.Net.request -> string option
(** [body_field name request] reads [name] from the body as text: a string as it is, an integer
    rendered, an absent field [None], and anything else rendered so a shape-drift case can still
    name what arrived. *)

val has_body_field : string -> Mcp_caps.Authority.Net.request -> bool
(** [has_body_field name request] is true when the body carries [name] whatever its value —
    including an explicit [null], which is the point for the adapters that send a filter at its
    default rather than omitting it. *)

val params : Mcp_caps.Authority.Net.request -> (string * string list) list
(** [params request] is the query string of a [GET] adapter's uri, as [Uri.query]
    gives it: a key may carry several values. *)

val param : Mcp_caps.Authority.Net.request -> string -> string option
(** [param request name] is one of those pairs' value. *)

val has_param : Mcp_caps.Authority.Net.request -> string -> bool
(** [has_param request name] is true when the parameter is present whatever it carries. *)
