(** Algolia — a keyed, index-scoped SERP-shaped backend over records you own.

    Billed per search request regardless of result count. The Search API at
    [{app_id}-dsn.algolia.net] queries operator-owned records in a single index. The API key is
    mandatory on all tiers.

    Endpoint: [POST] to {!endpoint_of_deployment} with Application-ID and API key headers.

    Records are schemaless JSON. Field extraction checks configurable attributes first, then falls
    back to common names (title/name/question, url/link, description/summary/excerpt/content/answer)
    and DocSearch hierarchy levels. Records missing both title and url are dropped.

    Algolia's search API accepts no filter constraints; all constraints are reported dropped in the
    notice. 403 indicates authentication failure; 402 and 429 indicate quota exhaustion. *)

val name : string
(** ["algolia"], the config key and the [provider] every response names. *)

val endpoint_of_deployment : app_id:string -> index:string -> Uri.t
(** [endpoint_of_deployment ~app_id ~index] is the Search API query endpoint for one deployment:
    [https://{app_id}-dsn.algolia.net/1/indexes/{index}/query] with the index name percent-encoded.
*)

val scalar_text : Yojson.Safe.t -> string option
(** [scalar_text value] coerces scalar JSON values ([string], [int], [float]) to text. Other values
    (including boolean) return [None]. *)

val first_str : string list -> Yojson.Safe.t -> string option
(** The first of [attrs] that holds a scalar in [record], coerced; [None] when none of them does. *)

val hierarchy_title : Yojson.Safe.t -> string option
(** The DocSearch-shaped title: the most specific non-empty [hierarchy.lvl0..6]. *)

val parse :
  snippet_chars:int ->
  ?title_attr:string ->
  ?url_attr:string ->
  ?snippet_attr:string ->
  Yojson.Safe.t ->
  limit:int ->
  Seekwright.Provider.hit list
(** [hits[]] mapped onto title/url/snippet. The limit slices the upstream list before anything is
    dropped; non-object records are skipped. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD. Flat per request. *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  ?title_attr:string ->
  ?url_attr:string ->
  ?snippet_attr:string ->
  app_id:string ->
  key:string ->
  endpoint:Uri.t ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the Algolia provider. [app_id], [key], [endpoint], and [net] are mandatory. *)
