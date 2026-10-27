"""Choosing the fetch extraction backend from config.

The backend module is imported lazily by the factory, so a missing library is a
translated error naming the extra rather than an ``ImportError`` from the middle
of a request -- these tests pin that translation and the name validation.

`build_providers` is the other half of the same job, and `TestProviderCaps` pins
the one wiring `search.cap` depends on: the engine names the cap on the log line
from its own config, so the adapter has to have been built with that same
number or the record would be reporting a limit nothing applied. `TestProviderRows`
pins the rest of what that job hands each adapter -- its default price, its
timeout floor, and whether it is built at all without its credential -- against
the table in `factory.py` that now carries them.
"""

import sys
from typing import ClassVar

import httpx
import pytest

from seekwright.config import (
    KNOWN_PROVIDERS,
    Config,
    FetchConfig,
    PolicyConfig,
    ProviderConfig,
    api_key_env_var,
)
from seekwright.factory import (
    _PROVIDERS,
    ExtractorUnavailable,
    build_extractor,
    build_fetch_stack,
    build_providers,
)
from seekwright.fetcher import (
    KNOWN_FALLBACKS,
    ContentFetcher,
    Crawl4aiFetcher,
    HttpFetcher,
    JinaFetcher,
    ScrappaFetcher,
)
from seekwright.providers.exa_mcp import ExaMcpProvider
from seekwright.providers.scrappa import ScrappaProvider


def cfg() -> Config:
    return Config(
        providers={"searxng": ProviderConfig(url="http://searx.test:8080")}
    )


class TestBuildExtractor:
    def test_the_default_config_builds_the_default_backend(self):
        extractor = build_extractor(cfg())

        assert extractor.name == "trafilatura"
        assert "text/html" in extractor.supported_types

    def test_a_missing_library_names_the_extra_to_install(self, monkeypatch):
        """`None` in the import cache is how a missing dependency looks."""
        monkeypatch.setitem(sys.modules, "trafilatura", None)
        monkeypatch.delitem(
            sys.modules, "seekwright.extractors.trafilatura", raising=False
        )

        with pytest.raises(ExtractorUnavailable, match="[t]rafilatura"):
            build_extractor(cfg())

    def test_the_message_names_the_extra_and_points_at_the_install_block(
        self, monkeypatch
    ):
        """An install command is not quoted in the message: pasted, one
        needs this instance's index URL, a version pin and `--python 3.14`, which
        is the failure class removed from the docs. The pointer goes to
        the page that carries the one runnable block."""
        monkeypatch.setitem(sys.modules, "trafilatura", None)
        monkeypatch.delitem(
            sys.modules, "seekwright.extractors.trafilatura", raising=False
        )

        with pytest.raises(ExtractorUnavailable) as exc:
            build_extractor(cfg())

        message = str(exc.value)
        assert "'trafilatura' extra" in message
        assert "fetch.extractor" in message
        assert "docs/quickstart.md" in message
        assert "pip install" not in message
        assert "seekwright[" not in message

    def test_the_standard_library_backend_builds_everywhere(self):
        """The name a bare install writes, and the one name with no extra behind
        it: the factory imports nothing outside the standard library for it, so
        there is no install that cannot build it."""
        config = cfg()
        config.fetch.extractor = "stdlib"

        backend = build_extractor(config)

        assert backend.name == "stdlib"

    def test_the_refusal_names_the_backend_that_needs_no_library(self, monkeypatch):
        """Pointing only at the extra left a bare install one dead end away from a
        working tool: it has no extra to install until it has a library to want."""
        monkeypatch.setitem(sys.modules, "trafilatura", None)
        monkeypatch.delitem(
            sys.modules, "seekwright.extractors.trafilatura", raising=False
        )

        with pytest.raises(ExtractorUnavailable) as exc:
            build_extractor(cfg())

        assert "'stdlib'" in str(exc.value)

    def test_an_unknown_name_is_defensively_rejected(self):
        """`FetchConfig` already rejects this, so reaching the factory with an
        unknown name means a `Config` built around validation."""
        config = cfg()
        config.fetch.extractor = "ghost"

        with pytest.raises(ValueError, match="ghost"):
            build_extractor(config)

    def test_the_unknown_name_error_lists_the_supported_ones(self):
        config = cfg()
        config.fetch.extractor = "ghost"

        with pytest.raises(ValueError, match="trafilatura"):
            build_extractor(config)


class TestProviderCaps:
    """The two policy caps reach the adapters that apply them.

    Not new behaviour -- this is the wiring `search.cap` rests on. The engine
    names `cap` on the line from its own `config.policy`, so an adapter built
    with a different number would make the record report a limit nothing
    applied.
    """

    def test_the_snippet_cap_reaches_a_serp_adapter(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")
        config = Config(
            providers={"scrappa": ProviderConfig()},
            policy=PolicyConfig(max_snippet_chars=123),
        )

        scrappa = build_providers(config, httpx.AsyncClient())["scrappa"]

        assert isinstance(scrappa, ScrappaProvider)
        assert scrappa._snippet_chars == 123

    def test_the_text_cap_reaches_a_content_adapter(self):
        config = Config(
            providers={"exa:free": ProviderConfig()},
            policy=PolicyConfig(max_result_text_chars=456),
        )

        exa = build_providers(config, httpx.AsyncClient())["exa:free"]

        assert isinstance(exa, ExaMcpProvider)
        assert exa._text_chars == 456


class TestProviderRows:
    """What each row of the factory table builds: price, timeout floor, credential.

    Not new behaviour. These are the numbers and the guards the 16-branch chain
    used to carry inline, and they are `provider-contract.md`'s wiring point 3:
    a name owes the price that applies when config says nothing, a timeout
    floor where its backend needs one, and a credential rule other than its key
    only where that is how the backend works. No per-name test would notice a
    row that lost its floor -- each adapter's own file asserts what a search
    returns, not what the factory built it with.
    """

    # name -> (price when config says nothing, timeout when policy asks 10 s).
    # MCP names carry 30 s of handshake headroom; scrappa and searxng scrape.
    ROWS: ClassVar[dict[str, tuple[float, float]]] = {
        "algolia": (0.50, 10.0),
        "anysearch": (0.0, 10.0),
        "deepseek": (0.75, 10.0),
        "exa": (7.00, 30.0),
        "exa:free": (0.0, 30.0),
        "freeserp": (0.0, 10.0),
        "linkup": (6.00, 20.0),
        "parallel": (1.00, 10.0),
        "parallel:free": (0.0, 30.0),
        "querit": (0.0, 10.0),
        "scrappa": (0.30, 15.0),
        "search1api": (0.76, 10.0),
        "searxng": (0.0, 15.0),
        "serpapi": (0.0, 10.0),
        "serper": (1.00, 10.0),
        "tavily": (8.00, 10.0),
        "tinyfish": (0.0, 10.0),
    }

    # Built with nothing in the environment: searxng's instance url is the
    # prerequisite named in config.
    NO_CREDENTIAL = frozenset(
        {"anysearch", "exa:free", "freeserp", "parallel:free", "searxng"}
    )

    @staticmethod
    def _config(policy_timeout: float = 10.0) -> Config:
        """Every name enabled, with the config-side prerequisites named."""
        return Config(
            providers={
                name: ProviderConfig(
                    url="http://searx.test:8080",
                    app_id="app123",
                    index="products",
                )
                for name in KNOWN_PROVIDERS
            },
            policy=PolicyConfig(provider_timeout_seconds=policy_timeout),
        )

    @staticmethod
    def _timeout_of(provider: object) -> float:
        """The timeout an adapter was built at.

        `TieredExaProvider` is two adapters rather than one, so its floor lands
        on both halves and there is no number to read at the top level.
        """
        direct = getattr(provider, "_timeout", None)
        if direct is not None:
            return float(direct)
        return float(vars(provider)["_keyed"]._timeout)

    def test_every_row_builds_its_name_at_its_own_numbers(self, monkeypatch):
        for name in KNOWN_PROVIDERS:
            monkeypatch.setenv(api_key_env_var(name), "k")

        built = build_providers(self._config(), httpx.AsyncClient())

        assert set(built) == set(self.ROWS)
        for name, (cost, timeout) in self.ROWS.items():
            assert built[name].cost_per_1k == cost, name
            assert self._timeout_of(built[name]) == timeout, name

    def test_the_timeout_floor_is_a_floor_not_a_ceiling(self, monkeypatch):
        """A policy timeout above a row's floor is what the adapter gets."""
        for name in KNOWN_PROVIDERS:
            monkeypatch.setenv(api_key_env_var(name), "k")

        built = build_providers(
            self._config(policy_timeout=60.0), httpx.AsyncClient()
        )

        assert {self._timeout_of(p) for p in built.values()} == {60.0}

    def test_a_name_without_its_credential_is_skipped(self, monkeypatch):
        for name in KNOWN_PROVIDERS:
            monkeypatch.delenv(api_key_env_var(name), raising=False)

        built = build_providers(self._config(), httpx.AsyncClient())

        assert set(built) == set(self.NO_CREDENTIAL)

    def test_only_exa_free_fixes_its_price_against_config(self, monkeypatch):
        """`exa:free` is priced at zero whatever config says; every other name
        takes the config figure over the row's default."""
        for name in KNOWN_PROVIDERS:
            monkeypatch.setenv(api_key_env_var(name), "k")
        config = Config(
            providers={
                name: ProviderConfig(
                    cost_per_1k=1.25,
                    url="http://searx.test:8080",
                    app_id="app123",
                    index="products",
                )
                for name in KNOWN_PROVIDERS
            }
        )

        built = build_providers(config, httpx.AsyncClient())

        assert {n: p.cost_per_1k for n, p in built.items()} == {
            name: (0.0 if name == "exa:free" else 1.25) for name in self.ROWS
        }

    def test_the_table_covers_every_name_config_admits(self):
        """A name config admits and the factory has no row for is skipped in
        silence -- the chain had the same hole, an unmatched name falling
        through to the `return`, which is why wiring point 3 is a wiring point.
        """
        assert set(_PROVIDERS) == set(KNOWN_PROVIDERS)


class TestFetchFallbacks:
    """`build_fetch_stack` asks each fallback's row what it needs.

    The loop used to carry one branch per vendor: a fallback's prerequisite, its
    permission gate and its constructor arguments all sat in `factory`. They live on
    the row now. What the loop still owns is the contract that did not change --
    build in config order, skip a fallback this deployment cannot run, and if anything
    built on the way has to be closed, close all of it.
    """

    @staticmethod
    def _config(**fetch_kw) -> Config:
        return Config(
            providers={"scrappa": ProviderConfig()},
            fetch=FetchConfig(enabled=True, **fetch_kw),
        )

    @staticmethod
    async def _close(fetcher: HttpFetcher | None, fallbacks: list[ContentFetcher]) -> None:
        if fetcher is not None:
            await fetcher.aclose()
        for fallback in fallbacks:
            await fallback.aclose()

    async def test_a_fallback_without_its_prerequisite_is_not_built(self, monkeypatch):
        """Two fallbacks neither of which this deployment can run: an empty ladder, not a failed start."""
        monkeypatch.delenv("SEEKWRIGHT_SCRAPPA_API_KEY", raising=False)

        fetcher, fallbacks = await build_fetch_stack(
            self._config(fallback=["crawl4ai", "scrappa"])
        )
        try:
            assert fallbacks == []
        finally:
            await self._close(fetcher, fallbacks)

    async def test_the_ladder_is_built_in_config_order_from_the_rows(self, monkeypatch):
        """Three fallbacks, three builders, and no branch in the loop naming any of them."""
        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")

        fetcher, fallbacks = await build_fetch_stack(
            self._config(
                fallback=["crawl4ai", "jina", "scrappa"],
                crawl4ai_url="http://int-crawl4ai:11235",
            )
        )
        try:
            assert [fallback.name for fallback in fallbacks] == ["crawl4ai", "jina", "scrappa"]
            assert [type(fallback) for fallback in fallbacks] == [
                Crawl4aiFetcher,
                JinaFetcher,
                ScrappaFetcher,
            ]
            # The builder reads the vendor's own knobs off the config, and only the fallback
            # that can bill carries a price.
            assert [fallback.cost_per_1k for fallback in fallbacks] == [
                None,
                None,
                pytest.approx(0.30),
            ]
        finally:
            await self._close(fetcher, fallbacks)

    async def test_a_name_the_registry_does_not_know_is_refused_naming_the_registry(
        self, monkeypatch
    ):
        """Defensive, and the same shape as `build_extractor`'s unknown-backend error.

        Validation closes this door; a `Config` built around it gets the sentence
        rather than a ladder with one fallback quietly missing from it.
        """
        from seekwright import factory as factory_module

        monkeypatch.setattr(
            factory_module,
            "KNOWN_FALLBACKS",
            {name: row for name, row in KNOWN_FALLBACKS.items() if name != "scrappa"},
        )
        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")

        with pytest.raises(ValueError, match="unknown fetch fallback 'scrappa'") as exc:
            await build_fetch_stack(self._config(fallback=["scrappa"]))

        assert "crawl4ai, jina" in str(exc.value)

    async def test_a_fallback_builder_that_raises_closes_everything_built_before_it(
        self, monkeypatch
    ):
        """All-or-nothing survives the new loop: the rows are called inside the same try.

        Every fetcher owns its own `httpx.AsyncClient`, so a fallback builder raising
        mid-ladder strands the fetcher and every fallback already built unless this
        function closes them -- and `test_server.py` pins the same thing one level up.
        """
        from dataclasses import replace

        from seekwright import factory as factory_module

        class FallbackBlewUp(Exception):
            """Whatever reason a fallback's builder has for failing."""

        def exploding(config: Config) -> ContentFetcher:
            raise FallbackBlewUp("the paid fallback could not be built")

        monkeypatch.setattr(
            factory_module,
            "KNOWN_FALLBACKS",
            {**KNOWN_FALLBACKS, "scrappa": replace(KNOWN_FALLBACKS["scrappa"], build=exploding)},
        )
        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")

        clients: list[httpx.AsyncClient] = []

        def watched(cls):
            def build(*args, **kwargs):
                built = cls(*args, **kwargs)
                clients.append(built._client)
                return built

            return build

        monkeypatch.setattr(factory_module, "HttpFetcher", watched(HttpFetcher))
        monkeypatch.setattr("seekwright.fetcher.Crawl4aiFetcher", watched(Crawl4aiFetcher))

        with pytest.raises(FallbackBlewUp):
            await build_fetch_stack(
                self._config(
                    fallback=["crawl4ai", "scrappa"],
                    crawl4ai_url="http://int-crawl4ai:11235",
                )
            )

        assert len(clients) == 2, "the fetcher and the first fallback were both built"
        assert all(client.is_closed for client in clients), "a partial stack leaked a client"
