"""AnySearch provider: response parsing, request shape, cost and wiring.

The fixture is the documented ``/v1/search`` envelope from the operator's API
docs (``https://www.anysearch.com/docs/api-endpoints/v1-search``, read
2026-10-16; the same shape the 2026-10-16 keyless probe observed). The gateway
fuses several data sources, so a hit carries what they report: ``title``
(always present, possibly empty), ``url``, and an optional ``snippet`` —
plus a ``content`` extract this adapter never reads.

These hermetic tests are the parser and request-shape coverage; the live
test in ``tests/live/test_live.py`` has run against the real endpoint (2026-10-17),
which is what cleared the untested status -- the name is no longer
in ``config.UNTESTED_PROVIDERS`` and the ``--check`` line does not name it.
"""

import json
from typing import Any

import httpx
import pytest

from seekwright.config import Config, ProviderConfig
from seekwright.factory import build_providers
from seekwright.models import SearchQuery
from seekwright.providers.anysearch import AnysearchProvider
from seekwright.providers.base import ProviderError, QuotaExhausted

SAMPLE: dict[str, Any] = {
    "code": 0,
    "message": "success",
    "request_id": "7d6f4e91-2a83-4c5b-9f10-6e8a3d27b541",
    "data": {
        "results": [
            {
                "title": "Go 1.26 Release Notes",
                "url": "https://go.dev/doc/go1.26",
                "snippet": "Introduction to the changes in Go 1.26.",
                "content": "Go 1.26 introduces changes to the language, "
                "toolchain, runtime, and libraries...",
            },
            {
                "title": "",
                "url": "https://example.com/untitled",
                "snippet": "A source that provides no title.",
            },
            {
                "title": "Snippet omitted upstream",
                "url": "https://example.com/no-snippet",
            },
        ],
        "metadata": {"total_results": 3, "search_time_ms": 312},
    },
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> AnysearchProvider:
    return AnysearchProvider(client or httpx.AsyncClient(), **kw)


def mock_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


class TestParsing:
    def test_extracts_records_that_carry_a_title_and_url(self):
        results = provider()._parse(SAMPLE["data"], limit=10)
        # The empty `title` drops the record the way a missing one does.
        assert len(results) == 2
        assert results[0].title == "Go 1.26 Release Notes"
        assert results[0].url == "https://go.dev/doc/go1.26"
        assert results[1].url == "https://example.com/no-snippet"

    def test_honours_the_limit(self):
        assert len(provider()._parse(SAMPLE["data"], limit=1)) == 1

    def test_snippet_is_kept_and_never_text(self):
        results = provider()._parse(SAMPLE["data"], limit=10)
        assert results[0].snippet == "Introduction to the changes in Go 1.26."
        assert results[0].text is None, (
            "a SERP backend fills snippet, never text"
        )

    def test_the_content_extract_is_never_read(self):
        """Filling both would ship the same prose twice; `content` is dropped."""
        results = provider()._parse(SAMPLE["data"], limit=10)
        for res in results:
            assert res.text is None
            assert "introduces changes to the language" not in (res.snippet or "")

    def test_a_missing_snippet_stays_none(self):
        """`snippet` is documented as omitted when unavailable -- never invented."""
        results = provider()._parse(SAMPLE["data"], limit=10)
        assert results[1].snippet is None

    def test_no_date_is_invented(self):
        """No date field exists upstream, so `published_date` stays empty."""
        results = provider()._parse(SAMPLE["data"], limit=10)
        for res in results:
            assert res.published_date is None

    def test_snippet_is_truncated(self):
        # The cap is below the fixture's normalised length (39), so the clip
        # bites: a cap of 40 would keep the snippet whole and say nothing.
        results = provider(snippet_chars=30)._parse(SAMPLE["data"], limit=10)
        assert len(results[0].snippet or "") <= 31  # the ellipsis is one char

    def test_the_length_the_cap_discarded_is_recorded(self):
        """`search.cap` reads this: the pre-cap length, log-only and off the wire."""
        hit = provider(snippet_chars=30)._parse(SAMPLE["data"], limit=10)[0]
        uncapped = hit._uncapped_chars
        assert uncapped is not None
        assert uncapped == len(
            " ".join(SAMPLE["data"]["results"][0]["snippet"].split())
        )
        assert uncapped > len(hit.snippet or "")
        # Private, so a caller can never see it: the response carries the
        # clipped snippet, never a measurement of the clip.
        assert "_uncapped_chars" not in hit.model_dump()

    def test_records_without_a_url_are_dropped(self):
        data = {"results": [{"title": "No url here"}]}
        assert provider()._parse(data, limit=10) == []

    def test_records_without_a_title_are_dropped(self):
        data = {"results": [{"url": "https://example.com"}]}
        assert provider()._parse(data, limit=10) == []

    def test_an_empty_title_is_a_missing_title(self):
        """Documented as always present but possibly empty -- dropped, not kept."""
        data = {"results": [{"title": "", "url": "https://example.com"}]}
        assert provider()._parse(data, limit=10) == []

    def test_non_dict_records_are_skipped(self):
        data = {"results": ["nonsense", {"title": "t", "url": "https://x"}]}
        assert len(provider()._parse(data, limit=10)) == 1

    def test_missing_container_is_empty_not_an_error(self):
        assert provider()._parse({"results": None}, limit=10) == []
        assert provider()._parse({}, limit=10) == []
        # The envelope itself can carry no `data` object: still empty, not an
        # error, for the same reason the missing container is.
        assert provider()._parse(None, limit=10) == []
        assert provider()._parse(["a", "b"], limit=10) == []


class TestUpstreamFieldGuards:
    """A non-string ``snippet`` or ``title`` is dropped, not raised.

    The upstream payload is untrusted: the schema documents the fields as
    strings, but nothing enforces that. A shape drift must not turn into a
    ``ValidationError`` (pydantic) or an ``AttributeError`` (out of
    ``truncate_snippet``'s ``text.split()``) that escapes the engine's
    provider-error handling as an internal error -- the call has to succeed
    with the field dropped, exactly as the sibling adapters do.
    """

    @pytest.mark.parametrize("bad_snippet", [{"nested": "object"}, ["a", "b"], 7])
    async def test_a_non_string_snippet_is_dropped_and_the_call_succeeds(
        self, bad_snippet
    ):
        data = {
            "code": 0,
            "message": "success",
            "data": {
                "results": [
                    {
                        "title": "t",
                        "url": "https://example.com/a",
                        "snippet": bad_snippet,
                    }
                ]
            },
        }
        p = provider(mock_client(lambda _: httpx.Response(200, json=data)))
        result = await p.search(SearchQuery(query="q"))
        assert len(result.results) == 1
        assert result.results[0].snippet is None

    @pytest.mark.parametrize("bad_title", [{"nested": "object"}, ["a", "b"], 7])
    async def test_a_non_string_title_drops_the_record(self, bad_title):
        data = {
            "code": 0,
            "message": "success",
            "data": {
                "results": [
                    {"title": bad_title, "url": "https://example.com/a"},
                    {"title": "kept", "url": "https://example.com/b"},
                ]
            },
        }
        p = provider(mock_client(lambda _: httpx.Response(200, json=data)))
        result = await p.search(SearchQuery(query="q"))
        assert [res.title for res in result.results] == ["kept"]

    async def test_a_string_snippet_still_reaches_the_model(self):
        """The guard must not change behaviour for a well-formed payload."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q"))
        assert result.results[0].snippet == "Introduction to the changes in Go 1.26."


class TestRequestShape:
    """The body AnySearch is sent, and the constraints it cannot honour.

    Only ``language`` rides the wire: there is no domain field, no date field,
    no safe-search field, and ``zone`` takes ``cn`` / ``intl`` -- a binary a
    country code cannot map into without guessing. Every drop is named in the
    ``notice``, which is the only thing standing between a caller that asked
    for the filter and the belief that it got it.
    """

    async def _search(self, **kw):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        result = await provider(mock_client(handler)).search(
            SearchQuery(query="wal mode", **kw)
        )
        return json.loads(seen["request"].content), seen["request"], result

    async def test_posts_json_to_the_documented_endpoint_without_auth(self):
        _, request, _ = await self._search()
        assert request.method == "POST"
        assert request.url.host == "api.anysearch.com"
        assert request.url.path == "/v1/search"
        # Keyless by scope: no Authorization header is ever sent.
        assert "Authorization" not in request.headers

    async def test_the_query_and_max_results_are_sent(self):
        body, _, _ = await self._search(max_results=3)
        assert body["query"] == "wal mode"
        assert body["max_results"] == 3

    async def test_max_results_is_clamped_to_the_documented_range(self):
        """The tool caps `max_results` at 20; the API's range is 1-10, so 11-20
        would be a documented-invalid request (400) rather than a search."""
        body, _, _ = await self._search(max_results=20)
        assert body["max_results"] == 10

    async def test_language_is_lowercased_on_the_wire(self):
        body, _, result = await self._search(language="DE")
        assert body["language"] == "de"
        # Language is honoured, so a language-only constraint carries no notice.
        assert result.notice is None

    async def test_language_is_absent_without_a_language(self):
        body, _, _ = await self._search()
        assert "language" not in body

    async def test_never_sends_a_region_or_capability_field(self):
        """`zone` is a binary a country cannot map into; `tag`, `params` and
        `format` are operator policy and an encoding for the extract this
        adapter does not read. None of them may appear in a body at all."""
        body, _, _ = await self._search(
            country="de",
            language="en",
        )
        for field in ("zone", "tag", "params", "format"):
            assert field not in body

    async def test_an_unconstrained_query_carries_no_notice(self):
        _, _, result = await self._search()
        assert result.notice is None

    async def test_a_country_constraint_is_noticed(self):
        """`language` is honoured, so the bucket is split and the notice names
        only the country half."""
        _, _, result = await self._search(country="de")
        assert result.notice == (
            "cannot filter by country; that constraint was ignored"
        )

    async def test_a_recency_constraint_is_noticed(self):
        _, _, result = await self._search(recency="week")
        assert result.notice == (
            "cannot filter by dates; that constraint was ignored"
        )

    @pytest.mark.parametrize("safe_search", [True, False])
    async def test_a_safe_search_is_noticed_for_both_values(self, safe_search):
        _, _, result = await self._search(safe_search=safe_search)
        assert result.notice == (
            "cannot filter by safe-search; that constraint was ignored"
        )

    async def test_domain_filters_are_noticed(self):
        _, _, result = await self._search(
            include_domains=["go.dev"], exclude_domains=["spam.example"]
        )
        assert result.notice == (
            "cannot filter by domain; that constraint was ignored"
        )

    async def test_all_dropped_buckets_are_named_together(self):
        _, _, result = await self._search(
            include_domains=["go.dev"],
            recency="day",
            country="de",
            safe_search=True,
            language="en",
        )
        assert result.notice == (
            "cannot filter by domain or dates or country or safe-search; that "
            "constraint was ignored"
        )

    async def test_the_honoured_bucket_stays_silent(self):
        """Only the dropped halves may appear in the notice."""
        _, _, result = await self._search(language="en", country="de")
        assert result.notice == (
            "cannot filter by country; that constraint was ignored"
        )


class TestErrors:
    """Only the rows this adapter answers differently.

    The six rows every HTTP adapter owes are pinned once for all of them by
    ``tests/providers/test_provider_contract.py``. What stays here is this adapter's quota
    statuses, the credential-bearing 402 body, its business-error codes, and the
    leak regression that proves the redaction rule for its keyless request.
    """

    @pytest.mark.parametrize("status", [402, 429])
    async def test_quota_and_rate_limit_are_quota(self, status: int):
        # 402's body may carry auto-generated credentials, so the message is the
        # constant.
        p = provider(mock_client(lambda _: httpx.Response(status, json={})))
        with pytest.raises(QuotaExhausted) as exc:
            await p.search(SearchQuery(query="q"))
        assert exc.value.retryable is False

    async def test_a_402_body_with_credentials_never_reaches_the_message(self):
        """The redaction rule's reason: the auto-registration flow puts a
        username, password and API key inside the 402 `message`."""
        body = {
            "code": -1,
            "message": (
                "Your account and API key have been automatically generated. "
                "Use the API key below to continue.\n"
                "username=op123\npassword=secret-password\napi_key=sk-live-abc"
            ),
        }
        p = provider(mock_client(lambda _: httpx.Response(402, json=body)))
        with pytest.raises(QuotaExhausted) as exc:
            await p.search(SearchQuery(query="q"))
        for secret in ("op123", "secret-password", "sk-live-abc"):
            assert secret not in str(exc.value)

    async def test_a_nonzero_business_code_fails_without_echoing_the_message(self):
        """The envelope's own contract: success is `code: 0`. The error
        channel's `message` is operator text the 402 flow shows can hold
        credentials, so the raised message is a constant."""
        body = {
            "code": -1,
            "message": "Query is required. caller=seekwright-deployment",
        }
        p = provider(mock_client(lambda _: httpx.Response(200, json=body)))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        assert exc.value.message == "search failed (business error)"
        assert "caller=seekwright-deployment" not in str(exc.value)

    async def test_a_missing_business_code_fails_the_same_way(self):
        body = {"message": "success", "data": {"results": []}}
        p = provider(mock_client(lambda _: httpx.Response(200, json=body)))
        with pytest.raises(ProviderError, match="business error"):
            await p.search(SearchQuery(query="q"))

    async def test_network_error_does_not_echo_the_request(self):
        def handler(_: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError(
                "connection refused for https://api.anysearch.com/v1/search "
                "query=secret-query"
            )

        p = provider(mock_client(handler))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        # The message must not carry the underlying exception: httpx errors
        # can echo the request, and the request names this deployment.
        assert exc.value.message == "network error"
        assert "secret-query" not in str(exc.value)


class TestCost:
    def test_cost_is_flat_zero(self):
        """The keyless mode cannot bill: nothing to scale, nothing to bill."""
        p = provider()
        assert p.cost_for(1) == p.cost_for(10) == 0.0
        assert p.cost_per_1k == 0.0

    async def test_reports_its_flat_cost_on_the_result(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=5))
        assert result.provider == "anysearch"
        assert result.cost_usd == 0.0


class TestWiring:
    def test_built_when_enabled_without_any_key(self, monkeypatch):
        """Keyless: no key guards construction, unlike the keyed names."""
        monkeypatch.delenv("SEEKWRIGHT_ANYSEARCH_API_KEY", raising=False)
        cfg = Config(providers={"anysearch": ProviderConfig()})
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["anysearch"], AnysearchProvider)
        assert built["anysearch"].cost_per_1k == 0.0

    def test_config_can_correct_the_cost(self):
        """An operator on a future paid tier can fix what `--check` reports."""
        cfg = Config(providers={"anysearch": ProviderConfig(cost_per_1k=0.5)})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["anysearch"].cost_per_1k == 0.5

    def test_a_disabled_entry_is_not_built(self):
        cfg = Config(providers={"anysearch": ProviderConfig(enabled=False)})
        assert "anysearch" not in build_providers(cfg, httpx.AsyncClient())
