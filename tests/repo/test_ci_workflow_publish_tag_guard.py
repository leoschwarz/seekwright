"""The release tag names the wheel it built, by test.

`publish.yml` has one trigger -- a push of a `v*` tag -- and on that path the release
name is the trigger ref: the release is `${GITHUB_REF_NAME}`, and the image is
`ghcr.io/OWNER/REPO:${GITHUB_REF_NAME}`. The wheel version comes from the other side
of the tree: `cut -d- -f2` of the built wheel filename, which is `[project] version` in
`pyproject.toml`. Nothing connects the two by construction, so a tag `v0.1.1` pushed at
a tree still reading `0.1.0` creates release `v0.1.1` carrying wheel
`seekwright-0.1.0` and image `:v0.1.1`, and the run reports success -- and it is that
run's colour a release gate reads as "the wheel and the image resolved". `ci.yml`
triggers on pushes to `main`, on pull requests and on dispatch, never on a tag, so no
other run of the lane catches the drift either.

The guard sits inside `build and upload the wheel`, after `VERSION` is derived and
before anything is uploaded or pushed. A guard in a later step of its own would run
once the release had already been created and the image pushed, and "a failed release
run is not a partial publish" (`docs/reference/publishing.md`) only holds while the
check comes first.

These checks read the workflow as text, the way
`tests/repo/test_ci_workflow_concurrency.py` and
`tests/repo/test_ci_workflow_publish_revision.py` read theirs: the runner consumes this
file, not Python. They fail if the tag path can reach the asset upload or the image
push without comparing the trigger ref to the built version.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "publish.yml"

WHEEL_STEP = "build and upload the wheel"
PUSH_STEP = "build and push the image"

# A step header, at the depth the runner reads the job at, and the run block under
# it. Line reads rather than a YAML parse: the claim is about what the shell does.
STEP_HEADER = re.compile(r"^      - name: (.+?)\s*$")
RUN_BLOCK = re.compile(r"^        run: \|\s*$")

# The release path's two version names, in the order the step produces them.
VERSION_DERIVED = re.compile(r"^\s*VERSION=\$\(printf.*cut -d- -f2\)\s*$")
REF_VS_VERSION = re.compile(r'GITHUB_REF_NAME\}?"?\s*(?:!=|=)\s*"?v\$\{?VERSION\b')
FAIL_REPORT = re.compile(r'^\s*echo "FAIL:')
EXIT_NONZERO = re.compile(r"^\s*exit [1-9]\d*\s*$")
UPLOADS = re.compile(r"^\s*(gh release create|uvx twine upload|uv publish)\b")
PUSHES = re.compile(r"^\s*docker push\b")

# The push step names its image by the tag that is being released, and the registry
# it goes to -- the counterpart of the unqualified tag the CI lane is pinned to.
GHCR_IMAGE = re.compile(r'IMAGE="ghcr\.io/\$\{GITHUB_REPOSITORY\}:\$\{GITHUB_REF_NAME\}"')


def step_body(name: str) -> list[str]:
    """The shell of one named step, dedented, in file order."""
    body, _ = step_lines(name)
    return body


def step_lines(name: str) -> tuple[list[str], int]:
    """The named step's header line index, and its shell dedented from there."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
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
        return body, index
    raise AssertionError(
        f"{WORKFLOW.relative_to(ROOT)}: no step named {name!r}, so the tag guard has "
        "nowhere to live and this check has nothing to read"
    )


def first(lines: list[str], pattern: re.Pattern[str], what: str) -> int:
    """The index of the first line matching `pattern`, or an assertion naming `what`."""
    hits = [i for i, line in enumerate(lines) if pattern.search(line)]
    assert hits, f"{WORKFLOW.relative_to(ROOT)}: step {WHEEL_STEP!r} holds no {what}"
    return hits[0]


def test_the_tag_is_compared_to_the_built_version_before_anything_uploads() -> None:
    """The wheel step compares the ref to the version it built, ahead of the upload."""
    body = step_body(WHEEL_STEP)
    derived = first(body, VERSION_DERIVED, "line deriving VERSION from the wheel name")
    compared = first(
        body, REF_VS_VERSION, "comparison of GITHUB_REF_NAME against v$VERSION"
    )
    uploaded = first(body, UPLOADS, "release asset upload")
    assert derived < compared, (
        "the tag check runs before the wheel version is derived, so it compares the "
        "ref to nothing"
    )
    assert compared < uploaded, (
        f"the tag check runs after the upload at line {uploaded + 1} of the step, so a "
        "mismatched tag still publishes the wheel and the run only fails afterwards: a "
        "failed release run has to publish nothing at all"
    )


def test_a_mismatched_tag_fails_the_run_and_prints_both_names() -> None:
    """The comparison exits non-zero, naming the ref, the version and the remedy."""
    body = step_body(WHEEL_STEP)
    compared = first(
        body, REF_VS_VERSION, "comparison of GITHUB_REF_NAME against v$VERSION"
    )
    uploaded = first(body, UPLOADS, "release asset upload")
    exits = [i for i in range(compared, uploaded) if EXIT_NONZERO.search(body[i])]
    assert exits, (
        "the tag/version comparison prints but never exits non-zero, so a release run "
        "publishes release v0.1.1 beside wheel seekwright-0.1.0 and reports success to "
        "the release gate"
    )
    report = body[compared + 1 : exits[0] + 1]
    assert any(FAIL_REPORT.search(line) for line in report), (
        "the tag mismatch is not reported with the FAIL: marker the collision guard in "
        "this step uses, so a release record quoting that guard's log lines cannot "
        "quote these"
    )
    printed = " ".join(report)
    assert "GITHUB_REF_NAME" in printed and "VERSION" in printed, (
        "the tag-mismatch report names neither the ref the run came in on nor the "
        "version it built, so its log cannot say which of the two is wrong"
    )


def test_the_guard_runs_in_the_step_before_the_image_is_pushed() -> None:
    """The step holding the comparison precedes the step that pushes the image."""
    _, wheel_at = step_lines(WHEEL_STEP)
    push_body, push_at = step_lines(PUSH_STEP)
    assert wheel_at < push_at, (
        "the step holding the tag/version check now runs after the image push, so a "
        f"mismatched tag still pushes {PUSH_STEP!r}'s image and the run only fails "
        "afterwards"
    )
    assert any(PUSHES.search(line) for line in push_body), (
        f"{WORKFLOW.relative_to(ROOT)}: step {PUSH_STEP!r} no longer pushes an image, so "
        "there is no later write to order the guard against"
    )
    assert any(GHCR_IMAGE.search(line) for line in push_body), (
        f"{WORKFLOW.relative_to(ROOT)}: step {PUSH_STEP!r} no longer names its image by "
        "ghcr.io plus the tag being released, so a mismatched tag would push some other "
        "name and the guard would have nothing to reject"
    )
