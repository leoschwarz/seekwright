"""Shared fixtures. There are exactly two, and both exist because of loguru.

This file holds no stubs: `tests/features/test_provider_selection.py` keeps its own next
to the tests that use it, and a fake shared by two call sites still belongs
there. Loguru is different -- it is process-global state: every test that
touches an instrumented path emits through whatever handler was installed last,
and the one loguru pre-installs at import has ``diagnose=True``.
Under that handler a failing assertion prints local variables -- including a
stub's API key -- into the pytest report. That is cross-cutting, so it lives
here.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest
from loguru import logger


@pytest.fixture(autouse=True)
def quiet_loguru() -> Iterator[None]:
    """Run every test with no loguru handler unless it asks for one."""
    logger.remove()
    yield
    logger.remove()


@pytest.fixture
def log_records() -> Iterator[list[Any]]:
    """Capture loguru records as objects.

    Tests assert on *fields* rather than on a rendered line: the rendering is
    the sink's business and is tested once, in `test_logs.py`.
    """
    captured: list[Any] = []
    sink_id = logger.add(captured.append, level="TRACE")
    yield captured
    logger.remove(sink_id)
