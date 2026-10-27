"""The extraction-backend contract and the plumbing every backend shares.

`fetch` pulls bytes off the network; turning them into text a model can read is
the part most likely to be replaced. So it sits behind a named backend, picked by
``fetch.extractor`` and looked up in :data:`KNOWN_EXTRACTORS` -- swapping the
engine is a config change, not a code change.

A backend implements :class:`Extractor`: a ``name``, the media types it can read,
and an ``extract`` returning an :class:`ExtractResult`. Backends import their own
libraries at import time (never here), so a missing one becomes an ``ImportError``
the factory translates into advice.

Adding a backend means six edits:

1. a module under ``extractors/`` exposing the :class:`Extractor` protocol;
2. its name in :data:`KNOWN_EXTRACTORS` below;
3. a branch in ``factory.build_extractor``;
4. an extra in ``pyproject.toml`` if it needs libraries of its own;
5. a bullet in ``docs/reference/configuration.md``;
6. tests -- ``tests/fetch/test_extractors.py`` is the shape to copy.

No separate contract document: two backends do not earn a reference page, and a
prose copy of the protocol rots faster than the protocol itself.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Protocol

# The JSON half of the fetch path lives beside the package rather than here: a
# backend decides *that* a body is JSON and hands it to `jsondoc`, which owns
# what a JSON document looks like to a caller.
from ..jsondoc import JSON_TYPES, render_json

_WS_RUNS = re.compile(r"[ \t]+")
_BLANK_RUNS = re.compile(r"\n{3,}")

HTML_TYPES = frozenset({"text/html", "application/xhtml+xml"})
PDF_TYPES = frozenset({"application/pdf", "application/x-pdf"})
TEXT_TYPES = frozenset({"text/plain", "text/markdown", "text/xml", "application/xml"})
SUPPORTED_TYPES = HTML_TYPES | PDF_TYPES | TEXT_TYPES | JSON_TYPES

KNOWN_EXTRACTORS: frozenset[str] = frozenset({"stdlib", "trafilatura"})
"""Every fetch extraction backend this build knows how to construct, by name.

Config validation rejects a ``fetch.extractor`` outside this set, exactly as it
rejects a provider name outside ``KNOWN_PROVIDERS`` -- a name that parses and
does nothing is the failure mode both exist to remove.

Every member except ``stdlib`` names a library, and rides in the extra of the
same name; ``stdlib`` is the member an install with no extra at all
can build, which is why a missing extra is a config line away from being a
missing tool rather than the loss of the process.
"""


class ExtractionFailed(Exception):
    """The bytes could not be turned into text at all."""


@dataclass(slots=True)
class ExtractResult:
    text: str
    title: str | None
    total_chars: int
    """Length of the full normalised extraction."""
    path_addressable: bool = False
    """Whether `text` is a structure rendering whose lines `fetch`'s `path` selects.

    Only the extraction can say it, so it says it: the engine must not infer
    "this is a JSON document" from a character of page text. A Makefile whose
    first line is `$ make all` starts with the root character of a path and is
    not one, and a body that reached the caller as text because the renderer
    declined it is not one either. Set by the backend that walked the
    structure; every other page leaves it False.
    """


class Extractor(Protocol):
    """A fetch extraction backend.

    ``supported_types`` is what the fetcher checks a response's media type
    against *before* downloading the body, so it must be honest: an unreadable
    type listed here spends a download on a page that can never be read.
    """

    name: str
    supported_types: frozenset[str]

    def extract(self, body: bytes, content_type: str | None) -> ExtractResult:
        """Extract readable text from a fetched body, uncut.

        Sizing it for a caller is the fetcher's job (``fetcher.window_text``):
        where to cut depends on who is asking. Raises :class:`ExtractionFailed`
        when the body cannot be read; an empty extraction is a reportable
        outcome, not an error.
        """
        ...


def media_type(content_type: str | None) -> str:
    """The bare media type, lowercased, with parameters stripped."""
    if not content_type:
        return ""
    return content_type.split(";", 1)[0].strip().lower()


def is_supported(types: frozenset[str], kind: str) -> bool:
    """Whether a backend claiming ``types`` can read ``kind``.

    The one place the RFC 6839 rule sits: a ``+json`` type *is* a JSON document
    whatever its prefix registers. A backend reading ``application/json`` reads
    ``application/geo+json`` with it; enumerating suffixes would make each new one
    a refusal the operator has to patch. The fetcher runs this *before*
    downloading a body, so the claim stays the backend's.
    """
    return kind in types or (kind.endswith("+json") and "application/json" in types)


def charset_of(content_type: str | None) -> str | None:
    """The declared charset, if the server bothered to send one."""
    if not content_type:
        return None
    for param in content_type.split(";")[1:]:
        name, _, value = param.partition("=")
        if name.strip().lower() == "charset":
            return value.strip().strip('"') or None
    return None


def decode(body: bytes, content_type: str | None) -> str:
    """Decode a response body to text, preferring the server's declared charset.

    Never raises: a page with a few mojibake characters is still useful, whereas
    an exception loses the whole page over one bad byte.
    """
    declared = charset_of(content_type)
    for encoding in (declared, "utf-8"):
        if not encoding:
            continue
        try:
            return body.decode(encoding)
        except LookupError, UnicodeDecodeError:
            continue
    return body.decode("utf-8", errors="replace")


def sniffs_html(body: bytes) -> bool:
    """Treat a missing Content-Type as HTML only if the bytes look like it.

    The rule belongs to the absent header, not to any one engine.
    """
    head = body[:512].lstrip().lower()
    return head.startswith((b"<!doctype html", b"<html"))


def normalise(text: str, title: str | None) -> ExtractResult:
    """Collapse whitespace runs, cap blank-line runs, and measure.

    The one place the wire shape of an extraction is decided, so two backends
    never disagree about what "the extracted text" means.
    """
    text = _BLANK_RUNS.sub("\n\n", _WS_RUNS.sub(" ", text)).strip()
    return ExtractResult(text, title or None, len(text))


def json_extraction(text: str) -> ExtractResult:
    """A JSON body as the structure it is, or as its own text when it is not one.

    An endpoint answering ``application/json`` with an HTML error page, or with
    JSON Lines rather than one document, has not failed to be fetched: its bytes
    are the answer, so they come back as text rather than as an
    :class:`ExtractionFailed`. :func:`normalise` never runs here -- its
    whitespace rules are for prose, and in a JSON value the spaces are the data.
    """
    rendered = render_json(text)
    if rendered is None:
        return ExtractResult(text, None, len(text))
    return ExtractResult(rendered, None, len(rendered), path_addressable=True)


_FAMILIES: tuple[tuple[str, frozenset[str]], ...] = (
    ("HTML", HTML_TYPES),
    # The XML media types ride with plain text: a backend reads them decoded and passed
    # through, not walked as a structure.
    ("plain text", TEXT_TYPES),
    # JSON is a family of its own because it is read as a structure, not as text;
    # the `+json` suffix types ride with it, through `is_supported` below.
    ("JSON", JSON_TYPES),
    ("PDF", PDF_TYPES),
)
"""Media types grouped into the families a model recognises, in display order."""


def describe_types(types: frozenset[str]) -> str:
    """A human phrase naming the media types a backend can read.

    Derived rather than hardcoded, because the phrase is model-facing: it
    appears in the refusal for a URL the backend cannot read, and a backend swap
    must not leave that message claiming a type the new one lacks. Families
    render in a fixed order, so a given set always reads the same way; a type no
    family claims is appended verbatim and sorted.
    """
    claimed = frozenset().union(*(members for _, members in _FAMILIES))
    labels = [label for label, members in _FAMILIES if types & members]
    labels += sorted(types - claimed)
    if not labels:
        return "nothing"
    if len(labels) == 1:
        return labels[0]
    return ", ".join(labels[:-1]) + f" and {labels[-1]}"


_CHUNK_CHARS = 1500
"""Grenularity of passage selection: roughly one to three paragraphs."""


def select_passages(
    text: str, query: str, *, max_chars: int
) -> tuple[list[tuple[int, str]], int]:
    """Pick the passages of a full extraction that answer ``query``.

    Deterministic, stdlib-only term overlap -- not an embedding or a provider
    call, so it adds no dependency and works on text any fallback produced.
    Returns ``(spans, dropped)``: ``(offset, text)`` pairs in document order,
    each offset indexing the *full* extraction, and the count of matching chunks
    the budget cut.

    Tokens are ``\\w+`` runs of the casefolded query, length >= 2, deduplicated
    (unicode ``\\w``: queries are not ASCII). Chunks are consecutive paragraphs
    packed to ``_CHUNK_CHARS``, a lone paragraph over the mark hard-split. A
    chunk scores by distinct query tokens; zero scores are never candidates.
    Candidates are taken best-first (score, then position) while the budget
    lasts, and the first that does not fit ends selection rather than letting a
    smaller one queue-jump. Selected chunks are re-sorted by offset and adjacent
    ones merged.
    """
    tokens = {t for t in re.findall(r"\w+", query.casefold()) if len(t) >= 2}
    if not tokens:
        return [], 0

    # Split on "\n\n" (the only breaks normalisation leaves), carrying absolute
    # offsets, then hard-split any paragraph over the mark.
    pieces: list[tuple[int, str]] = []
    pos = 0
    for para in text.split("\n\n"):
        for k in range(0, len(para), _CHUNK_CHARS):
            pieces.append((pos + k, para[k : k + _CHUNK_CHARS]))
        pos += len(para) + 2

    # Greedy pack: consecutive pieces up to the mark. A hard-split piece is exactly
    # the mark long, so it never shares a chunk.
    chunks: list[tuple[int, str]] = []
    start_i, buf_chars = 0, 0
    for i, (_, piece) in enumerate(pieces):
        if i > start_i and buf_chars + len(piece) + 2 > _CHUNK_CHARS:
            s = pieces[start_i][0]
            chunks.append((s, "\n\n".join(p[1] for p in pieces[start_i:i])))
            start_i, buf_chars = i, 0
        buf_chars += len(piece) + (2 if i > start_i else 0)
    if start_i < len(pieces):
        s = pieces[start_i][0]
        chunks.append((s, "\n\n".join(p[1] for p in pieces[start_i:])))

    scored = [
        (sum(1 for t in tokens if t in body.casefold()), offset, body)
        for offset, body in chunks
    ]
    ranked = sorted((s for s in scored if s[0] > 0), key=lambda s: (-s[0], s[1]))

    selected: list[tuple[int, str]] = []
    used = 0
    for _, offset, body in ranked:
        if used + len(body) + 2 > max_chars:
            break
        selected.append((offset, body))
        used += len(body) + 2
    if not selected:
        return [], len(ranked)

    selected.sort(key=lambda s: s[0])
    spans: list[tuple[int, str]] = []
    for offset, body in selected:
        prev = spans[-1] if spans else None
        # Adjacent chunks sit exactly one "\n\n" apart; merging them yields a
        # contiguous span at the earlier offset, joiner included.
        if prev is not None and offset == prev[0] + len(prev[1]) + 2:
            spans[-1] = (prev[0], f"{prev[1]}\n\n{body}")
        else:
            spans.append((offset, body))
    return spans, len(ranked) - len(selected)
