"""Documentation names a symbol, never a line of code -- and this file is the ban.

`docs/` used to point at line numbers (`usage.py:345`, `providers.md:410-411`,
`dashboard.html:657-692`), and this repository answered with an instrument that
resolved them: `tools/doc_cites.py`, a `--check` step in both copies of CI. That
answer bought the wrong guarantee. A pointer that resolves is not a pointer that is
true: reaching line 431 of a 1,500-line module says nothing about whether line 431
still holds what the sentence around it claims lives there, and the tree held cites
that had landed on blank lines -- the 2026-10 refactor survey records one on
`logs.py`, one on the `cli.py` server call and one on a `models.py` attribute. Its
first open question asked whether the citations stay and the resolver is the cheap
fix, or the docs move to symbols. The docs moved, and the resolver went with the
question: a number that shifts whenever a file above it is edited is not an address,
while `UsageRecorder._append`, `KNOWN_PROVIDERS` and `[project.urls]` name the same
code the day the code beside them is rewritten.

A prohibition has nothing to resolve, so the path lookup, the range classes, the
named exceptions and the exit codes are gone with the tool they served; `uv run
pytest` is the gate. This is the shape `tests/repo/test_docs_conventions.py` uses
for the map census: read the tree, name every offending line, assert the list is
empty.

What the pattern cannot see, and what stays a hand audit: a bare `` `:NNN` ``
continuation carries no filename for the pattern to attach to, so it is caught only
by reading the page. A literal `file.py:NNN`, a `::` node id, a file with a space
before its number, a host and a port, and a JSON number all fall out at the
extension whitelist or at the digits. Prose that says "line 379" is neither form:
that half of the rule is the sentence in `AGENTS.md`, and the survey's own samples
show why it is worth stating.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs"
# The markdown a reader meets before `docs/`, held to the same rule.
FRONT_DOOR = ("README.md", "CONTRIBUTING.md", "SECURITY.md", "AGENTS.md")

# A name with a code extension, then `:` and digits: one line, a range, or a comma
# list. The lookbehind stops a match starting inside a longer word or an earlier
# path segment, and the extension whitelist is what keeps a host and port
# (`127.0.0.1:8000`), a published container port and a JSON figure out of the ban --
# a name like `1` or `ai` is not a source extension.
LINE_CITE = re.compile(
    r"(?<![\w./-])([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*"
    r"\.(?:py|md|toml|html|feature|json|ya?ml|txt|sh|lock|cfg|ini)):\d+"
    r"(?:[-,]\s*\d+)?"
)

# Every shape the sweep found on a real page, so a widened or narrowed pattern has
# to answer for all of them.
CATCHES = (
    "See `usage.py:345` for the window.",
    "The tier is in `providers.md:410-411`.",
    "`src/seekwright/usage.py:990-1010` writes the line.",
    "The URLs sit at `pyproject.toml:40-43`.",
    "`tests/features/provider_selection.feature:51,57` pin the scenario.",
    "The panel is drawn at `dashboard.html:657-692`.",
    "`dashboard.py:1-13` states the self-contained rule.",
)

# The neighbours of those shapes: legal text a page must keep, each refused by the
# whitelist or by the digits rather than by luck.
IGNORES = (
    "`file.py:NNN` is the shape the ban names, not a cite.",
    "`tests/test_config.py::TestAnysearchRouting` is the guard.",
    "`usage.py: 345` has a space where a cite would have none.",
    "the listener answers 127.0.0.1:8000",
    "publish it with `-p <addr>:8000:8000`",
    "`exa:free` is the anonymous half of a backend",
    '{"ms":842} is one log field',
    "`api.exa.ai` is the endpoint",
    "`v0.1.0` is the tag",
    "`--allowed-host` adds to the Host allowlist",
)


def _offenders(paths: list[Path]) -> list[str]:
    """Each page line carrying a code line number, in the one form a reader can act on."""
    found: list[str] = []
    for path in paths:
        text = path.read_text(encoding="utf-8")
        for lineno, line in enumerate(text.splitlines(), start=1):
            if LINE_CITE.search(line):
                found.append(f"{path.relative_to(ROOT)}:{lineno}: {line.strip()}")
    return found


def _pages(*roots: Path, suffix: str = ".md") -> list[Path]:
    """Every page under `roots`, sorted, so a failure names them in a stable order."""
    return sorted(
        path for root in roots for path in root.rglob(f"*{suffix}") if path.is_file()
    )


def test_no_docs_page_carries_a_line_number_cite() -> None:
    """Every page under `docs/` names the symbol; not one of them counts a line.

    The scan being non-empty is part of the assertion: a guard whose population is
    empty passes in silence, and a silent guard is how the instrument this replaced
    rotted once the pages it read stopped being the pages the tree shipped.
    """
    pages = _pages(DOCS)
    assert pages, "docs/ holds no markdown pages, so this guard is checking nothing"
    offenders = _offenders(pages)
    assert not offenders, (
        "a docs page cites a code line; name the symbol (`UsageRecorder._append`, "
        "`KNOWN_PROVIDERS`, `[project.urls]`) or the page and its section "
        "(`provider-contract.md`, \"Failures\") instead:\n" + "\n".join(offenders)
    )


def test_no_front_door_document_carries_a_line_number_cite() -> None:
    """The front door is read before `docs/`, so it carries the same rule."""
    paths = [ROOT / name for name in FRONT_DOOR]
    missing = [name for name in FRONT_DOOR if not (ROOT / name).is_file()]
    assert not missing, f"the front-door list names files this tree does not hold: {missing}"
    offenders = _offenders(paths)
    assert not offenders, (
        "a front-door document cites a code line; a reader who follows the number "
        "lands wherever the file has moved to:\n" + "\n".join(offenders)
    )


def test_the_pattern_catches_every_cite_shape_and_ignores_the_rest() -> None:
    """The ban is only a ban if the pattern sees each cite shape and no legal text.

    Each row is one shape the sweep met on a real page, or one of the near-misses
    that a page has to keep: the extension whitelist is what separates a host and
    port from a cite, and the digits are what separate a quoted pattern
    (`file.py:NNN`) from a pointer.
    """
    missed = [row for row in CATCHES if not LINE_CITE.search(row)]
    assert not missed, f"these line cites would slip past the ban: {missed}"

    flagged = [row for row in IGNORES if LINE_CITE.search(row)]
    assert not flagged, f"these are not line cites, and the ban would refuse them: {flagged}"
