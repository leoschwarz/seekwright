"""The keyed Tavily extract fallback: envelope parsing, request shape, guardrails.

The fixture is the documented ``POST /extract`` payload (``docs/reference/providers.md``,
and the vendor's extract page as read 2026-10-23): ``results[]`` holds one entry per URL
that succeeded, each carrying ``url`` and ``raw_content``, and ``failed_results[]`` the
URLs that did not. The envelope holds no title and no media type, so those page fields
stay empty rather than being invented out of the markdown.

The two contract traps the issue names are both tested here. A 200 whose ``results``
array is empty is the vendor's way of saying every URL failed, and it is the near-empty
class ``fetch.min_text_chars`` refuses, so it has to read as *found nothing* and let the
next fallback fire -- the same reading ``tests/fetch/test_jina.py`` gives the reader's ``Loading...``
body. The other trap is that this vendor bills successful extractions rather than calls,
which is why the price the fallback declares is a per-success rate and why ``include_usage``
is not asked for.

The guardrail tests are the load-bearing ones, as for every remote fallback: the target must
be refused *before* the POST, so a mock that would otherwise succeed asserts it never was.
"""

import asyncio
import json

import httpx
import pytest

from seekwright.config import Config, FetchConfig, ProviderConfig
from seekwright.factory import build_fetch_stack
from seekwright.fetcher import (
    TAVILY_EXTRACT_ENDPOINT,
    ContentFetcher,
    FetchBlocked,
    TavilyFetcher,
)
from seekwright.providers.base import ProviderError, QuotaExhausted

URL = "https://example.com/article"

PAGE_TEXT = "# A Rendered Page\n\nThe text a browser sees."

EXTRACT_BODY: dict[str, object] = {
    "results": [{"url": URL, "raw_content": PAGE_TEXT}],
    "failed_results": [],
    "response_time": 1.61,
}


def fetcher(handler, **kw) -> TavilyFetcher:
    f = TavilyFetcher("tvly-test-key", **kw)
    f._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return f


def _sent_body(handler, **kw) -> dict[str, object]:
    """The JSON body the fallback POSTs, captured from a request that answers fine."""
    seen: list[httpx.Request] = []

    def record(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return handler(request)

    async def go() -> dict[str, object]:
        await fetcher(record, **kw).fetch(URL)
        assert len(seen) == 1
        return json.loads(seen[0].content)

    return asyncio.run(go())


def _built_fallback(cfg: Config) -> ContentFetcher | None:
    """The one fallback ``cfg`` names, built through the ladder, or ``None`` if its prerequisites are missing."""

    async def build():
        local, fallbacks = await build_fetch_stack(cfg)
        try:
            return fallbacks[0] if fallbacks else None
        finally:
            if local is not None:
                await local.aclose()
            for fallback in fallbacks:
                await fallback.aclose()

    return asyncio.run(build())


class TestBodyMapping:
    async def test_maps_the_envelope_onto_a_page(self):
        page = await fetcher(lambda _: httpx.Response(200, json=EXTRACT_BODY)).fetch(
            URL
        )

        assert page.text == PAGE_TEXT
        assert page.status_code == 200
        assert page.truncated is False
        assert page.total_chars == len(PAGE_TEXT)
        # Neither a title nor a media type is in the envelope, so the fallback claims neither.
        assert page.title is None
        assert page.content_type is None
        # A fallback that reads a body with a library returns prose, never a path-addressable document.
        assert page.path_addressable is False

    async def test_the_landing_url_the_vendor_names_is_reported(self):
        body = {
            "results": [{"url": "https://example.com/final", "raw_content": PAGE_TEXT}]
        }
        page = await fetcher(lambda _: httpx.Response(200, json=body)).fetch(
            "https://example.com/short-link"
        )
        # The extraction happened on the far side of the request, so the caller learns where it landed.
        assert page.url == "https://example.com/final"

    async def test_a_result_that_names_no_url_falls_back_to_the_target(self):
        body = {"results": [{"raw_content": PAGE_TEXT}]}
        page = await fetcher(lambda _: httpx.Response(200, json=body)).fetch(URL)
        assert page.url == URL

    async def test_text_is_capped_and_marked(self):
        text = "word " * 400
        body = {"results": [{"url": URL, "raw_content": text}]}
        page = await fetcher(lambda _: httpx.Response(200, json=body)).fetch(
            URL, max_chars=100
        )

        assert len(page.text) < 130
        assert page.truncated is True
        assert page.total_chars == len(text)

    @pytest.mark.parametrize(
        "body",
        [
            # Every URL failed, which is what an empty `results` array under a 200 means.
            {"results": [], "failed_results": [{"url": URL, "error": "not found"}]},
            {"failed_results": [{"url": URL, "error": "blocked"}]},
            {"results": [{"url": URL, "raw_content": ""}]},
            {"results": "not a list"},
        ],
        ids=["empty-results", "only-failures", "blank-content", "malformed-results"],
    )
    async def test_a_call_with_nothing_in_it_is_found_nothing(self, body):
        """The fallback falls through the ladder rather than serving an empty page.

        A page here ends the walk and prices a call this vendor billed at zero.
        Empty text is the near-empty class ``fetch.min_text_chars`` refuses, which
        is what keeps the ladder walking.
        """
        page = await fetcher(lambda _: httpx.Response(200, json=body)).fetch(URL)

        assert page.text == ""
        assert page.total_chars == 0
        assert page.status_code == 200


class TestRequestShape:
    def test_posts_the_validated_target_in_urls(self):
        sent = _sent_body(lambda _: httpx.Response(200, json=EXTRACT_BODY))
        assert sent["urls"] == [URL]
        assert "query" not in sent, (
            "chunks reranked against a query is the batch shape, not a ladder fallback's"
        )

    def test_asks_for_markdown_at_the_cheaper_depth(self):
        sent = _sent_body(lambda _: httpx.Response(200, json=EXTRACT_BODY))
        assert sent["format"] == "markdown"
        assert sent["extract_depth"] == "basic"
        assert "include_usage" not in sent, (
            "the fetch journal prices a fallback-served page from cost_per_1k, so a "
            "credit count in the body is a number nothing here reads"
        )

    @pytest.mark.parametrize(
        ("timeout", "expected"),
        [(5.0, 5.0), (30.0, 30.0), (120.0, 60.0)],
    )
    def test_the_vendors_timeout_bound_is_stayed_inside(self, timeout, expected):
        """``timeout`` takes 1-60 s on the vendor's side, whatever this fallback is told to wait."""
        sent = _sent_body(
            lambda _: httpx.Response(200, json=EXTRACT_BODY), timeout=timeout
        )
        assert sent["timeout"] == expected

    async def test_the_endpoint_is_the_module_constant(self):
        seen: list[httpx.Request] = []

        def handler(request: httpx.Request) -> httpx.Response:
            seen.append(request)
            return httpx.Response(200, json=EXTRACT_BODY)

        await fetcher(handler).fetch(URL)
        assert str(seen[0].url) == TAVILY_EXTRACT_ENDPOINT
        assert seen[0].method == "POST"
        assert seen[0].headers["authorization"] == "Bearer tvly-test-key"

    async def test_a_long_client_timeout_still_posts_a_legal_one(self):
        seen: list[httpx.Request] = []

        def handler(request: httpx.Request) -> httpx.Response:
            seen.append(request)
            return httpx.Response(200, json=EXTRACT_BODY)

        await fetcher(handler, timeout=120.0).fetch(URL)
        assert json.loads(seen[0].content)["timeout"] == 60.0


class TestStatusCodes:
    @pytest.mark.parametrize("status", [401, 403])
    async def test_a_rejected_key_is_a_refusal_not_a_retry(self, status):
        with pytest.raises(ProviderError) as excinfo:
            await fetcher(lambda _: httpx.Response(status)).fetch(URL)
        assert excinfo.value.retryable is False
        assert "authentication" in excinfo.value.message

    @pytest.mark.parametrize("status", [429, 432])
    async def test_rate_limit_and_exhausted_credits_are_quota(self, status):
        """432 is Tavily's monthly-credits-exhausted code and 429 its short-term limit."""
        with pytest.raises(QuotaExhausted):
            await fetcher(lambda _: httpx.Response(status)).fetch(URL)

    @pytest.mark.parametrize("status", [400, 402, 500])
    async def test_everything_else_is_a_plain_http_failure(self, status):
        with pytest.raises(ProviderError) as excinfo:
            await fetcher(lambda _: httpx.Response(status)).fetch(URL)
        assert excinfo.value.message == f"HTTP {status}"

    @pytest.mark.parametrize(
        "payload",
        ["not json at all", "[1, 2, 3]", "null"],
        ids=["text", "array", "null"],
    )
    async def test_an_unparseable_body_is_the_contracted_error(self, payload):
        with pytest.raises(ProviderError) as excinfo:
            await fetcher(lambda _: httpx.Response(200, text=payload)).fetch(URL)
        assert excinfo.value.message == "malformed JSON response"

    async def test_network_error_does_not_echo_the_request(self):
        def handler(_: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("connection refused")

        with pytest.raises(ProviderError) as excinfo:
            await fetcher(handler).fetch(URL)
        assert excinfo.value.message == "network error"
        assert "tvly-test-key" not in str(excinfo.value)


class TestGuardrails:
    async def test_private_addresses_are_refused_before_delegating(self):
        called = False

        def handler(_: httpx.Request) -> httpx.Response:
            nonlocal called
            called = True
            return httpx.Response(200, json=EXTRACT_BODY)

        with pytest.raises(FetchBlocked):
            await fetcher(handler).fetch("http://127.0.0.1:8080/admin")
        # Handing an internal hostname to the vendor is the leak, so the name never travels.
        assert called is False

    async def test_a_config_that_allows_private_addresses_cannot_reach_it(
        self, monkeypatch
    ):
        """The escape hatch is the local fetcher's, never a fallback's.

        Built from a config with ``fetch.allow_private_addresses = true``, the only
        route by which the flag could reach this class -- and the refusal below is
        not tunable, so an intranet page the local fallback may read is still not handed
        to a third party.
        """
        monkeypatch.setenv("SEEKWRIGHT_TAVILY_API_KEY", "tvly-test-key")
        cfg = Config(
            fetch=FetchConfig(
                enabled=True, allow_private_addresses=True, fallback=["tavily"]
            )
        )
        local, fallbacks = await build_fetch_stack(cfg)
        try:
            assert [fallback.name for fallback in fallbacks] == ["tavily"]
            with pytest.raises(FetchBlocked):
                await fallbacks[0].fetch("http://192.168.1.1/router-login")
        finally:
            assert local is not None
            await local.aclose()
            for fallback in fallbacks:
                await fallback.aclose()

    async def test_non_http_schemes_are_refused(self):
        with pytest.raises(FetchBlocked):
            await fetcher(lambda _: httpx.Response(200, json=EXTRACT_BODY)).fetch(
                "file:///etc/passwd"
            )


class TestWiring:
    """The fallback is keyed by the name `[providers]` already reads, gated by the same allow-list."""

    def test_built_only_when_a_key_is_present(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_TAVILY_API_KEY", raising=False)
        cfg = Config(fetch=FetchConfig(enabled=True, fallback=["tavily"]))
        assert _built_fallback(cfg) is None

    def test_a_permission_set_that_excludes_the_name_leaves_it_unbuilt(
        self, monkeypatch
    ):
        monkeypatch.setenv("SEEKWRIGHT_TAVILY_API_KEY", "tvly-test-key")
        cfg = Config(
            providers={"serper": ProviderConfig(), "tavily": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["serper"],
            fetch=FetchConfig(enabled=True, fallback=["tavily"]),
        )
        assert _built_fallback(cfg) is None

    def test_the_key_builds_it_at_its_declared_price(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_TAVILY_API_KEY", "tvly-test-key")
        cfg = Config(fetch=FetchConfig(enabled=True, fallback=["tavily"]))
        fallback = _built_fallback(cfg)
        assert fallback is not None
        assert fallback.name == "tavily"
        # Basic extraction: 1 credit per 5 successes, at the $8/1k credit rate the search adapter declares.
        assert fallback.cost_per_1k == 1.60

    def test_config_can_correct_the_cost(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_TAVILY_API_KEY", "tvly-test-key")
        cfg = Config(
            fetch=FetchConfig(enabled=True, fallback=["tavily"], cost_per_1k=0.40)
        )
        fallback = _built_fallback(cfg)
        assert fallback is not None
        assert fallback.cost_per_1k == 0.40
