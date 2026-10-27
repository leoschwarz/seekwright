"""The keyed Linkup fetch fallback: payload parsing, request shape, guardrails.

The fixture is the documented ``POST /v1/fetch`` payload (``docs/reference/providers.md``,
and the vendor's fetch contract as read 2026-10-23): ``markdown`` is always returned,
``contentType`` is a coarse kind rather than a media type, and ``favicon``, ``images[]``,
``data``, ``rawHtml`` and ``rawContent`` appear only when the request asks for them. This
fallback asks for none of them, and the two tests that matter most on that point are here:
the flags are sent ``false`` rather than left to the vendor's default, and a response
that carries ``images[]`` anyway still yields the page's text and nothing else -- the
image question is a separate one, gated by ``fetch.allow_images``, and this fallback does not
answer it twice.

``renderJs`` is why this fallback exists: it is the failure class ``HttpFetcher`` cannot
cover. The vendor prices Fetch per call off a ``mode`` × ``renderJs`` table, and the
cell this fallback sends -- standard, renderJs true, no schema -- reads $0.005 on the page
read 2026-10-24, which is what ``cost_per_1k`` declares: the price of the call the fallback
makes, not the cheapest cell it never sends or the schema cell it cannot buy.

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
    LINKUP_FETCH_ENDPOINT,
    ContentFetcher,
    FetchBlocked,
    LinkupFetcher,
)
from seekwright.providers.base import ProviderError, QuotaExhausted

URL = "https://example.com/article"

PAGE_TEXT = "# A Rendered Page\n\nThe text a browser sees."

FETCH_BODY: dict[str, object] = {
    "markdown": PAGE_TEXT,
    "contentType": "html",
    "favicon": "https://favicons.linkup.so?domain=example.com",
}


def fetcher(handler, **kw) -> LinkupFetcher:
    f = LinkupFetcher("pk-test-key", **kw)
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
    async def test_maps_the_payload_onto_a_page(self):
        page = await fetcher(lambda _: httpx.Response(200, json=FETCH_BODY)).fetch(URL)

        assert page.text == PAGE_TEXT
        assert page.status_code == 200
        assert page.truncated is False
        assert page.total_chars == len(PAGE_TEXT)
        assert page.title is None
        # `contentType` reads "html", a kind rather than a media type, and the fallback invents nothing from it.
        assert page.content_type is None
        # A fallback that reads a body with a library returns prose, never a path-addressable document.
        assert page.path_addressable is False

    async def test_the_url_stays_the_one_the_caller_wrote(self):
        """The service reads that URL and follows no links, so there is no landing URL to report."""
        page = await fetcher(lambda _: httpx.Response(200, json=FETCH_BODY)).fetch(URL)
        assert page.url == URL

    async def test_text_is_capped_and_marked(self):
        text = "word " * 400
        body = {"markdown": text, "contentType": "html"}
        page = await fetcher(lambda _: httpx.Response(200, json=body)).fetch(
            URL, max_chars=100
        )

        assert len(page.text) < 130
        assert page.truncated is True
        assert page.total_chars == len(text)

    @pytest.mark.parametrize(
        "body",
        [
            {"markdown": "", "contentType": "html"},
            {"contentType": "html"},
            {"markdown": None},
            {"markdown": {"not": "a string"}},
        ],
        ids=["empty-markdown", "missing-markdown", "null-markdown", "shaped-markdown"],
    )
    async def test_a_response_with_no_text_in_it_is_found_nothing(self, body):
        """A page the service could not render is the near-empty class, not a page.

        A body this short is a page the service did not read, so this is the class
        ``fetch.min_text_chars`` refuses: the walk goes on instead of ending here.
        """
        page = await fetcher(lambda _: httpx.Response(200, json=body)).fetch(URL)

        assert page.text == ""
        assert page.total_chars == 0
        assert page.status_code == 200

    async def test_images_in_the_response_are_not_carried(self):
        """The image path owns image bytes; this fallback parses the text and drops the rest."""
        body = {
            "markdown": PAGE_TEXT,
            "contentType": "html",
            "images": [{"alt": "Chart", "url": "https://example.com/chart.png"}],
            "data": {"name": "Example product", "price": 49},
            "rawHtml": "<html><body>nope</body></html>",
        }
        page = await fetcher(lambda _: httpx.Response(200, json=body)).fetch(URL)

        assert page.text == PAGE_TEXT
        assert "chart.png" not in page.text
        assert "nope" not in page.text


class TestRequestShape:
    def test_posts_the_validated_target_as_url(self):
        sent = _sent_body(lambda _: httpx.Response(200, json=FETCH_BODY))
        assert sent["url"] == URL

    def test_asks_for_the_rendered_read_and_no_raw_bodies(self):
        sent = _sent_body(lambda _: httpx.Response(200, json=FETCH_BODY))
        assert sent["renderJs"] is True, (
            "a JS-rendered page is the failure class this fallback exists to cover"
        )
        assert sent["mode"] == "standard", (
            "pro is a price cliff, so it stays operator policy"
        )
        # Sent false rather than left unset: a vendor-side default change cannot buy bytes this ladder has no path for.
        assert sent["extractImages"] is False
        assert sent["includeRawHtml"] is False
        assert sent["includeRawContent"] is False
        assert "schema" not in sent and "instructions" not in sent, (
            "instructions without a schema is a 400, and typed `data` is not page text"
        )

    async def test_the_endpoint_is_the_module_constant(self):
        seen: list[httpx.Request] = []

        def handler(request: httpx.Request) -> httpx.Response:
            seen.append(request)
            return httpx.Response(200, json=FETCH_BODY)

        await fetcher(handler).fetch(URL)
        assert str(seen[0].url) == LINKUP_FETCH_ENDPOINT
        assert seen[0].method == "POST"
        assert seen[0].headers["authorization"] == "Bearer pk-test-key"


class TestStatusCodes:
    @pytest.mark.parametrize("status", [401, 403])
    async def test_a_rejected_key_is_a_refusal_not_a_retry(self, status):
        with pytest.raises(ProviderError) as excinfo:
            await fetcher(lambda _: httpx.Response(status)).fetch(URL)
        assert excinfo.value.retryable is False
        assert "authentication" in excinfo.value.message

    async def test_rate_limit_and_a_spent_account_are_quota(self):
        with pytest.raises(QuotaExhausted):
            await fetcher(lambda _: httpx.Response(429)).fetch(URL)

    async def test_a_validation_answer_is_a_plain_http_failure(self):
        """The keyless x402 lane's 402 stays a plain failure: this tree never enters that lane."""
        with pytest.raises(ProviderError) as excinfo:
            await fetcher(
                lambda _: httpx.Response(
                    400, json={"error": {"code": "VALIDATION_ERROR"}, "statusCode": 400}
                )
            ).fetch(URL)
        assert excinfo.value.message == "HTTP 400"

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
        assert "pk-test-key" not in str(excinfo.value)


class TestGuardrails:
    async def test_private_addresses_are_refused_before_delegating(self):
        called = False

        def handler(_: httpx.Request) -> httpx.Response:
            nonlocal called
            called = True
            return httpx.Response(200, json=FETCH_BODY)

        with pytest.raises(FetchBlocked):
            await fetcher(handler).fetch("http://127.0.0.1:8080/admin")
        # Handing an internal hostname to the vendor is the leak, so the name never travels.
        assert called is False

    async def test_a_config_that_allows_private_addresses_cannot_reach_it(
        self, monkeypatch
    ):
        """The escape hatch is the local fetcher's, never a fallback's."""
        monkeypatch.setenv("SEEKWRIGHT_LINKUP_API_KEY", "pk-test-key")
        cfg = Config(
            fetch=FetchConfig(
                enabled=True, allow_private_addresses=True, fallback=["linkup"]
            )
        )
        local, fallbacks = await build_fetch_stack(cfg)
        try:
            assert [fallback.name for fallback in fallbacks] == ["linkup"]
            with pytest.raises(FetchBlocked):
                await fallbacks[0].fetch("http://192.168.1.1/router-login")
        finally:
            assert local is not None
            await local.aclose()
            for fallback in fallbacks:
                await fallback.aclose()

    async def test_non_http_schemes_are_refused(self):
        with pytest.raises(FetchBlocked):
            await fetcher(lambda _: httpx.Response(200, json=FETCH_BODY)).fetch(
                "file:///etc/passwd"
            )


class TestWiring:
    """The fallback is keyed by the name `[providers]` already reads, gated by the same allow-list."""

    def test_built_only_when_a_key_is_present(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_LINKUP_API_KEY", raising=False)
        cfg = Config(fetch=FetchConfig(enabled=True, fallback=["linkup"]))
        assert _built_fallback(cfg) is None

    def test_a_permission_set_that_excludes_the_name_leaves_it_unbuilt(
        self, monkeypatch
    ):
        monkeypatch.setenv("SEEKWRIGHT_LINKUP_API_KEY", "pk-test-key")
        cfg = Config(
            providers={"serper": ProviderConfig(), "linkup": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["serper"],
            fetch=FetchConfig(enabled=True, fallback=["linkup"]),
        )
        assert _built_fallback(cfg) is None

    def test_the_key_builds_it_at_its_declared_price(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_LINKUP_API_KEY", "pk-test-key")
        cfg = Config(fetch=FetchConfig(enabled=True, fallback=["linkup"]))
        fallback = _built_fallback(cfg)
        assert fallback is not None
        assert fallback.name == "linkup"
        # The `standard`/`renderJs: true` cell of the vendor's Fetch table, read 2026-10-24.
        assert fallback.cost_per_1k == 5.00

    def test_config_can_correct_the_cost(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_LINKUP_API_KEY", "pk-test-key")
        cfg = Config(
            fetch=FetchConfig(enabled=True, fallback=["linkup"], cost_per_1k=2.00)
        )
        fallback = _built_fallback(cfg)
        assert fallback is not None
        assert fallback.cost_per_1k == 2.00
