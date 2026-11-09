"""The disk page cache behind ``fetch``: one download per page, many reads.

Repeated partial reads of one page — an ``offset`` continuation, a ``path``
drill, a ``query`` over the same document — each re-download and re-extract
per call today, and on a named billable fallback each is a credit. This
module stores a page as ``<sha256(provider, validated URL)>.body`` plus a
``.meta.json`` sidecar in one operator-named directory, so the engine serves
the repeats off disk.

Bounded three ways, because a cache that cannot refuse a page cannot be
defaulted on: an entry larger than ``max_entry_bytes`` is never stored; the
directory is capped at ``max_bytes`` with LRU eviction by the body file's
atime (a hit is an ``os.utime``, never a body rewrite); an entry older than
``ttl_seconds`` reads as a miss and is removed on read. Both files of an
entry go through a temporary file and ``os.replace``, so a crash never
leaves a half entry visible — and a half entry, the sidecar without its
body or the reverse, reads as a miss under the same rule.

Nothing is resident in RAM between calls: a burst of distinct URLs grows the
directory, never the heap. :meth:`get_window` streams only the characters a
paged read serves — an incremental UTF-8 decode stopped at ``offset +
max_chars + 2`` — and applies the same cut :func:`fetcher.window_text`
applies, so a paged read of a document far larger than its window holds the
window, not the body. The full body is read whole only by :meth:`get`, for
the selections that need the entire document, and is freed after the call.

The window cut is mirrored here — :func:`_cut` — because this module
deliberately imports nothing of ``seekwright`` and ``fetcher`` pulls in
httpx; the mirror is byte-equality with ``window_text``, an invariant
``tests/fetch/test_page_cache.py`` pins over generated texts, and that test
is what keeps the mirror true as either side changes.

Every method touches the filesystem and therefore blocks, so the engine runs
them through ``asyncio.to_thread``; tests of the class itself are free to
call it synchronously. Only the standard library reads the bytes and writes
the files here: nothing parses caller-supplied content.
"""

from __future__ import annotations

import codecs
import hashlib
import json
import os
import tempfile
import threading
import time
from contextlib import suppress
from dataclasses import dataclass

DEFAULT_MAX_BYTES = 268_435_456
"""The directory cap, 256 MiB: room for pages by the hundred, small enough
that a burst of large pages cannot fill a disk."""
DEFAULT_MAX_ENTRY_BYTES = 33_554_432
"""The per-entry cap, 32 MiB: a page above it is never stored, so it is
fetched live on every read rather than staking a lifetime of disk."""
DEFAULT_TTL_SECONDS = 300.0
"""The default freshness window: five minutes is a page a caller pagers over,
not an archive; an operator who wants longer sets ``cache_ttl_seconds``."""

# window_text looks at ``[offset, offset + max_chars + 1]`` for its cut, and
# one character past that answers "more remains" without a second read.
_WINDOW_LOOKAHEAD = 2

_BODY_SUFFIX = ".body"
_META_SUFFIX = ".meta.json"

_CHUNK = 65536
"""Streaming read size; only the decoder, never the whole body, is held."""


def entry_name(provider: str, url: str) -> str:
    """One entry's file-name hash, keyed by provider and *validated* URL.

    The provider is in the key alongside the URL because the local read and a
    fallback's are different answers to the same page and never share an
    entry; the URL is the normalised string ``validate_url`` returned, not the
    raw spelling a caller wrote, which is where the engine's preflight finds
    it. The NUL keeps the two fields from trading characters across the
    boundary. A hash rather than the URL itself keeps a model-supplied
    filesystem string out of ``os.path.join``.
    """
    return hashlib.sha256(f"{provider}\0{url}".encode()).hexdigest()


@dataclass(frozen=True, slots=True)
class CachedPage:
    """One entry as the engine holds it: the fields :class:`FetchedPage` reads.

    ``text`` is the full extraction on an entry built by :meth:`put`, and the
    window to serve on one built by :meth:`get_window` — the same shape
    either way, because the engine only turns one into a ``FetchedPage``.
    ``truncated`` carries a windowed read's ``more_remains``; a full entry
    leaves it ``False``.
    """

    url: str
    title: str | None
    text: str
    content_type: str | None
    status_code: int
    path_addressable: bool
    total_chars: int
    truncated: bool = False


def _cut(head: str, *, offset: int, max_chars: int, total: int) -> tuple[str, bool]:
    """The window ``[offset, offset + max_chars)`` of a page, from its head.

    ``head`` holds the characters ``[0, offset + max_chars + 2)`` of the body
    — or the body entire, when it is shorter. This mirrors the cut in
    ``fetcher.window_text`` line for line, with every length test run against
    the *true* total rather than ``len(head)``: the logic only ever reads
    inside ``[offset, offset + max_chars]``, which the head covers by
    construction, and the head is shorter than the body only when the body
    is — so the two are byte-equal everywhere it can matter, and the test
    suite pins that over generated texts and offsets.
    """
    remainder = head[offset:]
    if len(remainder) <= max_chars and offset <= total:
        return remainder, False
    window = head[offset : offset + max_chars + 1]
    cut = window.rfind("\n\n")
    if cut <= max_chars // 2:
        cut = max_chars
    more_remains = offset + cut < total or offset > total
    sliced = head[offset : offset + cut].rstrip()
    if sliced and more_remains:
        sliced += "\n\n[...]"
    return sliced, more_remains


def _meta_str(meta: dict[str, object], key: str) -> str | None:
    """A string sidecar field, or ``None`` off a foreign file's wrong shape."""
    value = meta.get(key)
    return value if isinstance(value, str) else None


def _meta_int(meta: dict[str, object], key: str) -> int:
    """An integer sidecar field, or ``0`` off the same wrong shape."""
    value = meta.get(key)
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


class DiskPageCache:
    """One directory of page entries: bounded, TTL'd, and read by window."""

    def __init__(
        self,
        directory: str,
        *,
        max_bytes: int = DEFAULT_MAX_BYTES,
        max_entry_bytes: int = DEFAULT_MAX_ENTRY_BYTES,
        ttl_seconds: float = DEFAULT_TTL_SECONDS,
    ) -> None:
        """Prepare ``directory``; it is created if absent, failing loudly if not.

        A directory this process cannot create or use is a startup problem,
        not a cache miss typed lazily all day long: the :class:`OSError` from
        the ``makedirs`` reaches the engine's builder, which is where a
        filesystem fault becomes a refusal to start.
        """
        self.directory = directory
        self.max_bytes = max_bytes
        self.max_entry_bytes = max_entry_bytes
        self.ttl_seconds = ttl_seconds
        os.makedirs(directory, exist_ok=True)
        # Eviction lists and unlinks concurrently with reads and writes; one
        # in-process lock serialises those, and atomic writes already mean a
        # reader never sees a half entry whatever this lock does.
        self._evictions = threading.Lock()

    def _paths(self, name: str) -> tuple[str, str]:
        root = os.path.join(self.directory, name)
        return root + _BODY_SUFFIX, root + _META_SUFFIX

    def _read_meta(self, name: str) -> dict[str, object] | None:
        """One entry's sidecar, with expired entries removed: the pre-body check.

        Both read paths apply this before touching the body — an expired
        entry is a miss whatever the body still holds, and a truncated or
        foreign sidecar is as good as an absent one, so the entry is removed
        and the caller re-fetches.
        """
        _, meta_path = self._paths(name)
        try:
            with open(meta_path, encoding="utf-8") as fh:
                meta: dict[str, object] = json.load(fh)
            created = meta["created"]
            if isinstance(created, bool) or not isinstance(created, (int, float)):
                raise TypeError("created is not a timestamp")
            if time.time() - created > self.ttl_seconds:
                self._remove(name)
                return None
        except (OSError, ValueError, KeyError, TypeError):
            return None
        return meta

    def get(self, provider: str, url: str) -> CachedPage | None:
        """The full entry, or ``None`` — for the reads that select over a page.

        The whole body reads into one string and the caller frees it after its
        selections run; that transient cost is the one a ``query``/``path``
        call already pays against a live fetch. Any filesystem or decode
        fault reads as a miss, so a corrupted entry heals by re-fetching
        rather than failing a page.
        """
        name = entry_name(provider, url)
        meta = self._read_meta(name)
        if meta is None:
            return None
        body_path, _ = self._paths(name)
        try:
            with open(body_path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            return None
        # LRU currency: a hit refreshes the body's atime and never rewrites it.
        self._touch(body_path)
        return CachedPage(
            url=_meta_str(meta, "url") or url,
            title=_meta_str(meta, "title"),
            text=text,
            content_type=_meta_str(meta, "content_type"),
            status_code=_meta_int(meta, "status_code"),
            path_addressable=meta.get("path_addressable") is True,
            total_chars=_meta_int(meta, "total_chars"),
        )

    def get_window(
        self, provider: str, url: str, *, offset: int, max_chars: int
    ) -> CachedPage | None:
        """One window of an entry, streamed — the path a paged read takes.

        Reads only enough of the body to serve ``[offset, offset + max_chars)``
        and answer "more remains": an incremental UTF-8 decoder stops once
        ``offset + max_chars + 2`` characters are in hand, then :func:`_cut`
        applies the same slice the live fetch would have applied. A paged
        read of a document far larger than the window holds the window, not
        the body — the RSS story the engine's paged reads make is this
        method's to keep. Counts are over the *decoded* text, never the
        bytes, because the caller's offsets index the extraction.

        A decode or filesystem fault mid-read reads as a miss too, so a
        corrupted body heals by re-fetching rather than failing a page.
        """
        name = entry_name(provider, url)
        meta = self._read_meta(name)
        if meta is None:
            return None
        body_path, _ = self._paths(name)
        total = _meta_int(meta, "total_chars")
        decoder = codecs.getincrementaldecoder("utf-8")()
        parts: list[str] = []
        count = 0
        want = offset + max_chars + _WINDOW_LOOKAHEAD
        try:
            # The load-bearing touch: atime has to move on a hit even when
            # nothing else about the read does, so it rides the same open as
            # the streaming.
            self._touch(body_path)
            with open(body_path, "rb") as fh:
                while count < want:
                    chunk = fh.read(_CHUNK)
                    if not chunk:
                        break
                    text = decoder.decode(chunk)
                    if text:
                        # At exactly `want` characters the cut has all it
                        # needs; holding the stream beyond that would hold
                        # the body the streaming promise says it never does.
                        parts.append(text[: want - count])
                        count += len(text)
        except (OSError, UnicodeDecodeError):
            return None
        window, truncated = _cut(
            "".join(parts), offset=offset, max_chars=max_chars, total=total
        )
        return CachedPage(
            url=_meta_str(meta, "url") or url,
            title=_meta_str(meta, "title"),
            text=window,
            content_type=_meta_str(meta, "content_type"),
            status_code=_meta_int(meta, "status_code"),
            path_addressable=meta.get("path_addressable") is True,
            total_chars=total,
            truncated=truncated,
        )

    def put(self, provider: str, url: str, page: CachedPage) -> bool:
        """Store one successful text page, atomically; ``False`` when too large.

        ``page`` is the *whole* extraction — the uncapped read the engine is
        already holding on a miss, stored here before the window that call
        serves is cut back out of the entry. The per-entry cap is the first
        bound: a page above it is never an entry, so a hostile page fetched
        live once costs disk nothing. ``total_chars`` is stored rather than
        recounted on read — the sidecar is the one place the engine gets it
        without holding the body.
        """
        body = page.text.encode("utf-8")
        if len(body) > self.max_entry_bytes:
            return False
        name = entry_name(provider, url)
        body_path, meta_path = self._paths(name)
        meta: dict[str, object] = {
            "url": page.url,
            "title": page.title,
            "content_type": page.content_type,
            "status_code": page.status_code,
            "path_addressable": page.path_addressable,
            "total_chars": page.total_chars,
            "created": time.time(),
            "body_bytes": len(body),
        }
        # Both halves are written through a temporary file and renamed: a
        # reader can only ever see the placed file or the old one, whatever
        # order the two renames land in. A full disk or an unwritable
        # directory returns ``False`` rather than a fetch failure — the page
        # was already downloaded and is served with or without an entry.
        try:
            for path, payload in (
                (body_path, body),
                (meta_path, json.dumps(meta).encode("utf-8")),
            ):
                fd, tmp = tempfile.mkstemp(dir=self.directory, suffix=".tmp")
                try:
                    with os.fdopen(fd, "wb") as fh:
                        fh.write(payload)
                    os.replace(tmp, path)
                except BaseException:
                    # A half pair is as good as a miss on both read paths, so
                    # the losing temporary only has to stop existing.
                    with suppress(OSError):
                        os.unlink(tmp)
                    raise
        except OSError:
            return False
        with self._evictions:
            self._evict_to_cap()
        return True

    def stats(self) -> dict[str, int]:
        """Entry count and total body bytes, for the ``--check`` line.

        Counts *bodies*, since the cap is measured over them; a body whose
        sidecar vanished is a miss the read paths already treat as absent,
        and this figure is a diagnosis, not a serving decision.
        """
        bodies = [
            name
            for name in os.listdir(self.directory)
            if name.endswith(_BODY_SUFFIX)
        ]
        total = 0
        for name in bodies:
            try:
                total += os.path.getsize(os.path.join(self.directory, name))
            except OSError:
                pass
        return {"entries": len(bodies), "bytes": total}

    def _touch(self, body_path: str) -> None:
        """One hit's ``os.utime`` on the body: the order the LRU reads."""
        with suppress(OSError):
            os.utime(body_path)

    def _remove(self, name: str) -> None:
        for path in self._paths(name):
            with suppress(OSError):
                os.unlink(path)

    def _evict_to_cap(self) -> None:
        """Unlink the oldest-accessed entries until the directory is under the cap.

        A caller's own entry is the newest-accessed thing on disk, so this
        never deletes what was just written before anything older. Bodies and
        sidecars die together per entry, and the byte counts are read off the
        bodies — the size a visitor measures the directory by.
        """
        entries: list[tuple[float, int, str]] = []
        total = 0
        for file_name in os.listdir(self.directory):
            if not file_name.endswith(_BODY_SUFFIX):
                continue
            path = os.path.join(self.directory, file_name)
            try:
                stats = os.stat(path)
            except OSError:
                continue
            entries.append(
                (stats.st_atime, stats.st_size, file_name[: -len(_BODY_SUFFIX)])
            )
            total += stats.st_size
        if total <= self.max_bytes:
            return
        for _atime, size, name in sorted(entries):
            if total <= self.max_bytes:
                break
            self._remove(name)
            total -= size
