"""The failure rows every HTTP adapter owes, driven straight off the contract.

``docs/reference/provider-contract.md``'s Failures table is the promise, and until
now nothing checked it as a unit: each adapter's own test file asserted its own
copy of the same rows, so the suite carried the duplication without the shared
guarantee, and an adapter that skipped a row skipped it silently -- ``serper`` and
``linkup`` had no auth, HTTP-status, timeout, network-error or malformed-JSON test
at all. This module drives the table over every adapter, and it reads the table out
of the document instead of restating it, so the code and the contract cannot drift
in either direction: delete a row from the table and
``test_the_contract_document_still_lists_every_failure_row`` names it.

The quota row is required but not driven. Which statuses a backend answers with
"you have run out", and the sentence ``QuotaExhausted`` carries for it, are the
per-adapter quirks the table cannot parametrise; they stay in each
``tests/providers/test_<adapter>.py``. That split is the whole reason the mapping
itself was never collapsed into a shared helper (the 2026-10 refactor survey,
candidate 4).
"""

import re
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NamedTuple

import httpx
import pytest

from seekwright.models import SearchQuery
from seekwright.providers.algolia import AlgoliaProvider
from seekwright.providers.anysearch import AnysearchProvider
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.providers.deepseek import DeepSeekProvider
from seekwright.providers.freeserp import FreeserpProvider
from seekwright.providers.linkup import LinkupProvider
from seekwright.providers.parallel import ParallelProvider
from seekwright.providers.querit import QueritProvider
from seekwright.providers.scrappa import ScrappaProvider
from seekwright.providers.search1api import Search1ApiProvider
from seekwright.providers.searxng import SearxngProvider
from seekwright.providers.serpapi import SerpApiProvider
from seekwright.providers.serper import SerperProvider
from seekwright.providers.tavily import TavilyProvider
from seekwright.providers.tinyfish import TinyfishProvider

REPO = Path(__file__).resolve().parents[2]
CONTRACT = REPO / "docs" / "reference" / "provider-contract.md"
PROVIDER_DIR = REPO / "src" / "seekwright" / "providers"

# Never sent to anything real: it is the string a leak would carry.
# Redaction: the Failures section bans echoing an exception or a raw body.
KEY = "contract-probe-key-4c1f"

# The `>= 400` row's probes; `418` is a teapot no provider reserves.
# 402 and 429 stay out: what each adapter reads as quota is the quirks tests business.
OTHER_STATUSES = (400, 418, 500)

NON_OBJECT_BODIES: tuple[tuple[str, bytes], ...] = (
    ("empty-array", b"[]"),
    ("array-of-records", b'[{"title": "t", "url": "https://x"}]'),
    ("null", b"null"),
    ("number", b"42"),
    ("string", b'"a bare string"'),
)

# How a Signal cell is recognised. A row the map cannot name is a contract edit
# nobody reviewed, so it fails the run rather than passing quietly.
ROW_KEYS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("auth", re.compile(r"\b401\s*/\s*403\b")),
    ("quota", re.compile(r"\b402\s*/\s*429\b")),
    ("http", re.compile(r">=\s*400")),
    ("timeout", re.compile(r"httpx\.TimeoutException")),
    ("network", re.compile(r"httpx\.HTTPError")),
    ("malformed-json", re.compile(r"ValueError")),
    ("non-object", re.compile(r"not an object")),
)

# The six rows driven here, and the one row required to exist and left per adapter.
SHARED_ROWS = ("auth", "http", "timeout", "network", "malformed-json", "non-object")
QUIRK_ROWS = ("quota",)

# `exa_mcp` fronts an MCP tool, not an HTTP endpoint: it has no status line to map,
# and classifies the tool's error text instead. tests/providers/test_exa_tiers.py pins it.
NON_HTTP_MODULES = {"exa_mcp"}


@dataclass(frozen=True)
class Row:
    """One row of the contract's Failures table, as the test reads it."""

    key: str
    signal: str
    raises: str
    exception: type[ProviderError]
    message: str | None
    retryable: bool


def _failures_section() -> str:
    return CONTRACT.read_text().split("## Failures", 1)[1].split("\n## ", 1)[0]


def _failures_table() -> list[tuple[str, str]]:
    """The Failures table as (signal cell, raise cell), header and rule skipped."""
    lines = [line for line in _failures_section().splitlines() if line.startswith("|")]
    rows: list[tuple[str, str]] = []
    for line in lines[2:]:
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        assert len(cells) == 2, f"malformed row in the Failures table: {line!r}"
        rows.append((cells[0], cells[1]))
    return rows


def _parse_row(signal: str, raises: str) -> Row:
    key = next((name for name, pattern in ROW_KEYS if pattern.search(signal)), None)
    assert key is not None, (
        f"unrecognised Signal cell in the Failures table: {signal!r}"
    )
    quoted = re.search(r'"([^"]*)"', raises)
    wording = None if quoted is None or quoted.group(1) == "..." else quoted.group(1)
    return Row(
        key=key,
        signal=signal,
        raises=raises,
        exception=QuotaExhausted if "QuotaExhausted" in raises else ProviderError,
        # `...` in the quota row is the contract declining to fix the wording:
        # every backend words that failure after its own billing model.
        message=wording,
        retryable="retryable=False" not in raises,
    )


def _rows() -> dict[str, Row]:
    rows: dict[str, Row] = {}
    for signal, raises in _failures_table():
        row = _parse_row(signal, raises)
        rows[row.key] = row
    return rows


ROWS = _rows()

# Read from the paragraph under the table, so a new exemption is a reviewable doc
# edit.
NON_OBJECT_EXEMPT = {
    name for name in re.findall(r"`([a-z0-9_]+)` is the exception", _failures_section())
}


class Adapter(NamedTuple):
    """One HTTP adapter: its module, its provider name, and how to build it."""

    module: str
    name: str
    build: Callable[[httpx.AsyncClient], Any]
    auth_message: str | None = None


ADAPTERS: tuple[Adapter, ...] = (
    Adapter(
        "algolia",
        "algolia",
        lambda client: AlgoliaProvider(client, KEY, app_id="app123", index="products"),
    ),
    Adapter("anysearch", "anysearch", AnysearchProvider),
    Adapter("deepseek", "deepseek", lambda client: DeepSeekProvider(client, KEY)),
    Adapter("freeserp", "freeserp", FreeserpProvider),
    Adapter("linkup", "linkup", lambda client: LinkupProvider(client, KEY)),
    Adapter(
        "parallel",
        "parallel",
        lambda client: ParallelProvider(client, KEY, text_chars=500, timeout=10.0),
    ),
    Adapter("querit", "querit", lambda client: QueritProvider(client, KEY)),
    Adapter("scrappa", "scrappa", lambda client: ScrappaProvider(client, KEY)),
    Adapter("search1api", "search1api", lambda client: Search1ApiProvider(client, KEY)),
    Adapter(
        "searxng",
        "searxng",
        lambda client: SearxngProvider(client, url="https://searx.example/search"),
        # A locked-down instance can refuse the JSON format specifically, so this
        # adapter names what to fix in its auth message.
        auth_message="authentication rejected (enable `format=json` for this client)",
    ),
    Adapter("serpapi", "serpapi", lambda client: SerpApiProvider(client, KEY)),
    Adapter("serper", "serper", lambda client: SerperProvider(client, KEY)),
    Adapter("tavily", "tavily", lambda client: TavilyProvider(client, KEY)),
    Adapter("tinyfish", "tinyfish", lambda client: TinyfishProvider(client, KEY)),
)


Handler = Callable[[httpx.Request], httpx.Response]
Probe = tuple[str, Handler, str | None]


def _response(status: int, *, content: bytes | None = None) -> Handler:
    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(status, content=content if content is not None else b"{}")

    return handler


def _raising(exc: Exception) -> Handler:
    def handler(_: httpx.Request) -> httpx.Response:  # pragma: no cover - raises below
        raise exc

    return handler


def _probes(row: Row) -> list[Probe]:
    """(label, transport handler, expected message) driving one table row."""
    if row.key == "auth":
        return [
            (f"status {code}", _response(code), row.message)
            for code in (int(n) for n in re.findall(r"\d+", row.signal))
        ]
    if row.key == "http":
        return [
            (
                f"status {code}",
                _response(code),
                row.message.format(code=code) if row.message else None,
            )
            for code in OTHER_STATUSES
        ]
    if row.key == "timeout":
        timeout = _raising(httpx.ReadTimeout("read timed out"))
        return [("httpx read timeout", timeout, row.message)]
    if row.key == "network":
        # The message each of these carries names the key on purpose: the contract
        # is that none of it reaches the raised error.
        return [
            (
                "httpx connect error",
                _raising(httpx.ConnectError(f"connection refused, x-api-key: {KEY}")),
                row.message,
            ),
            (
                "httpx protocol error",
                _raising(httpx.ProtocolError(f"bad frame, key {KEY}")),
                row.message,
            ),
        ]
    if row.key == "malformed-json":
        return [
            (
                "html body",
                _response(200, content=b"<html>not json at all</html>"),
                row.message,
            ),
            (
                "html body quoting the key",
                _response(200, content=f"<html>upstream echoed {KEY}</html>".encode()),
                row.message,
            ),
        ]
    if row.key == "non-object":
        return [
            (label, _response(200, content=body), row.message)
            for label, body in NON_OBJECT_BODIES
        ]
    return []


def _where(adapter: Adapter, row: Row, label: str) -> str:
    return f"{adapter.name} [{row.key}: {label}]"


def _mismatches(
    adapter: Adapter,
    row: Row,
    label: str,
    exc: ProviderError,
    expected_message: str | None,
) -> list[str]:
    where = _where(adapter, row, label)
    problems: list[str] = []
    if isinstance(exc, QuotaExhausted) and row.exception is ProviderError:
        problems.append(f"{where}: raised QuotaExhausted, the table says ProviderError")
    elif not isinstance(exc, row.exception):
        problems.append(
            f"{where}: raised {type(exc).__name__}, "
            f"the table says {row.exception.__name__}"
        )
    if expected_message is not None and exc.message != expected_message:
        problems.append(
            f"{where}: message {exc.message!r}, "
            f"the table says {expected_message!r}"
        )
    if exc.retryable is not row.retryable:
        problems.append(
            f"{where}: retryable={exc.retryable}, "
            f"the table says retryable={row.retryable}"
        )
    if exc.provider != adapter.name:
        problems.append(f"{where}: provider names {exc.provider!r}")
    if KEY in str(exc):
        problems.append(f"{where}: the request key leaked into {str(exc)!r}")
    return problems


async def _row_problems(adapter: Adapter, row: Row) -> list[str]:
    """Every way one adapter departs from one row of the table."""
    exempt = adapter.name in NON_OBJECT_EXEMPT if row.key == "non-object" else False
    problems: list[str] = []
    for label, handler, message in _probes(row):
        if row.key == "auth" and adapter.auth_message is not None:
            message = adapter.auth_message
        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        where = _where(adapter, row, label)
        try:
            result = await adapter.build(client).search(
                SearchQuery(query="wal", max_results=3)
            )
        except ProviderError as exc:
            problems += _mismatches(adapter, row, label, exc, message)
        except Exception as exc:  # noqa: BLE001 - anything else escaped the mapping
            problems.append(
                f"{where}: raised {type(exc).__name__}, not a ProviderError"
            )
        else:
            if exempt:
                if result.results:
                    problems.append(
                        f"{where}: returned {len(result.results)} results where the"
                        " contract exempts this adapter to zero"
                    )
            elif message is not None:
                problems.append(
                    f"{where}: returned {len(result.results)} results "
                    "instead of failing"
                )
        finally:
            await client.aclose()
    return problems


def _driven_rows() -> list[Row]:
    return [ROWS[key] for key in SHARED_ROWS if key in ROWS]


def test_the_contract_document_still_lists_every_failure_row() -> None:
    missing = [key for key in (*SHARED_ROWS, *QUIRK_ROWS) if key not in ROWS]
    assert not missing, (
        "docs/reference/provider-contract.md's Failures table no longer lists: "
        + ", ".join(missing)
        + " -- either restore the row or update this module's row map with the decision"
    )


def test_the_adapter_set_covers_every_http_adapter_module() -> None:
    on_disk = {path.stem for path in PROVIDER_DIR.glob("*.py")}
    on_disk -= {"__init__", "base", *NON_HTTP_MODULES}
    driven = {adapter.module for adapter in ADAPTERS}
    assert on_disk == driven, (
        f"adapters on disk not driven here: {sorted(on_disk - driven)}; "
        f"driven but not on disk: {sorted(driven - on_disk)}"
    )


ADAPTER_IDS = [adapter.name for adapter in ADAPTERS]


@pytest.mark.parametrize("adapter", ADAPTERS, ids=ADAPTER_IDS)
async def test_every_adapter_honours_the_failure_rows(adapter: Adapter) -> None:
    problems = [
        problem
        for row in _driven_rows()
        for problem in await _row_problems(adapter, row)
    ]
    assert not problems, (
        f"\n{adapter.name} departs from the Failures table:\n" + "\n".join(problems)
    )


async def test_the_matrix_prints_one_row_per_adapter() -> None:
    """The same grid at once, so a red run shows which adapters broke on which row."""
    rows = _driven_rows()
    width = max(len(adapter.name) for adapter in ADAPTERS)
    grid = [
        f"{'adapter':<{width}}  " + "  ".join(f"{row.key:>14}" for row in rows)
    ]
    failures: list[str] = []
    for adapter in ADAPTERS:
        cells: list[str] = []
        for row in rows:
            problems = await _row_problems(adapter, row)
            failures += problems
            cells.append(("ok" if not problems else "FAIL").rjust(14))
        grid.append(f"{adapter.name:<{width}}  " + "  ".join(cells))
    print("\n".join(grid))
    assert not failures, "\n".join(grid) + "\n" + "\n".join(failures)
