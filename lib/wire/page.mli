(** One owner for the page records both halves of the fetch path speak.

    [Seekwright_fetch.Fetcher] produces a fetched page and [Engine.Fetch]
    consumes one: the engine attaches the response metadata — the notice, the
    route that served, the journal line — around the page the fetcher read.
    Python has one class for that, [fetcher.FetchedPage], and both modules import
    it. The port declared the record twice and wrote a copier between them,
    [Factory.page_of]: nine qualified fields plus a nested copy for the image, so
    a field added to one record and not the other compiled happily — the copier
    writes the second one by hand
    (plans/reviews/2026-11-12-style-review.md, M5).

    The records live here, stdlib-only, and each interface renames them with an
    {i equated} alias — [type page = Page.page = { … }] — the pattern
    [lib/caps/policy.mli] already uses: each interface keeps its own field
    documentation and its own name, one type sits under both, and a field missing
    on one side stops being a silent omission and becomes a type error.

    What did {b not} move is the error half. [Fetcher.refusal]/[Fetcher.error]
    and [Engine.Fetch.fetch_error] are different vocabularies on purpose — a
    [Fetcher.Blocked] becomes a [Fetch_blocked], a [Failed] becomes a provider
    error carrying the route's name — so [Factory.error_of] stays a translation. *)

type image = {
  media_type : string;
  (** The media type the body's own first bytes agreed with — never the server's
      header alone. *)

  body : string;
  (** The bytes, whole. *)
}
(** A page that {i is} an image: nothing was extracted and the bytes are the
    content. Python's [FetchedImage]. *)

type page = {
  url : string;
  (** Where the fetch actually landed, after any redirects. *)

  title : string option;
  text : string;
  (** Extracted text, {b unescaped}: the engine runs the escape pass once, at the
      point the page is settled, and page text is untrusted third-party content. *)

  content_type : string option;
  (** The media type this server read the body as. *)

  status_code : int;
  truncated : bool;
  total_chars : int;
  (** Length of the full extraction in codepoints, whatever the window held. *)

  path_addressable : bool;
  (** Whether [text] is a structure rendering whose lines [path] selects —
      carried out of the extraction, never inferred from page text. *)

  image : image option;
}
(** One fetched and extracted page, before response metadata is attached.
    Python's [FetchedPage]. *)
