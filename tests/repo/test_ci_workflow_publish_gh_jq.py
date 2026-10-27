"""`--jq` in the release run takes one expression and no flags.

`gh`'s `--jq` is gh's own jq, not the jq binary: it has no `--arg`, and a flag
written after it is read as one more positional argument. `gh release view v0.1.0
--jq --arg name "$WHEEL" …` therefore died with `accepts at most 1 arg(s),
received 4` — after the release carrying the wheel had been created, at the cold
install step, so the release record showed a failure with nothing said about why.

The field name is the second half of the same trap. `--json assets` renders the
browser download URL as `url`; `browser_download_url` is the REST spelling, which
evaluates to null. A null there prints nothing and exits 0, so the run reads an
empty result as "the release holds no such asset" — a silent wrong answer rather
than an error. Hence the interpolation: the asset filename is spliced into the
expression, and the two tests below hold both halves of the shape.
"""

from __future__ import annotations

import re
import shlex
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "publish.yml"

CONTINUED = re.compile(r"\\\s*$")


def commands() -> list[list[str]]:
    """Every shell command in the workflow, continuation lines joined and split."""
    joined: list[str] = []
    pending = ""
    for line in WORKFLOW.read_text(encoding="utf-8").splitlines():
        # Prose comments hold apostrophes, and a shell tokenizer reads those as
        # opening a quotation. No `--jq` sits in one, so they are dropped here.
        if line.strip().startswith("#"):
            continue
        pending += CONTINUED.sub("", line.strip()) + " "
        if not CONTINUED.search(line):
            joined.append(pending)
            pending = ""
    split = (shlex.split(command) for command in joined)
    return [tokens for tokens in split if tokens]


def jq_arguments() -> list[list[str]]:
    """The tokens following each `--jq`, in file order."""
    return [
        tokens[index + 1 :]
        for tokens in commands()
        for index, token in enumerate(tokens)
        if token == "--jq"
    ]


def test_the_workflow_still_asks_gh_for_a_jq_expression() -> None:
    """The release asset reads are what these guards are about, so they must exist."""
    assert jq_arguments(), (
        f"{WORKFLOW.relative_to(ROOT)}: no `--jq` left in the run, so these guards "
        "would pass without checking the release asset reads they describe"
    )


def test_no_jq_call_passes_a_flag_the_expression_has_not_absorbed() -> None:
    """The token after `--jq` is the expression, not a flag gh cannot parse."""
    for following in jq_arguments():
        assert following and not following[0].startswith("-"), (
            f"{WORKFLOW.relative_to(ROOT)}: `--jq {' '.join(following)}` — gh's jq "
            "takes one expression and no flags, so the run dies with `accepts at most "
            "1 arg(s)` instead of reading the release. Splice the value into the "
            "expression, as the asset-name reads do"
        )


def test_the_asset_reads_name_the_key_gh_emits() -> None:
    """`--json assets` spells the download URL `url`; the REST name evaluates to null."""
    for following in jq_arguments():
        expression = " ".join(following)
        assert "browser_download_url" not in expression, (
            f"{WORKFLOW.relative_to(ROOT)}: `{expression}` names the REST field "
            "`browser_download_url`, which `gh --json assets` does not emit: the "
            "expression yields null, prints nothing and exits 0, and the run reads "
            "that as the release holding no such asset. The `--json` key is `url`"
        )
