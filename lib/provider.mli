(** Search provider adapter contract and shared adapter utilities.

    Defines the {!S} module signature that provider adapters implement, failure models, request
    constraints reporting, text truncation caps, and network access seams. *)

type search_query = Model.search_query
(** Search request delivered to an adapter. *)

(** {1 The failure an adapter reports} *)

type error_kind =
  | Failure
  | Quota
      (** [Failure] is Python's [ProviderError], [Quota] its [QuotaExhausted]. The engine branches
          on the split: a quota failure gates the name out of the {b fallbacks} for a cooldown,
          while an ordinary failure just moves the walk along. Nothing else reads it, so a provider
          that reports quota for a plain 500 both lies about its billing and benches itself. *)

type error = { provider : string; kind : error_kind; message : string; retryable : bool }
(** Carries enough detail to explain a failure, not enough to leak one. [message] is model-facing
    prose from the fixed vocabulary below — never a response body, a header, a URL or an underlying
    exception, because the request those errors echo carries this deployment's credentials.
    [retryable] is False for the auth row and for every quota row. *)

type name = string
(** A provider name, [backend] or [backend:flavour], as [Router.name] spells it. *)

val provider_error : ?retryable:bool -> provider:name -> string -> error
(** [provider_error ~provider message] is a {!Failure} with [retryable] true unless the caller says
    otherwise — the Python constructor. *)

val quota_exhausted : provider:name -> ?message:string -> unit -> error
(** [quota_exhausted ~provider ()] is the {!Quota} row with the default wording; a backend whose
    billing model has its own sentence passes it as [~message]. Always non-retryable: a spent quota
    is not a transient fault, and there is no cache to degrade to. *)

val render_error : error -> string
(** [render_error e] is [provider: message] — the one line Python's [str()] of a [ProviderError]
    carries, and the reason a leak test reads the whole failure rather than only its message field.
*)

val auth_error : provider:name -> error
(** The 401/403 row: [authentication rejected (check API key)], non-retryable. *)

val http_status_error : provider:name -> int -> error
(** The "any other [>= 400]" row: [HTTP <code>]. The code is the whole payload; the body that came
    with it is not. *)

val timeout_error : provider:name -> error
(** The [httpx.TimeoutException] row: [request timed out]. *)

val network_error : provider:name -> error
(** The [httpx.HTTPError] row: [network error]. *)

val transport_error : provider:name -> Mcp_caps.Error.t -> error
(** The two transport rows, from the failure a {!Net.t} grant answers with. [Timeout] is the
    operation bound; every other kind — an endpoint refused by the allowlist, a name that did not
    resolve, a TLS handshake that failed — is the [network error] row, because the contract has no
    finer wording.

    The grant's own message is {b never} copied. [Mcp_caps.Error] sanitises what it says, but it may
    still name the peer address it dialled, and the rule is that a provider failure carries only the
    contracted sentence. *)

val decode_json_object : provider:name -> string -> (Yojson.Safe.t, error) result
(** The last two rows of the Failures table, which share a message on purpose: a body that does not
    decode and a body that decodes to something that is not an object are the same wire failure.
    [malformed JSON response] is what the adapter reports; the body is dropped, never quoted.
    Without the non-object guard the parser below would index into a list or a scalar and raise
    something that is not a {!error}. *)

(** {1 Reporting the constraints an adapter cannot honour} *)

val ignored_constraints :
  search_query ->
  domains:bool ->
  dates:bool ->
  geo:bool ->
  language:bool option ->
  safety:bool ->
  string option
(** [ignored_constraints q ~domains ~dates ~geo ~safety] names in one sentence the filters in [q]
    that this adapter cannot send, or [None] when it can send them all. Nothing filters an incapable
    provider out before dispatch, so this sentence — which goes in [notice] — is the only thing
    between a caller that asked for a filter and the belief that it got one.

    [domains], [dates], [geo] and [safety] are mandatory, so a new constraint is answered at every
    adapter rather than defaulting to "honoured". [language] is [None] for the Python default: it
    keeps the geo bucket joined as [country/language], which is right for an adapter with no geo
    surface at all; [Some] splits the bucket so the sentence names only what really dropped. (Python
    spells that default as an optional keyword; OCaml cannot erase an optional argument whose result
    is itself an option, so "not answered" is written [~language:None] — the same visibility the
    four mandatory buckets ask for.) [safety] fires whenever [safe_search] is set at all —
    [Some false] is a request too, and a backend with no such parameter ignores it as completely as
    it ignores [Some true]. *)

val site_filtered_query : search_query -> string
(** Folds the domain filters into the query string as [site:] / [-site:] operators, for the
    Google-backed backends where the operators {i are} the interface. Using it counts as honouring
    domains, so such an adapter files no [domain] notice. A backend with a native filter field never
    calls this. *)

val truncate_snippet : string option -> int -> string option * int option
(** Clips a snippet at a sentence boundary where one falls inside the window, and returns it with
    the normalised length the cap received — the second value is what makes [max_snippet_chars]
    measurable from real traffic ([search.cap]), because the clip happens before anything is
    recorded. [None] text in, [None] out with no length: an upstream field documented as a string
    and not enforced as one is dropped, not raised. *)

val truncate_text : string option -> int -> string option * bool * int option
(** The same clip for an inline page extract, plus whether anything was cut: a caller that cannot
    tell a clipped extract from a short page cannot judge whether [fetch] would give it anything
    more. A whole-field [None] reports [false], since nothing was cut. *)

(** {1 Reading an upstream payload} *)

module Json : sig
  val members : Yojson.Safe.t -> (string * Yojson.Safe.t) list option
  val list : Yojson.Safe.t -> Yojson.Safe.t list option
  val string : Yojson.Safe.t -> string option
  val number : Yojson.Safe.t -> float option
  val field : string -> Yojson.Safe.t -> Yojson.Safe.t
  val string_field : string -> Yojson.Safe.t -> string option
  val number_field : string -> Yojson.Safe.t -> float option
  val is_true : Yojson.Safe.t -> bool

  val is_true_field : string -> Yojson.Safe.t -> bool
  (** The payload readers an adapter's parse writes with. A provider documents a field as a string
      and nothing enforces it, so every reader here answers [None] for "absent {i or} not that
      shape" — the same rule as Python's [isinstance] guards, and for the same reason: shape drift
      drops a field, it does not raise out of the engine's provider-error handling. [number] refuses
      a [Bool], as Python's [isinstance(value, bool)] arm does: a JSON [true] is not the number a
      [score] claims to be. [field] answers [Null] for a missing key or a non-object, which is what
      makes those readers chain instead of threading an option. *)
end

(** {1 Reaching the endpoint} *)

module Net : sig
  type t = {
    request :
      Mcp_caps.Authority.Net.request -> (Mcp_caps.Authority.Net.response, Mcp_caps.Error.t) result;
  }
  (** The one network operation an adapter has: exactly what a [Authority.Net.t] grant offers, with
      the grant's optional per-call byte ceiling left out because an adapter never lowers it.

      This is the seam the adapter suites drive, so it is a plain record rather than an abstract
      grant: {!of_grant} is the only producer in a running server, and a test hands in its own
      [request] to record what was sent and to answer with a canned body or a transport failure.
      That is the same position [httpx.MockTransport] holds in Python — the client is injected — and
      the audit claim is unchanged: an adapter dials one fixed endpoint, and the value it was handed
      refuses every other. *)

  val of_grant : Mcp_caps.Authority.Net.t -> t
  (** [of_grant grant] wraps an authority net grant into the network seam. *)
end

val policy_of_uri : Uri.t -> Mcp_caps.Policy.endpoint
(** [policy_of_uri uri] extracts the scheme, host, and port endpoint triple matching [uri]. *)

val redact_url : string -> string
(** [redact_url url] extracts the host part of [url] (or ["?"] if absent), stripping path,
    credentials, and query parameters to avoid log leaks. *)

val escape_path_segment : string -> string
(** [escape_path_segment s] percent-encodes all characters in [s] outside the unreserved set
    ([a-zA-Z0-9_.-~]). *)

type hit = { result : Model.result; uncapped_chars : int option }
(** One search hit, plus the pre-cap length of its snippet or text. *)

type outcome = {
  provider : string;
  results : hit list;
  answer : string option;
  cost_usd : float option;
  notice : string option;
}
(** Adapter outcome before engine attaches response metadata. *)

val to_provider_result : outcome -> Model.provider_result

(** {1 The adapter skeleton} *)

val take : int -> 'a list -> 'a list
(** [take n xs] is the first [n] of [xs], whole, in order, and [] for a non-positive [n]. Adapters
    slice the {i upstream} list before validating a record, so a record that fails to parse still
    spends one of the caller's [max_results] slots — that is what the caller asked the provider for.
*)

val check_status :
  provider:name ->
  ?quota:int list ->
  ?quota_message:string ->
  ?named:(int * error) list ->
  int ->
  (unit, error) result
(** The status mapping every REST adapter spells: a status in [named] is that pair's own error,
    checked first; otherwise 401/403 is the {!auth_error} row, a status in [quota] (default
    [[402; 429]]) is the {!quota_exhausted} row with the vendor's own sentence, any other [>= 400]
    is {!http_status_error}, and anything else is [Ok ()].

    The two arguments exist because the row boundaries are not the same everywhere: Tavily answers
    432 for a spent month, Linkup has no 402 at all, DeepSeek's 408 is its own request-body timeout
    rather than the [HTTP 408] a caller would read as a server fault, and a SearXNG instance that
    answers 401 is usually saying [format=json] is not enabled — a sentence an API key cannot act
    on. Naming those statuses is an argument, not a re-derivation of the branch order, which is
    where the [retryable] advice the engine branches on gets decided. *)

val map_records :
  list_path:string list ->
  url_field:string ->
  title_field:string ->
  snippet_field:string ->
  snippet_chars:int ->
  ?date:(Yojson.Safe.t -> string option) ->
  ?score:(Yojson.Safe.t -> float option) ->
  limit:int ->
  Yojson.Safe.t ->
  hit list
(** The search-backend record shape: [{ title; url; snippet }] with no [text], the snippet clipped
    to [snippet_chars]. [list_path] is the key path to the record list, because a vendor that nests
    ([data.results], [results.result]) is an argument and not another parse. [url_field] is [link]
    for the Google-backed vendors and [url] for the rest; [snippet_field] is [snippet], [content] or
    [description]. A record with no usable url or title is dropped — {!Json}'s readers answer [None]
    for a field the vendor documented as a string and did not enforce, and a hit with no url cannot
    be cited.

    [date] and [score] read the record rather than naming a field because the reading itself varies:
    Freeserp takes the first non-empty of [published_at] and [crawled_at], Serper takes [date] as it
    comes, and most vendors have neither. *)

val map_content_records :
  list_path:string list ->
  url_field:string ->
  title_field:string ->
  content_field:string ->
  content_chars:int ->
  ?snippet:string * int ->
  ?date:(Yojson.Safe.t -> string option) ->
  ?score:(Yojson.Safe.t -> float option) ->
  limit:int ->
  Yojson.Safe.t ->
  hit list
(** The content-backend record shape: [{ title; url; text }] with [snippet] [None], because filling
    both ships the same prose twice, and [text_truncated] set only when something was cut.
    [~snippet:(field, chars)] adds a second, separately-capped snippet beside the extract for a
    vendor that sends both. *)

val http_search :
  provider:name ->
  net:Net.t ->
  request:Mcp_caps.Authority.Net.request ->
  cost_for:(int -> float) ->
  parse:(Yojson.Safe.t -> limit:int -> hit list) ->
  notice:(search_query -> Yojson.Safe.t -> string option) ->
  ?status:(int -> (unit, error) result) ->
  ?check:(Yojson.Safe.t -> (unit, error) result) ->
  ?answer:(Yojson.Safe.t -> string option) ->
  ?decode:(string -> (Yojson.Safe.t, error) result) ->
  search_query ->
  (outcome, error) result
(** One request and the tail every REST adapter repeats: the {!Net.t} call, {!transport_error} on a
    grant failure, [~status] on the status line, {!decode_json_object} on the body, [~check] for a
    vendor that reports failure {i inside} a 200 (Anysearch's [code], Freeserp's [engine_fallback]),
    then the {!outcome} record with [parse]'s hits, [~answer]'s extract, [cost_for] applied to the
    caller's [max_results] and [notice]'s constraint report.

    [~status] defaults to {!check_status} with the provider's name; an adapter passes its own
    partial application when its statuses or its sentence differ, which is also how an adapter with
    a paged walk reports the same rows. [parse] and [notice] both take the decoded object: a report
    about upstream warnings can only be written from the body, and where the records sit is vendor
    shape. An adapter whose own logic sits {i before} the call — a query length ceiling, a folded
    query — keeps its [search] and calls this for the part that is not its own. [~decode] replaces
    {!decode_json_object} for a vendor that tolerates a 200 whose body is valid JSON but not an
    object. *)

(** The search provider module signature. *)
module type S = sig
  val name : string
  val cost_per_1k : float
  val cost_for : int -> float
  val search : search_query -> (outcome, error) result
  val aclose : unit -> unit
end

type t = (module S)
(** Provider instance packed as a first-class module. *)

val name : t -> string
val cost_per_1k : t -> float
val cost_for : t -> int -> float
val search : t -> search_query -> (outcome, error) result
val aclose : t -> unit

type session = { adapter : t; warmup : unit -> bool }
(** Optional session lifecycle wrapper for MCP-backed adapters. *)

val project_url : string
(** Project repository URL. *)
