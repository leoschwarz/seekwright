"""Executable spec for `fetch` on a delimited table, run against the real server.

``csv_table.feature`` in this directory is written from the agent's side of the
wire: the MCP tool, the engine's shape read and -- where the disk page cache is
on -- the one-download promise behind the shape-then-drill idiom, applied to a
CSV body instead of a JSON document. The page the stub hands over is
`tabledoc`'s rendering of a five-row table, which is what a real extraction
backend produces from a ``text/csv`` response; the unit tests in ``tests/fetch/``
each see one segment of that trip.

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
from seekwright.tabledoc import render_table

scenarios("csv_table.feature")

URL = "https://example.com/orders.csv"

CSV = (
    "id,price,city,qty,note\n"
    "1,12.50,London,3,four\n"
    "2,7.00,Leeds,11,short\n"
    "3,3.99,Bristol,2,x\n"
    "4,120.00,Perth,1,long note here\n"
    "5,0.50,Cork,7,\n"
)

PROSE = (
    "The harbour at low tide is a wide plain of mud and weed, crossed by the "
    "tracks of wading birds and not by anything a caller could address as a "
    "row. The price of the morning's fish is settled on the quay, in conversation."
)


def _rendered() -> str:
    text = render_table(CSV, delimiter=",")
    assert text is not None, "a test fixture that is not a table"
    return text


class Endpoint:
    """The fetch stack reduced to counting: one answer, one call at a time.

    It stands in for ``HttpFetcher`` -- ``build_fetch_stack`` is replaced the
    way ``build_providers`` is in ``test_provider_selection.py`` -- so the page
    the scenarios read is whatever the given step hands it: a table rendering
    with ``text/csv`` behind it, path-addressable as a real backend's extraction
    is, or a prose page that is neither.
    """

    def __init__(
        self, *, rendering: str, path_addressable: bool, content_type: str
    ) -> None:
        self.calls = 0
        self.rendering = rendering
        self.path_addressable = path_addressable
        self.content_type = content_type

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        self.calls += 1
        return FetchedPage(
            url=url,
            title="Orders",
            text=self.rendering,
            content_type=self.content_type,
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
def a_table_endpoint(kind: str, monkeypatch, tmp_path) -> Endpoint:
    """The stack is a counting stub; the cache is real, from a config file.

    The page cache is what makes the one-download assertion meaningful: the
    rendering fills the entry on the shape read, and the drill serves from it.
    Without `cache_dir` the second read is a second dispatch by design, so the
    config the scenario writes is the operator's act of turning the cache on.
    """
    if kind == "a CSV table":
        engine = Endpoint(
            rendering=_rendered(), path_addressable=True, content_type="text/csv"
        )
    elif kind == "prose":
        engine = Endpoint(
            rendering=PROSE, path_addressable=False, content_type="text/plain"
        )
    else:
        raise ValueError(f"unknown fixture kind: {kind}")
    config = tmp_path / "config.toml"
    config.write_text(f'[fetch]\ncache_dir = "{tmp_path / "pages"}"\n')
    monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))
    monkeypatch.setattr(server, "build_fetch_stack", _endpoint_stack(engine))
    return engine


def _endpoint_stack(engine: Endpoint):
    """`build_fetch_stack` replaced: the stack is the counting stub and no fallbacks."""

    async def build(_config):
        return engine, []

    return build


@when("the agent fetches the file", target_fixture="result")
def fetching_the_file() -> types.CallToolResult:
    return _call_fetch({"url": URL})


@when("the agent fetches its shape", target_fixture="result")
def fetching_shape() -> types.CallToolResult:
    return _call_fetch({"url": URL, "structure": True})


@when("the agent drills into one column the shape named", target_fixture="result")
def drilling_into_price() -> types.CallToolResult:
    return _call_fetch({"url": URL, "path": "$.rows[*].price"})


@then("the response text names every row and its price column")
def the_table_arrives_labelled(result: types.CallToolResult) -> None:
    text = _text(result)
    assert "$.rows  array(5)" in text
    assert "$.rows[0].price" in text
    assert "$.rows[4].price" in text


@then("the response carries no notice")
def no_notice(result: types.CallToolResult) -> None:
    assert _envelope(result).get("notice") is None


@then("the shape names the columns and no cell value")
def the_shape_names_columns(result: types.CallToolResult) -> None:
    text = _text(result)
    assert "$.rows[*]  object(5)" in text
    assert "$.rows[*].price  string" in text
    assert "12.50" not in text
    assert "London" not in text


@then("the drill returns one line per row")
def one_line_per_row(result: types.CallToolResult) -> None:
    matches = _envelope(result)["matches"]
    assert isinstance(matches, list)
    lines = [match["text"] for match in matches if isinstance(match, dict)]
    assert lines == [
        '$.rows[0].price  "12.50"',
        '$.rows[1].price  "7.00"',
        '$.rows[2].price  "3.99"',
        '$.rows[3].price  "120.00"',
        '$.rows[4].price  "0.50"',
    ]


@then("the endpoint behind the page was asked for only once")
def one_download(endpoint: Endpoint) -> None:
    assert endpoint.calls == 1


@then("the response text is the prose itself")
def the_prose_is_untouched(result: types.CallToolResult, endpoint: Endpoint) -> None:
    assert _envelope(result)["text"] == endpoint.rendering


@then("the notice says the page is not one this server could read as either")
def the_notice_names_the_refusal(result: types.CallToolResult) -> None:
    assert "not one this server could read as either" in _text(result)
