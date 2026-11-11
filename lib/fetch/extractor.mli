(** The extraction-backend contract and the plumbing every backend shares.

    Port of [src/seekwright/extractors/base.py]. [fetch] pulls bytes off the
    network; turning them into text a model can read is the part most likely to
    be replaced. So it sits behind a named backend, picked by
    [fetch.extractor] and looked up in {!known_extractors} — swapping the
    engine is a config change, not a code change.

    A backend implements {!S}: a [name], the media types it can read, and an
    [extract] returning an {!extract_result}. {!Fetch.backend} is the
    first-class form the fetcher holds; {!of_module} packs a {!S} module into
    one. The JSON and table halves live in [Jsondoc] and [Tabledoc] for the
    same reason the Python original keeps them beside the package: a backend
    decides *that* a body is one of those and hands it over; the module owns
    what the document looks like to a caller.

    [trafilatura] and [pypdf] do not ride on this port: {!known_extractors}
    carries [stdlib] alone, and a PDF is refused through the type set rather
    than parsed — a backend lists only what its [extract] can read. *)

type extract_result = {
  text : string;
  title : string option;
  total_chars : int;
      (** Length of the full normalised extraction, in codepoints — the same
          coordinate system Python's [len] counts. *)

  path_addressable : bool;
      (** Whether [text] is a structure rendering whose lines [fetch]'s [path]
          selects. Only the extraction can say it, so it says it: the engine
          must not infer it from a character of page text — a Makefile whose
          first line is [$ make all] starts with the root character of a path
          and is not one. Set by the backend that walked the structure — a
          JSON document or a CSV table; every other page leaves it [false]. *)

}

exception Extraction_failed of string
(** The bytes could not be turned into text at all. The fetcher turns it into
the "cannot extract text: …" refusal; an empty extraction is a reportable
outcome, not an error. *)

module type S = sig
  (** What the fetcher checks a response's media type against *before*
      using the body, so it must be honest: an unreadable type listed here
      spends a download on a page that can never be read. *)

  val name : string
  val supported_types : string list
  (** [extract body content_type] extracts readable text from a fetched
      body, uncut. Sizing it for a caller is the fetcher's job
      ([Fetcher.window_text]): where to cut depends on who is asking.
      Raises [Extraction_failed] when the body cannot be read. *)

  val extract : string -> string option -> extract_result
end

type backend = {
  name : string;
  supported_types : string list;
  extract : string -> string option -> extract_result;
}
(** The first-class form the fetcher holds, one field per {!S} member. *)

val of_module : (module S) -> backend
(** [of_module (module E)] is the [backend] view of an [E] that implements
{!S}. *)

val known_extractors : string list
(** Every fetch extraction backend this build knows how to construct, by name.
Config validation rejects a [fetch.extractor] outside this set, exactly as
it rejects a provider name outside the router's registry — a name that
parses and does nothing is the failure mode both exist to remove. *)

(* {1 Media types} *)

val html_types : string list
val pdf_types : string list
val text_types : string list
(** The JSON family the backend claims: one-document types and the JSON
Lines stream types, [Jsondoc]'s two lists joined. *)

val json_types : string list
val table_types : string list
(** [Tabledoc.table_types]. *)

val supported_types : string list
(** The union every Python backend with its extra installed claimed — kept for
the derived-phrase tests, not for dispatch: the gate reads a backend's own
[supported_types]. *)

val media_type : string option -> string
(** The bare media type, lowercased, with parameters stripped. *)

val is_supported : string list -> string -> bool
(** [is_supported types kind] is whether a backend claiming [types] can read
[kind]. The one place the RFC 6839 rule sits: a [+json] type *is* a JSON
document whatever its prefix registers, so a backend reading
[application/json] reads [application/geo+json] with it. The fetcher runs
this before spending the body, so the claim stays the backend's. *)

val charset_of : string option -> string option
(** The declared charset, if the server bothered to send one. *)

val decode : string -> string option -> string
(** [decode body content_type] decodes a response body to text, preferring the
server's declared charset. Never raises: a page with a few mojibake
characters is still useful, whereas an exception loses the whole page over
one bad byte.

The declared charset is honoured for the encodings this port implements —
UTF-8, ASCII, ISO-8859-1 and Windows-1252 — and anything else is a header
problem, not a lost page: it falls through to UTF-8 the way an unknown
codec does in Python. Undecodable bytes become U+FFFD, one per bad byte
where Python replaces once per maximal bad subpart. *)

val sniffs_html : string -> bool
(** Treat a missing Content-Type as HTML only if the bytes look like it — the
head of the body, left-stripped, lowercased, starting at one of the two
document shapes. The rule belongs to the absent header, not to any one
engine. *)

val normalise : string -> string option -> extract_result
(** [normalise text title] collapses whitespace runs, caps blank-line runs,
strips, and measures — the one place the wire shape of an extraction is
decided, so two backends never disagree about what "the extracted text"
means. An empty [title] is [None], Python's [title or None]. *)

val json_extraction : string -> extract_result
(** A JSON body as the structure it is, or as its own text when it is not one.
[normalise] never runs here — its whitespace rules are for prose, and in a
JSON value the spaces are the data. *)

val table_extraction : string -> string -> extract_result
(** [table_extraction text kind] is a delimited body as the table it is, or as
its own text when it is not one. [normalise] never runs here either; in a
quoted cell the whitespace is the data. *)

val describe_types : string list -> string
(** A human phrase naming the media types a backend can read: [HTML, plain
text, JSON, CSV and PDF] for the full set. Derived rather than hardcoded,
because the phrase is model-facing — it appears in the refusal for a URL
the backend cannot read, and a backend swap must not leave that message
claiming a type the new one lacks. Families render in a fixed order; a
type no family claims is appended verbatim and sorted. *)

val select_passages : string -> string -> max_chars:int -> (int * string) list * int
(** [select_passages text query ~max_chars] picks the passages of a full
extraction that answer [query]. Returns [(spans, dropped)]: [(offset,
text)] pairs in document order, each offset indexing the *full* extraction
in codepoints, and the count of matching chunks the budget cut.

Tokens are word runs of the casefolded query, length >= 2, deduplicated
(Python's [\w] is Unicode-wide; this port carries the ASCII members plus
every non-ASCII codepoint, and [casefold] is the ASCII lowercasing
{!Utf8.ascii_lower} already records). Chunks are consecutive paragraphs
packed to 1500 characters, a lone paragraph over the mark hard-split. A
chunk scores by distinct query tokens; zero scores are never candidates.
Candidates are taken best-first — score, then position — while the budget
lasts, and the first that does not fit ends selection rather than letting
a smaller one queue-jump. Selected chunks are re-sorted by offset and
adjacent ones merged. *)
