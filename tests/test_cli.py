"""CLI (`--check`, `--metrics`, dispatch, the three client subcommands) tests."""

import asyncio
import json
import sys
import threading
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Self, override

import pytest

from seekwright import cli
from seekwright.config import Config, DashboardConfig, ProviderConfig
from seekwright.fetcher import KNOWN_FALLBACKS, Fallback
from seekwright.health import ProbeOutcome
from seekwright.models import (
    AnswerRequest,
    FetchRequest,
    ProviderResult,
    Result,
    SearchQuery,
    SearchRequest,
)
from seekwright.usage import UsageRecorder


class StubProvider:
    """Minimal stand-in for a SearchProvider with the surface cli needs.

    ``mcp=True`` mimics the exa adapter (exposes ``warmup``); HTTP-like stubs
    don't, so the connectivity probe path is exercised too.
    """

    def __init__(
        self, name: str = "stub", *, reachable: bool = True, mcp: bool = False
    ) -> None:
        self.name = name
        self.cost_per_1k = 1.0
        self._reachable = reachable
        self.searches: list[SearchQuery] = []
        if mcp:
            self.warmup = self._warmup  # type: ignore[attr-defined]

    async def _warmup(self) -> bool:
        return self._reachable

    async def search(self, q: SearchQuery) -> ProviderResult:
        self.searches.append(q)
        return ProviderResult(
            provider=self.name,
            results=[Result(title="t", url="https://example.com")],
            cost_usd=0.001,
        )

    async def aclose(self) -> None:
        return None


def make_config(names: list[str], default: str | None = None) -> Config:
    return Config(
        providers={name: ProviderConfig() for name in names},
        default_provider=default,
    )


async def _reachable(*_args, **_kwargs) -> str:
    return "reachable"


async def async_unreachable(*_args, **_kwargs) -> str:
    return "unreachable"


class TestCheck:
    def test_all_ready(self, monkeypatch, capsys):
        cfg = make_config(["serper", "exa"], default="serper")
        monkeypatch.setattr(
            cli,
            "build_providers",
            lambda _cfg, _client: {
                "serper": StubProvider("serper"),
                "exa": StubProvider("exa", mcp=True),
            },
        )
        monkeypatch.setattr(cli, "_probe_http", _reachable)

        assert cli.check(config=cfg) == 0
        out = capsys.readouterr().out
        assert "2 of 2 enabled providers ready" in out
        assert "MCP handshake ok" in out
        assert "default     serper" in out

    def test_missing_keys_name_the_env_var(self, monkeypatch, capsys):
        cfg = make_config(["serper", "linkup"])
        # Real build_providers with no keys in the env returns nothing.
        monkeypatch.setattr(cli, "build_providers", lambda _cfg, _client: {})

        assert cli.check(config=cfg) == 1
        out = capsys.readouterr().out
        assert "SEEKWRIGHT_SERPER_API_KEY" in out
        assert "no providers ready" in out

    def test_a_flavoured_names_line_names_its_backend_var(self, monkeypatch, capsys):
        """`--check` prints the variable an operator has to export, and a
        flavoured name's is its backend's -- `SEEKWRIGHT_EXA:FREE_API_KEY` is
        not a name any shell can export."""
        cfg = make_config(["exa:free"])
        monkeypatch.setattr(cli, "build_providers", lambda _cfg, _client: {})

        assert cli.check(config=cfg) == 1
        out = capsys.readouterr().out
        assert "SEEKWRIGHT_EXA_API_KEY" in out
        assert "SEEKWRIGHT_EXA:FREE_API_KEY" not in out

    def test_no_default_is_stated(self, monkeypatch, capsys):
        """Two enabled providers and no default means callers must choose."""
        cfg = make_config(["serper", "linkup"])
        monkeypatch.setattr(cli, "build_providers", lambda _cfg, _client: {})
        cli.check(config=cfg)
        assert "callers must pass provider" in capsys.readouterr().out

    def test_a_free_only_deployment_says_the_bare_search_walks_the_free_set(
        self, monkeypatch, capsys
    ):
        """The other half of the same line: with no default *and* nothing that
        can bill, an unnamed search is served rather than refused."""
        cfg = make_config(["exa:free", "parallel:free"])
        assert cfg.default_provider is None
        monkeypatch.setattr(cli, "build_providers", lambda _cfg, _client: {})

        cli.check(config=cfg)

        assert "a bare search walks the free set" in capsys.readouterr().out

    def test_an_implicit_set_is_reported_like_an_explicit_one(
        self, monkeypatch, capsys
    ):
        """A config that enables nothing is checked exactly as a written one is.

        Same rows, same ready tally -- the only extra line is the one saying the
        set was chosen for the operator, which is what keeps the defaulting from
        being silent.
        """
        stubs = {
            name: StubProvider(name, mcp=True)
            for name in ("exa:free", "parallel:free", "freeserp")
        }
        monkeypatch.setattr(cli, "build_providers", lambda _cfg, _client: stubs)

        implicit = Config()
        assert implicit.providers_defaulted is True
        cli.check(config=implicit)
        implicit_out = capsys.readouterr().out

        explicit = Config(
            providers={
                "exa:free": ProviderConfig(),
                "parallel:free": ProviderConfig(),
                "freeserp": ProviderConfig(),
            }
        )
        assert explicit.providers_defaulted is False
        cli.check(config=explicit)
        explicit_out = capsys.readouterr().out

        assert "implicit" in implicit_out
        assert "exa:free" in implicit_out and "parallel:free" in implicit_out
        assert "freeserp" in implicit_out
        assert "3 of 3 enabled providers ready" in implicit_out
        assert "implicit" not in explicit_out
        without_marker = [
            line for line in implicit_out.splitlines() if "implicit" not in line
        ]
        assert without_marker == explicit_out.splitlines()

    def test_live_probes_each_ready_provider(self, monkeypatch, capsys):
        cfg = make_config(["serper", "exa"], default="serper")
        serper = StubProvider("serper")
        exa = StubProvider("exa", mcp=True)
        monkeypatch.setattr(
            cli,
            "build_providers",
            lambda _cfg, _client: {"serper": serper, "exa": exa},
        )
        monkeypatch.setattr(cli, "_probe_http", _reachable)

        assert cli.check(config=cfg, live=True) == 0
        out = capsys.readouterr().out
        assert "live probes" in out
        assert len(serper.searches) == 1
        assert len(exa.searches) == 1
        assert serper.searches[0].max_results == 1

    def test_unreachable_provider_is_a_problem(self, monkeypatch, capsys):
        cfg = make_config(["serper"])
        monkeypatch.setattr(
            cli,
            "build_providers",
            lambda _cfg, _client: {"serper": StubProvider("serper")},
        )
        monkeypatch.setattr(cli, "_probe_http", async_unreachable)

        assert cli.check(config=cfg) == 1
        out = capsys.readouterr().out
        assert "unreachable" in out
        assert "no providers ready" in out

    def test_a_keyless_provider_with_a_proven_path_is_ready(self, monkeypatch, capsys):
        """searxng has no key, so the probe reports the keyless status;
        the network path being up is what ready means for it."""

        async def _no_key(*_args, **_kwargs) -> str:
            return "reachable (no key sent)"

        cfg = Config(
            providers={"searxng": ProviderConfig(url="http://searx.test:8080")}
        )
        monkeypatch.setattr(
            cli,
            "build_providers",
            lambda _cfg, _client: {"searxng": StubProvider("searxng")},
        )
        monkeypatch.setattr(cli, "_probe_http", _no_key)

        assert cli.check(config=cfg) == 0
        assert "1 of 1 enabled providers ready" in capsys.readouterr().out

    def test_a_rejected_key_is_a_problem_even_when_reachable(
        self, monkeypatch, capsys
    ):
        async def _rejected(*_args, **_kwargs) -> str:
            return "reachable, but API key rejected"

        cfg = make_config(["serper"])
        monkeypatch.setattr(
            cli,
            "build_providers",
            lambda _cfg, _client: {"serper": StubProvider("serper")},
        )
        monkeypatch.setattr(cli, "_probe_http", _rejected)

        assert cli.check(config=cfg) == 1
        assert "reachable, but API key rejected" in capsys.readouterr().out

    def test_a_missing_mandatory_key_is_not_a_ready_provider(
        self, monkeypatch, capsys
    ):
        """The key_required status is a problem, never readiness -- a provider
        that cannot be built without its key is not a provider `--check` may
        call ready."""

        async def _key_required(*_args, **_kwargs) -> str:
            return cli._PROSE[ProbeOutcome.KEY_REQUIRED]

        cfg = Config(
            providers={"algolia": ProviderConfig(app_id="app123", index="products")}
        )
        monkeypatch.setattr(
            cli,
            "build_providers",
            lambda _cfg, _client: {"algolia": StubProvider("algolia")},
        )
        monkeypatch.setattr(cli, "_probe_http", _key_required)

        assert cli.check(config=cfg) == 1
        out = capsys.readouterr().out
        assert "no API key (key is mandatory)" in out
        assert "no providers ready" in out

    def test_every_probe_outcome_has_prose(self):
        """`_PROSE` is read on the diagnostic path, which is the one place that
        must not raise: a new outcome without an entry would be a KeyError in
        `--check` rather than a report."""
        assert set(cli._PROSE) == set(ProbeOutcome)

    def test_disabled_provider_is_not_probed(self, monkeypatch, capsys):
        cfg = Config(
            providers={
                "serper": ProviderConfig(),
                "linkup": ProviderConfig(enabled=False),
            },
            default_provider="serper",
        )
        monkeypatch.setattr(
            cli,
            "build_providers",
            lambda _cfg, _client: {"serper": StubProvider("serper")},
        )
        monkeypatch.setattr(cli, "_probe_http", _reachable)

        assert cli.check(config=cfg) == 0
        assert "1 of 1 enabled providers ready" in capsys.readouterr().out


class TestCheckFetchFallbacks:
    """The fetch section reports each configured fallback's presence or absence.

    Reported, never counted as a problem: fetch works without any fallback, and a
    degraded ladder is never the reason a search would fail.
    """

    @staticmethod
    def make_config(**fetch_kw):
        from seekwright.config import FetchConfig

        cfg = make_config(["serper"], default="serper")
        cfg.fetch = FetchConfig(**fetch_kw)
        return cfg

    def run(self, monkeypatch, cfg, probe="reachable"):
        # A ready provider so the return code reflects only the fetch section.
        monkeypatch.setattr(
            cli, "build_providers", lambda _c, _cl: {"serper": StubProvider("serper")}
        )
        monkeypatch.setattr(cli, "_probe_http", _reachable)

        async def fake_probe(_cfg, _url):
            return probe

        monkeypatch.setattr(cli, "_probe_renderer", fake_probe)
        return cli.check(config=cfg)

    def test_a_ladder_without_crawl4ai_url_says_so(self, monkeypatch, capsys):
        cfg = self.make_config(fallback=["crawl4ai"])

        assert self.run(monkeypatch, cfg) == 0
        assert "(inactive: no fetch.crawl4ai_url)" in capsys.readouterr().out

    def test_a_reachable_renderer_is_reported(self, monkeypatch, capsys):
        cfg = self.make_config(
            fallback=["crawl4ai"], crawl4ai_url="http://int-crawl4ai:11235"
        )

        assert self.run(monkeypatch, cfg) == 0
        out = capsys.readouterr().out
        assert "fallback  crawl4ai" in out
        assert "reachable" in out

    def test_an_unreachable_renderer_is_not_a_problem(self, monkeypatch, capsys):
        cfg = self.make_config(
            fallback=["crawl4ai"], crawl4ai_url="http://int-crawl4ai:11235"
        )

        assert self.run(monkeypatch, cfg, probe="unreachable") == 0
        assert "unreachable" in capsys.readouterr().out

    def test_scrappa_reports_its_key_state(self, monkeypatch, capsys):
        cfg = self.make_config(fallback=["scrappa"])
        monkeypatch.delenv("SEEKWRIGHT_SCRAPPA_API_KEY", raising=False)
        monkeypatch.setattr(
            cli, "build_providers", lambda _c, _cl: {"serper": StubProvider("serper")}
        )
        monkeypatch.setattr(cli, "_probe_http", _reachable)

        assert cli.check(config=cfg) == 0
        assert "(inactive: no API key)" in capsys.readouterr().out

        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")
        assert cli.check(config=cfg) == 0
        assert "keyed" in capsys.readouterr().out

    def test_no_fallback_prints_no_fallback_lines(self, monkeypatch, capsys):
        cfg = self.make_config()

        assert self.run(monkeypatch, cfg) == 0
        out = capsys.readouterr().out
        assert "fallback" not in out
        assert "crawl4ai" not in out

    def test_the_extraction_backend_is_reported(self, monkeypatch, capsys):
        """The library is an install fact, so `--check` is where a missing extra
        is visible without starting the server."""
        cfg = self.make_config()

        assert self.run(monkeypatch, cfg) == 0
        assert "extractor trafilatura" in capsys.readouterr().out

    def test_a_backend_without_a_pdf_parser_says_so(self, monkeypatch, capsys):
        """The PDF parser left the core install, so building the
        backend no longer implies carrying it. A note, not a problem: `fetch`
        still reads HTML, which is why the exit code stays 0."""
        from seekwright.extractors.base import HTML_TYPES, TEXT_TYPES

        class NoPdfBackend:
            name = "trafilatura"
            supported_types = HTML_TYPES | TEXT_TYPES

        monkeypatch.setattr(cli, "build_extractor", lambda _cfg: NoPdfBackend())
        cfg = self.make_config()

        assert self.run(monkeypatch, cfg) == 0
        out = capsys.readouterr().out
        assert "extractor trafilatura" in out
        assert "pdf       not read" in out

    def test_the_backend_with_no_pdf_to_install_says_so(self, monkeypatch, capsys):
        """The standard-library backend has no PDF reader to lose, so
        the note has to name the backend as well as the extra that carries one."""
        cfg = self.make_config(extractor="stdlib")

        assert self.run(monkeypatch, cfg) == 0
        out = capsys.readouterr().out
        assert "extractor stdlib" in out
        assert "pdf       not read: the stdlib backend reads no PDF" in out

    def test_a_missing_backend_library_is_a_problem(self, monkeypatch, capsys):
        """Unlike an inert fallback: fetch is enabled, so this *is* why fetch fails."""
        from seekwright.factory import ExtractorUnavailable

        def unavailable(_cfg):
            raise ExtractorUnavailable("no trafilatura installed")

        monkeypatch.setattr(cli, "build_extractor", unavailable)
        cfg = self.make_config()

        assert self.run(monkeypatch, cfg) == 1
        out = capsys.readouterr().out
        assert "extractor trafilatura  UNAVAILABLE: no trafilatura installed" in out

    def test_the_ladder_order_is_shown(self, monkeypatch, capsys):
        cfg = self.make_config(
            fallback=["crawl4ai", "scrappa"],
            crawl4ai_url="http://int-crawl4ai:11235",
        )

        assert self.run(monkeypatch, cfg) == 0
        assert "crawl4ai -> scrappa" in capsys.readouterr().out

    def test_the_keyless_fallback_reports_itself(self, monkeypatch, capsys):
        """`jina` needs nothing, so its only inert state is the allow-list's --
        which is why the line says `keyless` rather than naming a credential."""
        cfg = self.make_config(fallback=["jina"])

        assert self.run(monkeypatch, cfg) == 0
        out = capsys.readouterr().out
        assert "  jina      keyless" in out
        assert "no API key" not in out

    def test_the_three_fallback_ladder_is_shown_in_order(self, monkeypatch, capsys):
        cfg = self.make_config(
            fallback=["crawl4ai", "jina", "scrappa"],
            crawl4ai_url="http://int-crawl4ai:11235",
        )

        assert self.run(monkeypatch, cfg) == 0
        assert "crawl4ai -> jina -> scrappa" in capsys.readouterr().out

    def test_every_fallback_in_the_registry_prints_exactly_one_row(
        self, monkeypatch, capsys
    ):
        """The report reads `fetcher.KNOWN_FALLBACKS`, so it names a fallback it has never
        heard of. The acceptance line -- a fallback is one module, one
        registry entry, one name in `fetch.fallback` -- was false in the CLI until
        the report read the registry: a fallback the `if/elif` chain did not name
        printed no state at all.
        The fake row is what a fourth fallback costs, and the free fallbacks are listed
        first because the billable one belongs last. The registry has held three
        priced rows and `FetchConfig` admits one per ladder, so the
        walk is one ladder per priced fallback and every row is asserted in a ladder it
        sits in."""
        monkeypatch.setitem(
            KNOWN_FALLBACKS,
            "acme",
            Fallback(
                name="acme",
                billable=False,
                endpoint=None,
                fetch_key="acme_url",
                build=lambda _cfg: None,
            ),
        )
        free = [name for name, row in KNOWN_FALLBACKS.items() if not row.billable]
        for billable in (name for name, row in KNOWN_FALLBACKS.items() if row.billable):
            ladder = [*free, billable]
            cfg = self.make_config(
                fallback=ladder, crawl4ai_url="http://int-crawl4ai:11235"
            )

            assert self.run(monkeypatch, cfg) == 0
            out = capsys.readouterr().out
            for name in ladder:
                rows = [
                    line for line in out.splitlines() if line.startswith(f"  {name:<9} ")
                ]
                assert len(rows) == 1, f"{name} prints one status row:\n{out}"
            assert "  acme      (inactive: no fetch.acme_url)" in out

    def test_a_fallback_named_for_a_provider_reports_its_key_state(
        self, monkeypatch, capsys
    ):
        """Which fallback is keyed comes from the registry's own credential rule -- a
        fallback named for a provider reads that provider's key -- and not from a name
        written into `cli.py`, so a fallback added to the registry says which key is
        missing and says `keyed` once the environment has it."""
        monkeypatch.setitem(
            KNOWN_FALLBACKS,
            "tinyfish",
            Fallback(
                name="tinyfish",
                billable=True,
                endpoint="https://api.tinyfish.ai/v1/search",
                build=lambda _cfg: None,
            ),
        )
        monkeypatch.delenv("SEEKWRIGHT_TINYFISH_API_KEY", raising=False)
        cfg = self.make_config(fallback=["jina", "tinyfish"])

        assert self.run(monkeypatch, cfg) == 0
        out = capsys.readouterr().out
        assert "  tinyfish  (inactive: no API key)" in out
        assert "  jina      keyless" in out

        monkeypatch.setenv("SEEKWRIGHT_TINYFISH_API_KEY", "k")
        assert self.run(monkeypatch, cfg) == 0
        assert "  tinyfish  keyed" in capsys.readouterr().out

    def test_a_fallback_named_for_a_keyless_provider_names_no_missing_key(
        self, monkeypatch, capsys
    ):
        """Which fallback has a credential is the config's own census of the names that
        do, not membership in the provider-name set: `searxng` is a provider name
        with no key, so a fallback named for it dials a host with no credential that
        could be missing."""
        monkeypatch.setitem(
            KNOWN_FALLBACKS,
            "searxng",
            Fallback(
                name="searxng",
                billable=False,
                endpoint="https://searx.example.org/search",
                build=lambda _cfg: None,
            ),
        )
        cfg = self.make_config(fallback=["searxng"])

        assert self.run(monkeypatch, cfg) == 0
        out = capsys.readouterr().out
        assert "  searxng   keyless" in out
        assert "no API key" not in out

    def test_a_fallback_outside_the_permission_set_reports_itself(
        self, monkeypatch, capsys
    ):
        """The allow-list gate is asked of the row, so it reaches a fallback the
        hand-written chain never named: an unpermitted fallback is not built, and the
        report is the only place that says so. The row dials a
        constant, which is the only shape the permission set gates: a
        configured-by-URL row is pinned by the test below instead."""
        from seekwright.config import FetchConfig

        monkeypatch.setitem(
            KNOWN_FALLBACKS,
            "acme",
            Fallback(
                name="acme",
                billable=False,
                endpoint="https://api.acme.test/v1/read",
                build=lambda _cfg: None,
            ),
        )
        cfg = Config(
            providers={"serper": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["serper"],
            fetch=FetchConfig(enabled=True, fallback=["acme"]),
        )

        assert self.run(monkeypatch, cfg) == 0
        assert "  acme      (inactive: not permitted)" in capsys.readouterr().out

    def test_a_declared_permission_set_leaves_the_self_hosted_fallback_reported(
        self, monkeypatch, capsys
    ):
        """`permitted_providers` is a set over provider names, and a
        configured-by-URL fallback is not one: the loader refuses `crawl4ai` there, and
        `_build_crawl4ai` never asks the set. A report that asked it anyway called
        a live renderer inert while fetch still routed through it, and pointed the
        operator at a fix the config refuses."""
        from pydantic import ValidationError

        from seekwright.config import KNOWN_PROVIDERS, FetchConfig
        from seekwright.factory import build_fetch_stack

        cfg = Config(
            providers={"serper": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["serper"],
            fetch=FetchConfig(
                enabled=True,
                fallback=["crawl4ai"],
                crawl4ai_url="http://int-crawl4ai:11235",
            ),
        )

        assert self.run(monkeypatch, cfg) == 0
        out = capsys.readouterr().out
        assert "  crawl4ai  reachable" in out
        assert "(inactive: not permitted)" not in out

        # The report is right because the ladder builds the fallback it just printed.
        _local, fallbacks = asyncio.run(build_fetch_stack(cfg))
        try:
            assert [type(fallback).__name__ for fallback in fallbacks] == ["Crawl4aiFetcher"]
        finally:
            for fallback in fallbacks:
                asyncio.run(fallback.aclose())

        # And the wrong line had no answer an operator could apply: the loader
        # refuses any name outside the provider set, so `permitted_providers` can
        # never admit a self-hosted fallback.
        assert "crawl4ai" not in KNOWN_PROVIDERS
        with pytest.raises(ValidationError, match="unknown provider"):
            Config(
                providers={"serper": ProviderConfig()},
                default_provider="serper",
                permitted_providers=["serper", "crawl4ai"],
            )

    # The two keyed fallbacks go inert the `scrappa` way -- a provider name, a key in the
    # environment, and the permission set over that name -- so the report gives them
    # Scrappa's two states instead of inventing new ones.
    @staticmethod
    def fallback_lines(capsys, fallback: str) -> list[str]:
        """The report's lines for one fallback, so no assertion reads another fallback's state."""
        return [
            line
            for line in capsys.readouterr().out.splitlines()
            if line.startswith(f"  {fallback}")
        ]

    @pytest.mark.parametrize("fallback", ["tavily", "linkup"])
    def test_a_keyed_fallback_without_its_key_reports_itself(self, monkeypatch, capsys, fallback):
        monkeypatch.delenv(f"SEEKWRIGHT_{fallback.upper()}_API_KEY", raising=False)
        cfg = self.make_config(fallback=[fallback])

        assert self.run(monkeypatch, cfg) == 0
        assert self.fallback_lines(capsys, fallback) == [f"  {fallback:<9} (inactive: no API key)"]

    @pytest.mark.parametrize("fallback", ["tavily", "linkup"])
    def test_a_keyed_fallback_with_its_key_reports_keyed(self, monkeypatch, capsys, fallback):
        monkeypatch.setenv(f"SEEKWRIGHT_{fallback.upper()}_API_KEY", "k")
        cfg = self.make_config(fallback=[fallback])

        assert self.run(monkeypatch, cfg) == 0
        assert self.fallback_lines(capsys, fallback) == [f"  {fallback:<9} keyed"]

    @pytest.mark.parametrize("fallback", ["tavily", "linkup"])
    def test_a_keyed_fallback_the_allow_list_excludes_reports_itself(
        self, monkeypatch, capsys, fallback
    ):
        """The fallback asks for no new permission, so the set that gates its `search` gates it."""
        monkeypatch.setenv(f"SEEKWRIGHT_{fallback.upper()}_API_KEY", "k")
        cfg = self.make_config(fallback=[fallback])
        cfg.permitted_providers = ["serper"]

        assert self.run(monkeypatch, cfg) == 0
        assert self.fallback_lines(capsys, fallback) == [
            f"  {fallback:<9} (inactive: not permitted)"
        ]


class TestCheckAllowList:
    """`--check` prints the permitted set beside the enabled set.

    The declared list under `permitted`, and the intersection under `effective`
    when the allow-list actually narrows something -- which is the actionable
    fact, since those are providers the operator turned on that can never be
    dispatched. Both lines are additions: every existing line keeps its text
    and its place (docs/reference/allow-list.md).
    """

    @staticmethod
    def run(monkeypatch, cfg, capsys):
        # A stub per enabled provider, so the return code reflects only what is
        # under test here.
        monkeypatch.setattr(
            cli,
            "build_providers",
            lambda c, _cl: {n: StubProvider(n) for n in c.enabled_providers()},
        )
        monkeypatch.setattr(cli, "_probe_http", _reachable)
        code = cli.check(config=cfg)
        return code, capsys.readouterr().out

    def test_the_declared_set_is_printed_under_permitted(self, monkeypatch, capsys):
        cfg = Config(
            providers={"serper": ProviderConfig(), "linkup": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["serper"],
        )

        code, out = self.run(monkeypatch, cfg, capsys)

        assert code == 0
        assert "permitted   serper\n" in out
        assert (
            "effective   1 of 2 enabled providers permitted; "
            "not permitted: linkup" in out
        )

    def test_the_order_the_operator_wrote_is_the_order_printed(
        self, monkeypatch, capsys
    ):
        cfg = Config(
            providers={"serper": ProviderConfig(), "exa:free": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["exa:free", "serper"],
        )

        _, out = self.run(monkeypatch, cfg, capsys)

        assert "permitted   exa:free, serper\n" in out
        assert "effective" not in out, "the sets are equal, so there is nothing to say"

    def test_unset_prints_the_marker_and_no_effective_line(self, monkeypatch, capsys):
        cfg = make_config(["serper"], default="serper")

        code, out = self.run(monkeypatch, cfg, capsys)

        assert code == 0
        assert "permitted   (unset: every enabled provider)\n" in out
        assert "effective" not in out

    def test_a_wildcard_list_prints_the_same_marker(self, monkeypatch, capsys):
        """One state, one rendering: `"*"` *is* the unset state, so neither an
        implementer nor a test has to choose between two strings."""
        cfg = Config(
            providers={"serper": ProviderConfig()}, permitted_providers=["*"]
        )

        _, out = self.run(monkeypatch, cfg, capsys)

        assert "permitted   (unset: every enabled provider)\n" in out
        assert "effective" not in out

    def test_an_unpermitted_fetch_fallback_reports_itself(self, monkeypatch, capsys):
        """`scrappa` is a provider name, so the allow-list can make the fallback
        inert the way a missing key does -- in the existing `(inactive: …)`
        shape, which is how this report already explains an inert fallback."""
        from seekwright.config import FetchConfig

        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")
        cfg = Config(
            providers={"serper": ProviderConfig(), "scrappa": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["serper"],
            fetch=FetchConfig(enabled=True, fallback=["scrappa"]),
        )

        code, out = self.run(monkeypatch, cfg, capsys)

        assert code == 0, "an inert fallback is reported, never counted as a problem"
        assert "  scrappa   (inactive: not permitted)" in out
        assert "keyed" not in out

    def test_an_unpermitted_keyless_fallback_reports_itself(self, monkeypatch, capsys):
        """The keyless fallback is a third party too, so the allow-list reaches it
        -- and since `jina` is not a provider name, declaring *any* set is what
        makes it inert. This line is the only place that is said out loud."""
        from seekwright.config import FetchConfig

        cfg = Config(
            providers={"serper": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["serper"],
            fetch=FetchConfig(enabled=True, fallback=["jina"]),
        )

        code, out = self.run(monkeypatch, cfg, capsys)

        assert code == 0, "an inert fallback is reported, never counted as a problem"
        assert "  jina      (inactive: not permitted)" in out
        assert "  jina      keyless" not in out

    def test_a_permitted_keyless_fallback_reports_keyless(self, monkeypatch, capsys):
        """The other half of the line above: a declared set that names `jina`
        admits it, so the row leaves the `(inactive: not permitted)` state and
        prints the keyless one -- admitting it enables nothing else."""
        from seekwright.config import FetchConfig

        cfg = Config(
            providers={"serper": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["serper", "jina"],
            fetch=FetchConfig(enabled=True, fallback=["jina"]),
        )

        code, out = self.run(monkeypatch, cfg, capsys)

        assert code == 0
        assert "  jina      keyless" in out
        assert "(inactive: not permitted)" not in out

    def test_the_default_primary_reports_the_local_reader(self, monkeypatch, capsys):
        """The default route is stated rather than implied: an operator reading
        the report learns that an unnamed fetch reads from this server's own IP,
        which is the fact `fetch.primary` exists to let them change."""
        cfg = make_config(["serper"], default="serper")

        code, out = self.run(monkeypatch, cfg, capsys)

        assert code == 0
        assert "  primary   http (the local reader)\n" in out

    def test_an_unbuildable_primary_is_reported_as_a_problem(
        self, monkeypatch, capsys
    ):
        """Unlike an inert fallback, an unbuilt primary is fatal: the server
        refuses to start rather than read from its own IP unasked, so `--check`
        must make the run fail -- otherwise the exit code says the box is fine
        and it is not. `jina` under a declared set is that state."""
        from seekwright.config import FetchConfig

        cfg = Config(
            providers={"serper": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["serper"],
            fetch=FetchConfig(primary="jina", fallback=["jina"]),
        )

        code, out = self.run(monkeypatch, cfg, capsys)

        assert code != 0, "an unbuildable primary is why the server will not start"
        assert "  primary   jina (inactive: not permitted)" in out

    def test_no_api_key_value_reaches_the_report(self, monkeypatch, capsys):
        """Both new lines print provider *names*: `--check`'s one promise is
        that it never bills, and its other one is that it never leaks."""
        secret = "sk-live-secret-9f3a2b"
        monkeypatch.setenv("SEEKWRIGHT_SERPER_API_KEY", secret)
        cfg = Config(
            providers={"serper": ProviderConfig(), "linkup": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["serper"],
        )

        _, out = self.run(monkeypatch, cfg, capsys)

        assert "permitted   serper\n" in out and "effective" in out
        assert secret not in out

    def test_a_live_probe_skips_an_unpermitted_provider(self, monkeypatch, capsys):
        """`--live` makes a *real search*, so it is a dispatch the allow-list
        refuses: an excluded provider is reported and never called, because
        otherwise the line saying it is excluded would sit directly above a
        billed search against it. The reachability probe still ran -- it sends
        no query and cannot bill."""
        cfg = Config(
            providers={"serper": ProviderConfig(), "linkup": ProviderConfig()},
            default_provider="serper",
            permitted_providers=["serper"],
        )
        serper, linkup = StubProvider("serper"), StubProvider("linkup")
        monkeypatch.setattr(
            cli,
            "build_providers",
            lambda _cfg, _client: {"serper": serper, "linkup": linkup},
        )
        monkeypatch.setattr(cli, "_probe_http", _reachable)

        assert cli.check(config=cfg, live=True) == 0
        out = capsys.readouterr().out

        assert len(serper.searches) == 1, "the permitted provider is still probed"
        assert linkup.searches == [], "the excluded provider is never dispatched"
        assert "  linkup    skipped: not permitted\n" in out
        assert "effective   1 of 2 enabled providers permitted; " in out


class TestCheckAgent:
    """The `agent` section of the report.

    Agent mode is the one section whose incompleteness is *fatal at startup*, so
    `--check` counts it as a problem -- the operator sees what is missing without
    the server dying to tell them, which is the whole point of the command. A
    disabled section is never a problem, and a model endpoint is never probed: a
    probe would be a call on the operator's account.
    """

    @staticmethod
    def make_config(**agent_kw) -> Config:
        from seekwright.config import AgentConfig

        cfg = make_config(["serper"], default="serper")
        cfg.agent = AgentConfig(**agent_kw)
        return cfg

    def run(self, monkeypatch, cfg):
        # A ready provider, so the return code reflects only the agent section.
        monkeypatch.setattr(
            cli, "build_providers", lambda _c, _cl: {"serper": StubProvider("serper")}
        )
        monkeypatch.setattr(cli, "_probe_http", _reachable)
        return cli.check(config=cfg)

    def test_off_by_default_and_not_a_problem(self, monkeypatch, capsys):
        cfg = self.make_config()

        assert self.run(monkeypatch, cfg) == 0
        out = capsys.readouterr().out
        assert "agent" in out
        assert "disabled in config" in out

    def test_enabled_but_incomplete_names_every_missing_piece(
        self, monkeypatch, capsys
    ):
        monkeypatch.delenv("SEEKWRIGHT_AGENT_API_KEY", raising=False)
        cfg = self.make_config(enabled=True)

        assert self.run(monkeypatch, cfg) == 1
        out = capsys.readouterr().out
        assert "enabled but incomplete" in out
        assert "agent.base_url" in out
        assert "agent.model" in out
        assert "SEEKWRIGHT_AGENT_API_KEY" in out

    def test_a_complete_section_names_the_model_and_the_endpoint(
        self, monkeypatch, capsys
    ):
        monkeypatch.setenv("SEEKWRIGHT_AGENT_API_KEY", "sk")
        cfg = self.make_config(
            enabled=True, base_url="https://model.test/v1", model="test-model"
        )

        assert self.run(monkeypatch, cfg) == 0
        out = capsys.readouterr().out
        assert "test-model" in out
        assert "https://model.test/v1" in out


class TestMetrics:
    """``--metrics``: the journal-only report.

    Nothing here may build a provider, reach the network or bill anything, so
    every test drives the reporter through an injected ``Config`` -- the one
    ``--check`` already accepts for the same reason.
    """

    @staticmethod
    def make_config(journal: Path | None = None, *, enabled: bool = True) -> Config:
        return Config(
            providers={"serper": ProviderConfig()},
            dashboard=DashboardConfig(
                enabled=enabled,
                history_path=str(journal) if journal is not None else None,
            ),
        )

    @staticmethod
    def write_journal(path: Path, lines: list[dict[str, object]]) -> None:
        path.write_text(
            "".join(json.dumps(line) + "\n" for line in lines), encoding="utf-8"
        )

    @staticmethod
    def search_line(
        day: str,
        *,
        provider: str = "serper",
        ms: int = 10,
        cost_usd: float = 0.001,
        fell_back: bool = False,
        error: str | None = None,
        clock: str = "09:00:00.000000",
    ) -> dict[str, object]:
        return {
            "ts": f"{day}T{clock}+00:00",
            "tool": "search",
            "provider": provider,
            "ms": ms,
            "cost_usd": cost_usd,
            "results": 1,
            "fell_back": fell_back,
            "error": error,
        }

    @staticmethod
    def days_ago(offset: int) -> str:
        return (datetime.now(UTC).date() - timedelta(days=offset)).isoformat()

    def test_the_report_prints_the_window_and_one_row_per_provider(
        self, tmp_path, capsys
    ):
        journal = tmp_path / "usage.jsonl"
        self.write_journal(
            journal,
            [
                self.search_line(self.days_ago(1), ms=401, cost_usd=0.0036),
                self.search_line(
                    self.days_ago(0),
                    ms=300,
                    cost_usd=0.0,
                    error="ProviderTimeout",
                    clock="10:00:00.000000",
                ),
                self.search_line(
                    self.days_ago(0), ms=1204, cost_usd=0.0031, clock="11:00:00.000000"
                ),
            ],
        )

        assert cli.metrics(config=self.make_config(journal)) == 0
        out = capsys.readouterr().out
        lines = out.splitlines()

        assert "seekwright metrics" in out
        assert "window      14 days," in out
        assert f"journal     {journal}  ok" in out

        header = next(line for line in lines if line.startswith("provider"))
        # The contract is the labels and their order; the widths are derived, so
        # this reads positions rather than comparing a padded string.
        positions = [header.index(label) for label in cli._METRIC_COLUMNS]
        assert positions == sorted(positions)

        row = next(line for line in lines if line.startswith("serper"))
        assert row.split() == [
            "serper",
            "3",  # calls: every terminal line, failures included
            "1",  # errors
            "0",  # fellback
            "2",  # samples: the failure is not a latency sample
            "401",  # p50 over [401, 1204]
            "1204",  # p95
            "802",  # mean, truncated
            "0.0067",  # cost over all three lines
            "2.2333",  # measured $/1k
            f"{datetime.now(UTC).date().isoformat()}T11:00:00Z",
        ]

    def test_a_null_percentile_is_a_dash_never_a_zero(self, tmp_path, capsys):
        """A provider whose only call fell back has no latency to report.

        Zero milliseconds reads as "instant"; the dash reads as "nothing to
        measure", which is the honest one.
        """
        journal = tmp_path / "usage.jsonl"
        self.write_journal(
            journal,
            [self.search_line(self.days_ago(0), ms=900, fell_back=True)],
        )

        assert cli.metrics(config=self.make_config(journal)) == 0
        row = next(
            line
            for line in capsys.readouterr().out.splitlines()
            if line.startswith("serper")
        )

        assert row.split() == [
            "serper",
            "1",
            "0",
            "1",
            "0",
            "—",
            "—",
            "—",
            "0.0010",
            "1.0000",
            f"{datetime.now(UTC).date().isoformat()}T09:00:00Z",
        ]

    def test_json_is_the_object_the_route_serves(self, tmp_path, capsys):
        """One document, one source: the terminal and the browser cannot drift.

        ``tests/test_server.py`` pins the route to this same
        ``snapshot()["endpoints"]`` key, so equality here is equality with the
        route body.
        """
        journal = tmp_path / "usage.jsonl"
        self.write_journal(
            journal,
            [
                self.search_line(self.days_ago(2), ms=120),
                self.search_line(self.days_ago(0), provider="exa:free", ms=80),
            ],
        )

        assert cli.metrics(as_json=True, config=self.make_config(journal)) == 0
        printed = json.loads(capsys.readouterr().out)

        served = UsageRecorder(history_path=str(journal)).snapshot()["endpoints"]
        assert printed == served
        assert printed["window_days"] == 14
        assert [p["provider"] for p in printed["providers"]] == ["exa:free", "serper"]

    def test_no_journal_and_an_empty_window_still_reports(self, capsys):
        assert cli.metrics(config=self.make_config()) == 0
        out = capsys.readouterr().out

        assert "off — dashboard.history_path unset" in out
        assert "no history" in out

    def test_a_journal_with_nothing_in_the_window_says_no_history(
        self, tmp_path, capsys
    ):
        journal = tmp_path / "usage.jsonl"
        # Outside the fourteen-day window: on disk, deliberately not reported.
        self.write_journal(journal, [self.search_line(self.days_ago(30))])

        assert cli.metrics(config=self.make_config(journal)) == 0
        assert "no history" in capsys.readouterr().out

    def test_dashboard_enabled_does_not_gate_it(self, tmp_path, capsys):
        """That key gates the HTTP page; the report is a different surface."""
        journal = tmp_path / "usage.jsonl"
        self.write_journal(journal, [self.search_line(self.days_ago(0))])

        assert cli.metrics(config=self.make_config(journal, enabled=False)) == 0
        out = capsys.readouterr().out
        assert "serper" in out
        assert "no history" not in out

    def test_a_missing_parent_directory_is_the_servers_startup_error(
        self, tmp_path, monkeypatch
    ):
        """Reported identically to `server.py`'s own pre-flight, and exits 1.

        A string ``SystemExit`` code is what prints the message and exits 1, so
        the assertion is on the message the operator sees.
        """
        cfg = self.make_config(tmp_path / "gone" / "usage.jsonl")
        monkeypatch.setattr(cli, "load_config", lambda: cfg)

        with pytest.raises(SystemExit) as exc:
            cli.main(["--metrics"])

        assert str(exc.value.code).startswith("seekwright: dashboard.history_path:")
        assert "parent directory does not exist" in str(exc.value.code)

    def test_an_unwritable_journal_is_the_servers_startup_error(
        self, tmp_path, monkeypatch
    ):
        journal = tmp_path / "usage.jsonl"
        journal.touch()
        cfg = self.make_config(journal)
        monkeypatch.setattr(cli, "load_config", lambda: cfg)

        def boom(*_args: object, **_kwargs: object) -> None:
            raise PermissionError(13, "Permission denied", str(journal))

        monkeypatch.setattr(Path, "open", boom)

        with pytest.raises(SystemExit) as exc:
            cli.main(["--metrics"])

        assert str(exc.value.code).startswith("seekwright: dashboard.history_path:")
        assert "not writable" in str(exc.value.code)

    def test_the_report_never_imports_the_server(self, tmp_path, monkeypatch):
        """No FastMCP app, no providers, no handshake -- just the journal."""
        journal = tmp_path / "usage.jsonl"
        self.write_journal(journal, [self.search_line(self.days_ago(0))])
        monkeypatch.delitem(sys.modules, "seekwright.server", raising=False)

        assert cli.metrics(config=self.make_config(journal)) == 0
        assert "seekwright.server" not in sys.modules


class TestDispatch:
    def test_check_dispatch_exits_with_return_code(self, monkeypatch):
        calls: dict[str, bool] = {}

        def fake_check(
            *, live: bool = False, config=None, log_level=None, log_format=None
        ) -> int:
            calls["live"] = live
            return 3

        monkeypatch.setattr(cli, "check", fake_check)
        with pytest.raises(SystemExit) as exc:
            cli.main(["--check"])
        assert exc.value.code == 3
        assert calls["live"] is False

    def test_live_requires_check(self):
        with pytest.raises(SystemExit) as exc:
            cli.main(["--live"])
        assert exc.value.code == 2

    def test_json_requires_metrics(self):
        """A companion flag, exactly as `--live` is a companion to `--check`."""
        with pytest.raises(SystemExit) as exc:
            cli.main(["--json"])
        assert exc.value.code == 2

    @pytest.mark.parametrize(
        "argv",
        [
            ["--metrics", "--check"],
            ["--metrics", "--live"],
            ["--metrics", "--http"],
            ["--metrics", "--host", "0.0.0.0"],
            ["--metrics", "--port", "9000"],
            ["--metrics", "--allowed-host", "search.internal:*"],
        ],
    )
    def test_metrics_serves_nothing_so_it_combines_with_nothing(self, argv):
        """Report-and-exit: it never serves, so it takes no serving flag."""
        with pytest.raises(SystemExit) as exc:
            cli.main(argv)
        assert exc.value.code == 2

    def test_metrics_dispatch_exits_with_return_code(self, monkeypatch):
        calls: dict[str, bool] = {}

        def fake_metrics(
            *, as_json: bool = False, config=None, log_level=None, log_format=None
        ) -> int:
            calls["as_json"] = as_json
            return 4

        monkeypatch.setattr(cli, "metrics", fake_metrics)
        with pytest.raises(SystemExit) as exc:
            cli.main(["--metrics", "--json"])
        assert exc.value.code == 4
        assert calls["as_json"] is True


class TestTransportDispatch:
    """What reaches ``server.main``. The transport is chosen here and nowhere else."""

    @pytest.fixture
    def spy(self, monkeypatch):
        calls: dict[str, object] = {}
        from seekwright import server

        monkeypatch.setattr(server, "main", lambda **kw: calls.update(kw))
        return calls

    def test_bare_invocation_is_stdio(self, spy):
        cli.main([])
        assert spy["http"] is False

    def test_http_defaults_to_loopback(self, spy):
        """0.0.0.0 is a thing the operator asks for, never a default."""
        cli.main(["--http"])
        assert spy["http"] is True
        assert spy["host"] == "127.0.0.1"
        assert spy["port"] == 8000
        assert spy["allowed_hosts"] == []

    def test_http_flags_are_passed_through(self, spy):
        cli.main(
            [
                "--http",
                "--host",
                "0.0.0.0",
                "--port",
                "9000",
                "--allowed-host",
                "search.internal:*",
                "--allowed-host",
                "100.64.0.1:9000",
            ]
        )
        assert spy["host"] == "0.0.0.0"
        assert spy["port"] == 9000
        assert spy["allowed_hosts"] == ["search.internal:*", "100.64.0.1:9000"]

    @pytest.mark.parametrize(
        "argv",
        [["--host", "0.0.0.0"], ["--port", "9000"], ["--allowed-host", "x"]],
    )
    def test_http_only_flags_require_http(self, argv):
        """Silently binding stdio while ignoring --host would be the bad outcome."""
        with pytest.raises(SystemExit) as exc:
            cli.main(argv)
        assert exc.value.code == 2


class TestCheckStreams:
    """`--check` prints a report; the server logs. The two must not mix."""

    def test_the_report_stays_on_stdout(self, capfd, monkeypatch, tmp_path):
        cfg = tmp_path / "config.toml"
        cfg.write_text('[providers."exa:free"]\nenabled = true\n')
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(cfg))
        async def probes(*_args, **_kwargs):
            return (["  exa:free  reachable"], 1, 0)

        monkeypatch.setattr(cli, "_probe_all", probes)

        cli.check()

        captured = capfd.readouterr()
        assert "seekwright check" in captured.out
        # Not an empty stderr -- a library warning during a probe legitimately
        # lands there. What matters is that the report itself does not.
        assert "seekwright check" not in captured.err

    def test_log_flags_are_accepted_and_forwarded(self, monkeypatch):
        seen: dict[str, object] = {}

        def fake_check(*, live=False, config=None, log_level=None, log_format=None):
            seen.update(log_level=log_level, log_format=log_format)
            return 0

        monkeypatch.setattr(cli, "check", fake_check)
        with pytest.raises(SystemExit):
            cli.main(["--check", "--log-level", "DEBUG", "--log-format", "json"])

        assert seen == {"log_level": "DEBUG", "log_format": "json"}

    def test_an_unknown_level_is_rejected_by_argparse(self):
        with pytest.raises(SystemExit) as exc:
            cli.main(["--log-level", "LOUD"])
        assert exc.value.code == 2


class StubServer:
    """A stubbed HTTP server for the two REST routes, on a loopback socket.

    A socket rather than a patched transport, because what these tests are for
    is the client *as it ships*: the URL it builds, the body it sends, the
    status it reads back. Nothing here reaches a provider, reads a key or
    leaves the machine -- the response is whatever the test handed it.
    """

    def __init__(
        self, *, status: int = 200, body: str | dict[str, object] | None = None
    ) -> None:
        self.status = status
        self.body = body
        # One entry per request received: path, headers, decoded body.
        self.requests: list[dict[str, object]] = []
        server = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length)
                server.requests.append(
                    {
                        "path": self.path,
                        "headers": {key.lower(): value for key, value in self.headers.items()},
                        "body": json.loads(raw) if raw else None,
                    }
                )
                encoded = server.response_text().encode("utf-8")
                self.send_response(server.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            @override
            def log_message(self, format: str, *args: object) -> None:
                """Silenced: a test's output is its assertions."""

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    def response_text(self) -> str:
        if isinstance(self.body, str):
            return self.body
        return json.dumps(self.body if self.body is not None else {})

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self._server.server_port}"

    def __enter__(self) -> Self:
        self._thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self._server.shutdown()
        self._server.server_close()


def run_cli(*argv: str) -> int:
    """Run `cli.main` and hand back its exit code -- every path exits."""
    with pytest.raises(SystemExit) as exc:
        cli.main(list(argv))
    return int(exc.value.code or 0)


def search_payload(**overrides: object) -> dict[str, object]:
    """A `SearchResponse` body, with one SERP result and one content result.

    Both shapes are here on purpose: a provider fills `snippet` or `text`, never
    both, so a render that only knows one of them drops half the providers.
    """
    payload: dict[str, object] = {
        "query": "test query",
        "provider": "exa:free",
        "results": [
            {"title": "First", "url": "https://first.test/", "snippet": "first snippet"},
            {"title": "Second", "url": "https://second.test/", "text": "second text"},
        ],
        "retrieved_at": "2026-10-14T05:00:00+00:00",
    }
    payload.update(overrides)
    return payload


def fetch_payload(**overrides: object) -> dict[str, object]:
    """A `FetchResponse` body: one page, no redirect, nothing truncated."""
    payload: dict[str, object] = {
        "url": "https://example.test/page",
        "requested_url": "https://example.test/page",
        "title": "Example Domain",
        "text": "the page text",
        "content_type": "text/html",
        "status_code": 200,
        "retrieved_at": "2026-10-14T05:00:00+00:00",
        "truncated": False,
        "total_chars": 13,
    }
    payload.update(overrides)
    return payload


def answer_payload(**overrides: object) -> dict[str, object]:
    """An `AnswerResponse` body: prose, the two sources it cited, no notice."""
    payload: dict[str, object] = {
        "query": "test query",
        "answer": "It scatters [1], and it is not the moon [2].",
        "sources": [
            {"title": "First", "url": "https://first.test/", "provider": "exa:free"},
            {"title": "Second", "url": "https://second.test/", "provider": "serper"},
        ],
        "model": "test-model",
        "depth": "brief",
        "searches": 1,
        "fetched": 0,
        "retrieved_at": "2026-10-14T05:00:00+00:00",
    }
    payload.update(overrides)
    return payload


class TestClientSearch:
    """`seekwright search` against a stubbed server: body, render, `--json`."""

    def test_the_body_is_the_search_request_model(self):
        with StubServer(body=search_payload()) as server:
            assert (
                run_cli(
                    "search",
                    "--server",
                    server.url,
                    "--provider",
                    "exa:free",
                    "--max-results",
                    "3",
                    "--include-domain",
                    "a.test",
                    "--include-domain",
                    "b.test",
                    "--exclude-domain",
                    "c.test",
                    "--recency",
                    "week",
                    "test query",
                )
                == 0
            )

        assert len(server.requests) == 1
        assert server.requests[0]["path"] == "/api/v1/search"
        sent = server.requests[0]["body"]
        assert sent == {
            "query": "test query",
            "provider": "exa:free",
            "max_results": 3,
            "include_domains": ["a.test", "b.test"],
            "exclude_domains": ["c.test"],
            "recency": "week",
        }
        # The same model the server validates with, so the two cannot disagree.
        assert SearchRequest.model_validate(sent).provider == "exa:free"

    def test_unset_flags_are_absent_from_the_body_not_null(self):
        """`WireModel`'s rule on the way out too: the server reads a body with
        no `provider` key, never one carrying `provider: null`."""
        with StubServer(body=search_payload()) as server:
            assert run_cli("search", "--server", server.url, "test query") == 0

        assert server.requests[0]["body"] == {"query": "test query", "max_results": 5}

    def test_the_default_output_is_for_a_person(self, capsys):
        with StubServer(body=search_payload()) as server:
            assert run_cli("search", "--server", server.url, "test query") == 0

        out = capsys.readouterr().out
        assert "seekwright search" in out
        assert "query     test query" in out
        # The routing answer: which provider actually answered.
        assert "provider  exa:free" in out
        assert "1. First" in out
        assert "   https://first.test/" in out
        assert "first snippet" in out
        # A content backend fills `text` where a SERP fills `snippet`.
        assert "2. Second" in out
        assert "second text" in out

    def test_a_notice_is_printed(self, capsys):
        with StubServer(
            body=search_payload(notice="include_domains ignored by exa:free")
        ) as server:
            assert run_cli("search", "--server", server.url, "test query") == 0

        assert "notice: include_domains ignored by exa:free" in capsys.readouterr().out

    def test_zero_results_is_a_success_with_nothing_to_list(self, capsys):
        with StubServer(body=search_payload(results=[])) as server:
            assert run_cli("search", "--server", server.url, "test query") == 0

        out = capsys.readouterr().out
        assert "results   0" in out
        assert "no results" in out

    def test_json_is_the_response_body_verbatim(self, capsys):
        payload = search_payload()
        with StubServer(body=payload) as server:
            assert run_cli("search", "--server", server.url, "--json", "test query") == 0

        out = capsys.readouterr().out
        assert json.loads(out) == payload
        # Verbatim: the bytes the server sent, not a re-serialisation of them,
        # which is what makes `| jq` mean what it says.
        assert out == json.dumps(payload) + "\n"


class TestClientFetch:
    """`seekwright fetch` against a stubbed server."""

    def test_the_body_is_the_fetch_request_model(self):
        with StubServer(body=fetch_payload()) as server:
            assert (
                run_cli(
                    "fetch",
                    "--server",
                    server.url,
                    "--query",
                    "a passage",
                    "--offset",
                    "1000",
                    "https://example.test/page",
                )
                == 0
            )

        assert server.requests[0]["path"] == "/api/v1/fetch"
        sent = server.requests[0]["body"]
        assert sent == {
            "url": "https://example.test/page",
            "query": "a passage",
            "offset": 1000,
        }
        assert FetchRequest.model_validate(sent).offset == 1000

    def test_unset_flags_are_absent_from_the_body_not_null(self):
        with StubServer(body=fetch_payload()) as server:
            assert run_cli("fetch", "--server", server.url, "https://example.test/page") == 0

        assert server.requests[0]["body"] == {"url": "https://example.test/page"}

    def test_the_provider_flag_reaches_the_body_as_written(self):
        """`--provider` is the CLI's spelling of the fifth `fetch` field.

        The client writes no sentence of its own about it: a name the server
        cannot serve comes back as the server's prose on stderr at exit 1, the
        path every refusal takes.
        """
        with StubServer(body=fetch_payload()) as server:
            assert (
                run_cli(
                    "fetch",
                    "--server",
                    server.url,
                    "--provider",
                    "crawl4ai",
                    "https://example.test/page",
                )
                == 0
            )

        assert server.requests[0]["body"] == {
            "url": "https://example.test/page",
            "provider": "crawl4ai",
        }

    def test_the_flag_set_is_the_fetch_request_model_and_nothing_else(self):
        """`answer`'s parity rule, applied to the verb that gained a name."""
        parser = cli._client_parser("fetch")
        args = vars(parser.parse_args(["https://example.test/page"]))

        assert set(args) == set(FetchRequest.model_fields) | {"server", "as_json"}
        assert args["url"] == "https://example.test/page"
        assert args["provider"] is None, "no name is the local read"

    def test_the_page_text_is_printed(self, capsys):
        with StubServer(body=fetch_payload()) as server:
            assert run_cli("fetch", "--server", server.url, "https://example.test/page") == 0

        out = capsys.readouterr().out
        assert "seekwright fetch" in out
        assert "url       https://example.test/page" in out
        assert "title     Example Domain" in out
        assert "chars     13" in out
        assert "the page text" in out

    def test_a_redirect_shows_both_urls(self, capsys):
        """A reader who cannot see a redirect happened cannot judge the text."""
        with StubServer(
            body=fetch_payload(
                url="https://example.test/new",
                requested_url="http://example.test/old",
            )
        ) as server:
            assert run_cli("fetch", "--server", server.url, "http://example.test/old") == 0

        out = capsys.readouterr().out
        assert "url       https://example.test/new" in out
        assert "requested http://example.test/old" in out

    def test_a_query_targeted_fetch_prints_its_matches(self, capsys):
        """`text` and `matches` are alternatives: a matched fetch prints the
        passages at the offsets a re-fetch continues from."""
        with StubServer(
            body=fetch_payload(
                text=None, matches=[{"offset": 1000, "text": "a passage"}], total_chars=5000
            )
        ) as server:
            assert (
                run_cli(
                    "fetch",
                    "--server",
                    server.url,
                    "--query",
                    "a passage",
                    "https://example.test/page",
                )
                == 0
            )

        out = capsys.readouterr().out
        assert "match at 1000:" in out
        assert "a passage" in out

    def test_an_image_is_named_by_type_and_size_and_never_printed(self, capsys):
        """A terminal is not where base64 gets read, so the line names the thing instead.

        `--json` prints the body the server sent and is how the bytes are reached
        for; the human render stays readable whatever the picture weighs.
        """
        encoded = "iVBORw0KGgphIHBuZyBib2R5"
        with StubServer(
            body=fetch_payload(
                text=None,
                content_type="image/png",
                total_chars=None,
                image={"byte_count": 18, "base64": encoded},
                notice="image/png image of 18 bytes returned as image bytes",
            )
        ) as server:
            assert (
                run_cli("fetch", "--server", server.url, "https://img.test/a.png") == 0
            )

        out = capsys.readouterr().out
        assert "image     image/png, 18 bytes (base64 in --json)" in out
        assert encoded not in out
        assert "chars" not in out

    def test_truncation_is_stated(self, capsys):
        """`truncated` tells the reader what they did not get."""
        with StubServer(
            body=fetch_payload(text="the first pageful", truncated=True, total_chars=40000)
        ) as server:
            assert run_cli("fetch", "--server", server.url, "https://example.test/page") == 0

        assert "chars     40000, truncated" in capsys.readouterr().out

    def test_json_is_the_response_body_verbatim(self, capsys):
        payload = fetch_payload()
        with StubServer(body=payload) as server:
            assert (
                run_cli("fetch", "--server", server.url, "--json", "https://example.test/page")
                == 0
            )

        assert capsys.readouterr().out == json.dumps(payload) + "\n"


class TestClientAnswer:
    """`seekwright answer` against a stubbed server: body, render, `--json`."""

    def test_the_body_is_the_answer_request_model(self):
        with StubServer(body=answer_payload()) as server:
            assert (
                run_cli(
                    "answer",
                    "--server",
                    server.url,
                    "--depth",
                    "report",
                    "--provider",
                    "exa:free",
                    "--extra-query",
                    "a second phrasing",
                    "--extra-query",
                    "a third",
                    "--include-domain",
                    "a.test",
                    "--exclude-domain",
                    "b.test",
                    "--recency",
                    "week",
                    "why is the sky blue",
                )
                == 0
            )

        assert len(server.requests) == 1
        assert server.requests[0]["path"] == "/api/v1/answer"
        sent = server.requests[0]["body"]
        assert sent == {
            "query": "why is the sky blue",
            "extra_queries": ["a second phrasing", "a third"],
            "depth": "report",
            "provider": "exa:free",
            "include_domains": ["a.test"],
            "exclude_domains": ["b.test"],
            "recency": "week",
        }
        # The same model the server validates with, so the two cannot disagree.
        assert AnswerRequest.model_validate(sent).depth == "report"

    def test_unset_flags_are_absent_from_the_body_not_null(self):
        """`WireModel`'s rule on the way out too -- and `depth` is left out
        rather than sent as `brief`, because the default is the server's."""
        with StubServer(body=answer_payload()) as server:
            assert run_cli("answer", "--server", server.url, "why is the sky blue") == 0

        assert server.requests[0]["body"] == {"query": "why is the sky blue"}

    def test_the_flag_set_is_the_request_model_and_nothing_else(self):
        """The CLI's whole rule: every flag is a field of one request shape, and
        `--server`/`--json` are the only names that are the invocation's own."""
        parser = cli._client_parser("answer")
        args = vars(parser.parse_args(["why is the sky blue"]))

        assert set(args) == set(AnswerRequest.model_fields) | {"server", "as_json"}
        assert args["query"] == "why is the sky blue"
        assert args["server"] == cli._DEFAULT_SERVER
        assert args["depth"] is None, "the plan applies `brief`, not the client"
        assert args["extra_queries"] is None
        assert args["as_json"] is False

    def test_the_default_output_is_for_a_person(self, capsys):
        with StubServer(body=answer_payload()) as server:
            assert run_cli("answer", "--server", server.url, "test query") == 0

        out = capsys.readouterr().out
        assert "seekwright answer" in out
        assert "query     test query" in out
        assert "model     test-model" in out
        assert "depth     brief" in out
        assert "searches  1" in out
        assert "fetched   0" in out
        assert "It scatters [1], and it is not the moon [2]." in out
        # The sources are the server's list, and the reader needs the provider
        # that supplied each one: that is what makes it a ranking signal.
        assert "sources   2" in out
        assert "1. First" in out
        assert "   https://first.test/" in out
        assert "   via exa:free" in out
        assert "2. Second" in out
        assert "   via serper" in out

    def test_an_uncited_answer_says_so(self, capsys):
        """`sources: []` is a 200, and the render has to make that visible: the
        prose has nothing behind it."""
        with StubServer(
            body=answer_payload(
                sources=[],
                notice=(
                    "the answer carries no citations; read it against `sources`"
                ),
            )
        ) as server:
            assert run_cli("answer", "--server", server.url, "test query") == 0

        out = capsys.readouterr().out
        assert "sources   none cited" in out
        assert "notice: the answer carries no citations" in out

    def test_a_notice_is_printed(self, capsys):
        with StubServer(
            body=answer_payload(notice="1 of 2 pages could not be read")
        ) as server:
            assert run_cli("answer", "--server", server.url, "test query") == 0

        assert "notice: 1 of 2 pages could not be read" in capsys.readouterr().out

    def test_a_truncated_answer_is_stated(self, capsys):
        """The model stopped at its output cap: the reader is told the prose is
        cut short rather than left to guess."""
        with StubServer(body=answer_payload(truncated=True)) as server:
            assert run_cli("answer", "--server", server.url, "test query") == 0

        assert "output cap" in capsys.readouterr().out

    def test_json_is_the_response_body_verbatim(self, capsys):
        payload = answer_payload()
        with StubServer(body=payload) as server:
            assert run_cli("answer", "--server", server.url, "--json", "test query") == 0

        out = capsys.readouterr().out
        assert json.loads(out) == payload
        # Verbatim: the bytes the server sent, not a re-serialisation of them.
        assert out == json.dumps(payload) + "\n"


class TestClientExitCodes:
    """0 when the operation produced a response, 1 when the call failed, 2 for
    a usage error -- `--check`'s convention, which the spec reuses."""

    def test_an_error_the_server_returned_exits_1(self, capsys):
        message = "Provider 'exa' is not enabled on this server."
        with StubServer(status=400, body={"error": message}) as server:
            assert (
                run_cli(
                    "search", "--server", server.url, "--provider", "exa", "test query"
                )
                == 1
            )

        err = capsys.readouterr().err
        assert message in err
        assert "HTTP 400" in err

    def test_an_upstream_failure_carries_its_own_sentence(self, capsys):
        message = "ProviderTimeout: exa:free did not answer in time."
        with StubServer(status=502, body={"error": message}) as server:
            assert run_cli("fetch", "--server", server.url, "https://example.test/page") == 1

        err = capsys.readouterr().err
        assert message in err
        assert "HTTP 502" in err

    def test_a_disabled_agent_mode_carries_its_own_sentence(self, capsys):
        """404: the operation is not served here, and the sentence says which
        two operations are."""
        message = (
            "This server has agent mode disabled; use `search` or `fetch` instead."
        )
        with StubServer(status=404, body={"error": message}) as server:
            assert run_cli("answer", "--server", server.url, "why is the sky blue") == 1

        err = capsys.readouterr().err
        assert "HTTP 404" in err
        assert message in err

    def test_a_model_failure_carries_its_own_sentence(self, capsys):
        """The third operation's other upstream: 502, and the prose names the
        phase -- a model that failed, not a provider."""
        message = (
            "The model endpoint (test-model) returned HTTP 500; no answer was "
            "produced."
        )
        with StubServer(status=502, body={"error": message}) as server:
            assert run_cli("answer", "--server", server.url, "why is the sky blue") == 1

        err = capsys.readouterr().err
        assert "HTTP 502" in err
        assert message in err

    def test_a_body_that_is_not_the_response_model_exits_1(self, capsys):
        with StubServer(body="<html>a proxy's error page</html>") as server:
            assert run_cli("search", "--server", server.url, "test query") == 1

        assert "is not a SearchResponse" in capsys.readouterr().err

    def test_an_unreachable_server_exits_1(self, capsys):
        """Not a usage error -- the call failed. The stub is closed first."""
        with StubServer(body=search_payload()) as server:
            url = server.url

        assert run_cli("search", "--server", url, "test query") == 1
        assert "cannot reach" in capsys.readouterr().err

    def test_a_usage_error_exits_2_and_sends_nothing(self, capsys):
        """Both kinds: argparse's, and the contract's -- refused by the same
        model the server would validate with, so the typo costs no round trip."""
        with StubServer(body=search_payload()) as server:
            assert run_cli("search", "--server", server.url, "--max-results", "99", "q1") == 2
            assert run_cli("search", "--server", server.url, "x") == 2
            assert run_cli("search", "--server", server.url, "--recency", "hour", "q1") == 2
            assert run_cli("search", "--server", server.url) == 2
            assert run_cli("fetch", "--server", server.url, "short") == 2
            assert server.requests == []

        assert "Invalid request" in capsys.readouterr().err

    def test_an_answer_usage_error_exits_2_and_sends_nothing(self, capsys):
        """The same two kinds, for the third operation: argparse's and the
        contract's -- a `depth` the enum has no room for, and a question too
        short to be one."""
        with StubServer(body=answer_payload()) as server:
            assert run_cli("answer", "--server", server.url, "x") == 2
            assert run_cli("answer", "--server", server.url, "--depth", "deep", "q1") == 2
            assert run_cli("answer", "--server", server.url, "--recency", "hour", "q1") == 2
            assert (
                run_cli("answer", "--server", server.url, "--extra-query", "x", "q1") == 2
            )
            assert run_cli("answer", "--server", server.url) == 2
            assert server.requests == []

        assert "Invalid request" in capsys.readouterr().err


class TestClientHoldsNoSecrets:
    """The client is a client: config, keys and spend all live on the server."""

    def test_the_cli_path_reads_no_config_and_sends_no_key(self, monkeypatch):
        def explode() -> Config:
            raise AssertionError("the CLI client loaded the config")

        def no_providers(*_args: object, **_kwargs: object) -> object:
            raise AssertionError("the CLI client built a provider")

        monkeypatch.setattr(cli, "load_config", explode)
        monkeypatch.setattr(cli, "build_providers", no_providers)
        monkeypatch.setenv("SEEKWRIGHT_EXA_API_KEY", "sk-never-sent")
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", "/nonexistent/config.toml")
        monkeypatch.delitem(sys.modules, "seekwright.server", raising=False)

        with StubServer(body=search_payload()) as server:
            assert run_cli("search", "--server", server.url, "test query") == 0

        request = server.requests[0]
        headers = request["headers"]
        assert isinstance(headers, dict)
        assert "authorization" not in headers
        assert "x-api-key" not in headers
        assert "***" not in json.dumps(request)
        # No FastMCP app either: the client never imports the server.
        assert "seekwright.server" not in sys.modules

    def test_the_answer_path_reads_no_config_and_sends_no_key(self, monkeypatch):
        """The third operation is a client like the other two: the model, its
        endpoint and its key are the server's, and none of them is here."""
        def explode() -> Config:
            raise AssertionError("the CLI client loaded the config")

        monkeypatch.setattr(cli, "load_config", explode)
        monkeypatch.setenv("SEEKWRIGHT_AGENT_API_KEY", "sk-agent-never-sent")
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", "/nonexistent/config.toml")
        monkeypatch.delitem(sys.modules, "seekwright.server", raising=False)

        with StubServer(body=answer_payload()) as server:
            assert run_cli("answer", "--server", server.url, "test query") == 0

        request = server.requests[0]
        headers = request["headers"]
        assert isinstance(headers, dict)
        assert "authorization" not in headers
        assert "sk-agent-never-sent" not in json.dumps(request)
        assert "seekwright.server" not in sys.modules


class TestSubcommandDispatch:
    """How the client and the server parsers stay out of each other's way."""

    def test_the_default_server_is_the_address_http_binds(self):
        """The two halves line up with no configuration."""
        assert cli._DEFAULT_SERVER == "http://127.0.0.1:8000"
        assert cli._client_parser("search").parse_args(["q"]).server == cli._DEFAULT_SERVER
        assert (
            cli._client_parser("fetch").parse_args(["https://example.test/"]).server
            == cli._DEFAULT_SERVER
        )
        assert cli._client_parser("answer").parse_args(["q1"]).server == cli._DEFAULT_SERVER

    def test_the_server_flag_overrides_the_default(self, capsys):
        with StubServer(body=search_payload()) as server:
            assert run_cli("search", "--server", server.url, "test query") == 0

        assert server.requests[0]["path"] == "/api/v1/search"
        assert "provider  exa:free" in capsys.readouterr().out

    def test_a_trailing_slash_on_the_server_is_not_doubled(self):
        with StubServer(body=search_payload()) as server:
            assert run_cli("search", "--server", f"{server.url}/", "test query") == 0

        assert server.requests[0]["path"] == "/api/v1/search"

    def test_the_subcommand_comes_first(self):
        """The spec's shape is `seekwright search --server URL QUERY`."""
        with pytest.raises(SystemExit) as exc:
            cli.main(["--server", "http://127.0.0.1:9", "search", "q"])
        assert exc.value.code == 2

    def test_the_two_namespaces_do_not_leak(self):
        """`--json` is the `--metrics` companion on the server and the verbatim
        body on the client; neither parser can see the other's flags."""
        with pytest.raises(SystemExit) as exc:
            cli.main(["--json"])
        assert exc.value.code == 2
        with pytest.raises(SystemExit) as exc:
            cli.main(["--http", "--json"])
        assert exc.value.code == 2
        with pytest.raises(SystemExit) as exc:
            cli.main(["search", "--http", "q"])
        assert exc.value.code == 2

    def test_a_bare_invocation_and_every_existing_flag_still_parse(self, monkeypatch):
        """The server parser is untouched: dispatch happens before it runs."""
        calls: dict[str, object] = {}
        from seekwright import server

        monkeypatch.setattr(server, "main", lambda **kw: calls.update(kw))

        cli.main([])
        assert calls["http"] is False

        cli.main(
            [
                "--http",
                "--host",
                "0.0.0.0",
                "--port",
                "9000",
                "--allowed-host",
                "search.internal:*",
                "--log-level",
                "DEBUG",
                "--log-format",
                "json",
            ]
        )
        assert calls == {
            "http": True,
            "host": "0.0.0.0",
            "port": 9000,
            "allowed_hosts": ["search.internal:*"],
            "log_level": "DEBUG",
            "log_format": "json",
        }
