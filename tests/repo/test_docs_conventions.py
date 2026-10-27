"""The prepend-collision check: `docs/decisions.md` is newest-first, by test.

Every dated entry is inserted at the same spot -- the first `## <date>` heading
under the header note -- so two decision-record PRs in one cycle conflict in one
hunk whatever their content, and the gate cannot resolve it: the case arose
in a real gate run, where `git merge-tree --write-tree` on a pull head returned
rc=1 with `CONFLICT (content): Merge conflict in docs/decisions.md` while the
other two files auto-merged and the pull-request readback reported
`mergeable: false`. The convention that settles it is stated in the header note
here and in AGENTS.md:
keep both entries, in date order. This file pins the ordering half of that
convention, so a merge resolution that drops an entry or leaves it below an
older one fails the gate instead of reaching main.

The two `## Earlier -- ...` sections at the tail of the file carry no date and so
take no part in the order; the check reads the dated headings only.

The remaining checks read the documented map against the tree. `docs/index.md`
is the way into `docs/` -- README.md and AGENTS.md both point at it -- and its
`## Documents` section is where every page is linked one at a time, while the
`## Structure` table above it names the paths in prose only. When this check was first
written, exactly one tracked page had no link there: `docs/reference/surface.md`, the
frozen-surface manifest, the page that says what the freeze holds. Nothing read the
map, so the gap was silent. The check walks `docs/` from the filesystem and asks
that every page but the map itself be linked in that
section, so a page added later arrives with its entry or fails the gate.
"""

from __future__ import annotations

import re
from collections import Counter
from itertools import pairwise
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DECISIONS = ROOT / "docs" / "decisions.md"
AGENTS = ROOT / "AGENTS.md"

DATED_HEADING = re.compile(r"^## (\d{4}-\d{2}-\d{2})\b", re.MULTILINE)

# The tie-break rule, held here as one string so the two documents that state it
# cannot drift into stating two different rules.
TIE_BREAK = (
    "Entries sit newest-first at the first `## <date>` heading, and when two "
    "branches each prepend an entry, the resolution is to keep both entries in "
    "date order (newest first) and to make no other edit to either entry."
)


def _flat(text: str) -> str:
    """The document on one line: markdown wraps, the agreement between copies does not."""
    return " ".join(text.split())


def test_dated_entries_sit_newest_first() -> None:
    """A `^## <date>` heading is never followed by an older one."""
    dates = DATED_HEADING.findall(DECISIONS.read_text(encoding="utf-8"))
    assert len(dates) > 1, f"{DECISIONS.relative_to(ROOT)}: no dated entry headings parsed"
    reversed_pairs = [
        (newer, older) for newer, older in pairwise(dates) if newer < older
    ]
    assert not reversed_pairs, (
        "docs/decisions.md must hold its dated entries newest-first; these adjacent "
        f"headings are out of order: {reversed_pairs}"
    )


def test_tie_break_rule_is_the_same_sentence_in_both_documents() -> None:
    """The rule is stated once in `docs/decisions.md` and identically in AGENTS.md."""
    rule = _flat(TIE_BREAK)
    decisions = _flat(DECISIONS.read_text(encoding="utf-8"))
    agents = _flat(AGENTS.read_text(encoding="utf-8"))
    assert decisions.count(rule) == 1, "the tie-break sentence is missing from docs/decisions.md"
    assert agents.count(rule) == 1, "the tie-break sentence is missing from AGENTS.md"


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


# The eight words below are the whole vocabulary: the map may not invent a kind.
KINDS = (
    "contract",
    "explanation",
    "guide",
    "record",
    "roadmap",
    "runbook",
    "survey",
    "thread",
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
