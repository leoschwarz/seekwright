"""Both GitHub workflows queue their runs instead of cancelling them, by test.

Each workflow file puts its runs into a `concurrency:` group keyed by workflow and
ref. That group exists to serialize runs, and with no `cancel-in-progress` key the
runner default (`true`) applies instead: each push to a pull request then cancels
every other queued or running run of that ref, and the head is left with no green
read at all -- the cancelled run never starts, so nothing downstream can tell a
refused run from a failing one. `cancel-in-progress: false` is the whole rule, and
this module is what keeps it in place.

Nothing else in the suite reads these two files -- the runner consumes them, not
Python -- so the missing key could come back and no gate would notice. The pin is
deliberately only the cancelling half: the two files name their groups differently
on purpose (the release run must not interleave with the gate run), so
`cancel-in-progress` is the only setting they have in common.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# The gate and the release lane: GitHub Actions reads `.github`, and both have to
# refuse to cancel.
WORKFLOWS = [
    ROOT / ".github" / "workflows" / "ci.yml",
    ROOT / ".github" / "workflows" / "publish.yml",
]

# A `concurrency:` block header: the key alone on its line, with an optional
# trailing comment. A scalar `concurrency: <value>` line is not a block.
BLOCK_HEADER = re.compile(r"^(?P<indent>\s*)concurrency:\s*(?:#.*)?$")


def concurrency_blocks(text: str) -> list[dict[str, str]]:
    """Every `concurrency:` block in a workflow, as its key/value pairs.

    A line read rather than a YAML parse, the way `tests/repo/test_packaging.py` reads the
    Containerfile: these files are consumed by the runner, and the claim under
    test is about what each file says at the depth the runner reads it at.
    """
    lines = text.splitlines()
    blocks: list[dict[str, str]] = []
    for index, line in enumerate(lines):
        match = BLOCK_HEADER.match(line)
        if match is None:
            continue
        indent = len(match.group("indent"))
        block: dict[str, str] = {}
        for child in lines[index + 1 :]:
            if not child.strip() or child.lstrip().startswith("#"):
                continue
            if len(child) - len(child.lstrip()) <= indent:
                break
            key, _, value = child.strip().partition(":")
            block[key.strip()] = value.strip()
        blocks.append(block)
    return blocks


def test_every_concurrency_block_queues_rather_than_cancels() -> None:
    """Each `concurrency:` block in both workflows sets `cancel-in-progress: false`."""
    for workflow in WORKFLOWS:
        blocks = concurrency_blocks(workflow.read_text(encoding="utf-8"))
        assert blocks, f"{workflow.relative_to(ROOT)}: no concurrency: block to pin"
        for block in blocks:
            assert block.get("cancel-in-progress") == "false", (
                f"{workflow.relative_to(ROOT)}: the concurrency block {block} leaves the "
                "runner default, cancel-in-progress: true, so one push cancels every "
                "other queued run of the same ref instead of queueing it behind the run "
                "ahead of it"
            )
