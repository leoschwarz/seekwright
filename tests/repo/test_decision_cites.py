"""A dated cite is not an argument, and this tree no longer makes one.

`docs/decisions.md` is the record of what was decided and what was refused. Naming it is
fine, and one page may link it as the record. What used to spread was the *dated cite*:
`(decisions.md, <date>)` at the end of a source comment, or "the <date> entry" inside a
docs page. A date carries no reasoning -- a reader who needs the reason has to open the
record and read prose to get it -- and it makes authority the
calendar rather than the constraint it states. So the rule this file pins: a page states
its own reason (`docs/index.md` says which page owns which contract), a source comment
states the constraint it protects, and neither points at a dated entry to do the arguing.

Two shapes are caught. A line that names the record and a date together, which is the cite
itself, and "the <date> entry|rule|decision", which is the same cite with the file left
out. A measurement date stays legal anywhere -- "read 2026-10-23" about a vendor's pricing
page is a fact with an expiry, not a justification -- and the record page is exempt
entirely, since its dates are its headings.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# The three trees that carry constraints in comments rather than arguments.
CODE_ROOTS = ("src", "tests", "tools")

DATE = re.compile(r"\b20\d{2}-\d{2}-\d{2}\b")
RECORD = re.compile(r"decisions\.md")
# The cite with the filename left out: "the <date> rule it replaces".
ENTRY = re.compile(r"\bthe \d{4}-\d{2}-\d{2} (?:entry|rule|decision)\b", re.IGNORECASE)


def _files(root: Path, suffixes: tuple[str, ...]) -> list[Path]:
    """Every candidate file under `root`, sorted, so a failure names files in a stable order."""
    return sorted(path for path in root.rglob("*") if path.suffix in suffixes and path.is_file())


def _offenders(paths: list[Path]) -> list[str]:
    """Each line that argues from a date instead of stating a constraint."""
    found: list[str] = []
    for path in paths:
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if (RECORD.search(line) and DATE.search(line)) or ENTRY.search(line):
                found.append(f"{path.relative_to(ROOT)}:{lineno}: {line.strip()}")
    return found


def test_no_source_file_cites_the_record_by_date() -> None:
    """`src/`, `tests/` and `tools/` state the constraint; the record is not their citation."""
    paths = [path for root in CODE_ROOTS for path in _files(ROOT / root, (".py", ".html"))]
    offenders = _offenders(paths)
    assert not offenders, "a source comment cites a dated decision entry:\n" + "\n".join(offenders)


def test_no_docs_page_cites_a_dated_entry() -> None:
    """A docs page carries its own reason; the dated record is a page to read, not a citation.

    The record page itself is the exception: its dated headings are the entries, and an
    entry is allowed to date itself.
    """
    pages = [path for path in _files(ROOT / "docs", (".md",)) if path.name != "decisions.md"]
    offenders = _offenders(pages)
    assert not offenders, "a docs page cites a dated decision entry:\n" + "\n".join(offenders)


def test_no_root_prose_cites_the_record_by_date() -> None:
    """The front door states its constraints the same way the code does.

    `AGENTS.md` is deliberately not in this list: the merge-gate rules live there,
    and their pointers to the dated record are part of that mechanism, not an
    argument borrowed from a date.
    """
    paths = [ROOT / name for name in ("README.md", "CONTRIBUTING.md", "SECURITY.md")]
    offenders = _offenders(paths)
    assert not offenders, "a root document cites a dated decision entry:\n" + "\n".join(offenders)


def test_the_record_is_reachable_from_the_map() -> None:
    """Stripping citations must not orphan the record: the map still names it.

    `test_docs_conventions.py` pins that the map links every page; this pins the one link
    that matters once nothing else points there.
    """
    index = (ROOT / "docs" / "index.md").read_text(encoding="utf-8")
    assert "](decisions.md)" in index, "docs/index.md no longer links the decision record"
