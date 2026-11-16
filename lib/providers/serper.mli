(** Serper.dev — raw Google SERP backend.

    Endpoint: [POST https://google.serper.dev/search] with [X-API-KEY] header.

    Pricing: bills 1 credit when [max_results <= 10], and 2 credits above 10. Supports domains via
    site operators, country ([gl]), language ([hl]), and recency ([tbs]). Safe search is unhonoured.

    402/429 indicates credit exhaustion or rate limit. *)

val name : string
(** ["serper"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** [https://google.serper.dev/search]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** Policy grant destination matching {!endpoint}. *)

val credit_over : int
(** Result threshold above which 2 credits are charged (10). *)

val make :
  ?cost_per_1k:float ->
  ?snippet_chars:int ->
  key:string ->
  net:Seekwright.Provider.Net.t ->
  unit ->
  Seekwright.Provider.t
(** Constructs the Serper provider. [key] and [net] are mandatory. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD, accounting for the credit-doubling threshold. *)

val parse : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** Parses hits from [organic[]]. *)
