"""Executable spec for the filters a search can ask a provider for.

The scenarios in ``search_constraints.feature`` in this directory are written from the
agent's side of the wire and run against the real MCP server over an in-memory
transport, with the *real* adapter underneath -- driven through an
``httpx.MockTransport`` -- so one scenario covers the whole path: the tool
schema, the ``SearchQuery`` the engine builds, the adapter's mapping onto its
own wire shape, and the ``notice`` the caller reads back. A stub returning a
canned ``ProviderResult`` would prove only the first of those, which is the part
that was never in doubt.

Steps are deliberately synchronous. pytest-bdd calls step functions directly, so
an ``async def`` step would return a coroutine nobody awaits and a scenario that
passes without asserting anything -- ``asyncio_mode = "auto"`` does not help,
since it applies to async *test* functions and the test pytest-bdd generates is
sync. The one async span (open a session, call the tool, close it) is therefore
run inside a single ``asyncio.run`` in the when-step.

What is *not* covered here, on purpose: `safe_search` has no partially-honoured
case to write a scenario for. Every capable backend honours both of its values
exactly, which is the property the parameter is a boolean rather than a level
scale for; the per-adapter tests (``tests/providers/test_scrappa.py``, ``tests/providers/test_searxng.py``,
``tests/providers/test_tavily.py``) assert both wire values on each one. The partially-honoured
case that does exist is `country` against `language` -- a backend that sends the
language while the country goes unhonoured names only the country -- and that is
asserted in ``tests/providers/test_searxng.py`` and ``tests/providers/test_tavily.py``.
"""

import asyncio
import json
from typing import Any

import httpx
from mcp import types
from mcp.shared.memory import create_connected_server_and_client_session
from pytest_bdd import given, parsers, scenarios, then, when

from seekwright import server
from seekwright.models import ProviderResult, SearchQuery
from seekwright.providers.algolia import AlgoliaProvider
from seekwright.providers.base import SearchProvider
from seekwright.providers.scrappa import ScrappaProvider
from seekwright.providers.serper import SerperProvider
from seekwright.providers.tinyfish import TinyfishProvider

scenarios("search_constraints.feature")

# One documented payload per backend, the shape its own ``_parse`` reads.
# A single union payload would have hidden a container rename.
SAMPLES: dict[str, dict[str, Any]] = {
    "scrappa": {
        "organic_results": [
            {
                "position": 1,
                "title": "Write-Ahead Logging",
                "link": "https://www.sqlite.org/wal.html",
                "snippet": "WAL is the default journal mode since 3.7.0.",
            }
        ]
    },
    "serper": {
        "organic": [
            {
                "title": "Write-Ahead Logging",
                "link": "https://www.sqlite.org/wal.html",
                "snippet": "WAL is the default journal mode since 3.7.0.",
            }
        ]
    },
    "tinyfish": {
        "results": [
            {
                "position": 1,
                "site_name": "sqlite.org",
                "title": "Write-Ahead Logging",
                "url": "https://www.sqlite.org/wal.html",
                "snippet": "WAL is the default journal mode since 3.7.0.",
            }
        ]
    },
    "algolia": {
        "hits": [
            {
                "title": "Write-Ahead Logging",
                "url": "https://www.sqlite.org/wal.html",
                "snippet": "WAL is the default journal mode since 3.7.0.",
            }
        ]
    },
}


def _adapter(name: str, client: httpx.AsyncClient) -> SearchProvider:
    """The real adapter for ``name``, on a throwaway key.

    Algolia's app ID and index are constructor arguments rather than config here,
    because the scenario replaces the factory: the point is the request the
    adapter builds, not how a deployment wires its credentials.
    """
    if name == "scrappa":
        return ScrappaProvider(client, "test-key")
    if name == "serper":
        return SerperProvider(client, "test-key")
    if name == "tinyfish":
        return TinyfishProvider(client, "test-key")
    if name == "algolia":
        return AlgoliaProvider(client, "test-key", app_id="app123", index="pages")
    raise AssertionError(f"no sample payload for {name!r}")


class RecordingProvider:
    """The stub: a real adapter plus a record of what the tool handed it.

    Structurally a ``SearchProvider``, so the engine cannot tell the difference.
    It keeps every ``SearchQuery`` the tool built and every ``httpx.Request`` the
    adapter then made, which is what lets the ``Then`` steps assert both halves
    of the claim: that the filter survived the tool boundary *and* that it
    reached the backend's own parameter.
    """

    def __init__(self, inner: SearchProvider, requests: list[httpx.Request]) -> None:
        self.name = inner.name
        self.cost_per_1k = inner.cost_per_1k
        self.queries: list[SearchQuery] = []
        self.requests = requests
        self._inner = inner

    async def search(self, q: SearchQuery) -> ProviderResult:
        self.queries.append(q)
        return await self._inner.search(q)

    async def aclose(self) -> None:
        return None


def _text(result: types.CallToolResult) -> str:
    return "\n".join(
        block.text for block in result.content if isinstance(block, types.TextContent)
    )


def _payload(result: types.CallToolResult) -> dict[str, Any]:
    return json.loads(_text(result))


def _call_search(arguments: dict[str, object]) -> types.CallToolResult:
    async def run() -> types.CallToolResult:
        async with create_connected_server_and_client_session(server.mcp) as session:
            return await session.call_tool("search", arguments)

    return asyncio.run(run())


@given(parsers.parse("a server enabling {names}"), target_fixture="providers")
def a_server_enabling(names, monkeypatch, tmp_path) -> dict[str, RecordingProvider]:
    enabled = [name.strip() for name in names.split(",")]
    config = tmp_path / "config.toml"
    config.write_text("".join(_provider_table(n) for n in enabled))
    monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))

    # The factory is replaced rather than the API keys: a scenario that reaches
    # a search would otherwise build the adapter from config and bill it.
    stubs = {name: _recording_adapter(name) for name in enabled}
    monkeypatch.setattr(server, "build_providers", lambda _config, _client: stubs)
    return stubs


def _recording_adapter(name: str) -> RecordingProvider:
    """A real adapter over a MockTransport that records the request it made."""
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, json=SAMPLES[name])

    return RecordingProvider(
        _adapter(name, httpx.AsyncClient(transport=httpx.MockTransport(handler))),
        requests,
    )


def _provider_table(name: str) -> str:
    """A ``[providers.<name>]`` table, quoted when the name needs it.

    A bare name is a legal TOML key unquoted; a `backend:flavour` name is not --
    `:` ends a key, so the unquoted form never parses (docs/reference/
    provider-contract.md, rule 1).

    Algolia's knobs are spelled out because the config validator refuses to
    enable the name without them -- it searches one operator-named index, so
    there is no sensible default to fall back on. The adapter itself is built
    from the factory this scenario replaces, so these only have to satisfy the
    config.
    """
    key = f'"{name}"' if ":" in name else name
    extra = 'app_id = "app123"\nindex = "pages"\n' if name == "algolia" else ""
    return f"[providers.{key}]\nenabled = true\n{extra}"


@when("the agent searches with safe_search true", target_fixture="result")
def searching_with_safe_search_true() -> types.CallToolResult:
    return _call_search({"query": "sqlite wal mode", "safe_search": True})


@when(
    parsers.parse('the agent searches with language "{language}"'),
    target_fixture="result",
)
def searching_with_language(language: str) -> types.CallToolResult:
    return _call_search({"query": "sqlite wal mode", "language": language})


@then(parsers.parse('{name} receives safe "{value}"'))
def the_provider_receives_safe(
    name: str, value: str, providers: dict[str, RecordingProvider]
) -> None:
    """The adapter's own parameter, read off the request it actually made."""
    stub = providers[name]
    assert stub.queries, "the tool never reached the provider"
    assert stub.queries[0].safe_search is True, "the tool dropped the filter"
    params = stub.requests[0].url.params
    assert params["safe"] == value


@then(parsers.parse('{name} receives language "{value}"'))
def the_provider_receives_language(
    name: str, value: str, providers: dict[str, RecordingProvider]
) -> None:
    stub = providers[name]
    assert stub.queries, "the tool never reached the provider"
    assert stub.queries[0].language == value, "the tool dropped the filter"
    params = stub.requests[0].url.params
    assert params["language"] == value


@then("the response carries no notice")
def the_response_carries_no_notice(result: types.CallToolResult) -> None:
    assert not result.isError, _text(result)
    assert _payload(result).get("notice") is None


@then(parsers.parse("the response notice says {token} was ignored"))
def the_notice_says_it_was_ignored(token: str, result: types.CallToolResult) -> None:
    """The token is named by the notice and the notice calls it a drop.

    Not an exact-sentence match on purpose: an adapter with no geo surface at all
    reports the joined `country/language` token, so a language-only drop there is
    named inside a longer phrase. What the caller has to be able to tell is that
    the constraint was seen and not applied.
    """
    assert not result.isError, _text(result)
    notice = _payload(result).get("notice") or ""
    assert token in notice, f"{token!r} is not named in {notice!r}"
    assert "ignored" in notice


@then("the call comes back as an error")
def the_call_is_an_error(
    result: types.CallToolResult, providers: dict[str, RecordingProvider]
) -> None:
    """And nothing was billed: the schema refuses it before the tool body runs.

    The scenario's whole point. `language` is bounded to two letters, so a
    regional tag never reaches an adapter -- a proxy that narrowed it with
    `split("-")[0]` would have spent the call and answered a different question
    than the caller asked.
    """
    assert result.isError, f"expected a tool error, got {_text(result)!r}"
    for stub in providers.values():
        assert not stub.requests, "a refused request still reached the backend"


@then("the error names language")
def the_error_names_language(result: types.CallToolResult) -> None:
    assert "language" in _text(result)
