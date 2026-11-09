"""Every action every workflow runs is pinned to a full commit SHA, by test.

A `uses:` line naming a tag (`actions/checkout@v7`) names a ref the owner can move:
the tag is a pointer, and whoever can publish a release can repoint it at a commit
this repository never reviewed. The 2025 Trivy action incident is the concrete case
-- a compromised action tag ran inside pipelines that had written the tag rather
than the commit -- and the same shape was in both workflow files here. A 40-hex SHA
is immutable, so it names the exact tree that runs; the trailing comment preserves
the human-readable version for the bump that moves it.

Like `tests/repo/test_ci_workflow_concurrency.py` and the other workflow guards,
this reads the files as text rather than parsing YAML: the runner consumes them, not
Python, and the claim is about what each `uses:` line says. Both files are walked,
so a third workflow is covered without editing this module.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = sorted((ROOT / ".github" / "workflows").glob("*.yml"))

# A step's `uses:` line, with or without the `- ` marker a list item carries; a
# job-level reusable-workflow call is the same key one level out. The captured value
# stops at whitespace, so the trailing `# version` comment is not part of the ref.
USES = re.compile(r"^\s*(?:-\s+)?uses:\s*(\S+)")
FULL_SHA = re.compile(r"@[0-9a-f]{40}$")


def refs_of(path: Path) -> list[tuple[int, str]]:
    """Every `uses:` ref in one workflow, with the line number a reader can find it at."""
    refs: list[tuple[int, str]] = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        match = USES.match(line)
        if match is not None:
            refs.append((number, match.group(1)))
    return refs


def test_every_workflow_action_is_pinned_to_a_commit_sha() -> None:
    """No `uses:` line reaches a mutable tag, in either workflow."""
    assert WORKFLOWS, "no .github/workflows/*.yml files, so this guard checks nothing"
    for workflow in WORKFLOWS:
        refs = refs_of(workflow)
        assert refs, (
            f"{workflow.relative_to(ROOT)}: holds no `uses:` line, so the pinning rule "
            "has nothing to check there and this test would pass in silence"
        )
        unpinned = [
            f"{workflow.relative_to(ROOT)}:{number}: {ref}"
            for number, ref in refs
            if not FULL_SHA.search(ref)
        ]
        assert not unpinned, (
            "a workflow action is not pinned to a full 40-hex commit SHA, so an "
            "upstream tag can move the code that runs here:\n" + "\n".join(unpinned)
        )
