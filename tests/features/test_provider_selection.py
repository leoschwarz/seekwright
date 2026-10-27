"""Executable spec for asking this server for a provider it does not have.

The scenarios in ``provider_selection.feature`` in this directory are written from the
agent's side of the wire and run against the real MCP server over an in-memory
transport, so they cover the whole path -- schema validation, then
``SearchEngine.resolve``, then the exception translation in ``server.py`` --
which the unit tests in ``test_engine.py`` and ``test_server.py`` each see only
one segment of. What an agent reads back is the contract here, and until this
module existed nothing checked that the engine's message survived the trip.

Steps are deliberately synchronous. pytest-bdd calls step functions directly, so
an ``async def`` step would return a coroutine nobody awaits and a scenario that
passes without asserting anything -- ``asyncio_mode = "auto"`` does not help,
since it applies to async *test* functions and the test pytest-bdd generates is
sync. The one async span (open a session, call the tool, close it) is therefore
run inside a single ``asyncio.run`` in the when-step.
"""

import asyncio
import json

from mcp import Client, types
from pytest_bdd import given, parsers, scenarios, then, when

from seekwright import server
from seekwright.config import FREE_PROVIDERS
from seekwright.models import ProviderResult, Result, SearchQuery
from seekwright.providers.base import ProviderError

scenarios("provider_selection.feature")


class StubProvider:
    """A provider that structurally satisfies ``SearchProvider`` for tests.

    Deliberately not shared with the stub in ``test_engine.py``. ``conftest.py``
    exists, but it holds only the two loguru fixtures -- loguru is process-global
    state, so that is genuinely cross-cutting -- and a fake shared by two call
    sites still belongs next to the tests that use it.
    """

    def __init__(self, name: str, *, fail: Exception | None = None) -> None:
        self.name = name
        self.cost_per_1k = 0.001
        self.calls = 0
        self._fail = fail

    async def search(self, q: SearchQuery) -> ProviderResult:
        self.calls += 1
        if self._fail is not None:
            raise self._fail
        return ProviderResult(
            provider=self.name,
            results=[
                Result(
                    title=f"Result for {q.query}",
                    url="https://example.com/a",
                    snippet="a snippet",
                )
            ],
        )

    async def aclose(self) -> None:
        return None


def _text(result: types.CallToolResult) -> str:
    return "\n".join(
        block.text for block in result.content if isinstance(block, types.TextContent)
    )


def _call_search(arguments: dict[str, object]) -> types.CallToolResult:
    async def run() -> types.CallToolResult:
        async with Client(server.mcp) as client:
            return await client.call_tool("search", arguments)

    return asyncio.run(run())


def _provider_table(name: str) -> str:
    """A ``[providers.<name>]`` table, quoted when the name needs it.

    A bare name is a legal TOML key unquoted; a `backend:flavour` name is not
    -- `:` ends a key, so the unquoted form never parses. Quoting only the
    flavoured names keeps the scenarios' configs the shape an operator writes
    (docs/reference/provider-contract.md, rule 1).
    """
    key = f'"{name}"' if ":" in name else name
    return f"[providers.{key}]\nenabled = true\n"


@given(parsers.parse("a server enabling {names}"), target_fixture="providers")
def a_server_enabling(names, monkeypatch, tmp_path) -> dict[str, StubProvider]:
    enabled = [name.strip() for name in names.split(",")]
    config = tmp_path / "config.toml"
    config.write_text("".join(_provider_table(n) for n in enabled))
    monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))

    # The factory is replaced rather than the API keys: the scenario that gets
    # as far as a search would otherwise build a real adapter and bill it.
    stubs = {name: StubProvider(name) for name in enabled}
    monkeypatch.setattr(server, "build_providers", lambda _config, _client: stubs)
    return stubs


@given(
    parsers.parse("a server whose default {default} fails, falling back to {fallbacks}"),
    target_fixture="providers",
)
def a_server_whose_default_fails(
    default: str, fallbacks: str, monkeypatch, tmp_path
) -> dict[str, StubProvider]:
    """The default's stub raises; the fallbacks' stubs are healthy. The config is
    a real TOML file, so the [search] validator runs as in production."""
    fallback_names = [name.strip() for name in fallbacks.split(",")]
    text = f'default_provider = "{default}"\n'
    text += _provider_table(default)
    for name in fallback_names:
        text += _provider_table(name)
    text += '[search]\nfallback = ["' + '", "'.join(fallback_names) + '"]\n'
    config = tmp_path / "config.toml"
    config.write_text(text)
    monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))

    stubs = {
        default: StubProvider(default, fail=ProviderError(default, "upstream 503"))
    }
    for name in fallback_names:
        stubs[name] = StubProvider(name)
    monkeypatch.setattr(server, "build_providers", lambda _config, _client: stubs)
    return stubs


@given(
    "a server whose default serper fails, and so does every fallback",
    target_fixture="providers",
)
def a_server_where_everything_fails(monkeypatch, tmp_path) -> dict[str, StubProvider]:
    config = tmp_path / "config.toml"
    config.write_text(
        'default_provider = "serper"\n'
        "[providers.serper]\nenabled = true\n"
        "[providers.linkup]\nenabled = true\n"
        '[search]\nfallback = ["linkup"]\n'
    )
    monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))

    stubs = {
        "serper": StubProvider("serper", fail=ProviderError("serper", "upstream 503")),
        "linkup": StubProvider("linkup", fail=ProviderError("linkup", "HTTP 500")),
    }
    monkeypatch.setattr(server, "build_providers", lambda _config, _client: stubs)
    return stubs


@given(
    parsers.parse("a server enabling {names} where every free provider fails"),
    target_fixture="providers",
)
def a_server_where_every_free_provider_fails(
    names: str, monkeypatch, tmp_path
) -> dict[str, StubProvider]:
    """Every free stub raises; the paid ones stay healthy and are the proof.

    The paid stub's call count is what the scenario asserts on: a free-only
    search must leave it at zero, whatever the free fallbacks do.
    """
    enabled = [name.strip() for name in names.split(",")]
    config = tmp_path / "config.toml"
    config.write_text("".join(_provider_table(n) for n in enabled))
    monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))

    stubs = {
        name: StubProvider(
            name,
            fail=(
                ProviderError(name, "rate limited") if name in FREE_PROVIDERS else None
            ),
        )
        for name in enabled
    }
    monkeypatch.setattr(server, "build_providers", lambda _config, _client: stubs)
    return stubs


@when(
    parsers.parse('the agent searches with provider "{provider}"'),
    target_fixture="result",
)
def searching_with_provider(provider: str) -> types.CallToolResult:
    return _call_search({"query": "sqlite wal mode", "provider": provider})


@when(
    parsers.parse('the agent searches with provider "{provider}" and mode "{mode}"'),
    target_fixture="result",
)
def searching_with_provider_and_mode(provider: str, mode: str) -> types.CallToolResult:
    return _call_search(
        {"query": "sqlite wal mode", "provider": provider, "mode": mode}
    )


@when(parsers.parse('the agent searches with mode "{mode}"'), target_fixture="result")
def searching_with_mode(mode: str) -> types.CallToolResult:
    return _call_search({"query": "sqlite wal mode", "mode": mode})


@when("the agent searches without naming a provider", target_fixture="result")
def searching_without_provider() -> types.CallToolResult:
    return _call_search({"query": "sqlite wal mode"})


@then("the call comes back as an error")
def the_call_is_an_error(result: types.CallToolResult) -> None:
    assert result.is_error, f"expected a tool error, got {_text(result)!r}"


@then(parsers.parse("the error names {name} as available"))
def the_error_names_an_available_provider(result: types.CallToolResult, name: str):
    assert name in _text(result)


@then("the error tells the agent to retry with an available provider")
def the_error_says_to_retry(result: types.CallToolResult) -> None:
    assert "Retry with one of those" in _text(result)


@then("the error tells the agent to name a provider")
def the_error_says_to_name_one(result: types.CallToolResult) -> None:
    assert "pass `provider`" in _text(result)


@then("the error names every provider the schema accepts")
def the_error_names_the_whole_literal(result: types.CallToolResult) -> None:
    """A name outside the `Literal` never reaches the engine.

    Schema validation rejects it first, so the agent is told which providers the
    *package* implements rather than which this deployment enabled -- recovery
    from here takes two calls, not one.
    """
    text = _text(result)
    for name in ("scrappa", "serper", "linkup", "exa", "exa:free"):
        assert name in text


@then("serper runs the search")
def serper_ran_the_search(
    result: types.CallToolResult, providers: dict[str, StubProvider]
) -> None:
    assert not result.is_error, _text(result)
    assert providers["serper"].calls == 1


@then("linkup runs the search and the notice names the substitute")
def linkup_ran_and_the_notice_names_the_substitute(
    result: types.CallToolResult, providers: dict[str, StubProvider]
) -> None:
    assert not result.is_error, _text(result)
    payload = json.loads(_text(result))
    assert payload["provider"] == "linkup"
    assert "serper failed (upstream 503)" in payload["notice"]
    assert "served by linkup instead" in payload["notice"]
    assert providers["serper"].calls == 1
    assert providers["linkup"].calls == 1


@then("linkup does not run")
def linkup_did_not_run(providers: dict[str, StubProvider]) -> None:
    assert providers["linkup"].calls == 0


@then("the error names the original failure and the failed fallbacks")
def the_error_names_the_original_and_the_failed_fallbacks(
    result: types.CallToolResult,
) -> None:
    text = _text(result)
    assert "upstream 503" in text
    assert "Fallbacks also failed: linkup." in text


@then("the error refuses the pair, naming `provider` and `mode`")
def the_error_refuses_the_pair(result: types.CallToolResult) -> None:
    """Two ways to name a route is an ambiguity with a precedence rule hiding
    in it, so neither wins -- the shape `fetch` uses for `query`/`offset`."""
    assert "pass `provider` or `mode`, not both" in _text(result)


@then(parsers.parse("{name} runs no search"))
def provider_runs_no_search(
    name: str, providers: dict[str, StubProvider]
) -> None:
    """The paid counter, not the response's `provider`: a free-only search
    must not reach a provider that can bill, whatever the free fallbacks do."""
    assert providers[name].calls == 0


@then("the error names the failed free fallbacks")
def the_error_names_the_failed_free_fallbacks(result: types.CallToolResult) -> None:
    text = _text(result)
    assert "exa:free: rate limited" in text
    assert "Fallbacks also failed: tinyfish." in text


@then("the error says no paid provider was tried")
def the_error_says_no_paid_provider_was_tried(result: types.CallToolResult) -> None:
    """The model cannot see the walk, so the message is the only place the
    reason nothing paid answered can be stated."""
    assert "no paid provider was tried" in _text(result)


@given(
    parsers.parse("a server enabling {names} and permitting only {permitted}"),
    target_fixture="providers",
)
def a_server_with_a_permission_set(
    names: str, permitted: str, monkeypatch, tmp_path
) -> dict[str, StubProvider]:
    """The allow-list as an operator writes it: one top-level key, and the
    names it omits stay enabled and unreachable -- the intersection, not a
    second `enabled`."""
    enabled = [name.strip() for name in names.split(",")]
    text = f'permitted_providers = ["{permitted.strip()}"]\n'
    text += "".join(_provider_table(n) for n in enabled)
    config = tmp_path / "config.toml"
    config.write_text(text)
    monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))

    stubs = {name: StubProvider(name) for name in enabled}
    monkeypatch.setattr(server, "build_providers", lambda _config, _client: stubs)
    return stubs


@then(parsers.parse("the error names {name} as not permitted"))
def the_error_names_a_refusal(result: types.CallToolResult, name: str) -> None:
    assert f"Provider '{name}' is not permitted on this server" in _text(result)


@then(parsers.parse("the error names {name} as permitted"))
def the_error_names_the_permitted_set(result: types.CallToolResult, name: str) -> None:
    assert f"Permitted: {name}" in _text(result)


@then(parsers.parse('the agent retries with provider "{provider}" and the search runs'))
def the_agent_retries_and_the_search_runs(
    result: types.CallToolResult, provider: str, providers: dict[str, StubProvider]
) -> None:
    """Recovery in one call: the refusal named the permitted set, so the retry
    it suggests works without a second failure."""
    retry = _call_search({"query": "sqlite wal mode", "provider": provider})

    assert not retry.is_error, _text(retry)
    assert json.loads(_text(retry))["provider"] == provider
    assert providers[provider].calls == 1
