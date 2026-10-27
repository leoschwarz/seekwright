"""Agent mode: the ``answer`` tool's model client and its fixed retrieval plan.

One rule carries the whole decision: **the model never drives retrieval**. The
server decides what to fetch -- the caller's question, up to two extra queries,
five results from each, and up to three pages through the fetch ladder -- and
the model writes prose over that material. Letting the model loop over
``search`` and ``fetch`` would make the per-call cost the *model's* decision,
enforced only by the reserve-then-reconcile ledger ROADMAP §5 declines. A fixed
plan costs a bounded amount by arithmetic, so there is exactly one model call
per ``answer`` and no loop anywhere in this module.

The client is one POST to an OpenAI-compatible ``/chat/completions`` on the
shared ``httpx`` client -- no SDK, and no tokenizer: the endpoint reports
``usage``. The retrieval steps run through the same
``SearchEngine``/``FetchEngine`` the tools use, so the provider ladder, the
health board, the SSRF guardrails and the journal lines behave as they do for a
``search`` or a ``fetch`` call.

The material is untrusted third-party text on its way to a model, and the caller
never sees it -- which is why the system prompt says so, and why the prose must
be read against the ``sources`` the server built.
"""

from __future__ import annotations

import asyncio
import re
import secrets
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Literal, cast

import httpx

from .config import Config
from .engine import FetchEngine, FetchFailed, SearchEngine, SearchFailed
from .logs import bind, elapsed_ms, safe
from .models import (
    AnswerResponse,
    AnswerSource,
    Result,
    SearchQuery,
    SearchResponse,
)
from .prompts import ANSWER_SYSTEM_PROMPT
from .sanitize import sanitize_text
from .usage import UsageRecorder

# The plan's width, as constants rather than config: these counts bound the per-call cost,
# and the tool schema is frozen at import so nothing config-derived could reach it anyway.
RESULTS_PER_QUERY = 5
PAGES_PER_REPORT = 3

# The server's, never the caller's: a caller-set temperature would be one more thing set on the operator's account.
TEMPERATURE = 0.2

# The spec's own ~4 characters-per-token estimate, used only for the money ceiling and never for a reported token count.
_CHARS_PER_TOKEN = 4

# The two depths' output instructions, sent with the question; the shapes they ask for are described in `answer_system.txt`.
_DEPTH_INSTRUCTION: dict[str, str] = {
    "brief": "Answer in a few sentences.",
    "report": "Write a short structured answer.",
}

# A citation marker, and what separates it from other bracketed prose: link text follows `(`; whitespace disqualifies a token.
# Counting either as a malformed citation would fire the `cited_invalid` notice on well-formed prose.
_MARKER = re.compile(r"\[([^\[\]\n]{1,32})\](?!\()")


def _now() -> str:
    """The response's timestamp, in the shape the other tools report."""
    return datetime.now(UTC).isoformat(timespec="seconds")


def _token_count(value: object) -> int | None:
    """The endpoint's own token count, or ``None``.

    Never a local estimate: a tokenizer would be a dependency, and an invented
    figure is worse than an honest absence.
    """
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


class AgentFailed(Exception):
    """The answer could not be produced. The message is written for the model."""


@dataclass
class _Material:
    """One numbered item handed to the model, kept for citation validation."""

    index: int
    title: str
    url: str
    provider: str
    text: str


@dataclass
class _Tally:
    """What the call got through, for the journal line and the response.

    Updated as the plan runs rather than assembled at the end: a call that dies
    at the model still has to record the retrieval it already paid for.
    """

    searches: int = 0
    results: int = 0
    fetched: int = 0
    material_chars: int = 0
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    answer_chars: int = 0
    cited: int = 0
    cited_invalid: int = 0
    sources: int = 0


@dataclass
class _Plan:
    """What the retrieval walk produced, before the model is called."""

    items: list[_Material]
    rendered: str
    notices: list[str] = field(default_factory=list)


@dataclass
class _Completion:
    """The endpoint's answer, read out and sanitised."""

    prose: str
    truncated: bool
    prompt_tokens: int | None
    completion_tokens: int | None


@dataclass
class _Citations:
    """What the prose actually cited, validated against the material."""

    cited: int
    cited_invalid: int
    sources: list[AnswerSource]


class AgentEngine:
    """Run the fixed plan, make the one model call, validate what it cited.

    Borrows the process's ``SearchEngine``, ``FetchEngine``, ``httpx`` client and
    usage recorder: the retrieval steps must be the same calls a ``search`` or a
    ``fetch`` would make, and the spend must land in the same aggregates.
    """

    def __init__(
        self,
        config: Config,
        client: httpx.AsyncClient,
        engine: SearchEngine,
        fetch_engine: FetchEngine | None = None,
        usage: UsageRecorder | None = None,
    ) -> None:
        self.config = config
        self.client = client
        self.engine = engine
        # None whenever `[fetch] enabled = false`: a `report` is still served from snippets,
        # with a notice saying no pages could be read.
        self.fetch_engine = fetch_engine
        self.usage = usage

    async def answer(
        self,
        *,
        query: str,
        extra_queries: list[str] | None = None,
        depth: Literal["brief", "report"] | None = None,
        provider: str | None = None,
        include_domains: list[str] | None = None,
        exclude_domains: list[str] | None = None,
        recency: Literal["day", "week", "month", "year"] | None = None,
        language: str | None = None,
        safe_search: bool | None = None,
    ) -> AnswerResponse:
        """Answer one question: fixed plan, one model call, validated citations.

        The whole call is bounded by ``agent.timeout_seconds``. Every failure
        path records the ``answer`` journal line before raising, so the retrieval
        spend the engine already incurred has a line to sit beside.
        """
        missing = self.config.missing_agent_settings()
        if missing:
            # Unreachable on a server that started -- `server.main` refuses to run in this state.
            # A direct construction gets an error naming the missing piece.
            raise AgentFailed(
                "Agent mode is not configured on this server: "
                + ", ".join(missing)
                + " is missing."
            )
        settings = self.config.agent
        selected: Literal["brief", "report"] = depth or "brief"
        run = secrets.token_hex(8)
        started = time.monotonic()
        tally = _Tally()
        # Names the phase the call died in: "retrieving" and "calling the model" have different recoveries.
        phase = "retrieving"
        try:
            async with asyncio.timeout(settings.timeout_seconds):
                plan = await self._retrieve(
                    run=run,
                    tally=tally,
                    depth=selected,
                    query=query,
                    extra_queries=extra_queries,
                    provider=provider,
                    include_domains=include_domains,
                    exclude_domains=exclude_domains,
                    recency=recency,
                    language=language,
                    safe_search=safe_search,
                )
                phase = "calling the model"
                completion = await self._complete(
                    material=plan.rendered, query=query, depth=selected
                )
        except TimeoutError as exc:
            self._record(tally, run=run, depth=selected, started=started, error="TimeoutError")
            raise AgentFailed(
                f"The answer call exceeded {settings.timeout_seconds:g}s while "
                f"{phase}; no answer was produced."
            ) from exc
        except AgentFailed as exc:
            self._record(
                tally,
                run=run,
                depth=selected,
                started=started,
                error=type(exc).__name__,
            )
            raise

        prose = completion.prose
        tally.prompt_tokens = completion.prompt_tokens
        tally.completion_tokens = completion.completion_tokens
        tally.answer_chars = len(prose)
        citations = self._cite(prose, plan.items)
        tally.cited = citations.cited
        tally.cited_invalid = citations.cited_invalid
        tally.sources = len(citations.sources)
        notices = [*plan.notices, *self._citation_notices(citations)]
        notice = "; ".join(notices) or None
        # The prose can echo the material's tokens back, so it gets the same escape as everything
        # that leaves. The count rides `answer.ok`, as its siblings ride `search.ok` and `fetch.ok`.
        sanitized = 0
        prose, n = sanitize_text(prose)
        sanitized += n
        for source in citations.sources:
            source.title, n = sanitize_text(source.title)
            sanitized += n
        self._record(
            tally,
            run=run,
            depth=selected,
            started=started,
            notice=notice,
            sanitized=sanitized,
        )
        self._log_content(prose, run=run, depth=selected)
        return AnswerResponse(
            query=query,
            answer=prose,
            sources=citations.sources,
            model=cast("str", settings.model),
            depth=selected,
            searches=tally.searches,
            fetched=tally.fetched,
            retrieved_at=_now(),
            # `None` rather than False, so a complete answer does not serialise a false -- the `Result.text_truncated` rule.
            truncated=completion.truncated or None,
            notice=notice,
        )

    async def _retrieve(
        self,
        *,
        run: str,
        tally: _Tally,
        depth: Literal["brief", "report"],
        query: str,
        extra_queries: list[str] | None,
        provider: str | None,
        include_domains: list[str] | None,
        exclude_domains: list[str] | None,
        recency: Literal["day", "week", "month", "year"] | None,
        language: str | None,
        safe_search: bool | None,
    ) -> _Plan:
        """Search, read pages, assemble the numbered material.

        Raises ``AgentFailed`` -- before any model call -- when there is nothing
        to ground prose in: paying a model to invent an answer over an empty
        result set is worse than telling the caller the search found nothing.
        """
        # `brief` is one search by contract -- the depth's cost knob.
        queries = [query, *(extra_queries or [])] if depth == "report" else [query]
        responses: list[SearchResponse] = []
        failed: list[int] = []
        # The first step's message, kept for the all-steps-failed error: the ladder's wording explains the search asked for.
        first_failure: str | None = None
        empty: list[int] = []
        ceiling = self.config.agent.max_cost_usd
        spent = 0.0
        for step, text in enumerate(queries, 1):
            before = self._spent()
            tally.searches += 1
            try:
                response = await self.engine.search(
                    SearchQuery(
                        query=text,
                        max_results=RESULTS_PER_QUERY,
                        include_domains=include_domains or [],
                        exclude_domains=exclude_domains or [],
                        recency=recency,
                        language=language,
                        safe_search=safe_search,
                    ),
                    provider=provider,
                    run=run,
                    step=step,
                )
            except SearchFailed as exc:
                # Recorded by the engine already; the walk continues, and only an all-steps-empty call is fatal.
                failed.append(step)
                if first_failure is None:
                    first_failure = str(exc)
                continue
            responses.append(response)
            if not response.results:
                empty.append(step)
            spent += self._spent() - before
            if ceiling is not None and (
                spent + self._worst_case_model_cost(depth) > ceiling
            ):
                raise AgentFailed(
                    f"Retrieval spend reached ${spent:.4f} after step {step} and "
                    f"the model call could push the total past the "
                    f"${ceiling:.2f} per-call ceiling (agent.max_cost_usd); the "
                    "call was aborted."
                )

        if not responses and first_failure is not None:
            raise AgentFailed(first_failure)
        if not any(response.results for response in responses):
            # Every step answered and came back with nothing: the engine's zero-result prose already names the retry.
            raise AgentFailed(
                next(
                    (
                        response.notice
                        for response in responses
                        if response.notice is not None
                    ),
                    "No results were returned for this question; retry or rephrase.",
                )
            )

        notices: list[str] = []
        if failed or empty:
            notices.append(self._partial_notice(len(queries), failed, empty))

        hits = [
            (result, response.provider)
            for response in responses
            for result in response.results
        ]
        tally.results = len(hits)
        texts: list[str | None] = [None] * len(hits)
        if depth == "report":
            # Pages are a `report` widening; a `brief` answers from snippets alone, which is what makes it the cheaper depth.
            texts = await self._read_pages(
                hits, run=run, tally=tally, notices=notices
            )
        plan = self._assemble(hits, texts)
        plan.notices = notices
        if not plan.items or not any(item.text.strip() for item in plan.items):
            raise AgentFailed(
                "The retrieval returned nothing usable to ground an answer in; "
                "retry, or rephrase the question."
            )
        tally.material_chars = len(plan.rendered)
        return plan

    async def _read_pages(
        self,
        hits: list[tuple[Result, str]],
        *,
        run: str,
        tally: _Tally,
        notices: list[str],
    ) -> list[str | None]:
        """Read up to three pages, in result order; ``None`` where nothing came back.

        Only a ``report`` reads pages, and only for results that carry no
        ``text``: a content backend already handed us the extract, and fetching
        it again would bill twice for the same prose. A page that fails or
        extracts to nothing is skipped rather than fatal, and the count travels
        in ``notice`` so a thin answer is visible as such.
        """
        texts: list[str | None] = [None] * len(hits)
        if self.fetch_engine is None:
            notices.append(
                "no pages could be read (this server has the fetch tool "
                "disabled), so the answer is grounded in search snippets alone"
            )
            return texts
        attempts = 0
        skipped = 0
        for index, (result, _provider) in enumerate(hits):
            if result.text:
                texts[index] = result.text
                continue
            if attempts >= PAGES_PER_REPORT:
                break
            attempts += 1
            try:
                # The plan asks for the walk on the call. `fetch.auto_fallback` is
                # off for routes with a caller in front of them; here nobody is
                # between the steps to act on a list of names, so a refusal would
                # be a lost page.
                page = await self.fetch_engine.fetch(
                    result.url, run=run, step=attempts, auto_fallback=True
                )
            except FetchFailed:
                # Logged and journalled by the fetch engine already; one unreadable page must not take the answer down with it.
                skipped += 1
                continue
            if page.text and page.text.strip():
                texts[index] = page.text
                tally.fetched += 1
            else:
                skipped += 1
        if skipped:
            notices.append(
                f"{skipped} of {attempts} pages could not be read; the answer is "
                "grounded in the rest of the material"
            )
        return texts

    def _assemble(
        self, hits: list[tuple[Result, str]], texts: list[str | None]
    ) -> _Plan:
        """Number the material from 1, bounded by ``agent.max_material_chars``.

        The bound is on what is handed over -- index, title, URL and body -- so
        the input side of the model call is a number rather than a property of
        whatever the providers returned. The same URL can appear at two indices;
        both are valid citations, and ``sources`` deduplicates by URL.
        """
        cap = self.config.agent.max_material_chars
        items: list[_Material] = []
        blocks: list[str] = []
        used = 0
        for (result, provider), text in zip(hits, texts, strict=True):
            # A `brief` has no page text, so its body is the provider's own: a content
            # backend fills `text`, a SERP backend fills `snippet`.
            body = text if text is not None else (result.text or result.snippet or "")
            header = f"[{len(items) + 1}] {result.title}\n{result.url}\n"
            room = cap - used - len(header)
            if room <= 0:
                break
            clipped = body[:room]
            items.append(
                _Material(
                    index=len(items) + 1,
                    title=result.title,
                    url=result.url,
                    provider=provider,
                    text=clipped,
                )
            )
            blocks.append(header + clipped)
            used += len(header) + len(clipped)
            if len(clipped) < len(body):
                # The cap was reached mid-item: everything after it is over budget, so the numbering stops here.
                break
        return _Plan(items=items, rendered="\n\n".join(blocks))

    async def _complete(
        self, *, material: str, query: str, depth: Literal["brief", "report"]
    ) -> _Completion:
        """One POST to the endpoint's chat-completions path, sanitised on the way out.

        The redaction rule applies with the same force as in a provider adapter:
        an httpx exception carries the request headers, and those carry the API
        key, so only the status code, the exception *type* and fixed prose reach
        the caller.
        """
        settings = self.config.agent
        payload = {
            "model": settings.model,
            "messages": [
                {"role": "system", "content": ANSWER_SYSTEM_PROMPT},
                {"role": "user", "content": self._user_message(material, query, depth)},
            ],
            "temperature": TEMPERATURE,
            "max_tokens": self._output_cap(depth),
            # Never streamed: the caller waits for one answer, and a stream would need a
            # second code path and a partial-prose failure mode this contract does not have.
            "stream": False,
        }
        try:
            response = await self.client.post(
                f"{(settings.base_url or '').rstrip('/')}/chat/completions",
                json=payload,
                headers={"Authorization": f"Bearer {self.config.agent_api_key() or ''}"},
                timeout=settings.model_timeout_seconds,
            )
        except httpx.TimeoutException as exc:
            raise AgentFailed(
                f"The model ({settings.model}) did not answer within "
                f"{settings.model_timeout_seconds:g}s; no answer was produced."
            ) from exc
        except httpx.HTTPError as exc:
            # The type only: "a ConnectError happened" is the diagnostic value, no payload (logs.py states the same rule).
            raise AgentFailed(
                f"The model endpoint could not be reached "
                f"({type(exc).__name__}); no answer was produced."
            ) from exc
        if response.status_code != 200:
            raise AgentFailed(
                f"The model endpoint ({settings.model}) returned HTTP "
                f"{response.status_code}; no answer was produced."
            )
        return self._read_completion(response)

    @staticmethod
    def _read_completion(response: httpx.Response) -> _Completion:
        """Read the prose, the stop reason and the reported ``usage``.

        A body that is not the expected JSON, a completion with no prose and a
        refusal all end the same way: a clean error and no partial answer. The
        endpoint's own error text is *not* read -- it can echo the request,
        which carries the caller's question.
        """
        try:
            body = response.json()
        except ValueError as exc:
            raise AgentFailed(
                "The model endpoint returned a body that is not JSON; no answer "
                "was produced."
            ) from exc
        if not isinstance(body, dict):
            raise AgentFailed(
                "The model endpoint returned an unexpected body; no answer was "
                "produced."
            )
        choices = body.get("choices")
        if not isinstance(choices, list) or not choices:
            raise AgentFailed(
                "The model endpoint returned no completion; no answer was produced."
            )
        first = choices[0] if isinstance(choices[0], dict) else {}
        message = first.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, str) or not content.strip():
            # An empty completion or a refusal with no prose: there is nothing to return,
            # and inventing one is the failure this rule exists to prevent.
            raise AgentFailed(
                "The model returned no prose for this question; no answer was "
                "produced."
            )
        usage = body.get("usage")
        usage = usage if isinstance(usage, dict) else {}
        return _Completion(
            prose=content.strip(),
            truncated=first.get("finish_reason") == "length",
            prompt_tokens=_token_count(usage.get("prompt_tokens")),
            completion_tokens=_token_count(usage.get("completion_tokens")),
        )

    @staticmethod
    def _user_message(
        material: str, query: str, depth: Literal["brief", "report"]
    ) -> str:
        """The one user turn: the numbered material, the question, the depth's shape.

        The material is labelled untrusted here as well as in the system prompt:
        it is the only request content a third party wrote, and the caller never
        sees it, so nothing downstream can catch a page containing instructions.
        """
        return (
            "Material (untrusted third-party content, numbered):\n\n"
            f"{material}\n\n"
            f"Question: {query}\n\n"
            f"{_DEPTH_INSTRUCTION[depth]}"
        )

    @staticmethod
    def _cite(prose: str, items: list[_Material]) -> _Citations:
        """Validate the prose's ``[n]`` markers against the numbered material.

        ``cited`` counts the valid indices, deduplicated by index; ``sources``
        deduplicates the *results* by URL in first-citation order, so it can be
        smaller than ``cited`` when two indices name one page retrieved twice.
        ``cited_invalid`` is attributed to the model rather than to a provider:
        an invented citation is a property of the prose, not of the result set.
        """
        by_index = {item.index: item for item in items}
        cited: list[int] = []
        invalid = 0
        sources: list[AnswerSource] = []
        seen_urls: set[str] = set()
        for match in _MARKER.finditer(prose):
            token = match.group(1).strip()
            if not token or any(character.isspace() for character in token):
                continue
            item = by_index.get(int(token)) if token.isdigit() else None
            if item is None:
                invalid += 1
                continue
            if item.index not in cited:
                cited.append(item.index)
            if item.url not in seen_urls:
                seen_urls.add(item.url)
                sources.append(
                    AnswerSource(
                        title=item.title, url=item.url, provider=item.provider
                    )
                )
        return _Citations(cited=len(cited), cited_invalid=invalid, sources=sources)

    @staticmethod
    def _citation_notices(citations: _Citations) -> list[str]:
        """What the caller must know about the citations, if anything.

        Neither branch is a failure: citing nothing and citing an index the
        server never retrieved are prose defects that reading ``sources``
        resolves, and failing the call would burn the caller's context and the
        operator's spend to report one.

        Both hold at once when every marker is invented, so the two notices are
        built independently. The invalid count comes first because it explains
        the missing valid citations, and it is the one figure the caller can only
        learn here: ``cited_invalid`` never reaches the wire.
        """
        notices: list[str] = []
        count = citations.cited_invalid
        if count == 1:
            notices.append(
                "the answer cites 1 index that is not in the retrieved "
                "material; that citation was dropped from `sources`"
            )
        elif count > 1:
            notices.append(
                f"the answer cites {count} indices that are not in the retrieved "
                "material; those citations were dropped from `sources`"
            )
        if citations.cited == 0:
            notices.append(
                "the answer carries no citations; read it against `sources`"
            )
        return notices

    @staticmethod
    def _partial_notice(total: int, failed: list[int], empty: list[int]) -> str:
        """Name the retrieval steps that came back empty, by ordinal.

        The caller cannot see the walk, so "2 of 3 retrieval steps returned
        results" is the difference between a thin answer and a thin question.
        """
        detail: list[str] = []
        if failed:
            detail.append("failed: " + ", ".join(f"step {step}" for step in failed))
        if empty:
            detail.append("no results: " + ", ".join(f"step {step}" for step in empty))
        return (
            f"{total - len(failed) - len(empty)} of {total} retrieval steps "
            f"returned results ({'; '.join(detail)})"
        )

    def _output_cap(self, depth: Literal["brief", "report"]) -> int:
        """The depth's output ceiling, sent as the endpoint's own cap."""
        settings = self.config.agent
        return (
            settings.max_output_tokens_report
            if depth == "report"
            else settings.max_output_tokens_brief
        )

    def _worst_case_model_cost(self, depth: Literal["brief", "report"]) -> float:
        """The most the one model call can cost at the configured prices.

        Zero when either price is unset: the structural bound -- the counts --
        is what remains, the same "counted, not priced" rule that leaves
        ``model_cost_usd`` null. The material's token count is estimated at
        ``_CHARS_PER_TOKEN``, which only ever feeds this ceiling.
        """
        settings = self.config.agent
        if settings.cost_per_1k_in is None or settings.cost_per_1k_out is None:
            return 0.0
        return (
            settings.max_material_chars / _CHARS_PER_TOKEN / 1000 * settings.cost_per_1k_in
            + self._output_cap(depth) / 1000 * settings.cost_per_1k_out
        )

    def _spent(self) -> float:
        """Search spend so far, or 0.0 when nothing is counting.

        Read off the process recorder's in-memory aggregate. A diff of this
        figure across a step is the step's spend; under concurrent calls it can
        only over-count, and the ceiling is ~11x the structural worst case, so
        that cannot abort a call near its budget.
        """
        return 0.0 if self.usage is None else self.usage.search_cost_usd()

    def _model_cost(self, tally: _Tally) -> float | None:
        """The model spend from the endpoint's counts, or ``None`` when unknown.

        Unset prices mean unknown, never ``0.0``: an invented figure is worse
        than an honest "counted, not priced".
        """
        settings = self.config.agent
        if (
            tally.prompt_tokens is None
            or tally.completion_tokens is None
            or settings.cost_per_1k_in is None
            or settings.cost_per_1k_out is None
        ):
            return None
        return (
            tally.prompt_tokens / 1000 * settings.cost_per_1k_in
            + tally.completion_tokens / 1000 * settings.cost_per_1k_out
        )

    def _record(
        self,
        tally: _Tally,
        *,
        run: str,
        depth: Literal["brief", "report"],
        started: float,
        error: str | None = None,
        notice: str | None = None,
        sanitized: int | None = None,
    ) -> None:
        """Write the one ``answer`` journal line and the operator's log line.

        Called on every path, failures included: ``error`` is what makes a
        failed answer visible to the dashboard. The log line carries the journal
        line's fields plus ``sanitized`` -- the response's escape count, carried
        as null on a failure rather than omitted, so a number traces from one
        line to the other without a second query.
        """
        ms = elapsed_ms(started)
        model_cost = self._model_cost(tally)
        if self.usage is not None:
            self.usage.record_answer(
                run=run,
                model=self.config.agent.model,
                depth=depth,
                searches=tally.searches,
                results=tally.results,
                fetched=tally.fetched,
                material_chars=tally.material_chars,
                prompt_tokens=tally.prompt_tokens,
                completion_tokens=tally.completion_tokens,
                answer_chars=tally.answer_chars,
                cited=tally.cited,
                cited_invalid=tally.cited_invalid,
                sources=tally.sources,
                model_cost_usd=model_cost,
                ms=ms,
                error=error,
            )
        log = bind(
            run=run,
            model=self.config.agent.model,
            depth=depth,
            ms=ms,
            searches=tally.searches,
            results=tally.results,
            fetched=tally.fetched,
            material_chars=tally.material_chars,
            prompt_tokens=tally.prompt_tokens,
            completion_tokens=tally.completion_tokens,
            answer_chars=tally.answer_chars,
            cited=tally.cited,
            cited_invalid=tally.cited_invalid,
            sources=tally.sources,
            model_cost_usd=model_cost,
            notice=notice,
            sanitized=sanitized,
        )
        if error is None:
            log.info("answer.ok")
        else:
            log.bind(error=error).warning("answer.failed")

    def _log_content(
        self, prose: str, *, run: str, depth: Literal["brief", "report"]
    ) -> None:
        """Emit ``agent.answer``: the prose, behind ``logging.log_content``.

        Its own event, alongside ``search.answer`` and ``fetch.content``, so
        ``answer.ok`` keeps a fixed shape and the prose's length cannot decide
        how long that line gets. Clipped to ``max_material_chars``.
        """
        if not self.config.logging.log_content:
            return
        bind(
            run=run,
            depth=depth,
            answer=safe(prose, self.config.agent.max_material_chars),
        ).info("agent.answer")
