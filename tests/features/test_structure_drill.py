"""Executable spec for the `fetch` structure view, run against the real server.

``structure_drill.feature`` in this directory is written from the agent's side
of the wire: the MCP tool, the engine's one-axis rule and -- where the disk
page cache is on -- the one-download promise behind the shape-then-drill
idiom, in one trip. The unit tests in ``tests/fetch/`` each see one segment of
that.

Steps are synchronous on purpose (pytest-bdd calls them directly; an
``async def`` step slides past ``asyncio_mode = "auto"`` un-awaited). The one
async span runs inside a single ``asyncio.run`` per step.
"""

import asyncio
import json

from mcp import Client, types
from pytest_bdd import given, parsers, scenarios, then, when

from seekwright import server
from seekwright.fetcher import FetchedPage
from seekwright.jsondoc import render_json

scenarios("structure_drill.feature")

URL = "https://example.com/data.json"


def _rendered(doc: str) -> str:
    text = render_json(doc)
    assert text is not None, "a test fixture that is not a document"
    return text


class Endpoint:
    """The fetch stack reduced to counting: one answer, one call at a time.

    It stands in for ``HttpFetcher`` -- ``build_fetch_stack`` is replaced the
    way ``build_providers`` is in ``test_provider_selection.py`` -- so the page
    the scenarios read is whatever the given step hands it, rendered and
    path-addressable, as a JSON body arrives from a real extraction backend.
    """

    def __init__(self, *, rendering: str, path_addressable: bool) -> None:
        self.calls = 0
        self.rendering = rendering
        self.path_addressable = path_addressable

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        self.calls += 1
        return FetchedPage(
            url=url,
            title="Data",
            text=self.rendering,
            content_type="text/plain",
            status_code=200,
            truncated=False,
            total_chars=len(self.rendering),
            path_addressable=self.path_addressable,
        )

    async def aclose(self) -> None:
        return None


def _text(result: types.CallToolResult) -> str:
    """The first text block, which carries the response serialised on the wire.

    The fetch tool answers with one text block holding the ``FetchResponse`` as
    JSON -- the same body the REST projection would print -- plus the parsed
    structured content a typed client reads. This spec reads what a plain
    client would display and parses the envelope itself.
    """
    for block in result.content:
        if isinstance(block, types.TextContent):
            return block.text
    return ""


def _envelope(result: types.CallToolResult) -> dict[str, object]:
    return json.loads(_text(result))


def _call_fetch(arguments: dict[str, object]) -> types.CallToolResult:
    async def run() -> types.CallToolResult:
        async with Client(server.mcp) as client:
            return await client.call_tool("fetch", arguments)

    return asyncio.run(run())


@given(
    parsers.parse("a server whose fetch endpoint answers {kind}"),
    target_fixture="endpoint",
)
def a_json_endpoint(kind: str, monkeypatch, tmp_path) -> Endpoint:
    """The stack is a counting stub; the cache is real, from a config file.

    The page cache is what makes the one-download assertion meaningful: the
    rendering fills the entry on the shape read, and the drill serves from it.
    Without `cache_dir` the second read is a second dispatch by design, so the
    config the scenario writes is the operator's act of turning the cache on.
    """
    if kind == "a JSON document":
        rendering = _rendered(
            """{"meta": {"count": 2}, "rows": [{"id": 1, "name": "walrus"},
            {"id": 2, "name": "narwhal"}], "next": null}"""
        )
        engine = Endpoint(rendering=rendering, path_addressable=True)
    elif kind == "prose":
        engine = Endpoint(
            rendering=(
                "The walrus (Odobenus rosmarus) is a large pinniped mammal of the "
                " Arctic. Its tusks, blubber and whiskers are all adaptations to a "
                " life spent hauled out on ice floes, and none of it is structured "
                " data no matter how eagerly the caller asks for a shape."
            ),
            path_addressable=False,
        )
    else:
        raise ValueError(f"unknown fixture kind: {kind}")
    config = tmp_path / "config.toml"
    config.write_text(
        f'[fetch]\ncache_dir = "{tmp_path / "pages"}"\n'
    )
    monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))
    monkeypatch.setattr(server, "build_fetch_stack", _endpoint_stack(engine))
    return engine


def _endpoint_stack(engine: Endpoint):
    """`build_fetch_stack` replaced: the stack is the counting stub and no fallbacks."""

    async def build(_config):
        return engine, []

    return build


@when("the agent fetches its shape", target_fixture="result")
def fetching_shape() -> types.CallToolResult:
    return _call_fetch({"url": URL, "structure": True})


@when(
    "the agent fetches its shape with `path` set too",
    target_fixture="result",
)
def fetching_shape_and_drill() -> types.CallToolResult:
    return _call_fetch({"url": URL, "structure": True, "path": "$.rows[*].id"})


@when(
    parsers.parse('the agent drills into the field the shape named'),
    target_fixture="result",
)
def drilling() -> types.CallToolResult:
    return _call_fetch({"url": URL, "path": "$.rows[*].id"})


@then("the response text names each array and object with its size")
def the_shape_names_sizes(result: types.CallToolResult) -> None:
    text = _text(result)
    assert "$.rows  array(2)" in text
    assert "$.meta  object(1)" in text


@then("the response text never carries a value from the document")
def the_shape_carries_no_values(result: types.CallToolResult) -> None:
    text = _text(result)
    assert "walrus" not in text
    assert "narwhal" not in text


@then("the drill returns the match at that path")
def the_drill_returns_matches(result: types.CallToolResult) -> None:
    text = _text(result)
    assert "$.rows[0].id" in text
    assert "$.rows[1].id" in text


@then("the endpoint behind the page was asked for only once")
def one_download(endpoint: Endpoint) -> None:
    assert endpoint.calls == 1


@then("the endpoint behind the page was never asked for")
def no_download(endpoint: Endpoint) -> None:
    assert endpoint.calls == 0


@then(parsers.parse("the call comes back as an error naming {word}"))
def error_names_the_axis(result: types.CallToolResult, word: str) -> None:
    assert result.is_error
    assert word in _text(result)


@then("the response text is the prose itself")
def the_prose_is_untouched(result: types.CallToolResult, endpoint: Endpoint) -> None:
    assert _envelope(result)["text"] == endpoint.rendering


@then("the notice says the page is not one this server could read as JSON")
def the_notice_names_the_refusal(result: types.CallToolResult) -> None:
    assert "not one this server could read as JSON" in _text(result)
