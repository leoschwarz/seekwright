"""Agent mode: the fixed plan, the model client, and the citations it validates.

Three layers are exercised here, and the split matters. Most of the contract is
driven straight at ``AgentEngine``, wired to the *real* ``SearchEngine`` and
``FetchEngine`` over stub providers and a stub fetcher -- so the retrieval lines,
the ladder and the journal are the production ones -- with only the model
endpoint stubbed through ``httpx.MockTransport``. The tool surface and the
clean refusal are driven through the MCP server over an in-memory session, which
is the only place the schema and the exception translation are visible.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any, override

import httpx
import pytest
from mcp import Client, types

from seekwright import server
from seekwright.agent import (
    PAGES_PER_REPORT,
    RESULTS_PER_QUERY,
    AgentEngine,
    AgentFailed,
)
from seekwright.config import AgentConfig, Config, LoggingConfig, ProviderConfig
from seekwright.engine import FetchEngine, SearchEngine
from seekwright.fetcher import ContentFetcher, FetchedPage
from seekwright.models import (
    FetchResponse,
    ProviderResult,
    Result,
    SearchQuery,
    SearchResponse,
)
from seekwright.providers.base import ProviderError
from seekwright.sanitize import ZWSP
from seekwright.usage import UsageRecorder

PROVIDER = "serper"

# Prices are per 1k *tokens*, not per 1k calls; the spec's cost table only balances
# here.
PRICE_IN = 0.00014
PRICE_OUT = 0.00028


class StubProvider:
    """A provider that structurally satisfies ``SearchProvider``.

    ``results`` decides what comes back (``None`` means one canned hit per
    call), ``fail`` raises the way a real adapter does, and ``text`` fills a
    content backend's extract instead of a snippet -- which is what decides
    whether the plan fetches a page or takes the text it was already handed.
    """

    def __init__(
        self,
        name: str = PROVIDER,
        *,
        results: list[Result] | None = None,
        fail: Exception | None = None,
        text: str | None = None,
        cost_usd: float = 0.007,
    ) -> None:
        self.name = name
        self.cost_per_1k = 0.001
        self.calls = 0
        self.queries: list[SearchQuery] = []
        self._results = results
        self._fail = fail
        self._text = text
        self._cost_usd = cost_usd

    async def search(self, q: SearchQuery) -> ProviderResult:
        self.calls += 1
        self.queries.append(q)
        if self._fail is not None:
            raise self._fail
        if self._results is not None:
            results = list(self._results)
        else:
            results = [
                Result(
                    title=f"About {q.query}",
                    url=f"https://example.com/{self.calls}",
                    snippet="a snippet",
                )
            ]
            if self._text is not None:
                results = [
                    Result(
                        title=f"About {q.query}",
                        url=f"https://example.com/{self.calls}",
                        text=self._text,
                    )
                ]
        return ProviderResult(
            provider=self.name, results=results, cost_usd=self._cost_usd
        )

    async def aclose(self) -> None:
        return None


class StubFetcher:
    """A local fetcher: a readable page, or a refusal, without a network call."""

    name = "fetch"
    cost_per_1k: float | None = None

    def __init__(
        self, *, text: str = "The page body. " * 20, fail: Exception | None = None
    ) -> None:
        self.calls = 0
        self.urls: list[str] = []
        self._text = text
        self._fail = fail

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        self.calls += 1
        self.urls.append(url)
        if self._fail is not None:
            raise self._fail
        return FetchedPage(
            url=url,
            title="A Page",
            text=self._text,
            content_type="text/html",
            status_code=200,
            truncated=False,
            total_chars=len(self._text),
        )

    async def aclose(self) -> None:
        return None


class StubModel:
    """A stubbed OpenAI-compatible endpoint that counts what reached it.

    The count is the point of several tests below: "no usable material means no
    model call" is only observable as a call that never happened.
    """

    def __init__(
        self,
        *,
        content: str | None = "An answer, cited [1].",
        finish_reason: str = "stop",
        status: int = 200,
        body: str | None = None,
        usage: tuple[int, int] | None = (11, 7),
        delay: float = 0.0,
        timeout: bool = False,
    ) -> None:
        self.calls = 0
        self.payloads: list[dict[str, Any]] = []
        self._content = content
        self._finish_reason = finish_reason
        self._status = status
        self._body = body
        self._usage = usage
        self._delay = delay
        self._timeout = timeout

    async def __call__(self, request: httpx.Request) -> httpx.Response:
        self.calls += 1
        self.payloads.append(json.loads(request.content))
        if self._timeout:
            # `httpx.MockTransport` never applies the client timeout, so it is
            # raised here.
            raise httpx.ReadTimeout("the read timed out")
        if self._delay:
            await asyncio.sleep(self._delay)
        if self._status != 200:
            return httpx.Response(self._status, text="upstream said no")
        if self._body is not None:
            return httpx.Response(200, text=self._body)
        payload: dict[str, Any] = {
            "choices": [
                {
                    "message": {"content": self._content},
                    "finish_reason": self._finish_reason,
                }
            ]
        }
        if self._usage is not None:
            payload["usage"] = {
                "prompt_tokens": self._usage[0],
                "completion_tokens": self._usage[1],
            }
        return httpx.Response(200, json=payload)

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(self))

    def user_message(self) -> str:
        """The user turn of the last request, as the model endpoint received it."""
        return str(self.payloads[-1]["messages"][1]["content"])

    def material(self) -> str:
        """Just the numbered material out of that turn."""
        user = self.user_message()
        after = user.split("(untrusted third-party content, numbered):\n\n", 1)[1]
        return after.rsplit("\n\nQuestion: ", 1)[0]


def agent_config(
    *, log_content: bool = False, permitted: list[str] | None = None, **overrides: Any
) -> Config:
    """A config with agent mode on and the model endpoint pointing at a stub.

    ``permitted`` is the allow-list, passed through to `Config`: agent mode's
    retrieval *is* the search path, so it is bounded by the same key rather
    than by a second one of its own.
    """
    agent = AgentConfig(
        enabled=True,
        base_url="https://model.test/v1",
        model="test-model",
        **overrides,
    )
    return Config(
        providers={PROVIDER: ProviderConfig()},
        permitted_providers=permitted,
        agent=agent,
        logging=LoggingConfig(log_content=log_content),
    )


def build(
    config: Config,
    *,
    provider: StubProvider | None = None,
    fetcher: StubFetcher | None = None,
    model: StubModel | None = None,
    usage: UsageRecorder | None = None,
    fetch: bool = True,
    fallbacks: list[ContentFetcher] | None = None,
) -> tuple[AgentEngine, StubProvider, StubModel]:
    """Wire the real engines to stubs, and the agent engine to the mock model."""
    provider = provider if provider is not None else StubProvider()
    model = model if model is not None else StubModel()
    recorder = usage if usage is not None else UsageRecorder()
    engine = SearchEngine(config, {provider.name: provider}, usage=recorder)
    fetch_engine = (
        FetchEngine(
            config,
            fetcher or StubFetcher(),
            fallbacks or [],
            usage=recorder,
        )
        if fetch
        else None
    )
    agent = AgentEngine(
        config, model.client(), engine, fetch_engine, usage=recorder
    )
    return agent, provider, model


def journal_lines(path: Path) -> list[dict[str, Any]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def _text(result: types.CallToolResult) -> str:
    return "\n".join(
        block.text for block in result.content if isinstance(block, types.TextContent)
    )


@pytest.fixture(autouse=True)
def agent_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """The key every enabled agent mode needs, from the environment only."""
    monkeypatch.setenv("SEEKWRIGHT_AGENT_API_KEY", "sk-test-key")


class TestThePlan:
    """What the fixed plan does with the caller's declaration, and nothing else."""

    async def test_a_brief_answer_runs_one_search_and_reads_no_pages(self):
        agent, provider, model = build(agent_config())

        response = await agent.answer(query="why is the sky blue")

        assert provider.calls == 1
        assert response.searches == 1
        assert response.fetched == 0
        assert response.depth == "brief"
        assert model.calls == 1

    async def test_a_brief_answer_does_not_run_the_extra_queries(self):
        """`brief` is one search by contract: it is the depth's whole promise."""
        agent, provider, _model = build(agent_config())

        response = await agent.answer(
            query="why is the sky blue",
            extra_queries=["rayleigh scattering", "sky colour physics"],
        )

        assert provider.calls == 1
        assert response.searches == 1

    async def test_a_report_runs_every_query_in_order(self):
        agent, provider, _model = build(agent_config())

        response = await agent.answer(
            query="why is the sky blue",
            extra_queries=["rayleigh scattering", "sky colour physics"],
            depth="report",
        )

        assert [q.query for q in provider.queries] == [
            "why is the sky blue",
            "rayleigh scattering",
            "sky colour physics",
        ]
        assert response.searches == 3

    async def test_every_query_carries_the_callers_filters_and_the_fixed_width(self):
        agent, provider, _model = build(agent_config())

        await agent.answer(
            query="why is the sky blue",
            depth="report",
            include_domains=["nasa.gov"],
            exclude_domains=["example.com"],
            recency="month",
            language="en",
            safe_search=True,
        )

        q = provider.queries[0]
        assert q.max_results == RESULTS_PER_QUERY == 5
        assert q.include_domains == ["nasa.gov"]
        assert q.exclude_domains == ["example.com"]
        assert q.recency == "month"
        # Both `search`-shaped filters reach every step; a filter settable on one
        # tool only is the trap.
        assert q.language == "en"
        assert q.safe_search is True

    async def test_both_new_filters_reach_every_step_of_a_report(self):
        agent, provider, _model = build(agent_config())

        await agent.answer(
            query="why is the sky blue",
            extra_queries=["rayleigh scattering"],
            depth="report",
            language="de",
            safe_search=False,
        )

        assert len(provider.queries) == 2
        assert [q.language for q in provider.queries] == ["de", "de"]
        assert [q.safe_search for q in provider.queries] == [False, False]

    async def test_a_report_reads_at_most_three_pages(self):
        """The page count is a constant, not a function of what came back."""
        results = [
            Result(title=f"r{i}", url=f"https://example.com/{i}", snippet="s")
            for i in range(1, 6)
        ]
        fetcher = StubFetcher()
        agent, _provider, _model = build(
            agent_config(), provider=StubProvider(results=results), fetcher=fetcher
        )

        response = await agent.answer(query="why is the sky blue", depth="report")

        assert fetcher.calls == PAGES_PER_REPORT == 3
        assert response.fetched == 3
        assert len(results) > PAGES_PER_REPORT

    async def test_a_result_that_already_carries_text_is_not_fetched(self):
        """A content backend handed us the extract; refetching bills twice."""
        fetcher = StubFetcher()
        agent, _provider, model = build(
            agent_config(),
            provider=StubProvider(text="An extract the backend returned."),
            fetcher=fetcher,
        )

        response = await agent.answer(query="why is the sky blue", depth="report")

        assert fetcher.calls == 0
        assert response.fetched == 0
        assert "An extract the backend returned." in model.material()

    async def test_a_brief_is_grounded_in_a_content_backends_extract(self):
        """A content backend fills `text` and leaves `snippet` empty.

        `brief` reads no pages, so that extract is the only body it has. The
        default keyless set is content backends, and `brief` is the default
        depth: reading `snippet` alone failed the cheapest deployment outright.
        """
        agent, _provider, model = build(
            agent_config(),
            provider=StubProvider(text="An extract the backend returned."),
        )

        response = await agent.answer(query="why is the sky blue")

        assert response.depth == "brief"
        assert "An extract the backend returned." in model.material()

    async def test_the_extract_is_the_body_when_a_backend_sends_both(self):
        """`text` before `snippet`, the order `report` already uses to skip a fetch."""
        results = [
            Result(
                title="both",
                url="https://example.com/both",
                snippet="a snippet",
                text="the fuller extract",
            )
        ]
        agent, _provider, model = build(
            agent_config(), provider=StubProvider(results=results)
        )

        await agent.answer(query="why is the sky blue")

        material = model.material()
        assert "the fuller extract" in material

    async def test_the_material_is_numbered_and_carries_title_and_url(self):
        agent, _provider, model = build(agent_config())

        await agent.answer(query="why is the sky blue")

        material = model.material()
        assert material.startswith("[1] About why is the sky blue")
        assert "https://example.com/1" in material
        assert "a snippet" in material

    async def test_the_material_is_bounded_by_max_material_chars(self):
        """The input side of the model call is a number, not a provider's whim."""
        cap = 60
        agent, _provider, model = build(agent_config(max_material_chars=cap))

        await agent.answer(query="why is the sky blue")

        material = model.material()
        assert len(material) <= cap
        assert material.count("[1]") == 1
        assert "[2]" not in material

    async def test_a_report_is_served_from_snippets_when_fetch_is_off(self):
        agent, _provider, model = build(agent_config(), fetch=False)

        response = await agent.answer(query="why is the sky blue", depth="report")

        assert response.fetched == 0
        assert "fetch tool disabled" in (response.notice or "")
        assert model.calls == 1

    async def test_the_model_call_carries_the_servers_own_settings(self):
        """Prompt, temperature and the output cap are the server's, never a parameter."""
        agent, _provider, model = build(agent_config())

        await agent.answer(query="why is the sky blue")

        payload = model.payloads[0]
        assert payload["model"] == "test-model"
        assert payload["temperature"] == 0.2
        assert payload["max_tokens"] == 500
        assert payload["stream"] is False
        assert "untrusted third-party content" in payload["messages"][0]["content"]

    async def test_the_report_output_cap_is_the_reports(self):
        agent, _provider, model = build(agent_config())

        await agent.answer(query="why is the sky blue", depth="report")

        assert model.payloads[0]["max_tokens"] == 2500


class TestCitations:
    """`sources` is the server's list, built from what it retrieved."""

    async def test_sources_hold_only_what_the_prose_cited(self):
        model = StubModel(content="Scattering does it [1].")
        agent, _provider, _model = build(agent_config(), model=model)

        response = await agent.answer(query="why is the sky blue")

        assert [s.url for s in response.sources] == ["https://example.com/1"]
        assert response.sources[0].provider == PROVIDER
        assert response.sources[0].title == "About why is the sky blue"

    async def test_an_invented_index_is_dropped_counted_and_named(self):
        """A 200, not a failure: the defect is in the prose, not in the retrieval."""
        model = StubModel(content="Scattering does it [1] and the moon does too [9].")
        agent, _provider, _model = build(agent_config(), model=model)

        response = await agent.answer(query="why is the sky blue")

        assert [s.url for s in response.sources] == ["https://example.com/1"]
        assert response.notice is not None
        assert "cites 1 index" in response.notice
        assert "dropped" in response.notice

    async def test_an_uncited_answer_is_returned_with_a_notice(self):
        model = StubModel(content="Scattering does it, on the whole.")
        agent, _provider, _model = build(agent_config(), model=model)

        response = await agent.answer(query="why is the sky blue")

        assert response.answer == "Scattering does it, on the whole."
        assert response.sources == []
        assert response.notice is not None
        assert "no citations" in response.notice

    async def test_an_answer_whose_only_markers_are_invented_names_the_count(self, tmp_path):
        """Both citation rows hold at once: nothing valid, and two invented.

        `cited_invalid` never reaches the wire, so a notice that only said "no
        citations" would leave the caller unable to tell a model that cited
        nothing from one that invented two indices.
        """
        journal = tmp_path / "usage.jsonl"
        model = StubModel(content="The moon does it [7] and also [8].")
        agent, _provider, _model = build(
            agent_config(),
            model=model,
            usage=UsageRecorder(history_path=str(journal)),
        )

        response = await agent.answer(query="why is the sky blue")

        assert response.answer == "The moon does it [7] and also [8]."
        assert response.sources == []
        assert response.notice is not None
        assert "cites 2 indices" in response.notice
        assert "no citations" in response.notice
        line = next(l for l in journal_lines(journal) if l["tool"] == "answer")
        assert line["cited"] == 0
        assert line["cited_invalid"] == 2

    async def test_a_marker_that_is_not_a_number_counts_as_invalid(self):
        model = StubModel(content="See [n] for the detail, and [1] for the claim.")
        agent, _provider, _model = build(agent_config(), model=model)

        response = await agent.answer(query="why is the sky blue")

        assert [s.url for s in response.sources] == ["https://example.com/1"]
        assert "cites 1 index" in (response.notice or "")

    async def test_markdown_link_text_is_not_a_citation_marker(self):
        """The one false positive worth excluding: `[text](url)` is not an index."""
        model = StubModel(content="Scattering [see the note](https://x.test/n) does it [1].")
        agent, _provider, _model = build(agent_config(), model=model)

        response = await agent.answer(query="why is the sky blue")

        assert response.notice is None
        assert [s.url for s in response.sources] == ["https://example.com/1"]

    async def test_two_indices_for_one_url_collapse_in_sources(self):
        """`cited` deduplicates by index, `sources` by URL -- so they can differ."""
        results = [
            Result(title="a", url="https://example.com/same", snippet="s"),
            Result(title="b", url="https://example.com/same", snippet="s"),
        ]
        model = StubModel(content="Both say it [1][2].")
        agent, _provider, _model = build(
            agent_config(), provider=StubProvider(results=results), model=model
        )

        response = await agent.answer(query="why is the sky blue")

        assert [s.url for s in response.sources] == ["https://example.com/same"]

    async def test_sources_are_in_first_citation_order(self):
        results = [
            Result(title="a", url="https://example.com/a", snippet="s"),
            Result(title="b", url="https://example.com/b", snippet="s"),
        ]
        model = StubModel(content="Second [2], then first [1].")
        agent, _provider, _model = build(
            agent_config(), provider=StubProvider(results=results), model=model
        )

        response = await agent.answer(query="why is the sky blue")

        assert [s.url for s in response.sources] == [
            "https://example.com/b",
            "https://example.com/a",
        ]


class TestFailureContract:
    """Every row of the spec's table, including the ones that never call the model."""

    async def test_no_results_at_all_fails_without_calling_the_model(self):
        model = StubModel()
        agent, _provider, _model = build(
            agent_config(), provider=StubProvider(results=[]), model=model
        )

        with pytest.raises(AgentFailed) as raised:
            await agent.answer(query="why is the sky blue")

        assert model.calls == 0
        assert "Zero results usually means the phrasing" in str(raised.value)

    async def test_results_with_no_usable_text_fail_without_calling_the_model(self):
        model = StubModel()
        results = [Result(title="t", url="https://example.com/a")]
        agent, _provider, _model = build(
            agent_config(), provider=StubProvider(results=results), model=model
        )

        with pytest.raises(AgentFailed) as raised:
            await agent.answer(query="why is the sky blue")

        assert model.calls == 0
        assert "nothing usable" in str(raised.value)

    async def test_every_step_failing_fails_without_calling_the_model(self):
        model = StubModel()
        agent, _provider, _model = build(
            agent_config(),
            provider=StubProvider(fail=ProviderError(PROVIDER, "upstream 503")),
            model=model,
        )

        with pytest.raises(AgentFailed) as raised:
            await agent.answer(query="why is the sky blue")

        assert model.calls == 0
        assert "upstream 503" in str(raised.value)

    async def test_a_partial_walk_continues_and_says_which_steps_came_back_empty(self):
        """One empty step is a notice, not a failure: the rest of the walk ran."""
        class Flaky(StubProvider):
            @override
            async def search(self, q: SearchQuery) -> ProviderResult:
                if q.query == "rayleigh scattering":
                    raise ProviderError(PROVIDER, "upstream 503")
                if q.query == "sky colour physics":
                    self.calls += 1
                    return ProviderResult(provider=self.name, results=[], cost_usd=0.007)
                return await super().search(q)

        agent, _provider, model = build(agent_config(), provider=Flaky())

        response = await agent.answer(
            query="why is the sky blue",
            extra_queries=["rayleigh scattering", "sky colour physics"],
            depth="report",
        )

        assert model.calls == 1
        assert response.searches == 3
        assert response.notice is not None
        assert "1 of 3 retrieval steps returned results" in response.notice
        assert "step 2" in response.notice
        assert "step 3" in response.notice

    async def test_a_page_that_cannot_be_read_is_a_notice_not_a_failure(self):
        fetcher = StubFetcher(fail=ProviderError("fetch", "connection reset"))
        agent, _provider, model = build(agent_config(), fetcher=fetcher)

        response = await agent.answer(query="why is the sky blue", depth="report")

        assert model.calls == 1
        assert response.fetched == 0
        assert "1 of 1 pages could not be read" in (response.notice or "")

    async def test_the_plan_asks_for_the_walk_a_caller_is_denied(self):
        """`fetch.auto_fallback` is off, and `answer` still walks.

        Between the plan's steps there is no caller to act on a list of provider
        names, so a refusal there is a lost page rather than a choice: flipping
        the default would otherwise quietly make `answer` read less on the
        JavaScript-heavy sites the ladder exists for. The plan asks on the call.
        """
        results = [Result(title="r1", url="https://example.com/1", snippet="s")]
        local = StubFetcher(fail=ProviderError("fetch", "connection reset"))
        fallback = StubFetcher(text="The page a browser could read. " * 8)
        agent, _provider, model = build(
            agent_config(),
            provider=StubProvider(results=results),
            fetcher=local,
            fallbacks=[fallback],
        )

        response = await agent.answer(query="why is the sky blue", depth="report")

        assert (local.calls, fallback.calls) == (1, 1), "the plan walks when the caller may not"
        assert response.fetched == 1
        assert "The page a browser could read." in model.material()

    async def test_a_model_5xx_is_a_clean_error_with_the_status(self):
        model = StubModel(status=503)
        agent, _provider, _model = build(agent_config(), model=model)

        with pytest.raises(AgentFailed) as raised:
            await agent.answer(query="why is the sky blue")

        assert model.calls == 1
        assert "HTTP 503" in str(raised.value)
        # The upstream body is never interpolated into the error.
        assert "upstream said no" not in str(raised.value)

    async def test_a_model_timeout_names_the_model_and_the_phase(self):
        model = StubModel(timeout=True)
        agent, _provider, _model = build(
            agent_config(model_timeout_seconds=0.05), model=model
        )

        with pytest.raises(AgentFailed) as raised:
            await agent.answer(query="why is the sky blue")

        assert "test-model" in str(raised.value)
        assert "did not answer within" in str(raised.value)
        # The httpx exception's own text never reaches the caller.
        assert "the read timed out" not in str(raised.value)

    async def test_an_empty_completion_is_an_error_not_an_invented_answer(self):
        agent, _provider, _model = build(
            agent_config(), model=StubModel(content="   ")
        )

        with pytest.raises(AgentFailed) as raised:
            await agent.answer(query="why is the sky blue")

        assert "no prose" in str(raised.value)

    async def test_a_body_that_is_not_json_is_a_clean_error(self):
        agent, _provider, _model = build(
            agent_config(), model=StubModel(body="<html>not json</html>")
        )

        with pytest.raises(AgentFailed) as raised:
            await agent.answer(query="why is the sky blue")

        assert "not JSON" in str(raised.value)

    async def test_the_whole_call_is_bounded_by_timeout_seconds(self):
        model = StubModel(delay=0.2)
        agent, _provider, _model = build(
            agent_config(timeout_seconds=0.05, model_timeout_seconds=30.0), model=model
        )

        with pytest.raises(AgentFailed) as raised:
            await agent.answer(query="why is the sky blue")

        assert "exceeded 0.05s" in str(raised.value)
        assert "calling the model" in str(raised.value)

    async def test_a_retrieval_spend_past_the_money_ceiling_aborts_the_call(self):
        """The early exit: it stops the walk, and the model is never called."""
        model = StubModel()
        agent, provider, _model = build(
            agent_config(
                max_cost_usd=0.001, cost_per_1k_in=PRICE_IN, cost_per_1k_out=PRICE_OUT
            ),
            provider=StubProvider(cost_usd=0.007),
            model=model,
        )

        with pytest.raises(AgentFailed) as raised:
            await agent.answer(query="why is the sky blue", depth="report")

        assert model.calls == 0
        assert provider.calls == 1
        assert "per-call ceiling" in str(raised.value)

    async def test_an_unconfigured_agent_names_what_is_missing(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_AGENT_API_KEY")
        config = Config(
            providers={PROVIDER: ProviderConfig()},
            agent=AgentConfig(enabled=True, base_url=None, model=None),
        )
        agent, _provider, model = build(config)

        with pytest.raises(AgentFailed) as raised:
            await agent.answer(query="why is the sky blue")

        assert model.calls == 0
        message = str(raised.value)
        assert "agent.base_url" in message
        assert "agent.model" in message
        assert "SEEKWRIGHT_AGENT_API_KEY" in message


class TestTheAllowList:
    """Agent mode inherits the allow-list; it does not get a second key.

    Its retrieval **is** the search path -- ``AgentEngine`` calls
    ``self.engine.search(...)``, the same call a `search` tool call makes -- so
    a pinned provider the permission set excludes fails the retrieval step,
    and the failure lands before any model call. This is the stricter cousin of
    the `[agent] enabled = false` precedent: there the model was never asked,
    and here it is never reached.
    """

    async def test_an_unpermitted_pin_fails_before_the_model_call(self):
        model = StubModel()
        agent, provider, _model = build(
            agent_config(permitted=["linkup"]), model=model
        )

        with pytest.raises(AgentFailed) as raised:
            await agent.answer(query="why is the sky blue", provider=PROVIDER)

        assert model.calls == 0, "a refusal before dispatch is before the model too"
        assert provider.calls == 0
        message = str(raised.value)
        assert f"Provider {PROVIDER!r} is not permitted on this server" in message
        assert "Permitted: linkup" in message


class TestUsageAccounting:
    """Tokens, cost and the journal line, which is what the ranking data reads."""

    async def test_the_endpoints_usage_becomes_the_journal_line(self, tmp_path):
        journal = tmp_path / "usage.jsonl"
        agent, _provider, _model = build(
            agent_config(cost_per_1k_in=PRICE_IN, cost_per_1k_out=PRICE_OUT),
            model=StubModel(content="Cited [1].", usage=(1000, 500)),
            usage=UsageRecorder(history_path=str(journal)),
        )

        await agent.answer(query="why is the sky blue")

        line = next(l for l in journal_lines(journal) if l["tool"] == "answer")
        assert set(line) == {
            "ts",
            "tool",
            "run",
            "model",
            "depth",
            "searches",
            "results",
            "fetched",
            "material_chars",
            "prompt_tokens",
            "completion_tokens",
            "answer_chars",
            "cited",
            "cited_invalid",
            "sources",
            "model_cost_usd",
            "ms",
            "error",
        }
        assert line["model"] == "test-model"
        assert line["prompt_tokens"] == 1000
        assert line["completion_tokens"] == 500
        assert line["answer_chars"] == len("Cited [1].")
        assert line["cited"] == 1
        assert line["cited_invalid"] == 0
        assert line["sources"] == 1
        assert line["model_cost_usd"] == pytest.approx(PRICE_IN + PRICE_OUT / 2)
        assert line["error"] is None

    async def test_an_endpoint_with_no_usage_reports_null_never_zero(self, tmp_path):
        journal = tmp_path / "usage.jsonl"
        agent, _provider, _model = build(
            agent_config(cost_per_1k_in=PRICE_IN, cost_per_1k_out=PRICE_OUT),
            model=StubModel(usage=None),
            usage=UsageRecorder(history_path=str(journal)),
        )

        await agent.answer(query="why is the sky blue")

        line = next(l for l in journal_lines(journal) if l["tool"] == "answer")
        assert line["prompt_tokens"] is None
        assert line["completion_tokens"] is None
        assert line["model_cost_usd"] is None

    async def test_unset_prices_record_the_cost_as_unknown(self, tmp_path):
        """Counted, not priced -- an invented figure is worse than an honest null."""
        journal = tmp_path / "usage.jsonl"
        agent, _provider, _model = build(
            agent_config(),
            model=StubModel(usage=(1000, 500)),
            usage=UsageRecorder(history_path=str(journal)),
        )

        await agent.answer(query="why is the sky blue")

        line = next(l for l in journal_lines(journal) if l["tool"] == "answer")
        assert line["prompt_tokens"] == 1000
        assert line["model_cost_usd"] is None

    async def test_finish_reason_length_sets_truncated(self):
        agent, _provider, _model = build(
            agent_config(), model=StubModel(finish_reason="length")
        )

        response = await agent.answer(query="why is the sky blue")

        assert response.truncated is True

    async def test_a_complete_answer_does_not_serialise_truncated(self):
        agent, _provider, _model = build(agent_config())

        response = await agent.answer(query="why is the sky blue")

        assert response.truncated is None
        assert "truncated" not in response.model_dump()

    async def test_the_retrieval_lines_carry_the_run_and_the_step(self, tmp_path):
        journal = tmp_path / "usage.jsonl"
        agent, _provider, _model = build(
            agent_config(),
            usage=UsageRecorder(history_path=str(journal)),
        )

        await agent.answer(
            query="why is the sky blue",
            extra_queries=["rayleigh scattering"],
            depth="report",
        )

        lines = journal_lines(journal)
        answer = next(l for l in lines if l["tool"] == "answer")
        searches = [l for l in lines if l["tool"] == "search"]
        fetches = [l for l in lines if l["tool"] == "fetch"]
        assert [l["step"] for l in searches] == [1, 2]
        assert all(l["run"] == answer["run"] for l in searches)
        assert [l["step"] for l in fetches] == [1, 2]
        assert all(l["run"] == answer["run"] for l in fetches)
        # The retrieval spend is real provider spend and still counts as a search.
        assert answer["searches"] == 2
        assert answer["fetched"] == 2

    async def test_the_journal_counts_the_citations_the_prose_made(self, tmp_path):
        journal = tmp_path / "usage.jsonl"
        agent, _provider, _model = build(
            agent_config(),
            model=StubModel(content="One [1], an invented [7] and a stray [x]."),
            usage=UsageRecorder(history_path=str(journal)),
        )

        await agent.answer(query="why is the sky blue")

        line = next(l for l in journal_lines(journal) if l["tool"] == "answer")
        assert line["cited"] == 1
        assert line["cited_invalid"] == 2
        # `sources` is a count of the *results* cited, deduplicated by URL.
        assert line["sources"] == 1

    async def test_a_failed_model_call_still_records_the_retrieval(self, tmp_path):
        journal = tmp_path / "usage.jsonl"
        agent, _provider, _model = build(
            agent_config(),
            model=StubModel(status=500),
            usage=UsageRecorder(history_path=str(journal)),
        )

        with pytest.raises(AgentFailed):
            await agent.answer(query="why is the sky blue")

        lines = journal_lines(journal)
        assert [l["tool"] for l in lines].count("search") == 1
        line = next(l for l in lines if l["tool"] == "answer")
        assert line["error"] == "AgentFailed"
        assert line["prompt_tokens"] is None

    async def test_the_prose_rides_its_own_event_behind_log_content(
        self, log_records
    ):
        """`answer.ok` keeps a fixed shape; the prose is a separate, opt-in line."""
        agent, _provider, _model = build(agent_config(log_content=True))

        await agent.answer(query="why is the sky blue")

        events = [r.record["message"] for r in log_records]
        assert "answer.ok" in events
        assert "agent.answer" in events
        ok = next(r for r in log_records if r.record["message"] == "answer.ok")
        assert "answer" not in ok.record["extra"]
        prose = next(r for r in log_records if r.record["message"] == "agent.answer")
        assert "An answer, cited [1]." in str(prose.record["extra"]["answer"])


class TestSpecialTokenEscaping:
    """Escaping on the answer path: the prompt the model receives, and the prose out."""

    async def test_the_material_the_model_receives_is_already_escaped(self):
        """The retrieval engines escape before the plan assembles the material,
        so the model endpoint -- an ingress the caller never sees, and the
        incident's exact failure one hop earlier -- gets clean text."""
        model = StubModel(content="The end marker is <|endoftext|>. [1]")
        provider = StubProvider(
            results=[
                Result(
                    title="tokenizer docs",
                    url="https://example.com/tokens",
                    snippet="docs quote <|endoftext|> verbatim",
                )
            ]
        )
        agent, _p, _m = build(agent_config(), provider=provider, model=model)

        response = await agent.answer(query="what is the end token")

        assert "<|endoftext|>" not in model.material()
        assert f"<{ZWSP}|endoftext|>" in model.material()
        # The prose the model writes, echoing the token, leaves escaped.
        assert response.answer == f"The end marker is <{ZWSP}|endoftext|>. [1]"
        # And the citation validates to the escaped source.
        assert response.sources[0].title == "tokenizer docs"

    async def test_the_count_rides_answer_ok(self, log_records):
        model = StubModel(content="echoing <|im_start|> and [INST]")
        agent, _p, _m = build(agent_config(), model=model)

        await agent.answer(query="why is the sky blue")

        ok = next(r for r in log_records if r.record["message"] == "answer.ok")
        assert ok.record["extra"]["sanitized"] == 2

    async def test_a_clean_call_counts_zero(self, log_records):
        agent, _p, _m = build(agent_config())

        await agent.answer(query="why is the sky blue")

        ok = next(r for r in log_records if r.record["message"] == "answer.ok")
        assert ok.record["extra"]["sanitized"] == 0


class TestThroughTheMcpServer:
    """The tool itself: its schema, its refusal, and one call over the wire."""

    @staticmethod
    def _call(arguments: dict[str, object]) -> types.CallToolResult:
        async def run() -> types.CallToolResult:
            async with Client(server.mcp) as client:
                return await client.call_tool("answer", arguments)

        return asyncio.run(run())

    async def _tool(self) -> types.Tool:
        tools = await server.mcp.list_tools()
        return next(tool for tool in tools if tool.name == "answer")

    async def test_only_the_question_is_required(self):
        tool = await self._tool()

        assert tool.input_schema["required"] == ["query"]

    async def test_the_parameters_are_the_specs_and_nothing_else(self):
        tool = await self._tool()

        assert set(tool.input_schema["properties"]) == {
            "query",
            "extra_queries",
            "depth",
            "provider",
            "include_domains",
            "exclude_domains",
            "recency",
            "language",
            "safe_search",
        }
        # The four things that would make this an open proxy on the operator's key.
        for absent in ("max_results", "model", "temperature", "system_prompt"):
            assert absent not in tool.input_schema["properties"]

    async def test_the_parameter_bounds_are_the_specs(self):
        props = (await self._tool()).input_schema["properties"]

        assert props["query"]["minLength"] == 2
        assert props["query"]["maxLength"] == 400
        assert props["extra_queries"]["anyOf"][0]["maxItems"] == 2
        assert props["extra_queries"]["anyOf"][0]["items"]["minLength"] == 2
        assert props["extra_queries"]["anyOf"][0]["items"]["maxLength"] == 400
        assert props["depth"]["anyOf"][0]["enum"] == ["brief", "report"]
        assert props["recency"]["anyOf"][0]["enum"] == [
            "day",
            "week",
            "month",
            "year",
        ]
        assert props["include_domains"]["anyOf"][0]["maxItems"] == 20
        assert props["exclude_domains"]["anyOf"][0]["maxItems"] == 20
        # Two letters, exactly: a regional tag is refused by the schema rather
        # than narrowed silently on the way to an adapter.
        assert props["language"]["anyOf"][0]["minLength"] == 2
        assert props["language"]["anyOf"][0]["maxLength"] == 2
        assert props["safe_search"]["anyOf"][0]["type"] == "boolean"

    async def test_the_provider_pin_lists_every_adapter(self):
        props = (await self._tool()).input_schema["properties"]

        assert sorted(props["provider"]["anyOf"][0]["enum"]) == [
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

    async def test_the_response_model_is_the_specs(self):
        schema = (await self._tool()).output_schema

        assert schema is not None
        assert set(schema["properties"]) == {
            "query",
            "answer",
            "sources",
            "model",
            "depth",
            "searches",
            "fetched",
            "retrieved_at",
            "truncated",
            "notice",
        }
        # The caller is not the party paying, and the material is not theirs.
        for absent in ("cost_usd", "prompt_tokens", "completion_tokens", "material"):
            assert absent not in schema["properties"]

    def test_it_refuses_cleanly_when_agent_mode_is_off(
        self, monkeypatch, tmp_path
    ):
        config = tmp_path / "config.toml"
        config.write_text(f"[providers.{PROVIDER}]\nenabled = true\n")
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))
        monkeypatch.setattr(
            server, "build_providers", lambda _config, _client: {PROVIDER: StubProvider()}
        )

        result = self._call({"query": "why is the sky blue"})

        assert result.is_error
        text = _text(result)
        assert "agent mode disabled" in text
        assert "`search` or `fetch`" in text

    def test_it_serves_a_cited_answer_over_the_wire(self, monkeypatch, tmp_path):
        config = tmp_path / "config.toml"
        config.write_text(
            f"[providers.{PROVIDER}]\nenabled = true\n"
            "[agent]\n"
            "enabled = true\n"
            'base_url = "https://model.test/v1"\n'
            'model = "test-model"\n'
        )
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))
        monkeypatch.setattr(
            server, "build_providers", lambda _config, _client: {PROVIDER: StubProvider()}
        )
        model = StubModel(content="Rayleigh scattering [1].")
        real = AgentEngine
        # The transport is what is substituted: the plan, the engines and the
        # journal are the production ones.
        monkeypatch.setattr(
            server,
            "AgentEngine",
            lambda config, client, engine, fetch_engine=None, usage=None: real(
                config, model.client(), engine, fetch_engine, usage=usage
            ),
        )

        result = self._call({"query": "why is the sky blue"})

        assert not result.is_error, _text(result)
        payload = json.loads(_text(result))
        assert payload["answer"] == "Rayleigh scattering [1]."
        assert payload["model"] == "test-model"
        assert payload["depth"] == "brief"
        assert payload["searches"] == 1
        assert payload["fetched"] == 0
        assert payload["sources"] == [
            {
                "title": "About why is the sky blue",
                "url": "https://example.com/1",
                "provider": PROVIDER,
            }
        ]
        assert model.calls == 1
        assert set(payload) == {
            "query",
            "answer",
            "sources",
            "model",
            "depth",
            "searches",
            "fetched",
            "retrieved_at",
        }

    def test_a_failure_reaches_the_caller_as_a_tool_error(self, monkeypatch, tmp_path):
        config = tmp_path / "config.toml"
        config.write_text(
            f"[providers.{PROVIDER}]\nenabled = true\n"
            "[agent]\nenabled = true\n"
            'base_url = "https://model.test/v1"\n'
            'model = "test-model"\n'
        )
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))
        monkeypatch.setattr(
            server,
            "build_providers",
            lambda _config, _client: {PROVIDER: StubProvider(results=[])},
        )

        result = self._call({"query": "why is the sky blue"})

        assert result.is_error
        assert "Zero results usually means the phrasing" in _text(result)


class TestWiring:
    """What `build_app_context` hands the agent engine, and what it does not."""

    async def test_the_agent_engine_borrows_the_process_engines_and_client(
        self, monkeypatch
    ):
        seen: dict[str, httpx.AsyncClient] = {}
        real = AgentEngine

        def build_providers(_config: Config, client: httpx.AsyncClient) -> dict[str, Any]:
            seen["providers"] = client
            return {PROVIDER: StubProvider()}

        def agent_factory(
            config: Config,
            client: httpx.AsyncClient,
            engine: SearchEngine,
            fetch_engine: FetchEngine | None = None,
            usage: UsageRecorder | None = None,
        ) -> AgentEngine:
            seen["agent"] = client
            return real(config, client, engine, fetch_engine, usage=usage)

        monkeypatch.setattr(server, "build_providers", build_providers)
        monkeypatch.setattr(server, "AgentEngine", agent_factory)
        config = agent_config()

        async with server.build_app_context(config) as ctx:
            assert ctx.agent_engine is not None
            assert ctx.agent_engine.engine is ctx.engine
            assert ctx.agent_engine.fetch_engine is ctx.fetch_engine
            assert ctx.agent_engine.usage is ctx.usage

        assert seen["agent"] is seen["providers"]

    async def test_agent_mode_off_builds_no_engine(self, monkeypatch):
        monkeypatch.setattr(
            server, "build_providers", lambda _config, _client: {PROVIDER: StubProvider()}
        )
        config = Config(providers={PROVIDER: ProviderConfig()})

        async with server.build_app_context(config) as ctx:
            assert ctx.agent_engine is None

    async def test_the_startup_log_names_the_model(self, monkeypatch, log_records):
        """The one thing an operator must see about the new egress point."""
        monkeypatch.setattr(
            server, "build_providers", lambda _config, _client: {PROVIDER: StubProvider()}
        )

        async with server.build_app_context(agent_config()):
            pass

        startup = next(r for r in log_records if r.record["message"] == "startup")
        assert startup.record["extra"]["agent"] == "test-model"

    def test_an_incomplete_agent_section_refuses_to_start(self, monkeypatch, tmp_path):
        """A `SystemExit` before `mcp.run`, never inside `lifespan`.

        The missing-provider-key shape: a `SystemExit` raised inside `lifespan`
        arrives wrapped in an `ExceptionGroup` traceback, and a stdio server that
        dies miserably is the thing these messages exist to prevent.
        """
        config = tmp_path / "config.toml"
        config.write_text(
            '[providers."exa:free"]\nenabled = true\n\n[agent]\nenabled = true\n'
        )
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))
        monkeypatch.delenv("SEEKWRIGHT_AGENT_API_KEY", raising=False)
        served: list[dict[str, object]] = []
        monkeypatch.setattr(server.mcp, "run", lambda **kwargs: served.append(kwargs))

        with pytest.raises(SystemExit) as raised:
            server.main()

        message = str(raised.value)
        assert "agent mode is enabled but missing" in message
        assert "agent.base_url" in message
        assert "agent.model" in message
        assert "SEEKWRIGHT_AGENT_API_KEY" in message
        assert served == []


class TestThinModeUnchanged:
    """The acceptance criterion that `search` and `fetch` are untouched."""

    async def test_a_plain_search_line_carries_no_run_or_step(self, tmp_path):
        journal = tmp_path / "usage.jsonl"
        config = agent_config()
        engine = SearchEngine(
            config, {PROVIDER: StubProvider()}, usage=UsageRecorder(history_path=str(journal))
        )

        await engine.search(SearchQuery(query="sqlite wal mode"))

        line = journal_lines(journal)[0]
        assert line["tool"] == "search"
        assert "run" not in line
        assert "step" not in line

    async def test_a_plain_fetch_line_carries_no_run_or_step(self, tmp_path):
        journal = tmp_path / "usage.jsonl"
        config = agent_config()
        engine = FetchEngine(
            config, StubFetcher(), usage=UsageRecorder(history_path=str(journal))
        )

        await engine.fetch("https://example.com/a")

        line = journal_lines(journal)[0]
        assert line["tool"] == "fetch"
        assert "run" not in line
        assert "step" not in line

    def test_the_search_and_fetch_models_gained_no_fields(self):
        """`SearchResponse`/`FetchResponse` are the thin-mode wire contract."""
        assert set(SearchResponse.model_fields) == {
            "query",
            "provider",
            "results",
            "answer",
            "retrieved_at",
            "notice",
        }
        assert set(FetchResponse.model_fields) == {
            "url",
            "requested_url",
            "title",
            "text",
            "content_type",
            "status_code",
            "retrieved_at",
            "truncated",
            "total_chars",
            "offset",
            "matches",
            "image",
            "notice",
        }
