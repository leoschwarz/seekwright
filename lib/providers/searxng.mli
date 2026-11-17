(** SearXNG — self-hosted metasearch instance via its JSON API.

    Requires an operator-provided instance URL configured to serve [format=json]. Keyless and free
    of per-query billing.

    Paginates up to {!max_pages} pages per search to satisfy result count. Continuation page
    failures degrade gracefully to partial results. Supports domains, recency, language, and safe
    search; country is unhonoured. *)

val name : string
(** ["searxng"], the config key and the [provider] every response names. *)

val max_pages : int
(** Maximum pages fetched per search request (3). *)

val search_uri : Uri.t -> Uri.t
(** [search_uri instance] appends [/search] to the instance base URI. *)

val make :
  cost_for:(int -> float) ->
  ?snippet_chars:int ->
  endpoint:Uri.t ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the SearXNG provider for the given instance endpoint. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses hits from [results[]]. *)
