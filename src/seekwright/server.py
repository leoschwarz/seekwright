"""The MCP server: three tools, `search`, `fetch` and `answer`.

No cache, so every `search` reaches a live provider and the tool descriptions
make a model search deliberately rather than reflexively. `answer` is agent mode:
one fixed retrieval plan, one model call, citations the server validated
(docs/reference/agent-mode.md). Off unless `[agent] enabled = true`; off, it
refuses cleanly.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import time
from collections.abc import AsyncGenerator
from dataclasses import dataclass
from typing import Annotated, Any, Literal, cast

import anyio
import httpx
from mcp.server.mcpserver import Context, MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.transport_security import (
    TransportSecurityMiddleware,
    TransportSecuritySettings,
)
from mcp.types import (
    CallToolResult,
    ContentBlock,
    ImageContent,
    TextContent,
    ToolAnnotations,
)
from pydantic import Field, ValidationError
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, Response

from .agent import AgentEngine, AgentFailed
from .config import UNTESTED_PROVIDERS, Config, LogLevel, api_key_env_var, load_config
from .dashboard import DASHBOARD_HTML
from .engine import (
    FetchEngine,
    FetchFailed,
    FetchRefused,
    SearchEngine,
    SearchFailed,
    SearchRefused,
)
from .factory import (
    ExtractorUnavailable,
    build_extractor,
    build_fetch_stack,
    build_providers,
)
from .fetcher import IMAGE_TYPES
from .health import HealthBoard, HealthMonitor
from .logs import apply_log_overrides, bind, setup_logging, to_stdlib_level
from .models import (
    AnswerRequest,
    AnswerResponse,
    FetchRequest,
    FetchResponse,
    SearchQuery,
    SearchRequest,
    SearchResponse,
)
from .prompts import (
    ANSWER_DESCRIPTION,
    FETCH_DESCRIPTION,
    SEARCH_DESCRIPTION,
    SERVER_INSTRUCTIONS,
)
from .providers.base import SearchProvider
from .usage import UsageRecorder


@dataclass
class AppContext:
    config: Config
    engine: SearchEngine
    # Before `fetch_engine`, which carries a default: a dataclass cannot put a
    # required field after an optional one.
    usage: UsageRecorder
    # None whenever `[fetch] enabled = false`: the tool stays registered, so "off"
    # is a clean refusal rather than an advertised tool that then fails.
    fetch_engine: FetchEngine | None = None
    # None whenever `[agent] enabled = false`, the default; same rule.
    agent_engine: AgentEngine | None = None


@contextlib.asynccontextmanager
async def build_app_context(config: Config) -> AsyncGenerator[AppContext]:
    """Own the shared httpx client and the upstream MCP sessions for the process.

    Per-request ownership would discard connection reuse, and for MCP-client
    providers re-handshake (or respawn a subprocess) on every search. Entered once
    per *process*, which is not once per `lifespan` -- see the note there.
    """
    # Before the client and the engines: a bad `dashboard.history_path` is a
    # config problem, and should read as one rather than as a crash later.
    try:
        usage = UsageRecorder(history_path=config.dashboard.history_path)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"seekwright: dashboard.history_path: {exc}") from exc
    async with httpx.AsyncClient(follow_redirects=True) as client:
        providers = build_providers(config, client)
        # One board for the process: the engine records real traffic on it, the
        # monitor probes against it, and both must agree on who is up.
        board = HealthBoard(
            failure_threshold=config.search.health_failure_threshold,
            cooldown_seconds=config.search.health_cooldown_seconds,
        )
        engine = SearchEngine(config, providers, health=board, usage=usage)
        # Before the monitor task: a missing extraction-backend library raises
        # here, and the `finally` sits below that raise. `build_fetch_stack`
        # closes a stack whose constructor raised.
        fetcher, fallbacks = await build_fetch_stack(config)
        monitor = HealthMonitor(
            config=config, providers=providers, client=client, board=board
        )
        monitor_task = (
            asyncio.create_task(monitor.run(), name="health-monitor")
            if config.search.health_interval_seconds > 0.0
            else None
        )
        try:
            await _warm_up_providers(providers)
            bind(
                providers=",".join(config.enabled_providers()),
                default_provider=config.default_provider,
                # True when the set above is the implicit keyless set.
                providers_defaulted=config.providers_defaulted,
                # Enabled providers that shipped untested (config.UNTESTED_PROVIDERS).
                untested=(
                    ",".join(
                        sorted(set(config.enabled_providers()) & UNTESTED_PROVIDERS)
                    )
                    or None
                ),
                # Comma-joined, or `None` when unset: a refusal is the wrong
                # moment to learn a policy is active.
                permitted=(
                    ",".join(config.permitted_providers)
                    if config.permitted_providers is not None
                    else None
                ),
                fetch=config.fetch.enabled,
                fetch_extractor=config.fetch.extractor,
                fetch_fallbacks=",".join(fallback.name for fallback in fallbacks) or None,
                fetch_primary=config.fetch.primary,
                search_fallbacks=",".join(config.search.fallback or []) or None,
                # The one fact an operator needs about the new egress point without
                # reading the config back. `None` when agent mode is off.
                agent=config.agent.model,
            ).info("startup")
            # Built before the yield because the agent engine borrows both
            # engines and the same journal the spend lands in.
            fetch_engine = (
                FetchEngine(config, fetcher, fallbacks, usage=usage)
                if fetcher is not None
                else None
            )
            yield AppContext(
                config=config,
                engine=engine,
                usage=usage,
                fetch_engine=fetch_engine,
                agent_engine=(
                    AgentEngine(config, client, engine, fetch_engine, usage=usage)
                    if config.agent.enabled
                    else None
                ),
            )
        finally:
            if monitor_task is not None:
                monitor_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await monitor_task
            for provider in providers.values():
                await provider.aclose()
            if fetcher is not None:
                await fetcher.aclose()
            for fallback in fallbacks:
                await fallback.aclose()
            bind().info("shutdown")


async def _warm_up_providers(providers: dict[str, SearchProvider]) -> None:
    """Open upstream MCP sessions now rather than on the first request.

    The alternative is a handshake billed to a user-visible search. `warmup`
    returns False rather than raising, so a cold upstream does not stop the
    server -- so the failure has to be logged: a deployment answering every
    search from the *keyed* fallback because the free session never opened looks
    identical from outside.
    """
    for name, provider in providers.items():
        warmup = getattr(provider, "warmup", None)
        if warmup is not None and not await warmup():
            bind(provider=name).warning("warmup.failed")


_shared: AppContext | None = None
"""Process-owned context, set only by the HTTP path. See `lifespan`."""


@contextlib.asynccontextmanager
async def lifespan(_server: MCPServer) -> AsyncGenerator[AppContext]:
    """Hand the running server its context.

    Building the context here would tie it to the server's own lifetime, and the
    HTTP path needs it to outlive nothing but the socket: it has to open before
    `uvicorn.Server.serve()` and close after, which a lifespan the session
    manager runs cannot express.

    The HTTP path therefore builds the context itself and parks it in `_shared`;
    this hands out a reference. Under stdio `_shared` is never set.
    """
    if _shared is not None:
        yield _shared
        return
    async with build_app_context(load_config()) as ctx:
        yield ctx


mcp = MCPServer(
    "seekwright",
    instructions=SERVER_INSTRUCTIONS,
    lifespan=lifespan,
)


# The server matches this annotation against the bare `Context` class at runtime,
# so it cannot be subscripted even though `Context` is generic. That is also why
# the cast is here: the class is unparameterised, so mcp 2's own typing reads the
# lifespan value back as `dict[str, Any]`. Through `object` because the two types
# do not overlap, which is exactly what the cast asserts.
def _ctx(ctx: Context) -> AppContext:
    return cast(AppContext, cast(object, ctx.request_context.lifespan_context))


# One mapping per operation, run by both encodings: the tool builds the request model, the route validates one from the body.
# tests/test_api.py pins the tool schema, the request model and these mappings to one field set.


async def _run_search(engine: SearchEngine, req: SearchRequest) -> SearchResponse:
    """The `search` mapping: one `SearchRequest`, one engine call.

    The domain lists default to `[]` rather than null, which is what the adapters
    read, and `provider`/`mode` stay outside the query: they choose which
    provider runs rather than filter what it returns.
    """
    return await engine.search(
        SearchQuery(
            query=req.query,
            max_results=req.max_results,
            include_domains=req.include_domains or [],
            exclude_domains=req.exclude_domains or [],
            recency=req.recency,
            language=req.language,
            safe_search=req.safe_search,
        ),
        provider=req.provider,
        mode=req.mode,
    )


async def _run_fetch(engine: FetchEngine, req: FetchRequest) -> FetchResponse:
    """The `fetch` mapping: `offset` takes its default here, where both
    encodings reach it, and `query` and `path` go through as given -- the
    fetcher distinguishes "not narrowed", "narrowed to these terms" and
    "narrowed to this subtree". `provider` goes through as written, including the
    null that *is* the local read: `engine.resolve` decides what a name means.
    """
    return await engine.fetch(
        req.url,
        offset=req.offset or 0,
        query=req.query,
        path=req.path,
        provider=req.provider,
    )


def _image_block(response: FetchResponse) -> ImageContent | None:
    """The MCP image block for an image response, or `None` when there is none to build.

    The engine fills `image` only for a type its own bytes agreed with, and that
    type is what `content_type` carries; the pair is restated here so nothing can
    hand a client's decoder a media type nothing checked the bytes against.
    """
    image, kind = response.image, response.content_type
    if image is None or not kind or kind not in IMAGE_TYPES:
        return None
    return ImageContent(type="image", data=image.base64, mime_type=kind)


def _fetch_tool_result(response: FetchResponse) -> CallToolResult:
    """One `fetch` on the MCP wire: the response as JSON, plus an image block when there is an image.

    `Annotated[CallToolResult, FetchResponse]` on the tool is what makes that
    possible without moving the surface: FastMCP takes the second argument as the
    output model, so `list_tools` still advertises the `FetchResponse` schema and
    validates `structuredContent` against it, while the tool adds content blocks
    a model can see.

    `json.dumps(..., indent=2)` reproduces the text block FastMCP writes for a
    plain model return. The one field that projection loses is `image`, and only
    when its bytes became a content block: leaving them in would put one picture
    in a model's context twice, as pixels and as characters.
    """
    block = _image_block(response)
    payload = response.model_dump(mode="json")
    if block is not None:
        payload.pop("image", None)
    content: list[ContentBlock] = [
        TextContent(type="text", text=json.dumps(payload, indent=2))
    ]
    if block is not None:
        content.append(block)
    return CallToolResult(content=content, structured_content=payload)


async def _run_answer(engine: AgentEngine, req: AnswerRequest) -> AnswerResponse:
    """The `answer` mapping: the whole parameter set to the plan.

    `depth` reaches the plan as `None` when the caller left it out, which means
    "the plan's own default"; substituting `"brief"` here would turn the default
    into a cost knob.
    """
    return await engine.answer(
        query=req.query,
        extra_queries=req.extra_queries,
        depth=req.depth,
        provider=req.provider,
        include_domains=req.include_domains,
        exclude_domains=req.exclude_domains,
        recency=req.recency,
        language=req.language,
        safe_search=req.safe_search,
    )


@mcp.tool(
    name="search",
    title="Web Search",
    description=SEARCH_DESCRIPTION,
    annotations=ToolAnnotations(
        read_only_hint=True, idempotent_hint=True, open_world_hint=True
    ),
)
async def search(
    ctx: Context,
    query: Annotated[
        str,
        Field(
            min_length=2,
            max_length=400,
            description="The search query. Natural-language questions work well.",
        ),
    ],
    provider: Annotated[
        # The schema is frozen at decoration time, so it lists every adapter in the
        # package; an unenabled name is answered with the set that are.
        Literal[
            "scrappa",
            "serper",
            "linkup",
            "exa",
            "exa:free",
            "parallel",
            "parallel:free",
            "searxng",
            "tavily",
            "tinyfish",
            "algolia",
            "freeserp",
            "search1api",
            "anysearch",
            "serpapi",
            "querit",
            "deepseek",
        ]
        | None,
        Field(
            None,
            description=(
                "Which search backend to use. Omit to use the server's default; "
                "if that fails, the server retries the fallbacks its operator "
                "configured and says so in `notice`. A deployment where every "
                "enabled provider is free and no default is configured has no "
                "price to guess at, so an omitted `provider` there is served by "
                "that free set instead of refused. Naming a provider gets "
                "exactly that provider or an error. Not every provider is "
                "enabled on every deployment."
            ),
        ),
    ] = None,
    mode: Annotated[
        # Constants only, like `provider`: the annotation is `eval`'d against module
        # globals at import, so config values raise NameError. `"task"` is reserved
        # and stays absent until measured per-task defaults exist.
        Literal["free"] | None,
        Field(
            None,
            description=(
                "Route the search through free providers only. The names that "
                "cannot bill are `exa:free` and `parallel:free` (rate-limited "
                "anonymous endpoints), `searxng` (the operator's own "
                "instance), `tinyfish` (free at any balance) and `freeserp` "
                "(a keyless web index). The server "
                "fails rather than escalating to a paid provider, so a "
                "free-only search can come back with nothing. Not every one "
                "is enabled on every deployment. Mutually exclusive with "
                "`provider`."
            ),
        ),
    ] = None,
    max_results: Annotated[
        int,
        Field(
            5,
            ge=1,
            le=20,
            description=(
                "Maximum number of results. Keep this low unless you need breadth; "
                "each result costs context."
            ),
        ),
    ] = 5,
    include_domains: Annotated[
        list[str] | None,
        Field(
            None,
            max_length=20,
            description='Restrict results to these domains, e.g. ["arxiv.org"].',
        ),
    ] = None,
    exclude_domains: Annotated[
        list[str] | None,
        Field(None, max_length=20, description="Omit results from these domains."),
    ] = None,
    recency: Annotated[
        Literal["day", "week", "month", "year"] | None,
        Field(
            None,
            description=(
                "Restrict results to pages published in the last day, week, "
                "month or year. A provider without a date filter says so in "
                "`notice` rather than pretending it filtered."
            ),
        ),
    ] = None,
    language: Annotated[
        # Two letters exactly: a region is refused here rather than narrowed silently.
        str | None,
        Field(
            None,
            min_length=2,
            max_length=2,
            description=(
                "The language results should be in, as an ISO 639-1 code (`en`, "
                "`de`); a region is `country`'s job and this field does not take "
                "one. A provider with no language parameter says so in `notice` "
                "rather than pretending it filtered."
            ),
        ),
    ] = None,
    safe_search: Annotated[
        bool | None,
        Field(
            None,
            description=(
                "`true` asks the backend to filter adult content, `false` asks "
                "it not to; omitting it means the server does not override the "
                "provider's own default, which is not the same as unfiltered. A "
                "provider without the parameter says so in `notice`."
            ),
        ),
    ] = None,
) -> SearchResponse:
    app = _ctx(ctx)
    req = SearchRequest(
        query=query,
        provider=provider,
        mode=mode,
        max_results=max_results,
        include_domains=include_domains,
        exclude_domains=exclude_domains,
        recency=recency,
        language=language,
        safe_search=safe_search,
    )
    try:
        return await _run_search(app.engine, req)
    except SearchFailed as exc:
        # `ToolError`, not a bare exception. Both reach the client under mcp 2,
        # but only `ToolError` is the documented contract, and only it is logged
        # as one line: anything else is reported with a traceback, which this
        # codebase does not render (a failing adapter has an API key in scope).
        # This sentence -- which names the providers that would serve the call --
        # is the product contract, asserted by the feature tests. The REST route
        # keeps its own `_error`, so both encodings carry the same text.
        raise ToolError(str(exc)) from exc


@mcp.tool(
    name="fetch",
    title="Fetch Page Text",
    description=FETCH_DESCRIPTION,
    annotations=ToolAnnotations(
        read_only_hint=True, idempotent_hint=True, open_world_hint=True
    ),
)
async def fetch(
    ctx: Context,
    url: Annotated[
        str,
        Field(
            min_length=8,
            max_length=2048,
            description=(
                "The absolute http(s) URL to read, normally taken from a `search` "
                "result."
            ),
        ),
    ],
    # Both parameters are constants on the tool surface: no config reaches the
    # schema, which is frozen at import time.
    offset: Annotated[
        int | None,
        Field(
            None,
            ge=0,
            description=(
                "Character offset into the extracted text. To continue past a "
                "`truncated` page, fetch again with this set to the previous "
                "`offset` plus the length of the text you received."
            ),
        ),
    ] = None,
    query: Annotated[
        str | None,
        Field(
            None,
            min_length=2,
            max_length=400,
            description=(
                "Return only the passages matching these terms, each with its "
                "`offset`, instead of the full page -- the cheap way to read one "
                "section of a long document."
            ),
        ),
    ] = None,
    path: Annotated[
        str | None,
        Field(
            None,
            min_length=1,
            max_length=400,
            description=(
                "On a JSON page, return only the part this path addresses, "
                "instead of the whole document: `$.meta`, `$.items[0].name`, "
                "`$.items[*].id` for every element, `$.items[0:5]` for a slice. "
                "A JSON page arrives as one line per value, each labelled with "
                "the path that addresses it, so the page you just read names "
                "the paths you can ask for next."
            ),
        ),
    ] = None,
    # A plain `str | None`, not a `Literal` of `fetcher.KNOWN_FALLBACKS`: what this
    # deployment builds is config, a key and a permission set, while the
    # annotation is evaluated at import. An unavailable name is refused at call
    # time by `FetchEngine.resolve`.
    provider: Annotated[
        str | None,
        Field(
            None,
            description=(
                "Read this page through one named fetch provider instead of the "
                "server's default route -- its own reader unless the operator "
                "configured `fetch.primary` to name a provider. The names "
                "available are the fetch fallbacks this server's operator "
                "configured; the local reader has no name, so on a "
                "default-routed server omitting `provider` is that provider "
                "rather than a local read. A name this server does not run is "
                "refused before anything is fetched, and the refusal lists the "
                "names it does run. A named provider is served as named: it is "
                "the one attempt, with no default-route read first and nothing "
                "behind it, so a priced name is billed for this call."
            ),
        ),
    ] = None,
) -> Annotated[CallToolResult, FetchResponse]:
    app = _ctx(ctx)
    if app.fetch_engine is None:
        # Only `[fetch] enabled = false` gets here; the REST projection hands the
        # same sentence back as its 404.
        raise ToolError(_FETCH_DISABLED)
    try:
        req = FetchRequest(
            url=url, offset=offset, query=query, path=path, provider=provider
        )
        response = await _run_fetch(app.fetch_engine, req)
    except FetchFailed as exc:
        raise ToolError(str(exc)) from exc
    return _fetch_tool_result(response)


@mcp.tool(
    name="answer",
    title="Answer a Question",
    description=ANSWER_DESCRIPTION,
    annotations=ToolAnnotations(
        read_only_hint=True, idempotent_hint=True, open_world_hint=True
    ),
)
async def answer(
    ctx: Context,
    query: Annotated[
        str,
        Field(
            min_length=2,
            max_length=400,
            description="The question. Natural-language questions work well.",
        ),
    ],
    extra_queries: Annotated[
        # Item bounds as well as the count, the range `query` has, so a
        # one-character fragment cannot become a billed search.
        list[Annotated[str, Field(min_length=2, max_length=400)]] | None,
        Field(
            None,
            max_length=2,
            description=(
                "Up to two more retrieval queries, run after `query`, for a "
                "question one phrasing would only partly cover. Used by "
                '`depth="report"`: a `brief` answer runs `query` alone.'
            ),
        ),
    ] = None,
    depth: Annotated[
        Literal["brief", "report"] | None,
        Field(
            None,
            description=(
                "`brief` (the default) runs one search and answers from "
                "snippets. `report` runs up to three searches and reads up to "
                "three pages before answering, which costs the operator several "
                "times as much. This is the only cost knob you control."
            ),
        ),
    ] = None,
    provider: Annotated[
        # Constants only, like `search`: the schema lists every adapter, not just the enabled subset.
        Literal[
            "scrappa",
            "serper",
            "linkup",
            "exa",
            "exa:free",
            "parallel",
            "parallel:free",
            "searxng",
            "tavily",
            "tinyfish",
            "algolia",
            "freeserp",
            "search1api",
            "anysearch",
            "serpapi",
            "querit",
            "deepseek",
        ]
        | None,
        Field(
            None,
            description=(
                "Pin retrieval to one backend, exactly as `search` does: that "
                "provider or an error. Omit to use the server's default, with "
                "its configured fallbacks. Not every provider is enabled on "
                "every deployment."
            ),
        ),
    ] = None,
    include_domains: Annotated[
        list[str] | None,
        Field(
            None,
            max_length=20,
            description='Restrict retrieval to these domains, e.g. ["arxiv.org"].',
        ),
    ] = None,
    exclude_domains: Annotated[
        list[str] | None,
        Field(
            None,
            max_length=20,
            description="Omit results from these domains.",
        ),
    ] = None,
    recency: Annotated[
        Literal["day", "week", "month", "year"] | None,
        Field(
            None,
            description=(
                "Restrict retrieval to pages published in the last day, week, "
                "month or year. A provider without a date filter says so in "
                "`notice` rather than pretending it filtered."
            ),
        ),
    ] = None,
    language: Annotated[
        # The same parameters and bounds as `search`: a safety filter settable on
        # one tool and not the other is the trap the notice mechanism prevents.
        str | None,
        Field(
            None,
            min_length=2,
            max_length=2,
            description=(
                "The language retrieval should be in, as an ISO 639-1 code "
                "(`en`, `de`); a region is not this field's job and it does not "
                "take one. A provider with no language parameter says so in "
                "`notice` rather than pretending it filtered."
            ),
        ),
    ] = None,
    safe_search: Annotated[
        bool | None,
        Field(
            None,
            description=(
                "`true` asks each backend to filter adult content, `false` asks "
                "it not to; omitting it means the server does not override the "
                "provider's own default, which is not the same as unfiltered. A "
                "provider without the parameter says so in `notice`."
            ),
        ),
    ] = None,
) -> AnswerResponse:
    app = _ctx(ctx)
    if app.agent_engine is None:
        # Only `[agent] enabled = false` gets here; the same constant the REST
        # route answers 404 with, so the two encodings cannot drift apart.
        raise ToolError(_AGENT_DISABLED)
    req = AnswerRequest(
        query=query,
        extra_queries=extra_queries,
        depth=depth,
        provider=provider,
        include_domains=include_domains,
        exclude_domains=exclude_domains,
        recency=recency,
        language=language,
        safe_search=safe_search,
    )
    try:
        return await _run_answer(app.agent_engine, req)
    except AgentFailed as exc:
        raise ToolError(str(exc)) from exc


def _transport_security(allowed_hosts: list[str]) -> TransportSecuritySettings:
    """Build the Host+Origin allowlist the listener and `_guard` share.

    mcp 2 moved transport config off `mcp.settings` onto the app factory, and its
    auto-enable only fires for a loopback bind -- this server may bind a routable
    address, so the allowlist is always built here, seeded with the loopback names
    and widened with the operator's.

    Both spellings of the loopback entries: bare names (v1 style, what `_guard`
    matched before) and `host:*` patterns (what mcp 2's auto-enable uses). The
    matcher compares `Host` exactly or by trailing `:*` pattern, and a client
    almost always sends the port, so the bare names alone would refuse every
    request through `_guard`.

    Widening, never narrowing: the loopback seed is what stops a web page from
    driving this server through the user's network, so `--allowed-host` adds to it
    rather than replacing it. Origins are widened in step, under both schemes: a
    browser client that got past the Host check only to fail on Origin would debug
    a second, near identical 403 for the same reason.
    """
    loopback = ("localhost", "127.0.0.1", "::1")
    return TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=[
            *loopback,
            *(f"{h}:*" for h in loopback),
            "[::1]:*",
            *allowed_hosts,
        ],
        allowed_origins=[
            *(
                f"{scheme}://{h}"
                for h in (*loopback, *allowed_hosts)
                for scheme in ("http", "https")
            ),
        ],
    )


_transport_security_settings: TransportSecuritySettings | None = None
"""The allowlist the running listener was built with. Set by `_serve_http`.

`_guard` reads it for the custom routes, which sit outside the transport where
the check actually runs. `None` means no listener is up -- under stdio, or in a
test that builds the app itself.
"""


_started_at: float | None = None
"""When the HTTP listener came up. Set by `_serve_http`, read by `healthz`."""


async def healthz(_request: Request) -> JSONResponse:
    """Liveness and readiness for the HTTP transport.

    Mounted by `_serve_http` rather than at import, so it exists only on the
    transport that has an HTTP surface.

    `custom_route` puts it *outside* `StreamableHTTPServerTransport`, where
    DNS-rebinding protection actually lives -- the Host allowlist is enforced
    inside `handle_request`, not as ASGI middleware. That is load-bearing: a
    kubelet probes with the pod IP in `Host`, which no `--allowed-host` value can
    anticipate, so a health check behind that allowlist would answer 421 to every
    probe it was written for.

    Which obliges it to leak nothing. Enabled provider *names* only: an
    unauthenticated `/mcp` caller already learns that list from `SearchFailed`.
    Absent on purpose: which keys are present (a phishing target list), the config
    path, the bind address, the allowlist, dependency versions.

    It never reports unhealthy because a *provider* is down. Every failure this
    service has is upstream and none is fixed by restarting the pod; a 503 on a
    Serper outage would turn a degraded proxy into CrashLoopBackOff and take
    `exa:free`, which was working, down with it.
    """
    if _shared is None:
        # Only reachable while tearing down: `_serve_http` sets `_shared` before
        # the socket accepts and clears it in its `finally`. A 503 is how a load
        # balancer stops sending work.
        return JSONResponse({"status": "stopping"}, status_code=503)
    return JSONResponse(
        {
            "status": "ok",
            "providers": _shared.config.enabled_providers(),
            "default_provider": _shared.config.default_provider,
            "uptime_s": int(time.monotonic() - (_started_at or time.monotonic())),
        }
    )


async def _guard(request: Request) -> Response | None:
    """Run the ``/mcp`` Host+Origin check by hand for a custom route.

    `custom_route` sits outside `StreamableHTTPServerTransport`, where
    DNS-rebinding protection lives (see `healthz`), so this runs it by hand. Unlike
    `/healthz` these surfaces carry data and get no bypass: they stay behind the
    allowlist, and a browser needs the name it types in `--allowed-host`. Returns
    the refusal response, or None to proceed.
    """
    settings = (
        _transport_security_settings
        if _transport_security_settings is not None
        # No listener was built by this process -- a test driving the app
        # directly. The loopback seed alone is the v1 default this replaces; the
        # bare constructor would carry an empty allowlist and refuse everything.
        else _transport_security([])
    )
    return await TransportSecurityMiddleware(settings).validate_request(
        request, is_post=False
    )


async def dashboard(request: Request) -> Response:
    """The usage page itself: one self-contained HTML document.

    Same listener and Host allowlist as `/mcp`; no auth, because the bind address
    is the access control.
    """
    denied = await _guard(request)
    if denied is not None:
        return denied
    return HTMLResponse(DASHBOARD_HTML)


async def dashboard_data(request: Request) -> Response:
    """The snapshot behind the page, refreshed by its poll.

    Reads the process recorder, never the journal (already folded in at startup).
    Reports "stopping" when `_shared` is gone, exactly as `/healthz` does.
    """
    denied = await _guard(request)
    if denied is not None:
        return denied
    if _shared is None:
        return JSONResponse({"status": "stopping"}, status_code=503)
    return JSONResponse(_shared.usage.snapshot())


async def dashboard_metrics(request: Request) -> Response:
    """The per-endpoint latency and cost window, for a script or a page.

    The snapshot's `endpoints` key and nothing else: `GET /dashboard/data`
    carries the same object, so the terminal report and the panel cannot drift.
    Like its sibling it takes `_guard` and reads the in-memory recorder, never
    the journal.

    Registered inside the `config.dashboard.enabled` block, so `enabled = false`
    leaves it unbuilt and it 404s. Not on the `/healthz` bypass: that surface is
    unauthenticated and stays secret-free.
    """
    denied = await _guard(request)
    if denied is not None:
        return denied
    if _shared is None:
        return JSONResponse({"status": "stopping"}, status_code=503)
    return JSONResponse(_shared.usage.snapshot()["endpoints"])


_FETCH_DISABLED = "This server has the fetch tool disabled; use `search` instead."
"""The one sentence both encodings give when `[fetch] enabled = false`."""

_AGENT_DISABLED = (
    "This server has agent mode disabled; use `search` or `fetch` instead."
)
"""The one sentence both encodings give when `[agent] enabled = false`.

The `[fetch] enabled = false` precedent, extended to a tool whose dependency is
an external service: the MCP tool hands it to the model, and the REST route
answers it as a `404` -- "the operation is not served here" -- because that is
what a deployment with no agent mode is saying.
"""


def _error(message: str, status: int) -> JSONResponse:
    """The one error shape, whatever failed: ``{"error": "<message>"}``.

    The message is the prose the MCP tool hands the model, never a traceback or an
    exception object: AGENTS.md's log-discipline rule, applied to a response body.
    """
    return JSONResponse({"error": message}, status_code=status)


def _stopping() -> JSONResponse:
    """The 503 `/healthz` gives, in the REST surface's error shape."""
    return _error("The server is stopping; retry shortly.", 503)


def _invalid(exc: ValidationError) -> JSONResponse:
    """One sentence naming the fields a body got wrong, not pydantic's report."""
    details = "; ".join(
        f"{'.'.join(str(part) for part in error['loc']) or 'body'}: {error['msg']}"
        for error in exc.errors()
    )
    return _error(f"Invalid request: {details}.", 400)


async def _json_body(request: Request) -> dict[str, Any] | Response:
    """Decode the body as a JSON object, or the 400 that says why not.

    Non-JSON is refused here rather than handed to pydantic as a field error.
    `Content-Type` is not checked: the spec fixes the encoding, not a rejection
    rule for a wrong one, and the status table has no 415.
    """
    try:
        payload = await request.json()
    except ValueError as exc:
        return _error(f"Body is not valid JSON: {exc}", 400)
    if not isinstance(payload, dict):
        return _error("Body must be a JSON object.", 400)
    return payload


async def api_search(request: Request) -> Response:
    """`POST /api/v1/search`: the `search` tool over plain JSON.

    The body is the tool's parameter set, the response is
    `models.SearchResponse`, and the engine call is the one the tool makes, so the
    two encodings cannot drift. Behind `_guard`: this route carries data and
    spends money, so it gets no `/healthz` exemption.

    The split the tool layer does not draw: a `SearchRefused` is a request this
    server will not serve at all (400, nothing billed); anything else that failed
    was upstream's (502). Both carry the sentence the model would have got.
    """
    denied = await _guard(request)
    if denied is not None:
        return denied
    app = _shared
    if app is None:
        return _stopping()
    body = await _json_body(request)
    if isinstance(body, Response):
        return body
    try:
        req = SearchRequest.model_validate(body)
    except ValidationError as exc:
        return _invalid(exc)
    try:
        response = await _run_search(app.engine, req)
    except SearchRefused as exc:
        return _error(str(exc), 400)
    except SearchFailed as exc:
        return _error(str(exc), 502)
    return JSONResponse(response.model_dump(mode="json"))


async def api_fetch(request: Request) -> Response:
    """`POST /api/v1/fetch`: the `fetch` tool over plain JSON.

    A POST rather than `GET /api/v1/fetch?url=...`: a URL a model chose off a
    third-party page is the same sensitivity class as a query, and a query string
    lands in every access and proxy log on the path; a body does not.

    `[fetch] enabled = false` is a 404, checked before the body: "not served" is a
    fact about the deployment. A guardrail refusing the URL as written is a 400
    (`FetchRefused`, nothing sent); everything else that failed was dispatched and
    failed upstream (502).
    """
    denied = await _guard(request)
    if denied is not None:
        return denied
    app = _shared
    if app is None:
        return _stopping()
    engine = app.fetch_engine
    if engine is None:
        return _error(_FETCH_DISABLED, 404)
    body = await _json_body(request)
    if isinstance(body, Response):
        return body
    try:
        req = FetchRequest.model_validate(body)
    except ValidationError as exc:
        return _invalid(exc)
    try:
        response = await _run_fetch(engine, req)
    except FetchRefused as exc:
        return _error(str(exc), 400)
    except FetchFailed as exc:
        return _error(str(exc), 502)
    return JSONResponse(response.model_dump(mode="json"))


async def api_answer(request: Request) -> Response:
    """`POST /api/v1/answer`: the `answer` tool over plain JSON.

    Projected like its siblings: the body is `models.AnswerRequest`, the response
    is `models.AnswerResponse`, and the plan is the one the tool runs. Behind
    `_guard`: it carries the caller's question and spends the operator's money
    twice over, on retrieval and on a model.

    `[agent] enabled = false` is a 404, before the body is read -- the `[fetch]`
    rule. A guardrail refusal is a 400, and the one this operation has is the
    provider pin: `SearchEngine._resolve_or_reject` refuses an unserved name (or a
    body naming none where there is no default) *before* any dispatch. It is the
    logging wrapper rather than the bare `resolve`, so a refused pin leaves the
    same `search.rejected` line the `search` route logs; `mode` is `None` here
    because the `answer` tool has no mode.

    That check belongs here rather than in the walk, which deliberately swallows a
    step failure: a refused pin would leave as an `AgentFailed` instead of the
    400 the request deserves. Everything from the first dispatched search onward
    is upstream's, and the failure table's 502 carries the phase in its message.
    """
    denied = await _guard(request)
    if denied is not None:
        return denied
    app = _shared
    if app is None:
        return _stopping()
    engine = app.agent_engine
    if engine is None:
        return _error(_AGENT_DISABLED, 404)
    body = await _json_body(request)
    if isinstance(body, Response):
        return body
    try:
        req = AnswerRequest.model_validate(body)
    except ValidationError as exc:
        return _invalid(exc)
    try:
        # The logging wrapper, not the bare `resolve`: a refused pin reaches the
        # operator as the same `search.rejected` line on every surface.
        app.engine._resolve_or_reject(req.provider)
    except SearchRefused as exc:
        return _error(str(exc), 400)
    try:
        response = await _run_answer(engine, req)
    except AgentFailed as exc:
        return _error(str(exc), 502)
    return JSONResponse(response.model_dump(mode="json"))


async def _serve_http(
    config: Config, host: str, port: int, allowed_hosts: list[str]
) -> None:
    """Serve streamable-http with one process-wide context.

    uvicorn is driven directly rather than through `mcp.run("streamable-http")`,
    which builds the app and serves it in one call, leaving nowhere to open
    `build_app_context` around it.

    The server is stateless: with `_shared` in place `lifespan` is a bare yield
    however often the session manager enters it. Statelessness also avoids
    `StreamableHTTPSessionManager` tracking
    stateful sessions in a dict with no idle timeout by default, so every client
    that ever connected holds a slot until restart. Nothing here needs a session:
    the tools are request/response.
    """
    global _shared, _transport_security_settings

    import uvicorn

    global _started_at
    _started_at = time.monotonic()
    mcp.custom_route("/healthz", methods=["GET"])(healthz)
    # Part of the HTTP transport, so `--http` itself is the switch: no config key.
    # POST and behind `_guard`, not `/healthz`'s exemption: these carry data and spend money.
    mcp.custom_route("/api/v1/search", methods=["POST"])(api_search)
    mcp.custom_route("/api/v1/fetch", methods=["POST"])(api_fetch)
    # Unconditional, unlike the dashboard routes: a 404 can carry a sentence, the
    # absence of a route cannot.
    mcp.custom_route("/api/v1/answer", methods=["POST"])(api_answer)
    if config.dashboard.enabled:
        # Registered only when on: a disabled dashboard 404s like any unregistered route.
        mcp.custom_route("/dashboard", methods=["GET"])(dashboard)
        mcp.custom_route("/dashboard/data", methods=["GET"])(dashboard_data)
        # The data route's `endpoints` key alone, for a script.
        mcp.custom_route("/dashboard/metrics", methods=["GET"])(dashboard_metrics)

    security = _transport_security(allowed_hosts)
    # Before the socket opens: `_guard` serves the custom routes, and a request
    # arriving between the two lines would be checked against the previous
    # allowlist.
    _transport_security_settings = security

    async with build_app_context(config) as ctx:
        _shared = ctx
        try:
            server = uvicorn.Server(
                uvicorn.Config(
                    mcp.streamable_http_app(
                        stateless_http=True, transport_security=security
                    ),
                    host=host,
                    port=port,
                    # `None`, not uvicorn's built-in config: it points
                    # `uvicorn.access` at stdout with `propagate: False`, breaking
                    # the everything-on-stderr rule.
                    log_config=None,
                    # `library_level`, as an int: uvicorn re-applies it to its own
                    # loggers after `setup_logging`, and TRACE/SUCCESS are loguru names.
                    log_level=to_stdlib_level(config.logging.library_level),
                    # `propagate = False` on `uvicorn.access` is what actually silences the per-request line.
                    access_log=config.logging.access_log,
                )
            )
            bind(host=host, port=port).info("http.listening")
            await server.serve()
        finally:
            _shared = None
            # Last, with the socket: once this is gone `_guard` falls back, so a
            # request in flight against the dying listener is checked against the
            # allowlist the listener was actually built with.
            _transport_security_settings = None


def main(
    *,
    http: bool = False,
    host: str = "127.0.0.1",
    port: int = 8000,
    allowed_hosts: list[str] | None = None,
    log_level: LogLevel | None = None,
    log_format: Literal["text", "json"] | None = None,
) -> None:
    # Config problems are settled before `mcp.run`, not inside `lifespan`: a
    # SystemExit under an anyio task group reaches the operator as an
    # ExceptionGroup traceback.
    config = load_config()

    # Reaching this line means FastMCP's import-time `logging.basicConfig` has run,
    # so this is what takes the root logger back off it -- see `logs.setup_logging`.
    config.logging = apply_log_overrides(config.logging, log_level, log_format)
    setup_logging(config.logging)

    # An enabled provider with no key would fail every search through the model, so
    # the server refuses to start; `--check` explains it without dying.
    missing = config.missing_api_keys()
    if missing:
        raise SystemExit(
            "seekwright: missing API key(s) for enabled provider(s): "
            + ", ".join(f"{n} ({api_key_env_var(n)})" for n in missing)
        )

    if config.fetch.enabled:
        try:
            build_extractor(config)
        except ExtractorUnavailable as exc:
            raise SystemExit(f"seekwright: {exc}") from exc

    if config.fetch.enabled and config.fetch.primary != "http":
        # A primary this deployment cannot build must not silently become the
        # local reader: that would dial from this server's own IP against the
        # operator's explicit route. `--check` prints the per-name reason.
        from .fetcher import KNOWN_FALLBACKS

        probe = KNOWN_FALLBACKS[config.fetch.primary].build(config)
        if probe is None:
            raise SystemExit(
                f"seekwright: fetch.primary names {config.fetch.primary!r}, "
                "which this deployment cannot build (see `seekwright --check` "
                "for why); refusing to start rather than read from this "
                "server's own IP unasked"
            )
        anyio.run(probe.aclose)

    missing_agent = config.missing_agent_settings()
    if missing_agent:
        raise SystemExit(
            "seekwright: agent mode is enabled but missing "
            + ", ".join(missing_agent)
        )

    if http:
        # Nothing authenticates this listener and every call spends credits, so the
        # bind address is the whole access-control story (docs/reference/container.md).
        anyio.run(lambda: _serve_http(config, host, port, allowed_hosts or []))
        return

    mcp.run(transport="stdio")
