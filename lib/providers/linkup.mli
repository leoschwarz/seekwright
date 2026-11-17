(** Linkup — answer synthesis and web search backend.

    Supports two payload shapes via {!output}: [Sourced_answer] returns a prose answer with citation
    sources; [Search_results] returns structured web search hits.

    Endpoint: [POST https://api.linkup.so/v1/search] with bearer token.

    Supports [recency] mapped to [fromDate] timestamp, plus [include_domains] and [exclude_domains].
    429 indicates rate limiting (10 QPS org-wide). *)

val name : string
(** ["linkup"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** [https://api.linkup.so/v1/search]. *)

type output = Sourced_answer | Search_results

val show_output : output -> string
(** Serialises to "sourcedAnswer" or "searchResults". *)

val age_days : Seekwright.Model.recency -> int
(** Window length in days: Day (1), Week (7), Month (30), Year (365). *)

val format_utc : float -> string
(** Formats timestamp as [%Y-%m-%dT%H:%M:%SZ]. *)

val parse_sources : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses [sources[]] citations for [Sourced_answer]. *)

val parse_results : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses [results[]] hits for [Search_results], skipping image results. *)

val answer : output:output -> Yojson.Safe.t -> string option
(** Extracts prose answer when [output] is [Sourced_answer]; returns [None] otherwise. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat per request. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  ?depth:string ->
  ?output:output ->
  key:string ->
  now:(unit -> float) ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the Linkup provider. [key], [now], and [net] are mandatory. *)
