(** JSON documents on the fetch path: what counts as one, how one is rendered,
    and how part of one is addressed.

    Port of [src/seekwright/jsondoc.py]. A JSON page is extracted as one line
    per node, each labelled with the path that addresses it, so the document
    arrives as its own map: [total_chars], [offset] and the [[...]] marker keep
    their meaning, [query] still selects by terms, and [path] selects by
    structure. A line's path is the exact string a caller passes back as
    [path], which is why it is absolute and printed on every line rather than
    implied by indentation, and why {!parse_path} reads the same syntax
    {!render_json} writes. *)

type key =
  | Name of string
      (** A member addressed by name. *)

  | Ordinal of int
      (** A member addressed by position. *)

type step =
  | Key of string
      (** One member of an object: [.name] or [["a b"]]. *)

  | Position of int
      (** One element of an array: [[3]]. *)

  | Every
      (** Every member at this level, whatever it is called: [[*]]. *)

  | Bounds of int option * int option
      (** A slice of an array: [[a:b]], either bound absent meaning the array's
          own end. *)

exception Path_syntax of string
(** A [path] this grammar cannot express. A distinct exception so the engine
can answer it as a refusal rather than as a fetch failure: the caller wrote
something unreadable, and that is known before any request goes out. *)

val json_document_types : string list
(** The media types that name one JSON document, written out because there are
only two of them and the difference from a stream is a decision, not a
detail. *)

val jsonl_types : string list
(** The JSON Lines types: JSON, but a stream of records rather than one
document. They ride with the JSON family so a backend claims them and hands
the body back as text instead of refusing the download, and they are held
out of {!is_json_document_media} because a stream cut mid-record still has
whole records at its head, where a document cut in the middle has nothing. *)

val max_depth : int
(** How deep {!render_json} expands a document, counting the root as zero.
Real documents measured in this work sit under ten; past a hundred the path
each line carries is longer than the value it labels. *)

val max_render_ratio : int
(** How much larger than the body {!render_json} is allowed to make it. Every
line carries its whole path, so the cost of a rendering is a function of
the document's shape, not of its bytes. *)

val min_render_chars : int
(** The floor under that budget, so that no small document is ever cut. *)

val is_json_document_media : string -> bool
(** Whether a media type names one JSON *document* rather than a stream of
them. The fetcher needs the distinction for a body it had to cut at
[fetch.max_download_bytes]: a document severed in the middle is neither a
document nor readable in part, while a record stream cut mid-record still
has whole records at its head. The suffix carries the vendor types: in
[application/vnd.foo+json] the prefix says whose document it is, the suffix
what syntax, and parsing only cares about the syntax. *)

val is_json_media : string -> bool
(** Whether a media type names a JSON body: one document, or a stream of them. *)

val sniffs_json : string -> bool
(** Treat a missing Content-Type as JSON only if the bytes look like it.
Mirrors [sniffs_html]: only the two shapes a JSON *document* starts with
count. A body beginning with a digit or a quote is a bare JSON value, and
guessing that from unlabelled bytes is how a CSV of numbers becomes a
document. *)

val child_path : string -> key -> string
(** The path of one member of a container, in the syntax {!parse_path} reads.
A name that [child_path] cannot write bare is quoted through JSON, so a key
holding a dot, a space or a quote round-trips: the path is a caller's
argument, so it has to be re-readable, not pretty. *)

val json_string : string -> string
(** One string as compact JSON with Unicode left raw — the leaf spelling
[json.dumps(..., ensure_ascii=False)] writes — so a rendered line stays one
line. {!Tabledoc} writes its cells with it. *)

val render_json : string -> string option
(** Render a JSON document as one line per node: [[<path>  <value>]]. A
container renders as its own header line naming its size —
[$  object(4)] then [$.items  array(120)] — before its members, so the
shape is legible in the first screenful, and [array(120)] tells the caller
how far [$.items[0:5]] is from the end. A leaf renders as compact JSON.

Two cuts bound the rendering, both printing a line naming where they fell:
{!max_depth} on nesting, and {!max_render_ratio} times the body's length on
size. Depth alone leaves the wide-under-the-cap shape unbounded, since a
path label per leaf is a cost the document's *shape* sets. The walk is
bounded by the same budget: a container goes back onto the stack as one
frame read one member at a time, so the walk never runs ahead of what has
been printed.

Returns [None] when the body is not one document this function can walk —
a trailing-comma pseudo-JSON API, an HTML error page served under
[application/json], or a JSON Lines stream — and the caller then answers
with the body as text. *)

val parse_path : string -> step list
(** Read a path selector: [$.items[0].name], [$.items[*].id], [$.items[2:9]].
This is the subset of JSONPath the tree can honour: [$] for the document,
[.name] and [["name"]] for an object member, [[3]] for an array element,
[[*]] for every member at that level, and [[a:b]] for a slice of an array.
Filters and recursive descent need a library; [query] already covers the
searching half of a filter over a page in hand. A leading [$] is optional,
because a caller reading a line of the rendering already holds a path that
starts with it. *)

val select_paths : string -> string -> max_chars:int -> (int * string) list * int
(** The part of a rendered JSON document that [path] addresses.
[select_paths rendered path ~max_chars] returns [(spans, dropped)], the
same shape as [select_passages]: [(offset, text)] pairs in document order,
each offset indexing the *full* rendering in codepoints, and the count of
sections the budget cut.

Adjacent matching lines are one span, so a subtree comes back as a block,
and a subtree bigger than the budget is cut at a line boundary rather than
withheld — the head of [$.items] is an answer. Selection stops at the
first span that does not fit, the [select_passages] rule, so both
selectors spend [fetch.max_match_chars] the same way. *)

val render_schema : string -> string option
(** The shape of a *rendered* JSON document: paths and types, no values.
Input is {!render_json}'s one-line-per-node output, which is the only form
the fetch path carries — the raw JSON is gone by the time the engine sees
the page, so the shape is derived from the rendering. Output is one line
per node again, but every leaf prints only its type —
[$.items  array(20000)], [$.items[*].id  number] — and a uniform array
collapses to one [[*]] subtree, so a document that renders to millions of
characters reports its shape in a few kilobytes. Every path a line carries
round-trips through {!parse_path} as a [path=] argument — that round-trip
is the point: read the shape, then drill, and one drill costs one read.
Returns [None] when the input is not one rendered document — any line that
does not start at the root, or a line this reader cannot classify — so the
caller answers with the page as it is rather than a schema of something
else. *)
