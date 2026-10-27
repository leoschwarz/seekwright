"""The two properties this module exists to guarantee: stderr only, keys never.

Both are tested twice -- once behaviourally, once structurally. The behavioural
test proves the current code is right; the structural one is what keeps it right
after a refactor that nobody thought to re-check.
"""

from __future__ import annotations

import ast
import json
import logging as stdlib_logging
import pathlib
import re
from typing import ClassVar

import pytest
from loguru import logger

from seekwright.config import LoggingConfig
from seekwright.logs import (
    InterceptHandler,
    apply_log_overrides,
    bind,
    elapsed_ms,
    host_of,
    query_fields,
    result_fields,
    safe,
    setup_logging,
)
from seekwright.models import Result

SRC = pathlib.Path(__file__).parent.parent / "src" / "seekwright"


class TestNothingOnStdout:
    """Under stdio, stdout is the JSON-RPC channel. A log line on it is a bug."""

    def test_every_stream_lands_on_stderr(self, capfd):
        # `capfd`, not `capsys`: the leak is a handler that captured the original
        # stream at basicConfig time.
        setup_logging(LoggingConfig(library_level="INFO", access_log=True))

        bind(provider="serper").info("search.ok")
        stdlib_logging.getLogger("uvicorn.access").info("uvicorn-line")
        stdlib_logging.getLogger("mcp.server.lowlevel.server").info("sdk-line")

        captured = capfd.readouterr()
        assert captured.out == ""
        for expected in ("search.ok", "uvicorn-line", "sdk-line"):
            assert expected in captured.err

    def test_uvicorn_access_can_only_reach_stderr_through_root(self):
        """A structural guard on the fix in `_serve_http`.

        uvicorn ships a `LOGGING_CONFIG` pointing `uvicorn.access` at stdout
        with `propagate: False`. Passing `log_config=None` is what stops it
        being applied; this pins the resulting state rather than the argument,
        so it fails whichever way the fix gets undone.
        """
        setup_logging(LoggingConfig())
        access = stdlib_logging.getLogger("uvicorn.access")
        assert access.handlers == []
        assert access.propagate is True


class TestNoSecretsEscape:
    CANARY = "sk-canary-DO-NOT-LOG"

    def test_intercepted_traceback_drops_the_exception_payload(self, capfd):
        """The place loguru's own documented recipe would leak.

        The canonical InterceptHandler forwards `record.exc_info`, which
        re-renders an upstream traceback through our sink. An httpx exception's
        frames hold the request headers, and those hold the API key.
        """
        setup_logging(LoggingConfig(library_level="INFO"))
        try:
            raise RuntimeError(f"connection failed with header {self.CANARY}")
        except RuntimeError:
            # G201 wants `.exception()` here, which is exactly what a
            # third-party library would call. Standing in for one is the test.
            stdlib_logging.getLogger("httpx").error(  # noqa: G201
                "upstream blew up", exc_info=True
            )

        captured = capfd.readouterr()
        assert captured.out == ""
        assert self.CANARY not in captured.err
        # The type survives, because "a RuntimeError happened" is the
        # diagnostic value and carries no payload.
        assert "RuntimeError" in captured.err

    def test_sink_is_configured_without_diagnose_or_backtrace(self, capfd):
        """loguru's defaults are `backtrace=True, diagnose=True`.

        `diagnose=True` renders local variable *values* into a frame, and every
        adapter builds `headers = {"x-api-key": ...}` as a local before the call
        that fails. This drives that exact shape through a real handler.
        """
        setup_logging(LoggingConfig())

        def call_provider():
            # Live local at the moment of the raise -- the exact shape every
            # adapter has, and what `diagnose=True` would render.
            headers = {"x-api-key": self.CANARY}
            if headers:
                raise RuntimeError("network error")

        try:
            call_provider()
        except RuntimeError:
            logger.error("search.failed")

        captured = capfd.readouterr()
        assert self.CANARY not in captured.err
        assert "headers" not in captured.err


class TestSourceDiscipline:
    """Rules enforced structurally, so review does not have to catch them.

    All of these walk the AST rather than the text. A substring search would
    match this module's own prose about what not to write, and `parser.error`
    would look like a log call.
    """

    LEVELS = frozenset(
        {"trace", "debug", "info", "success", "warning", "error", "critical"}
    )
    # Rooted in those names, which is what keeps `parser.error(...)` out of the
    # scan.
    ORIGINS = frozenset({"logger", "bind", "log", "entry"})

    @staticmethod
    def _sources() -> list[tuple[pathlib.Path, ast.Module]]:
        return [
            (p, ast.parse(p.read_text())) for p in sorted(SRC.rglob("*.py"))
        ]

    @classmethod
    def _root_name(cls, node: ast.expr) -> str | None:
        """Walk `a.b(...).c` back to `a`."""
        while True:
            match node:
                case ast.Attribute(value=inner):
                    node = inner
                case ast.Call(func=inner):
                    node = inner
                case ast.Name(id=name):
                    return name
                case _:
                    return None

    @classmethod
    def _log_calls(cls, tree: ast.Module):
        for node in ast.walk(tree):
            match node:
                case ast.Call(func=ast.Attribute(attr=attr, value=receiver)) if (
                    attr in cls.LEVELS and cls._root_name(receiver) in cls.ORIGINS
                ):
                    yield node
                case _:
                    pass

    def test_no_traceback_rendering_anywhere(self):
        """`diagnose=True` prints local variable values, and a local is the key.

        `logger.exception`, `logger.catch` and either traceback flag all end in
        the same place: a frame from a provider adapter, where
        `headers = {"x-api-key": ...}` is in scope.
        """
        offenders: list[str] = []
        for path, tree in self._sources():
            for node in ast.walk(tree):
                match node:
                    case ast.Attribute(attr="exception" | "catch", value=receiver) if (
                        self._root_name(receiver) in self.ORIGINS
                    ):
                        offenders.append(f"{path.relative_to(SRC)}:{node.lineno}")
                    case ast.keyword(
                        arg="diagnose" | "backtrace", value=ast.Constant(value=True)
                    ):
                        offenders.append(f"{path.relative_to(SRC)}: traceback flag")
                    case _:
                        pass
        assert offenders == [], f"tracebacks here hold API keys: {offenders}"

    def test_log_messages_are_constant_event_names(self):
        """A value reaches a log line only by being named in `bind()`.

        The first argument of every log call must be a literal string. That is
        the enforceable form of the convention -- it is what lets one call site
        render as text or JSON, and it is why no f-string can smuggle an
        exception object into a message.
        """
        offenders: list[str] = []
        for path, tree in self._sources():
            for node in self._log_calls(tree):
                first = node.args[0] if node.args else None
                if not (
                    isinstance(first, ast.Constant) and isinstance(first.value, str)
                ):
                    offenders.append(f"{path.relative_to(SRC)}:{node.lineno}")
        assert offenders == [], f"non-constant log message at: {offenders}"

    def test_event_names_are_dotted_and_lowercase(self):
        for path, tree in self._sources():
            for node in self._log_calls(tree):
                match node.args:
                    case [ast.Constant(value=str() as event), *_]:
                        assert re.fullmatch(r"[a-z_]+(\.[a-z_]+)*", event), (
                            f"{path.name}:{node.lineno}: {event!r} is not a "
                            "dotted event name"
                        )
                    case _:
                        pass

    def test_the_scan_actually_finds_the_call_sites(self):
        """Guards the guards: a broken matcher would pass every test above."""
        found = {
            path.name for path, tree in self._sources() if any(self._log_calls(tree))
        }
        assert {"engine.py", "server.py", "exa_mcp.py"} <= found


class TestQueryFields:
    def test_text_is_withheld_by_default(self):
        fields = query_fields(LoggingConfig(), "write-ahead logging")
        assert fields == {"qlen": 19, "qhash": fields["qhash"]}
        assert "query" not in fields

    def test_hash_is_stable_across_calls(self):
        cfg = LoggingConfig()
        assert query_fields(cfg, "same")["qhash"] == query_fields(cfg, "same")["qhash"]
        assert query_fields(cfg, "a")["qhash"] != query_fields(cfg, "b")["qhash"]

    def test_opting_in_adds_the_text(self):
        fields = query_fields(LoggingConfig(log_queries=True), "write-ahead logging")
        assert fields["query"] == "write-ahead logging"

    def test_opting_in_announces_itself(self, capfd):
        """A privacy-affecting setting says so where the operator will see it."""
        setup_logging(LoggingConfig(log_queries=True))
        assert "startup.query_logging_enabled" in capfd.readouterr().err


class TestResultFields:
    """The content half of the same switch. `query_fields`' sibling."""

    CAPS: ClassVar[dict[str, int]] = {"snippet_chars": 500, "text_chars": 2000}

    def test_a_serp_hit_carries_its_snippet_and_no_text_key(self):
        fields = result_fields(
            Result(title="Polars vs pandas", url="https://x.test/a", snippet="a bench"),
            1,
            **self.CAPS,
        )
        assert fields["rank"] == 1
        assert fields["title"] == "'Polars vs pandas'"
        assert fields["snippet"] == "'a bench'"
        # `snippet` or `text`, never both -- filling both ships the same prose
        # twice, and the log has no business inventing a shape the wire forbids.
        assert "text" not in fields

    def test_a_content_hit_carries_its_text_and_no_snippet_key(self):
        fields = result_fields(
            Result(title="t", url="https://x.test/a", text="the body"), 2, **self.CAPS
        )
        assert fields["text"] == "'the body'"
        assert "snippet" not in fields

    def test_truncation_is_recorded_only_when_it_happened(self):
        """A thin result and a clipped one are the distinction being debugged."""
        plain = result_fields(Result(title="t", url="u", text="x"), 1, **self.CAPS)
        assert "text_truncated" not in plain

        clipped = result_fields(
            Result(title="t", url="u", text="x", text_truncated=True), 1, **self.CAPS
        )
        assert clipped["text_truncated"] is True

    def test_a_hostile_title_cannot_forge_a_log_line(self):
        """A title is whatever was in a page the *model* chose. Assume malice."""
        fields = result_fields(
            Result(title="ok\nWARNING fake.event", url="u", snippet="s"),
            1,
            **self.CAPS,
        )
        assert "\n" not in str(fields["title"])

    def test_content_is_clipped_to_the_policy_cap(self):
        fields = result_fields(
            Result(title="t", url="u", snippet="x" * 900), 1, snippet_chars=500,
            text_chars=2000,
        )
        assert len(str(fields["snippet"])) <= 504

    def test_opting_in_announces_itself(self, capfd):
        setup_logging(LoggingConfig(log_content=True))
        assert "startup.content_logging_enabled" in capfd.readouterr().err

    def test_the_default_announces_nothing(self, capfd):
        setup_logging(LoggingConfig())
        assert "content_logging_enabled" not in capfd.readouterr().err


class TestHelpers:
    def test_safe_cannot_forge_a_log_line(self):
        rendered = safe("evil\nWARNING fake.event")
        assert "\n" not in rendered

    def test_safe_clips(self):
        assert len(safe("x" * 500, 20)) <= 24

    def test_host_of_survives_a_malformed_url(self):
        # The malformed URL is precisely the input that produces `fetch.blocked`,
        # so raising here would turn a clean refusal into a 500.
        assert host_of("::::") == "?"
        assert host_of("http://example.test/a") == "example.test"

    def test_elapsed_ms_is_a_non_negative_int(self):
        import time

        assert isinstance(elapsed_ms(time.monotonic()), int)
        assert elapsed_ms(time.monotonic()) >= 0

    def test_overrides_are_a_copy_not_a_mutation(self):
        cfg = LoggingConfig()
        updated = apply_log_overrides(cfg, "DEBUG", "json")
        assert (updated.level, updated.format) == ("DEBUG", "json")
        assert (cfg.level, cfg.format) == ("INFO", "text")
        assert apply_log_overrides(cfg, None, None) is cfg


class TestSinks:
    def test_json_sink_emits_a_flat_object(self, capfd):
        setup_logging(LoggingConfig(format="json"))
        bind(provider="exa", cost_usd=0.007, ms=842).info("search.ok")

        payload = json.loads(capfd.readouterr().err.strip())
        assert payload["event"] == "search.ok"
        assert payload["level"] == "INFO"
        assert (payload["provider"], payload["cost_usd"], payload["ms"]) == (
            "exa",
            0.007,
            842,
        )

    def test_text_sink_appends_fields(self, capfd):
        setup_logging(LoggingConfig(format="text"))
        bind(provider="serper", ms=12).info("search.ok")

        line = capfd.readouterr().err.strip()
        assert "search.ok" in line
        assert "provider=serper" in line and "ms=12" in line

    def test_text_sink_handles_an_event_with_no_fields(self, capfd):
        setup_logging(LoggingConfig(format="text"))
        bind().info("shutdown")
        assert capfd.readouterr().err.strip().endswith("shutdown")

    @pytest.mark.parametrize("fmt", ["text", "json"])
    def test_a_brace_in_a_value_does_not_raise(self, capfd, fmt):
        """Why the sinks are functions rather than loguru `format` callables.

        A format callable must return a format *template*, so any `{` in a field
        value -- a provider `notice`, a refusal message -- gets re-interpolated
        and raises KeyError inside the sink. That failure only ever shows up in
        production, on the error path.
        """
        setup_logging(LoggingConfig(format=fmt))
        bind(notice="ignored {constraint} here").info("search.ok")
        assert "search.ok" in capfd.readouterr().err


class TestInterceptHandler:
    def test_unknown_level_falls_back_to_the_numeric_one(self, capfd):
        setup_logging(LoggingConfig(library_level="TRACE"))
        stdlib_logging.addLevelName(25, "NOTICE")
        stdlib_logging.getLogger("mcp").log(25, "odd-level-line")
        assert "odd-level-line" in capfd.readouterr().err

    def test_records_carry_their_source_logger(self, log_records):
        stdlib_logging.getLogger("root").addHandler(InterceptHandler())
        stdlib_logging.getLogger("uvicorn.error").setLevel(stdlib_logging.INFO)
        stdlib_logging.getLogger("uvicorn.error").error("boom")
        assert any(r.record["extra"].get("logger") == "uvicorn.error" for r in log_records)
