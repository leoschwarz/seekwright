(** The provider contract: what an adapter owes, and the machinery that promise names.

    Port of [src/seekwright/providers/base.py] plus the rules of
    [docs/reference/provider-contract.md]. Python states the contract as a
    [runtime_checkable] Protocol — "a class that has the members *is* a
    provider" — and this module states it as {!S}, a module type: an adapter
    that is missing a member is a compile error rather than a runtime
    [isinstance] surprise, which is the point of porting it.

    What lives here is the contract and the shared helpers a contract needs:
    the failure type and its status-code mapping, the constraint report an
    adapter that cannot honour a filter must file, the snippet and text caps,
    and the one operation an adapter may use to reach its endpoint ({!Net.t}).
    Dispatch, retries, the health board and the per-name registry stay in the
    engine (P5), and the six places a *name* gets wired stay in config and the
    factory (P3, P5) — an adapter never decides whether it is enabled.

    Two Python members are deliberately absent. [warmup] belongs to the
    MCP-backed adapters only (plans/seekwright-ocaml-port.md, open question 3)
    and no such adapter exists in this tree yet, and a GADT branch nothing
    constructs is a warning, so it is not stubbed. [cost_for] is a `getattr`
    extra in Python and a required member here: every adapter in the tree
    defines it, and one more member of {!S} costs an adapter one line. *)

type search_query = Model.search_query
(** The request an adapter is handed. Exactly [query], [max_results],
    [include_domains], [exclude_domains], [country], [language], [recency] and
    [safe_search]: adding a field is a change to every adapter. *)

(** {1 The failure an adapter reports} *)

type error_kind = Failure | Quota
(** [Failure] is Python's [ProviderError], [Quota] its [QuotaExhausted]. The
    engine branches on the split: a quota failure gates the name out of the
    {b fallbacks} for a cooldown, while an ordinary failure just moves the walk
    along. Nothing else reads it, so a provider that reports quota for a plain
    500 both lies about its billing and benches itself. *)

type error = {
  provider : string;
  kind : error_kind;
  message : string;
  retryable : bool;
}
(** Carries enough detail to explain a failure, not enough to leak one.
    [message] is model-facing prose from the fixed vocabulary below — never a
    response body, a header, a URL or an underlying exception, because the
    request those errors echo carries this deployment's credentials.
    [retryable] is False for the auth row and for every quota row. *)

type name = string
(** A provider name, [backend] or [backend:flavour], as [Router.name] spells it. *)

val provider_error : ?retryable:bool -> provider:name -> string -> error
(** [provider_error ~provider message] is a {!Failure} with [retryable] true
    unless the caller says otherwise — the Python constructor. *)

val quota_exhausted : provider:name -> ?message:string -> unit -> error
(** [quota_exhausted ~provider ()] is the {!Quota} row with the default
    wording; a backend whose billing model has its own sentence passes it as
    [~message]. Always non-retryable: a spent quota is not a transient fault,
    and there is no cache to degrade to. *)

val render_error : error -> string
(** [render_error e] is [provider: message] — the one line Python's [str()] of a
    [ProviderError] carries, and the reason a leak test reads the whole failure
    rather than only its message field. *)

val auth_error : provider:name -> error
(** The 401/403 row: [authentication rejected (check API key)], non-retryable. *)

val http_status_error : provider:name -> int -> error
(** The "any other [>= 400]" row: [HTTP <code>]. The code is the whole payload;
    the body that came with it is not. *)

val timeout_error : provider:name -> error
(** The [httpx.TimeoutException] row: [request timed out]. *)

val network_error : provider:name -> error
(** The [httpx.HTTPError] row: [network error]. *)

val transport_error : provider:name -> Mcp_caps.Error.t -> error
(** The two transport rows, from the failure a {!Net.t} grant answers with.
    [Timeout] is the operation bound; every other kind — an endpoint refused by
    the allowlist, a name that did not resolve, a TLS handshake that failed —
    is the [network error] row, because the contract has no finer wording.

    The grant's own message is {b never} copied. [Mcp_caps.Error] sanitises what
    it says, but it may still name the peer address it dialled, and the rule is
    that a provider failure carries only the contracted sentence. *)

val decode_json_object : provider:name -> string -> (Yojson.Safe.t, error) result
(** The last two rows of the Failures table, which share a message on purpose:
    a body that does not decode and a body that decodes to something that is
    not an object are the same wire failure. [malformed JSON response] is what
    the adapter reports; the body is dropped, never quoted. Without the
    non-object guard the parser below would index into a list or a scalar and
    raise something that is not a {!error}. *)

(** {1 Reporting the constraints an adapter cannot honour} *)

val ignored_constraints :
  search_query ->
  domains:bool ->
  dates:bool ->
  geo:bool ->
  language:bool option ->
  safety:bool ->
  string option
(** [ignored_constraints q ~domains ~dates ~geo ~safety] names in one sentence
    the filters in [q] that this adapter cannot send, or [None] when it can send
    them all. Nothing filters an incapable provider out before dispatch, so this
    sentence — which goes in [notice] — is the only thing between a caller that
    asked for a filter and the belief that it got one.

    [domains], [dates], [geo] and [safety] are mandatory, so a new constraint is
    answered at every adapter rather than defaulting to "honoured". [language]
    is [None] for the Python default: it keeps the geo bucket joined as
    [country/language], which is right for an adapter with no geo surface at
    all; [Some] splits the bucket so the sentence names only what really
    dropped. (Python spells that default as an optional keyword; OCaml cannot
    erase an optional argument whose result is itself an option, so "not
    answered" is written [~language:None] — the same visibility the four
    mandatory buckets ask for.) [safety] fires whenever [safe_search] is set at
    all — [Some false] is a request too, and a backend with no such parameter
    ignores it as completely as it ignores [Some true]. *)

val site_filtered_query : search_query -> string
(** Folds the domain filters into the query string as [site:] / [-site:]
    operators, for the Google-backed backends where the operators {i are} the
    interface. Using it counts as honouring domains, so such an adapter files no
    [domain] notice. A backend with a native filter field never calls this. *)

val truncate_snippet : string option -> int -> string option * int option
(** Clips a snippet at a sentence boundary where one falls inside the window,
    and returns it with the normalised length the cap received — the second
    value is what makes [max_snippet_chars] measurable from real traffic
    ([search.cap]), because the clip happens before anything is recorded.
    [None] text in, [None] out with no length: an upstream field documented as
    a string and not enforced as one is dropped, not raised. *)

val truncate_text : string option -> int -> string option * bool * int option
(** The same clip for an inline page extract, plus whether anything was cut: a
    caller that cannot tell a clipped extract from a short page cannot judge
    whether [fetch] would give it anything more. A whole-field [None] reports
    [false], since nothing was cut. *)

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
  (** The payload readers an adapter's parse writes with. A provider documents a
      field as a string and nothing enforces it, so every reader here answers
      [None] for "absent {i or} not that shape" — the same rule as Python's
      [isinstance] guards, and for the same reason: shape drift drops a field, it
      does not raise out of the engine's provider-error handling. [number]
      refuses a [Bool], as Python's [isinstance(value, bool)] arm does: a JSON
      [true] is not the number a [score] claims to be. [field] answers [Null] for
      a missing key or a non-object, which is what makes those readers chain
      instead of threading an option. *)
end

(** {1 Reaching the endpoint} *)

module Net : sig
  type t = {
    request :
      Mcp_caps.Authority.Net.request ->
      (Mcp_caps.Authority.Net.response, Mcp_caps.Error.t) result
  }
  (** The one network operation an adapter has: exactly what a
      [Authority.Net.t] grant offers, with the grant's optional per-call byte
      ceiling left out because an adapter never lowers it.

      This is the seam the adapter suites drive, so it is a plain record rather
      than an abstract grant: {!of_grant} is the only producer in a running
      server, and a test hands in its own [request] to record what was sent and
      to answer with a canned body or a transport failure. That is the same
      position [httpx.MockTransport] holds in Python — the client is injected —
      and the audit claim is unchanged: an adapter dials one fixed endpoint, and
      the value it was handed refuses every other. *)

  val of_grant : Mcp_caps.Authority.Net.t -> t
  (** [of_grant grant] is the production wiring: the adapter's traffic goes
      through the endpoint allowlist the grant was built with
      ([Policy.with_endpoints]), so "what may this provider reach" is answered
      where the grant is built, not in the adapter (plans/seekwright-ocaml-port.md
      §1). The operation bound is the grant's too — [Authority.with_operation_timeout]
      — which is why no adapter takes a timeout of its own the way the Python
      [httpx] call does. *)
end

(** {1 Naming an endpoint, and reducing one} *)

val policy_of_uri : Uri.t -> Mcp_caps.Policy.endpoint
(** [policy_of_uri uri] is the same destination in the grant's words:
    [Mcp_caps.Policy.with_endpoints] pins scheme, host and an explicit port, and
    this is the one place a URI is read into that triple. An adapter's endpoint
    and the entry the factory allows its grant to reach are the {i} same fact
    because both come from here — two spellings of one destination are what drift
    the first time either is edited (plans/ocaml-finalisation.md, F4.1).

    A URI with no host gives an endpoint with no host, which every grant policy
    refuses to connect to: a config-derived destination ([searxng]'s instance, an
    [exa] override) is checked where it is read, by the registry, and this stays
    a total derivation. *)

val redact_url : string -> string
(** [redact_url url] is the URL's host and nothing else — the oracle's
    [urlsplit(url).hostname or "?"], the same reduction the fetch log's [host]
    field is built with. Every line that names a URL in a log event or a
    provider error goes through it, and it is load-bearing for [serpapi], the one
    documented request shape that puts an API key in the query string: a key
    cannot survive a reduction to a host. *)

val escape_path_segment : string -> string
(** [escape_path_segment s] is [s] with every byte outside the URI unreserved set
    percent-encoded: the oracle's [quote(value, safe="")], which is {i} narrower
    than [Uri.escape] — that one keeps sub-delims like [?] and [&] literal, and a
    path segment that keeps them is a segment that changes meaning. A value from
    config that goes into a path ([algolia]'s [index]) goes through this on its
    way to the request. *)

(** {1 What an adapter returns} *)

type hit = {
  result : Model.result;
  uncapped_chars : int option
}
(** One search hit, plus the pre-cap length of its snippet or text. Python hangs
    that number on [Result._uncapped_chars] — private, so it cannot reach the
    wire. An OCaml record has no private field, and the wire model must not
    carry one, so the measurement rides {i beside} the result on the provider
    boundary and the engine logs it as [search.cap]; {!to_provider_result} is
    where it is dropped. *)

type outcome = {
  provider : string;
  results : hit list;
  answer : string option;
  cost_usd : float option;
  notice : string option;
}
(** [ProviderResult]: what an adapter returns before the engine adds response
    metadata. [provider] is this adapter's own name, always set — every response
    names the provider that served it. *)

val to_provider_result : outcome -> Model.provider_result
(** The wire-model view, with the {!hit} wrapper dropped. *)

(** {1 The contract, and a provider as a value} *)

module type S = sig
  val name : string
  val cost_per_1k : float
  val cost_for : int -> float
  val search : search_query -> (outcome, error) result
  val aclose : unit -> unit
end
(** The [SearchProvider] protocol. [name] matches the config key; [cost_per_1k]
    is reporting only — it corrects the figure [--check --live] prints and
    nothing routes on it; [cost_for] is the per-query figure a caller reads when
    a deployment wants one, and flat-priced adapters ignore its argument;
    [search] is the whole job; [aclose] exists because the MCP-backed adapters
    own a session, and an HTTP adapter's is a documented no-op — the grant
    belongs to the server, not to the adapter, so closing it would break its
    siblings.

    A failure is a returned [Error], not a raised exception: Python's [raise
    ProviderError] and its [except] arms become this [Error] channel, which is
    what keeps the engine's fallback walk in one control-flow shape. *)

type t = (module S)
(** A provider as a value: what the engine's registry holds under its name. *)

val name : t -> string
val cost_per_1k : t -> float
val cost_for : t -> int -> float
val search : t -> search_query -> (outcome, error) result
val aclose : t -> unit
(** The accessors, so a caller holds a {!t} rather than a module it has to open. *)

(** {1 Shared constants} *)

val project_url : string
(** What a provider is asked to identify us with ([freeserp]'s [website]
    parameter), and the same constant the fetch path's User-Agent is built from
    (P6, P8). [seekwright.__init__.PROJECT_URL] in the oracle; one place until
    the surface printer pins it. *)
