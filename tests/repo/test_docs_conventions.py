"""The map checked against the tree, and the retired record kept retired.

`docs/index.md` is the way into `docs/` -- README.md and AGENTS.md both point at
it -- and its `## Documents` section is where every page is linked one at a time,
while the `## Structure` table above it names the paths in prose only. When the
map check was first written, exactly one tracked page had no link there:
`docs/reference/surface.md`, the frozen-surface manifest, the page that says what
the freeze holds. Nothing read the map, so the gap was silent. The check walks
`docs/` from the filesystem and asks that every page but the map itself be
linked in that section, so a page added later arrives with its entry or fails
the gate.

The last check reads the other direction. The dated decision record was retired
because its reasoning belongs beside the rule it explains, not in a growing
ledger; the file is gone, and nothing resolves a markdown link, so a surviving
mention would send a reader nowhere. This module also keeps the older ban on
arguing from a date: a page states its own reason, and a measurement date ("read
2026-10-23") stays legal anywhere.
"""

from __future__ import annotations

import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


# The map links every docs page: a page named only in prose never reaches a reader.
INDEX = ROOT / "docs" / "index.md"
DOCS = ROOT / "docs"
DOCUMENTS_HEADING = re.compile(r"^## Documents[ \t]*$", re.MULTILINE)
NEXT_SECTION = re.compile(r"^## ", re.MULTILINE)
LINK_TARGET = re.compile(r"\]\(([^)\s]+)\)")


def _documents_section(text: str) -> str:
    """The body of the `## Documents` section: its heading up to the next `## `."""
    heading = DOCUMENTS_HEADING.search(text)
    if heading is None:
        return ""
    rest = text[heading.end() :]
    following = NEXT_SECTION.search(rest)
    return rest[: following.start()] if following else rest


def _unmapped_pages(section: str) -> list[str]:
    """The pages under `docs/` that no link in the map's `## Documents` section names."""
    linked = {target.split("#", 1)[0] for target in LINK_TARGET.findall(section)}
    return sorted(
        str(path.relative_to(DOCS))
        for path in DOCS.rglob("*.md")
        if path != INDEX and str(path.relative_to(DOCS)) not in linked
    )


def test_every_docs_page_is_linked_in_the_map() -> None:
    """Every page under `docs/` but `docs/index.md` is a link in the map's list.

    `docs/reference/surface.md` -- the frozen-surface manifest, the page
    the freeze answer lives on -- reached `main` with no entry in `docs/index.md`'s
    `## Documents` section, named only as prose in the `## Structure` table, so a
    reader following the documented map never reached it. The map is the documented
    route, its list links one page per bullet, and no check read it, so the gap was
    made silently and any page added later could repeat it. The map names itself in
    the `## Structure` table rather than in its own list, so it is the one page the
    census leaves out.
    """
    section = _documents_section(INDEX.read_text(encoding="utf-8"))
    assert section, "docs/index.md has no `## Documents` section for its pages to be linked in"
    unmapped = _unmapped_pages(section)
    assert not unmapped, (
        "docs/index.md's `## Documents` section must link every page under docs/; "
        f"these pages are in the tree with no entry in the map: {unmapped}"
    )


# The six words below are the whole vocabulary: the map may not invent a kind.
KINDS = (
    "contract",
    "explanation",
    "guide",
    "roadmap",
    "runbook",
    "survey",
)
MAP_BULLET = re.compile(r"^- \*\*([a-z ]+)\*\* — \[", re.MULTILINE)
KIND_TABLE_ROW = re.compile(r"^\| `([a-z ]+)` \|", re.MULTILINE)
KINDS_HEADING = re.compile(r"^## Kinds[^\n]*$", re.MULTILINE)


def _kinds_section(text: str) -> str:
    """The body of the map's `## Kinds...` section: its heading up to the next `## `."""
    heading = KINDS_HEADING.search(text)
    if heading is None:
        return ""
    rest = text[heading.end() :]
    following = NEXT_SECTION.search(rest)
    return rest[: following.start()] if following else rest


def test_the_map_labels_every_page_with_a_declared_kind() -> None:
    """Every page is linked once in the map, under a kind the map defines.

    `docs/reference/` answers for four kinds of document at one level --
    a contract that moves with the code, a runbook someone performs again, a dated
    finding that changes nothing, and a design thread still open -- and the map was
    one flat list, so the kind was nowhere a reader or a writer could see it. The
    list now labels every bullet, so this check can hold three things: a page linked
    exactly once, a label on every bullet, and a vocabulary the map's own table
    defines rather than a word invented per page.
    """
    text = INDEX.read_text(encoding="utf-8")
    section = _documents_section(text)
    linked = [target.split("#", 1)[0] for target in LINK_TARGET.findall(section)]
    repeated = sorted(target for target, seen in Counter(linked).items() if seen > 1)
    assert not repeated, (
        "docs/index.md must link each page under docs/ exactly once; these are linked "
        f"more than once, so a reader meets the same page in two groups: {repeated}"
    )
    labelled = MAP_BULLET.findall(section)
    assert len(labelled) == len(linked), (
        f"docs/index.md's `## Documents` section has {len(linked)} page links in "
        f"{len(labelled)} labelled bullets: every map bullet has the form "
        f'"- **<kind>** -- [Title](path)"'
    )
    invented = sorted(set(labelled) - set(KINDS))
    assert not invented, (
        f"these kind labels are not in the map's vocabulary: {invented}; the kinds are "
        f"{', '.join(KINDS)}"
    )
    declared = KIND_TABLE_ROW.findall(_kinds_section(text))
    assert set(declared) == set(KINDS), (
        "docs/index.md must define exactly the kinds the map uses, one table row each; "
        f"the table declares {sorted(declared)} and the map allows {sorted(KINDS)}"
    )


# The decision record was retired; a pointer to it is a pointer to no file. The
# date-as-authority pattern is held for the same reason as before: a page states
# its own reason, and a measurement date stays legal.
RETIRED_RECORD = re.compile(r"decisions\.md")
DATED_AUTHORITY = re.compile(r"\bthe \d{4}-\d{2}-\d{2} (?:entry|rule|decision)\b", re.IGNORECASE)
GUARDED_SUFFIXES = (".md", ".py", ".html")


def _files(root: Path, suffixes: tuple[str, ...]) -> list[Path]:
    """Every candidate file under `root`, sorted, so a failure names files in a stable order."""
    return sorted(path for path in root.rglob("*") if path.suffix in suffixes and path.is_file())


def test_no_file_cites_the_retired_decision_record() -> None:
    """`docs/`, `src/`, `tests/`, `tools/` and the front door name no retired record.

    The file was deleted rather than trimmed, and nothing checks that a markdown
    link resolves, so a surviving mention would send a reader to a 404. This module
    is skipped by its own scan: it holds the pattern it bans.
    """
    roots = [DOCS, ROOT / "src", ROOT / "tests", ROOT / "tools"]
    paths = [
        path
        for root in roots
        for path in _files(root, GUARDED_SUFFIXES)
        if path != Path(__file__).resolve()
    ]
    paths += [ROOT / name for name in ("AGENTS.md", "README.md", "CONTRIBUTING.md", "SECURITY.md")]
    offenders = [
        f"{path.relative_to(ROOT)}: {line.strip()}"
        for path in paths
        for line in path.read_text(encoding="utf-8").splitlines()
        if RETIRED_RECORD.search(line) or DATED_AUTHORITY.search(line)
    ]
    assert not offenders, "a surviving citation of the retired decision record:\n" + "\n".join(offenders)
