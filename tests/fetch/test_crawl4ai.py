"""The crawl4ai renderer fallback: payload mapping, request shape, guardrails.

The fixture is the ``POST /crawl`` payload of the pinned 0.9.x server line
(see ``docs/reference/crawl4ai.md`` -- ``markdown`` arrives as a
MarkdownGenerationResult dict, and the origin status rides per-result). The
request-shape tests drive the fetcher through an ``httpx.MockTransport``, like
``tests/providers/test_scrappa.py`` does for its provider.

The private-address test is the load-bearing one: the target must be refused
*before* the POST, so a mock that would otherwise succeed asserts it never was.
"""

import json
from typing import Any

import httpx
import pytest

from seekwright.fetcher import Crawl4aiFetcher, FetchBlocked
from seekwright.providers.base import ProviderError

BASE = "http://int-crawl4ai:11235"
URL = "https://example.com/article"

CRAWLED_RESULT: dict[str, Any] = {
    "url": URL,
    "success": True,
    "status_code": 200,
    "redirected_url": None,
    "markdown": {
        "raw_markdown": "The text a browser sees.",
        "markdown_with_citations": "The text a browser sees.",
        "references_markdown": "",
        "fit_markdown": None,
        "fit_html": None,
    },
    "metadata": {"title": "A Rendered Page", "description": "…"},
    "error_message": None,
}

CRAWLED: dict[str, Any] = {
    "success": True,
    "results": [CRAWLED_RESULT],
    "server_processing_time_s": 0.5,
}


def fetcher(handler, **kw) -> Crawl4aiFetcher:
    f = Crawl4aiFetcher(kw.pop("base_url", BASE), **kw)
    f._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return f


class TestPayloadMapping:
    async def test_maps_the_payload_onto_a_page(self):
        page = await fetcher(lambda _: httpx.Response(200, json=CRAWLED)).fetch(URL)

        assert page.title == "A Rendered Page"
        assert page.text == "The text a browser sees."
        assert page.status_code == 200
        # Where we asked; nothing redirected us.
        assert page.url == URL
        assert page.content_type is None
        assert page.truncated is False

    async def test_reports_where_the_crawl_landed(self):
        payload = {**CRAWLED, "results": [{**CRAWLED_RESULT, "redirected_url": URL + "?utm=1"}]}
        page = await fetcher(lambda _: httpx.Response(200, json=payload)).fetch(URL)

        assert page.url == URL + "?utm=1"

    async def test_a_string_markdown_is_accepted(self):
        # Older server lines sent `markdown` as a plain string; both shapes are
        # read.
        payload = {**CRAWLED, "results": [{**CRAWLED_RESULT, "markdown": "plain"}]}
        page = await fetcher(lambda _: httpx.Response(200, json=payload)).fetch(URL)

        assert page.text == "plain"

    async def test_text_is_capped(self):
        payload = {
            **CRAWLED,
            "results": [{**CRAWLED_RESULT, "markdown": {"raw_markdown": "x" * 500}}],
        }
        f = fetcher(lambda _: httpx.Response(200, json=payload), max_text_chars=100)
        page = await f.fetch(URL)

        assert page.text == "x" * 100 + "\n\n[...]"
        assert page.truncated is True
        assert page.total_chars == 500

    async def test_no_markdown_is_empty_not_broken(self):
        # No markdown is an empty page for the emptiness gate, not a malformed
        # response.
        payload = {**CRAWLED, "results": [{**CRAWLED_RESULT, "markdown": None}]}
        page = await fetcher(lambda _: httpx.Response(200, json=payload)).fetch(URL)

        assert page.text == ""
        assert page.status_code == 200


class TestPayloadErrors:
    async def test_an_origin_error_page_is_not_content(self):
        # The service answers 200 with the origin's 404 body rendered; that is
        # a successful crawl and a failed fetch.
        payload = {**CRAWLED, "results": [{**CRAWLED_RESULT, "status_code": 404}]}
        f = fetcher(lambda _: httpx.Response(200, json=payload))
        with pytest.raises(ProviderError, match="404"):
            await f.fetch(URL)

    async def test_a_failed_crawl_entry_is_an_error(self):
        payload = {
            **CRAWLED,
            "results": [
                {**CRAWLED_RESULT, "success": False, "error_message": "timeout"}
            ],
        }
        f = fetcher(lambda _: httpx.Response(200, json=payload))
        with pytest.raises(ProviderError, match="timeout"):
            await f.fetch(URL)

    async def test_an_envelope_failure_is_an_error(self):
        payload = {"success": False, "msg": "server overloaded"}
        f = fetcher(lambda _: httpx.Response(200, json=payload))
        with pytest.raises(ProviderError):
            await f.fetch(URL)

    async def test_results_missing_is_malformed(self):
        f = fetcher(lambda _: httpx.Response(200, json={"success": True}))
        with pytest.raises(ProviderError, match="malformed"):
            await f.fetch(URL)

    async def test_a_non_dict_payload_is_malformed(self):
        f = fetcher(lambda _: httpx.Response(200, json=[CRAWLED]))
        with pytest.raises(ProviderError, match="malformed"):
            await f.fetch(URL)

    async def test_malformed_json_is_an_error(self):
        f = fetcher(lambda _: httpx.Response(200, content=b"<html>"))
        with pytest.raises(ProviderError, match="malformed JSON"):
            await f.fetch(URL)

    @pytest.mark.parametrize("status", [401, 403])
    async def test_auth_rejection_is_not_retryable(self, status: int):
        f = fetcher(lambda _: httpx.Response(status, json={}))
        with pytest.raises(ProviderError) as exc:
            await f.fetch(URL)
        assert exc.value.retryable is False

    async def test_a_server_error_is_typed(self):
        f = fetcher(lambda _: httpx.Response(500, json={}))
        with pytest.raises(ProviderError, match="HTTP 500"):
            await f.fetch(URL)

    async def test_network_error_does_not_echo_the_request(self):
        def handler(_: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError(
                "connection refused to Authorization: Bearer sekrit"
            )

        f = fetcher(handler)
        with pytest.raises(ProviderError) as exc:
            await f.fetch(URL)
        # The message must not carry the underlying exception: httpx errors can
        # echo the request headers, and those hold the bearer token.
        assert exc.value.message == "network error"
        assert "sekrit" not in str(exc.value)


class TestRequestShape:
    async def test_posts_the_validated_target_with_default_configs(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=CRAWLED)

        await fetcher(handler).fetch(f"{URL}?track=1")

        request = seen["request"]
        assert request.method == "POST"
        assert str(request.url) == f"{BASE}/crawl"
        # The tracked URL is what we asked to read, so it is what the service
        # gets; the validation and normalisation happen before this line.
        body = json.loads(request.content)
        assert body["urls"] == [f"{URL}?track=1"]
        # Empty configs are the point: the pinned server line already means
        # bypass-cache and markdown, and the fallback's contract is *only* that.
        assert body["browser_config"] == {}
        assert body["crawler_config"] == {}

    async def test_the_token_rides_bearer_auth(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=CRAWLED)

        await fetcher(handler, token="sekrit").fetch(URL)

        assert seen["request"].headers["Authorization"] == "Bearer sekrit"

    async def test_no_token_means_no_auth_header(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=CRAWLED)

        await fetcher(handler).fetch(URL)

        assert "Authorization" not in seen["request"].headers


class TestGuardrails:
    async def test_private_addresses_are_refused_before_delegating(self):
        called = False

        def handler(_: httpx.Request) -> httpx.Response:
            nonlocal called
            called = True
            return httpx.Response(200, json=CRAWLED)

        f = fetcher(handler)
        with pytest.raises(FetchBlocked):
            await f.fetch("http://127.0.0.1:8080/admin")
        # The hostname never reaches the service at all: handing internal names
        # away is the leak.
        assert called is False

    async def test_allow_private_addresses_does_not_apply_here(self):
        """The engine's escape hatch is the local fetcher's, never this fallback's.

        A config that permits intranet fetches through `HttpFetcher` must not
        silently permit handing intranet names to the renderer -- there the
        request *is* the leak.
        """
        f = fetcher(lambda _: httpx.Response(200, json=CRAWLED))
        # The guard is unconditional: no config reaches Crawl4aiFetcher, so there
        # is no flag to pass.
        with pytest.raises(FetchBlocked):
            await f.fetch("http://192.168.1.1/router-login")

    async def test_non_http_schemes_are_refused(self):
        f = fetcher(lambda _: httpx.Response(200, json=CRAWLED))
        with pytest.raises(FetchBlocked):
            await f.fetch("file:///etc/passwd")
