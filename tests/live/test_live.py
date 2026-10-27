"""Live smoke tests against real providers.

Run explicitly, never by default:

    SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live

The env-var gate is the primary switch; per-provider tests additionally skip
unless the relevant API key is present. `exa:free`, `parallel:free`, `freeserp`
and `anysearch` need no key, so

    SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k "exa_free or parallel_free or freeserp or anysearch"

runs the riskiest integration (the MCP-client adapters) for free. The `-k`
expression spells the names snake_case because it selects *test names*, and a
`:` cannot appear in a Python identifier. Everything else here makes real, billed
calls -- `exa` included, because it is the keyed half of the same endpoint. Name
`exa:free` rather than `exa` for the free run. These tests cover what a hermetic
suite cannot: the parsers are otherwise only checked against API documentation.

Agent mode hermetically runs a stub model, so a real deployment is where its
assembly gets checked:

    SEEKWRIGHT_AGENT_BASE_URL=https://... SEEKWRIGHT_AGENT_MODEL=... \
    SEEKWRIGHT_AGENT_API_KEY=... \
    SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k agent_mode

Retrieval there rides the keyless set, so the only spend is the model call. A
slow endpoint -- a reasoning model asked for a `report` -- needs
`SEEKWRIGHT_AGENT_MODEL_TIMEOUT_SECONDS` raised as well; the shipped 30s is that
leg's ceiling.
"""

import os
from typing import Literal

import httpx
import pytest

from seekwright.config import Config, ProviderConfig
from seekwright.engine import SearchEngine
from seekwright.factory import build_providers
from seekwright.models import SearchQuery

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(
        os.environ.get("SEEKWRIGHT_LIVE_TESTS") != "1",
        reason="set SEEKWRIGHT_LIVE_TESTS=1 to run live smoke tests",
    ),
]

ALL_PROVIDERS = (
    "scrappa",
    "serper",
    "linkup",
    "exa",
    "exa:free",
    "parallel",
    "parallel:free",
    "searxng",
    "tavily",
    "tinyfish",
    "algolia",
    "freeserp",
    "search1api",
    "anysearch",
    "serpapi",
    "querit",
    "deepseek",
)


def _configured(name: str) -> bool:
    """`exa:free`, `parallel:free`, `freeserp` and `anysearch` are keyless and
    always available; everything else needs a key.

    `exa` is deliberately not exempt. It was, back when one `exa` covered both
    credentials -- which meant this suite billed for its "free" run whenever a
    key happened to be in the environment, silently, because the adapter picked
    the key up and nothing here looked.

    `searxng` is keyless but needs a configured instance URL
    (`SEEKWRIGHT_SEARXNG_URL`, fed into the config the fixture builds).

    `algolia` needs three env vars -- `SEEKWRIGHT_ALGOLIA_API_KEY` plus the
    index it must search, `SEEKWRIGHT_ALGOLIA_APP_ID` and
    `SEEKWRIGHT_ALGOLIA_INDEX` -- so it is configured only when all three are
    present.
    """
    if name in ("exa:free", "parallel:free", "freeserp", "anysearch"):
        return True
    if name == "searxng":
        return bool(os.environ.get("SEEKWRIGHT_SEARXNG_URL"))
    if name == "algolia":
        return bool(
            os.environ.get("SEEKWRIGHT_ALGOLIA_API_KEY")
            and os.environ.get("SEEKWRIGHT_ALGOLIA_APP_ID")
            and os.environ.get("SEEKWRIGHT_ALGOLIA_INDEX")
        )
    return bool(os.environ.get(f"SEEKWRIGHT_{name.upper()}_API_KEY"))


@pytest.fixture
def engine():
    def _provider_config(name: str) -> ProviderConfig:
        # searxng's endpoint is config, not a constant: the url rides the env var
        # _configured gates on.
        if name == "searxng":
            return ProviderConfig(url=os.environ["SEEKWRIGHT_SEARXNG_URL"])
        if name == "algolia":
            return ProviderConfig(
                app_id=os.environ["SEEKWRIGHT_ALGOLIA_APP_ID"],
                index=os.environ["SEEKWRIGHT_ALGOLIA_INDEX"],
            )
        return ProviderConfig()

    cfg = Config(
        providers={
            name: _provider_config(name)
            for name in ALL_PROVIDERS
            if _configured(name)
        }
    )

    async def make() -> tuple[SearchEngine, httpx.AsyncClient]:
        client = httpx.AsyncClient(follow_redirects=True)
        return SearchEngine(cfg, build_providers(cfg, client)), client

    return make


async def _search(engine, query: SearchQuery, provider: str):
    """Run one live search against the named provider.

    Always explicit: with several providers configured there is no default, and
    naming the one under test is the only way a test bills what it claims to.
    """
    eng, client = await engine()
    try:
        return await eng.search(query, provider=provider)
    finally:
        await client.aclose()


async def test_serper_search(engine):
    if not _configured("serper"):
        pytest.skip("SEEKWRIGHT_SERPER_API_KEY not set")
    r = await _search(engine, SearchQuery(query="python 3.14 release notes"), "serper")

    assert r.provider == "serper"
    assert r.results, "expected organic results from serper"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title


async def test_serper_domain_filter(engine):
    """The `site:` emulation must actually constrain returned URLs."""
    if not _configured("serper"):
        pytest.skip("SEEKWRIGHT_SERPER_API_KEY not set")
    r = await _search(
        engine,
        SearchQuery(query="generators", max_results=5, include_domains=["python.org"]),
        "serper",
    )
    assert r.results, "expected results restricted to python.org"
    for res in r.results:
        assert "python.org" in res.url


async def test_scrappa_search(engine):
    """The documented `organic_results` shape must survive contact with reality."""
    if not _configured("scrappa"):
        pytest.skip("SEEKWRIGHT_SCRAPPA_API_KEY not set")
    r = await _search(engine, SearchQuery(query="python 3.14 release notes"), "scrappa")

    assert r.provider == "scrappa"
    assert r.results, "expected organic results from scrappa"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title


async def test_scrappa_domain_filter(engine):
    """The shared `site:` emulation, against Scrappa's index rather than Serper's."""
    if not _configured("scrappa"):
        pytest.skip("SEEKWRIGHT_SCRAPPA_API_KEY not set")
    r = await _search(
        engine,
        SearchQuery(query="generators", max_results=5, include_domains=["python.org"]),
        "scrappa",
    )
    assert r.results, "expected results restricted to python.org"
    for res in r.results:
        assert "python.org" in res.url


async def test_linkup_answer(engine):
    """sourcedAnswer parsing: prose plus citable sources."""
    if not _configured("linkup"):
        pytest.skip("SEEKWRIGHT_LINKUP_API_KEY not set")
    r = await _search(engine, SearchQuery(query="who discovered penicillin"), "linkup")

    assert r.answer, "expected a synthesised answer"
    assert r.results, "expected citable sources"


async def test_linkup_reports_a_geo_constraint_it_cannot_honour(engine):
    """The replacement for the capability filter, against the real endpoint."""
    if not _configured("linkup"):
        pytest.skip("SEEKWRIGHT_LINKUP_API_KEY not set")
    r = await _search(
        engine, SearchQuery(query="who discovered penicillin", country="de"), "linkup"
    )
    assert "country/language" in (r.notice or "")


async def test_exa_free_search(engine):
    """The MCP-client adapter: handshake, call, and block-format parsing.

    The one live test that costs nothing, which is why it is the one to reach
    for when all you want is to know the riskiest adapter still works.
    """
    r = await _search(
        engine, SearchQuery(query="rust async runtime", max_results=2), "exa:free"
    )

    assert r.results, "expected extracted page content from exa"
    assert r.results[0].url.startswith("http")
    assert r.provider == "exa:free"


async def test_exa_serves_from_the_free_tier_when_it_can(engine):
    """The ladder, against the real endpoint: a healthy free tier means a keyed
    `exa` search still costs nothing."""
    if not _configured("exa"):
        pytest.skip("SEEKWRIGHT_EXA_API_KEY not set")
    r = await _search(
        engine, SearchQuery(query="rust async runtime", max_results=2), "exa"
    )

    assert r.results, "expected extracted page content from exa"
    # `provider` stays the name the caller asked for; which credential ran shows
    # up in the notice, and only when it was the billed one.
    assert r.provider == "exa"
    assert r.notice is None or "API key" not in r.notice, (
        "the free tier was healthy, so this search should not have been billed"
    )


async def test_freeserp_search(engine):
    """The keyless web index: no account, no key, and the documented SERP shape
    pinned while it is fresh -- `results[].{url, title, snippet}`.

    One call, and it costs nothing. The one failure this test cannot tell apart
    from a broken mapping is `ProviderError: upstream index unavailable`: their
    web engine can answer `index=web` from the sites index instead
    (`engine_fallback: true`), which the adapter refuses by design -- so a
    failure here means the operator's engine is degraded, not that the parser
    drifted.
    """
    r = await _search(
        engine, SearchQuery(query="python asyncio tutorial", max_results=5), "freeserp"
    )

    assert r.provider == "freeserp"
    # The price is asserted on the provider in `tests/providers/test_freeserp.py`: cost stays
    # off the response by design (the caller is not the party paying).
    assert r.results, "expected web results from freeserp"
    with_snippet = [res for res in r.results if res.url and res.snippet]
    assert with_snippet, "expected at least one result with a url and a snippet"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title
        assert res.text is None, "a SERP backend fills `snippet`, never `text`"


async def test_parallel_search(engine):
    """The billed REST fallback: content results with `text`, never `snippet`."""
    if not _configured("parallel"):
        pytest.skip("SEEKWRIGHT_PARALLEL_API_KEY not set")
    r = await _search(
        engine, SearchQuery(query="python 3.14 release notes", max_results=3), "parallel"
    )

    assert r.provider == "parallel"
    assert r.results, "expected content results from parallel"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title
        assert res.snippet is None, "a content backend fills `text`, not `snippet`"


async def test_parallel_domain_filter(engine):
    """The native `source_policy.include_domains` must constrain returned URLs."""
    if not _configured("parallel"):
        pytest.skip("SEEKWRIGHT_PARALLEL_API_KEY not set")
    r = await _search(
        engine,
        SearchQuery(query="generators", max_results=5, include_domains=["python.org"]),
        "parallel",
    )
    assert r.results, "expected results restricted to python.org"
    for res in r.results:
        assert "python.org" in res.url


async def test_parallel_free_search(engine):
    """The free anonymous hosted MCP: the whole point of the second name.

    One call only -- anonymous rate limits are lower than a keyed tier's.
    Built inline rather than through `_search` so the zero price can be read
    off the provider: cost stays off the response by design (the caller is not
    the party paying).
    """
    eng, client = await engine()
    try:
        r = await eng.search(
            SearchQuery(query="rust async runtime", max_results=2),
            provider="parallel:free",
        )
        # The second name earns its keep by being unable to bill.
        assert eng.providers["parallel:free"].cost_per_1k == 0.0
    finally:
        await client.aclose()

    assert r.provider == "parallel:free"
    assert r.results, "expected content results from parallel:free"
    for res in r.results:
        assert res.url.startswith("http")


async def test_searxng_search(engine):
    """The metasearch adapter, against whatever instance the env names."""
    if not _configured("searxng"):
        pytest.skip("SEEKWRIGHT_SEARXNG_URL not set")
    r = await _search(engine, SearchQuery(query="python 3.14 release notes"), "searxng")

    assert r.provider == "searxng"
    # Cost stays off the response by design; the instance is the operator's own,
    # hence free.
    assert r.results, "expected aggregated results from the instance"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title


async def test_tavily_search(engine):
    """The content backend, against the real API: text results and an answer."""
    if not _configured("tavily"):
        pytest.skip("SEEKWRIGHT_TAVILY_API_KEY not set")
    r = await _search(
        engine,
        SearchQuery(query="python 3.14 release notes", max_results=3, recency="month"),
        "tavily",
    )

    assert r.provider == "tavily"
    assert r.results, "expected content results from tavily"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title
        assert res.text and not res.snippet, "content backends fill text, not snippet"
    # `include_answer: basic` is always sent, so prose should ride along too.
    assert r.answer


async def test_tavily_native_domain_filter(engine):
    """Domains go in the body's native fields, not folded into the query."""
    if not _configured("tavily"):
        pytest.skip("SEEKWRIGHT_TAVILY_API_KEY not set")
    r = await _search(
        engine,
        SearchQuery(query="generators", max_results=5, include_domains=["python.org"]),
        "tavily",
    )
    assert r.results, "expected results restricted to python.org"
    for res in r.results:
        assert "python.org" in res.url


async def test_tinyfish_search(engine):
    """The free keyed aggregator, against the real API -- and the documented
    shape pinned while it is fresh: `results[].{title, snippet, url}` with
    optional `date`."""
    if not _configured("tinyfish"):
        pytest.skip("SEEKWRIGHT_TINYFISH_API_KEY not set")
    r = await _search(
        engine,
        SearchQuery(query="python 3.14 release notes", max_results=3, recency="week"),
        "tinyfish",
    )

    assert r.provider == "tinyfish"
    assert r.cost_usd == 0.0
    assert r.results, "expected SERP results from tinyfish"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title
        assert res.snippet is not None and res.text is None, (
            "tinyfish is a SERP backend: snippet, never text"
        )


async def test_algolia_search(engine):
    """The index-scoped adapter, against the operator's own index.

    Needs three env vars, not one -- `_configured` and the fixture both gate on
    the index and app id -- so a bare API key alone skips rather than failing.
    """
    if not _configured("algolia"):
        pytest.skip("SEEKWRIGHT_ALGOLIA_{API_KEY,APP_ID,INDEX} not all set")
    r = await _search(
        engine, SearchQuery(query="python", max_results=3), "algolia"
    )

    assert r.provider == "algolia"
    assert r.results, "expected hits from the configured index"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title
        assert res.snippet is not None and res.text is None, (
            "algolia is a SERP-shaped adapter: snippet, never text"
        )


async def test_search1api_search(engine):
    """The multi-engine SERP adapter, against the real API.

    The first live run against the documented shape is what clears the
    untested status (``config.UNTESTED_PROVIDERS``) -- until it has run,
    ``--check`` and the startup line say so. One basic search: 1 credit,
    whatever ``max_results`` says.
    """
    if not _configured("search1api"):
        pytest.skip("SEEKWRIGHT_SEARCH1API_API_KEY not set")
    r = await _search(
        engine,
        SearchQuery(query="python 3.14 release notes", max_results=3),
        "search1api",
    )

    assert r.provider == "search1api"
    # The credit count is asserted on the adapter: cost stays off the response
    # by design (the caller is not the party paying).
    assert r.results, "expected SERP results from search1api"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title
        assert res.snippet is not None and res.text is None, (
            "search1api is a SERP backend: snippet, never text"
        )


async def test_anysearch_search(engine):
    """The keyless SERP: no account, no key, and the documented envelope
    pinned while it is fresh -- `data.results[].{title, url, snippet}`.

    One call, and it costs nothing. The first live run (2026-10-17)
    is what cleared the untested status (``config.UNTESTED_PROVIDERS``) -- the
    name has left that set, so ``--check`` and the startup line no longer say
    so.
    """
    r = await _search(
        engine,
        SearchQuery(query="python asyncio tutorial", max_results=5),
        "anysearch",
    )

    assert r.provider == "anysearch"
    # The price is asserted on the provider in `tests/providers/test_anysearch.py`: cost stays
    # off the response by design (the caller is not the party paying).
    assert r.results, "expected web results from anysearch"
    with_snippet = [res for res in r.results if res.url and res.snippet]
    assert with_snippet, "expected at least one result with a url and a snippet"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title
        assert res.text is None, "a SERP backend fills `snippet`, never `text`"


async def test_serpapi_search(engine):
    """The Google-SERP adapter, against the real API.

    The first live run against the documented shape is what clears the
    untested status (``config.UNTESTED_PROVIDERS``) -- until it has run,
    ``--check`` and the startup line say so. One search, whatever
    ``max_results`` says; the free plan's 250/month counts only successful
    searches. The key rides in the query string, the operator's documented
    shape -- the assertion that it never surfaces in the response is what
    the redaction rule is for.
    """
    if not _configured("serpapi"):
        pytest.skip("SEEKWRIGHT_SERPAPI_API_KEY not set")
    r = await _search(
        engine,
        SearchQuery(query="python 3.14 release notes", max_results=3),
        "serpapi",
    )

    assert r.provider == "serpapi"
    assert r.results, "expected SERP results from serpapi"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title
        assert res.snippet is not None and res.text is None, (
            "serpapi is a SERP backend: snippet, never text"
        )


async def test_querit_search(engine):
    """The real-time SERP adapter, against the real API.

    The first live run against the documented shape is what clears the
    untested status (``config.UNTESTED_PROVIDERS``) -- until it has run,
    ``--check`` and the startup line say so. One search, whatever
    ``max_results`` says; the free plan's 1,000 calls/month is per call, and
    the 10-result cap is clamped on the request side, so a small ask is what
    a live run costs.
    """
    if not _configured("querit"):
        pytest.skip("SEEKWRIGHT_QUERIT_API_KEY not set")
    r = await _search(
        engine,
        SearchQuery(query="python 3.14 release notes", max_results=3),
        "querit",
    )

    assert r.provider == "querit"
    assert r.results, "expected SERP results from querit"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title
        assert res.snippet is not None and res.text is None, (
            "querit is a SERP backend: snippet, never text"
        )


async def test_deepseek_search(engine):
    """The DeepSeek in-house engine, against the real API.

    The first live run against the documented shape is what clears the
    untested status (``config.UNTESTED_PROVIDERS``) -- until it has run,
    ``--check`` and the startup line say so. Search bills **per successful
    request** ($0.75/1k, guides/search read 2026-10-21) and ``count`` does not
    move that price, so a three-result ask costs the same as a fifty-result one
    and is the cheaper first call.
    """
    if not _configured("deepseek"):
        pytest.skip("SEEKWRIGHT_DEEPSEEK_API_KEY not set")
    r = await _search(
        engine,
        SearchQuery(query="python 3.14 release notes", max_results=3),
        "deepseek",
    )

    assert r.provider == "deepseek"
    assert r.results, "expected results from deepseek"
    for res in r.results:
        assert res.url.startswith("http")
        assert res.title
        assert res.snippet is not None, (
            "deepseek documents a short snippet on every hit"
        )


class TestFetchLive:
    """Real page fetches. Free -- no provider, no key, no billing.

    Worth running even when no API keys are configured: extraction is the one
    part of the fetch path a hermetic suite cannot honestly check, because real
    pages are messier than any fixture.
    """

    async def test_fetches_and_extracts_a_real_page(self):
        from seekwright.extractors.trafilatura import TrafilaturaExtractor
        from seekwright.fetcher import HttpFetcher

        fetcher = HttpFetcher(extractor=TrafilaturaExtractor())
        try:
            page = await fetcher.fetch("https://example.com/")
        finally:
            await fetcher.aclose()

        assert page.status_code == 200
        assert "example" in page.text.lower()
        assert page.content_type == "text/html"

    async def test_blocks_the_cloud_metadata_endpoint(self):
        """The guardrail that matters most, exercised against the real stack."""
        from seekwright.extractors.trafilatura import TrafilaturaExtractor
        from seekwright.fetcher import FetchBlocked, HttpFetcher

        fetcher = HttpFetcher(extractor=TrafilaturaExtractor())
        try:
            with pytest.raises(FetchBlocked):
                await fetcher.fetch("http://169.254.169.254/latest/meta-data/")
        finally:
            await fetcher.aclose()

    async def test_scrappa_scraper_returns_the_documented_shape(self):
        """One billed credit, to prove `data.body_text` is really where text is."""
        from seekwright.fetcher import ScrappaFetcher

        key = os.environ.get("SEEKWRIGHT_SCRAPPA_API_KEY")
        if not key:
            pytest.skip("SEEKWRIGHT_SCRAPPA_API_KEY not set")

        fetcher = ScrappaFetcher(key)
        try:
            page = await fetcher.fetch("https://example.com/")
        finally:
            await fetcher.aclose()

        assert page.status_code == 200
        assert "example" in page.text.lower()

    async def test_jina_reader_returns_the_page_as_markdown(self):
        """The keyless fallback, live: free, no account, no key, no billing.

        Select it with `SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k jina`.
        What only a live run can check is the part a fixture cannot: that the
        service's real body still carries the `Markdown Content:` header block
        this fallback parses, and that it answers without a credential.

        The page's *words* are deliberately not asserted. The reader answers
        from its own cache -- a cached snapshot is the service's default and
        this fallback leaves it on -- so what the body says is the service's
        snapshot of the origin, not something this fallback controls; a content
        assertion here turns red when that snapshot changes rather than when
        the fallback breaks. (`https://example.com/` is served from a snapshot
        whose body has no "example" in it, while the same service returns the
        real page for a cache-busting query on the same URL.) What the fallback
        owns is the read, and that is what this asserts: 200, text, the header
        block parsed off the body, and the marker line not left in the text.
        """
        from seekwright.fetcher import JinaFetcher

        fetcher = JinaFetcher()
        try:
            page = await fetcher.fetch("https://example.com/")
        finally:
            await fetcher.aclose()

        assert page.status_code == 200
        assert page.text.strip(), "the fallback must come back with the page's text"
        assert "Markdown Content:" not in page.text
        assert page.title, "the reader's header block must still be parsed"

    async def test_tavily_extract_returns_the_documented_shape(self):
        """One keyed call, to prove `results[0].raw_content` is really where the text is.

        Select it with `SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k tavily_extract`.
        This vendor bills 1 credit per 5 **successful** extractions at `basic`, so a run
        of this test is a fifth of a credit and the account's credit counter is the
        record; the price the fallback declares is dated in
        ``docs/reference/providers.md``. No key in the environment, no call -- the fallback
        exists only where ``SEEKWRIGHT_TAVILY_API_KEY`` is set.

        What is asserted is the read, not the page's words: the service may answer from
        its own snapshot, and an empty ``results`` array under a 200 is the vendor's way
        of saying the extraction failed, which this fallback turns into *found nothing*.
        """
        from seekwright.fetcher import TavilyFetcher

        key = os.environ.get("SEEKWRIGHT_TAVILY_API_KEY")
        if not key:
            pytest.skip("SEEKWRIGHT_TAVILY_API_KEY not set")

        fetcher = TavilyFetcher(key)
        try:
            page = await fetcher.fetch("https://example.com/")
        finally:
            await fetcher.aclose()

        assert page.status_code == 200
        assert page.text.strip(), (
            "an empty extraction on a page this simple means the envelope moved"
        )
        assert page.content_type is None
        assert page.path_addressable is False

    async def test_linkup_fetch_returns_the_page_as_markdown(self):
        """One keyed call, to prove `markdown` is really where the text is.

        Select it with `SEEKWRIGHT_LIVE_TESTS=1 uv run pytest -m live -k linkup_fetch`.
        The fallback asks for `renderJs`, and the vendor prices that call at $0.005
        (pricing page read 2026-10-24), with 4,000 queries free and no card
        required, so the run costs a fraction of a cent on a fresh key. No key, no call.
        """
        from seekwright.fetcher import LinkupFetcher

        key = os.environ.get("SEEKWRIGHT_LINKUP_API_KEY")
        if not key:
            pytest.skip("SEEKWRIGHT_LINKUP_API_KEY not set")

        fetcher = LinkupFetcher(key)
        try:
            page = await fetcher.fetch("https://example.com/")
        finally:
            await fetcher.aclose()

        assert page.status_code == 200
        assert page.text.strip(), "the service must come back with the page's markdown"
        assert page.url == "https://example.com/"
        assert page.content_type is None
        assert page.path_addressable is False


# ---------------------------------------------------------------------------
# agent mode


def _agent_configured() -> bool:
    """The model endpoint, one model on it, and the key: agent mode needs all three.

    `base_url` and `model` are config-file keys in a deployment, and the key is
    `SEEKWRIGHT_AGENT_API_KEY` there too. Only the key is read from the real
    variable; the other two ride test-only names so this suite builds the config
    it claims to test instead of whatever is installed on the machine.
    """
    return bool(
        os.environ.get("SEEKWRIGHT_AGENT_API_KEY")
        and os.environ.get("SEEKWRIGHT_AGENT_BASE_URL")
        and os.environ.get("SEEKWRIGHT_AGENT_MODEL")
    )


agent_live = pytest.mark.skipif(
    not _agent_configured(),
    reason=(
        "agent mode needs SEEKWRIGHT_AGENT_BASE_URL, SEEKWRIGHT_AGENT_MODEL "
        "and SEEKWRIGHT_AGENT_API_KEY"
    ),
)


async def _answer(query: str, depth: Literal["brief", "report"]):
    """One real `answer` over the real stack: keyless retrieval, pages, the model.

    Retrieval rides the three keyless providers, so the only spend is the
    operator's model call; the config is built here, not read from disk.
    """
    from seekwright.agent import AgentEngine
    from seekwright.config import AgentConfig
    from seekwright.engine import FetchEngine
    from seekwright.factory import build_fetch_stack

    # The model leg's budget is a test-only env name because a slow endpoint
    # needs it raised: the shipped 30s is what a reasoning model at `report`
    # depth exceeded on the first real run. Raising it without the whole-call
    # budget would only move where the call dies, so the two move together.
    model_timeout = float(
        os.environ.get("SEEKWRIGHT_AGENT_MODEL_TIMEOUT_SECONDS", "30")
    )
    cfg = Config(
        providers={
            name: ProviderConfig() for name in ("exa:free", "parallel:free", "freeserp")
        },
        agent=AgentConfig(
            enabled=True,
            base_url=os.environ["SEEKWRIGHT_AGENT_BASE_URL"],
            model=os.environ["SEEKWRIGHT_AGENT_MODEL"],
            model_timeout_seconds=model_timeout,
            timeout_seconds=max(90.0, model_timeout + 30.0),
        ),
    )
    client = httpx.AsyncClient(follow_redirects=True)
    providers = build_providers(cfg, client)
    engine = SearchEngine(cfg, providers)
    fetcher, fallbacks = await build_fetch_stack(cfg)
    fetch_engine = (
        FetchEngine(cfg, fetcher, fallbacks) if fetcher is not None else None
    )
    try:
        agent = AgentEngine(cfg, client, engine, fetch_engine)
        return await agent.answer(query=query, depth=depth)
    finally:
        for fallback in fallbacks:
            await fallback.aclose()
        if fetcher is not None:
            await fetcher.aclose()
        for provider in providers.values():
            await provider.aclose()
        await client.aclose()


@agent_live
async def test_agent_mode_answers_at_the_brief_depth():
    """End to end on the cheapest real deployment: search, assemble, model, citations.

    This is the call hermetic stubs cannot make: every stub result carried a
    `snippet`, while the keyless defaults are content backends that fill `text`.
    A `brief` -- the default depth -- assembled nothing from them and failed
    before the model was ever billed.
    """
    response = await _answer(
        "What is the Gitea project, and what licence is it released under?", "brief"
    )

    assert response.answer.strip()
    assert response.model == os.environ["SEEKWRIGHT_AGENT_MODEL"]
    assert response.searches == 1
    # Cited, or said so: an answer with no validated citation comes back with
    # empty `sources` and a `notice` that says the prose is uncited. Asserting a
    # citation would make this test the model's mood, not the server's contract.
    assert response.sources or "no citations" in (response.notice or "")


@agent_live
async def test_agent_mode_answers_at_the_report_depth():
    """The same plan at its wider depth: up to three searches and three pages."""
    response = await _answer(
        "How does Gitea differ from its upstream forge, and under what licence "
        "is it developed?",
        "report",
    )

    assert response.answer.strip()
    assert response.depth == "report"
    assert response.sources or "no citations" in (response.notice or "")
