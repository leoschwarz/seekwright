(** Parallel — web search backend with REST (billed) and MCP (anonymous free) halves.

    [parallel] uses the REST API with structured filter parameters (domains, recency, location,
    mode). [parallel:free] uses the hosted Search MCP endpoint anonymously. Both share the same
    [results[]] parsing logic. *)

val endpoint : Uri.t
(** [https://api.parallel.ai/v1/search], the REST API endpoint. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** Policy grant destination matching {!endpoint}. *)

val mcp_uri : Uri.t
(** [https://search.parallel.ai/mcp], the hosted MCP endpoint. *)

val mcp_tool : string
(** [web_search] tool name on the MCP endpoint. *)

val recency_days : Seekwright.Model.recency -> int
(** Window length in days: Day (1), Week (7), Month (30), Year (365). *)

val after_date : now:(unit -> float) -> Seekwright.Model.recency -> string
(** Formats [YYYY-MM-DD] for the recency window boundary relative to [now]. *)

val parse_results : Yojson.Safe.t -> limit:int -> text_chars:int -> Seekwright.Provider.hit list
(** Parses hits from [results[]], mapping excerpts to text. *)

val make :
  ?cost_per_1k:float ->
  ?text_chars:int ->
  ?mode:string ->
  key:string ->
  now:(unit -> float) ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the billed REST provider. [key], [now], and [net] are mandatory. *)

val make_mcp :
  ?cost_per_1k:float ->
  ?text_chars:int ->
  name:string ->
  uri:Uri.t ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.session
(** Constructs the anonymous hosted-MCP provider for [parallel:free]. *)
