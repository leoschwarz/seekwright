"""The frozen value-set checker cannot rot: a registry with one row added fails `--check`.

The 0.1.0 freeze fixes value sets as well as names -- the members of `KNOWN_FALLBACKS`,
`KNOWN_EXTRACTORS`, `KNOWN_PROVIDERS`, `ProviderConfig.output_type`, `LoggingConfig.format`
and `LogLevel` -- and the one path for moving one is a superseding dated entry in the
decision record, opened as an issue first. Neither `tools/surface.py` nor any other step
could see those sets move, which is how `KNOWN_FALLBACKS` went from three rows at a pull
request's base to five at its head while `ci / check (pull_request)` answered success at
that head. `tools/value_sets.py` is that reading, made once, at every head.

A checker's own blindness is what would let that happen again, so the guarantee the issue asks
for runs against a tree this file builds and through the command CI runs: pin a
three-fallback registry, add a fourth row to `KNOWN_FALLBACKS`, and `--check` exits 1 naming
that set and that name. A fixture left in the real tree would fail the gate, so every file
below lives under `tmp_path`, manifest included -- it is written by `--write` at the fixture,
which is also how the landed baseline gets pinned.

The rest pins what a green run cannot see: the exit code for a source that stops spelling its
members the way the tool reads them (a reader that skips what it cannot parse reports a
smaller set at rc 0, which is the failure class this tool exists to close, and it is why the
census reads `Assign` and `AnnAssign` alike); the rule that a `Literal`'s members sit in the
annotation of an annotated config key and in the value of a module-level alias; and the
wiring in the CI lane.

The subprocess runs use `-m tools.value_sets`, the command the gate runs, with the repository
root on `PYTHONPATH` and the working directory set to the tree being read -- the tool resolves
both its sources and its manifest against the working directory, which is what makes a scratch
tree checkable at all.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# The six sets the freeze names, keyed the way the manifest keys them.
FROZEN_IDS = (
    "KNOWN_FALLBACKS",
    "KNOWN_EXTRACTORS",
    "KNOWN_PROVIDERS",
    "ProviderConfig.output_type",
    "LoggingConfig.format",
    "LogLevel",
)

# The three sources the census reads, spelled the way `src/` spells them: a dict registry, a `frozenset`
# collection, and `Literal`s in both the annotated-key form and the module-level alias form.
FETCHER = """
KNOWN_FALLBACKS: dict[str, Fallback] = {
    "crawl4ai": Fallback(name="crawl4ai"),
    "jina": Fallback(name="jina"),
    "scrappa": Fallback(name="scrappa"),
}
"""

EXTRACTOR_BASE = """
KNOWN_EXTRACTORS: frozenset[str] = frozenset({"stdlib", "trafilatura"})
"""

CONFIG = """
KNOWN_PROVIDERS = frozenset({"scrappa", "serper"})


class ProviderConfig(Section):
    output_type: Literal["sourcedAnswer", "searchResults"] = "sourcedAnswer"


LogLevel = Literal["TRACE", "DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR", "CRITICAL"]


class LoggingConfig(Section):
    format: Literal["text", "json"] = "text"
"""


def _run(tool_arg: str, cwd: Path) -> subprocess.CompletedProcess[str]:
    """The command CI runs, against `cwd`, with the tool itself found at the repository root."""
    env = {**os.environ, "PYTHONPATH": str(ROOT)}
    return subprocess.run(
        [sys.executable, "-m", "tools.value_sets", tool_arg],
        capture_output=True,
        text=True,
        check=False,
        cwd=cwd,
        env=env,
    )


def _tree(tmp_path: Path, fetcher: str = FETCHER, config: str = CONFIG) -> Path:
    """A checkout holding the three sources the census reads, and a `tools/` dir for its manifest."""
    package = tmp_path / "src" / "seekwright"
    (package / "extractors").mkdir(parents=True, exist_ok=True)
    (package / "fetcher.py").write_text(fetcher, encoding="utf-8")
    (package / "config.py").write_text(config, encoding="utf-8")
    (package / "extractors" / "base.py").write_text(EXTRACTOR_BASE, encoding="utf-8")
    (tmp_path / "tools").mkdir(parents=True, exist_ok=True)
    return tmp_path


def test_a_fallback_added_to_the_registry_fails_the_command_ci_runs(tmp_path: Path) -> None:
    """The issue's own guarantee: a fourth `KNOWN_FALLBACKS` row exits 1 and names itself, not a silent pass."""
    tree = _tree(tmp_path)
    assert _run("--write", tree).returncode == 0, "the fixture cannot pin its own baseline"

    wider = FETCHER.replace(
        '    "scrappa": Fallback(name="scrappa"),',
        '    "scrappa": Fallback(name="scrappa"),\n    "linkup": Fallback(name="linkup"),',
    )
    (tree / "src" / "seekwright" / "fetcher.py").write_text(wider, encoding="utf-8")

    done = _run("--check", tree)
    assert done.returncode == 1, done.stdout + done.stderr
    report = done.stderr
    assert "KNOWN_FALLBACKS" in report, report
    assert "linkup" in report, report
    assert "docs/decisions.md" in report, (
        f"a move is reported without the rule it has to satisfy: {report}"
    )


def test_a_widened_literal_on_an_annotated_key_fails_the_command_ci_runs(tmp_path: Path) -> None:
    """`output_type: Literal[...] = default`: the members are in the annotation, and so is the drift."""
    tree = _tree(tmp_path)
    assert _run("--write", tree).returncode == 0
    (tree / "src" / "seekwright" / "config.py").write_text(
        CONFIG.replace('output_type: Literal["sourcedAnswer",', 'output_type: Literal["answerNow", "sourcedAnswer",'),
        encoding="utf-8",
    )

    done = _run("--check", tree)
    assert done.returncode == 1, done.stdout + done.stderr
    assert "ProviderConfig.output_type" in done.stderr, done.stdout + done.stderr
    assert "answerNow" in done.stderr, done.stdout + done.stderr


def test_a_member_that_is_not_a_string_literal_exits_2(tmp_path: Path) -> None:
    """A set the reader cannot parse is an error, never a smaller set reported as a pass."""
    tree = _tree(tmp_path)
    assert _run("--write", tree).returncode == 0
    (tree / "src" / "seekwright" / "extractors" / "base.py").write_text(
        'KNOWN_EXTRACTORS: frozenset[str] = frozenset({STDLIB, "trafilatura"})\n', encoding="utf-8"
    )

    done = _run("--check", tree)
    assert done.returncode == 2, done.stdout + done.stderr
    assert "not a string literal" in done.stderr, done.stdout + done.stderr


def test_a_registry_that_leaves_the_dict_shape_exits_2(tmp_path: Path) -> None:
    """`--check` keeps its third exit code when a source moves out of the shape the census reads."""
    tree = _tree(tmp_path)
    assert _run("--write", tree).returncode == 0
    (tree / "src" / "seekwright" / "fetcher.py").write_text(
        'KNOWN_FALLBACKS = {"crawl4ai", "jina", "scrappa"}\n', encoding="utf-8"
    )

    done = _run("--check", tree)
    assert done.returncode == 2, done.stdout + done.stderr
    assert "not a dict literal" in done.stderr, done.stdout + done.stderr


def test_a_source_that_does_not_parse_exits_two(tmp_path: Path) -> None:
    """A source the census cannot parse is the third exit code, on one line: not a traceback.

    The census parses source text with whatever interpreter runs it, while the tree is written for
    `requires-python >=3.14`: PEP 758's parenthesis-free `except A, B:` compiles on 3.14 and is a
    syntax error on 3.13, so reader and tree can disagree about whether a file parses. The answer
    is the source failure the docstring promises -- 2, file and line named -- because a traceback
    reports no set, no file, and nothing the gate can act on.
    """
    tree = _tree(tmp_path)
    assert _run("--write", tree).returncode == 0
    (tree / "src" / "seekwright" / "extractors" / "base.py").write_text(
        'KNOWN_EXTRACTORS: frozenset[str] = frozenset({"stdlib", "trafilatura"\n',
        encoding="utf-8",
    )

    done = _run("--check", tree)
    assert done.returncode == 2, done.stdout + done.stderr
    assert "src/seekwright/extractors/base.py:1 does not parse" in done.stderr, done.stderr
    assert "Traceback" not in done.stderr, done.stderr


def test_the_landed_manifest_matches_the_landed_tree() -> None:
    """The baseline is the tree that lands it: `main` passes its own check, and the six sets are all pinned."""
    done = _run("--check", ROOT)
    assert done.returncode == 0, done.stdout + done.stderr

    manifest = ROOT / "tools" / "value_sets.json"
    assert manifest.is_file(), "the pinned baseline is not committed, so the CI step checks nothing"
    text = manifest.read_text(encoding="utf-8")
    for key in FROZEN_IDS:
        assert f'"{key}"' in text, f"{key} is not pinned in {manifest}"


def test_the_ci_lane_runs_the_step() -> None:
    """The step is the instrument: CI carries it beside the other three checks."""
    workflow = ROOT / ".github" / "workflows" / "ci.yml"
    text = workflow.read_text(encoding="utf-8")
    assert "uv run python -m tools.value_sets --check" in text, (
        f"{workflow.relative_to(ROOT)} runs no frozen value-set check; the other `--check` "
        "steps there are the pattern this one follows"
    )
