"""The keyless Jina Reader fallback: body parsing, request shape, guardrails.

The fixture is the ``text/plain`` body the service actually returns (captured
live 2026-10-14): a blank-line-separated ``Title:`` /
``URL Source:`` / ``Published Time:`` header block, sometimes a ``Warning:``,
then the literal line ``Markdown Content:`` and the page as markdown. It is not
JSON and carries no schema, so the parser is tested against the shape rather
than against a client library's idea of it.

The guardrail tests are the load-bearing ones, exactly as they are for the
other two remote fallbacks: the target must be refused *before* the GET, so a mock
that would otherwise succeed asserts it never was. The second of them goes
through ``build_fetch_stack`` from a config that *does* permit intranet
fetches, because that is the only route by which the flag could reach this
class -- and it must not.
"""

import httpx
import pytest

from seekwright.config import Config, FetchConfig
from seekwright.factory import build_fetch_stack
from seekwright.fetcher import FetchBlocked, JinaFetcher
from seekwright.providers.base import ProviderError, QuotaExhausted

URL = "https://example.com/article"

READER_BODY = (
    "Title: A Rendered Page\n"
    "\n"
    "URL Source: https://example.com/article\n"
    "\n"
    "Published Time: Tue, 13 Oct 2026 22:05:48 GMT\n"
    "\n"
    "Warning: This is a cached snapshot. Use X-No-Cache to bypass.\n"
    "\n"
    "Markdown Content:\n"
    "# A Rendered Page\n"
    "\n"
    "The text a browser sees.\n"
)

PAGE_TEXT = "# A Rendered Page\n\nThe text a browser sees."


def fetcher(handler, **kw) -> JinaFetcher:
    f = JinaFetcher(**kw)
    f._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return f


class TestBodyMapping:
    async def test_maps_the_body_onto_a_page(self):
        page = await fetcher(
            lambda _: httpx.Response(200, text=READER_BODY)
        ).fetch(URL)

        assert page.title == "A Rendered Page"
        assert page.text == PAGE_TEXT
        assert page.status_code == 200
        # The reader reports no media type and the fallback invents none.
        assert page.content_type is None
        assert page.truncated is False

    async def test_the_marker_line_is_stripped(self):
        page = await fetcher(lambda _: httpx.Response(200, text=READER_BODY)).fetch(URL)

        assert "Markdown Content:" not in page.text
        # Nor is the header block part of the page.
        assert "URL Source" not in page.text
        assert "Warning" not in page.text

    async def test_the_url_is_the_source_the_reader_names(self):
        """Where the read actually landed, not the string we asked with."""
        body = READER_BODY.replace(
            "URL Source: https://example.com/article",
            "URL Source: https://example.com/article?utm=1",
        )
        page = await fetcher(lambda _: httpx.Response(200, text=body)).fetch(URL)

        assert page.url == "https://example.com/article?utm=1"

    async def test_the_source_falls_back_to_the_requested_url(self):
        """A body with no `URL Source:` still yields a page, not an empty url."""
        body = "Markdown Content:\nThe page.\n"
        page = await fetcher(lambda _: httpx.Response(200, text=body)).fetch(URL)

        assert page.url == URL
        assert page.title is None
        assert page.text == "The page."

    async def test_a_body_without_the_marker_is_read_whole(self):
        """The service answered with markdown it did not label. Dropping it
        would turn a usable read into an empty fallback, so it is the page."""
        page = await fetcher(
            lambda _: httpx.Response(200, text="# Just markdown\n")
        ).fetch(URL)

        assert page.text == "# Just markdown\n"

    async def test_the_marker_does_not_swallow_a_first_line(self):
        """`Markdown Content:` on its own line, with the page starting under
        it -- the live shape, and the one that must not lose a line."""
        body = "Markdown Content:\nFirst line.\nSecond line.\n"
        page = await fetcher(lambda _: httpx.Response(200, text=body)).fetch(URL)

        assert page.text == "First line.\nSecond line."

    async def test_text_is_capped(self):
        body = f"Markdown Content:\n{'x' * 500}\n"
        f = fetcher(lambda _: httpx.Response(200, text=body), max_text_chars=100)
        page = await f.fetch(URL)

        # Windowed the same way as every other fallback (paragraph-preferred cut,
        # marker after the slice); total_chars is the full extraction either way.
        assert page.text == "x" * 100 + "\n\n[...]"
        assert page.truncated is True
        assert page.total_chars == 500

    @pytest.mark.parametrize(
        "placeholder", ["Loading...", "Please enable JavaScript to view this page."]
    )
    async def test_a_placeholder_body_is_empty_not_a_page(self, placeholder: str):
        """The service's "I have no page for you" bodies.

        Read as *found nothing*, which is what lets the next fallback fire. It is
        asserted at `min_text_chars = 0` as well as at the default, because
        these are a statement about the read rather than a length -- and at the
        default the length would hide the difference.
        """
        body = f"Title: A Rendered Page\n\nMarkdown Content:\n{placeholder}\n"
        page = await fetcher(lambda _: httpx.Response(200, text=body)).fetch(URL)

        assert page.text == ""
        assert page.total_chars == 0
        # The title is still the reader's report of the page it could not read;
        # withholding it would be inventing a second, worse answer.
        assert page.title == "A Rendered Page"


class TestRequestShape:
    async def test_gets_the_target_as_a_path_suffix(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, text=READER_BODY)

        await fetcher(handler).fetch(f"{URL}?track=1")

        request = seen["request"]
        assert request.method == "GET"
        # Not a query parameter: the reader takes the whole URL as the path.
        assert str(request.url) == f"https://r.jina.ai/{URL}?track=1"
        assert request.url.params.get("url") is None

    async def test_asks_for_markdown_and_sends_the_configured_user_agent(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, text=READER_BODY)

        await fetcher(handler, user_agent="seekwright/9.9.9 (test)").fetch(URL)

        headers = seen["request"].headers
        assert headers["Accept"] == "text/markdown"
        assert headers["User-Agent"] == "seekwright/9.9.9 (test)"

    async def test_no_credential_is_ever_sent(self):
        """The whole point of the fallback: there is no key to send, and none may
        ride along from the shared client either."""
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, text=READER_BODY)

        await fetcher(handler).fetch(URL)

        headers = seen["request"].headers
        assert "Authorization" not in headers
        assert "x-api-key" not in headers
        # The service's cache stays on: re-rendering spends one of 20 requests a
        # minute for nothing.
        assert "x-no-cache" not in headers


class TestBodyErrors:
    async def test_rate_limiting_is_typed(self):
        """20 requests per 60 s per IP, and the window is shared."""
        f = fetcher(lambda _: httpx.Response(429, text=""))
        with pytest.raises(QuotaExhausted):
            await f.fetch(URL)

    async def test_a_payment_required_answer_is_typed(self):
        f = fetcher(lambda _: httpx.Response(402, text=""))
        with pytest.raises(QuotaExhausted):
            await f.fetch(URL)

    async def test_a_cloudflare_rejection_is_a_plain_http_error(self):
        """No credential is sent, so a 403 is the service refusing this address
        or this target -- never a key to go and fix."""
        f = fetcher(lambda _: httpx.Response(403, text=""))
        with pytest.raises(ProviderError) as exc:
            await f.fetch(URL)
        assert exc.value.message == "HTTP 403"
        assert exc.value.retryable is True

    async def test_a_server_error_is_typed(self):
        f = fetcher(lambda _: httpx.Response(500, text=""))
        with pytest.raises(ProviderError, match="HTTP 500"):
            await f.fetch(URL)

    async def test_network_error_does_not_echo_the_request(self):
        def handler(_: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("connection refused to User-Agent: sekrit")

        f = fetcher(handler)
        with pytest.raises(ProviderError) as exc:
            await f.fetch(URL)
        # The message must not carry the underlying exception: httpx errors can
        # echo the request headers.
        assert exc.value.message == "network error"
        assert "sekrit" not in str(exc.value)


class TestGuardrails:
    async def test_private_addresses_are_refused_before_delegating(self):
        called = False

        def handler(_: httpx.Request) -> httpx.Response:
            nonlocal called
            called = True
            return httpx.Response(200, text=READER_BODY)

        f = fetcher(handler)
        with pytest.raises(FetchBlocked):
            await f.fetch("http://127.0.0.1:8080/admin")
        # The hostname never reaches the reader at all: handing internal names away
        # is the leak.
        assert called is False

    async def test_a_config_that_allows_private_addresses_cannot_reach_it(self):
        """The escape hatch is the local fetcher's, never a fallback's.

        Built from a config with `fetch.allow_private_addresses = true`, which
        is the only way the flag could reach this class -- and the refusal below
        is not tunable, so there is no flag to pass. An intranet page the local
        fallback may read is still not handed to a third party.
        """
        cfg = Config(
            fetch=FetchConfig(
                enabled=True, allow_private_addresses=True, fallback=["jina"]
            )
        )

        fetcher_, fallbacks = await build_fetch_stack(cfg)
        try:
            assert [fallback.name for fallback in fallbacks] == ["jina"]
            with pytest.raises(FetchBlocked):
                await fallbacks[0].fetch("http://192.168.1.1/router-login")
        finally:
            assert fetcher_ is not None
            await fetcher_.aclose()
            for fallback in fallbacks:
                await fallback.aclose()

    async def test_non_http_schemes_are_refused(self):
        f = fetcher(lambda _: httpx.Response(200, text=READER_BODY))
        with pytest.raises(FetchBlocked):
            await f.fetch("file:///etc/passwd")
