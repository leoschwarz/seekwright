"""Every job of every workflow declares timeout-minutes, by test.

An unbounded job inherits the runner default, and a step stuck at an interactive
prompt -- uv's "replace the existing virtual environment?" question is the one this
tree has actually met -- reaches that default in hours, not seconds. While such a
job runs it holds its `concurrency:` group, so every run queued behind it, including
the merge check a reviewer is waiting on, waits with it. Both workflows bound every
job; this module is what keeps a bound from being dropped by the next workflow edit.

A bound padded far past the work the job does fails the same way: it never fires, so
the lane stays held. Each job therefore has a ceiling as well as a bound -- the gate
job, the image build and the wheel build are all minutes of work and bounded at 10;
a release run builds, uploads, installs and pushes, and is bounded at 30.

Like `tests/repo/test_ci_workflow_concurrency.py`,
`tests/repo/test_ci_workflow_build_jobs.py` and
`tests/repo/test_ci_workflow_wheel_venv_clear.py`, this reads the workflow files as
text: the runner consumes them, not Python, so the only way a job lands unbounded is
that a test looks for it.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GITHUB_CI = ROOT / ".github" / "workflows" / "ci.yml"
PUBLISH_CI = ROOT / ".github" / "workflows" / "publish.yml"
WORKFLOWS = (GITHUB_CI, PUBLISH_CI)

# A workflow file is read at column 0: `jobs:` opens the section, and the next
# column-0 key closes it, so the `push:` and `pull_request:` keys of an `on:` block
# are never mistaken for jobs.
JOBS_KEY = re.compile(r"^jobs:\s*$")
JOB_HEADER = re.compile(r"^  ([a-z][a-z0-9_-]*):\s*$")
# The bound a job declares for itself, at the job key's own nesting level.
TIMEOUT = re.compile(r"^    timeout-minutes: (\d+)\s*$")

# What each job may claim: a bound padded past the work the job does never fires, so
# it does not release the lane.
MAX_MINUTES = {"check": 10, "container": 10, "wheel": 10, "publish": 30}
DEFAULT_MAX_MINUTES = 30


def timeouts_of(block: list[str]) -> list[int]:
    """Every timeout-minutes a job block declares at its own level."""
    limits: list[int] = []
    for line in block:
        declared = TIMEOUT.match(line)
        if declared is not None:
            limits.append(int(declared.group(1)))
    return limits


def jobs_of(path: Path) -> dict[str, list[str]]:
    """Every job of one workflow, mapped to the lines under its header."""
    lines = path.read_text(encoding="utf-8").splitlines()
    opening = [i for i, line in enumerate(lines) if JOBS_KEY.match(line)]
    assert opening, f"{path.relative_to(ROOT)}: has no column-0 `jobs:` key"
    jobs: dict[str, list[str]] = {}
    current: str | None = None
    for line in lines[opening[0] + 1 :]:
        if line.startswith("#") or not line or line[0].isspace():
            header = JOB_HEADER.match(line)
            if header is not None:
                name = header.group(1)
                jobs[name] = []
                current = name
            elif current is not None:
                jobs[current].append(line)
            continue
        break
    assert jobs, f"{path.relative_to(ROOT)}: its `jobs:` section holds no job"
    return jobs


def test_every_job_of_every_workflow_declares_a_timeout() -> None:
    """No job is left to inherit the runner default."""
    for workflow in WORKFLOWS:
        jobs = jobs_of(workflow)
        for job, block in jobs.items():
            limits = timeouts_of(block)
            assert limits, (
                f"{workflow.relative_to(ROOT)}: job {job!r} of {sorted(jobs)} sets no "
                "timeout-minutes, so a step stuck at an interactive prompt inherits the "
                "runner default and holds the concurrency group for every run queued "
                "behind it"
            )


def test_no_bound_is_padded_past_its_work() -> None:
    """A bound that can never fire leaves the lane held as surely as no bound."""
    for workflow in WORKFLOWS:
        for job, block in jobs_of(workflow).items():
            ceiling = MAX_MINUTES.get(job, DEFAULT_MAX_MINUTES)
            limits = timeouts_of(block)
            assert limits, (
                f"{workflow.relative_to(ROOT)}: job {job!r} declares no timeout-minutes"
            )
            declared = max(limits)
            assert declared <= ceiling, (
                f"{workflow.relative_to(ROOT)}: job {job!r} bounds itself at {declared} min, "
                f"above the {ceiling} min of work its steps do"
            )
