"""The wheel smoke venv is created non-interactively, and the build jobs are bounded.

`uv venv` asked to create a path that already exists stops and asks: `? A virtual
environment already exists at '/tmp/wheel-smoke'. Do you want to replace it? [y/n]`.
A runner step has no terminal to answer, so a job that writes that line hangs -- and
with every job of a run sharing a `concurrency:` group, the hang holds up the runs
queued behind it. `--clear` is what makes the create non-interactive: `uv venv --help`
at uv 0.13.1 prints `-c, --clear  Remove any existing files or directories at the
target path`. The bound is the other half of the defence -- `timeout-minutes: 10` on
the two jobs that build the artifacts a release ships -- because an unbounded hung
step sits at that prompt until the runner default ends it.

Like `tests/repo/test_ci_workflow_concurrency.py` and
`tests/repo/test_ci_workflow_build_jobs.py`, this reads the workflow file as text: the
runner consumes it, not Python, so the only way a dropped `--clear` or a dropped bound
fails anywhere is that a test looks for it.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

# `uv venv [--clear] --python 3.14 /tmp/wheel-smoke`, at the file's step depth.
VENV_CLEAR = re.compile(r"^\s*uv venv --clear --python 3\.14 /tmp/wheel-smoke\s*$")
VENV_ANY = re.compile(r"^\s*uv venv .*?/tmp/wheel-smoke\s*$")

# The job-level bound, and the two jobs that build the artifacts a release ships.
JOB_HEADER = re.compile(r"^  ([a-z][a-z0-9_-]*):\s*$")
TIMEOUT = re.compile(r"^    timeout-minutes: (\d+)\s*$")
BOUND_MINUTES = 10
BUILD_JOBS = ("container", "wheel")


def job_block(name: str) -> list[str]:
    """The lines of one job of the workflow, from its header to the next job header."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    starts: list[tuple[int, str]] = []
    for index, line in enumerate(lines):
        header = JOB_HEADER.match(line)
        if header is not None:
            starts.append((index, header.group(1)))
    found = [k for k, (_, job) in enumerate(starts) if job == name]
    assert found, f"{WORKFLOW.relative_to(ROOT)}: no job named {name!r}, holding {[j for _, j in starts]}"
    stop = starts[found[0] + 1][0] if found[0] + 1 < len(starts) else len(lines)
    return lines[starts[found[0]][0] + 1 : stop]


def venv_lines() -> list[str]:
    """Every line of the workflow that creates the smoke venv."""
    return [line for line in WORKFLOW.read_text(encoding="utf-8").splitlines() if VENV_ANY.match(line)]


def test_the_smoke_venv_is_created_non_interactively() -> None:
    """The job clears the path instead of letting uv ask a runner to answer it."""
    created = venv_lines()
    assert created, f"{WORKFLOW.relative_to(ROOT)}: creates no /tmp/wheel-smoke venv at all"
    for line in created:
        assert VENV_CLEAR.match(line), (
            f"{WORKFLOW.relative_to(ROOT)}: {line.strip()!r} asks uv to create a path that "
            "may already exist, so the run stops at an interactive replace prompt no "
            "runner can answer"
        )


def test_the_artifact_build_jobs_are_bounded() -> None:
    """A hung build step releases the shared concurrency group instead of holding it."""
    for job in BUILD_JOBS:
        limits: list[int] = []
        for line in job_block(job):
            limit = TIMEOUT.match(line)
            if limit is not None:
                limits.append(int(limit.group(1)))
        assert limits, (
            f"{WORKFLOW.relative_to(ROOT)}: job {job!r} sets no timeout-minutes, so a step "
            "stuck at an interactive prompt inherits the runner default and holds the "
            "concurrency group with it"
        )
        assert max(limits) <= BOUND_MINUTES, (
            f"{WORKFLOW.relative_to(ROOT)}: job {job!r} bounds itself at {max(limits)} min, "
            "against an artifact build that takes seconds"
        )
