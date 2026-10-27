"""The four findings an earlier review left on `tools/surface.py`, pinned by tests.

The tool landed with no test of its own: it shipped as a CI step, and the
CI step runs one command (`python -m tools.surface --check`) over one tree, so it
pins the tree and nothing about how the tool behaves when the tree is not what it
expects. That review found four things behind this, each
re-measured at the landed tree and each pinned here:

* the two failures are two exit codes, not one: a manifest with no marker line
  exits 1 and says so, while only a manifest that is not in the tree exits 2 --
  the pull request's body had them both as 2, and the same sentence sat in the manifest's own
  header prose and in `public-api.md`;
* a drift hunk names the line it drifted and, since two lines of context rarely
  reach the heading above them, not the section: QA's probe was a renamed `search`
  argument reported as `@@ -25,5 +25,5 @@`, so a CI failure named a name with no
  tool, route or config table attached;
* the section is now printed above each hunk, taken from the side of the diff the
  change sits on, so a pure insertion is located too -- and which side it is read
  from is pinned here as well;
* the header line printed `no-commit` in every linked worktree, because `.git` is
  a `gitdir:` pointer file there rather than a directory -- the commit is read from
  the worktree's own `HEAD`, and the branch ref is looked for in that directory and
  then in the common directory, loose or packed.

The tool is imported by path rather than by name because `testpaths` is `tests`,
so a bare `pytest` run has no repository root on `sys.path`; the subprocess runs
use `-m tools.surface` from the repository root, which is the command the gate runs.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs" / "reference" / "surface.md"
MARKER = "<!-- surface:body -->"
SHA = "1111111111111111111111111111111111111111"
NL = "\n"  # the newline git terminates each of these ref files with


def _load_tool() -> ModuleType:
    """`tools/surface.py` as a module, without the repository root on `sys.path`."""
    spec = importlib.util.spec_from_file_location("surface_tool", ROOT / "tools" / "surface.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


surface = _load_tool()


def run(*argv: str) -> subprocess.CompletedProcess[str]:
    """Run the tool the way the gate runs it, and hand back the whole result."""
    return subprocess.run(
        [sys.executable, "-m", "tools.surface", *argv],
        capture_output=True,
        text=True,
        check=False,
        cwd=ROOT,
    )


def body_of_manifest() -> list[str]:
    """The checked-in manifest's body: the lines below the marker."""
    lines = MANIFEST.read_text(encoding="utf-8").splitlines()
    return lines[lines.index(MARKER) + 1 :]


def section_label_above(report: list[str]) -> str:
    """The label printed above the only hunk of a one-hunk drift report."""
    header = next(line for line in report if line.startswith("@@"))
    return report[report.index(header) - 1]


def section_labels(report: list[str]) -> list[str]:
    """The section label of every hunk of a drift report, in hunk order."""
    return [line.removeprefix(">> section: ") for line in report if line.startswith(">> section:")]


# A manifest body long enough that the hunk around the middle name cannot carry
# the heading it sits under: nine arguments under one `###` heading.
BODY = [
    "## MCP tools (1)",
    "",
    "### `search` (9 arguments)",
    "",
    *[f"- `argument_{index}`" for index in range(9)],
    "",
    "## Provider names (1)",
    "",
    "- `alpha`",
]

# Three sections so a name added mid-list is numbered on the following heading's
# line.
SECTIONS = [
    "## MCP tools (2)",
    "",
    "### `search` (6 arguments)",
    "",
    *[f"- `argument_{index}`" for index in range(6)],
    "",
    "### `fetch` (3 arguments)",
    "",
    "- `url`",
    "- `max_bytes`",
    "- `timeout`",
    "",
    "## Provider names (1)",
    "",
    "- `alpha`",
]


def linked_worktree(
    tmp_path: Path, sha: str, *, branch: str = "main", pack: bool = False
) -> Path:
    """A linked worktree of a hand-written git layout: `.git` is a pointer file,
    its `HEAD` is in the worktree's own git directory, and the branch ref lives in
    the common directory -- loose, or packed when `pack` is set."""
    common = tmp_path / "common"
    (common / "refs" / "heads").mkdir(parents=True)
    (common / "HEAD").write_text(f"ref: refs/heads/{branch}" + NL, encoding="utf-8")
    if pack:
        (common / "packed-refs").write_text(
            f"# pack{NL}{sha} refs/heads/{branch}" + NL, encoding="utf-8"
        )
    else:
        (common / "refs" / "heads" / branch).write_text(f"{sha}" + NL, encoding="utf-8")

    worktree = tmp_path / "wt"
    worktree.mkdir()
    gitdir = common / "worktrees" / "wt"
    gitdir.mkdir(parents=True)
    (gitdir / "HEAD").write_text(f"ref: refs/heads/{branch}" + NL, encoding="utf-8")
    (gitdir / "commondir").write_text("../.." + NL, encoding="utf-8")
    (worktree / ".git").write_text(f"gitdir: {gitdir}" + NL, encoding="utf-8")
    return worktree


def test_the_checked_in_manifest_still_matches_the_tree() -> None:
    """The gate's own command, as a test: the manifest in this tree is a printing
    of this tree, so every other test here reads a body that is honest."""
    done = run("--check")
    assert done.returncode == 0, done.stderr
    assert "SURFACE OK" in done.stdout


def test_the_fetch_parameter_move_reaches_both_ends_of_the_manifest() -> None:
    """`fetch` gained `provider`, and the instrument reads its two
    ends apart: the tool's arguments off `server.py`, the REST body keys off
    `models.FetchRequest`. A name that grew on one encoding only is drift here,
    not a pass -- which is the check that keeps the manifest printed in the same
    pull that moves the surface.
    """
    reading = surface.read_surface(ROOT)
    tool = next(t for t in reading["tools"] if t["name"] == "fetch")
    route = next(r for r in reading["rest_routes"] if r["path"] == "/api/v1/fetch")
    assert tool["arguments"] == ["url", "offset", "query", "path", "provider"]
    assert route["body_keys"] == ["offset", "path", "provider", "query", "url"]


def test_a_manifest_with_no_marker_exits_one(tmp_path: Path) -> None:
    """Not a rendering made by this tool is drift-shaped, not a missing file.

    A pull request's body stated 2 for both failures; measured at the landed tree and here,
    the marker-less case exits 1 with its own message and only the missing file
    exits 2. Both fail CI, so the gate never depended on the sentence.
    """
    unmarked = tmp_path / "surface.md"
    unmarked.write_text(
        MANIFEST.read_text(encoding="utf-8").replace(MARKER, "<-- marker removed -->"),
        encoding="utf-8",
    )
    done = run("--check", "--manifest", str(unmarked))
    assert done.returncode == 1, done.stderr
    assert f"{MARKER} is missing: not a rendering made by this tool" in done.stderr


def test_a_manifest_that_is_not_in_the_tree_exits_two(tmp_path: Path) -> None:
    done = run("--check", "--manifest", str(tmp_path / "absent.md"))
    assert done.returncode == 2, done.stderr
    assert "no manifest at" in done.stderr


def test_a_source_that_does_not_parse_names_itself(tmp_path: Path) -> None:
    """A file the reading needs that stops parsing fails on its own line.

    The tool reads source text, so an unreadable file is a source that moved: the
    same one-line treatment a name that stopped being assigned gets, at the exit
    code a source failure takes, rather than a traceback naming no name.
    """
    broken = tmp_path / "src" / "seekwright" / "config.py"
    broken.parent.mkdir(parents=True)
    broken.write_text("KNOWN_PROVIDERS = frozenset({\n", encoding="utf-8")

    with pytest.raises(SystemExit) as caught:
        surface.parse(tmp_path, "src/seekwright/config.py")
    message = str(caught.value)
    assert message.startswith("src/seekwright/config.py:1 does not parse"), message


def test_a_drift_hunk_names_the_section_it_belongs_to() -> None:
    """QA's probe: a renamed argument deep in the `search` list lands in a hunk
    whose context carries no heading, so the report has to carry it."""
    drifted = list(BODY)
    drifted[BODY.index("- `argument_5`")] = "- `renamed_argument`"
    report = surface.drift(drifted, BODY)

    header = next(line for line in report if line.startswith("@@"))
    hunk = report[report.index(header) :]
    context = [line for line in hunk[1:] if line[:1] in (" ", "+", "-")]
    assert context, "the hunk has no context lines to read"
    assert not [line for line in context if line[1:].lstrip().startswith("#")]
    assert section_label_above(report) == ">> section: ### `search` (9 arguments)"
    # A manifest line is already a list item, so the diff renders it doubled.
    assert "-- `renamed_argument`" in report
    assert "+- `argument_5`" in report


def test_a_change_directly_under_a_heading_is_named_by_that_heading() -> None:
    """The label agrees with a heading the hunk itself shows, rather than naming
    the section before it."""
    drifted = list(BODY)
    drifted[BODY.index("- `argument_0`")] = "- `renamed_argument`"
    report = surface.drift(drifted, BODY)
    assert section_label_above(report) == ">> section: ### `search` (9 arguments)"


def test_a_pure_insertion_is_located_on_the_side_it_was_added_to() -> None:
    """An added name has no old-side line, so it is located in the new body."""
    added = list(BODY)
    added.insert(BODY.index("- `alpha`") + 1, "- `beta`")
    report = surface.drift(BODY, added)
    assert section_label_above(report) == ">> section: ## Provider names (1)"


def test_an_insertion_in_a_middle_section_is_read_from_the_new_side() -> None:
    """The side of the diff is chosen, not just guessed at.

    `drift()` looks the heading up in the checked-in body when a hunk starts from
    a deleted line and in the printed body when it starts from an added one.
    Rewriting that choice to always read the checked-in body leaves this file
    green: the insertion above sits at the end of the body, where the shorter list
    clamps to its own end and both readings agree. Here an earlier hunk adds a
    line above, so the two bodies hold different line counts, and the name added
    to the `fetch` list is numbered on the line `## Provider names (1)` held
    before the change: the new-side read names `fetch`, the old-side read names
    the section below the change.
    """
    added = list(SECTIONS)
    added.insert(added.index("- `argument_2`") + 1, "- `offset`")
    added.insert(added.index("- `timeout`") + 1, "- `image`")
    report = surface.drift(SECTIONS, added)

    headers = [line for line in report if line.startswith("@@")]
    assert len(headers) == 2, report
    span = surface.HUNK_HEADER.match(headers[1])
    assert span is not None, headers[1]
    old_start, new_start = span.groups()
    assert int(new_start) == int(old_start) + 1, headers[1]
    assert section_labels(report) == [
        "### `search` (6 arguments)",
        "### `fetch` (3 arguments)",
    ]


def test_the_drift_count_excludes_the_section_labels() -> None:
    """`check()` counts drifted lines as the ones starting with `+` or `-`, so the
    labels added above each hunk stay commentary and never inflate the count."""
    drifted = list(BODY)
    drifted[BODY.index("- `argument_5`")] = "- `renamed_argument`"
    report = surface.drift(drifted, BODY)
    labels = [line for line in report if line.startswith(">>")]
    counted = [
        line
        for line in report
        if line.startswith(("+", "-")) and not line.startswith(("+++", "---"))
    ]
    assert labels == [">> section: ### `search` (9 arguments)"]
    assert counted == ["-- `renamed_argument`", "+- `argument_5`"]


def test_head_commit_reads_a_linked_worktree(tmp_path: Path) -> None:
    """The header line lied wherever `.git` was a file: reading `<root>/.git/HEAD`
    found nothing and printed `no-commit`."""
    assert surface.head_commit(linked_worktree(tmp_path, SHA)) == SHA


def test_head_commit_reads_a_worktree_ref_packed_in_the_common_dir(tmp_path: Path) -> None:
    assert surface.head_commit(linked_worktree(tmp_path, SHA, pack=True)) == SHA


def test_head_commit_reads_a_detached_worktree_directly(tmp_path: Path) -> None:
    """A detached checkout names its commit in `HEAD`, which is what CI makes."""
    worktree = linked_worktree(tmp_path, SHA)
    pointer = (worktree / ".git").read_text(encoding="utf-8")
    gitdir = Path(pointer.removeprefix("gitdir: ").strip())
    (gitdir / "HEAD").write_text(f"{SHA}" + NL, encoding="utf-8")
    assert surface.head_commit(worktree) == SHA


def test_head_commit_names_the_real_commit_of_a_normal_checkout(tmp_path: Path) -> None:
    committed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=True,
        cwd=ROOT,
    ).stdout.strip()
    assert surface.head_commit(ROOT) == committed

    not_a_repo = tmp_path / "not-a-repo"
    not_a_repo.mkdir()
    assert surface.head_commit(not_a_repo) == surface.NO_COMMIT
