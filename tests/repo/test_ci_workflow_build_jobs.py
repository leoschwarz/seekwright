"""Both artifacts a release ships are built by the CI lane, by test.

`.github/workflows/ci.yml` gates a pull request and, on a push to `main` or a
dispatch, builds the two artifacts `publish.yml` releases: a `container` job that
builds this `Containerfile` under BuildKit and runs `--help` inside the result, and
a `wheel` job that builds the wheel and smokes the installed entry point outside the
checkout. Without those jobs the recipe rots behind a green check, because the only
other build of either artifact in the tree sits in `publish.yml` beside its release
writes -- `gh release create` and `docker push` -- so measuring an artifact would
cost publishing it. The two CI jobs therefore may not write: the image tag they
build is unqualified, so no registry name is reachable from that file, and the only
publishes in the tree stay the two `publish.yml` steps that are the release.
`--check` is recorded rather than asserted -- CI holds no provider keys -- so a
future edit that turns it into a gate fails here too.

These checks read the workflow as text, the way
`tests/repo/test_ci_workflow_concurrency.py` and the two `publish` guards read
theirs: the runner consumes this file, not Python. They fail if an artifact job
disappears, grows a write, or stops being the thing the release checklist credits.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
PUBLISH = ROOT / ".github" / "workflows" / "publish.yml"
PUBLISHING = ROOT / "docs" / "reference" / "publishing.md"
CONTAINER_DOC = ROOT / "docs" / "reference" / "container.md"

CONTAINER_JOB = "container"
WHEEL_JOB = "wheel"
BUILD_STEP = "build the image"
SMOKE_STEP = "smoke the image"
WHEEL_STEP = "build the wheel and smoke the installed entry point"

# Job, step and run-block headers, each at the depth the runner reads the file at.
JOBS_KEY = re.compile(r"^jobs:\s*$")
JOB_HEADER = re.compile(r"^  ([a-z][a-z0-9_-]*):\s*$")
STEP_HEADER = re.compile(r"^      - name: (.+?)\s*$")
RUN_BLOCK = re.compile(r"^        run: \|\s*$")

# The lane a job runs on: an artifact build costs a merge check nothing to skip.
PR_SKIPPED = re.compile(r"^    if: \$\{\{ github\.event_name != 'pull_request' \}\}\s*$")

# A release write, in any form, anywhere in the file -- `^` has to mean every line,
# or this finds one candidate at the top of the file and nothing else.
WRITES = re.compile(
    r"^\s*(docker push|docker login|docker tag|docker pull|gh release create|uvx twine upload|uv publish)\b",
    re.MULTILINE,
)

# The image half: BuildKit for `RUN --mount=type=cache`, and an unqualified tag.
BUILD = re.compile(r"^DOCKER_BUILDKIT=1 docker build --file Containerfile --tag ([^ ]+) \.\s*$")
HELP_RUN = re.compile(r"^docker run --rm seekwright:ci --help\b")
EXTRACTOR_IMPORT = re.compile(r"import seekwright\.extractors\.trafilatura")
CHECK_RUN = re.compile(r"^docker run --rm seekwright:ci --check\s*$")
CHECK_RECORDED = re.compile(r'^echo "image --check exit code: \$\?"')
OFF = re.compile(r"^set \+e\s*$")
NO_ASSERT = re.compile(r"\|\| true|\btrue\s*$")
ON = re.compile(r"^set -e\s*$")

# The wheel half: build it, install the built file, run it from outside the tree.
UV_BUILD = re.compile(r"^uv build\s*$")
BUILT_REPORT = re.compile(r'^echo "built \$WHEEL sha256=\$SHA"')
INSTALL = re.compile(r'^uv pip install --python /tmp/wheel-smoke/bin/python "dist/\$WHEEL"')
LEFT_TREE = re.compile(r"^cd /tmp\s*$")
INSTALLED_RUN = re.compile(r"^/tmp/wheel-smoke/bin/seekwright --help\b")


def job_lines(name: str) -> list[str]:
    """The raw lines of one job, from its header to the next job header."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    jobs_at = [i for i, line in enumerate(lines) if JOBS_KEY.match(line)]
    assert jobs_at, f"{WORKFLOW.relative_to(ROOT)}: no jobs: key, so nothing here runs"
    starts: list[tuple[int, str]] = []
    for index in range(jobs_at[0] + 1, len(lines)):
        header = JOB_HEADER.match(lines[index])
        if header is not None:
            starts.append((index, header.group(1)))
    found = [k for k, (_, job) in enumerate(starts) if job == name]
    assert found, (
        f"{WORKFLOW.relative_to(ROOT)}: no job named {name!r} -- the lane holds "
        f"{[job for _, job in starts]}, so the artifact this job built is no longer "
        "built at all"
    )
    index = found[0]
    stop = starts[index + 1][0] if index + 1 < len(starts) else len(lines)
    return lines[starts[index][0] + 1 : stop]


def step_body(job: str, name: str) -> list[str]:
    """The shell of one named step of one job, dedented, continuations joined."""
    lines = job_lines(job)
    for index, line in enumerate(lines):
        header = STEP_HEADER.match(line)
        if header is None or header.group(1) != name:
            continue
        following = lines[index + 1 :]
        block = [i for i, entry in enumerate(following) if RUN_BLOCK.match(entry)]
        assert block, f"{WORKFLOW.relative_to(ROOT)}: step {name!r} has no run: block"
        body: list[str] = []
        for entry in following[block[0] + 1 :]:
            if entry.strip() and not entry.startswith("          "):
                break
            body.append(entry[10:])
        joined: list[str] = []
        for entry in body:
            if joined and joined[-1].endswith("\\"):
                joined[-1] = joined[-1][:-1] + " " + entry.strip()
            else:
                joined.append(entry)
        return joined
    raise AssertionError(
        f"{WORKFLOW.relative_to(ROOT)}: job {job!r} has no step named {name!r}, so the "
        "artifact that step exists to build is no longer built or no longer smoked"
    )


def first(lines: list[str], pattern: re.Pattern[str], what: str) -> int:
    """The index of the first line matching `pattern`, or an assertion naming `what`."""
    hits = [i for i, line in enumerate(lines) if pattern.search(line)]
    assert hits, f"{WORKFLOW.relative_to(ROOT)}: holds no {what}"
    return hits[0]


# The two checklist halves and the job that measures each; `\s+` so a re-wrap of the
# bullet cannot break the pin.
WHEEL_JOB_NAMED = re.compile(r"`wheel` job of\s+`\.github/workflows/ci\.yml`")
IMAGE_JOB_NAMED = re.compile(r"`container` job of\s+`\.github/workflows/ci\.yml`")


def checklist_item(number: int) -> str:
    """One `- **Item N, ...**` bullet of the release checklist."""
    text = PUBLISHING.read_text(encoding="utf-8")
    marker = f"- **Item {number},"
    assert marker in text, f"{PUBLISHING.relative_to(ROOT)}: no checklist item {number}"
    rest = text[text.index(marker) + len(marker) :]
    ends = [m.start() for m in re.finditer(r"^(?:- \*\*Item |#{1,3} )", rest, re.MULTILINE)]
    return rest[: ends[0]] if ends else rest


def test_the_ci_lane_builds_both_release_artifacts() -> None:
    """The gate file holds a `container` job and a `wheel` job, each building one artifact."""
    built = step_body(CONTAINER_JOB, BUILD_STEP)
    command = first(built, BUILD, "a DOCKER_BUILDKIT=1 docker build of the Containerfile")
    tag = BUILD.search(built[command])
    assert tag is not None and "/" not in tag.group(1), (
        f"{WORKFLOW.relative_to(ROOT)}: the CI image tag {built[command]!r} names a "
        "registry, so the lane that is forbidden to publish is one edit from pushing"
    )
    wheel = step_body(WHEEL_JOB, WHEEL_STEP)
    first(wheel, UV_BUILD, "an uv build of the wheel")


def test_the_build_jobs_run_where_their_cost_is_free() -> None:
    """Both build jobs skip a pull request; the gate job does not."""
    for job in (CONTAINER_JOB, WHEEL_JOB):
        assert any(PR_SKIPPED.match(line) for line in job_lines(job)), (
            f"{WORKFLOW.relative_to(ROOT)}: job {job!r} runs on every pull request, so "
            "each merge check pays for an artifact build it cannot use"
        )
    assert not any(PR_SKIPPED.match(line) for line in job_lines("check")), (
        f"{WORKFLOW.relative_to(ROOT)}: the gate job now skips pull requests, which is "
        "the read every merge gate here depends on"
    )


def test_the_ci_lane_writes_nothing_and_publish_still_does() -> None:
    """No push, login, tag or upload in `ci.yml`; the release lane keeps both."""
    writes = WRITES.findall(WORKFLOW.read_text(encoding="utf-8"))
    assert not writes, (
        f"{WORKFLOW.relative_to(ROOT)}: the check lane contains a release write "
        f"({', '.join(sorted(set(writes)))}), and measuring an artifact must not cost publishing it"
    )
    published = WRITES.findall(PUBLISH.read_text(encoding="utf-8"))
    assert "docker push" in published and "gh release create" in published, (
        f"{PUBLISH.relative_to(ROOT)}: no longer holds both the image push and the "
        "release asset upload, so the release has no publish step left to guard"
    )


def test_the_image_build_asks_for_buildkit() -> None:
    """The build command names BuildKit instead of inheriting the runner's builder."""
    built = step_body(CONTAINER_JOB, BUILD_STEP)
    first(built, BUILD, "a DOCKER_BUILDKIT=1 docker build of the Containerfile")


def test_the_image_help_is_asserted_and_its_check_exit_code_recorded() -> None:
    """`--help` gates the run; `--check` is printed as an exit code, as publish's smoke does."""
    smoke = step_body(CONTAINER_JOB, SMOKE_STEP)
    helped = first(smoke, HELP_RUN, "a docker run of --help against the built image")
    first(smoke, EXTRACTOR_IMPORT, "the default extractor import inside the image")
    off = first(smoke, OFF, "the set +e that opens the recorded half")
    assert helped < off and not NO_ASSERT.search(smoke[helped]), (
        f"{WORKFLOW.relative_to(ROOT)}: the image --help smoke is no longer asserted, so "
        "an image that cannot start at all is still reported as built"
    )
    checked = first(smoke, CHECK_RUN, "a docker run of --check against the built image")
    reported = first(smoke, CHECK_RECORDED, "the image --check exit code report")
    assert off < checked < reported, (
        "the image --check run is no longer wrapped in `set +e` and reported as an exit "
        "code, so CI either gates on a command that needs provider keys or drops the "
        "figure the release record quotes"
    )
    on = first(smoke[checked:], ON, "the set -e that closes the recorded half")
    assert not [line for line in smoke[checked : checked + on] if re.search(r"\bexit [1-9]", line)], (
        "the recorded --check half now exits, which turns a figure into a gate"
    )


def test_the_wheel_smoke_installs_the_built_file_outside_the_checkout() -> None:
    """The wheel is built, reported, installed into a clean venv, then run outside the tree."""
    wheel = step_body(WHEEL_JOB, WHEEL_STEP)
    built = first(wheel, UV_BUILD, "the uv build")
    reported = first(wheel, BUILT_REPORT, "the built <wheel> sha256= report line")
    installed = first(wheel, INSTALL, "the install of the built wheel into /tmp/wheel-smoke")
    left = first(wheel, LEFT_TREE, "the cd /tmp that leaves the checkout")
    smoked = first(wheel, INSTALLED_RUN, "the installed seekwright --help run")
    assert built < reported < installed < left < smoked, (
        "the wheel step no longer builds, reports, installs, leaves the checkout and "
        "then smokes, so the thing CI runs is the source tree rather than the artifact"
    )


def test_the_docs_credit_the_lane_that_runs() -> None:
    """The checklist names the jobs that build the artifacts at `main`."""
    assert "minus the image build" not in WORKFLOW.read_text(encoding="utf-8"), (
        f"{WORKFLOW.relative_to(ROOT)}: the comment still says this file skips the image "
        "build, which is the claim this test retires"
    )
    assert WHEEL_JOB_NAMED.search(checklist_item(4)), (
        f"{PUBLISHING.relative_to(ROOT)}: item 4 no longer names the job that builds and "
        "installs the wheel at main, so it still points a reader at a hand build"
    )
    assert IMAGE_JOB_NAMED.search(checklist_item(6)), (
        f"{PUBLISHING.relative_to(ROOT)}: item 6 no longer names the job that builds the "
        "image at main, so the image half is back to being measured only by a release write"
    )
    assert ".github/workflows" in CONTAINER_DOC.read_text(encoding="utf-8"), (
        f"{CONTAINER_DOC.relative_to(ROOT)}: no longer credits the workflow that builds "
        "the image at main, so a reader is sent to a hand build for the only image CI checks"
    )
