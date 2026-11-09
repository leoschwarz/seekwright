"""The disk page cache: the module, and the seam the fetch engine reads it through.

Unit tests of :class:`pagecache.DiskPageCache` run the class synchronously -- its
methods block, and the engine is what puts them in a worker thread. The seam
tests run two fetches of the same URL through a real :class:`FetchEngine` and
count what the stub fetched: what the cache promises is one download per page,
and a call count is the only honest way to observe it.

The byte-equality sweep is the load-bearing pin: ``pagecache._cut`` mirrors
``fetcher.window_text`` by construction, because the ring the cache makes
(``pagecache`` imports nothing of the package) is worth exactly what the mirror
costs, and the mirror is true only while that test keeps passing.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
from typing import Any, cast

import pytest

from seekwright.config import Config, FetchConfig, PolicyConfig, ProviderConfig
from seekwright.engine import FetchEngine
from seekwright.fetcher import UNCAPPED, ContentFetcher, FetchedPage, window_text
from seekwright.jsondoc import render_json
from seekwright.pagecache import CachedPage, DiskPageCache, _cut, entry_name
from seekwright.usage import UsageRecorder

URL = "https://example.com/article"


def usage_snapshot(rec: Any) -> dict[str, Any]:
    """The dashboard state typed loosely, the way tests/test_usage.py reads it."""
    return cast("dict[str, Any]", rec.snapshot())


def _rendered(doc: str) -> str:
    text = render_json(doc)
    assert text is not None, "a test fixture that is not a document"
    return text

PAGE_TEXT = (
    "The page body. Every fetch test that means to exercise a successful "
    "extraction uses this string, so it has to be long enough that the engine "
    "does not mistake it for the nav stub a JavaScript-rendered page leaves "
    "behind. Anything shorter is the empty case, which has its own tests "
    "and this one clears the bar twice over."
)


def make_cfg(**cache) -> Config:
    return Config(
        providers={"serper": ProviderConfig()},
        policy=PolicyConfig(),
        fetch=FetchConfig(**cache),
    )


class CountingFetcher:
    """A stub that counts what it was asked for and can slow one call.

    ``cost_per_1k`` is set so the journal can tell a billed live call from a
    cache hit -- the distinction the seam exists to make.
    """

    name = "scrappa"
    cost_per_1k: float | None = 0.001

    def __init__(
        self,
        *,
        delay: float = 0.0,
        text: str = PAGE_TEXT,
        path_addressable: bool = False,
    ):
        self.calls = 0
        self.seen: list[tuple[int, int | None]] = []
        self._delay = delay
        self._text = text
        self._path_addressable = path_addressable

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        self.calls += 1
        self.seen.append((offset, max_chars))
        if self._delay:
            await asyncio.sleep(self._delay)
        return FetchedPage(
            url=url,
            title="A Page",
            text=self._text,
            content_type="text/html",
            status_code=200,
            truncated=False,
            total_chars=len(self._text),
            path_addressable=self._path_addressable,
        )

    async def aclose(self) -> None:
        return None


def engine_with_cache(
    fetcher: ContentFetcher, cache: DiskPageCache, *, usage: UsageRecorder | None = None
) -> FetchEngine:
    return FetchEngine(make_cfg(), fetcher, usage=usage, cache=cache)


def cached_engine(tmp_path, fetcher: ContentFetcher, *, usage=None) -> FetchEngine:
    return engine_with_cache(
        fetcher,
        DiskPageCache(str(tmp_path / "pages"), max_bytes=1 << 20, max_entry_bytes=1 << 20),
        usage=usage,
    )


class TestDiskPageCacheUnits:
    def test_put_get_roundtrips_the_whole_page(self, tmp_path):
        cache = DiskPageCache(str(tmp_path))
        page = CachedPage(
            url=URL,
            title="A Page",
            text=PAGE_TEXT,
            content_type="text/html",
            status_code=200,
            path_addressable=False,
            total_chars=len(PAGE_TEXT),
        )
        assert cache.put("http", URL, page) is True
        entry = cache.get("http", URL)
        assert entry is not None
        assert entry.text == PAGE_TEXT
        assert entry.url == URL
        assert entry.title == "A Page"
        assert entry.total_chars == len(PAGE_TEXT)

    def test_provider_isolation(self, tmp_path):
        """The local read and a fallback's are different answers to one URL."""
        cache = DiskPageCache(str(tmp_path))
        page = CachedPage(
            url=URL, title=None, text=PAGE_TEXT, content_type=None,
            status_code=200, path_addressable=False, total_chars=len(PAGE_TEXT),
        )
        cache.put("http", URL, page)
        assert cache.get("scrappa", URL) is None
        # The same pair a second time is the same entry: the key is stable.
        entry = cache.get("http", URL)
        assert entry is not None
        assert entry.text == PAGE_TEXT

    def test_unknown_url_is_a_miss_without_removing_anything(self, tmp_path):
        cache = DiskPageCache(str(tmp_path))
        cache.put("http", URL, CachedPage(
            url=URL, title=None, text=PAGE_TEXT, content_type=None,
            status_code=200, path_addressable=False, total_chars=len(PAGE_TEXT),
        ))
        assert cache.get("http", "https://example.com/other") is None
        assert cache.get("http", URL) is not None

    def test_an_entry_over_the_per_entry_cap_is_refused(self, tmp_path):
        cache = DiskPageCache(str(tmp_path), max_entry_bytes=1024)
        page = CachedPage(
            url=URL, title=None, text="x" * 4096, content_type=None,
            status_code=200, path_addressable=False, total_chars=4096,
        )
        assert cache.put("http", URL, page) is False
        assert cache.get("http", URL) is None

    def test_ttl_expiry_reads_as_a_miss_and_removes_the_entry(self, tmp_path):
        cache = DiskPageCache(str(tmp_path), ttl_seconds=0.05)
        cache.put("http", URL, CachedPage(
            url=URL, title=None, text=PAGE_TEXT, content_type=None,
            status_code=200, path_addressable=False, total_chars=len(PAGE_TEXT),
        ))
        assert cache.get("http", URL) is not None
        time.sleep(0.1)
        assert cache.get("http", URL) is None
        # Removed on read, not merely expired: the directory holds nothing.
        assert [n for n in os.listdir(str(tmp_path)) if n.endswith(".body")] == []

    def test_get_window_is_byte_equal_to_the_live_window(self, tmp_path):
        """The whole point of the seam: a cached paged read nobody can tell apart.

        Long enough for the paragraph cut to matter, and swept over offsets on
        both sides of the boundary conditions -- the start, the end, and past
        the end."""
        cache = DiskPageCache(str(tmp_path))
        text = "\n\n".join(f"paragraph {i} of the body text." for i in range(60))
        cache.put("http", URL, CachedPage(
            url=URL, title=None, text=text, content_type=None,
            status_code=200, path_addressable=False, total_chars=len(text),
        ))
        for offset in (0, 1, 5, 100, len(text) - 1, len(text), len(text) + 10):
            for cap in (10, 40, 400, 40_000):
                window = cache.get_window("http", URL, offset=offset, max_chars=cap)
                expected, truncated = window_text(text, offset=offset, max_chars=cap)
                assert window is not None, (offset, cap)
                assert (window.text, window.truncated) == (
                    expected or "",
                    truncated,
                ), (offset, cap)

    def test_cut_matches_window_text_over_a_generated_sweep(self):
        for text in ("", "a", "one\n\ntwo\n\nthree", "word " * 500):
            for offset in (0, 3, 120, len(text), len(text) + 7):
                for cap in (1, 8, 50):
                    assert _cut(text, offset=offset, max_chars=cap, total=len(text)) == (
                        window_text(text, offset=offset, max_chars=cap)
                    ), (text[:20], offset, cap)

    def test_a_window_read_streams_only_the_window(self, tmp_path):
        """A paged read of a large page holds the page's window, not its body."""
        cache = DiskPageCache(str(tmp_path), max_entry_bytes=1 << 20)
        text = "\n\n".join(f"paragraph {i}." for i in range(40_000))
        cache.put("http", URL, CachedPage(
            url=URL, title=None, text=text, content_type=None,
            status_code=200, path_addressable=False, total_chars=len(text),
        ))
        window = cache.get_window("http", URL, offset=500_000, max_chars=400)
        assert window is not None
        expected, truncated = window_text(text, offset=500_000, max_chars=400)
        assert window.text == expected
        assert window.truncated == truncated

    def test_lru_eviction_drops_the_oldest_accessed_bodies(self, tmp_path):
        directory = str(tmp_path)
        # Entries are staged through a cache whose cap nothing trips, because
        # eviction runs inside `put`: all four must exist before the atimes are
        # set ahead of the one put that runs the scan under the real cap.
        urls = [f"https://example.com/{i}" for i in range(4)]
        for name in urls:
            DiskPageCache(directory, max_bytes=1_000_000, max_entry_bytes=200).put(
                "http",
                name,
                CachedPage(
                    url=name, title=None, text="y" * 100, content_type=None,
                    status_code=200, path_addressable=False, total_chars=100,
                ),
            )
        # Age the bodies explicitly, in creation order: the first stored is the
        # least recently used. Sorting the directory would order by hash, and
        # the atime is the only thing the eviction reads.
        cache = DiskPageCache(directory, max_bytes=300, max_entry_bytes=200)
        now = time.time()
        for i, name in enumerate(urls):
            stamp = now - (100 - i)
            os.utime(os.path.join(directory, entry_name("http", name) + ".body"),
                     (stamp, stamp))
        cache.put("http", URL, CachedPage(
            url=URL, title=None, text="z" * 100, content_type=None,
            status_code=200, path_addressable=False, total_chars=100,
        ))
        bodies = {n for n in os.listdir(directory) if n.endswith(".body")}
        # Two evictions fit the cap again; the two oldest are the ones that go.
        assert len(bodies) == 3
        assert cache.get("http", "https://example.com/0") is None
        assert cache.get("http", "https://example.com/1") is None
        assert cache.get("http", "https://example.com/2") is not None
        assert cache.get("http", URL) is not None

    def test_stats_counts_bodies(self, tmp_path):
        cache = DiskPageCache(str(tmp_path))
        assert cache.stats() == {"entries": 0, "bytes": 0}
        cache.put("http", URL, CachedPage(
            url=URL, title=None, text=PAGE_TEXT, content_type=None,
            status_code=200, path_addressable=False, total_chars=len(PAGE_TEXT),
        ))
        stats = cache.stats()
        assert stats["entries"] == 1
        assert stats["bytes"] == len(PAGE_TEXT.encode())

    def test_entry_name_is_stable_and_field_separated(self):
        assert entry_name("http", URL) == entry_name("http", URL)
        assert entry_name("http", URL) != entry_name("scrappa", URL)
        assert entry_name("scrappa", URL) != entry_name("scra", "ppa " + URL[4:])


class TestEngineSeam:
    async def test_a_cold_then_warm_fetch_downloads_once(self, tmp_path):
        fetcher = CountingFetcher()
        engine = cached_engine(tmp_path, fetcher)
        first = await engine.fetch(URL)
        assert fetcher.calls == 1
        second = await engine.fetch(URL, offset=10)
        assert fetcher.calls == 1, "a warm entry must serve without a dispatch"
        assert second.text == (first.text or "")[10:]
        assert second.total_chars == first.total_chars

    async def test_a_warm_fetch_serves_the_window_a_live_fetch_would(self, tmp_path):
        text = "\n\n".join(f"paragraph {i} of the body." for i in range(300))
        cache = DiskPageCache(
            str(tmp_path / "p"), max_bytes=1 << 22, max_entry_bytes=1 << 22
        )
        cached = CountingFetcher(text=text)
        cfg = make_cfg(max_text_chars=400)
        with_cache = FetchEngine(cfg, cached, cache=cache)
        r = await with_cache.fetch(URL)
        assert cached.calls == 1
        # The cache fills UNCAPPED; the served window is the same one
        # window_text cuts out of the page -- where windowing matters, because
        # the page is far larger than the 400-char cap.
        expected, truncated = window_text(text, offset=0, max_chars=400)
        assert r.text == expected
        assert r.truncated == truncated
        assert r.total_chars == len(text)
        warm = await with_cache.fetch(URL, offset=500)
        assert cached.calls == 1
        expected, truncated = window_text(text, offset=500, max_chars=400)
        assert warm.text == expected
        assert warm.truncated == truncated

    async def test_warm_response_matches_the_uncached_response_field_for_field(
        self, tmp_path
    ):
        fetcher = CountingFetcher()
        engine = cached_engine(tmp_path, fetcher)
        await engine.fetch(URL)
        await engine.fetch(URL)
        cold = FetchEngine(make_cfg(), CountingFetcher())
        live = await cold.fetch(URL)
        warm = await engine.fetch(URL)
        for field in ("url", "requested_url", "title", "content_type", "status_code",
                      "truncated", "total_chars", "text"):
            assert getattr(warm, field) == getattr(live, field), field

    async def test_a_selection_read_takes_the_whole_entry_uncapped(self, tmp_path):
        fetcher = CountingFetcher()
        engine = cached_engine(tmp_path, fetcher)
        await engine.fetch(URL, query="body")
        assert fetcher.seen == [(0, UNCAPPED)]
        # A second selection is served from the entry, still uncapped upstream.
        await engine.fetch(URL, query="body")
        assert fetcher.calls == 1

    async def test_a_structure_read_is_uncapped_then_warm(self, tmp_path):
        """A shape read fills at the whole rendering, and re-reads pay no dispatch.

        The schema replacement happens *after* the read, on the serving path,
        so the entry keeps the rendering a `path` drill addresses -- a
        structure read that stored its own output would coral the drill into
        interpreting a schema's `[*]`, which no document contains.
        """
        fetcher = CountingFetcher(
            # Long enough to clear fetch.min_text_chars: a tiny rendering is
            # the empty case for a drill, wherever the read came from.
            text=_rendered(json.dumps({"k": "x" * 220})),
            path_addressable=True,
        )
        engine = cached_engine(tmp_path, fetcher)
        response = await engine.fetch(URL, structure=True)
        assert fetcher.seen == [(0, UNCAPPED)]
        assert response.text is not None and "string" in response.text
        await engine.fetch(URL, structure=True)
        assert fetcher.calls == 1
        # The entry is the rendering, not the schema: a drill still works warm.
        drill = await engine.fetch(URL, path="$.k")
        assert drill.matches is not None

    async def test_a_paged_read_after_a_selection_read_is_still_warm(self, tmp_path):
        fetcher = CountingFetcher()
        engine = cached_engine(tmp_path, fetcher)
        await engine.fetch(URL, query="body")
        await engine.fetch(URL, offset=5)
        assert fetcher.calls == 1

    async def test_image_pages_are_served_live_and_stored_nothing(self, tmp_path):
        stub = ImageFetcher()
        engine = cached_engine(tmp_path, stub)
        first = await engine.fetch(URL)
        assert first.image is not None and first.image.byte_count == 3
        await engine.fetch(URL)
        assert stub.calls == 2, "an image page is never cached (v1 scope)"
        cache = DiskPageCache(str(tmp_path / "pages"))
        assert cache.get("http", URL) is None

    async def test_singleflight_fills_once_for_concurrent_readers(self, tmp_path):
        fetcher = CountingFetcher(delay=0.05)
        engine = cached_engine(tmp_path, fetcher)
        pages = await asyncio.gather(*(engine.fetch(URL) for _ in range(5)))
        assert fetcher.calls == 1
        for page in pages:
            assert page.text == PAGE_TEXT
        # The flight is over: a later read is warm with or without it.
        await engine.fetch(URL)
        assert fetcher.calls == 1

    async def test_a_blocked_url_is_refused_with_a_warm_entry(self, tmp_path):
        """Guardrails before the lookup: the cache cannot whitewash a URL."""
        from seekwright.engine import FetchFailed

        fetcher = CountingFetcher()
        engine = cached_engine(tmp_path, fetcher)
        await engine.fetch(URL)
        assert fetcher.calls == 1
        with pytest.raises(FetchFailed, match="refus"):
            await engine.fetch("https://user:pass@example.com/steal")
        assert fetcher.calls == 1

    async def test_an_entry_refused_on_store_falls_back_to_live_reads(self, tmp_path):
        """An over-cap page is never stored, so every read fetches."""
        cache = DiskPageCache(
            str(tmp_path / "pages"), max_bytes=4096, max_entry_bytes=16
        )
        stub = CountingFetcher()
        engine = engine_with_cache(stub, cache)
        await engine.fetch(URL)
        await engine.fetch(URL)
        assert stub.calls == 2

    async def test_a_walk_rung_hit_serves_warm(self, tmp_path):
        """The walk's rung reads through the same seam, so a second walk is warm."""
        stub = CountingFetcher()
        engine = FetchEngine(
            make_cfg(),
            DownFetcher(),
            [stub],
            cache=DiskPageCache(str(tmp_path / "p")),
        )
        first = await engine.fetch(URL, auto_fallback=True)
        assert stub.calls == 1
        assert first.text == PAGE_TEXT
        second = await engine.fetch(URL, auto_fallback=True)
        assert stub.calls == 1, "a walk serves its rung from the warm entry too"
        assert second.text == first.text

    async def test_a_named_fallback_call_is_warm_on_the_second_read(self, tmp_path):
        fetcher = CountingFetcher()
        engine = FetchEngine(
            make_cfg(),
            DownFetcher(),
            [fetcher],
            usage=UsageRecorder(),
            cache=DiskPageCache(str(tmp_path / "p")),
        )
        await engine.fetch(URL, provider="scrappa")
        assert fetcher.calls == 1
        r = await engine.fetch(URL, provider="scrappa", offset=10)
        assert fetcher.calls == 1
        assert r.text == PAGE_TEXT[10:]

    async def test_journal_marks_the_warm_call_unbilled(self, tmp_path):
        usage = UsageRecorder()
        fetcher = CountingFetcher()
        engine = FetchEngine(
            make_cfg(),
            DownFetcher(),
            [fetcher],
            usage=usage,
            cache=DiskPageCache(str(tmp_path / "p")),
        )
        await engine.fetch(URL, provider="scrappa")
        await engine.fetch(URL, provider="scrappa")
        snap = usage_snapshot(usage)
        recent: list[dict[str, Any]] = snap["recent"]  # newest first
        assert len(recent) == 2
        unbilled, billed = recent
        assert billed["fallback"] == "scrappa"
        assert billed["cost_usd"] == pytest.approx(0.001 / 1000)
        assert "cost_usd" not in unbilled, (
            "a dispatch-free read is unbilled even on a priced rung"
        )
        assert unbilled["fallback"] == "scrappa"


class DownFetcher:
    """A primary that always fails, so the fallback is the only page source."""

    name = "fetch"
    cost_per_1k: float | None = None

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        from seekwright.providers.base import ProviderError

        raise ProviderError("fetch", "the local reader is down in this test")

    async def aclose(self) -> None:
        return None


class ImageFetcher:
    """An image resource: bytes, no text, and nothing to store."""

    name = "fetch"
    cost_per_1k: float | None = None

    def __init__(self) -> None:
        from seekwright.fetcher import FetchedImage

        self.calls = 0
        self._image = FetchedImage(media_type="image/png", body=b"png")

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        self.calls += 1
        return FetchedPage(
            url=url, title=None, text="", content_type="image/png", status_code=200,
            truncated=False, total_chars=0, image=self._image,
        )

    async def aclose(self) -> None:
        return None
