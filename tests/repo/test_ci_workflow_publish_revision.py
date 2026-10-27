"""The published image names the commit it was built from.

On the release path the image tag is the git tag -- `ghcr.io/OWNER/REPO:v0.1.0` --
which embeds no sha. An image whose OCI labels carry no
`org.opencontainers.image.revision` therefore cannot answer "which commit is the
image a user pulls built from" out of the artifact: `docker image inspect` shows no
commit, and the documented verification path -- `docker pull`, then `--check` -- never
reads one. The release record's own evidence line, `IMAGE SMOKE OK: $IMAGE`, would
then name a tag and no commit.

Three files carry the mechanism, and each can lose it on its own:

* `Containerfile` declares `ARG SEEKWRIGHT_REVISION` inside the final stage -- an
  `ARG` does not cross a `FROM` boundary, and the `LABEL` that reads it lives
  below the second `FROM` -- and adds the revision label to that block. A hand
  build that passes nothing still builds; its label is then empty.
* `build and push the image` passes the run sha with `--build-arg`. `actions/checkout`
  checks out `$GITHUB_SHA`, the commit the pushed tag names, so that is the sha the
  build context came from.
* `smoke the published image` reads the label back off the image it pulled out of the
  registry -- not off the local build -- exits non-zero unless it equals the run sha,
  and prints `IMAGE REVISION OK: <image> built from <sha>` for the release record.

These checks read those files as text, the way
`tests/repo/test_ci_workflow_publish_tag_guard.py` and
`tests/repo/test_ci_workflow_concurrency.py` read the workflow: the runner and
`docker build` consume the files, not Python. They fail when the label, the build arg
or the read-back check goes away.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "publish.yml"
CONTAINERFILE = ROOT / "Containerfile"
PUBLISHING = ROOT / "docs" / "reference" / "publishing.md"
CONTAINER_DOC = ROOT / "docs" / "reference" / "container.md"

BUILD_STEP = "build and push the image"
SMOKE_STEP = "smoke the published image"

# A step header, at the depth the runner reads the job at, and the run block under
# it -- the same line reads tests/repo/test_ci_workflow_publish_tag_guard.py makes.
STEP_HEADER = re.compile(r"^      - name: (.+?)\s*$")
RUN_BLOCK = re.compile(r"^        run: \|\s*$")

# The Containerfile: the ARG declaration and the label that consumes it.
FROM_LINE = re.compile(r"^FROM\b", re.MULTILINE)
ARG_DECL = re.compile(r"^ARG\s+SEEKWRIGHT_REVISION\s*$", re.MULTILINE)
LABEL_REVISION = re.compile(
    r'^\s*org\.opencontainers\.image\.revision="\$\{SEEKWRIGHT_REVISION\}"', re.MULTILINE
)

# The build step: one `docker build` command, which has to carry the build arg.
DOCKER_BUILD = re.compile(r"\bdocker build\b")
BUILD_ARG = re.compile(r'--build-arg\s+SEEKWRIGHT_REVISION="\$GITHUB_SHA"')
DOCKER_PUSH = re.compile(r"^\s*docker push\b")

# The smoke step: pull, read back, compare, then fail or report.
DOCKER_PULL = re.compile(r'^\s*docker pull\s+"\$IMAGE"')
READ_BACK = re.compile(r"docker image inspect\b")
READS_LABEL = re.compile(r"Config\.Labels[^\n]*org\.opencontainers\.image\.revision")
MISMATCH_TEST = re.compile(r'\[\s*"?\$\{?REVISION\}?"?\s*!=\s*"\$GITHUB_SHA"\s*\]')
FAIL_REPORT = re.compile(r'echo "FAIL:')
EXIT_NONZERO = re.compile(r"^\s*exit [1-9]\d*\s*$")
OK_REPORT = re.compile(r'^\s*echo "IMAGE REVISION OK: [^"]*\$IMAGE[^"]*built from \$GITHUB_SHA')
SMOKE_OK = re.compile(r'^\s*echo "IMAGE SMOKE OK:')


def step_body(name: str) -> list[str]:
    """The shell of one named step, dedented, with line continuations joined.

    Joining `\\`-continuations keeps a command split over source lines in one
    entry, so an ordering claim is about the command rather than about one of its
    lines.
    """
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
        joined: list[str] = []
        for entry in body:
            if joined and joined[-1].endswith("\\"):
                joined[-1] = joined[-1][:-1] + " " + entry.strip()
            else:
                joined.append(entry)
        return joined
    raise AssertionError(
        f"{WORKFLOW.relative_to(ROOT)}: no step named {name!r}, so the revision label "
        "has nowhere to be passed and nowhere to be read back"
    )


def final_stage() -> str:
    """The Containerfile's last stage, where an ARG can reach the LABEL.

    An ARG declared before a FROM is not visible in the next stage, so the
    declaration has to sit in the same stage as the label that reads it.
    """
    text = CONTAINERFILE.read_text(encoding="utf-8")
    starts = [match.start() for match in FROM_LINE.finditer(text)]
    assert starts, f"{CONTAINERFILE.relative_to(ROOT)}: no FROM line, no build stage"
    return text[starts[-1] :]


def first(lines: list[str], pattern: re.Pattern[str], what: str) -> int:
    """The index of the first line matching `pattern`, or an assertion naming `what`."""
    hits = [i for i, line in enumerate(lines) if pattern.search(line)]
    assert hits, f"{WORKFLOW.relative_to(ROOT)}: step {SMOKE_STEP!r} holds no {what}"
    return hits[0]


def section(path: Path, heading: str) -> str:
    """One `##` section of a docs page, up to the next heading of any level."""
    text = path.read_text(encoding="utf-8")
    marker = f"## {heading}"
    assert marker in text, f"{path.relative_to(ROOT)}: no section {heading!r}"
    start = text.index(marker) + len(marker)
    rest = text[start:]
    ends = [match.start() for match in re.finditer(r"^#{1,3} ", rest, re.MULTILINE)]
    return rest[: ends[0]] if ends else rest


def test_the_image_labels_the_commit_it_was_built_from() -> None:
    """The final stage declares the ARG, and its LABEL block reads it."""
    stage = final_stage()
    declared = ARG_DECL.search(stage)
    assert declared, (
        f"{CONTAINERFILE.relative_to(ROOT)}: the final stage declares no ARG "
        "SEEKWRIGHT_REVISION, so the revision label in that stage can never be given "
        "a value by `docker build --build-arg`"
    )
    labelled = LABEL_REVISION.search(stage)
    assert labelled, (
        f"{CONTAINERFILE.relative_to(ROOT)}: no org.opencontainers.image.revision "
        "label, so the pushed image names no commit and only a run log or an "
        "attestation says what a user pulled"
    )
    assert declared.start() < labelled.start(), (
        "ARG SEEKWRIGHT_REVISION is declared after the revision label that reads it, "
        "so the label expands to an empty string"
    )


def test_the_build_step_hands_the_run_sha_to_the_image() -> None:
    """The push step builds with the run's own commit as a build arg."""
    body = step_body(BUILD_STEP)
    built = [i for i, line in enumerate(body) if DOCKER_BUILD.search(line)]
    assert built, f"{WORKFLOW.relative_to(ROOT)}: step {BUILD_STEP!r} runs no docker build"
    passed = [i for i, line in enumerate(body) if BUILD_ARG.search(line)]
    assert passed, (
        f"{WORKFLOW.relative_to(ROOT)}: step {BUILD_STEP!r} passes no --build-arg "
        'SEEKWRIGHT_REVISION="$GITHUB_SHA", so the label the Containerfile declares is '
        "built empty and the published image still names no commit"
    )
    assert body[built[0]] == body[passed[0]], (
        "the --build-arg SEEKWRIGHT_REVISION is no longer part of the docker build "
        "command, so docker build never sees it"
    )
    pushed = [i for i, line in enumerate(body) if DOCKER_PUSH.search(line)]
    assert pushed and passed[0] < pushed[0], (
        "the image is pushed before --build-arg SEEKWRIGHT_REVISION reaches the build, "
        "so the pushed artifact carries no revision"
    )


def test_the_revision_is_read_back_off_the_pulled_image() -> None:
    """The smoke step inspects the artifact from the registry, not the local build."""
    body = step_body(SMOKE_STEP)
    pulled = first(body, DOCKER_PULL, "pull of the published image")
    read = [
        i
        for i, line in enumerate(body)
        if READ_BACK.search(line) and READS_LABEL.search(line)
    ]
    assert read, (
        f"{WORKFLOW.relative_to(ROOT)}: step {SMOKE_STEP!r} never reads the revision "
        "label off the image, so a publish run reports success whatever the artifact "
        "carries"
    )
    assert pulled < read[0], (
        "the revision label is inspected before `docker pull`, so the check reads the "
        "local build rather than the artifact the registry hands out to a user"
    )
    assert "$IMAGE" in body[read[0]], (
        "the revision read is not applied to $IMAGE, the tag this run pushed and "
        "pulled back"
    )


def test_a_revision_mismatch_fails_the_run_and_names_both_commits() -> None:
    """The read-back comparison exits non-zero and says which commit is which."""
    body = step_body(SMOKE_STEP)
    read = first(body, READ_BACK, "docker image inspect of the pulled image")
    compared = [i for i, line in enumerate(body) if MISMATCH_TEST.search(line)]
    assert compared, (
        f"{WORKFLOW.relative_to(ROOT)}: step {SMOKE_STEP!r} no longer compares the "
        "image revision to $GITHUB_SHA, so an image labelled with another commit -- or "
        "with none -- passes the release gate"
    )
    assert read < compared[0], (
        "the revision comparison runs before the label is read, so it compares an "
        "undefined variable to the run sha and proves nothing"
    )
    after = body[compared[0] :]
    exits = [i for i, line in enumerate(after) if EXIT_NONZERO.search(line)]
    assert exits, (
        "the revision mismatch prints and the run carries on, so the gate reads "
        "success for an image naming a commit other than the one the release record "
        "quotes"
    )
    report = " ".join(after[: exits[0]])
    assert FAIL_REPORT.search(report), (
        "the revision mismatch is not reported with the FAIL: marker the other guards "
        "in this workflow use, so a release record cannot quote it"
    )
    assert "REVISION" in report and "GITHUB_SHA" in report, (
        "the revision-mismatch report names neither the label value nor the run sha, so "
        "its log cannot say which of the two is wrong"
    )


def test_the_ok_line_names_the_image_and_its_commit() -> None:
    """Success prints the line the release record quotes, before `IMAGE SMOKE OK`."""
    body = step_body(SMOKE_STEP)
    reported = first(body, OK_REPORT, "IMAGE REVISION OK report line")
    smoke_ok = first(body, SMOKE_OK, "IMAGE SMOKE OK report line")
    assert reported < smoke_ok, (
        "IMAGE REVISION OK no longer precedes IMAGE SMOKE OK, so the smoke line the "
        "gate quotes is no longer backed by a line naming the commit"
    )


def test_the_docs_move_with_the_mechanism() -> None:
    """The evidence list gains the new line, and a hand build is given the arg."""
    evidence = section(PUBLISHING, "What a publish run has to show")
    assert "IMAGE REVISION OK" in evidence, (
        f"{PUBLISHING.relative_to(ROOT)}: the evidence list does not name the IMAGE "
        "REVISION OK line, so a release record quoting that list still carries no "
        "commit"
    )
    hand = CONTAINER_DOC.read_text(encoding="utf-8")
    assert '--build-arg SEEKWRIGHT_REVISION="$(git rev-parse HEAD)"' in hand, (
        f"{CONTAINER_DOC.relative_to(ROOT)}: the hand build no longer names "
        "--build-arg SEEKWRIGHT_REVISION=$(git rev-parse HEAD), so an image built "
        "locally labels itself empty while a published one does not"
    )
