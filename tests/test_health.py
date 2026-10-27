"""The health board, its probe, and the monitor that drives them.

The board is the interesting half: its state machine (closed -> open ->
half-open -> closed) decides which default-route fallbacks a search may use, so
every transition and every emission is pinned here. The probe is pinned to
its outcome mapping; the monitor to feeding the board and cancelling cleanly.
"""

import asyncio
import contextlib

import httpx
import pytest

from seekwright.config import (
    KNOWN_PROVIDERS,
    PROVIDERS_REQUIRING_KEY,
    Config,
    ProviderConfig,
    SearchConfig,
    api_key_env_var,
)
from seekwright.factory import build_providers
from seekwright.health import HealthBoard, HealthMonitor, ProbeOutcome, probe


def _events(records, name):
    """The extra fields of every record emitted for event ``name``."""
    return [r.record["extra"] for r in records if r.record["message"] == name]


class _UrlRecorder:
    """A transport handler that records the URL of every request it answers."""

    def __init__(self) -> None:
        self.urls: list[str] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.urls.append(str(request.url))
        return httpx.Response(200)

class TestHealthBoard:
    async def test_failures_below_the_threshold_stay_closed_and_silent(
        self, log_records
    ):
        board = HealthBoard(failure_threshold=2, cooldown_seconds=0.05)
        board.record_failure("serper", reason="upstream 503")

        assert board.is_open("serper") is False
        assert _events(log_records, "health.open") == []

    async def test_reaching_the_threshold_opens_once_with_its_fields(
        self, log_records
    ):
        board = HealthBoard(failure_threshold=2, cooldown_seconds=0.05)
        board.record_failure("serper", reason="upstream 503")
        board.record_failure("serper", reason="upstream 503")

        assert board.is_open("serper") is True
        assert _events(log_records, "health.open") == [
            {"provider": "serper", "reason": "upstream 503", "consecutive": 2}
        ]

    async def test_a_failure_while_open_extends_the_gate_without_relogging(
        self, log_records
    ):
        board = HealthBoard(failure_threshold=2, cooldown_seconds=60.0)
        board.record_failure("serper", reason="a")
        board.record_failure("serper", reason="b")
        board.record_failure("serper", reason="c")

        assert board.is_open("serper") is True
        assert [e["reason"] for e in _events(log_records, "health.open")] == ["b"]

    async def test_expiry_is_half_open_and_one_failure_reopens(self, log_records):
        board = HealthBoard(failure_threshold=2, cooldown_seconds=0.05)
        board.record_failure("serper", reason="a")
        board.record_failure("serper", reason="b")

        await asyncio.sleep(0.06)

        assert board.is_open("serper") is False, "an expired gate reads closed"

        board.record_failure("serper", reason="again")

        assert board.is_open("serper") is True
        assert len(_events(log_records, "health.open")) == 2
        assert _events(log_records, "health.open")[1]["reason"] == "again"

    async def test_half_open_reopens_without_the_threshold(self, log_records):
        """The re-open branch, isolated from the threshold: the count stays
        far below `failure_threshold` the whole time."""
        board = HealthBoard(failure_threshold=10, cooldown_seconds=0.05)
        board.record_failure("serper", reason="down", force_open=True)

        await asyncio.sleep(0.06)
        assert board.is_open("serper") is False

        board.record_failure("serper", reason="still down")

        assert board.is_open("serper") is True
        assert len(_events(log_records, "health.open")) == 2

    async def test_a_success_while_armed_closes_and_resets_the_count(
        self, log_records
    ):
        board = HealthBoard(failure_threshold=2, cooldown_seconds=60.0)
        board.record_failure("serper", reason="a")
        board.record_failure("serper", reason="b")
        board.record_success("serper", reason="search succeeded")

        assert board.is_open("serper") is False
        assert board.open_for_s("serper") == 0.0
        assert _events(log_records, "health.closed") == [
            {"provider": "serper", "reason": "search succeeded"}
        ]
        # The count was reset, so the threshold applies from zero again.
        board.record_failure("serper", reason="c")
        assert board.is_open("serper") is False
        board.record_failure("serper", reason="d")
        assert board.is_open("serper") is True

    async def test_a_success_on_a_never_armed_board_logs_nothing(self, log_records):
        board = HealthBoard()
        board.record_success("serper", reason="search succeeded")

        assert _events(log_records, "health.closed") == []
        assert _events(log_records, "health.open") == []

    async def test_force_open_opens_from_zero_failures(self, log_records):
        board = HealthBoard(failure_threshold=3, cooldown_seconds=60.0)
        board.record_failure("serper", reason="probe key rejected", force_open=True)

        assert board.is_open("serper") is True
        assert _events(log_records, "health.open") == [
            {"provider": "serper", "reason": "probe key rejected", "consecutive": 1}
        ]

    async def test_an_unknown_name_reads_closed(self):
        board = HealthBoard()

        assert board.is_open("serper") is False
        assert board.open_for_s("serper") == 0.0


class TestProbe:
    @staticmethod
    def client_with(handler) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(handler))

    async def test_a_200_with_a_key_is_reachable(self, monkeypatch):
        seen: dict[str, str | None] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["url"] = str(request.url)
            seen["auth"] = request.headers.get("X-API-KEY")
            return httpx.Response(200)

        monkeypatch.setenv("SEEKWRIGHT_SERPER_API_KEY", "k")
        cfg = Config(providers={"serper": ProviderConfig()})
        async with self.client_with(handler) as client:
            outcome = await probe("serper", client=client, config=cfg)

        assert outcome is ProbeOutcome.REACHABLE
        assert seen["url"] == "https://google.serper.dev/search"
        assert seen["auth"] == "k"

    async def test_a_200_without_a_key_is_reachable_no_key(self, monkeypatch):
        cfg = Config(
            providers={"searxng": ProviderConfig(url="http://searx.test:8080")}
        )
        async with self.client_with(
            lambda request: httpx.Response(200)
        ) as client:
            outcome = await probe("searxng", client=client, config=cfg)

        assert outcome is ProbeOutcome.REACHABLE_NO_KEY

    @pytest.mark.parametrize("status", [401, 403])
    async def test_an_auth_rejection_is_key_rejected(self, monkeypatch, status):
        monkeypatch.setenv("SEEKWRIGHT_SERPER_API_KEY", "k")
        cfg = Config(providers={"serper": ProviderConfig()})
        async with self.client_with(
            lambda request: httpx.Response(status)
        ) as client:
            outcome = await probe("serper", client=client, config=cfg)

        assert outcome is ProbeOutcome.KEY_REJECTED

    async def test_a_transport_error_is_unreachable(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_SERPER_API_KEY", "k")
        cfg = Config(providers={"serper": ProviderConfig()})

        def handler(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("no route")

        async with self.client_with(handler) as client:
            outcome = await probe("serper", client=client, config=cfg)

        assert outcome is ProbeOutcome.UNREACHABLE

    async def test_exa_is_unsupported_and_makes_no_request(self, monkeypatch):
        def handler(request: httpx.Request) -> httpx.Response:
            raise AssertionError("no request should be made")

        monkeypatch.setenv("SEEKWRIGHT_EXA_API_KEY", "k")
        cfg = Config(providers={"exa": ProviderConfig()})
        async with self.client_with(handler) as client:
            outcome = await probe("exa", client=client, config=cfg)

        assert outcome is ProbeOutcome.UNSUPPORTED

    async def test_parallel_probes_its_endpoint_with_the_key_header(
        self, monkeypatch
    ):
        seen: dict[str, str | None] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["url"] = str(request.url)
            seen["auth"] = request.headers.get("x-api-key")
            return httpx.Response(200)

        monkeypatch.setenv("SEEKWRIGHT_PARALLEL_API_KEY", "k")
        cfg = Config(providers={"parallel": ProviderConfig()})
        async with self.client_with(handler) as client:
            outcome = await probe("parallel", client=client, config=cfg)

        assert outcome is ProbeOutcome.REACHABLE
        assert seen["url"] == "https://api.parallel.ai/v1/search"
        assert seen["auth"] == "k"

    async def test_parallel_free_is_unsupported_and_makes_no_request(
        self, monkeypatch
    ):
        # It has `warmup`, so `--check` proves it by MCP handshake instead.
        def handler(request: httpx.Request) -> httpx.Response:
            raise AssertionError("no request should be made")

        monkeypatch.delenv("SEEKWRIGHT_PARALLEL_API_KEY", raising=False)
        cfg = Config(providers={"parallel:free": ProviderConfig()})
        async with self.client_with(handler) as client:
            outcome = await probe("parallel:free", client=client, config=cfg)

        assert outcome is ProbeOutcome.UNSUPPORTED

    async def test_searxng_builds_its_url_from_config(self, monkeypatch):
        seen: dict[str, str] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["url"] = str(request.url)
            return httpx.Response(200)

        monkeypatch.delenv("SEEKWRIGHT_SEARXNG_API_KEY", raising=False)
        cfg = Config(
            providers={"searxng": ProviderConfig(url="http://searx.internal:8080/")}
        )
        async with self.client_with(handler) as client:
            outcome = await probe("searxng", client=client, config=cfg)

        assert outcome is ProbeOutcome.REACHABLE_NO_KEY
        assert seen["url"] == "http://searx.internal:8080/search?q=probe&format=json"

    async def test_algolia_builds_its_config_endpoint_and_sends_both_headers(
        self, monkeypatch
    ):
        seen: dict[str, str | None] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["url"] = str(request.url)
            seen["app"] = request.headers.get("x-algolia-application-id")
            seen["key"] = request.headers.get("x-algolia-api-key")
            # A malformed hitsPerPage fails parameter validation, so a 400 proves
            # the path and spends no quota.
            return httpx.Response(400)

        monkeypatch.setenv("SEEKWRIGHT_ALGOLIA_API_KEY", "k")
        cfg = Config(
            providers={"algolia": ProviderConfig(app_id="app123", index="products")}
        )
        async with self.client_with(handler) as client:
            outcome = await probe("algolia", client=client, config=cfg)

        assert outcome is ProbeOutcome.REACHABLE
        assert seen["url"] == (
            "https://app123-dsn.algolia.net/1/indexes/products/query"
            "?query=probe&hitsPerPage=notanumber"
        )
        assert seen["app"] == "app123"
        assert seen["key"] == "k"

    async def test_algolia_without_a_key_is_key_required(self, monkeypatch):
        """Its key is mandatory on every tier, so a keyless probe would prove
        nothing: `build_providers` skips the provider and no search can reach
        it. `REACHABLE_NO_KEY` is a readiness report, and this is not one."""
        def handler(request: httpx.Request) -> httpx.Response:
            raise AssertionError("no request should be made")

        monkeypatch.delenv("SEEKWRIGHT_ALGOLIA_API_KEY", raising=False)
        cfg = Config(
            providers={"algolia": ProviderConfig(app_id="app123", index="products")}
        )
        async with self.client_with(handler) as client:
            outcome = await probe("algolia", client=client, config=cfg)

        assert outcome is ProbeOutcome.KEY_REQUIRED

    @pytest.mark.parametrize("name", sorted(PROVIDERS_REQUIRING_KEY - {"algolia"}))
    async def test_every_mandatory_key_provider_without_a_key_is_key_required(
        self, monkeypatch, name
    ):
        """The algolia shape swept across the set rather than fixed per
        adapter: a keyless probe of a provider that cannot be built keyless is
        not a readiness report whatever its backend is. Derived from
        `PROVIDERS_REQUIRING_KEY`, so a new mandatory-key name is covered by
        being added there -- and a new one needing more config than a name
        (algolia's `app_id`/`index`) fails here until it is handled too."""
        def handler(request: httpx.Request) -> httpx.Response:
            raise AssertionError("no request should be made")

        monkeypatch.delenv(f"SEEKWRIGHT_{name.upper()}_API_KEY", raising=False)
        cfg = Config(providers={name: ProviderConfig()})
        async with self.client_with(handler) as client:
            outcome = await probe(name, client=client, config=cfg)

        assert outcome is ProbeOutcome.KEY_REQUIRED

    async def test_algolia_with_a_bad_key_is_key_rejected(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_ALGOLIA_API_KEY", "bad")
        cfg = Config(
            providers={"algolia": ProviderConfig(app_id="app123", index="products")}
        )
        async with self.client_with(
            lambda request: httpx.Response(403)
        ) as client:
            outcome = await probe("algolia", client=client, config=cfg)

        assert outcome is ProbeOutcome.KEY_REJECTED


    async def test_the_table_covers_every_name_the_monitor_probes(
        self, monkeypatch
    ):
        """Every name the monitor hands to ``probe`` makes a request, and every
        name it does not -- the MCP-backed ones, verified by ``warmup``
        instead -- answers UNSUPPORTED without one.

        The split is derived rather than listed: ``build_providers`` says which
        names exist, and the monitor's own duck-type (has ``warmup``) says
        which of them ``probe`` is asked about. A provider added without a row
        in the table would read broken in ``--check`` --
        provider-contract.md's wiring point 5 -- and no per-name test would
        notice, because no test names a provider nobody added.
        """
        for name in KNOWN_PROVIDERS:
            monkeypatch.setenv(api_key_env_var(name), "k")
        cfg = Config(
            providers={
                name: ProviderConfig(
                    url="http://searx.test:8080",
                    app_id="app123",
                    index="products",
                )
                for name in KNOWN_PROVIDERS
            }
        )
        async with httpx.AsyncClient() as client:
            built = build_providers(cfg, client)
        probeable = {
            name
            for name, provider in built.items()
            if getattr(provider, "warmup", None) is None
        }

        for name in sorted(KNOWN_PROVIDERS):
            recorder = _UrlRecorder()
            async with self.client_with(recorder) as client:
                outcome = await probe(name, client=client, config=cfg)
            expect_request = name in probeable
            assert bool(recorder.urls) is expect_request, (
                f"{name}: probeable={expect_request}"
            )
            assert (outcome is ProbeOutcome.UNSUPPORTED) is not expect_request


class _HttpStub:
    """A provider without ``warmup``, so the monitor takes the probe path."""

    name = "stub"
    cost_per_1k = 0.0

    async def search(self, q):
        raise AssertionError("the monitor never searches")

    async def aclose(self) -> None:
        return None


class _WarmupStub(_HttpStub):
    """A provider whose handshake is the only thing the monitor can check."""

    def __init__(self, ok: bool) -> None:
        self._ok = ok

    async def warmup(self) -> bool:
        return self._ok


class TestHealthMonitor:
    async def test_the_monitor_feeds_the_board_and_cancels_cleanly(
        self, monkeypatch, log_records
    ):
        def handler(request: httpx.Request) -> httpx.Response:
            host = request.url.host
            if host == "api.linkup.so":
                raise httpx.ConnectError("no route")
            if host == "google.serper.dev":
                return httpx.Response(403)
            return httpx.Response(200)

        monkeypatch.setenv("SEEKWRIGHT_SERPER_API_KEY", "k")
        # linkup needs a key too, or the probe answers key_required, not the failure.
        # A mandatory-key provider is never probed keyless: build_providers drops it.
        monkeypatch.setenv("SEEKWRIGHT_LINKUP_API_KEY", "k")
        cfg = Config(
            providers={
                "searxng": ProviderConfig(url="http://searx.test:8080"),
                "serper": ProviderConfig(),
                "linkup": ProviderConfig(),
                "exa:free": ProviderConfig(),
            },
            search=SearchConfig(health_interval_seconds=0.01),
        )
        board = HealthBoard(failure_threshold=1, cooldown_seconds=60.0)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            monitor = HealthMonitor(
                config=cfg,
                providers={
                    "searxng": _HttpStub(),
                    "serper": _HttpStub(),
                    "linkup": _HttpStub(),
                    "exa:free": _WarmupStub(ok=False),
                },
                client=client,
                board=board,
            )
            task = asyncio.create_task(monitor.run())
            await asyncio.sleep(0.05)

            assert board.is_open("serper") is True, "a rejected key opens at once"
            assert board.is_open("linkup") is True, "unreachable trips threshold 1"
            assert board.is_open("exa:free") is True, "a failed warmup feeds the board"
            assert board.is_open("searxng") is False, "reachable stays closed"

            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

        assert task.done()
        assert _events(log_records, "health.closed") == []
