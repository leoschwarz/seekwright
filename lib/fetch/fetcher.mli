(** Fetching a URL safely, behind the Net authority grant.

    Port of [src/seekwright/fetcher.py]'s [HttpFetcher] — the free primary of
    the fetch path. The URLs reaching this module are chosen by a language
    model, from text written by whoever controls the page it last read, so
    every guardrail here assumes the URL is hostile input.

    Two layers own the safety, and the split is the port's point
    (plans/seekwright-ocaml-port.md §1): the *address* policy — scheme shape,
    no embedded credentials, public-IP-only resolution bound to the actual
    connection — is the [Mcp_caps.Authority.Net] grant's validation, because
    the authority API cannot be asked for [file://] or a private address at
    all; this module owns what the grant cannot see — redirect re-validation,
    the download cap's per-type refusals, the type gate, image magic-number
    agreement and the response window. All HTTP goes through the grant; this
    module never names cohttp.

    The extraction backend is injected and required
    ([Extractor.of_module (module …)]): a default would import a backend at
    library-import time. The keyed/third-party fallbacks of the Python module
    (jina, scrappa, crawl4ai, tavily, linkup) are out of scope for v1, and
    there is no page cache (deferred by plan review).

    The fetcher is Eio direct style: [fetch] performs bounded I/O through the
    grant, so it runs in a fiber of the loop the grant was opened under — the
    same contract as every [Authority] operation. Each hop is bounded by the
    grant's per-operation timeout; the chain is bounded by [max_redirects]
    (Python's single 2× wall-clock budget over the chain is the engine's job
    in this port, P5). *)

(* The page records are [Seekwright_wire.Page]'s, re-declared here under the
   names this interface uses, so the two halves of the fetch path cannot drift
   and the layer between them has nothing to copy (style review M5). The
   equated-alias form is the one [lib/caps/policy.mli] already uses: one type,
   two names, the fields spelled out on both sides so each interface keeps its
   own field documentation — and a field that stops matching stops being a
   silent omission and becomes a type error. *)

type fetched_image = Seekwright_wire.Page.image = {
  media_type : string;
  (** The media type the bytes' own first bytes agreed with — never the
      server's header alone. *)

  body : string;
}

type fetched_page = Seekwright_wire.Page.page = {
  url : string;
  (** Where the fetch actually landed, after any redirects. *)

  title : string option;
  text : string;
  content_type : string option;
  status_code : int;
  truncated : bool;
  total_chars : int;
  (** Length of the full extraction in codepoints, whatever the window. *)

  path_addressable : bool;
  (** Whether [text] is a structure rendering whose lines [path] selects —
      carried out of the extraction, never inferred from page text. *)

  image : fetched_image option;
}

(** {1 Refusals and failures} *)

type refusal =
  | Url_blocked of string
      (** The URL as written was refused before any request was sent — the one
          refusal a caller can act on by choosing a different URL. The REST
          projection reports it apart from a mid-flight one. *)

  | Redirect_blocked of string
      (** A redirect target was refused with a request already in flight. A
          sibling of [Url_blocked], not a case of it: the engine's
          "refused the written URL" test must not catch a redirect refusal. *)

  | Blocked of string
      (** Any other policy refusal (cap, type gate, downgrade, redirect cap).
          Not retryable: the answer will be the same next time. *)

type error =
  | Refusal of refusal
  | Failed of string
      (** A transport or HTTP-status failure ([Failed "HTTP 404"] is an error
          page, whose body is not content). Retryable, unlike a refusal. *)

type t

val fetch :
  ?chain_timeout:Eio.Time.Timeout.t ->
  t ->
  string ->
  offset:int ->
  max_chars:int option ->
  (fetched_page, error) result
(** [fetch t url ~offset ~max_chars] fetches, extracts and windows to
    [[offset, offset + max_chars)] in codepoints. [max_chars = None] means the
    fetcher's own configured default; {!total_chars} always reports the full
    extraction, whatever the window.

    [?chain_timeout] is the budget for the {b whole} redirect chain, on top of
    the grant's per-operation bound, which restarts at every hop. Without it a
    deployment that allows ten redirects can spend ten timeouts on one page, and
    Python's reader — which measures one budget over the chain — has no OCaml
    counterpart. It is a [Timeout.t] rather than a number of seconds because
    measuring it needs the monotonic clock, and this module deliberately holds
    none: the caller that built the grant has the clock and builds the timeout
    with it. An expired budget is a {b value}, not an exception: the chain's
    fiber is cancelled and [fetch] answers [Error (Failed "request timed out")],
    the same sentence the grant's own per-hop timeout maps to, so a caller cannot
    tell which bound expired and never has to. A cancellation that comes from
    outside — the caller's switch closing, its own timeout firing — is {b not}
    caught here and keeps unwinding. *)

(** {1 Construction} *)

val default_user_agent : string

val make :
  net:Mcp_caps.Authority.Net.t ->
  extractor:Extractor.backend ->
  ?max_download_bytes:int ->
  ?max_text_chars:int ->
  ?max_redirects:int ->
  ?allow_images:bool ->
  ?user_agent:string ->
  unit ->
  t
(** [make ~net ~extractor ()] is the free primary: the grant is the only network
    path ([Policy.with_public_web] in production), the backend is injected with
    no default. [max_download_bytes] is enforced on the grant-delivered body —
    the grant's own ceiling is the streaming bound and is set where the grant
    is built — so a document cut at the cap is refused where a record stream
    keeps its head, exactly as the Python reader's sliced buffer does. *)

(** {1 What may raise, and where it turns back into a value}

    Every function in this interface answers with a value. The port's rule, said
    once here because this is the interface that used to break it:

    - An {b outcome a caller can act on} is a [result]. A refused URL, a denied
      host, a body over the cap, an expired budget — [Refusal] and [Failed], and
      the engine's [resolve] wrappers turn those into [Fetch_refused] /
      [Fetch_failed] for the wire.
    - An {b exception} is for what no caller can act on at the point it happens:
      the pure grammars ([Jsondoc.Path_syntax], [Tabledoc.No_rows],
      [Router.Route_refused]) and what has to unwind out of the middle of an Eio
      body ([Policy_net.Refusal], [Extractor.Extraction_failed]). Both kinds are
      converted at a boundary the caller chose, never at the raise.

    [Fetcher] itself raises nothing. It used to carry [exception Url_blocked]
    beside the [Url_blocked] constructor of [refusal] — the same name in the two
    sum types that look identical in a pattern, one of them invisible in the type
    of the function that raised it — and the raising [validate_url] had no caller
    outside its own tests: the chain reads [validate_url_opt]. The two are now
    one function that returns. A grep for [^exception ] in [lib/*.mli] is meant
    to answer "which exceptions cross this boundary?", and this file's answer is
    none. *)

val validate_url : string -> (string, string) result
(** Check scheme and shape and normalise: scheme lowercased, empty path
becoming [/], fragment dropped, query kept. Credentials are refused rather
than stripped: a model constructing [http://user:pass@host/] has been told
to exfiltrate something or is replaying a secret it read on a page. The
port is settled here rather than at connect time, because a parser that
accepts [:99999] silently fails later, past every handler that maps a
refusal onto a refusal row. *)

val window_text : string -> offset:int -> max_chars:int -> string * bool
(** [window_text text ~offset ~max_chars] slices the window
[[offset, offset + max_chars)] out of an extraction, returning
[(window, more_remains)]. The ["\n\n[...]"] marker is appended after
slicing, so the offsets a caller sees — and the [offset] it passes back to
continue — always index the un-marker'd extraction. The cut prefers a
paragraph break in the back half of the budget; a window reaching the end
of the page is returned whole; an offset past the end returns empty text
but still flags [more_remains]. *)

val uncapped : int
(** The [max_chars] value meaning "no cap". *)

val resolved_cap : int -> int option -> int
(** [resolved_cap default max_chars]: [None] means the fallback's own
configured default. *)

val image_types : string list
(** The image media types this server will hand to a caller, and the only ones
it names: the four the MCP SDK's image content block maps. [image/svg+xml]
is deliberately absent — an SVG is a document that can carry script — and
[image/jpg] because it is not a registered type. *)

val sniff_image_type : string -> string option
(** Which member of {!image_types} these bytes are, from their own first
bytes. The header's media type comes from the party being guarded against,
while the string written into an image block is what the caller's decoder
trusts, so the two have to be checked against each other. Magic numbers,
not a decoder: this process never opens the image. *)
