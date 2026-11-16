(** Agent mode: fixed retrieval plan feeding a single model call with server-validated citations.

    The model never drives retrieval: the server executes queries (at most two extra queries,
    five results each, and up to three pages for [depth = Report]) and feeds the material
    into one completion call. Citations (`[n]`) are validated by the server against
    retrieved material. *)

val results_per_query : int
(** [max_results] on every retrieval step (5). *)

val pages_per_report : int
(** Maximum pages fetched for a report (3). *)

val temperature : float
(** Server sampling temperature (0.2). *)

val answer_system_prompt : string
(** System prompt requiring strict citation against numbered material. *)

type t
(** Agent mode engine. *)

val create :
  Config.t ->
  net:Provider.Net.t ->
  Engine.Search.t ->
  ?fetch_engine:Engine.Fetch.t ->
  ?usage:Usage.t ->
  ?log:Engine.log ->
  clock:(unit -> float) ->
  now:(unit -> float) ->
  unit ->
  t
(** [create config ~net engine ~clock ~now ()]. [~clock] provides monotonic
    seconds for timeouts and latency accounting; [~now] provides UTC wall
    seconds for timestamps. *)

val answer :
  t ->
  query:string ->
  ?extra_queries:string list ->
  ?depth:Model.depth ->
  ?provider:Config.name ->
  ?include_domains:string list ->
  ?exclude_domains:string list ->
  ?recency:Model.recency ->
  ?language:string ->
  ?safe_search:bool ->
  unit ->
  (Model.answer_response, string) result
(** Answers [query] using the fixed retrieval plan, executing one model call
    and returning verified sources. *)
