(** Exa — web search provider accessed via MCP tool call.

    Exa serves both anonymous (rate-limited free) and authenticated (paid) requests from the same
    MCP endpoint. Responses arrive as formatted text parsed from block format into structured
    results.

    The tiered adapter attempts the free tier first and falls back to the API key on any failure,
    maintaining a cooldown period during which subsequent calls use the key directly. *)

val default_uri : Uri.t
(** [https://mcp.exa.ai/mcp], the default MCP endpoint. *)

val tool_name : string
(** [web_search_exa], advertising [query] and [numResults]. Any query constraints are recorded as
    ignored in {!Seekwright.Provider.ignored_constraints}. *)

val parse : text_chars:int -> string -> limit:int -> Seekwright.Provider.hit list
(** Parses block-formatted text into hits with highlights and text joined. *)

val make_mcp :
  cost_for:(int -> float) ->
  ?text_chars:int ->
  name:string ->
  ?auth:string ->
  uri:Uri.t ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.session
(** Constructs a single MCP session adapter (e.g. for [exa:free] or direct keyed use). *)

val make_tiered :
  cost_for:(int -> float) ->
  ?text_chars:int ->
  ?cooldown_seconds:float ->
  now:(unit -> float) ->
  ?log:Seekwright.Log.log ->
  key:string ->
  uri:Uri.t ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.session
(** Constructs the tiered [exa] provider that tries free first and falls back to the API key on
    failure. [now] must provide monotonic time. [cost_for] prices the keyed rung — what a caller
    should assume it might pay — and this function prices the free rung at zero. *)
