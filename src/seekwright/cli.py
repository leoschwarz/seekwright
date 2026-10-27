"""CLI surface: run the server on either transport, or self-diagnose without one.

``seekwright``                 run the MCP server (stdio transport)
``seekwright --http``          run it as an HTTP service on ``--host``/``--port``
``seekwright --check``         verify config and provider reachability. Never
                                    bills: the only live calls are Exa MCP
                                    handshakes, free even on a keyed session.
``seekwright --check --live``  also one real search per ready permitted provider
                                    (~$0.00x per call, billed); an unpermitted
                                    one is reported and skipped.
``seekwright --metrics``       per-endpoint latency and cost over the journal
                                    window, then exit. No provider, no network
                                    call, nothing billed.
``seekwright --metrics --json``  that report as one JSON document -- the
                                    object ``GET /dashboard/metrics`` serves.
``seekwright search QUERY``    ask a running ``--http`` server for results
``seekwright fetch URL``       ask it for one page's text
``seekwright answer QUERY``    ask it one question and get a grounded answer
                                    with the sources it cited: a fixed
                                    retrieval plan and a model call on the
                                    operator's account.

Neither the check nor the metrics path imports :mod:`server`, so the FastMCP app
is never constructed for a diagnosis or a report. The three client subcommands
load no config, build no provider and read no API key -- the server holds all
three -- and their bodies are :mod:`models`' request and response models, so the
client cannot drift from the contract it speaks.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from typing import Any, Literal, cast

import httpx
from pydantic import ValidationError

from .config import (
    KEYLESS_PROVIDERS,
    PROVIDERS_REQUIRING_KEY,
    UNTESTED_PROVIDERS,
    Config,
    LogLevel,
    api_key_env_var,
    config_path,
    load_config,
)
from .extractors.base import PDF_TYPES
from .factory import ExtractorUnavailable, build_extractor, build_providers
from .fetcher import KNOWN_FALLBACKS, Fallback, HttpFetcher
from .health import ProbeOutcome, probe
from .logs import apply_log_overrides, setup_logging
from .models import (
    AnswerRequest,
    AnswerResponse,
    FetchRequest,
    FetchResponse,
    SearchQuery,
    SearchRequest,
    SearchResponse,
)
from .providers.base import ProviderError, SearchProvider
from .usage import UsageRecorder

_PROBE_QUERY = "seekwright connectivity check"

_DEFAULT_SERVER = "http://127.0.0.1:8000"
"""Where ``--server`` points when it is not given.

The address ``--http`` binds by default, so the two halves of the tool line up
with no configuration -- which is the whole reason the client is a subcommand of
this entry point rather than a separate program.
"""

_REQUEST_TIMEOUT = 60.0
"""Seconds to wait for one REST call.

Generous rather than tight, and deliberately not read from config -- the client
reads none. A search can walk the server's whole fallback ladder, so the timeout
that matters is the server's own; this one only has to be long enough not to
interrupt it.
"""

_SUBCOMMANDS = ("search", "fetch", "answer")


def main(argv: list[str] | None = None) -> None:
    # Dispatch on the first token, not argparse subparsers: a client flag is a field
    # of the request body, a server flag is this invocation's, and `--json` is the
    # one name both namespaces have.
    tokens = list(sys.argv[1:] if argv is None else argv)
    if tokens and tokens[0] in _SUBCOMMANDS:
        raise SystemExit(client(tokens[0], tokens[1:]))

    parser = argparse.ArgumentParser(
        prog="seekwright",
        description=(
            "An MCP proxy in front of web-search providers: paid, "
            "free-tiered and keyless. With no options, runs the stdio MCP "
            "server."
        ),
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify config and provider connectivity, then exit "
        "(no provider calls, no billing).",
    )
    parser.add_argument(
        "--live",
        action="store_true",
        help="With --check: also make one real search per ready permitted "
        "provider (billed, on the order of $0.001 each) and one page fetch "
        "(free). A provider the allow-list excludes is skipped.",
    )
    parser.add_argument(
        "--metrics",
        action="store_true",
        help="Report per-endpoint latency and cost over the usage journal "
        "window, then exit. Reads the journal only -- no provider call, no "
        "billing.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="With --metrics: print the report as one JSON document instead of "
        "a table -- the same object GET /dashboard/metrics serves.",
    )
    parser.add_argument(
        "--http",
        action="store_true",
        help="Serve over streamable HTTP instead of stdio. Nothing "
        "authenticates the listener and every call it serves is billed, so "
        "what you bind to is the access control.",
    )
    # Defaulted to None rather than to the real values, so "not passed" stays
    # distinguishable from "passed the default" and the guard below can say so.
    parser.add_argument(
        "--host",
        default=None,
        help="With --http: interface to bind (default 127.0.0.1). Use 0.0.0.0 "
        "inside a container, where the published port decides who can reach it.",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=None,
        help="With --http: port to bind (default 8000).",
    )
    parser.add_argument(
        "--allowed-host",
        action="append",
        default=None,
        metavar="HOST[:PORT]",
        help="With --http: a Host header to accept, repeatable. Loopback is "
        "always accepted; anything else answers 421 until named here. A "
        "trailing ':*' matches any port, e.g. search.internal:*.",
    )
    # Verbosity is a property of an invocation, not of an install -- the same
    # argument that keeps `--http`/`--host`/`--port` out of the TOML.
    parser.add_argument(
        "--log-level",
        default=None,
        choices=["TRACE", "DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR", "CRITICAL"],
        help="Override [logging] level for this run.",
    )
    parser.add_argument(
        "--log-format",
        default=None,
        choices=["text", "json"],
        help="Override [logging] format for this run. Logs go to stderr either "
        "way; stdout is the protocol channel under stdio.",
    )
    args = parser.parse_args(argv)

    http_only = (args.host, args.port, args.allowed_host)
    # `--metrics` is the second report-and-exit mode, so it excludes everything that would serve or bill.
    if args.metrics and (
        args.check
        or args.live
        or args.http
        or any(value is not None for value in http_only)
    ):
        parser.error(
            "--metrics reports and exits; it cannot be combined with --check, "
            "--live, --http, --host, --port or --allowed-host"
        )
    if args.json and not args.metrics:
        parser.error("--json only makes sense together with --metrics")
    if args.live and not args.check:
        parser.error("--live only makes sense together with --check")
    if any(value is not None for value in http_only) and not args.http:
        parser.error(
            "--host, --port and --allowed-host only make sense together with --http"
        )

    if args.metrics:
        raise SystemExit(
            metrics(
                as_json=args.json,
                log_level=args.log_level,
                log_format=args.log_format,
            )
        )

    if args.check:
        raise SystemExit(
            check(live=args.live, log_level=args.log_level, log_format=args.log_format)
        )

    from .server import main as server_main

    server_main(
        http=args.http,
        host=args.host if args.host is not None else "127.0.0.1",
        port=args.port if args.port is not None else 8000,
        allowed_hosts=args.allowed_host or [],
        log_level=args.log_level,
        log_format=args.log_format,
    )


def client(command: str, argv: list[str]) -> int:
    """Run one client subcommand. Returns a process exit code.

    The parser is built per command, so `--json` here means "print the body
    verbatim", never the `--metrics` companion it means one token to the left. A
    body the contract refuses is a usage error (2) caught before the request by
    the same model the server validates with, so a typo costs no round trip.
    """
    parser = _client_parser(command)
    args = parser.parse_args(argv)
    try:
        if command == "search":
            return search(
                server=args.server,
                query=args.query,
                provider=args.provider,
                max_results=args.max_results,
                include_domains=args.include_domains,
                exclude_domains=args.exclude_domains,
                recency=args.recency,
                language=args.language,
                safe_search=args.safe_search,
                as_json=args.as_json,
            )
        if command == "fetch":
            return fetch(
                server=args.server,
                url=args.url,
                query=args.query,
                offset=args.offset,
                path=args.path,
                provider=args.provider,
                as_json=args.as_json,
            )
        return answer(
            server=args.server,
            query=args.query,
            extra_queries=args.extra_queries,
            depth=args.depth,
            provider=args.provider,
            include_domains=args.include_domains,
            exclude_domains=args.exclude_domains,
            recency=args.recency,
            language=args.language,
            safe_search=args.safe_search,
            as_json=args.as_json,
        )
    except ValidationError as exc:
        parser.error(_refused(exc))


def _client_parser(command: str) -> argparse.ArgumentParser:
    """The parser for one client subcommand: a flag per request field.

    Separate from the server's parser rather than a subparser of it (see `main`),
    and every flag maps to a field of one of the three request shapes
    (public-api.md).
    """
    parser = argparse.ArgumentParser(
        prog=f"seekwright {command}",
        description=(
            f"Ask a running `seekwright --http` server to {command} over its "
            "REST projection. The server holds the config, the provider keys "
            "and the bill; this command holds none of them."
        ),
    )
    parser.add_argument(
        "--server",
        default=_DEFAULT_SERVER,
        metavar="URL",
        help=f"Base URL of the running server (default {_DEFAULT_SERVER}, the "
        "address --http binds by default).",
    )
    if command == "search":
        parser.add_argument("query", metavar="QUERY", help="What to search for.")
        parser.add_argument(
            "--provider",
            metavar="P",
            help="Name of the provider to use. Omitted, the server's default "
            "answers, or the search fails if it has none.",
        )
        parser.add_argument(
            "--max-results",
            type=int,
            default=5,
            metavar="N",
            help="Results to ask for, 1-20 (default 5, the tool's own default).",
        )
        parser.add_argument(
            "--include-domain",
            action="append",
            dest="include_domains",
            metavar="D",
            help="Restrict results to a domain, repeatable (up to 20). A "
            "provider that cannot honour it says so in `notice`.",
        )
        parser.add_argument(
            "--exclude-domain",
            action="append",
            dest="exclude_domains",
            metavar="D",
            help="Drop results from a domain, repeatable (up to 20).",
        )
        parser.add_argument(
            "--recency",
            choices=("day", "week", "month", "year"),
            help="Prefer results from the last day, week, month or year.",
        )
        parser.add_argument(
            "--language",
            metavar="CODE",
            help="ISO 639-1 code for the language results should be in (`en`, "
            "`de`). Two letters exactly: a region is not this flag's job. A "
            "provider that cannot honour it says so in `notice`.",
        )
        parser.add_argument(
            "--safe-search",
            action=argparse.BooleanOptionalAction,
            default=None,
            help="`--safe-search` asks the backend to filter adult content, "
            "`--no-safe-search` asks it not to. Omitting both leaves the "
            "provider's own default standing, which is not the same as "
            "unfiltered; a provider without the parameter says so in `notice`.",
        )
    elif command == "fetch":
        parser.add_argument(
            "url",
            metavar="URL",
            help="The absolute http(s) URL to read, normally taken from a "
            "`search` result.",
        )
        parser.add_argument(
            "--query",
            metavar="Q",
            help="Return the passages matching this query instead of the whole "
            "page.",
        )
        parser.add_argument(
            "--offset",
            type=int,
            metavar="N",
            help="Character offset into the extracted text, to continue past a "
            "truncated page.",
        )
        parser.add_argument(
            "--path",
            metavar="P",
            help="On a JSON page, read only the part this path addresses: "
            "`$.meta`, `$.items[*].name` for one field of every element, "
            "`$.items[0:5]` for a slice. A JSON page prints one line per value "
            "labelled with its path, so the page names the paths to ask for.",
        )
        parser.add_argument(
            "--provider",
            metavar="P",
            help="Read the page through this named fetch provider instead of the "
            "server's default route (its own reader unless the operator "
            "configured a provider primary). The names a server runs are the "
            "fetch fallbacks its operator configured; the local reader has no "
            "name, so on a server whose primary is a provider, omitting the flag "
            "reads through that provider. A name that server does not run is "
            "refused before anything is fetched, with the list it does run.",
        )
    else:
        parser.add_argument("query", metavar="QUERY", help="The question to answer.")
        parser.add_argument(
            "--depth",
            choices=("brief", "report"),
            help="`brief` (the server's default) runs one search and answers "
            "from snippets; `report` runs up to three searches and reads up to "
            "three pages first, and costs several times as much. The one cost "
            "knob the caller controls.",
        )
        parser.add_argument(
            "--extra-query",
            action="append",
            dest="extra_queries",
            metavar="Q",
            help="A second retrieval query, repeatable (up to two). The server "
            "runs it only for `--depth report`.",
        )
        parser.add_argument(
            "--provider",
            metavar="P",
            help="Pin retrieval to one provider. Omitted, the server's default "
            "route answers, fallbacks included.",
        )
        parser.add_argument(
            "--include-domain",
            action="append",
            dest="include_domains",
            metavar="D",
            help="Restrict retrieval to a domain, repeatable (up to 20). A "
            "provider that cannot honour it says so in `notice`.",
        )
        parser.add_argument(
            "--exclude-domain",
            action="append",
            dest="exclude_domains",
            metavar="D",
            help="Omit results from a domain, repeatable (up to 20).",
        )
        parser.add_argument(
            "--recency",
            choices=("day", "week", "month", "year"),
            help="Prefer pages published in the last day, week, month or year.",
        )
        parser.add_argument(
            "--language",
            metavar="CODE",
            help="ISO 639-1 code for the language retrieval should be in (`en`, "
            "`de`). Two letters exactly: a region is not this flag's job. A "
            "provider that cannot honour it says so in `notice`.",
        )
        parser.add_argument(
            "--safe-search",
            action=argparse.BooleanOptionalAction,
            default=None,
            help="`--safe-search` asks each backend to filter adult content, "
            "`--no-safe-search` asks it not to. Omitting both leaves the "
            "provider's own default standing, which is not the same as "
            "unfiltered; a provider without the parameter says so in `notice`.",
        )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="as_json",
        help="Print the response body verbatim, so it pipes into jq.",
    )
    return parser


def search(
    *,
    server: str = _DEFAULT_SERVER,
    query: str,
    provider: str | None = None,
    max_results: int = 5,
    include_domains: list[str] | None = None,
    exclude_domains: list[str] | None = None,
    recency: Literal["day", "week", "month", "year"] | None = None,
    language: str | None = None,
    safe_search: bool | None = None,
    as_json: bool = False,
) -> int:
    """`POST /api/v1/search`; returns an exit code.

    The body is `models.SearchRequest` and the response `models.SearchResponse`,
    imported rather than re-declared, so this command cannot drift from the
    contract. Raises pydantic's `ValidationError` for a refused body; the entry
    point turns that into a usage error.
    """
    body = SearchRequest(
        query=query,
        provider=provider,
        max_results=max_results,
        include_domains=include_domains,
        exclude_domains=exclude_domains,
        recency=recency,
        language=language,
        safe_search=safe_search,
    ).model_dump(mode="json")
    response, code = _send("search", body, server=server)
    if response is None:
        return code
    try:
        parsed = SearchResponse.model_validate(response.json())
    except (ValidationError, ValueError) as exc:
        return _malformed("SearchResponse", exc)
    if as_json:
        print(response.text)
    else:
        _print_search(parsed)
    return 0


def fetch(
    *,
    server: str = _DEFAULT_SERVER,
    url: str,
    query: str | None = None,
    offset: int | None = None,
    path: str | None = None,
    provider: str | None = None,
    as_json: bool = False,
) -> int:
    """`POST /api/v1/fetch`; returns an exit code.

    The same two models and rules as :func:`search`. `--json` prints the body the
    server sent, not a re-serialisation, so what a caller pipes into `jq` is what
    the server said. A pre-dispatch refusal comes back as its prose on stderr and
    exit `1`: the client writes no wording of its own.
    """
    body = FetchRequest(
        url=url, query=query, offset=offset, path=path, provider=provider
    ).model_dump(mode="json")
    response, code = _send("fetch", body, server=server)
    if response is None:
        return code
    try:
        parsed = FetchResponse.model_validate(response.json())
    except (ValidationError, ValueError) as exc:
        return _malformed("FetchResponse", exc)
    if as_json:
        print(response.text)
    else:
        _print_fetch(parsed)
    return 0


def answer(
    *,
    server: str = _DEFAULT_SERVER,
    query: str,
    extra_queries: list[str] | None = None,
    depth: Literal["brief", "report"] | None = None,
    provider: str | None = None,
    include_domains: list[str] | None = None,
    exclude_domains: list[str] | None = None,
    recency: Literal["day", "week", "month", "year"] | None = None,
    language: str | None = None,
    safe_search: bool | None = None,
    as_json: bool = False,
) -> int:
    """`POST /api/v1/answer`; returns an exit code.

    The same two models and rules as its siblings: `models.AnswerRequest` in,
    `models.AnswerResponse` out, imported rather than re-declared. Nothing about
    the plan, the model or the prices lives here -- `depth` is the one cost knob
    the contract gives a caller.

    A server with `[agent] enabled = false` answers 404 and this exits 1: the
    caller acts on that by calling `search` or `fetch` instead.
    """
    body = AnswerRequest(
        query=query,
        extra_queries=extra_queries,
        depth=depth,
        provider=provider,
        include_domains=include_domains,
        exclude_domains=exclude_domains,
        recency=recency,
        language=language,
        safe_search=safe_search,
    ).model_dump(mode="json")
    response, code = _send("answer", body, server=server)
    if response is None:
        return code
    try:
        parsed = AnswerResponse.model_validate(response.json())
    except (ValidationError, ValueError) as exc:
        return _malformed("AnswerResponse", exc)
    if as_json:
        print(response.text)
    else:
        _print_answer(parsed)
    return 0


def _send(
    command: str, body: dict[str, Any], *, server: str
) -> tuple[httpx.Response | None, int]:
    """POST one operation body. Returns (the response, 0), or (None, exit code).

    The one place the client talks to the network and decides what a non-200
    means: the server's own error prose goes to stderr, exit code 1. A server that
    does not answer at all is the same code -- the call failed, usage did not.
    """
    try:
        response = asyncio.run(_post(server, command, body))
    except httpx.HTTPError as exc:
        print(f"seekwright: cannot reach {server}: {exc}", file=sys.stderr)
        return None, 1
    if response.status_code != 200:
        print(f"seekwright: {_error_message(response)}", file=sys.stderr)
        return None, 1
    return response, 0


async def _post(server: str, command: str, body: dict[str, Any]) -> httpx.Response:
    """One POST to `/api/v1/<command>` on `server`."""
    async with httpx.AsyncClient(timeout=_REQUEST_TIMEOUT) as client:
        return await client.post(f"{server.rstrip('/')}/api/v1/{command}", json=body)


def _error_message(response: httpx.Response) -> str:
    """The status that failed, and the server's sentence about it.

    The prose is the contract's, the same sentence the MCP tool hands a model, so
    it passes through unchanged; the status is prepended because it tells a person
    whether trying again is worth anything.
    """
    try:
        payload = response.json()
    except ValueError:
        payload = None
    if isinstance(payload, dict) and isinstance(payload.get("error"), str):
        return f"HTTP {response.status_code}: {payload['error']}"
    body = response.text.strip()
    return f"HTTP {response.status_code}" + (f": {body}" if body else "")


def _refused(exc: ValidationError) -> str:
    """One sentence naming the fields a request got wrong, not pydantic's report.

    The shape the server's 400 uses, so a caller sees the same prose whether the
    body was refused here or there.
    """
    details = "; ".join(
        f"{'.'.join(str(part) for part in error['loc']) or 'body'}: {error['msg']}"
        for error in exc.errors()
    )
    return f"Invalid request: {details}."


def _malformed(model: str, exc: Exception) -> int:
    """A 200 whose body is not the response model: reported, never rendered."""
    print(f"seekwright: the response is not a {model}: {exc}", file=sys.stderr)
    return 1


def _print_search(response: SearchResponse) -> None:
    """The human-readable render of one search response.

    It leads with the routing answer (which provider actually ran), then one block
    per result: title, URL, and the snippet a SERP backend filled or the text a
    content backend did -- never both, per `models.Result`. The server's caps
    bound that text, not a length this render invents.
    """
    print("seekwright search")
    print("=" * 17)
    print(f"query     {response.query}")
    print(f"provider  {response.provider}")
    print(f"results   {len(response.results)}")
    if not response.results:
        print()
        print("no results")
    for index, result in enumerate(response.results, start=1):
        print()
        print(f"{index}. {result.title}")
        print(f"   {result.url}")
        content = result.snippet if result.snippet is not None else result.text
        if content:
            for line in content.splitlines():
                print(f"   {line}")
    if response.notice:
        print()
        print(f"notice: {response.notice}")


def _print_fetch(response: FetchResponse) -> None:
    """The human-readable render of one fetch response.

    Shows the landing URL, plus the requested one whenever a redirect moved the
    fetch: a reader who cannot see that cannot judge whether the text is what they
    asked for (`models.FetchResponse`). The page text follows whole -- `chars`
    says whether it was cut short -- and matches print at their re-fetch offsets.
    """
    print("seekwright fetch")
    print("=" * 16)
    print(f"url       {response.url}")
    if response.requested_url != response.url:
        print(f"requested {response.requested_url}")
    if response.title:
        print(f"title     {response.title}")
    if response.total_chars is not None:
        cut = ", truncated" if response.truncated else ""
        print(f"chars     {response.total_chars}{cut}")
    if response.image is not None:
        # The base64 is the image, and a terminal is not where it is read: `--json`
        # prints the body the server sent, which is the way to get at the bytes.
        print(
            f"image     {response.content_type}, "
            f"{response.image.byte_count:,} bytes (base64 in --json)"
        )
    if response.text:
        print()
        print(response.text)
    for match in response.matches or []:
        print()
        print(f"match at {match.offset}:")
        print(match.text)
    if response.notice:
        print()
        print(f"notice: {response.notice}")


def _print_answer(response: AnswerResponse) -> None:
    """The human-readable render of one answer response.

    The prose first, then the sources it actually cited: the answer is only as
    good as the list under it, and that list is the server's, built from what it
    retrieved rather than from what the model claimed, so a sentence with nothing
    behind it is visible as one. The counts say what the plan did, and `notice`
    carries what the server had to leave out.
    """
    print("seekwright answer")
    print("=" * 18)
    print(f"query     {response.query}")
    print(f"model     {response.model}")
    print(f"depth     {response.depth}")
    print(f"searches  {response.searches}")
    print(f"fetched   {response.fetched}")
    if response.truncated:
        print("the answer stopped at the model's output cap and is cut short")
    print()
    print(response.answer)
    print()
    if response.sources:
        print(f"sources   {len(response.sources)}")
        for index, source in enumerate(response.sources, start=1):
            print(f"{index}. {source.title}")
            print(f"   {source.url}")
            print(f"   via {source.provider}")
    else:
        # Not an error: the prose simply cited nothing, which the notice says
        # too. Read the answer as unverified.
        print("sources   none cited")
    if response.notice:
        print()
        print(f"notice: {response.notice}")


def _default_route(cfg: Config) -> str:
    """What an unnamed ``search`` does here, in the words of the route it takes.

    Three cases, each naming a route: the configured default, the free walk a
    deployment with nothing but free names and no default takes, and the refusal
    everything else gets.
    """
    if cfg.default_provider is not None:
        return cfg.default_provider
    if cfg.default_route_is_free_only():
        return "none (a bare search walks the free set)"
    return "none (callers must pass provider)"


def check(
    *,
    live: bool = False,
    config: Config | None = None,
    log_level: LogLevel | None = None,
    log_format: Literal["text", "json"] | None = None,
) -> int:
    """Run the self-diagnostics. Returns a process exit code.

    ``config`` is injectable for tests; the CLI always loads the real one.
    """
    cfg = config or load_config()
    # The report is `print`ed, not logged -- it is this command's output. Logging
    # is set up so a library warning arrives in the server's format on stderr.
    setup_logging(apply_log_overrides(cfg.logging, log_level, log_format))
    problems = 0
    print("seekwright check")
    print("=" * 16)

    path = config_path()
    print(f"config      {path}  {'(present)' if path.is_file() else '(defaults)'}")
    print(f"default     {_default_route(cfg)}")
    # Always printed: a permissive default an operator cannot see is the surprise
    # this line removes. An absent key and a list containing "*" render alike.
    declared = cfg.permitted_providers
    permitted = (
        ", ".join(declared)
        if declared is not None
        else "(unset: every enabled provider)"
    )
    print(f"permitted   {permitted}")

    async def run_probes() -> tuple[list[str], int, int]:
        timeout = cfg.policy.provider_timeout_seconds
        async with httpx.AsyncClient(follow_redirects=True, timeout=timeout) as client:
            return await _probe_all(cfg, client, live=live)

    lines, probe_problems, ready = asyncio.run(run_probes())
    problems += probe_problems
    print("providers")
    if cfg.providers_defaulted:
        # The rows below are the effective set; this says where it came from.
        print(
            "  implicit  nothing was enabled, so the keyless set "
            f"({', '.join(KEYLESS_PROVIDERS)}) is the effective set"
        )
    untested = sorted(set(cfg.enabled_providers()) & UNTESTED_PROVIDERS)
    if untested:
        # The sibling of the implicit line, for how ready a member is: an
        # unverified provider says so where the operator reads its status.
        verb = "is" if len(untested) == 1 else "are"
        print(
            f"  untested  {', '.join(untested)} {verb} new and untested: no live "
            "verification against the real endpoint has happened in-repo "
            "(docs/reference/providers.md)"
        )
    for line in lines:
        print(line)

    enabled = cfg.enabled_providers()
    if ready:
        print(f"{ready} of {len(enabled)} enabled providers ready")
    else:
        print("no providers ready -- searches would fail until configured")
        problems += 1

    # Printed only when the allow-list narrows something; a line saying nothing
    # changed is noise.
    effective = cfg.effective_providers()
    if len(effective) != len(enabled):
        refused = [name for name in enabled if name not in effective]
        print(
            f"effective   {len(effective)} of {len(enabled)} enabled providers "
            f"permitted; not permitted: {', '.join(refused)}"
        )

    problems += _report_fetch(cfg, live=live)
    problems += _report_agent(cfg)
    return 1 if problems else 0


# The column labels, in order: this tuple is the surface's published contract
# (docs/reference/metrics.md, Surfaces), so a figure is added here and nowhere else.
_METRIC_COLUMNS = (
    "provider",
    "calls",
    "errors",
    "fellback",
    "samples",
    "p50 ms",
    "p95 ms",
    "mean ms",
    "cost usd",
    "$/1k",
    "last seen",
)


def metrics(
    *,
    as_json: bool = False,
    config: Config | None = None,
    log_level: LogLevel | None = None,
    log_format: Literal["text", "json"] | None = None,
) -> int:
    """Report the per-endpoint latency and cost window. Returns an exit code.

    Built from ``dashboard.history_path`` directly, never through :mod:`server`:
    no provider is constructed, no network call is made, nothing is billed, which
    is what lets this run on a box that holds no keys. ``dashboard.enabled`` does
    not gate it -- that key gates the HTTP page, this is another surface on the
    same journal.

    ``config`` is injectable for tests; the CLI always loads the real one.

    The exit code is 0 whenever the report was produced, including an empty window
    and no journal at all. The one non-zero exit is a ``history_path`` whose
    parent is missing or unwritable -- the server's own startup error, a config
    problem rather than a metrics one.
    """
    cfg = config or load_config()
    # Same reason as `check`: a warning raised while the journal is folded belongs
    # on stderr in the server's format; the report goes to stdout.
    setup_logging(apply_log_overrides(cfg.logging, log_level, log_format))
    try:
        recorder = UsageRecorder(history_path=cfg.dashboard.history_path)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"seekwright: dashboard.history_path: {exc}") from exc

    snapshot = cast("dict[str, Any]", recorder.snapshot())
    endpoints = cast("dict[str, Any]", snapshot["endpoints"])
    if as_json:
        # Structurally equal to the route body: the terminal and the browser read
        # the same object, so they cannot drift.
        print(json.dumps(endpoints, indent=2))
        return 0
    _print_metrics(endpoints, cast("dict[str, Any]", snapshot["journal"]))
    return 0


def _print_metrics(endpoints: dict[str, Any], journal: dict[str, Any]) -> None:
    """Print the window rollup: the routing answer, one line per provider.

    The per-day series is not printed -- that is what ``--json`` and the dashboard
    panel are for. The column *labels and order* are the contract; whitespace is not.
    """
    today = datetime.now(UTC).date()
    window_days = int(endpoints["window_days"])
    first = (today - timedelta(days=window_days - 1)).isoformat()
    print("seekwright metrics")
    print("=" * 18)
    print(f"window      {window_days} days, {first} .. {today.isoformat()} (UTC)")
    print(f"journal     {_journal_state(journal)}")
    print()

    rows = [_metric_row(entry) for entry in endpoints["providers"]]
    if not rows:
        # Absent, not zero: a zero row would read as "$0.0000 spent" rather than
        # "nothing recorded".
        print("no history")
        return
    widths = [
        max(len(label), *(len(row[i]) for row in rows))
        for i, label in enumerate(_METRIC_COLUMNS)
    ]
    print(_format_row(_METRIC_COLUMNS, widths))
    for row in rows:
        print(_format_row(row, widths))


def _journal_state(journal: dict[str, Any]) -> str:
    """The journal's state in one phrase, for the report's header line."""
    path = journal["path"]
    if path is None:
        return "off — dashboard.history_path unset"
    return f"{path}  {'failed' if journal['failed'] else 'ok'}"


def _metric_row(entry: dict[str, Any]) -> list[str]:
    """One rollup row as table cells, in `_METRIC_COLUMNS` order."""
    return [
        str(entry["provider"]),
        str(entry["calls"]),
        str(entry["errors"]),
        str(entry["fell_back_calls"]),
        str(entry["latency_samples"]),
        _milliseconds(entry["p50_ms"]),
        _milliseconds(entry["p95_ms"]),
        _milliseconds(entry["mean_ms"]),
        f"{float(entry['cost_usd']):.4f}",
        _per_1k(entry["cost_per_1k"]),
        _seen(entry["last_seen"]),
    ]


def _milliseconds(value: int | None) -> str:
    """A latency figure, or an em dash when there is no sample.

    ``null`` never renders as ``0``: zero reads as "instant", absence as "nothing
    to measure".
    """
    return "—" if value is None else str(value)


def _per_1k(value: float | None) -> str:
    """The measured dollars-per-thousand-calls figure, or an em dash."""
    return "—" if value is None else f"{value:.4f}"


def _seen(value: str | None) -> str:
    """A journal timestamp, truncated to seconds with a `Z` suffix.

    The journal writes microsecond precision; a "when was this last used" column
    does not need it, and the fixed width keeps the table readable.
    """
    if value is None:
        return "—"
    return datetime.fromisoformat(value).astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _format_row(cells: Sequence[str], widths: list[int]) -> str:
    """Two spaces between columns; the provider and the timestamp left-aligned."""
    last = len(cells) - 1
    return "  ".join(
        cell.ljust(widths[i]) if i in (0, last) else cell.rjust(widths[i])
        for i, cell in enumerate(cells)
    )


def _report_fetch(cfg: Config, *, live: bool) -> int:
    """Report the fetch section of ``--check``; returns the problems found.

    Separate from the provider rows and not in the ready tally: fetch has no API
    key and costs nothing, so it is never why a search would fail.

    A fallback missing its prerequisite is silently inert at runtime, which is
    what --check exists to say out loud; none is counted as a problem, because
    fetch works without any fallback. Every row comes out of
    :data:`fetcher.KNOWN_FALLBACKS`, so a registry addition is reported without an
    edit here.

    The primary route is the one fetch fact that can stop the server:
    ``server.main`` refuses a primary this deployment cannot build, so an
    inactive one counts as a problem.
    """
    problems = 0
    print("fetch")
    if not cfg.fetch.enabled:
        print("  disabled in config")
        return problems
    print(
        f"  enabled   {cfg.fetch.max_text_chars} chars max, "
        f"{cfg.fetch.max_redirects} redirects, "
        f"private addresses "
        f"{'allowed' if cfg.fetch.allow_private_addresses else 'blocked'}"
    )
    if cfg.fetch.primary == "http":
        print("  primary   http (the local reader)")
    else:
        row = KNOWN_FALLBACKS.get(cfg.fetch.primary)
        state = (
            _fallback_state(cfg, row)
            if row is not None
            else "(inactive: no row in the fallback registry)"
        )
        print(f"  primary   {cfg.fetch.primary} {state}")
        if state.startswith("(inactive:"):
            # Not a note: with a primary configured, an unbuilt one is a startup
            # refusal, not an inert fallback.
            problems += 1
    # The backend library is an install fact, not a config one: the only place a
    # missing extra is visible without starting the server, and why fetch would fail.
    try:
        backend = build_extractor(cfg)
    except ExtractorUnavailable as exc:
        print(f"  extractor {cfg.fetch.extractor}  UNAVAILABLE: {exc}")
        problems += 1
    else:
        print(f"  extractor {cfg.fetch.extractor}")
        if not backend.supported_types & PDF_TYPES:
            # A note, not a problem: the PDF parser left the core install, so a
            # working backend does not imply a parser.
            if cfg.fetch.extractor == "stdlib":
                print(
                    "  pdf       not read: the stdlib backend reads no PDF "
                    "(install the 'trafilatura' extra and select that backend)"
                )
            else:
                print(
                    "  pdf       not read: this install carries no PDF parser "
                    "(install the 'trafilatura' extra)"
                )
    if cfg.fetch.fallback:
        print(f"  fallback  {' -> '.join(cfg.fetch.fallback)}")
        for name in cfg.fetch.fallback:
            row = KNOWN_FALLBACKS.get(name)
            if row is None:
                # `FetchConfig._validate_fallback` refuses a name outside the
                # registry, so a row-less name is a Config built around
                # validation: the same defensive read `factory.build_fetch_stack`
                # makes, reported rather than raised.
                print(f"  {name:<9} (inactive: no row in the fallback registry)")
                continue
            print(f"  {name:<9} {_fallback_state(cfg, row)}")
    if live:
        line, ok = asyncio.run(_live_fetch_probe(cfg))
        print(f"  {line}")
        if not ok:
            problems += 1
    return problems


def _fallback_state(cfg: Config, row: Fallback) -> str:
    """What one configured fallback is, read off its registry row rather than its name.

    Three readings of the row answer for every fallback the registry holds, and
    none of them is the name:

    * the permission set, asked only of a row that dials an ``endpoint`` constant:
      it can leave a keyed *and* a keyless third-party fallback inert
      (docs/reference/allow-list.md, site 7). An ``endpoint=None`` row dials a host
      this deployment wrote, and :meth:`FetchConfig._validate_permitted_providers`
      refuses a self-hosted name in `permitted_providers`, so asking the set there
      would report a live fallback inert;
    * whether the config counts the name as having a credential at all
      (:data:`config.PROVIDERS_REQUIRING_KEY`, the census
      :meth:`Config.missing_api_keys` asks). A keyed fallback reads
      ``SEEKWRIGHT_<PROVIDER>_API_KEY`` like the provider it shares a name with, so
      a fallback named for a keyless provider such as ``searxng`` says what it
      lacks instead of naming a key no vendor has;
    * where its host comes from: an ``endpoint`` constant dials a third party that
      is always addressable; ``endpoint=None`` dials the ``[fetch]`` attribute its
      ``fetch_key`` names, which this deployment may not have written.

    Never counted as a problem: fetch works without any fallback. The only network
    call here is the free health probe of a host this deployment names.
    """
    if row.endpoint is not None and not cfg.is_permitted(row.name):
        # Only a row dialing a third-party constant has a host the set can refuse.
        return "(inactive: not permitted)"
    keyed = row.name in PROVIDERS_REQUIRING_KEY
    if keyed and not cfg.api_key(row.name):
        return "(inactive: no API key)"
    if row.endpoint is None:
        if row.fetch_key is None:
            # `Fallback.__post_init__` refuses this shape, so a row that reaches here was built around it.
            return "(inactive: the fallback row names no host)"
        url = getattr(cfg.fetch, row.fetch_key, None)
        if not url:
            return f"(inactive: no fetch.{row.fetch_key})"
        return asyncio.run(_probe_renderer(cfg, url))
    return "keyed" if keyed else "keyless"


def _report_agent(cfg: Config) -> int:
    """Report the agent section of ``--check``; returns the problems found.

    Agent mode is the one section whose incompleteness is fatal at startup --
    ``server.main`` refuses to run without an endpoint, a model and a key -- so the
    same fact is a problem here, reported rather than raised: the operator sees
    what is missing without the server dying to tell them.

    Nothing here reaches the network or bills. The model endpoint is not probed: a
    probe would be a call on the operator's account.
    """
    print("agent")
    if not cfg.agent.enabled:
        print("  disabled in config")
        return 0
    missing = cfg.missing_agent_settings()
    if missing:
        print(f"  enabled but incomplete: {', '.join(missing)}")
        return 1
    print(f"  model     {cfg.agent.model}")
    print(f"  endpoint  {cfg.agent.base_url}")
    return 0


_FETCH_PROBE_URL = "https://example.com/"


async def _probe_renderer(cfg: Config, url: str) -> str:
    """Probe a self-hosted fallback: GET /health, free, like the provider probes.

    ``/health`` is the one path crawl4ai's auth gate leaves public, so this proves
    the network path and nothing about the token. Reported, never counted as a
    problem: fetch degrades to the next fallback without it.
    """
    base = url.rstrip("/")
    try:
        async with httpx.AsyncClient(
            timeout=cfg.policy.provider_timeout_seconds
        ) as client:
            resp = await client.get(f"{base}/health")
    except httpx.HTTPError:
        return "unreachable"
    return "reachable" if resp.status_code == 200 else f"HTTP {resp.status_code}"


async def _live_fetch_probe(cfg: Config) -> tuple[str, bool]:
    """Fetch one stable page. Unlike the provider live probes, this is free."""
    fetcher = HttpFetcher(
        extractor=build_extractor(cfg),
        timeout=cfg.fetch.timeout_seconds,
        max_download_bytes=cfg.fetch.max_download_bytes,
        max_text_chars=cfg.fetch.max_text_chars,
        max_redirects=cfg.fetch.max_redirects,
        allow_private_addresses=cfg.fetch.allow_private_addresses,
        user_agent=cfg.fetch.user_agent,
    )
    started = time.monotonic()
    try:
        page = await fetcher.fetch(_FETCH_PROBE_URL)
    except ProviderError as exc:
        return f"live probe FAILED: {exc.message}", False
    finally:
        await fetcher.aclose()
    elapsed = int((time.monotonic() - started) * 1000)
    return (
        f"live probe ok ({_FETCH_PROBE_URL}, {len(page.text)} chars, {elapsed}ms)",
        True,
    )


async def _probe_all(
    cfg: Config, client: httpx.AsyncClient, *, live: bool
) -> tuple[list[str], int, int]:
    """Probe every enabled provider; returns (lines, problems, ready count)."""
    providers = build_providers(cfg, client)
    lines: list[str] = []
    problems = 0
    ready: list[tuple[str, SearchProvider]] = []

    for name in cfg.enabled_providers():
        provider = providers.get(name)
        if provider is None:
            lines.append(
                f"  {name:<9} no API key (set {api_key_env_var(name)})"
            )
            problems += 1
            continue

        # Duck-typed like the server lifespan: MCP-backed providers expose
        # warmup(), HTTP ones do not.
        warmup = getattr(provider, "warmup", None)
        if warmup is not None:
            ok = await warmup()
            status = "MCP handshake ok" if ok else "MCP handshake failed"
        else:
            status = await _probe_http(name, cfg, client)

        # A rejected key is a problem, and "no API key (key is mandatory)" is a
        # missing credential, not a reachable endpoint.
        if status in ("reachable", "reachable (no key sent)", "MCP handshake ok"):
            ready.append((name, provider))
        else:
            problems += 1
        # Read off `cost_per_1k`, not identity: a zero there is the adapter
        # declaring itself unbilled.
        price = f"${provider.cost_per_1k:.2f}/1k" if provider.cost_per_1k else "unbilled"
        lines.append(f"  {name:<9} {status:<22} {price}")

    if live:
        lines.append("live probes (one real search per ready permitted provider):")
        for name, provider in ready:
            if not cfg.is_permitted(name):
                # A live probe *is* a real search, exactly the dispatch the
                # allow-list refuses: running one would bill a name under the line
                # that says it is excluded.
                lines.append(f"  {name:<9} skipped: not permitted")
                continue
            line, ok = await _live_probe(provider)
            lines.append(f"  {name:<9} {line}")
            if not ok:
                problems += 1

    if not ready and not live:
        lines.append("  (none ready)")
    return lines, problems, len(ready)


# The exact prose --check prints, one per ProbeOutcome: every member needs an
# entry, because the diagnostic path must not raise. tests/test_cli.py pins it.
_PROSE = {
    ProbeOutcome.REACHABLE: "reachable",
    ProbeOutcome.REACHABLE_NO_KEY: "reachable (no key sent)",
    ProbeOutcome.KEY_REJECTED: "reachable, but API key rejected",
    ProbeOutcome.KEY_REQUIRED: "no API key (key is mandatory)",
    ProbeOutcome.UNREACHABLE: "unreachable",
    ProbeOutcome.UNSUPPORTED: "unsupported (no connectivity probe)",
}


async def _probe_http(name: str, cfg: Config, client: httpx.AsyncClient) -> str:
    """Render `health.probe`'s outcome in the prose --check prints."""
    return _PROSE[await probe(name, client=client, config=cfg)]


async def _live_probe(provider: SearchProvider) -> tuple[str, bool]:
    """One real search on ``provider``; returns (description, ok)."""
    query = SearchQuery(query=_PROBE_QUERY, max_results=1)
    started = time.monotonic()
    try:
        result = await provider.search(query)
    except ProviderError as exc:
        return f"FAILED: {exc.message}", False
    elapsed = int((time.monotonic() - started) * 1000)
    cost_for = getattr(provider, "cost_for", None)
    cost = (
        result.cost_usd
        if result.cost_usd is not None
        else (cost_for(1) if cost_for is not None else None)
    )
    detail = f"results={len(result.results)}"
    if cost is not None:
        detail += f" cost=${cost:.4f}"
    detail += f" {elapsed}ms"
    if result.results:
        detail += f"  first={result.results[0].url}"
    return detail, True
