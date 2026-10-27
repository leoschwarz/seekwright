"""The release tag has to name main's head, by test.

On the release path the commit `publish.yml` builds is whatever commit the tag names,
and nothing else in that file can see `main`. A tag cut from an old commit therefore
builds, publishes and reports success on a tree `ci.yml` never ran on: that workflow
triggers on pushes to `main`, on pull requests and on dispatch, never on a tag. Every
instrument the release run already carries passes on a stale tree, because each one is
self-consistent with it -- the tag-versus-version guard compares the tag *name* to the
wheel version declared by that same tree, and the revision read-back compares the image
label to `$GITHUB_SHA` of the same run. A stale release is only visible from outside the
run, which is the one place nobody is looking.

So the guard fetches `main` at depth 1 from the checkout's own origin and exits
non-zero unless its head equals `$GITHUB_SHA`, the commit the pushed tag names. It sits
ahead of `build and upload the wheel`, so a rejected release publishes nothing, and a
hotfix release re-cuts the tag after the fix merges rather than moving a tag onto an
unverified commit.

These checks read the workflow as text, the way
`tests/repo/test_ci_workflow_publish_tag_guard.py`,
`tests/repo/test_ci_workflow_publish_revision.py` and
`tests/repo/test_ci_workflow_concurrency.py` read it: the runner consumes this file, not
Python. They fail if the check is dropped, moves after the upload or the push, stops
exiting non-zero, stops naming `main`, or acquires a branch that skips it. The mismatch
itself is pinned here rather than by a live `v*` tag push: a tag push is a real publish,
so both sides of the comparison are replayed against a scratch clone instead -- see the
pull request's review evidence.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "publish.yml"
PUBLISHING = ROOT / "docs" / "reference" / "publishing.md"

GUARD_STEP = "the tag must name the commit main names"
WHEEL_STEP = "build and upload the wheel"
PUSH_STEP = "build and push the image"

# A step header, at the depth the runner reads the job at, and the run block under
# it -- the same line reads tests/repo/test_ci_workflow_publish_tag_guard.py makes.
STEP_HEADER = re.compile(r"^      - name: (.+?)\s*$")
RUN_BLOCK = re.compile(r"^        run: \|\s*$")

# The guard, in the order its step produces the two names.
FETCH_MAIN = re.compile(r"\bgit fetch\b[^\n]*\borigin main\b")
MAIN_READ = re.compile(r"^\s*MAIN=\$\(git rev-parse FETCH_HEAD\)\s*$")
MISMATCH_TEST = re.compile(r'\[\s*"?\$\{?MAIN\}?"?\s*!=\s*"\$\{?GITHUB_SHA\}?"?\s*\]')
FAIL_REPORT = re.compile(r'^\s*echo "FAIL:')
EXIT_NONZERO = re.compile(r"^\s*exit [1-9]\d*\s*$")
OK_REPORT = re.compile(r'^\s*echo "TAG NAMES MAIN HEAD: [^"]*\$\{GITHUB_REF_NAME\}[^"]*\$\{GITHUB_SHA\}[^"]*"')
ECHO = re.compile(r"^\s*echo ")

# Which shell condition, if any, one line of the step runs inside: the guard belongs
# to every release run, so the comparison itself must sit at the top level.
IF_TEST = re.compile(r"^\s*(?:if|elif)\s+(.*?)\s*;\s*then\s*$")
ELSE_LINE = re.compile(r"^\s*else\s*$")
FI_LINE = re.compile(r"^\s*fi\b")

# The one condition the step's failure is allowed to sit inside.
MISMATCH_BRANCH = '[ "$MAIN" != "$GITHUB_SHA" ]'


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
        f"{WORKFLOW.relative_to(ROOT)}: no step named {name!r}, so nothing compares "
        "the tag's commit to main's head and a stale tag publishes unchecked"
    )


def first(lines: list[str], pattern: re.Pattern[str], what: str) -> int:
    """The index of the first line matching `pattern`, or an assertion naming `what`."""
    hits = [i for i, line in enumerate(lines) if pattern.search(line)]
    assert hits, f"{WORKFLOW.relative_to(ROOT)}: step {GUARD_STEP!r} holds no {what}"
    return hits[0]


def conditions_at(lines: list[str], index: int) -> list[str]:
    """The `if`/`elif`/`else` tests still in force at one line of the step."""
    stack: list[str] = []
    for line in lines[: index + 1]:
        opened = IF_TEST.match(line)
        if opened:
            if re.match(r"^\s*elif\b", line) and stack:
                stack.pop()
            stack.append(opened.group(1))
        elif ELSE_LINE.match(line):
            if stack:
                stack[-1] = f"not ({stack[-1]})"
        elif FI_LINE.match(line) and stack:
            stack.pop()
    return stack


def flat(text: str) -> str:
    """The text with its prose wrapping collapsed, for a docs claim search."""
    return re.sub(r"\s+", " ", text)


def section(path: Path, heading: str) -> str:
    """One `##` section of a docs page, up to the next heading of any level."""
    text = path.read_text(encoding="utf-8")
    marker = f"## {heading}"
    assert marker in text, f"{path.relative_to(ROOT)}: no section {heading!r}"
    start = text.index(marker) + len(marker)
    rest = text[start:]
    ends = [match.start() for match in re.finditer(r"^#{1,3} ", rest, re.MULTILINE)]
    return rest[: ends[0]] if ends else rest


def test_the_guard_runs_before_anything_uploads_or_pushes() -> None:
    """The step exists, and precedes the wheel step and the image push."""
    _, guard_at = step_lines(GUARD_STEP)
    _, wheel_at = step_lines(WHEEL_STEP)
    _, push_at = step_lines(PUSH_STEP)
    assert guard_at < wheel_at, (
        "the tag/main check now runs after the wheel step, so a release run that "
        "rejects the tag has already created the release and uploaded the wheel: a "
        "failed release run has to publish nothing at all"
    )
    assert guard_at < push_at, (
        f"the tag/main check now runs after {PUSH_STEP!r}, so a rejected release still "
        "pushes an image under the release name"
    )


def test_the_guard_fetches_main_head_from_the_run_s_own_origin() -> None:
    """`main` is fetched and read, so the comparison has a head to compare to."""
    body, _ = step_lines(GUARD_STEP)
    fetched = first(body, FETCH_MAIN, "fetch of main from origin")
    read = first(body, MAIN_READ, "MAIN=$(git rev-parse FETCH_HEAD)")
    compared = first(
        body, MISMATCH_TEST, "comparison of MAIN against GITHUB_SHA"
    )
    assert fetched < read < compared, (
        "the guard compares MAIN before it fetches and reads main, so it compares an "
        "unset variable to the run sha and proves nothing"
    )
    fetches = [line for line in body if re.search(r"\bgit fetch\b", line)]
    assert len(fetches) == 1 and re.search(r"\borigin main\b", fetches[0]), (
        "the guard's fetch is no longer exactly one fetch of `main` from origin, so it "
        "can re-read this run's own ref and compare the tag to itself"
    )


def test_a_tag_that_does_not_name_main_head_fails_the_run_and_names_both_shas() -> None:
    """The comparison exits non-zero, naming both commits and the remedy."""
    body, _ = step_lines(GUARD_STEP)
    compared = first(body, MISMATCH_TEST, "comparison of MAIN against GITHUB_SHA")
    after = body[compared + 1 :]
    exits = [i for i, line in enumerate(after) if EXIT_NONZERO.search(line)]
    assert exits, (
        "the tag/main comparison prints and the run carries on, so a tag at an old "
        "commit publishes a tree CI never ran on and reports the green a release gate "
        "reads as 'the wheel and the image resolved'"
    )
    printed = [line for line in after[: exits[0]] if line.strip()]
    report = " ".join(printed)
    unmarked = [line for line in printed if not FAIL_REPORT.search(line)]
    assert not unmarked, (
        "the tag/main mismatch report has a line without the FAIL: marker the other "
        "guards in this workflow use, so a release record quoting those cannot quote "
        "these"
    )
    assert "MAIN" in report and "GITHUB_SHA" in report, (
        "the tag/main mismatch report names neither main's head nor the commit the tag "
        "names, so its log cannot say which of the two moved"
    )
    assert ("move" in report or "re-cut" in report) and "re-run" in report, (
        "the tag/main mismatch report states no remedy, so the release procedure has "
        "to be reconstructed from the failure"
    )


def test_the_guard_runs_on_every_release_run_with_no_branch_that_skips_it() -> None:
    """One trigger, one path: the comparison is unconditional, and only it fails."""
    body, _ = step_lines(GUARD_STEP)
    compared = first(body, MISMATCH_TEST, "comparison of MAIN against GITHUB_SHA")
    assert not conditions_at(body, compared - 1), (
        "the tag/main comparison now sits inside a shell condition, so some release run "
        "reaches it and some does not -- with one trigger there is no path left to "
        "scope it to"
    )
    failing = [i for i, line in enumerate(body) if EXIT_NONZERO.search(line)]
    assert failing, "the guard has no failing branch at all, so it checks nothing"
    for index in failing:
        assert conditions_at(body, index) == [MISMATCH_BRANCH], (
            "the tag/main step exits non-zero on a line the mismatch branch does not "
            "reach, which fails a run whose tag does name main's head"
        )


def test_a_tag_naming_main_head_prints_the_evidence_line_the_release_record_quotes() -> None:
    """Success prints one line, naming the tag and the commit it names."""
    body, _ = step_lines(GUARD_STEP)
    reported = [i for i, line in enumerate(body) if OK_REPORT.search(line)]
    assert len(reported) == 1, (
        f"{WORKFLOW.relative_to(ROOT)}: step {GUARD_STEP!r} prints no single "
        "TAG NAMES MAIN HEAD line, so the release record has nothing to quote beside "
        "WHEEL INSTALL OK and IMAGE REVISION OK"
    )
    compared = first(body, MISMATCH_TEST, "comparison of MAIN against GITHUB_SHA")
    assert compared < reported[0], (
        "TAG NAMES MAIN HEAD is printed before the comparison, so the release record "
        "quotes an evidence line the run then contradicts"
    )
    echoed = [i for i, line in enumerate(body) if ECHO.match(line)]
    assert len(echoed) == 3, (
        "this step prints something other than the two FAIL lines and the one evidence "
        "line, so the release record's log no longer has exactly one line to quote on "
        "success"
    )
    assert OK_REPORT.search(body[reported[0]])


def test_the_docs_move_with_the_mechanism() -> None:
    """The tag rule, the pre-release note and the evidence list all carry the check."""
    tag_rule = flat(section(PUBLISHING, "One trigger, one version source"))
    assert GUARD_STEP in tag_rule and "main" in tag_rule, (
        f"{PUBLISHING.relative_to(ROOT)}: the section that states the tag rule no "
        f"longer names {GUARD_STEP!r}, so the procedure a release follows and the "
        "workflow that enforces it drift apart"
    )
    before = flat(section(PUBLISHING, "What has to happen before the release run"))
    assert GUARD_STEP in before, (
        f"{PUBLISHING.relative_to(ROOT)}: the section recording what has to be true "
        f"before a tag is pushed no longer names {GUARD_STEP!r}, so it still reads as "
        "though a push at any tag would publish"
    )
    evidence = flat(section(PUBLISHING, "What a publish run has to show"))
    assert "TAG NAMES MAIN HEAD" in evidence, (
        f"{PUBLISHING.relative_to(ROOT)}: the evidence list does not name the TAG "
        "NAMES MAIN HEAD line, so a release record quoting that list still carries no "
        "statement that the tag named main's head"
    )
