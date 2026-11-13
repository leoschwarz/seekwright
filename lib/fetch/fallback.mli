(** The shared half of a remote fetch fallback: the failure vocabulary, the
    vendor seam, and the JSON readers the envelopes are parsed with.

    A fallback fetches {i through a vendor} — a reader, a renderer, or a
    scraper — instead of over this server's own socket. Five things are the
    same for all five vendors, and this module owns exactly those:

    - {!error}, the four-way failure split. Python raises [UrlBlocked] (a
      [FetchBlocked] subclass), [ProviderError(retryable=False)] for an auth
      rejection, [QuotaExhausted], and [ProviderError] for everything else;
      the engine branches on the first three differently, so the sum keeps
      them apart and the factory turns each into the engine's [fetch_error].
    - {!net}, the request seam. Production hands in a bounded
      [Mcp_caps.Authority.Net] grant pinned to one vendor endpoint
      ([Grants.grant_of_endpoint] in the factory — never a web-wide variant,
      and a fallback's grant is public-only whatever
      [fetch.allow_private_addresses] says); a test hands in its own [request]
      to record what would have gone out. Same position [httpx.MockTransport]
      holds in the Python suites.
    - the transport mapping: the grant's [Timeout] is Python's
      [httpx.TimeoutException] row ("request timed out") and every other
      grant failure is its [httpx.HTTPError] row ("network error"). The
      grant's own message is never copied: it may name the peer, and the
      contracted sentence is all a caller should learn.
    - the JSON envelope readers — the [isinstance] guards Python wraps every
      vendor field in, so shape drift drops a field rather than raising.
    - {!windowed}, the tail every [_to_page] shares: [window_text] under
      [resolved_cap], and the two fields no vendor can honestly fill —
      [content_type] (a vendor returns markdown or prose, not a media type;
      guessing [text/html] is the guess the Python comments refuse) and
      [path_addressable] (the envelope is parsed here and never leaves, so a
      [path] could never select inside the page the caller named) — set once
      for everyone.

    What lives in each fallback's own module ([Fallback_jina] and siblings)
    instead is only that vendor: its endpoint constant, request shape, status
    arms, and envelope mapping. *)

(** {1 The failure vocabulary} *)

type error =
  | Url_blocked of string
      (** The target URL was refused before anything was sent — the oracle's
          [UrlBlocked]. The one failure the caller can act on by choosing a
          different URL, and the only one the REST projection reports as a
          refusal (400) rather than a failure. *)
  | Rejected of string
      (** The vendor refused {i this deployment}: 401/403. Not retryable:
          retrying with the same credential gets the same answer. *)
  | Quota of string
      (** The vendor's account or IP meter is spent (402/429/432). The engine
          benches the name out of the fallbacks for a cooldown on this one,
          which is why it is its own constructor and not a [Failed]. *)
  | Failed of string
      (** Everything else: an error status ("HTTP 500"), a vendor that says
          the crawl itself failed, an undecodable body, a timeout, a network
          fault. Retryable, as Python's [ProviderError] is. *)

type page = Seekwright_wire.Page.page
(** The page record — the same {!Seekwright_wire.Page.page} the local reader
    produces, so the engine windows and escapes one page type whatever route
    produced it. *)

(** {1 The vendor seam} *)

type net = {
  request :
    max_response_bytes:int option ->
    Mcp_caps.Authority.Net.request ->
    (Mcp_caps.Authority.Net.response, Mcp_caps.Error.t) result
}
(** The one network operation a fallback has: what an [Authority.Net] grant
    offers, with its optional byte ceiling made an explicit argument because a
    record field cannot carry an optional label. [Fallback.of_grant] is the
    only producer in a running server. *)

val of_grant : Mcp_caps.Authority.Net.t -> net
(** Wrap the production grant — the endpoint allowlist and the operation bound
    live in it, which is why no fallback module takes a timeout argument for
    the {i transport}; the per-vendor timeout each sends (Tavily's request
    field) is a different number. *)

val transport_error : Mcp_caps.Error.t -> error
(** [transport_error caps_error]: the grant's [Timeout] becomes
    "request timed out" and every other grant failure becomes "network
    error", the two httpx rows the Python fallbacks raise. The grant's own
    message is never copied: it may name the peer it dialled, and the
    contracted sentence is all a caller should learn. *)

val malformed : unit -> error
(** [Failed "malformed JSON response"] — the one sentence Python uses for a
    body that does not decode and a body that decodes to a non-object alike:
    either way the vendor did not answer as documented, and the body is
    dropped, never quoted. *)

(** {1 The payload readers}

    Every reader answers [None] for "absent {i or} not that shape", the
    [isinstance] rule Python's [_to_page] methods are written with: a field a
    vendor documents as a string and does not enforce is dropped, not an
    error. *)

module Json : sig
  val decode_object : string -> (Yojson.Safe.t, error) result
  (** [Ok] only for a body that decodes {i and} is a JSON object — the
      non-object guard Python writes before indexing into [body]. *)

  val field : string -> Yojson.Safe.t -> Yojson.Safe.t
  (** [Null] for a missing key or a non-object. *)

  val string_field : string -> Yojson.Safe.t -> string option

  (** [isinstance(status, int)]: a JSON float in a status field is drift,
      not a status. *)
  val int_field : string -> Yojson.Safe.t -> int option

  val list_field : string -> Yojson.Safe.t -> Yojson.Safe.t list option

  val is_false : Yojson.Safe.t -> bool
  (** Exactly JSON [false], which is what Python's [body.get(k) is False]
      tests: a missing or null flag is not a reported failure. *)
end

(** {1 The shared page tail} *)

val windowed :
  string ->
  url:string ->
  max_text_chars:int ->
  offset:int ->
  max_chars:int option ->
  title:string option ->
  status_code:int ->
  page
(** [windowed text ~url ~max_text_chars ~offset ~max_chars ~title ~status_code]
    windows the extraction the way the local reader windows its own — the
    offsets a caller sees index the whole text, and [total_chars] reports it
    whatever the window — and sets [content_type = None] and
    [path_addressable = false] with the reasons stated above. A vendor whose
    page that itself landed elsewhere passes its own [url]; these five pass
    the target. *)
