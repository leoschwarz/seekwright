(** Record tables on the fetch path: what counts as one, and how one is
    rendered.

    Port of [src/seekwright/tabledoc.py]. A CSV body is the other half of the
    problem [Jsondoc] solved for JSON: the bytes are content, but read as text
    they are a wall of commas that passage selection cannot search and [path]
    cannot address. A table is therefore rendered into [Jsondoc]'s line grammar
    — one line per node, each labelled with the path that addresses it — so
    [fetch]'s [path], [structure] and [offset] need no new machinery and a
    column of every row is one [[*]] step: [$.rows[*].price]. *)

val table_types : string list
(** The types that name a delimited table by themselves.

[application/vnd.ms-excel] is deliberately absent: it names a binary
workbook as often as a CSV export, and a backend must not claim a type it
reads by guessing. [text/csv] with a [charset] parameter reaches here
anyway — the extractor's media-type normalisation strips parameters. *)

val tab_types : string list
(** The types whose own name states the delimiter, so nothing is sniffed. *)

val max_column_name_chars : int
(** A column name longer than this is cut.

The name becomes the path label of every cell under it, so one hostile
header cell of a megabyte makes every row's label longer than the row. The
cap also keeps a printed path inside [fetch]'s 400-character [path] bound,
so every column a caller can read off the page is one it can also ask for. *)

val field_limit : int
(** [csv.field_size_limit]'s process default, pinned here because the stop
message names it and the value is what a record stream stops on. Never
raised by config: the Python original keeps it process-global state, and
this port keeps the same constant. *)

val is_table_media : string -> bool
(** Whether a media type names a table.

Never consulted on an absent header: unlike JSON's braces, a delimited line
is indistinguishable from prose, so a body with no Content-Type is text.
[Jsondoc.sniffs_json] refuses [1,2,3] for the same reason and that guard
stays green. *)

val table_delimiter : string -> string -> string
(** [table_delimiter kind text] is the delimiter this type declares, or the one
this file's head supports. A tab type states its delimiter whatever the
body looks like, so a body full of commas does not out-vote it. For the
rest the head of the file is parsed under the CSV grammar four ways, once
per comma-family candidate, and the one every row agrees on wins — the
*narrowest* row it produces, not the widest, because a cell merely
containing a separator splits under that candidate and would otherwise
outbid the real delimiter. Ties go to the declared order, so a file that
agrees on nothing stays on commas. *)

val render_table : string -> delimiter:string -> string option
(** [render_table text ~delimiter] is a delimited body as one line per row and
cell in [Jsondoc]'s line grammar — [$.rows[N]  object(C)] and one line per
column under it — or [None] when it is not one. The first non-blank row
names the columns; every row object has exactly the header's width, shorter
rows padded and longer rows cut, which is what lets a shape view collapse
the whole array to one [$.rows[*]] subtree.

Two cuts bound the rendering, both printing the line naming where they
fell: the budget is [Jsondoc]'s, measured against the file's own
characters, and a record stream that stops parsing — the reader's field
cap, never raised from config — stops printing rather than failing the
fetch, keeping the rows above it complete. [None] is the caller's signal to
answer with the bytes: a header the reader cannot walk, and a reader that
stopped before any row printed — columns without one row say nothing about
the file. *)
