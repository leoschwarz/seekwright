"""Record tables on the fetch path: what counts as one, and how one is rendered.

A CSV body is the other half of the problem `jsondoc` solved for JSON: the bytes
are content, but read as text they are a wall of commas that `select_passages`
cannot search and `path` cannot address. A table is therefore rendered into
`jsondoc`'s line grammar -- one line per node, each labelled with the path that
addresses it -- so `fetch`'s `path`, `structure` and `offset` need no new
machinery and a column of every row is one `[*]` step: ``$.rows[*].price``.

The row source is the only part that knows about commas: :func:`_emit` takes
columns and rows, not a body. The next record format -- a Parquet reader behind
its own extra, the way ``pypdf`` is behind the ``trafilatura`` one -- feeds the
same emitter and changes nothing in the engine, the path grammar or the cache.
"""

from __future__ import annotations

import csv
import io
import json
from collections.abc import Iterable, Iterator, Sequence
from typing import NamedTuple

from .jsondoc import MAX_RENDER_RATIO, MIN_RENDER_CHARS, child_path

TABLE_TYPES: frozenset[str] = frozenset(
    {"text/csv", "application/csv", "text/tab-separated-values"}
)
"""The types that name a delimited table by themselves.

``application/vnd.ms-excel`` is deliberately absent: it names a binary workbook
as often as a CSV export, and a backend must not claim a type it reads by
guessing. ``text/csv`` with a ``charset`` parameter reaches here anyway --
`extractors.base.media_type` strips parameters.
"""

TAB_TYPES: frozenset[str] = frozenset({"text/tab-separated-values"})
"""The types whose own name states the delimiter, so nothing is sniffed."""

MAX_COLUMN_NAME_CHARS = 128
"""A column name longer than this is cut.

The name becomes the path label of every cell under it, so one hostile header
cell of a megabyte makes every row's label longer than the row. The cap also
keeps a printed path inside ``fetch``'s 400-character ``path`` bound, so every
column a caller can read off the page is one it can also ask for.
"""

_HEAD_CHARS = 8192
_HEAD_LINES = 20
_SNIFF_ORDER = (",", ";", "\t", "|")
"""The delimiter sample: bounded in characters and lines, because the file is a
stranger's and the sniff costs four parses of the sample."""


class _ParseStopped(NamedTuple):
    """Where a record stream stopped parsing, and what the reader said."""

    reason: str


def is_table_media(kind: str) -> bool:
    """Whether a media type names a table.

    Never consulted on an absent header: unlike JSON's braces, a delimited line
    is indistinguishable from prose, so a body with no Content-Type is text.
    `jsondoc.sniffs_json` refuses ``b"1,2,3"`` for the same reason and that
    guard stays green.
    """
    return kind in TABLE_TYPES


def table_delimiter(kind: str, text: str) -> str:
    """The delimiter this type declares, or the one this file's head supports."""
    if kind in TAB_TYPES:
        return "\t"
    return _choose_delimiter(text)


def _choose_delimiter(text: str) -> str:
    """Pick a comma-family delimiter by parsing the head four ways.

    A European export served as ``text/csv`` really is semicolon-separated, and
    reading it on commas answers one column named after the whole line: a wrong
    answer, not a refusal. Counting characters would be fooled by a comma inside
    a quoted value, so each candidate is parsed under the CSV grammar and the one
    every row agrees on wins -- the *narrowest* row it produces, not the widest,
    because a cell merely containing a semicolon splits under ``;`` and would
    otherwise outbid the real delimiter: an address column of ``"1 Main St;
    London; UK"`` in a comma file reads as one column and loses the city. Ties
    go to the order in `_SNIFF_ORDER`, so a file that agrees on nothing stays on
    commas. Not `csv.Sniffer`: its dialect search takes a sample of the caller's
    choosing and is bounded by nothing this tree controls.
    """
    sample = "\n".join(text[:_HEAD_CHARS].splitlines()[:_HEAD_LINES])
    best, best_width = ",", 1
    for delimiter in _SNIFF_ORDER:
        try:
            width = min(
                (len(row) for row in csv.reader(io.StringIO(sample), delimiter=delimiter)),
                default=1,
            )
        except csv.Error:
            width = 1
        if width > best_width:
            best, best_width = delimiter, width
    return best


def _column_names(header: Sequence[str]) -> list[str]:
    """The header row as column names: faithful, capped, never empty.

    Names are not trimmed or case-folded: a header cell of ``" id"`` is a column
    called ``" id"``, and `child_path` writes the quoted spelling that round-
    trips it. Duplicate names are left alone -- `path` then answers both, which
    reports the file's defect rather than renaming its data, and `render_schema`
    keys members by label, so the shape view prints that column once under a row
    header still naming the file's real width. Two distinct names sharing a
    128-character prefix collapse the same way, a rarer case of the same choice.
    An empty cell gets the positional name, so no path label is blank.
    """
    names: list[str] = []
    for ordinal, raw in enumerate(header):
        name = raw[:MAX_COLUMN_NAME_CHARS]
        names.append(name or f"column{ordinal + 1}")
    return names


def render_table(text: str, *, delimiter: str) -> str | None:
    """A delimited body as one line per row and cell, or ``None`` when it is not one.

    The first non-blank row names the columns; every row after it becomes
    ``$.rows[N]  object(C)`` and one line per column under it. Rows shorter than
    the header are padded with empty cells and rows longer than it are cut to
    it, so every row object has exactly the header's width -- which is what lets
    `render_schema` collapse the whole array to one ``$.rows[*]`` subtree.
    Cells stay quoted strings whatever they hold: a CSV has no types, and
    ``007`` or ``1.50`` unquoted would be a different value than the file wrote.

    ``None`` is the caller's signal to answer with the bytes: a header the reader
    cannot walk, and a reader that stopped before any row printed -- columns
    without one row say nothing about the file.
    """
    reader = csv.reader(io.StringIO(text.removeprefix("\ufeff")), delimiter=delimiter)
    try:
        while True:
            header = next(reader)
            if header:
                break
    except (csv.Error, StopIteration):
        return None
    return _emit(_column_names(header), _records(reader), len(text))


def _records(reader: Iterator[list[str]]) -> Iterator[Sequence[str] | _ParseStopped]:
    """The records after the header, and one stop marker where parsing failed.

    A record stream cut mid-file keeps its head -- the `JSONL_TYPES` precedent,
    and why `fetcher._read_body` refuses a cut JSON *document* but not a cut
    stream. The csv reader's own field cap (131072 characters, never raised:
    `csv.field_size_limit` is process-global state) lands here as a stop marker
    rather than a fetch failure.
    """
    try:
        yield from reader
    except csv.Error as exc:
        yield _ParseStopped(str(exc))


def _emit(
    columns: Sequence[str],
    rows: Iterable[Sequence[str] | _ParseStopped],
    body_chars: int,
) -> str | None:
    """Print a table in `jsondoc`'s line grammar; the format-agnostic half.

    The budget is `jsondoc`'s, measured against the file's own characters, so a
    rendering can cost four times a body that `fetch.max_download_bytes` already
    bounded: measured at this tree, 6.8 MB of four-column CSV parses in 0.25 s
    and renders to the 27 MB budget in 0.9 s -- inside `fetch.timeout_seconds`,
    which the fetcher already enforces on the extraction thread. Rows past the
    budget are not printed and so not addressable, which is why the line naming
    the cut counts *this* rendering's rows and never implies the file's length:
    `array(N)` is a bound, not a row count.

    Returns ``None`` when the reader stopped before any row printed: all that is
    known of the file is its columns, and the bytes serve the caller better than
    an empty table that claims to be one.
    """
    width = len(columns)
    budget = max(MIN_RENDER_CHARS, MAX_RENDER_RATIO * body_chars)
    printed = 0
    spent = 0
    stop: str | None = None
    out: list[str] = []
    for row in rows:
        if isinstance(row, _ParseStopped):
            if printed == 0:
                # Only the columns printed: the bytes serve the caller better.
                return None
            stop = (
                f"not rendered: this file stopped parsing at this row "
                f"({row.reason}); the rows above it are complete"
            )
            break
        if not row:
            continue
        if spent > budget:
            stop = (
                f"not rendered: the table expands past the budget of {budget} "
                f"characters, {MAX_RENDER_RATIO} times the file's own "
                f"{body_chars}; {printed} rows are printed above and no further "
                "row of the file is addressable in this page -- fetch with "
                "`offset` to page through what is here, or raise "
                "fetch.max_download_bytes, the budget being a ratio of it"
            )
            break
        path = f"$.rows[{printed}]"
        line = f"{path}  object({width})"
        out.append(line)
        spent += len(line) + 1
        cells = list(row[:width]) + [""] * max(0, width - len(row))
        for name, value in zip(columns, cells, strict=True):
            leaf = (
                f"{child_path(path, name)}  "
                f"{json.dumps(value, ensure_ascii=False, separators=(',', ':'))}"
            )
            out.append(leaf)
            spent += len(leaf) + 1
        printed += 1
    lines = ["$  object(1)", f"$.rows  array({printed})", *out]
    if stop is not None:
        lines.append(f"$.rows[{printed}]  {stop}")
    return "\n".join(lines)
