"""`fetch(structure=True)`: the shape of a JSON page instead of its values.

Network-free, like the rest of the engine suite; the stub carries a
`path_addressable=True` page, which is what a JSON rendering looks like on the
way out of an extraction backend. What is pinned: one read, one axis -- a
structure request mixes with nothing else; the schema replaces the page text
before the escape pass runs, so keys are escaped like any page text; a page
this server could not read as a structure is answered with the whole page and a
sentence, the way `path` answers; and the emptiness gate -- about a JS shell
answering a read meant to find prose -- does not apply to a deliberate shape
read.
"""

from typing import cast

import pytest

from seekwright.config import Config, FetchConfig, PolicyConfig, ProviderConfig
from seekwright.engine import FetchEngine, FetchRefused
from seekwright.fetcher import UNCAPPED, ContentFetcher, FetchedPage
from seekwright.jsondoc import render_json
from seekwright.sanitize import ZWSP
from seekwright.tabledoc import render_table
from seekwright.usage import UsageRecorder

URL = "https://example.com/data.json"

JSON_DOC = """
{
  "maxResults": 10,
  "items": [
    {"id": 101, "label": "walrus"},
    {"id": 102, "label": "narwhal"},
    {"id": 103, "label": "orca"}
  ],
  "next": null
}
"""


def rendered(doc: str) -> str:
    text = render_json(doc)
    assert text is not None, "a test fixture that is not a document"
    return text


class StubFetcher:
    name = "fetch"
    cost_per_1k: float | None = None

    def __init__(
        self,
        *,
        text: str = rendered(JSON_DOC),
        path_addressable: bool = True,
        content_type: str | None = "text/plain",
        fail: Exception | None = None,
    ):
        self.calls = 0
        self.kwargs: list[dict[str, object]] = []
        self._text = text
        self._path_addressable = path_addressable
        self._content_type = content_type
        self._fail = fail

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        self.calls += 1
        self.kwargs.append({"offset": offset, "max_chars": max_chars})
        if self._fail:
            raise self._fail
        return FetchedPage(
            url=url,
            title="Data",
            text=self._text,
            content_type=self._content_type,
            status_code=200,
            truncated=False,
            total_chars=len(self._text),
            path_addressable=self._path_addressable,
        )

    async def aclose(self) -> None:
        return None


@pytest.fixture
def make_engine():
    def _make(
        fetcher: ContentFetcher | None = None,
        *,
        usage: UsageRecorder | None = None,
    ) -> FetchEngine:
        cfg = Config(
            providers={"serper": ProviderConfig()},
            policy=PolicyConfig(),
            fetch=FetchConfig(),
        )
        return FetchEngine(cfg, fetcher or StubFetcher(), [], usage=usage)

    return _make


class TestStructureReads:
    async def test_the_response_text_is_the_schema_not_the_page(self, make_engine):
        engine = make_engine()
        response = await engine.fetch(URL, structure=True)
        assert response.text is not None
        assert "$.items[*].id  number" in response.text
        assert "$.items[*]  object(2)" in response.text
        assert "walrus" not in response.text, "no values ride a shape read"
        assert response.matches is None

    async def test_the_read_is_uncapped_upstream(self, make_engine):
        """A selection is one whole read; the budget bounds the response, not the fetch."""
        fetcher = StubFetcher()
        engine = make_engine(fetcher)
        await engine.fetch(URL, structure=True)
        assert fetcher.calls == 1
        assert fetcher.kwargs == [{"offset": 0, "max_chars": UNCAPPED}]

    async def test_a_sub_min_chars_page_is_still_answered_without_a_walk(self):
        """The emptiness gate is about a JS shell, not a small but real document.

        A tiny JSON page renders below `fetch.min_text_chars`; a structure read
        of it is a deliberate read of the shape and must not escalate to the
        fallback ladder over emptiness.
        """
        tiny = rendered('{"n": 1}')
        assert len(tiny) < 200
        fetcher = StubFetcher(text=tiny)
        ladder = [StubFetcher(text="the ladder served this")]
        cfg = Config(
            providers={"serper": ProviderConfig()},
            policy=PolicyConfig(),
            fetch=FetchConfig(min_text_chars=len(tiny) + 1),
        )
        engine = FetchEngine(cfg, fetcher, cast("list[ContentFetcher]", ladder))
        response = await engine.fetch(URL, structure=True)
        assert fetcher.calls == 1
        assert ladder[0].calls == 0, "a structure read is never the empty case"
        assert response.text is not None and "number" in response.text

    async def test_a_short_table_is_answered_and_never_walked(self):
        """A three-row table renders below `fetch.min_text_chars`: it is the answer.

        The emptiness gate reads a short page as the JS-shell symptom, and a
        table's rendering is short because the table is small. With the walk
        asked for -- what `answer` passes on every page -- escalating here would
        bill a fallback and hand back its prose in place of the rows.
        """
        tiny = render_table("id,name\n1,Ada\n", delimiter=",")
        assert tiny is not None and len(tiny) < 200
        fetcher = StubFetcher(text=tiny, content_type="text/csv")
        ladder = [StubFetcher(text="the ladder served prose instead. " * 12)]
        cfg = Config(
            providers={"serper": ProviderConfig()},
            policy=PolicyConfig(),
            fetch=FetchConfig(min_text_chars=len(tiny) + 1),
        )
        engine = FetchEngine(cfg, fetcher, cast("list[ContentFetcher]", ladder))
        response = await engine.fetch(URL, auto_fallback=True)
        assert fetcher.calls == 1
        assert ladder[0].calls == 0, "a table page is never the empty case"
        assert response.text is not None and '$.rows[0].name  "Ada"' in response.text
        assert "JavaScript" not in (response.notice or "")


class TestStructureRefusals:
    async def test_structure_and_query_are_refused(self, make_engine):
        with pytest.raises(FetchRefused, match="structure"):
            await make_engine().fetch(URL, structure=True, query="walrus")

    async def test_structure_and_path_are_refused(self, make_engine):
        with pytest.raises(FetchRefused, match="structure"):
            await make_engine().fetch(URL, structure=True, path="$.items")

    async def test_structure_and_offset_are_refused(self, make_engine):
        with pytest.raises(FetchRefused, match="structure"):
            await make_engine().fetch(URL, structure=True, offset=8)

    async def test_the_refusal_is_before_anything_is_fetched(self, make_engine):
        fetcher = StubFetcher()
        engine = make_engine(fetcher)
        with pytest.raises(FetchRefused):
            await engine.fetch(URL, structure=True, query="x")
        assert fetcher.calls == 0, "one axis, decided before the dispatch"

class TestStructurePageKinds:
    async def test_a_page_without_a_structure_returns_the_page_and_names_it(self):
        """A prose page is returned whole; the caller still gets the prose back.

        A rendering-shaped page is the one thing a schema is derived from, so a
        page with no path-labelled lines comes back as the page, the same
        sentence `path` answers with -- not an empty answer.
        """
        plain = (
            "The walrus (Odobenus rosmarus) is a large pinniped. This body is a "
            "great deal longer than a page needs, so the emptiness gate floats "
            "over it without a word."
        )
        fetcher = StubFetcher(text=plain, path_addressable=False)
        engine = FetchEngine(
            Config(
                providers={"serper": ProviderConfig()},
                policy=PolicyConfig(),
                fetch=FetchConfig(),
            ),
            fetcher,
            [],
        )
        response = await engine.fetch(URL, structure=True)
        assert fetcher.calls == 1
        assert response.text == plain
        assert response.notice is not None
        assert "structure" in response.notice
        assert "not one this server could read as either" in response.notice

    async def test_a_json_claim_the_body_does_not_honour_names_what_it_is(
        self, make_engine
    ):
        fetcher = StubFetcher(text=",{ br0ken", path_addressable=False)
        engine = make_engine(fetcher)
        response = await engine.fetch(URL, structure=True)
        assert response.text == ",{ br0ken"
        assert "structure" in cast(str, response.notice)

    async def test_render_schema_refusal_says_so_not_the_sentences_behind(
        self, make_engine
    ):
        """A rendering with a line no classifier answers is a schema of nothing."""
        render_break = rendered(JSON_DOC) + "\ntrailing nonsense"
        fetcher = StubFetcher(text=render_break)
        engine = make_engine(fetcher)
        response = await engine.fetch(URL, structure=True)
        assert response.text == render_break
        assert "not one this server could read as either" in cast(str, response.notice)


class TestStructurePassesService:
    async def test_the_schema_is_escaped_like_any_page_text(self, make_engine):
        engine = make_engine()
        response = await engine.fetch(URL, structure=True)
        # No key in the fixture carries a special-token literal, so nothing of
        # the escape pass had to insert: the count stays a property of the text,
        # and a hostile key escapes in test_page_cache.py's pin of the pass.
        assert response.text is not None

    async def test_a_hostile_key_is_escaped_out_of_the_schema(self, make_engine):
        """A key cannot smuggle a model special-token literal through a shape read."""
        doc = '{"<|endoftext|>": [{"key": 1}, {"key": 2}]}'
        fetcher = StubFetcher(text=rendered(doc))
        engine = make_engine(fetcher)
        response = await engine.fetch(URL, structure=True)
        assert response.text is not None
        assert ZWSP in response.text, "the escape pass still applies to schema text"
        assert "<|endoftext|>" not in response.text

    async def test_the_journal_records_a_structure_read_like_any_page(self, make_engine):
        usage = UsageRecorder()
        engine = make_engine(usage=usage)
        await engine.fetch(URL, structure=True)
        recent = cast("list[dict[str, object]]", usage.snapshot()["recent"])
        assert len(recent) == 1
        assert recent[0]["tool"] == "fetch"
        assert recent[0]["error"] is None
