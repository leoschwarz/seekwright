(** Serper.dev — raw Google SERP backend.

    Endpoint: [POST https://google.serper.dev/search] with [X-API-KEY] header.

    Pricing: the vendor bills 1 credit up to 10 results and 2 credits above — the factory's registry
    row for [serper] encodes that rule and hands this adapter the per-query figure. Supports domains
    via site operators, country ([gl]), language ([hl]), and recency ([tbs]). Safe search is
    unhonoured.

    402/429 indicates credit exhaustion or rate limit. *)

val name : string
(** ["serper"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** [https://google.serper.dev/search]. *)

val make :
  cost_for:(int -> float) ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the Serper provider. [cost_for], [key] and [net] are mandatory. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses hits from [organic[]]. *)
