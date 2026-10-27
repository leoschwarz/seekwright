"""Tool surface and session-lifetime regressions.

Verifies the shapes MCP clients depend on, and guards the cancel-scope bug that
only appears across multiple requests (see ``ExaMcpProvider._own_session``).
"""

import asyncio
import base64
import contextlib
import json
import logging as stdlib_logging
import re
from datetime import UTC, datetime
from typing import Any, NoReturn, cast

import httpx
import pytest
from mcp import ClientSession
from mcp.shared.memory import create_connected_server_and_client_session
from mcp.types import ImageContent, TextContent

from seekwright import server as server_module
from seekwright.fetcher import FetchedImage, FetchedPage
from seekwright.models import (
    FetchResponse,
    ProviderResult,
    Result,
    SearchQuery,
)
from seekwright.providers.base import ProviderError
from seekwright.providers.exa_mcp import ExaMcpProvider
from seekwright.usage import UsageRecorder


@pytest.fixture
def server(monkeypatch, tmp_path):
    cfg = tmp_path / "config.toml"
    cfg.write_text("[providers.serper]\nenabled = true\n")
    monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(cfg))
    from seekwright.server import mcp

    return mcp


class TestToolSurface:
    async def test_exactly_three_tools(self, server):
        """`search`, `fetch`, and agent mode's `answer`.

        The third is registered on every deployment, including this one with
        `[agent]` left off: a tool schema is frozen at import, so the choice is
        between advertising it and refusing the call cleanly, or a deployment
        whose surface depends on config it cannot read (the `[fetch] enabled =
        false` precedent).
        """
        names = [t.name for t in await server.list_tools()]
        assert names == ["search", "fetch", "answer"]

    async def test_schemas_are_object_rooted(self, server):
        """The 2025-11-25 spec restricts both schemas to `type: object` at root."""
        for tool in await server.list_tools():
            assert tool.inputSchema["type"] == "object"
            assert tool.outputSchema is not None
            assert tool.outputSchema["type"] == "object"

    async def test_search_requires_a_query(self, server):
        search = next(t for t in await server.list_tools() if t.name == "search")
        assert search.inputSchema["required"] == ["query"]

    async def test_fetch_requires_a_url(self, server):
        tool = next(t for t in await server.list_tools() if t.name == "fetch")
        assert tool.inputSchema["required"] == ["url"]

    async def test_fetch_omits_search_params(self, server):
        """Fetch takes a URL, not a *search* -- no domain filters, no free mode.

        `query` used to be in this absent list, until it became the fetch tool's
        own parameter: passage targeting, not a web search. The two never
        interact -- fetch's `query` matches text already extracted. `provider`
        left this list the same way when fetch gained one of its own: it names a
        fetch provider, and the test after this one
        pins what that parameter looks like.
        """
        tool = next(t for t in await server.list_tools() if t.name == "fetch")
        props = tool.inputSchema["properties"]
        assert "url" in props
        for absent in ("max_results", "include_domains", "mode", "recency"):
            assert absent not in props

    async def test_fetch_paging_and_targeting_params(self, server):
        """`offset` and `query` are optional, and neither replaces the other."""
        tool = next(t for t in await server.list_tools() if t.name == "fetch")
        props = tool.inputSchema["properties"]
        assert tool.inputSchema["required"] == ["url"]

        offset = props["offset"]
        assert offset["default"] is None
        assert "integer" in str(offset)
        assert "0" in str(offset), "a negative offset is not a window"

        query = props["query"]
        assert query["default"] is None
        assert "string" in str(query)
        assert "truncated" in tool.description
        assert "passages" in tool.description

    async def test_fetch_provider_is_free_text_not_a_vocabulary(self, server):
        """`fetch` has a `provider`, and the schema cannot enumerate its names.

        Which fetch providers a deployment runs is config, a key, a URL and the
        permission set, and this schema is built at import -- so a `Literal` of
        the registry would freeze a set that grows by a registry row and answer
        an unbuilt name with a schema error instead of the sentence naming what
        this server *can* serve. That refusal belongs to `FetchEngine.resolve`,
        and it fires at call time.
        """
        tool = next(t for t in await server.list_tools() if t.name == "fetch")
        prop = tool.inputSchema["properties"]["provider"]
        assert prop["default"] is None
        assert "enum" not in str(prop)

    async def test_no_cache_params_survive(self, server):
        """Nothing in the surface promises caching this version does not do."""
        for tool in await server.list_tools():
            props = tool.inputSchema["properties"]
            assert "max_age_seconds" not in props
            assert "refresh_token" not in props

    async def test_provider_is_selectable_on_search(self, server):
        """The schema lists every adapter, not the subset this config enabled.

        It is built once at import time, so the enabled set can only be reported
        in an error at call time.
        """
        search = next(t for t in await server.list_tools() if t.name == "search")
        prop = search.inputSchema["properties"]["provider"]
        assert prop["default"] is None
        assert "scrappa" in str(prop)

    @pytest.mark.parametrize("tool_name", ["search", "answer"])
    async def test_provider_schema_lists_all_seventeen_names(self, server, tool_name):
        """Fifteen backends across seventeen names; Exa and Parallel each twice.

        A name missing here is a wiring point somebody skipped -- the schema is
        frozen at import, so the tool would refuse a provider that exists. Both
        copies carry the same list, and the allow-list narrows neither: a config
        value cannot reach a schema at all, which is why the refusal is the
        surface and this guard stays over all seventeen.
        """
        from seekwright.config import KNOWN_PROVIDERS

        tool = next(t for t in await server.list_tools() if t.name == tool_name)
        names = tool.inputSchema["properties"]["provider"]["anyOf"][0]["enum"]
        assert sorted(names) == [
            "algolia",
            "anysearch",
            "deepseek",
            "exa",
            "exa:free",
            "freeserp",
            "linkup",
            "parallel",
            "parallel:free",
            "querit",
            "scrappa",
            "search1api",
            "searxng",
            "serpapi",
            "serper",
            "tavily",
            "tinyfish",
        ]
        assert set(names) == set(KNOWN_PROVIDERS), "the schema and the registry agree"

    async def test_recency_is_the_four_value_enum(self, server):
        search = next(t for t in await server.list_tools() if t.name == "search")
        prop = search.inputSchema["properties"]["recency"]
        assert prop["default"] is None
        values = prop["anyOf"][0]["enum"]
        assert sorted(values) == ["day", "month", "week", "year"]

    async def test_mode_is_a_literal_of_constants(self, server):
        """One constant, and nothing read from config.

        The schema is built once at import and its annotations are `eval`'d
        against module globals, so a value derived from a config object would
        raise `NameError` before the server ever started -- the same reason
        `provider` lists every adapter rather than this deployment's set.
        `"task"` is the reserved second member and is deliberately absent
        (ROADMAP §6).
        """
        search = next(t for t in await server.list_tools() if t.name == "search")
        prop = search.inputSchema["properties"]["mode"]
        assert prop["default"] is None
        # A one-member `Literal` renders as `const`; more members would render
        # as an `enum`. Either way the only value in the schema is a constant.
        allowed = prop["anyOf"][0].get("enum") or [prop["anyOf"][0]["const"]]
        assert allowed == ["free"]

    async def test_annotations_mark_both_tools_read_only(self, server):
        for tool in await server.list_tools():
            assert tool.annotations.readOnlyHint is True
            assert tool.annotations.openWorldHint is True


_PNG_BODY = b"\x89PNG\r\n\x1a\n" + b"a png body"


class _StubLocalFetcher:
    """The local fetcher replaced by one that answers with an image, or with text."""

    name = "fetch"
    cost_per_1k: float | None = None

    def __init__(self, *, image: FetchedImage | None = None) -> None:
        self._image = image

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        if self._image is None:
            text = "The page body. " * 20
            return FetchedPage(
                url=url,
                title="A Page",
                text=text,
                content_type="text/html",
                status_code=200,
                truncated=False,
                total_chars=len(text),
            )
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

    async def aclose(self) -> None:
        return None


class TestFetchImageContent:
    """An MCP tool result can carry an image, and this is the wire proof.

    A real client session against the real server, with only the fetch stack
    stubbed. Two halves matter: the content a client is actually handed, and the
    schema advertised by `list_tools` -- the half a `CallToolResult` return would
    have silently dropped, since the tool no longer returns a model.
    """

    async def test_the_admitted_output_schema_is_still_the_response_model(
        self, server
    ):
        tool = next(t for t in await server.list_tools() if t.name == "fetch")
        assert tool.outputSchema is not None
        assert set(tool.outputSchema["properties"]) == set(FetchResponse.model_fields)

    async def test_an_image_arrives_as_an_image_block(self, server, monkeypatch):
        fetcher = _StubLocalFetcher(
            image=FetchedImage(media_type="image/png", body=_PNG_BODY)
        )

        async def stack(_config):
            return fetcher, []

        monkeypatch.setattr(server_module, "build_fetch_stack", stack)
        async with create_connected_server_and_client_session(server) as session:
            result = await session.call_tool("fetch", {"url": "https://img.test/a.png"})

        assert not result.isError
        assert [block.type for block in result.content] == ["text", "image"]
        image = next(b for b in result.content if b.type == "image")
        assert isinstance(image, ImageContent)
        assert image.mimeType == "image/png"
        assert base64.b64decode(image.data) == _PNG_BODY
        structured = result.structuredContent
        assert structured is not None
        assert structured["content_type"] == "image/png"
        # The bytes ride once: the content block carries them, and the JSON half
        # a caller reads stays the document it always was, minus that field.
        assert "image" not in structured
        text = next(b for b in result.content if b.type == "text")
        assert isinstance(text, TextContent)
        assert json.loads(text.text) == structured

    async def test_a_text_page_keeps_the_result_shape_it_always_had(
        self, server, monkeypatch
    ):
        async def stack(_config):
            return _StubLocalFetcher(), []

        monkeypatch.setattr(server_module, "build_fetch_stack", stack)
        async with create_connected_server_and_client_session(server) as session:
            result = await session.call_tool("fetch", {"url": "https://example.com/a"})

        assert not result.isError
        assert [block.type for block in result.content] == ["text"]
        assert result.structuredContent is not None
        text = result.content[0]
        assert isinstance(text, TextContent)
        assert json.loads(text.text) == result.structuredContent


class TestSharedContext:
    """`lifespan` runs per `Server.run()`, which under HTTP is per request.

    The whole HTTP design rests on the process building its context once and
    `lifespan` handing out that reference. Rebuilding it would open a connection
    pool and re-handshake every MCP-client provider on every search -- correct,
    invisible in a unit test of one call, and expensive per call thereafter.
    """

    async def test_lifespan_reuses_the_process_context(self, server, monkeypatch):
        import seekwright.server as srv

        built = 0

        @contextlib.asynccontextmanager
        async def counting_build(config):
            nonlocal built
            built += 1
            yield cast(srv.AppContext, object())

        monkeypatch.setattr(srv, "build_app_context", counting_build)

        async with counting_build(None) as shared:
            monkeypatch.setattr(srv, "_shared", shared)
            built = 0
            async with srv.lifespan(server) as a, srv.lifespan(server) as b:
                assert a is shared and b is shared
        assert built == 0, "the HTTP path must not rebuild the context per request"

    async def test_lifespan_builds_its_own_when_unshared(self, server, monkeypatch):
        """Under stdio there is one `Server.run`, so lifespan still owns it."""
        import seekwright.server as srv

        built = 0

        @contextlib.asynccontextmanager
        async def counting_build(config):
            nonlocal built
            built += 1
            yield cast(srv.AppContext, object())

        monkeypatch.setattr(srv, "build_app_context", counting_build)
        monkeypatch.setattr(srv, "_shared", None)

        async with srv.lifespan(server):
            pass
        assert built == 1

    @staticmethod
    def _monitor_tasks() -> list[asyncio.Task[None]]:
        return [t for t in asyncio.all_tasks() if t.get_name() == "health-monitor"]

    async def test_the_health_monitor_lives_and_dies_with_the_context(self):
        """One monitor per process, cancelled with the context: a leaked one
        would keep probing -- and spending -- after shutdown."""
        import seekwright.server as srv
        from seekwright.config import Config, ProviderConfig, SearchConfig

        cfg = Config(
            providers={"searxng": ProviderConfig(url="http://searx.test:8080")},
            search=SearchConfig(health_interval_seconds=0.05),
        )

        async with srv.build_app_context(cfg):
            (task,) = self._monitor_tasks()

        assert task.done()
        assert self._monitor_tasks() == []

    async def test_a_zero_interval_starts_no_monitor(self):
        """`health_interval_seconds = 0.0` is the documented off switch; the
        passive breaker keeps working without the ping task."""
        import seekwright.server as srv
        from seekwright.config import Config, ProviderConfig, SearchConfig

        cfg = Config(
            providers={"searxng": ProviderConfig(url="http://searx.test:8080")},
            search=SearchConfig(health_interval_seconds=0.0),
        )

        async with srv.build_app_context(cfg):
            assert self._monitor_tasks() == []

    async def test_a_failing_fetch_stack_leaves_no_monitor_running(self, monkeypatch):
        """The documented failure: an enabled `fetch` whose extraction-backend
        library is not installed.

        `build_fetch_stack` builds the extractor, so `ExtractorUnavailable`
        surfaces *inside* `build_app_context` -- and used to surface after the
        monitor task was created but above the `finally` that cancels it. The
        task then outlived the context, still probing through the httpx client
        the enclosing `async with` was closing, and asyncio reported it at loop
        teardown as "Task was destroyed but it is pending!".

        Asserting the task's absence is the checkable form of that warning: a
        task that is not left pending cannot be destroyed pending. The loop
        handler is the second shape of the same leak -- a task that *raised*
        with nobody left to retrieve it -- and must stay untouched too.
        """
        import seekwright.server as srv
        from seekwright import factory
        from seekwright.config import (
            Config,
            FetchConfig,
            ProviderConfig,
            SearchConfig,
        )

        def unavailable(_cfg):
            raise factory.ExtractorUnavailable(
                "the 'trafilatura' extra is not installed"
            )

        # Patched in `factory`, not in `server`: that is the module that resolves
        # the name.
        monkeypatch.setattr(factory, "build_extractor", unavailable)

        cfg = Config(
            providers={"searxng": ProviderConfig(url="http://searx.test:8080")},
            # A live interval, so the unfixed code really does create a task to
            # leak rather than skipping it.
            search=SearchConfig(health_interval_seconds=0.05),
            fetch=FetchConfig(enabled=True),
        )

        loop = asyncio.get_running_loop()
        unhandled: list[dict[str, Any]] = []
        previous = loop.get_exception_handler()
        loop.set_exception_handler(lambda _loop, ctx: unhandled.append(ctx))
        try:
            with pytest.raises(factory.ExtractorUnavailable):
                async with srv.build_app_context(cfg):
                    pytest.fail("a failed fetch stack must not yield a context")

            # Give a leaked task the turns it needs to run and, if it is going
            # to, fail.
            for _ in range(3):
                await asyncio.sleep(0)
        finally:
            loop.set_exception_handler(previous)

        assert self._monitor_tasks() == []
        assert unhandled == [], f"a leaked task reported {unhandled!r}"

    async def test_an_unwritable_journal_refuses_to_start(self, tmp_path, monkeypatch):
        """An unwritable `dashboard.history_path` refuses the same way a
        missing parent does: `SystemExit` before anything else is built, not
        a green boot whose first append turns the dashboard badge red.
        """
        from pathlib import Path

        import seekwright.server as srv
        from seekwright.config import Config, DashboardConfig, ProviderConfig

        journal = tmp_path / "usage.jsonl"
        journal.touch()

        def boom(*_args: object, **_kwargs: object) -> None:
            raise PermissionError(13, "Permission denied", str(journal))

        monkeypatch.setattr(Path, "open", boom)
        cfg = Config(
            providers={"serper": ProviderConfig()},
            dashboard=DashboardConfig(history_path=str(journal)),
        )

        with pytest.raises(SystemExit) as exc:
            async with srv.build_app_context(cfg):
                pytest.fail("an unwritable journal must not yield a context")

        assert str(exc.value.code).startswith("seekwright: dashboard.history_path:")
        assert "not writable" in str(exc.value.code)

    async def test_a_raising_fallback_constructor_closes_the_stack_it_leaves_behind(
        self, monkeypatch
    ):
        """A fallback constructor that raises must not strand the clients built
        before it.

        `build_fetch_stack` builds `HttpFetcher` first and appends the ladder
        fallbacks after it, and every fetcher owns its **own** `httpx.AsyncClient`
        -- deliberately not the shared one, which carries provider API keys. A
        fallback constructor raising therefore leaves a fully built fetcher, and
        every fallback before it, owned by nobody: the enclosing `async with` in
        `build_app_context` closes a *different* client, its `finally` sits
        below the raise and never runs at all, and the caller cannot close a
        stack the builder never returned. Closing the partial stack is
        therefore the builder's own job, which is what this asserts.

        Two fallbacks, so the raise lands with both a fetcher and a fallback already
        built; each carries a client of its own.
        """
        import seekwright.server as srv
        from seekwright import factory
        from seekwright.config import Config, FetchConfig, ProviderConfig
        from seekwright.fetcher import Crawl4aiFetcher, HttpFetcher

        class FallbackBlewUp(Exception):
            """Whatever reason a fallback constructor has for failing."""

        def exploding_scrappa(*_args: Any, **_kwargs: Any) -> NoReturn:
            raise FallbackBlewUp("the scrappa fallback could not be built")

        built: list[HttpFetcher | Crawl4aiFetcher] = []

        def recording_http(*args: Any, **kwargs: Any) -> HttpFetcher:
            fetcher = HttpFetcher(*args, **kwargs)
            built.append(fetcher)
            return fetcher

        def recording_crawl4ai(*args: Any, **kwargs: Any) -> Crawl4aiFetcher:
            fallback = Crawl4aiFetcher(*args, **kwargs)
            built.append(fallback)
            return fallback

        # Patched in `factory` for the local fetcher and in `fetcher` for the fallbacks:
        # each builder resolves the class it names from its own module's globals.
        monkeypatch.setattr(factory, "HttpFetcher", recording_http)
        monkeypatch.setattr("seekwright.fetcher.Crawl4aiFetcher", recording_crawl4ai)
        monkeypatch.setattr("seekwright.fetcher.ScrappaFetcher", exploding_scrappa)
        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")

        cfg = Config(
            providers={"searxng": ProviderConfig(url="http://searx.test:8080")},
            fetch=FetchConfig(
                enabled=True,
                fallback=["crawl4ai", "scrappa"],
                crawl4ai_url="http://int-crawl4ai:11235",
            ),
        )

        with pytest.raises(FallbackBlewUp):
            async with srv.build_app_context(cfg):
                pytest.fail("a failed fetch stack must not yield a context")

        assert len(built) == 2, "the fetcher and the first fallback must be built"
        assert built[0]._client.is_closed, "the fetcher's own client leaked"
        assert built[1]._client.is_closed, "the first fallback's own client leaked"


class TestFetchLadderWiring:
    """The configured ladder becomes engine fallbacks, each only when it can run.

    A fallback missing its prerequisite -- crawl4ai without a URL, Scrappa without
    an API key -- stays silently absent rather than failing every fetch that
    reaches for it; `--check` is where that is reported.
    """

    @staticmethod
    def _config(**fetch_kw):
        from seekwright.config import Config, FetchConfig, ProviderConfig

        return Config(
            providers={"scrappa": ProviderConfig()},
            fetch=FetchConfig(**fetch_kw),
        )

    async def _built_fallback_names(self, monkeypatch, **fetch_kw):
        import seekwright.server as srv

        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")
        async with srv.build_app_context(self._config(**fetch_kw)) as ctx:
            assert ctx.fetch_engine is not None
            return ctx.fetch_engine.fallbacks

    async def test_the_ladder_is_built_in_config_order(self, monkeypatch):
        from seekwright.fetcher import Crawl4aiFetcher, ScrappaFetcher

        fallbacks = await self._built_fallback_names(
            monkeypatch,
            fallback=["crawl4ai", "scrappa"],
            crawl4ai_url="http://int-crawl4ai:11235",
            crawl4ai_token="t",
        )

        assert [fallback.name for fallback in fallbacks] == ["crawl4ai", "scrappa"]
        assert isinstance(fallbacks[0], Crawl4aiFetcher)
        assert isinstance(fallbacks[1], ScrappaFetcher)
        # The token and the renderer's own timeout reach the adapter.
        assert fallbacks[0]._token == "t"

    async def test_crawl4ai_without_a_url_stays_absent(self, monkeypatch):
        fallbacks = await self._built_fallback_names(
            monkeypatch, fallback=["crawl4ai", "scrappa"]
        )

        assert [fallback.name for fallback in fallbacks] == ["scrappa"]

    async def test_scrappa_without_a_key_stays_absent(self, monkeypatch):
        from seekwright.fetcher import Crawl4aiFetcher

        monkeypatch.delenv("SEEKWRIGHT_SCRAPPA_API_KEY", raising=False)
        import seekwright.server as srv

        async with srv.build_app_context(
            self._config(
                fallback=["crawl4ai", "scrappa"],
                crawl4ai_url="http://int-crawl4ai:11235",
            )
        ) as ctx:
            assert ctx.fetch_engine is not None
            fallbacks = ctx.fetch_engine.fallbacks

        assert [fallback.name for fallback in fallbacks] == ["crawl4ai"]
        assert isinstance(fallbacks[0], Crawl4aiFetcher)

    async def test_an_empty_ladder_is_an_empty_list(self, monkeypatch):
        fallbacks = await self._built_fallback_names(monkeypatch)

        assert fallbacks == []


class TestMainMissingProviderKey:
    """A keyed provider whose key never arrived refuses to start, naming the
    variable an operator has to export.

    Same shape as the missing extraction backend below, and in the same place
    for the same reason: stdio should show the sentence rather than an
    ExceptionGroup traceback. The variable is the *backend's* -- a key names the
    account, a flavour names the route through it -- so the first keyed flavour
    cannot print `SEEKWRIGHT_FOO:BAR_API_KEY`, a name no shell can export. What
    it prints instead is the backend's own variable.
    """

    def test_a_flavoured_names_key_names_the_backend(self, monkeypatch):
        import seekwright.config as cfg
        import seekwright.server as srv

        # Both flavoured names ship anonymous, so no keyed flavour exists to
        # configure; widening the set is what exercises the message with one.
        monkeypatch.setattr(cfg, "PROVIDERS_REQUIRING_KEY", frozenset({"exa:free"}))
        monkeypatch.delenv("SEEKWRIGHT_EXA_API_KEY", raising=False)
        monkeypatch.setattr(
            srv,
            "load_config",
            lambda: cfg.Config(providers={"exa:free": cfg.ProviderConfig()}),
        )
        monkeypatch.setattr(srv.mcp, "run", lambda **_kw: pytest.fail("ran anyway"))

        with pytest.raises(SystemExit) as excinfo:
            srv.main()

        message = str(excinfo.value)
        assert "SEEKWRIGHT_EXA_API_KEY" in message
        assert "SEEKWRIGHT_EXA:FREE_API_KEY" not in message


class TestMainFetchExtractor:
    """An enabled `fetch` whose extraction backend is missing refuses to start.

    Same shape as a provider without its key, and for the same reason: the
    deployment would otherwise advertise a tool that fails on every call, with
    the reason visible only through the model. Placed before `mcp.run`, so
    stdio shows the sentence rather than an ExceptionGroup traceback.
    """

    @staticmethod
    def _config(**fetch_kw):
        from seekwright.config import Config, FetchConfig, ProviderConfig

        return Config(
            providers={"searxng": ProviderConfig(url="http://searx.test:8080")},
            fetch=FetchConfig(**fetch_kw),
        )

    def test_a_missing_backend_library_refuses_to_start(self, monkeypatch):
        import seekwright.server as srv
        from seekwright.factory import ExtractorUnavailable

        def unavailable(_cfg):
            raise ExtractorUnavailable("the 'trafilatura' extra is not installed")

        monkeypatch.setattr(srv, "load_config", self._config)
        monkeypatch.setattr(srv, "build_extractor", unavailable)
        monkeypatch.setattr(srv.mcp, "run", lambda **_kw: pytest.fail("ran anyway"))

        with pytest.raises(SystemExit, match="trafilatura"):
            srv.main()

    def test_a_disabled_fetch_skips_the_pre_flight(self, monkeypatch):
        """`fetch.enabled = false` means the backend is never going to be used,
        so a missing library must not stop the server that still serves search."""
        import seekwright.server as srv

        monkeypatch.setattr(srv, "load_config", lambda: self._config(enabled=False))

        def unavailable(_cfg):
            pytest.fail("a disabled fetch must not be pre-flighted")

        def sentinel(**_kw):
            raise RuntimeError("reached mcp.run")

        monkeypatch.setattr(srv, "build_extractor", unavailable)
        monkeypatch.setattr(srv.mcp, "run", sentinel)

        with pytest.raises(RuntimeError, match="reached mcp.run"):
            srv.main()


class TestAllowedHosts:
    """DNS-rebinding protection defaults to loopback-only and stays on."""

    def test_declared_hosts_are_added_not_substituted(self, monkeypatch):
        import seekwright.server as srv

        security = srv.mcp.settings.transport_security
        assert security is not None
        monkeypatch.setattr(
            security, "allowed_hosts", list(security.allowed_hosts), raising=False
        )
        monkeypatch.setattr(
            security, "allowed_origins", list(security.allowed_origins), raising=False
        )
        before = list(security.allowed_hosts)
        assert any("127.0.0.1" in h for h in before)

        srv._allow_hosts(["search.internal:*"])

        assert security.allowed_hosts == [*before, "search.internal:*"]
        assert "http://search.internal:*" in security.allowed_origins
        assert "https://search.internal:*" in security.allowed_origins
        assert security.enable_dns_rebinding_protection is True

    def test_no_declared_hosts_changes_nothing(self, monkeypatch):
        import seekwright.server as srv

        security = srv.mcp.settings.transport_security
        assert security is not None
        monkeypatch.setattr(
            security, "allowed_hosts", list(security.allowed_hosts), raising=False
        )
        before = list(security.allowed_hosts)
        srv._allow_hosts([])
        assert security.allowed_hosts == before


class TestExaSessionLifetime:
    """Regression guard for the anyio cancel-scope crash.

    The transport's context managers bind cancel scopes to the entering task. If
    request A enters the session and request B exits it, anyio raises "attempted
    to exit a cancel scope that isn't the current task's" and the server dies --
    which only shows up on the *second* call, so unit-testing one call misses it.
    """

    async def test_session_is_entered_and_exited_by_one_task(self, monkeypatch):
        entered: list[str] = []
        provider = ExaMcpProvider(url="http://stub.invalid/mcp")

        async def fake_own_session():
            task = asyncio.current_task()
            assert task is not None
            entered.append(task.get_name())
            assert provider._ready is not None
            assert provider._shutdown is not None
            # Only identity matters here, not the type: the owner task must
            # publish *a* session object and clear it on shutdown.
            provider._session = cast(ClientSession, object())
            provider._ready.set_result(provider._session)
            await provider._shutdown.wait()
            provider._session = None

        monkeypatch.setattr(provider, "_own_session", fake_own_session)

        # Two "requests" from different tasks share one owner task.
        s1 = await asyncio.create_task(provider._ensure_session())
        s2 = await asyncio.create_task(provider._ensure_session())
        assert s1 is s2
        assert len(entered) == 1, "session must be created once, not per request"

        owner = provider._owner
        assert owner is not None
        await provider._reset()
        assert owner.done(), "reset must let the owner task finish cleanly"
        assert provider._session is None

    async def test_reset_is_safe_when_never_connected(self):
        await ExaMcpProvider(url="http://stub.invalid/mcp")._reset()

    async def test_warmup_failure_is_not_fatal(self):
        """A cold upstream must not prevent the server from starting."""
        provider = ExaMcpProvider(url="http://127.0.0.1:1/mcp", timeout=2.0)
        assert await provider.warmup() is False
        await provider.aclose()

    async def test_handshake_timeout_takes_the_owner_down_with_it(self, monkeypatch):
        """A hanging handshake must not leave its owner task behind.

        The stale owner keeps its client open and, once the next call reassigns
        `_ready`/`_shutdown`, can no longer be signalled -- a late handshake
        completion would then land on the *new* future and clobber the newer
        session.
        """
        provider = ExaMcpProvider(url="http://stub.invalid/mcp", timeout=0.05)
        started: list[asyncio.Task[None]] = []

        async def hanging_own_session() -> None:
            task = asyncio.current_task()
            assert task is not None
            started.append(task)
            # The handshake never completes; the owner would only wake long
            # after the caller gave up.
            await asyncio.sleep(30)

        monkeypatch.setattr(provider, "_own_session", hanging_own_session)

        with pytest.raises(ProviderError, match="handshake timed out"):
            await provider._ensure_session()

        assert started, "the owner task must have been started"
        assert all(t.done() and t.cancelled() for t in started), (
            "the timed-out handshake's owner must be cancelled, not leaked"
        )
        assert provider._owner is None
        assert provider._session is None
        assert provider._ready is None
        assert provider._shutdown is None

        # A follow-up call builds fresh state and can succeed without the dead
        # owner interfering.
        async def good_own_session() -> None:
            session = cast(ClientSession, object())
            provider._session = session
            assert provider._ready is not None
            assert provider._shutdown is not None
            if not provider._ready.done():
                provider._ready.set_result(session)
            await provider._shutdown.wait()

        monkeypatch.setattr(provider, "_own_session", good_own_session)
        session = await asyncio.wait_for(provider._ensure_session(), timeout=2.0)
        assert session is provider._session
        await provider.aclose()


class TestHealthz:
    """The probe endpoint, and the two properties that make it usable.

    It has to answer a kubelet that sends the pod IP as `Host`, and it has to
    give away nothing while doing so -- the listener has no authentication.
    """

    @pytest.fixture
    def app(self, server, monkeypatch):
        import seekwright.server as srv
        from seekwright.config import Config, ProviderConfig

        cfg = Config(
            providers={"serper": ProviderConfig(), "exa:free": ProviderConfig()},
            default_provider="serper",
        )
        # A real AppContext with null engines: `healthz` reads only `config`.
        monkeypatch.setattr(
            srv,
            "_shared",
            srv.AppContext(
                config=cfg,
                engine=cast(Any, None),
                usage=UsageRecorder(),
                fetch_engine=cast(Any, None),
            ),
        )
        monkeypatch.setattr(srv, "_started_at", None)
        srv.mcp.custom_route("/healthz", methods=["GET"])(srv.healthz)
        return srv.mcp.streamable_http_app()

    async def _get(self, app, headers=None):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://testserver"
        ) as client:
            return await client.get("/healthz", headers=headers or {})

    async def test_it_reports_ok_with_the_enabled_providers(self, app):
        r = await self._get(app)

        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "ok"
        assert body["providers"] == ["exa:free", "serper"]
        assert body["default_provider"] == "serper"
        assert isinstance(body["uptime_s"], int)

    async def test_an_unknown_host_header_still_gets_through(self, app):
        """The property that makes it work as a Kubernetes probe.

        A kubelet sends the pod IP in `Host`, which changes per pod and so can
        never be listed in `--allowed-host`. DNS-rebinding protection lives
        inside the streamable-HTTP transport rather than as ASGI middleware, so
        a `custom_route` sits outside it. If this ever starts returning 421,
        every probe in the cluster is failing.
        """
        r = await self._get(app, headers={"Host": "10.42.0.7:8000"})
        assert r.status_code == 200

    async def test_the_same_host_is_still_refused_on_the_mcp_route(self, app):
        """The other half: the bypass is scoped to `/healthz`, not general.

        Driven through the app's lifespan because `/mcp` needs the session
        manager's task group -- which is also the point, since that manager is
        where the Host check lives.
        """
        import seekwright.server as srv

        security = srv.mcp.settings.transport_security
        assert security is not None
        security.enable_dns_rebinding_protection = True
        transport = httpx.ASGITransport(app=app)
        async with app.router.lifespan_context(app), httpx.AsyncClient(
            transport=transport, base_url="http://testserver"
        ) as client:
            mcp_response = await client.post(
                "/mcp",
                # Content-Type and Accept are validated before Host, so both are
                # needed to reach the check.
                headers={
                    "Host": "10.42.0.7:8000",
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream",
                },
                json={"jsonrpc": "2.0", "id": 1, "method": "ping"},
            )
            health = await client.get(
                "/healthz", headers={"Host": "10.42.0.7:8000"}
            )

        assert mcp_response.status_code == 421
        assert health.status_code == 200

    async def test_it_leaks_nothing_beyond_the_provider_names(self, app, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_SERPER_API_KEY", "sk-canary-DO-NOT-LEAK")

        body = (await self._get(app)).text

        assert "sk-canary-DO-NOT-LEAK" not in body
        # The config path, the bind address and the allowlist are all absent by
        # construction; assert on the shape so adding one is a failing test.
        assert set((await self._get(app)).json()) == {
            "status",
            "providers",
            "default_provider",
            "uptime_s",
        }

    async def test_it_reports_stopping_once_the_context_is_gone(
        self, app, monkeypatch
    ):
        """How a load balancer learns to stop sending work during shutdown."""
        import seekwright.server as srv

        monkeypatch.setattr(srv, "_shared", None)

        r = await self._get(app)
        assert r.status_code == 503
        assert r.json()["status"] == "stopping"


class _StubProvider:
    """Minimal provider for the dashboard wiring and end-to-end tests."""

    def __init__(self, name: str = "serper", *, cost_usd: float = 0.001) -> None:
        self.name = name
        self.cost_per_1k = 0.001
        self.calls = 0
        self._cost_usd = cost_usd

    async def search(self, q: SearchQuery) -> ProviderResult:
        self.calls += 1
        return ProviderResult(
            provider=self.name,
            results=[Result(title="t", url="https://example.com/a", snippet="s")],
            cost_usd=self._cost_usd,
        )

    async def aclose(self) -> None:
        return None


class _StubFetcher:
    """A local fetcher that returns a readable page without a network call."""

    name = "fetch"
    cost_per_1k: float | None = None

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        text = "The page body. " * 40
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


class TestDashboard:
    """The usage page and its data route, behind the `/mcp` Host allowlist.

    Unlike `/healthz` these carry data, so they do not get the allowlist
    bypass: a browser must type a name the operator put in `--allowed-host`.
    """

    @pytest.fixture
    def app(self, server, monkeypatch):
        import seekwright.server as srv
        from seekwright.config import Config, ProviderConfig

        cfg = Config(providers={"serper": ProviderConfig()})
        monkeypatch.setattr(
            srv,
            "_shared",
            srv.AppContext(
                config=cfg,
                engine=cast(Any, None),
                usage=UsageRecorder(),
                fetch_engine=cast(Any, None),
            ),
        )
        srv.mcp.custom_route("/dashboard", methods=["GET"])(srv.dashboard)
        srv.mcp.custom_route("/dashboard/data", methods=["GET"])(srv.dashboard_data)
        srv.mcp.custom_route("/dashboard/metrics", methods=["GET"])(srv.dashboard_metrics)
        return srv.mcp.streamable_http_app()

    async def _get(self, app, path: str, headers=None):
        # A loopback Host by default: the guard refuses anything the operator
        # did not allow, and the ASGI default (`testserver`) is not on the list.
        request_headers = {"Host": "127.0.0.1:8000", **(headers or {})}
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://127.0.0.1:8000"
        ) as client:
            return await client.get(path, headers=request_headers)

    async def test_the_page_is_self_contained_html(self, app):
        r = await self._get(app, "/dashboard")

        assert r.status_code == 200
        assert r.headers["content-type"].startswith("text/html")
        assert "seekwright · usage" in r.text
        # No external assets: a container behind a VPN loads nothing off-site.
        assert "cdn" not in r.text.lower()

    async def test_the_data_route_returns_the_snapshot(self, app):
        r = await self._get(app, "/dashboard/data")

        assert r.status_code == 200
        assert set(r.json()) == {
            "since",
            "process_started_at",
            "totals",
            "days",
            "providers",
            "answers",
            "endpoints",
            "recent",
            "journal",
        }

    async def test_the_page_carries_the_endpoint_panel(self, app):
        """The panel's two `<tbody>` ids and its heading are the static contract.

        They are what the page's own render targets, so a rename is a failing
        test rather than a panel that silently stops filling in.
        """
        text = (await self._get(app, "/dashboard")).text

        assert 'id="panel-endpoints"' in text
        assert 'id="endpoint-rollup"' in text
        assert 'id="endpoint-days"' in text
        assert "Endpoint latency &amp; cost · last 14 days" in text
        # Rendered from the existing poll's snapshot -- no second fetch.
        assert text.count("/dashboard/data") == 1

    async def test_the_page_carries_the_cost_by_provider_chart(self, app):
        """The stacked cost panel's two render targets are its static contract.

        The bar chart above answers *what did the day cost*; this one answers
        *whose money was it*. Its ids are the
        contract the way the Endpoint panel's `<tbody>` ids are -- a rename is a
        failing test, not a panel that silently never fills -- and like that
        panel it draws from the `endpoints` series the poll already carries, so
        no second route appears on the page.
        """
        text = (await self._get(app, "/dashboard")).text

        assert 'id="panel-provider-cost"' in text
        assert 'id="provider-chart"' in text
        assert 'id="provider-legend"' in text
        assert "Cost per day by provider · last 14 days" in text
        # A free provider bills nothing, so it draws no segment; the panel says
        # so rather than letting an absent bar read as an absent provider.
        assert "an unbilled provider draws no height" in text
        assert text.count("/dashboard/data") == 1

    async def test_the_page_carries_the_answers_panel(self, app):
        """The answers panel's ids and heading are the static contract too.

        The ranking data the section exists for is rendered client-side, so a
        rename of a `<tbody>` id is a panel that silently stops filling in
        unless a test names it.
        """
        text = (await self._get(app, "/dashboard")).text

        assert 'id="panel-answers"' in text
        assert 'id="answers-model"' in text
        assert 'id="answers-providers"' in text
        assert "Agent answers" in text
        # The model's own column, and the rule that keeps cited_invalid off a
        # provider row, are on the page for a reader who is not in the spec.
        assert "Spend · model" in text
        assert "cited invalid is never a provider's" in text
        assert "counted, not priced" in text

    async def test_every_id_the_page_script_looks_up_exists(self, app):
        """A `$("x")` with no such element is a panel that silently never fills.

        The static half of the page's contract: the ids the script reads are
        the ids the document has, and every no-argument `render*` function is
        wired into `render()` -- a new panel that is defined and never called
        looks exactly like a panel with no data.
        """
        text = (await self._get(app, "/dashboard")).text

        present = set(re.findall(r'id="([^"]+)"', text))
        looked_up = set(re.findall(r'\$\("([^"]+)"\)', text))
        looked_up |= set(re.findall(r'getElementById\("([^"]+)"\)', text))
        assert looked_up <= present, sorted(looked_up - present)

        body = text.split("function render() {")[1].split("\n  }")[0]
        for name in re.findall(r"function (render[A-Z]\w*)\(\)", text):
            assert name + "()" in body, name

    async def test_the_answers_section_is_served_empty_and_not_a_zero_row(self, app):
        r = await self._get(app, "/dashboard/data")

        answers = r.json()["answers"]
        assert answers["calls"] == 0
        assert answers["model_cost_usd"] is None
        assert answers["prompt_tokens"] is None
        assert answers["mean_ms"] is None
        assert answers["providers"] == []

    async def test_the_metrics_route_serves_the_endpoints_object(self, app):
        """An empty window is an empty list, not a zero row: absence, not 0."""
        r = await self._get(app, "/dashboard/metrics")

        assert r.status_code == 200
        assert r.json() == {"window_days": 14, "providers": []}

    async def test_an_unknown_host_is_refused_on_every_data_route(self, app):
        for path in ("/dashboard", "/dashboard/data", "/dashboard/metrics"):
            r = await self._get(app, path, {"Host": "evil.example"})
            assert r.status_code == 421, path

    async def test_the_loopback_host_is_accepted(self, app):
        r = await self._get(app, "/dashboard/data", {"Host": "127.0.0.1:8000"})
        assert r.status_code == 200

    async def test_it_reports_stopping_once_the_context_is_gone(self, app, monkeypatch):
        import seekwright.server as srv

        monkeypatch.setattr(srv, "_shared", None)

        r = await self._get(app, "/dashboard/data")
        assert r.status_code == 503
        assert r.json()["status"] == "stopping"

    async def test_the_metrics_route_reports_stopping_too(self, app, monkeypatch):
        import seekwright.server as srv

        monkeypatch.setattr(srv, "_shared", None)

        r = await self._get(app, "/dashboard/metrics")
        assert r.status_code == 503
        assert r.json()["status"] == "stopping"

    async def test_the_recorder_is_wired_into_both_engines(self, monkeypatch):
        import seekwright.server as srv
        from seekwright.config import Config, ProviderConfig

        monkeypatch.setattr(
            srv, "build_providers", lambda _config, _client: {"serper": _StubProvider()}
        )
        cfg = Config(providers={"serper": ProviderConfig()})

        async with srv.build_app_context(cfg) as ctx:
            assert ctx.usage is ctx.engine.usage
            assert ctx.fetch_engine is not None
            assert ctx.fetch_engine.usage is ctx.usage

    async def test_spend_and_usage_reach_the_page_and_the_journal(
        self, monkeypatch, tmp_path
    ):
        """The end-to-end proof: a real search and fetch, then the JSON route."""
        import seekwright.server as srv
        from seekwright.config import Config, DashboardConfig, ProviderConfig

        monkeypatch.setattr(
            srv,
            "build_providers",
            lambda _config, _client: {"serper": _StubProvider(cost_usd=0.001)},
        )
        journal = tmp_path / "usage.jsonl"
        cfg = Config(
            providers={"serper": ProviderConfig()},
            dashboard=DashboardConfig(history_path=str(journal)),
        )

        async with srv.build_app_context(cfg) as ctx:
            monkeypatch.setattr(srv, "_shared", ctx)
            assert ctx.fetch_engine is not None
            ctx.fetch_engine.fetcher = _StubFetcher()  # type: ignore[assignment]
            await ctx.engine.search(SearchQuery(query="sqlite wal mode"))
            await ctx.fetch_engine.fetch("https://example.com/a")

            srv.mcp.custom_route("/dashboard/data", methods=["GET"])(srv.dashboard_data)
            app = srv.mcp.streamable_http_app()
            body = (await self._get(app, "/dashboard/data")).json()

        assert body["totals"]["searches"] == 1
        assert body["totals"]["search_cost_usd"] == 0.001
        assert body["totals"]["fetches"] == 1

        lines = journal.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 2
        parsed = [json.loads(line) for line in lines]
        assert {p["tool"] for p in parsed} == {"search", "fetch"}
        assert parsed[0]["provider"] == "serper"
        assert parsed[0]["cost_usd"] == 0.001
        # A fresh recorder backfills `since` from the file it wrote.
        assert UsageRecorder(history_path=str(journal)).snapshot()["since"] == (
            body["since"]
        )

    async def test_the_metrics_route_carries_the_recorded_endpoints(
        self, monkeypatch, tmp_path
    ):
        """A real search, then the route -- and never the journal again.

        The recorder folds the journal in at construction, so a line appended
        afterwards must not appear: no request on this route is answered from
        history, which is the property `/dashboard/data` already has. The route
        body is also asserted equal to the `endpoints` key the panel renders,
        so the script's answer and the page's cannot drift.
        """
        import seekwright.server as srv
        from seekwright.config import Config, DashboardConfig, ProviderConfig

        monkeypatch.setattr(
            srv,
            "build_providers",
            lambda _config, _client: {"serper": _StubProvider(cost_usd=0.001)},
        )
        journal = tmp_path / "usage.jsonl"
        cfg = Config(
            providers={"serper": ProviderConfig()},
            dashboard=DashboardConfig(history_path=str(journal)),
        )

        async with srv.build_app_context(cfg) as ctx:
            monkeypatch.setattr(srv, "_shared", ctx)
            await ctx.engine.search(SearchQuery(query="sqlite wal mode"))

            srv.mcp.custom_route("/dashboard/metrics", methods=["GET"])(
                srv.dashboard_metrics
            )
            app = srv.mcp.streamable_http_app()
            body = (await self._get(app, "/dashboard/metrics")).json()
            snapshot = (await self._get(app, "/dashboard/data")).json()

            with journal.open("a", encoding="utf-8") as handle:
                handle.write(
                    json.dumps(
                        {
                            "ts": "2026-01-01T00:00:00+00:00",
                            "tool": "search",
                            "provider": "appended",
                            "ms": 5,
                            "cost_usd": 0.5,
                            "results": 1,
                            "fell_back": False,
                            "error": None,
                        }
                    )
                    + "\n"
                )
            again = (await self._get(app, "/dashboard/metrics")).json()

        assert body == snapshot["endpoints"]
        assert body["window_days"] == 14
        assert [p["provider"] for p in body["providers"]] == ["serper"]
        row = body["providers"][0]
        assert row["calls"] == 1
        assert row["errors"] == 0
        assert row["fell_back_calls"] == 0
        assert row["latency_samples"] == 1
        assert row["cost_usd"] == 0.001
        assert isinstance(row["p50_ms"], int)
        assert row["days"] == [
            {
                "date": datetime.now(UTC).date().isoformat(),
                "calls": 1,
                "errors": 0,
                "fell_back_calls": 0,
                "latency_samples": 1,
                "p50_ms": row["p50_ms"],
                "p95_ms": row["p50_ms"],
                "mean_ms": row["p50_ms"],
                "cost_usd": 0.001,
                "cost_per_1k": 1.0,
                "first_seen": row["first_seen"],
                "last_seen": row["last_seen"],
            }
        ]
        assert again == body


class TestUvicornLogging:
    def test_access_logs_are_kept_off_stdout(self, monkeypatch):
        """`log_config=None` is load-bearing, so it is pinned.

        uvicorn's built-in LOGGING_CONFIG points `uvicorn.access` at *stdout*
        and marks its loggers `propagate: False`, which both breaks the
        everything-on-stderr rule and routes around the intercept handler.
        """
        import uvicorn
        import uvicorn.config

        assert (
            uvicorn.config.LOGGING_CONFIG["handlers"]["access"]["stream"]
            == "ext://sys.stdout"
        ), "the default this guards against has changed; revisit _serve_http"

        import seekwright.server as srv

        captured: dict[str, object] = {}

        class FakeConfig:
            def __init__(self, _app, **kw):
                captured.update(kw)

        class FakeServer:
            def __init__(self, _config):
                pass

            async def serve(self):
                return None

        monkeypatch.setattr(uvicorn, "Config", FakeConfig)
        monkeypatch.setattr(uvicorn, "Server", FakeServer)

        from seekwright.config import Config, ProviderConfig

        cfg = Config(providers={"exa:free": ProviderConfig()})
        asyncio.run(srv._serve_http(cfg, "127.0.0.1", 8000, []))

        assert captured["log_config"] is None
        # uvicorn re-applies `log_level` after `setup_logging`, so this must not
        # carry our level.
        assert captured["log_level"] == stdlib_logging.WARNING
        assert captured["access_log"] is False


class _FixedContext:
    """The slice of FastMCP's `Context` the tool bodies read: the app."""

    def __init__(self, app: Any) -> None:
        class _RequestContext:
            lifespan_context = app

        self.request_context = _RequestContext()


class TestFetchDisabled:
    """`[fetch] enabled = false` used to be inert: `--check` reported it and
    the startup log printed it, while the tool kept serving -- paid fallbacks
    included. The tool stays registered (its schema is frozen at import) and
    refuses here instead -- the same reasoning that keeps the `provider`
    parameter a Literal of every backend while the schema stays frozen at
    import."""

    async def test_a_disabled_fetch_refuses_with_a_clean_error(self):
        from seekwright.config import Config, FetchConfig, ProviderConfig
        from seekwright.server import AppContext, fetch

        cfg = Config(
            providers={"serper": ProviderConfig()},
            fetch=FetchConfig(enabled=False),
        )
        app = AppContext(config=cfg, engine=cast(Any, None), usage=UsageRecorder())

        with pytest.raises(ValueError, match="disabled"):
            await fetch(_FixedContext(app), "https://example.com/")

    async def test_a_disabled_fetch_builds_no_fetcher_or_fallbacks(
        self, monkeypatch, tmp_path
    ):
        """An off key must also not cost the connection pool it would save."""
        from seekwright.config import load_config
        from seekwright.server import build_app_context

        cfg_path = tmp_path / "config.toml"
        cfg_path.write_text(
            "[providers.serper]\nenabled = true\n\n"
            '[fetch]\nenabled = false\nfallback = ["scrappa"]\n'
        )
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(cfg_path))

        async with build_app_context(load_config()) as ctx:
            assert ctx.fetch_engine is None


class TestFetchPrimaryPreFlight:
    """`fetch.primary` naming a fallback this deployment cannot build refuses
    to start, rather than quietly reading from this server's own IP.

    The key is the operator saying which route an unnamed fetch leads with, and
    the local reader dials from this server's own address. A primary that
    cannot be built -- no key, no `crawl4ai_url`, or excluded by
    `permitted_providers` -- therefore must not degrade into the one route the
    operator was steering away from. Same shape and same place as the missing
    provider key and the missing extraction backend above: a `SystemExit`
    before `mcp.run`, so stdio shows the sentence rather than an
    ExceptionGroup traceback.
    """

    def test_an_unbuildable_primary_refuses_to_start(self, monkeypatch):
        import seekwright.server as srv
        from seekwright.config import Config, FetchConfig, ProviderConfig

        # `scrappa` is built only from its key; without one the builder returns
        # `None`, the same absence a `permitted_providers` set that omits the
        # name produces.
        monkeypatch.delenv("SEEKWRIGHT_SCRAPPA_API_KEY", raising=False)
        monkeypatch.setattr(
            srv,
            "load_config",
            lambda: Config(
                providers={"searxng": ProviderConfig(url="http://searx.test:8080")},
                fetch=FetchConfig(primary="scrappa", fallback=["scrappa"]),
            ),
        )
        # The extraction-backend check runs first and is not what this asserts.
        monkeypatch.setattr(srv, "build_extractor", lambda _cfg: None)
        monkeypatch.setattr(srv.mcp, "run", lambda **_kw: pytest.fail("ran anyway"))

        def dialled(*_args: object, **_kwargs: object) -> NoReturn:
            pytest.fail("a probe that was never built must not be closed")

        monkeypatch.setattr(srv.anyio, "run", dialled)

        with pytest.raises(SystemExit) as excinfo:
            srv.main()

        message = str(excinfo.value)
        assert "fetch.primary names 'scrappa'" in message
        assert "cannot build" in message
        # The refusal is only actionable if it says where the reason is printed.
        assert "`seekwright --check`" in message
        assert "refusing to start" in message

    def test_a_primary_the_engine_was_not_handed_is_refused(self):
        """The engine-side twin of the pre-flight: a config that validates but
        whose ladder never got the named fallback.

        `FetchConfig` checks registry membership only, so `jina` validates on
        every deployment; an engine handed an empty ladder must say so rather
        than fall back to the local reader the operator did not choose.
        """
        from seekwright.config import (
            Config,
            FetchConfig,
            PolicyConfig,
            ProviderConfig,
        )
        from seekwright.engine import FetchEngine

        cfg = Config(
            providers={"serper": ProviderConfig()},
            policy=PolicyConfig(),
            fetch=FetchConfig(primary="jina"),
        )

        with pytest.raises(ValueError, match="which this deployment did not build"):
            FetchEngine(cfg, _StubLocalFetcher(), [])


class TestFreeModeOnTheTool:
    """`mode="free"` on the wire.

    Both refusals are raised by the engine and translated by the tool's
    `except SearchFailed`, so the tool body stays thin -- the shape `fetch`
    uses for `query`/`offset` -- and the tool is registered either way, because
    its schema was frozen at import.
    """

    @staticmethod
    def _app(*names: str):
        from seekwright.config import Config, ProviderConfig
        from seekwright.engine import SearchEngine
        from seekwright.server import AppContext

        cfg = Config(
            providers={
                name: (
                    ProviderConfig(url="http://searxng.test:8080")
                    if name == "searxng"
                    else ProviderConfig()
                )
                for name in names
            }
        )
        engine = SearchEngine(cfg, {name: cast(Any, None) for name in names})
        return AppContext(config=cfg, engine=engine, usage=UsageRecorder())

    async def test_no_free_provider_enabled_refuses_naming_the_free_set(self, server):
        from seekwright.server import search

        with pytest.raises(ValueError, match="No free provider is enabled") as exc:
            await search(_FixedContext(self._app("serper")), "sqlite wal mode", mode="free")

        text = str(exc.value)
        for name in ("exa:free", "parallel:free", "freeserp", "searxng", "tinyfish"):
            assert name in text
        # The refusal is a call-time error, not a missing tool: the schema is
        # frozen at import and cannot advertise what this deployment enabled.
        assert "search" in [t.name for t in await server.list_tools()]

    async def test_naming_both_provider_and_mode_refuses(self, server):
        from seekwright.server import search

        app = self._app("serper", "exa:free")

        with pytest.raises(ValueError) as exc:
            await search(
                _FixedContext(app),
                "sqlite wal mode",
                provider="serper",
                mode="free",
            )

        assert "pass `provider` or `mode`, not both" in str(exc.value)


class TestTheImplicitProviderSet:
    """A config that enables nothing starts, and says what it enabled.

    The default is allowed to exist; it is not allowed to be silent, which is
    the difference from the rule it replaces -- `--check` and the startup line
    are where an operator who never wrote a `[providers]` block learns which
    backends a bare `search` can reach.
    """

    async def test_the_startup_line_names_the_implicit_keyless_set(
        self, monkeypatch, tmp_path, log_records
    ):
        import seekwright.server as srv
        from seekwright.config import load_config

        cfg_path = tmp_path / "config.toml"
        cfg_path.write_text("[policy]\nmax_snippet_chars = 100\n")
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(cfg_path))
        # No network: the point is the line, not the handshake.
        monkeypatch.setattr(srv, "build_providers", lambda _cfg, _client: {})

        async with srv.build_app_context(load_config()):
            pass

        startup = next(r for r in log_records if r.record["message"] == "startup")
        assert startup.record["extra"]["providers"] == "exa:free,freeserp,parallel:free"
        assert startup.record["extra"]["providers_defaulted"] is True

    async def test_an_explicit_set_is_not_reported_as_defaulted(
        self, monkeypatch, tmp_path, log_records
    ):
        import seekwright.server as srv
        from seekwright.config import load_config

        cfg_path = tmp_path / "config.toml"
        cfg_path.write_text('[providers."exa:free"]\nenabled = true\n')
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(cfg_path))
        monkeypatch.setattr(srv, "build_providers", lambda _cfg, _client: {})

        async with srv.build_app_context(load_config()):
            pass

        startup = next(r for r in log_records if r.record["message"] == "startup")
        assert startup.record["extra"]["providers"] == "exa:free"
        assert startup.record["extra"]["providers_defaulted"] is False
