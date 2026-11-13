(** Linkup — answer synthesis with citations, about $6/1k for [sourcedAnswer].

    Port of [src/seekwright/providers/linkup.py]. The endpoint answers in one of
    two shapes and this adapter has to know which one it asked for, so
    {!Linkup.output} is a type rather than a string compared at call time: the
    payload key that holds the prose, the list that holds the material, and the way
    the result cap is applied all follow from that choice.

    Endpoint: [POST https://api.linkup.so/v1/search] with the key as a bearer
    token.

    Two settings decide what a call here costs and they are the operator's, never
    the model's: [depth] because [deep] is a ~10x cost cliff ($0.05 against
    $0.006), and [output_type] because [sourcedAnswer] is the shape that buys the
    prose. Neither is a tool parameter — which is why the row carries them in
    [settings] and the tool surface stays three parameters wide.

    [fromDate] is the recency mapping here, and it is the one date computation in
    the adapter inventory: a {i timestamp}, where [freeserp] sends a bare date and
    [tavily] sends a window word. The clock is therefore injected, and the day
    counts are fixed — 30-day months, 365-day years — because recency is
    "published within the last {i n}", open-ended, with no [toDate] to agree a
    calendar boundary with.

    429 is the only quota row. Linkup prices a keyless x402 lane that this adapter
    never enters, so a 402 arriving at a bearer-keyed request is an unexpected
    status, not a spent account, and stays on the [HTTP 402] row: the same status
    means different things to [scrappa], [serper] and here, and the classes say so. *)

val name : string
(** ["linkup"], the config key and the [provider] every response names. *)

val endpoint : Uri.t
(** What is dialed: [https://api.linkup.so/v1/search]. *)

val policy_endpoint : Mcp_caps.Policy.endpoint
(** The same destination as a grant entry, so the factory builds the one allowlist
    entry this adapter can satisfy. *)

(** Which payload shape the request asks for. The row's [output_type] config key
    selects it through [Config.show_output_kind], whose two words are exactly the
    endpoint's own [outputType] values. *)
type output =
  | Sourced_answer  (** prose answer, with [sources[]] as its citations *)
  | Search_results  (** a result list, and no answer at all *)

val show_output : output -> string
(** The endpoint's spelling: [sourcedAnswer] or [searchResults]. *)

val age_days : Seekwright.Model.recency -> int
(** How far back [fromDate] reaches: 1, 7, 30 and 365 fixed days. *)

val format_utc : float -> string
(** [format_utc epoch] is that Unix timestamp as [%Y-%m-%dT%H:%M:%SZ], the format
    the endpoint documents — no timezone library, no [Local_time] dependency, and
    the same [civil_from_days] arithmetic [Seekwright_providers.Freeserp] carries. *)

val request_body :
  depth:string ->
  output:output ->
  from_date:string option ->
  Seekwright.Provider.search_query ->
  string
(** The request document. [from_date] is the {i computed} lower bound rather than
   the raw [recency], because the clock it came from is the adapter's, and taking
   the value here is what lets a test pin [fromDate] to an injected instant.
   [maxResults] goes upstream even though both parses cap as well: the endpoint
   sizes its own answer, and the parse is the guarantee the caller actually reads. *)

val parse_sources : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** The [sourcedAnswer] citation list: [name], [url], [snippet], [favicon]. The limit
    slices the upstream list before anything is dropped, so a record without a url
    still spends one of the slots — [sources] arrives already sized for the answer
    the endpoint wrote. *)

val parse_results : snippet_chars:int -> Yojson.Safe.t -> limit:int -> Seekwright.Provider.hit list
(** The [searchResults] list: [name], [url], [content], [favicon], [type]. There is
    {b no} slice: the
    walk continues until [limit] usable items are collected, skipping image rows,
    because an index page's unusable rows should not cost the caller results it
    asked for. Both parses title a record by its [name] and fall back to the url
    when there is none. *)

val answer : output:output -> Yojson.Safe.t -> string option
(** The prose [sourcedAnswer] writes over its own citations, and [None] for the
    [Search_results] shape whatever the payload holds: an answer in a payload the
    caller did not ask for is a field it was never promised. *)

val cost_for : cost_per_1k:float -> int -> float
(** Per-query cost in USD, flat: Linkup bills per request, so [max_results] does
    not scale it. The argument is ignored rather than absent because callers treat
    [cost_for] as the same duck-typed extra on every adapter. *)

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
(** The adapter as a provider value. [key] is mandatory: the x402 lane that would
    answer without one is a different surface than this adapter. [now] is injected
    because [fromDate] moves with every call — the factory hands in the clock its
    grant was built with, and a suite hands in an instant it can pin. [depth] and
    [output] come from the row's settings; [cost_per_1k] is reporting only, and the
    row's [default_cost] is the figure the factory builds with. *)
