"""The REST projection: `POST /api/v1/search`, `POST /api/v1/fetch`, `answer`.

The routes live in `server.py`, beside `/healthz` and `/dashboard`; this module is
their test. It drives the real app over ASGI with a real `AppContext` and stubs
where the network would be, because what the projection must get right is the
status code and the body -- the operation behind it is `tests/test_engine.py`'s
and `tests/fetch/test_fetch_engine.py`'s.

`answer` has two upstreams: the retrieval it shares with `search` and the model
call `tests/test_agent.py` owns. Both are stubbed, so what is asserted is the
projection: 200, 400, 404, 502, 503 and the sentence each carries.

The spec is `docs/reference/public-api.md`: the request body is the tool's
parameter set, the response body is the tool's response model, and its status
table is the acceptance criteria. `SearchRefused` and `FetchRefused` carry the
400/502 split and are raised before anything is dispatched, which is why
`tests/test_engine.py` still sees them as `SearchFailed`/`FetchFailed`.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import inspect
from collections.abc import AsyncGenerator
from typing import Any

import httpx
import pytest

from seekwright.config import AgentConfig, Config, FetchConfig, ProviderConfig
from seekwright.fetcher import FetchedImage, FetchedPage, HttpFetcher
from seekwright.models import (
    AnswerRequest,
    FetchRequest,
    ProviderResult,
    Result,
    SearchQuery,
    SearchRequest,
)
from seekwright.prompts import ANSWER_SYSTEM_PROMPT
from seekwright.providers.base import ProviderError

HOST = "127.0.0.1:8000"


class _StubProvider:
    """Minimal provider: one hit, or whatever the test asks it to do."""

    def __init__(
        self,
        name: str = "serper",
        *,
        results: list[Result] | None = None,
        notice: str | None = None,
        error: Exception | None = None,
        cost_usd: float = 0.001,
    ) -> None:
        self.name = name
        self.cost_per_1k = 0.001
        self.calls = 0
        self._results = (
            results
            if results is not None
            else [Result(title="t", url="https://example.com/a", snippet="s")]
        )
        self._notice = notice
        self._error = error
        self._cost_usd = cost_usd

    async def search(self, q: SearchQuery) -> ProviderResult:
        self.calls += 1
        if self._error is not None:
            raise self._error
        return ProviderResult(
            provider=self.name,
            results=self._results,
            notice=self._notice,
            cost_usd=self._cost_usd,
        )

    async def aclose(self) -> None:
        return None


class _StubFetcher:
    """A local fetcher that returns a page without a network call, or raises."""

    name = "fetch"
    cost_per_1k: float | None = None

    def __init__(
        self,
        *,
        name: str = "fetch",
        text: str | None = None,
        error: Exception | None = None,
        image: FetchedImage | None = None,
    ) -> None:
        # `name` is an instance attribute so one class can stand for the local
        # fetcher and for a named fallback.
        self.name = name
        self.calls = 0
        self._text = text
        self._error = error
        self._image = image

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        self.calls += 1
        if self._error is not None:
            raise self._error
        if self._image is not None:
            # An image page carries no text, which is what `HttpFetcher` returns;
            # the stub has to say the same thing for the engine to treat it alike.
            return FetchedPage(
                url=url,
                title=None,
                text="",
                content_type=self._image.media_type,
                status_code=200,
                truncated=False,
                total_chars=0,
                image=self._image,
            )
        text = self._text if self._text is not None else "The page body. " * 40
        return FetchedPage(
            url=url,
            title="A Page",
            text=text,
            content_type="text/html",
            status_code=200,
            truncated=False,
            total_chars=len(text),
        )

    async def aclose(self) -> None:
        return None


_PNG = b"\x89PNG\r\n\x1a\n" + b"a png body"
_B64_PNG = base64.b64encode(_PNG).decode("ascii")


class _StubModel:
    """A stubbed OpenAI-compatible endpoint: no test reaches a real model.

    `httpx.MockTransport` rather than a patched `AgentEngine`, so the call that
    is exercised is the one `agent.py` really makes -- URL, headers, payload --
    and only the far end is fake.
    """

    def __init__(
        self,
        *,
        content: str = "An answer, cited [1].",
        status: int = 200,
        usage: tuple[int, int] | None = (11, 7),
    ) -> None:
        self.calls = 0
        self._content = content
        self._status = status
        self._usage = usage

    async def __call__(self, request: httpx.Request) -> httpx.Response:
        self.calls += 1
        if self._status != 200:
            return httpx.Response(self._status, text="upstream said no")
        payload: dict[str, Any] = {
            "choices": [
                {"message": {"content": self._content}, "finish_reason": "stop"}
            ]
        }
        if self._usage is not None:
            payload["usage"] = {
                "prompt_tokens": self._usage[0],
                "completion_tokens": self._usage[1],
            }
        return httpx.Response(200, json=payload)


@pytest.fixture
def srv():
    """`server` with both REST routes registered, exactly as `_serve_http` does.

    Registering here rather than at import keeps the test's route table the
    server's: the paths and the methods are read off the same call the HTTP
    path makes, and `TestRoutesAreRegistered` pins that call itself.
    """
    import seekwright.server as srv

    srv.mcp.custom_route("/api/v1/search", methods=["POST"])(srv.api_search)
    srv.mcp.custom_route("/api/v1/fetch", methods=["POST"])(srv.api_fetch)
    srv.mcp.custom_route("/api/v1/answer", methods=["POST"])(srv.api_answer)
    return srv


def _config(**fetch_kw: Any) -> Config:
    """One provider with a default: the deployment the routes are aimed at.

    Agent mode off, which is the default and therefore the deployment most
    callers meet: `answer` is a 404 here.
    """
    return Config(
        providers={"serper": ProviderConfig()},
        default_provider="serper",
        fetch=FetchConfig(**fetch_kw),
    )


def _agent_config(**agent_kw: Any) -> Config:
    """The same deployment with `[agent] enabled = true`.

    The endpoint is a name that never resolves -- every test that reaches the
    model swaps the engine's client for `_StubModel`, so nothing here can leave
    the machine even if one forgot to.
    """
    return Config(
        providers={"serper": ProviderConfig()},
        default_provider="serper",
        agent=AgentConfig(
            enabled=True,
            base_url="https://model.test/v1",
            model="test-model",
            **agent_kw,
        ),
    )


@pytest.fixture
def agent_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """The model key, which `AgentEngine` refuses to call an endpoint without."""
    monkeypatch.setenv("SEEKWRIGHT_AGENT_API_KEY", "test-key")


@contextlib.asynccontextmanager
async def _served(
    srv: Any,
    cfg: Config,
    monkeypatch: pytest.MonkeyPatch,
    *,
    providers: dict[str, _StubProvider] | None = None,
    fetcher: _StubFetcher | None = None,
    fallbacks: list[_StubFetcher] | None = None,
    model: _StubModel | None = None,
) -> AsyncGenerator[tuple[Any, dict[str, _StubProvider]]]:
    """A real `AppContext` with stub engines, served through the real app.

    `build_providers` is patched, so no provider key and no network is needed;
    everything else -- the config, the fetch stack, the recorder -- is what the
    process would run with. A `fetcher` left out means the *real* local fetcher,
    which is what the guardrail tests want: they exercise `validate_url` and
    `resolve_public` rather than a stub that pretends to be refused.

    A `model` swaps the agent engine's client for one that talks to a stub
    endpoint. The client is the process's, shared with every provider, so it is
    replaced rather than reconfigured -- and only for the duration, because the
    context manager that owns the real one closes it on the way out.
    """
    stubs = (
        providers
        if providers is not None
        else {name: _StubProvider(name) for name in cfg.enabled_providers()}
    )
    monkeypatch.setattr(
        srv, "build_providers", lambda _config, _client: dict(stubs)
    )
    async with srv.build_app_context(cfg) as ctx:
        monkeypatch.setattr(srv, "_shared", ctx)
        if fetcher is not None:
            assert ctx.fetch_engine is not None
            ctx.fetch_engine.fetcher = fetcher
        if fallbacks is not None:
            # The names a caller may pass to `fetch(provider=...)` are the ones
            # this deployment built, so a test that names one needs a stack.
            assert ctx.fetch_engine is not None
            ctx.fetch_engine.fallbacks = list(fallbacks)
        model_client = None
        if model is not None:
            assert ctx.agent_engine is not None
            model_client = httpx.AsyncClient(transport=httpx.MockTransport(model))
            ctx.agent_engine.client = model_client
        try:
            yield srv.mcp.streamable_http_app(), stubs
        finally:
            if model_client is not None:
                await model_client.aclose()


async def _post(
    app: Any,
    path: str,
    payload: Any = None,
    *,
    raw: str | None = None,
    headers: dict[str, str] | None = None,
) -> httpx.Response:
    """POST through the app. The Host defaults to the loopback the guard allows."""
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(
        transport=transport, base_url=f"http://{HOST}"
    ) as client:
        if raw is not None:
            return await client.post(
                path,
                content=raw.encode(),
                headers={"Content-Type": "application/json", **(headers or {})},
            )
        return await client.post(path, json=payload, headers=headers or {})


async def _get(app: Any, path: str, **params: Any) -> httpx.Response:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(
        transport=transport, base_url=f"http://{HOST}"
    ) as client:
        return await client.get(path, params=params)


class TestSearchRoute:
    async def test_it_returns_the_tool_response(self, srv, monkeypatch):
        async with _served(srv, _config(), monkeypatch) as (app, stubs):
            r = await _post(app, "/api/v1/search", {"query": "sqlite wal mode"})

        assert r.status_code == 200
        assert r.headers["content-type"].startswith("application/json")
        body = r.json()
        assert body["query"] == "sqlite wal mode"
        assert body["provider"] == "serper"
        assert body["results"] == [
            {"title": "t", "url": "https://example.com/a", "snippet": "s"}
        ]
        assert "retrieved_at" in body
        assert stubs["serper"].calls == 1

    async def test_zero_results_is_a_response(self, srv, monkeypatch):
        """200, not 404: the operation succeeded and the web was empty."""
        stub = _StubProvider(results=[])
        async with _served(
            srv, _config(), monkeypatch, providers={"serper": stub}
        ) as (app, _):
            r = await _post(app, "/api/v1/search", {"query": "nothing at all"})

        assert r.status_code == 200
        assert r.json()["results"] == []
        assert "No results from serper" in r.json()["notice"]

    async def test_an_ignored_filter_is_a_response(self, srv, monkeypatch):
        """The `notice` reports it; the status code does not punish it."""
        stub = _StubProvider(notice="cannot filter by dates; that constraint was ignored")
        async with _served(
            srv, _config(), monkeypatch, providers={"serper": stub}
        ) as (app, _):
            r = await _post(
                app, "/api/v1/search", {"query": "sqlite wal mode", "recency": "day"}
            )

        assert r.status_code == 200
        assert r.json()["notice"] == "cannot filter by dates; that constraint was ignored"

    async def test_the_body_is_the_tool_parameter_set(self, srv, monkeypatch):
        """Every tool parameter reaches the engine, and nothing else does."""
        stub = _StubProvider()
        async with _served(
            srv, _config(), monkeypatch, providers={"serper": stub}
        ) as (app, _):
            r = await _post(
                app,
                "/api/v1/search",
                {
                    "query": "sqlite wal mode",
                    "provider": "serper",
                    "max_results": 3,
                    "include_domains": ["sqlite.org"],
                    "exclude_domains": ["example.com"],
                    "recency": "month",
                },
            )

        assert r.status_code == 200

    async def test_cost_usd_never_reaches_the_body(self, srv, monkeypatch):
        """The caller is not the party paying, and `WireModel` sends no nulls."""
        stub = _StubProvider(cost_usd=0.001)
        async with _served(
            srv, _config(), monkeypatch, providers={"serper": stub}
        ) as (app, _):
            r = await _post(app, "/api/v1/search", {"query": "sqlite wal mode"})

        assert "cost_usd" not in r.text
        assert "null" not in r.text

    @pytest.mark.parametrize(
        "payload",
        [
            {"query": "x"},
            {"query": "sqlite wal mode", "max_results": 0},
            {"query": "sqlite wal mode", "max_results": 21},
            {"query": "sqlite wal mode", "recency": "fortnight"},
            {"query": "sqlite wal mode", "strategy": "cheapest"},
            # The tool's `mode` is `Literal["free"]`, so `"task"` -- the reserved
            # member -- is a field error.
            {"query": "sqlite wal mode", "mode": "task"},
            {},
        ],
    )
    async def test_a_body_that_does_not_validate_is_a_400(
        self, srv, monkeypatch, payload
    ):
        async with _served(srv, _config(), monkeypatch) as (app, _):
            r = await _post(app, "/api/v1/search", payload)

        assert r.status_code == 400
        assert "Invalid request" in r.json()["error"]

    @pytest.mark.parametrize("raw", ["not json at all", "[1, 2, 3]"])
    async def test_a_body_that_is_not_a_json_object_is_a_400(
        self, srv, monkeypatch, raw
    ):
        async with _served(srv, _config(), monkeypatch) as (app, _):
            r = await _post(app, "/api/v1/search", raw=raw)

        assert r.status_code == 400
        assert r.json()["error"]

    async def test_a_provider_this_deployment_does_not_serve_is_a_400(
        self, srv, monkeypatch
    ):
        """Refused before dispatch, so nothing was billed -- and the sentence
        is the one the MCP tool hands the model."""
        async with _served(srv, _config(), monkeypatch) as (app, stubs):
            r = await _post(
                app, "/api/v1/search", {"query": "sqlite wal mode", "provider": "nope"}
            )

        assert r.status_code == 400
        assert r.json()["error"] == (
            "Provider 'nope' is not enabled on this server. Available: serper. "
            "Retry with one of those, or omit `provider` to use the default."
        )
        assert stubs["serper"].calls == 0

    async def test_no_default_and_none_named_is_a_400(self, srv, monkeypatch):
        cfg = Config(providers={"serper": ProviderConfig(), "exa:free": ProviderConfig()})
        assert cfg.default_provider is None, "two enabled providers: callers choose"
        async with _served(srv, cfg, monkeypatch) as (app, stubs):
            r = await _post(app, "/api/v1/search", {"query": "sqlite wal mode"})

        assert r.status_code == 400
        assert "No default provider is configured" in r.json()["error"]
        assert {stub.calls for stub in stubs.values()} == {0}

    async def test_a_free_only_search_is_served_by_a_free_provider(
        self, srv, monkeypatch
    ):
        """`mode` is projected, so a REST caller can declare the ceiling an MCP
        caller can -- and the response names the free fallback that served it."""
        from seekwright.config import FREE_PROVIDERS

        cfg = Config(providers={"exa:free": ProviderConfig()})
        assert cfg.default_provider == "exa:free", "one enabled provider is the default"
        async with _served(srv, cfg, monkeypatch) as (app, stubs):
            r = await _post(
                app, "/api/v1/search", {"query": "sqlite wal mode", "mode": "free"}
            )

        assert r.status_code == 200
        assert r.json()["provider"] == "exa:free"
        assert r.json()["provider"] in FREE_PROVIDERS
        assert stubs["exa:free"].calls == 1

    async def test_a_free_only_search_without_a_free_provider_is_a_400(
        self, srv, monkeypatch
    ):
        """`_resolve_free`'s refusal: nothing is dispatched, so nothing is
        billed, and the sentence says what this deployment does not have."""
        async with _served(srv, _config(), monkeypatch) as (app, stubs):
            r = await _post(
                app, "/api/v1/search", {"query": "sqlite wal mode", "mode": "free"}
            )

        assert r.status_code == 400
        assert "No free provider is enabled on this server" in r.json()["error"]
        assert stubs["serper"].calls == 0

    async def test_provider_and_mode_together_are_a_400(self, srv, monkeypatch):
        """The contradiction `fetch` answers for `query`/`offset`, in the same
        words -- refused before dispatch, so nothing was billed."""
        async with _served(srv, _config(), monkeypatch) as (app, stubs):
            r = await _post(
                app,
                "/api/v1/search",
                {"query": "sqlite wal mode", "provider": "serper", "mode": "free"},
            )

        assert r.status_code == 400
        assert r.json()["error"] == "pass `provider` or `mode`, not both"
        assert stubs["serper"].calls == 0

    async def test_a_provider_failure_is_a_502(self, srv, monkeypatch):
        """Dispatched and failed upstream: the message is the model's, the
        status is the caller's."""
        stub = _StubProvider(error=ProviderError("serper", "rate limited"))
        async with _served(
            srv, _config(), monkeypatch, providers={"serper": stub}
        ) as (app, _):
            r = await _post(app, "/api/v1/search", {"query": "sqlite wal mode"})

        assert r.status_code == 502
        assert r.json()["error"] == (
            "Search failed - serper: rate limited. Retry shortly or try a "
            "different phrasing."
        )

    async def test_quota_exhaustion_is_a_502(self, srv, monkeypatch):
        from seekwright.providers.base import QuotaExhausted

        stub = _StubProvider(error=QuotaExhausted("serper"))
        async with _served(
            srv, _config(), monkeypatch, providers={"serper": stub}
        ) as (app, _):
            r = await _post(app, "/api/v1/search", {"query": "sqlite wal mode"})

        assert r.status_code == 502
        assert "Do not retry immediately" in r.json()["error"]


class TestFetchRoute:
    async def test_it_returns_the_tool_response(self, srv, monkeypatch):
        async with _served(
            srv, _config(), monkeypatch, fetcher=_StubFetcher()
        ) as (app, _):
            r = await _post(app, "/api/v1/fetch", {"url": "https://example.com/a"})

        assert r.status_code == 200
        assert r.headers["content-type"].startswith("application/json")
        body = r.json()
        assert body["url"] == "https://example.com/a"
        assert body["requested_url"] == "https://example.com/a"
        assert body["title"] == "A Page"
        assert body["status_code"] == 200
        assert body["text"].startswith("The page body.")
        assert "cost_usd" not in r.text
        assert "null" not in r.text

    async def test_a_query_fetch_returns_matches_not_text(self, srv, monkeypatch):
        """`text` and `matches` are alternatives, on this encoding too."""
        async with _served(
            srv, _config(), monkeypatch, fetcher=_StubFetcher()
        ) as (app, _):
            r = await _post(
                app, "/api/v1/fetch", {"url": "https://example.com/a", "query": "body"}
            )

        assert r.status_code == 200
        body = r.json()
        assert body["matches"], body
        assert "text" not in body

    async def test_paging_returns_the_offset_it_read_from(self, srv, monkeypatch):
        async with _served(
            srv, _config(), monkeypatch, fetcher=_StubFetcher()
        ) as (app, _):
            r = await _post(
                app, "/api/v1/fetch", {"url": "https://example.com/a", "offset": 10}
            )

        assert r.status_code == 200
        assert r.json()["offset"] == 10

    async def test_a_url_the_guardrails_refuse_is_a_400(self, srv, monkeypatch):
        """The real fetcher, no stub: a loopback URL is refused before any
        request is sent, which is what makes it the caller's mistake."""
        async with _served(srv, _config(), monkeypatch) as (app, _):
            r = await _post(app, "/api/v1/fetch", {"url": "http://127.0.0.1:9/x"})

        assert r.status_code == 400
        assert r.json()["error"] == (
            "Fetch failed - fetch: 127.0.0.1 is not a public address."
        )

    async def test_a_scheme_the_fetcher_cannot_read_is_a_400(self, srv, monkeypatch):
        async with _served(srv, _config(), monkeypatch) as (app, _):
            r = await _post(app, "/api/v1/fetch", {"url": "file:///etc/passwd"})

        assert r.status_code == 400
        assert "only http and https are allowed" in r.json()["error"]

    async def test_query_and_offset_together_are_a_400(self, srv, monkeypatch):
        async with _served(
            srv, _config(), monkeypatch, fetcher=_StubFetcher()
        ) as (app, _):
            r = await _post(
                app,
                "/api/v1/fetch",
                {"url": "https://example.com/a", "query": "body", "offset": 10},
            )

        assert r.status_code == 400
        assert r.json()["error"] == "pass `query` or `offset`, not both"

    async def test_a_path_that_cannot_be_read_is_a_400(self, srv, monkeypatch):
        """The grammar is checked before the fetch, so a junk selector costs no request."""
        async with _served(
            srv, _config(), monkeypatch, fetcher=_StubFetcher()
        ) as (app, _):
            r = await _post(
                app,
                "/api/v1/fetch",
                {"url": "https://example.com/a", "path": "$.items[?(@.id)]"},
            )

        assert r.status_code == 400
        assert r.json()["error"].startswith("`path` is not readable")

    async def test_a_path_with_a_query_is_a_400(self, srv, monkeypatch):
        async with _served(
            srv, _config(), monkeypatch, fetcher=_StubFetcher()
        ) as (app, _):
            r = await _post(
                app,
                "/api/v1/fetch",
                {"url": "https://example.com/a", "path": "$.items", "query": "body"},
            )

        assert r.status_code == 400
        assert r.json()["error"] == "pass `path`, `query` or `offset`, one at a time"

    async def test_a_path_on_a_page_that_is_not_json_returns_the_page_with_a_notice(
        self, srv, monkeypatch
    ):
        """The constraint the page cannot honour is reported, not an error: the page was fetched."""
        async with _served(
            srv, _config(), monkeypatch, fetcher=_StubFetcher()
        ) as (app, _):
            r = await _post(
                app, "/api/v1/fetch", {"url": "https://example.com/a", "path": "$.items"}
            )

        assert r.status_code == 200
        body = r.json()
        assert body["text"], "the page is the answer when there is no structure to select"
        assert "not one this server could read" in body["notice"]

    async def test_a_disabled_fetch_is_a_404(self, srv, monkeypatch):
        """`[fetch] enabled = false`: the operation is not served here."""
        async with _served(
            srv, _config(enabled=False), monkeypatch
        ) as (app, _):
            r = await _post(app, "/api/v1/fetch", {"url": "https://example.com/a"})

        assert r.status_code == 404
        assert r.json()["error"] == (
            "This server has the fetch tool disabled; use `search` instead."
        )

    async def test_a_disabled_fetch_still_serves_search(self, srv, monkeypatch):
        async with _served(srv, _config(enabled=False), monkeypatch) as (app, _):
            r = await _post(app, "/api/v1/search", {"query": "sqlite wal mode"})

        assert r.status_code == 200

    async def test_a_failed_fetch_is_a_502(self, srv, monkeypatch):
        fetcher = _StubFetcher(error=ProviderError("fetch", "HTTP 500"))
        async with _served(
            srv, _config(), monkeypatch, fetcher=fetcher
        ) as (app, _):
            r = await _post(app, "/api/v1/fetch", {"url": "https://example.com/a"})

        assert r.status_code == 502
        assert r.json()["error"] == (
            "Fetch failed - fetch: HTTP 500. Retry shortly, or search for the "
            "content."
        )

    async def test_an_extraction_failure_after_dispatch_is_a_502(self, srv, monkeypatch):
        """`cannot extract text` fires with the request already sent, so it is a
        failed fetch rather than a refused one -- the split the engine's
        `UrlBlocked` draws."""
        fetcher = _StubFetcher(error=ProviderError("fetch", "cannot extract text: boom"))
        async with _served(
            srv, _config(), monkeypatch, fetcher=fetcher
        ) as (app, _):
            r = await _post(app, "/api/v1/fetch", {"url": "https://example.com/a"})

        assert r.status_code == 502

    async def test_an_unrunnable_fetch_provider_is_a_400(self, srv, monkeypatch):
        """`fetch` naming a provider this server cannot serve: nothing dispatched.

        `FetchRefused` already means *refused before a request was sent*, so this
        is the same 400 a guardrail URL refusal gets, not a 502. With no fetch
        provider configured the sentence states that rather than printing an
        empty list.
        """
        local = _StubFetcher()
        async with _served(
            srv, _config(), monkeypatch, fetcher=local
        ) as (app, _):
            r = await _post(
                app,
                "/api/v1/fetch",
                {"url": "https://example.com/a", "provider": "scraper"},
            )

        assert r.status_code == 400
        assert local.calls == 0, "a refusal dispatches nothing"
        assert r.json()["error"] == (
            "Fetch provider 'scraper' is not enabled on this server. No other "
            "fetch provider is configured on this server. Retry with one of "
            "those, or omit `provider` to read the page locally."
        )

    async def test_an_unbuilt_fetch_provider_is_a_400_naming_the_built_ones(
        self, srv, monkeypatch
    ):
        """The registry has the name and this deployment never built it.

        No key, no URL, or excluded by the permission set: the engine cannot tell
        those apart and does not try to, so all three reach this one sentence --
        and the list in it is what the caller can act on.
        """
        built = _StubFetcher(name="crawl4ai")
        async with _served(
            srv, _config(), monkeypatch, fetcher=_StubFetcher(), fallbacks=[built]
        ) as (app, _):
            r = await _post(
                app,
                "/api/v1/fetch",
                {"url": "https://example.com/a", "provider": "scrappa"},
            )

        assert r.status_code == 400
        assert built.calls == 0
        assert "Available: crawl4ai." in r.json()["error"]

    async def test_a_named_fetch_provider_is_the_one_that_serves(
        self, srv, monkeypatch
    ):
        """The named route over REST: that provider answers, the local read does not run."""
        local = _StubFetcher()
        named = _StubFetcher(
            name="crawl4ai", text="Rendered by the named provider. " * 20
        )
        async with _served(
            srv, _config(), monkeypatch, fetcher=local, fallbacks=[named]
        ) as (app, _):
            r = await _post(
                app,
                "/api/v1/fetch",
                {"url": "https://example.com/a", "provider": "crawl4ai"},
            )

        assert r.status_code == 200
        assert (local.calls, named.calls) == (0, 1)
        assert r.json()["text"].startswith("Rendered by the named provider.")

    @pytest.mark.parametrize(
        ("location", "expected"),
        [
            # SSRF-via-redirect: the same guardrail one hop later, so the split
            # cannot be by exception class.
            (
                "https://169.254.169.254/latest/meta-data/",
                "Fetch failed - fetch: 169.254.169.254 is not a public address.",
            ),
            (
                "file:///etc/passwd",
                (
                    "Fetch failed - fetch: scheme 'file' is not fetchable; "
                    "only http and https are allowed."
                ),
            ),
        ],
    )
    async def test_a_redirect_refused_after_dispatch_is_a_502(
        self, srv, monkeypatch, location, expected
    ):
        """A guardrail refusal of a redirect *target* is a failed fetch, not a
        refused one.

        Both URL-level checks run again on the target, and by then a request has
        gone out, so the spec's 400 row -- "refuses the URL as written, before
        any network I/O" -- does not cover it and the 502 row does. The real
        fetcher answers one 302; the message is the tool's, unchanged.
        """
        async with _served(srv, _config(), monkeypatch) as (app, _):
            ctx = srv._shared
            assert ctx is not None and ctx.fetch_engine is not None
            fetcher = ctx.fetch_engine.fetcher
            assert isinstance(fetcher, HttpFetcher)
            fetcher._client = httpx.AsyncClient(
                transport=httpx.MockTransport(
                    lambda _request: httpx.Response(
                        302, headers={"location": location}
                    )
                ),
                follow_redirects=False,
            )
            # A public address literal, so hop 0 resolves without DNS and the
            # 302 is actually reached; the refusal lands on the hop after it.
            r = await _post(app, "/api/v1/fetch", {"url": "https://93.184.216.34/"})

        assert r.status_code == 502
        assert r.json()["error"] == expected

    async def test_it_is_not_a_get(self, srv, monkeypatch):
        """`GET /api/v1/fetch?url=...` would put a model-chosen URL into every
        access log and proxy log on the path; the route answers POST only."""
        async with _served(srv, _config(), monkeypatch) as (app, _):
            r = await _get(app, "/api/v1/fetch", url="https://example.com/a")

        assert r.status_code == 405

    @pytest.mark.parametrize(
        "payload",
        [
            {"url": "short"},
            {"url": "https://example.com/a", "offset": -1},
            {"url": "https://example.com/a", "max_results": 5},
            {},
        ],
    )
    async def test_a_body_that_does_not_validate_is_a_400(
        self, srv, monkeypatch, payload
    ):
        async with _served(srv, _config(), monkeypatch) as (app, _):
            r = await _post(app, "/api/v1/fetch", payload)

        assert r.status_code == 400
        assert "Invalid request" in r.json()["error"]


class TestAnswerRoute:
    """`answer` over REST: the tool's plan behind the tool's two models.

    Agent mode is on for these, the way it has to be for the route to serve
    anything, and both upstreams are stubbed -- a stub provider for retrieval
    and `_StubModel` for the endpoint -- so the assertions are about the
    projection rather than about `agent.py`, which `tests/test_agent.py` drives
    against the real plan.
    """

    async def test_it_returns_the_tool_response(self, srv, monkeypatch, agent_key):
        model = _StubModel()
        async with _served(
            srv, _agent_config(), monkeypatch, model=model
        ) as (app, stubs):
            r = await _post(app, "/api/v1/answer", {"query": "why is the sky blue"})

        assert r.status_code == 200
        assert r.headers["content-type"].startswith("application/json")
        body = r.json()
        assert body["query"] == "why is the sky blue"
        assert body["answer"] == "An answer, cited [1]."
        assert body["model"] == "test-model"
        assert body["depth"] == "brief"
        assert body["searches"] == 1
        assert body["fetched"] == 0
        assert body["sources"] == [
            {"title": "t", "url": "https://example.com/a", "provider": "serper"}
        ]
        assert "retrieved_at" in body
        assert stubs["serper"].calls == 1
        assert model.calls == 1

    async def test_a_report_reads_pages_and_counts_them(
        self, srv, monkeypatch, agent_key
    ):
        """Every parameter the body can carry reaches the plan: `depth` widens
        it, `extra_queries` adds a retrieval step, and the counts report both.
        """
        model = _StubModel()
        async with _served(
            srv,
            _agent_config(),
            monkeypatch,
            fetcher=_StubFetcher(),
            model=model,
        ) as (app, _):
            r = await _post(
                app,
                "/api/v1/answer",
                {
                    "query": "why is the sky blue",
                    "extra_queries": ["why is the sky red"],
                    "depth": "report",
                    "provider": "serper",
                    "include_domains": ["example.com"],
                    "exclude_domains": ["other.test"],
                    "recency": "month",
                },
            )

        assert r.status_code == 200
        body = r.json()
        assert body["depth"] == "report"
        # Two queries, each one hit, each page read: `report` is the wider plan.
        assert body["searches"] == 2
        assert body["fetched"] == 2

    async def test_dropped_citations_are_a_200_with_a_notice(
        self, srv, monkeypatch, agent_key
    ):
        """The prose's defect is not the caller's request: 200, plus the notice
        that says which citations were dropped and why `sources` is short."""
        model = _StubModel(content="The moon does it [9].")
        async with _served(
            srv, _agent_config(), monkeypatch, model=model
        ) as (app, _):
            r = await _post(app, "/api/v1/answer", {"query": "why is the sky blue"})

        assert r.status_code == 200
        body = r.json()
        assert body["answer"] == "The moon does it [9]."
        assert body["sources"] == []
        assert "cites 1 index" in body["notice"]
        assert "no citations" in body["notice"]

    async def test_the_prompt_and_the_material_never_reach_the_body(
        self, srv, monkeypatch, agent_key
    ):
        """The system prompt is the server's and the material is not the
        caller's to inspect; the prose must be read against `sources` instead.
        """
        model = _StubModel()
        async with _served(
            srv, _agent_config(), monkeypatch, model=model
        ) as (app, _):
            r = await _post(app, "/api/v1/answer", {"query": "why is the sky blue"})

        assert ANSWER_SYSTEM_PROMPT not in r.text
        # The material's own header and the question turn it is wrapped in: the
        # wire carries what the caller can act on, not what the model was shown.
        assert "untrusted third-party content" not in r.text
        assert "Question:" not in r.text
        assert not {"prompt", "material", "messages"} & set(r.json())

    async def test_cost_usd_never_reaches_the_body(self, srv, monkeypatch, agent_key):
        """The caller is not the party paying -- the `SearchResponse` rule, and
        `WireModel` still sends no nulls."""
        model = _StubModel()
        async with _served(
            srv, _agent_config(), monkeypatch, model=model
        ) as (app, _):
            r = await _post(app, "/api/v1/answer", {"query": "why is the sky blue"})

        assert "cost_usd" not in r.text
        assert "prompt_tokens" not in r.text
        assert "null" not in r.text

    @pytest.mark.parametrize(
        "payload",
        [
            {"query": "x"},
            {"query": "why is the sky blue", "depth": "deep"},
            {"query": "why is the sky blue", "recency": "fortnight"},
            # The tool takes at most two extra queries, each 2-400 characters.
            {"query": "why is the sky blue", "extra_queries": ["a", "b", "c"]},
            {"query": "why is the sky blue", "extra_queries": ["x"]},
            {"query": "why is the sky blue", "include_domains": ["d.test"] * 21},
            # Not a tool parameter, so not a body field: the rule is that the
            # body is the parameter set, and `max_results` is `search`'s.
            {"query": "why is the sky blue", "max_results": 3},
            {},
        ],
    )
    async def test_a_body_that_does_not_validate_is_a_400(
        self, srv, monkeypatch, payload
    ):
        async with _served(srv, _agent_config(), monkeypatch) as (app, _):
            r = await _post(app, "/api/v1/answer", payload)

        assert r.status_code == 400
        assert "Invalid request" in r.json()["error"]

    @pytest.mark.parametrize("raw", ["not json at all", "[1, 2, 3]"])
    async def test_a_body_that_is_not_a_json_object_is_a_400(
        self, srv, monkeypatch, raw
    ):
        async with _served(srv, _agent_config(), monkeypatch) as (app, _):
            r = await _post(app, "/api/v1/answer", raw=raw)

        assert r.status_code == 400
        assert r.json()["error"]

    async def test_a_provider_this_deployment_does_not_serve_is_a_400(
        self, srv, monkeypatch, agent_key
    ):
        """Refused before dispatch, so nothing was billed -- not even a
        retrieval step, and certainly not a model call. The sentence is the one
        the MCP tool hands the model, because it is the same refusal."""
        model = _StubModel()
        async with _served(
            srv, _agent_config(), monkeypatch, model=model
        ) as (app, stubs):
            r = await _post(
                app,
                "/api/v1/answer",
                {"query": "why is the sky blue", "provider": "nope"},
            )

        assert r.status_code == 400
        assert r.json()["error"] == (
            "Provider 'nope' is not enabled on this server. Available: serper. "
            "Retry with one of those, or omit `provider` to use the default."
        )
        assert stubs["serper"].calls == 0
        assert model.calls == 0

    async def test_a_refused_pin_is_logged_like_the_search_routes(
        self, srv, monkeypatch, agent_key, log_records
    ):
        """The operator gets the refusal here too, on the same fields.

        The pre-check goes through the engine's *logging* wrapper -- the call
        `SearchEngine.search` makes -- so this route cannot be the one front
        door that refuses a pin silently. Both routes are driven against one
        listener, because the property is a comparison: one `search.rejected`
        line per request, and the two lines indistinguishable, so the operator
        reads one shape whatever the route. `mode` is `None` for both, the
        `answer` tool having no mode to declare.
        """
        model = _StubModel()
        async with _served(
            srv, _agent_config(), monkeypatch, model=model
        ) as (app, stubs):
            answered = await _post(
                app,
                "/api/v1/answer",
                {"query": "why is the sky blue", "provider": "nope"},
            )
            searched = await _post(
                app,
                "/api/v1/search",
                {"query": "sqlite wal mode", "provider": "nope"},
            )

        sentence = (
            "Provider 'nope' is not enabled on this server. Available: serper. "
            "Retry with one of those, or omit `provider` to use the default."
        )
        assert (answered.status_code, searched.status_code) == (400, 400)
        assert answered.json()["error"] == sentence
        assert searched.json()["error"] == sentence

        rejected = [
            r.record for r in log_records if r.record["message"] == "search.rejected"
        ]
        assert len(rejected) == 2, "one line per request, and no more"
        for record in rejected:
            assert record["level"].name == "WARNING"
            assert record["extra"]["requested"] == "'nope'"
            assert record["extra"]["mode"] is None
            assert record["extra"]["enabled"] == "serper"
        assert rejected[0]["extra"] == rejected[1]["extra"], (
            "a refusal the operator cannot tell apart by route"
        )
        # Refused before dispatch on both routes: no retrieval, no model call.
        assert stubs["serper"].calls == 0
        assert model.calls == 0

    async def test_no_default_and_none_named_is_a_400(
        self, srv, monkeypatch, agent_key
    ):
        cfg = Config(
            providers={"serper": ProviderConfig(), "exa:free": ProviderConfig()},
            agent=AgentConfig(
                enabled=True, base_url="https://model.test/v1", model="test-model"
            ),
        )
        assert cfg.default_provider is None, "two enabled providers: callers choose"
        model = _StubModel()
        async with _served(srv, cfg, monkeypatch, model=model) as (app, stubs):
            r = await _post(app, "/api/v1/answer", {"query": "why is the sky blue"})

        assert r.status_code == 400
        assert "No default provider is configured" in r.json()["error"]
        assert {stub.calls for stub in stubs.values()} == {0}
        assert model.calls == 0

    async def test_a_disabled_agent_mode_is_a_404(self, srv, monkeypatch):
        """`[agent] enabled = false`: the operation is not served here, which is
        the mapping `[fetch] enabled = false` gets -- and the sentence is the
        tool's own, so the two encodings cannot disagree."""
        async with _served(srv, _config(), monkeypatch) as (app, _):
            r = await _post(app, "/api/v1/answer", {"query": "why is the sky blue"})

        assert r.status_code == 404
        assert r.json() == {
            "error": (
                "This server has agent mode disabled; use `search` or `fetch` "
                "instead."
            )
        }

    async def test_a_disabled_agent_mode_refuses_before_the_body(
        self, srv, monkeypatch
    ):
        """\"Not served\" is a fact about the deployment, not about this request
        -- the `[fetch] enabled = false` ordering, which answers 404 to a body
        it never parsed."""
        async with _served(srv, _config(), monkeypatch) as (app, _):
            r = await _post(app, "/api/v1/answer", raw="not json at all")

        assert r.status_code == 404

    async def test_a_retrieval_failure_is_a_502(self, srv, monkeypatch, agent_key):
        """Dispatched and failed upstream, with the message naming the phase the
        call died in: retrieval, here, and the ladder's own wording."""
        stub = _StubProvider(error=ProviderError("serper", "rate limited"))
        model = _StubModel()
        async with _served(
            srv, _agent_config(), monkeypatch, providers={"serper": stub}, model=model
        ) as (app, _):
            r = await _post(app, "/api/v1/answer", {"query": "why is the sky blue"})

        assert r.status_code == 502
        error = r.json()["error"]
        assert error == (
            "Search failed - serper: rate limited. Retry shortly or try a "
            "different phrasing."
        )
        # No material, so no model call: the rule that makes an empty walk cheap.
        assert model.calls == 0

    async def test_a_model_failure_is_a_502(self, srv, monkeypatch, agent_key):
        """The other upstream, and the message says so: the caller has to be
        able to tell a provider that failed from a model that did."""
        model = _StubModel(status=500)
        async with _served(
            srv, _agent_config(), monkeypatch, model=model
        ) as (app, _):
            r = await _post(app, "/api/v1/answer", {"query": "why is the sky blue"})

        assert r.status_code == 502
        assert r.json()["error"] == (
            "The model endpoint (test-model) returned HTTP 500; no answer was "
            "produced."
        )
        assert model.calls == 1


class TestTheListener:
    """All three routes are part of `--http`, behind the `/mcp` guard, and stop
    with it."""

    @pytest.mark.parametrize(
        ("path", "payload"),
        [
            ("/api/v1/search", {"query": "sqlite wal mode"}),
            ("/api/v1/fetch", {"url": "https://example.com/a"}),
            ("/api/v1/answer", {"query": "why is the sky blue"}),
        ],
    )
    async def test_a_host_the_operator_never_allowed_is_refused(
        self, srv, monkeypatch, path, payload
    ):
        """Unlike `/healthz`, these carry data: no exemption from the allowlist.

        Nothing is flipped on the way in: `_guard` reads the allowlist the
        listener was built with, and with no listener here -- the app is built
        directly -- it falls back to the loopback seed, which refuses this Host.
        """
        async with _served(srv, _config(), monkeypatch) as (app, _):
            r = await _post(app, path, payload, headers={"Host": "evil.example"})

        assert r.status_code == 421

    @pytest.mark.parametrize(
        ("path", "payload"),
        [
            ("/api/v1/search", {"query": "sqlite wal mode"}),
            ("/api/v1/fetch", {"url": "https://example.com/a"}),
            ("/api/v1/answer", {"query": "why is the sky blue"}),
        ],
    )
    async def test_a_stopping_process_is_a_503(
        self, srv, monkeypatch, path, payload
    ):
        async with _served(srv, _config(), monkeypatch) as (app, _):
            monkeypatch.setattr(srv, "_shared", None)
            r = await _post(app, path, payload)

        assert r.status_code == 503
        assert r.json() == {"error": "The server is stopping; retry shortly."}

    def test_the_http_path_registers_all_three_routes_as_posts(
        self, srv, monkeypatch
    ):
        """`--http` is the switch: the routes are built with the app, not at import.

        Driven through `_serve_http` itself, with uvicorn faked out, so the
        assertion is about the registration the HTTP path performs rather than
        about a fixture's copy of it.
        """
        import uvicorn

        captured: dict[str, Any] = {}

        class FakeConfig:
            def __init__(self, app, **kw):
                captured["app"] = app

        class FakeServer:
            def __init__(self, _config):
                pass

            async def serve(self):
                return None

        monkeypatch.setattr(uvicorn, "Config", FakeConfig)
        monkeypatch.setattr(uvicorn, "Server", FakeServer)
        monkeypatch.setattr(
            srv,
            "build_providers",
            lambda _config, _client: {"serper": _StubProvider()},
        )

        asyncio.run(srv._serve_http(_config(), "127.0.0.1", 8000, []))

        routes = {
            route.path: route
            for route in captured["app"].routes
            if getattr(route, "path", None)
            in {"/api/v1/search", "/api/v1/fetch", "/api/v1/answer"}
        }
        assert set(routes) == {
            "/api/v1/search",
            "/api/v1/fetch",
            "/api/v1/answer",
        }
        for path, route in routes.items():
            assert route.methods == {"POST"}, path


class _FixedContext:
    """The slice of FastMCP's `Context` the tool bodies read: the app."""

    def __init__(self, app: Any) -> None:
        class _RequestContext:
            lifespan_context = app

        self.request_context = _RequestContext()


class TestTheTwoEncodingsAgree:
    """The contract's rule, tested: one operation, one response model, two ways in.

    "The REST response body is the tool's response model" is only true while it
    is checked, and the check that means something is against the tool itself
    rather than against a second copy of the expected JSON.
    """

    async def test_search_returns_what_the_tool_returns(self, srv, monkeypatch):
        async with _served(srv, _config(), monkeypatch) as (app, _):
            r = await _post(app, "/api/v1/search", {"query": "sqlite wal mode"})
            tool = await srv.search(
                _FixedContext(srv._shared), query="sqlite wal mode"
            )

        assert _comparable(r.json()) == _comparable(tool.model_dump(mode="json"))

    async def test_fetch_returns_what_the_tool_returns(self, srv, monkeypatch):
        async with _served(
            srv, _config(), monkeypatch, fetcher=_StubFetcher()
        ) as (app, _):
            r = await _post(app, "/api/v1/fetch", {"url": "https://example.com/a"})
            tool = await srv.fetch(_FixedContext(srv._shared), "https://example.com/a")

        # The tool spells its MCP result out, because an image rides there as a
        # content block; `structuredContent` is the `FetchResponse` the REST body
        # is built from, and FastMCP validates it against the advertised schema.
        assert _comparable(r.json()) == _comparable(tool.structured_content)

    async def test_an_image_is_bytes_in_the_body_and_a_block_in_the_tool(
        self, srv, monkeypatch
    ):
        """The one place the two encodings carry a body differently, pinned as such.

        The REST body has nowhere for bytes but a string, so it carries them as
        `image.base64`; the MCP result has a content type built for them, so it
        carries them as an image block and leaves the base64 out of the JSON
        projection -- the same picture, once per encoding, never twice per call.
        """
        fetcher = _StubFetcher(image=FetchedImage(media_type="image/png", body=_PNG))
        async with _served(
            srv, _config(allow_images=True), monkeypatch, fetcher=fetcher
        ) as (app, _):
            r = await _post(app, "/api/v1/fetch", {"url": "https://img.test/a.png"})
            tool = await srv.fetch(
                _FixedContext(srv._shared), "https://img.test/a.png"
            )

        assert r.status_code == 200
        body = r.json()
        assert body["content_type"] == "image/png"
        assert body["image"] == {"byte_count": len(_PNG), "base64": _B64_PNG}
        blocks = [c for c in tool.content if c.type == "image"]
        assert len(blocks) == 1
        assert blocks[0].mime_type == "image/png"
        assert blocks[0].data == _B64_PNG
        assert "image" not in (tool.structured_content or {})

    async def test_answer_returns_what_the_tool_returns(
        self, srv, monkeypatch, agent_key
    ):
        """The third operation, checked the same way -- against the tool itself
        rather than against a second copy of the expected JSON."""
        model = _StubModel()
        async with _served(
            srv, _agent_config(), monkeypatch, model=model
        ) as (app, _):
            r = await _post(app, "/api/v1/answer", {"query": "why is the sky blue"})
            tool = await srv.answer(
                _FixedContext(srv._shared), query="why is the sky blue"
            )

        assert _comparable(r.json()) == _comparable(tool.model_dump(mode="json"))


def _comparable(body: dict[str, Any]) -> dict[str, Any]:
    """Drop the one field that is a timestamp rather than a shape."""
    return {k: v for k, v in body.items() if k != "retrieved_at"}


class TestNoDrift:
    """The rule that keeps the two encodings one contract, checked mechanically.

    "The REST request body is the tool's parameter set" is only true while it is
    tested: the tool signature is the source and the request model mirrors it,
    so a parameter added on one side and not the other has to fail here.
    """

    async def test_the_search_body_is_the_search_tool(self, srv):
        tools = {tool.name: tool for tool in await srv.mcp.list_tools()}
        assert set(SearchRequest.model_fields) == set(
            tools["search"].input_schema["properties"]
        )

    async def test_the_fetch_body_is_the_fetch_tool(self, srv):
        tools = {tool.name: tool for tool in await srv.mcp.list_tools()}
        assert set(FetchRequest.model_fields) == set(
            tools["fetch"].input_schema["properties"]
        )

    async def test_the_answer_body_is_the_answer_tool(self, srv):
        tools = {tool.name: tool for tool in await srv.mcp.list_tools()}
        assert set(AnswerRequest.model_fields) == set(
            tools["answer"].input_schema["properties"]
        )

    def test_country_stays_off_the_api_while_language_and_safe_search_are_on_it(self):
        """`SearchQuery` carries all three; only two are tool parameters.

        `country` is exposed by neither encoding -- the model-facing fields name
        language, not geo, and exposing it is its own decision -- so the REST body
        must not carry it. `language` and `safe_search` *are* tool parameters, and the body is
        the tool's parameter set, so both are projected.
        """
        assert {"country", "language", "safe_search"} <= set(SearchQuery.model_fields)
        assert "country" not in SearchRequest.model_fields
        assert {"language", "safe_search"} <= set(SearchRequest.model_fields)

    def test_the_rest_body_bounds_a_language_to_two_letters(self):
        """A regional tag is refused by the body, as it is by the tool schema."""
        with pytest.raises(ValueError):
            SearchRequest.model_validate({"query": "sqlite wal", "language": "de-DE"})


class TestOneMappingPerOperation:
    """The invariant: one field set per operation, and one
    mapping behind it.

    `TestNoDrift` compares the two public surfaces, and cannot see the step
    between a surface and the engine: a parameter carried by the tool schema and
    by the REST body but dropped on the way in still passes it. These tests read
    the field set off every place it has to agree -- the tool's own parameters,
    the MCP schema, and the request model the shared mapping consumes -- and then
    ask the engine what it was handed, once through the tool and once through the
    route, with every parameter populated rather than left at its default.
    """

    @pytest.mark.parametrize(
        ("operation", "model"),
        [
            ("search", SearchRequest),
            ("fetch", FetchRequest),
            ("answer", AnswerRequest),
        ],
    )
    async def test_the_tool_parameters_are_the_body_fields(
        self, srv: Any, operation: str, model: Any
    ) -> None:
        """One field set per operation, read off three places at once.

        The tool signature is what feeds the request model the mapping reads, so
        a parameter that grew on one encoding only fails here rather than
        reaching one encoding and not the other.
        """
        tools = {tool.name: tool for tool in await srv.mcp.list_tools()}
        schema_fields = set(tools[operation].input_schema["properties"])
        signature_fields = set(inspect.signature(getattr(srv, operation)).parameters)
        signature_fields.discard("ctx")
        assert signature_fields == schema_fields == set(model.model_fields)

    async def test_the_search_mapping_is_one_call_both_ways(
        self, srv: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """`provider`/`mode` and every filter reach the engine identically.

        Two parameter sets: one that pins a provider and one that routes by
        free mode, because those two are the fields that do not land in the
        `SearchQuery` and so are the ones a mapping can quietly lose.
        """
        cfg = Config(
            providers={"serper": ProviderConfig(), "exa:free": ProviderConfig()},
            default_provider="serper",
            fetch=FetchConfig(),
        )
        pinned: dict[str, Any] = {
            "query": "sqlite wal mode",
            "provider": "serper",
            "max_results": 7,
            "include_domains": ["arxiv.org"],
            "exclude_domains": ["reddit.com"],
            "recency": "week",
            "language": "de",
            "safe_search": True,
        }
        free_mode: dict[str, Any] = {"query": "sqlite wal mode", "mode": "free"}
        seen: list[tuple[dict[str, Any], dict[str, Any]]] = []

        async with _served(srv, cfg, monkeypatch) as (app, _stubs):
            engine = srv._shared.engine
            real = engine.search

            async def record(query: Any, **route_kw: Any) -> Any:
                seen.append((query.model_dump(), route_kw))
                return await real(query, **route_kw)

            monkeypatch.setattr(engine, "search", record)
            route = await _post(app, "/api/v1/search", pinned)
            await srv.search(_FixedContext(srv._shared), **pinned)
            route_free = await _post(app, "/api/v1/search", free_mode)
            await srv.search(_FixedContext(srv._shared), **free_mode)

        assert (route.status_code, route_free.status_code) == (200, 200)
        assert len(seen) == 4
        assert seen[0] == seen[1]
        assert seen[2] == seen[3]
        assert seen[0][0] == {
            "query": "sqlite wal mode",
            "max_results": 7,
            "include_domains": ["arxiv.org"],
            "exclude_domains": ["reddit.com"],
            "country": None,
            "language": "de",
            "recency": "week",
            "safe_search": True,
        }
        assert seen[0][1] == {"provider": "serper", "mode": None}
        assert seen[2][1] == {"provider": None, "mode": "free"}

    async def test_the_fetch_mapping_is_one_call_both_ways(
        self, srv: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The URL, the paging offset, the narrowing query and the provider, both ways in.

        Five bodies: `offset` and `query` are mutually exclusive at the engine;
        the fourth leaves both out, since `offset`'s default of 0 is the
        mapping's rather than the surface's and has to come out the same whether
        the caller wrote it or not; and the fifth names a provider, which is why
        the served stack carries one built fallback for it to name.
        """
        url = "https://example.com/a"
        bodies: list[dict[str, Any]] = [
            {"url": url, "offset": 120},
            {"url": url, "query": "wal checkpoint"},
            {"url": url, "path": "$.items[0]"},
            {"url": url},
            {"url": url, "provider": "crawl4ai"},
        ]
        seen: list[tuple[str, dict[str, Any]]] = []

        async with _served(
            srv,
            _config(),
            monkeypatch,
            fetcher=_StubFetcher(),
            fallbacks=[_StubFetcher(name="crawl4ai")],
        ) as (app, _stubs):
            engine = srv._shared.fetch_engine
            assert engine is not None
            real = engine.fetch

            async def record(rec_url: str, **fetch_kw: Any) -> Any:
                seen.append((rec_url, fetch_kw))
                return await real(rec_url, **fetch_kw)

            monkeypatch.setattr(engine, "fetch", record)
            for body in bodies:
                route = await _post(app, "/api/v1/fetch", body)
                assert route.status_code == 200, body
                await srv.fetch(_FixedContext(srv._shared), **body)

        assert len(seen) == 10
        assert seen[0] == seen[1] == (
            url,
            {"offset": 120, "query": None, "path": None, "provider": None},
        )
        assert seen[2] == seen[3] == (
            url,
            {"offset": 0, "query": "wal checkpoint", "path": None, "provider": None},
        )
        assert seen[4] == seen[5] == (
            url,
            {"offset": 0, "query": None, "path": "$.items[0]", "provider": None},
        )
        assert seen[6] == seen[7] == (
            url,
            {"offset": 0, "query": None, "path": None, "provider": None},
        )
        assert seen[8] == seen[9] == (
            url,
            {"offset": 0, "query": None, "path": None, "provider": "crawl4ai"},
        )

    async def test_the_answer_mapping_is_one_call_both_ways(
        self, srv: Any, monkeypatch: pytest.MonkeyPatch, agent_key: None
    ) -> None:
        """All nine parameters, both ways in, and none of them dropped on the way.

        `depth` arrives as the caller wrote it rather than as `"brief"`: the plan
        owns that default, which is why the body allows the null.
        """
        params: dict[str, Any] = {
            "query": "why is the sky blue",
            "extra_queries": ["rayleigh scattering"],
            "depth": "brief",
            "provider": "serper",
            "include_domains": ["arxiv.org"],
            "exclude_domains": ["reddit.com"],
            "recency": "month",
            "language": "fr",
            "safe_search": False,
        }
        seen: list[dict[str, Any]] = []

        async with _served(
            srv, _agent_config(), monkeypatch, model=_StubModel()
        ) as (app, _stubs):
            engine = srv._shared.agent_engine
            assert engine is not None
            real = engine.answer

            async def record(**plan_kw: Any) -> Any:
                seen.append(dict(plan_kw))
                return await real(**plan_kw)

            monkeypatch.setattr(engine, "answer", record)
            route = await _post(app, "/api/v1/answer", params)
            await srv.answer(_FixedContext(srv._shared), **params)

        assert route.status_code == 200
        assert len(seen) == 2
        assert seen[0] == seen[1]
        assert set(seen[0]) == set(AnswerRequest.model_fields)
        assert seen[0]["depth"] == "brief"
