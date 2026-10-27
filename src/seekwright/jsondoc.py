"""JSON documents on the fetch path: what counts as one, how one is rendered, and how part of one is addressed.

Two halves of one problem meet here. A JSON response is refused outright,
because no extraction backend claims ``application/json``; and a JSON body
arriving as ``text/plain`` -- what a raw ``.json`` file on a code host does --
is a wall of braces ``select_passages`` cannot search: it scores raw
1500-character slices, so ``query`` either misses the field or cuts a value in
half.

Both halves are answered with the standard library alone, so no second parser
has to be trusted with bytes a stranger wrote.

A JSON page is extracted as one line per node, each labelled with the path that
addresses it, so the document arrives as its own map: ``total_chars``,
``offset`` and the ``[...]`` marker keep their meaning, ``query`` still selects
by terms, and ``path`` selects by structure. A line's path is the exact string a
caller passes back as ``path``, which is why it is absolute and printed on every
line rather than implied by indentation, and why :func:`parse_path` reads the
same syntax :func:`render_json` writes.
"""

from __future__ import annotations

import ast
import json
import re
from collections.abc import Iterator
from typing import NamedTuple

JSON_DOCUMENT_TYPES: frozenset[str] = frozenset({"application/json", "text/json"})
"""The media types that name one JSON document, written out because there are
only two of them and the difference from a stream is a decision, not a detail."""

JSONL_TYPES: frozenset[str] = frozenset({"application/jsonl", "application/x-ndjson"})
"""The JSON Lines types: JSON, but a stream of records rather than one document.

They ride with the JSON family so a backend claims them and hands the body back
as text instead of refusing the download, and they are held out of
:func:`is_json_document_media` because a stream cut mid-record still has whole
records at its head, where a document cut in the middle has nothing."""

JSON_TYPES: frozenset[str] = JSON_DOCUMENT_TYPES | JSONL_TYPES
"""The media types that name a JSON body by themselves.

The RFC 6839 ``+json`` structured-syntax types (``application/geo+json``,
``application/ld+json``, ``application/vnd.api+json``) name one too, and
:func:`is_json_media` reads the suffix rather than a list of registered
prefixes: a closed list would refuse the next vendor type instead of parsing it.
"""

_JSON_SUFFIX = "+json"

_MAX_DEPTH = 100
"""How deep :func:`render_json` expands a document, counting the root as zero.

Real documents measured in this work sit under ten; past a hundred the path
each line carries is longer than the value it labels, so the cut is a
readability line as much as a memory one.

Depth alone does not answer size, which is what :data:`_MAX_RENDER_RATIO` is for.
"""

_MAX_RENDER_RATIO = 4
"""How much larger than the body :func:`render_json` is allowed to make it.

Every line carries its whole path, so the cost of a rendering is a function of
the document's shape, not of its bytes: 400 KB nested 99 deep -- inside the
depth cap, with 200k leaves under it -- renders to 61 million characters, 153
times the body it was fetched from. The real documents measured in this work
render at about 1.07 times their own size, so this ceiling leaves room for a
path label longer than the key it addresses without letting one page cost three
orders of magnitude more than its own download.
"""

_MIN_RENDER_CHARS = 8000
"""The floor under that budget, so that no small document is ever cut.

Four times a few hundred bytes is less than the same document rendered with
every path spelled out; the budget exists to bound large bodies, not to refuse
to print a short one.
"""

_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_SIGNED = re.compile(r"-?\d+")

class Key(NamedTuple):
    """One member of an object: ``.name`` or ``["a b"]``."""

    name: str


class Position(NamedTuple):
    """One element of an array: ``[3]``."""

    ordinal: int


class Every(NamedTuple):
    """Every member at this level, whatever it is called: ``[*]``."""


class Bounds(NamedTuple):
    """A slice of an array: ``[a:b]``, either bound absent meaning the array's
    own end."""

    start: int | None
    stop: int | None


Step = Key | Position | Every | Bounds
"""One step of a path: the four shapes the grammar reads."""


class PathSyntax(ValueError):
    """A ``path`` this grammar cannot express.

    A distinct type so the engine can answer it as a refusal rather than as a
    fetch failure: the caller wrote something unreadable, and that is known
    before any request goes out.
    """


def is_json_media(kind: str) -> bool:
    """Whether a media type names a JSON body: one document, or a stream of them.

    The suffix carries the vendor types: in ``application/vnd.foo+json`` the
    prefix says whose document it is, the suffix what syntax, and parsing only
    cares about the syntax.
    """
    return is_json_document_media(kind) or kind in JSONL_TYPES


def is_json_document_media(kind: str) -> bool:
    """Whether a media type names one JSON *document* rather than a stream of them.

    The fetcher needs the distinction for a body it had to cut at
    ``fetch.max_download_bytes``: a document severed in the middle is neither a
    document nor readable in part, while a record stream cut mid-record still
    has whole records at its head.
    """
    return kind in JSON_DOCUMENT_TYPES or kind.endswith(_JSON_SUFFIX)


def sniffs_json(body: bytes) -> bool:
    """Treat a missing Content-Type as JSON only if the bytes look like it.

    Mirrors ``sniffs_html``: only the two shapes a JSON *document* starts with
    count. A body beginning with a digit or a quote is a bare JSON value, and
    guessing that from unlabelled bytes is how a CSV of numbers becomes a
    document.
    """
    return body[:512].lstrip()[:1] in (b"{", b"[")


def _child_path(parent: str, key: str | int) -> str:
    """The path of one member of a container, in the syntax `parse_path` reads."""
    if isinstance(key, int):
        return f"{parent}[{key}]"
    if _NAME.fullmatch(key):
        return f"{parent}.{key}"
    # Quoted through json so a key holding a dot, a space or a quote round-trips;
    # the path is a caller's argument, so it has to be re-readable, not pretty.
    return f"{parent}[{json.dumps(key)}]"


class _Frame(NamedTuple):
    """A container the walk has printed the header of, holding its unread members.

    The walk keeps a container as one of these instead of pushing every member:
    an eager walk of a wide container cost a stack entry and a path string per
    member before any of them were printed -- 2.3 GB for one 8 MB page.
    """

    members: Iterator[tuple[str | int, object]]


def render_json(text: str) -> str | None:
    """Render a JSON document as one line per node: ``<path>  <value>``.

    A container renders as its own header line naming its size -- ``$  object(4)``
    then ``$.items  array(120)`` -- before its members, so the shape is legible in
    the first screenful, and ``array(120)`` tells the caller how far
    ``$.items[0:5]`` is from the end. A leaf renders as compact JSON.

    Two cuts bound the rendering, both printing a line naming where they fell:
    :data:`_MAX_DEPTH` on nesting, and :data:`_MAX_RENDER_RATIO` times the body's
    length on size. Depth alone leaves the wide-under-the-cap shape unbounded,
    since a path label per leaf is a cost the document's *shape* sets. The walk
    is bounded by the same budget: a container goes back onto the stack as one
    :class:`_Frame`, so the queue never runs ahead of what has been printed.

    Returns ``None`` when the body is not one document this function can walk --
    a trailing-comma pseudo-JSON API, an HTML error page served under
    ``application/json``, or a JSON Lines stream -- and the caller then answers
    with the body as text.
    """
    try:
        value = json.loads(text)
    except (ValueError, RecursionError):
        return None

    budget = max(_MIN_RENDER_CHARS, _MAX_RENDER_RATIO * len(text))
    lines: list[str] = []
    spent = 0
    # An explicit stack, because the depth of the walk is a stranger's choice
    # and the recursion limit is not the place to answer it. A container goes
    # back onto it as a `_Frame` over its own iterator rather than as one entry
    # per member, so what the walk holds is one entry per level it is inside --
    # the rendering's own budget bounds the walk with it.
    stack: list[tuple[str, int, object]] = [("$", 0, value)]
    while stack:
        path, depth, node = stack.pop()
        if spent > budget:
            lines.append(
                f"{path}  not rendered: the document expands past the budget of "
                f"{budget} characters, {_MAX_RENDER_RATIO} times its own size; "
                "ask for one part of it with `path`, as in $.items[0:5]"
            )
            break
        if isinstance(node, _Frame):
            member = next(node.members, None)
            if member is None:
                continue
            key, child = member
            # The frame goes back under the child: an array of 200k members is
            # one stack entry read one member at a time, not 200k entries.
            stack.append((path, depth, node))
            stack.append((_child_path(path, key), depth + 1, child))
            continue
        if isinstance(node, (dict, list)):
            kind = "array" if isinstance(node, list) else "object"
            if depth >= _MAX_DEPTH:
                line = (
                    f"{path}  {kind}({len(node)}) not expanded: nested past "
                    f"depth {_MAX_DEPTH}"
                )
            else:
                line = f"{path}  {kind}({len(node)})"
                members: Iterator[tuple[str | int, object]] = (
                    enumerate(node)
                    if isinstance(node, list)
                    else ((str(key), child) for key, child in node.items())
                )
                stack.append((path, depth, _Frame(members)))
        else:
            line = f"{path}  {json.dumps(node, ensure_ascii=False, separators=(",", ":"))}"
        lines.append(line)
        spent += len(line) + 1
    return "\n".join(lines)


def _scan_path(raw: str, *, bare_names: bool) -> tuple[list[Step], int]:
    """Read path steps from the start of ``raw``; stop at the first character
    that cannot continue a path.

    ``bare_names`` separates the two readers: a rendered line starts with ``$``
    and ends at a space, so a stray character there is a value rather than a
    syntax error, while a caller's ``items.name`` has an implicit root and has
    to parse.
    """
    steps: list[Step] = []
    at = 0
    if raw.startswith("$"):
        at = 1
    while at < len(raw):
        char = raw[at]
        if char == ".":
            at += 1
            if at < len(raw) and raw[at] == "[":
                # `$.["a b"]`: the dot is a separator here, not a member name.
                # Refusing it would make a caller re-type a path it read straight
                # out of the rendering, and nothing about the answer changes.
                continue
            match = _NAME.match(raw, at)
            if match is None:
                raise PathSyntax(f"expected a member name after '.' at offset {at}")
            steps.append(Key(match.group()))
            at = match.end()
        elif char == "[":
            step, at = _scan_bracket(raw, at)
            steps.append(step)
        elif bare_names:
            match = _NAME.match(raw, at)
            if match is None:
                raise PathSyntax(f"cannot read {raw[at:]!r} at offset {at}")
            steps.append(Key(match.group()))
            at = match.end()
        else:
            break
    return steps, at


def _scan_bracket(raw: str, at: int) -> tuple[Step, int]:
    """One ``[...]`` step, and the offset just past it."""
    index = at + 1
    inner_start = index
    quote = ""
    while index < len(raw):
        char = raw[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
        elif char == "]":
            break
        index += 1
    else:
        raise PathSyntax("a `[` in the path is never closed")
    inner = raw[inner_start:index].strip()
    end = index + 1
    if inner == "*":
        return Every(), end
    if ":" in inner:
        start_text, _, stop_text = inner.partition(":")
        return Bounds(_bound(start_text), _bound(stop_text)), end
    number = _SIGNED.fullmatch(inner)
    if number is not None:
        value = int(number.group())
        if value < 0:
            raise PathSyntax(
                "a negative index is not supported; the array's length is on "
                "its header line, so ask for the range you want, as in [0:5]"
            )
        return Position(value), end
    if inner[:1] in ('"', "'"):
        key = _quoted_key(inner)
        if key is None:
            raise PathSyntax(f"the quoted key {inner!r} is not readable")
        if not isinstance(key, str):
            raise PathSyntax(f"the bracketed key {inner!r} is not a name")
        return Key(key), end
    raise PathSyntax(f"cannot read the bracketed step [{inner!r}]")


def _quoted_key(inner: str) -> object | None:
    """Read a bracketed key: ``["a b"]``, and ``['a b']`` with it.

    ``json.loads`` reads the quoting :func:`render_json` writes, which is the
    spelling a caller reads off the page. A caller typing a path from memory
    writes the JSONPath spelling in single quotes, so the Python literal reader
    covers that too; the answer still has to be a string to name a member.
    """
    try:
        return json.loads(inner)
    except ValueError:
        pass
    try:
        return ast.literal_eval(inner)
    except (ValueError, SyntaxError):
        return None


def _bound(text: str) -> int | None:
    """One side of a slice: an index, or ``None`` for "the array's own end"."""
    if not text.strip():
        return None
    try:
        value = int(text)
    except ValueError as exc:
        raise PathSyntax(f"the slice bound {text!r} is not an index") from exc
    if value < 0:
        raise PathSyntax(
            "a negative slice bound is not supported; the array's length is on "
            "its header line, so name the range you want, as in [0:5]"
        )
    return value


def parse_path(spec: str) -> list[Step]:
    """Read a path selector: ``$.items[0].name``, ``$.items[*].id``, ``$.items[2:9]``.

    This is the subset of JSONPath the tree can honour with the standard
    library: ``$`` for the document, ``.name`` and ``["name"]`` for an object
    member, ``[3]`` for an array element, ``[*]`` for every member at that
    level, and ``[a:b]`` for a slice of an array. Filters
    (``[?(@.price<10)]``) and recursive descent (``..``) need a library;
    ``query`` already covers the searching half of a filter over a page in hand.

    A leading ``$`` is optional, because a caller reading a line of the
    rendering already holds a path that starts with it.
    """
    raw = spec.strip()
    steps, at = _scan_path(raw, bare_names=True)
    if at != len(raw):
        raise PathSyntax(f"cannot read {raw[at:]!r} at offset {at}")
    if not steps and raw != "$":
        # A blank or whitespace-only `path` reads as the root, which silently
        # turns a caller's typo into a request for the whole document. `$` is
        # the spelling that *means* the whole document, and it stays honoured.
        raise PathSyntax(
            "the path names nothing; ask for a member, as in $.items[0], or `$` "
            "for the whole document"
        )
    return steps


def _matches(line_steps: list[Step], spec: list[Step]) -> bool:
    """Whether a rendered line's path is the selected node or under it.

    Prefix matching is what makes ``$.items`` the array *and* its 120 elements:
    the caller asked for the node, and a node is its whole subtree.
    """
    if len(line_steps) < len(spec):
        return False
    for step, wanted in zip(line_steps, spec, strict=False):
        if isinstance(wanted, Every):
            continue
        if isinstance(wanted, Key):
            if not (isinstance(step, Key) and step.name == wanted.name):
                return False
        elif isinstance(wanted, Position):
            if not (isinstance(step, Position) and step.ordinal == wanted.ordinal):
                return False
        elif not (
            isinstance(step, Position)
            and (wanted.start is None or step.ordinal >= wanted.start)
            and (wanted.stop is None or step.ordinal < wanted.stop)
        ):
            return False
    return True


def select_paths(
    rendered: str, path: str, *, max_chars: int
) -> tuple[list[tuple[int, str]], int]:
    """The part of a rendered JSON document that ``path`` addresses.

    Returns ``(spans, dropped)``, the same shape as ``select_passages``:
    ``(offset, text)`` pairs in document order, each offset indexing the *full*
    rendering, and the count of sections the budget cut.

    Adjacent matching lines are one span, so a subtree comes back as a block,
    and a subtree bigger than the budget is cut at a line boundary rather than
    withheld -- the head of ``$.items`` is an answer. Selection stops at the
    first span that does not fit, the ``select_passages`` rule, so both
    selectors spend ``fetch.max_match_chars`` the same way.
    """
    spec = parse_path(path)
    spans: list[tuple[int, str]] = []
    buf: list[str] = []
    run_start = 0
    run_chars = 0
    offset = 0
    for line in rendered.split("\n"):
        # Only the renderer's own lines are candidates: every one of them starts
        # at the document root, so a page that reached the caller as raw text
        # has no path to match rather than a wrong one.
        matched = line.startswith("$") and _matches(
            _scan_path(line, bare_names=False)[0], spec
        )
        if matched:
            if buf and run_chars + len(line) + 1 > max_chars:
                spans.append((run_start, "\n".join(buf)))
                run_start, buf, run_chars = offset, [line], len(line)
            elif buf:
                buf.append(line)
                run_chars += len(line) + 1
            else:
                run_start, buf, run_chars = offset, [line], len(line)
        elif buf:
            spans.append((run_start, "\n".join(buf)))
            buf = []
        offset += len(line) + 1
    if buf:
        spans.append((run_start, "\n".join(buf)))

    selected: list[tuple[int, str]] = []
    used = 0
    for start, text in spans:
        if used + len(text) + 1 > max_chars:
            break
        selected.append((start, text))
        used += len(text) + 1
    return selected, len(spans) - len(selected)
