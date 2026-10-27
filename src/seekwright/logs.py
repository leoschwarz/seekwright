"""Operator-facing logging: one stderr stream, no secrets, no tracebacks.

Everything this process logs goes to stderr, unconditionally. Under the stdio
transport stdout *is* the JSON-RPC channel, so a log line on it is a protocol
violation that presents as a client which mysteriously stops working.

Tracebacks are a redaction decision, not a taste one. loguru's
``diagnose=True`` -- the default, including on the handler it pre-installs at
import -- renders the *values of local variables* into a traceback frame, and
in this codebase those frames hold the API key: every adapter builds
``headers = {"x-api-key": ...}`` as a local before the call that fails. So one
``logger.exception()`` under stock loguru would put a live key in the log store.
``logger.remove()`` retires the pre-installed handler and
``backtrace=False, diagnose=False`` keeps the replacement safe.

The calling convention carries the same rule: a log *message* is always a
constant dotted event name (``search.ok``), and every variable travels as a
bound field -- no f-strings, no ``%s``. That is what lets one call site render
as text or JSON, and a value reaches a log line only by being named in
``bind()``, which `tests/test_logs.py` checks mechanically.

There are deliberately no counters here: aggregation is the log store's job.
"""

from __future__ import annotations

import hashlib
import json
import logging as stdlib_logging
import sys
import time
from typing import TYPE_CHECKING, Any, Literal, override
from urllib.parse import urlsplit

from loguru import logger

from .config import LoggingConfig, LogLevel

if TYPE_CHECKING:
    # Stub-only names: loguru exports them from its `.pyi` but not at runtime, so importing them unguarded is an ImportError.
    from loguru import Logger, Message

    # Annotation-only, so this module keeps importing nothing but `config`: the wire models have no business
    # being a runtime dependency of the logging setup.
    from .models import Result


def apply_log_overrides(
    cfg: LoggingConfig,
    level: LogLevel | None,
    format_: Literal["text", "json"] | None,
) -> LoggingConfig:
    """Fold the per-invocation CLI overrides onto the configured settings.

    Returns a copy: the CLI flags are about one run, and mutating the loaded
    config would make them look like something the file said.
    """
    updates: dict[str, object] = {}
    if level is not None:
        updates["level"] = level
    if format_ is not None:
        updates["format"] = format_
    return cfg.model_copy(update=updates) if updates else cfg


def bind(**pairs: object) -> Logger:
    """Attach one event's structured fields to the logger.

    Every value that reaches a log line comes through here, which is what makes
    the no-secrets rule checkable instead of merely stated.
    """
    return logger.bind(**pairs)


def elapsed_ms(started: float) -> int:
    """Milliseconds since a `time.monotonic()` mark.

    `cli.py` uses the same idiom for its probes.
    """
    return int((time.monotonic() - started) * 1000)


def query_fields(cfg: LoggingConfig, query: str) -> dict[str, object]:
    """Describe a query without recording it, unless the operator opted in.

    ``qhash`` is a *correlation handle, not anonymisation*: queries are
    low-entropy natural language, so anyone holding the log and a wordlist can
    invert an eight-character digest. What it buys is "the same query ran forty
    times today" without the text sitting in the log store. Unsalted on purpose
    -- a per-process salt would break the across-restart correlation the field
    exists for.
    """
    fields: dict[str, object] = {
        "qlen": len(query),
        "qhash": hashlib.sha256(query.encode()).hexdigest()[:8],
    }
    if cfg.log_queries:
        fields["query"] = query
    return fields


def result_fields(
    result: Result, rank: int, *, snippet_chars: int, text_chars: int
) -> dict[str, object]:
    """Describe one search hit for the log, gated by ``logging.log_content``.

    The gate is the *caller's*, not this function's -- same split as the fetched
    URL at `engine.FetchEngine.fetch`, and the reason this stays a pure field
    builder a test can call directly.

    Everything goes through `safe`: a result title is whatever was in the
    ``<title>`` of a page the model found, so a newline in it would close this
    record and open one an attacker wrote.

    ``snippet`` and ``text`` are mutually exclusive by the invariant in
    ``AGENTS.md``, so this emits whichever is set. Only a true
    ``text_truncated`` is worth a field: it separates a result that was thin
    from one that was merely clipped.
    """
    fields: dict[str, object] = {
        "rank": rank,
        "title": safe(result.title, 200),
        "url": safe(result.url, 200),
    }
    if result.snippet is not None:
        fields["snippet"] = safe(result.snippet, snippet_chars)
    if result.text is not None:
        fields["text"] = safe(result.text, text_chars)
    if result.text_truncated:
        fields["text_truncated"] = True
    return fields


def safe(value: str | None, limit: int = 120) -> str:
    """Render a model-supplied string so it cannot forge a log line.

    ``repr`` rather than the raw value: a value containing a newline would
    otherwise close one record and open a fabricated one. Clipping bounds what a
    very long one does to the stream.
    """
    return repr((value or "")[:limit])


def host_of(url: str) -> str:
    """The host of a URL, or ``?``. Never raises.

    `urlsplit(...).hostname` raises on a malformed URL -- which is precisely the
    input that produces the ``fetch.blocked`` event this is called from, so a
    helper that raised here would turn a clean refusal into a 500.
    """
    try:
        return urlsplit(url).hostname or "?"
    except ValueError:
        return "?"


def _text_sink(message: Message) -> None:
    record = message.record
    extra = " ".join(f"{k}={v}" for k, v in record["extra"].items())
    line = (
        f"{record['time']:%Y-%m-%dT%H:%M:%S%z} "
        f"{record['level'].name:<8} "
        f"{record['message']}"
    )
    sys.stderr.write(f"{line} {extra}\n" if extra else f"{line}\n")


def _json_sink(message: Message) -> None:
    record = message.record
    payload: dict[str, Any] = {
        "ts": record["time"].isoformat(),
        "level": record["level"].name,
        "event": record["message"],
        **record["extra"],
    }
    # `default=str` rather than letting a stray non-serialisable value raise: a sink that throws loses
    # the log line *and* tells nobody why.
    sys.stderr.write(json.dumps(payload, default=str) + "\n")


def to_stdlib_level(level: LogLevel) -> int:
    """Translate a loguru level name into a stdlib one.

    ``TRACE`` and ``SUCCESS`` are loguru's own additions; `Logger.setLevel`
    rejects both with a bare ValueError. Since one setting governs both sides,
    the two that have no stdlib equivalent map to the nearest tier that does.
    """
    match level:
        case "TRACE":
            return stdlib_logging.DEBUG
        case "SUCCESS":
            return stdlib_logging.INFO
        case _:
            # `getLevelNamesMapping`, not `getLevelName`: the latter's str -> int direction is deprecated as a design mistake.
            return stdlib_logging.getLevelNamesMapping()[level]


class InterceptHandler(stdlib_logging.Handler):
    """Route stdlib logging into loguru, dropping exception state on the way.

    Three streams have to end up in one place: FastMCP's
    `logging.basicConfig` (run when `server.py` builds the app at import time),
    the MCP SDK's line per JSON-RPC request, and uvicorn's own. Left alone that
    is two formats on two streams, one of them stdout.

    ``record.exc_info`` is deliberately *not* forwarded, departing from loguru's
    documented recipe: forwarding it would re-emit an upstream traceback --
    including an httpx call, whose frames hold the request headers -- through
    our sink. The exception *type* is kept: "a ConnectError happened" carries no
    payload.
    """

    @override
    def emit(self, record: stdlib_logging.LogRecord) -> None:
        try:
            level: str | int = logger.level(record.levelname).name
        except ValueError:
            level = record.levelno
        fields: dict[str, object] = {"logger": record.name}
        if record.exc_info and record.exc_info[0] is not None:
            fields["exc_type"] = record.exc_info[0].__name__
        logger.bind(**fields).log(level, record.getMessage())


def setup_logging(cfg: LoggingConfig) -> None:
    """Point every log stream in this process at stderr, through loguru.

    Must run *after* :mod:`seekwright.server` is imported. Constructing FastMCP
    calls `logging.basicConfig` at import time, and `basicConfig` is a no-op
    once the root logger has handlers -- so an intercept installed first would
    sit behind FastMCP's handler and every line would print twice.
    ``force=True`` closes and removes whatever `basicConfig` left. `cli.main`
    imports `server` lazily, so a call from `server.main` is always after.
    """
    logger.remove()
    logger.add(
        _json_sink if cfg.format == "json" else _text_sink,
        level=cfg.level,
        # The two that would leak an API key. Never turn these on.
        backtrace=False,
        diagnose=False,
        # `enqueue=True` would spawn a queue and a thread for an ordering guarantee a single-process service does not need,
        # and it is a fork hazard. Left off.
        enqueue=False,
    )

    stdlib_logging.basicConfig(
        handlers=[InterceptHandler()],
        level=stdlib_logging.NOTSET,
        force=True,
    )
    library_level = to_stdlib_level(cfg.library_level)
    for name in ("mcp", "uvicorn", "uvicorn.error", "httpx", "httpcore"):
        stdlib_logging.getLogger(name).setLevel(library_level)
    stdlib_logging.getLogger("uvicorn.access").setLevel(
        stdlib_logging.INFO if cfg.access_log else stdlib_logging.WARNING
    )

    if cfg.log_queries:
        # A privacy-affecting setting announces itself once, where the operator who set it will see it --
        # not only in the docs they read once.
        bind(setting="logging.log_queries").warning("startup.query_logging_enabled")
    if cfg.log_content:
        bind(setting="logging.log_content").warning("startup.content_logging_enabled")
