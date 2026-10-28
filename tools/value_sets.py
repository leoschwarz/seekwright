"""The six frozen value sets, read out of the tree and checked against a pinned manifest.

The 0.1.0 freeze fixes value sets as well as names: the members of `KNOWN_FALLBACKS`,
`KNOWN_EXTRACTORS`, `KNOWN_PROVIDERS`, `ProviderConfig.output_type`, `LoggingConfig.format`
and `LogLevel`. None of those prints a line in `tools/surface.py`, so a widened fallback set
or a second extraction backend is invisible in the surface diff -- which is how
`KNOWN_FALLBACKS` grew from three rows to five and CI answered success. This is the third
`--check` step, beside `tools/surface.py` and `tools/egress_lists`, in the one CI lane.
Stdlib-only, and shipped nowhere: `.containerignore` drops `tools/`.

Three conventions the check depends on:

* Stdlib `ast`, and no import of the package -- the rule `tools/egress_lists.py` states too.
  Reading the source text is what lets this file see `config.py`, which cannot import
  `fetcher.py` at runtime, and importing the package would report what an interpreter with
  pydantic installed resolved rather than what the tree says. Only string literals are read:
  a member spelled any other way is a source that has moved, because a reader that silently
  skips it is the blindness this tool exists to remove.
* `tools/value_sets.json` is the single pinned baseline, written here by `--write`. The tree
  that lands the manifest is the tree it pins, so the check guards moves from that head
  forward rather than turning `main` red for moves already in it. Members are sorted, so a
  move reads as one added name and one removed name at a known place.
* `--check` answers with three exit codes, mirroring `tools/surface.py` and
  `tools/egress_lists.py`: 1 when a pinned set has moved, 2 when a source the census reads is
  missing or stops saying what this file claims it says. An instrument that cannot read its
  input never exits 0: a silent green on an unparsable source is the failure mode this guards.

What is deliberately absent. Whether a move is allowed is not this tool's call: it prints the
rule the move has to satisfy -- an issue first, then one pull request that re-pins the
manifest beside the code -- and the gate decides. Only membership is compared: the freeze
refuses to freeze defaults, bounds and prices. And size is not a check -- a name traded for
a name leaves every count alone -- so the gate still reads the diff for a swap.
"""

from __future__ import annotations

import argparse
import ast
import json
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

SUMMARY = "Print the frozen value sets the tree declares, or check them against the pinned manifest."
SRC = Path("src/seekwright")
FETCHER = SRC / "fetcher.py"
EXTRACTOR_BASE = SRC / "extractors" / "base.py"
CONFIG = SRC / "config.py"
MANIFEST = Path("tools/value_sets.json")

# How each set spells its members in the source.
REGISTRY = "dict keys"
COLLECTION = "set literal"
LITERAL = "Literal members"

FREEZE_RULE = (
    "frozen value sets: a frozen set moves only in one pull request that opens as an issue first and "
    "re-pins `tools/value_sets.json` beside the code -- re-run "
    "`uv run python -m tools.value_sets --write` at that tree, or move the name back"
)


class SourceError(Exception):
    """A source the census reads is missing, or stops saying what this file claims it says."""


def _joined(names: Sequence[str]) -> str:
    """Members on one line, in the order the caller already sorted them."""
    return ", ".join(names)

@dataclass(frozen=True)
class Frozen:
    """One set the freeze names, and where and how this tree declares its members."""

    id: str
    source: Path
    symbol: str
    shape: str
    owner: str | None = None


SETS = (
    Frozen("KNOWN_FALLBACKS", FETCHER, "KNOWN_FALLBACKS", REGISTRY),
    Frozen("KNOWN_EXTRACTORS", EXTRACTOR_BASE, "KNOWN_EXTRACTORS", COLLECTION),
    Frozen("KNOWN_PROVIDERS", CONFIG, "KNOWN_PROVIDERS", COLLECTION),
    Frozen("ProviderConfig.output_type", CONFIG, "output_type", LITERAL, "ProviderConfig"),
    Frozen("LoggingConfig.format", CONFIG, "format", LITERAL, "LoggingConfig"),
    Frozen("LogLevel", CONFIG, "LogLevel", LITERAL),
)


@dataclass(frozen=True)
class Declared:
    """A set as the tree declares it now: its members, and the line that declares them."""

    lineno: int
    names: tuple[str, ...]


@dataclass(frozen=True)
class Drift:
    """One pinned set whose membership the tree has moved."""

    id: str
    source: Path
    lineno: int
    added: tuple[str, ...]
    removed: tuple[str, ...]

    def render(self) -> str:
        lines = [f"DRIFT in {self.id} ({self.source}:{self.lineno}):"]
        if self.added:
            lines.append(f"  added:   {_joined(self.added)}")
        if self.removed:
            lines.append(f"  removed: {_joined(self.removed)}")
        return "\n".join(lines)


def _module(path: Path) -> ast.Module:
    if not path.is_file():
        raise SourceError(f"{path} is missing")
    try:
        return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except SyntaxError as exc:
        # A source that stops parsing is a source that has moved. It is named on one
        # line and answered with the exit code the gate reads: an uncaught exception
        # here is a traceback, and a traceback names no set.
        raise SourceError(f"{path}:{exc.lineno} does not parse: {exc.msg}") from exc


def _binding(body: list[ast.stmt], symbol: str, where: str) -> ast.stmt:
    """The statement binding `symbol` in a statement list, reading `Assign` and `AnnAssign` alike."""
    for stmt in body:
        targets: list[ast.expr] = []
        if isinstance(stmt, ast.Assign):
            targets = list(stmt.targets)
        elif isinstance(stmt, ast.AnnAssign):
            targets = [stmt.target]
        if any(isinstance(target, ast.Name) and target.id == symbol for target in targets):
            return stmt
    raise SourceError(f"{where} declares no {symbol}")


def _strings(nodes: list[ast.expr], where: str) -> tuple[str, ...]:
    """Members spelled as string literals; anything else is a source that has moved."""
    names = []
    for node in nodes:
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            names.append(node.value)
        else:
            raise SourceError(f"{where}: a member is not a string literal, so its value is not readable here")
    return tuple(sorted(names))


def _dict_keys(node: ast.expr, where: str) -> tuple[str, ...]:
    if not isinstance(node, ast.Dict):
        raise SourceError(f"{where} is not a dict literal, so the registry has moved away from the expected shape")
    names: list[str] = []
    for key in node.keys:
        if isinstance(key, ast.Constant) and isinstance(key.value, str):
            names.append(key.value)
        else:
            raise SourceError(f"{where}: a key is not a string literal, so its name is not readable here")
    return tuple(sorted(names))


def _set_members(node: ast.expr, where: str) -> tuple[str, ...]:
    """Members of a `{...}` literal or of `frozenset({...})` -- the two spellings both registries use."""
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in {"frozenset", "set"}:
        if len(node.args) != 1:
            raise SourceError(f"{where} wraps something other than one literal")
        node = node.args[0]
    if not isinstance(node, (ast.Set, ast.List, ast.Tuple)):
        raise SourceError(f"{where} is not a set literal, so the pinned set has moved out of the tree")
    return _strings(list(node.elts), where)


def _member_node(stmt: ast.stmt, shape: str, where: str) -> ast.expr:
    """The node that spells a set's members.

    A `Literal` on a config key puts its members in the annotation and its default in the value
    (`output_type: Literal["sourcedAnswer", "searchResults"] = "sourcedAnswer"`), while a module-level
    alias has only the value (`LogLevel = Literal[...]`). Only membership is frozen -- the same entry
    refuses to freeze defaults -- so whichever side carries the `Literal` is the side read. A registry
    or a collection always spells its members in the value.
    """
    annotation = stmt.annotation if isinstance(stmt, ast.AnnAssign) else None
    value = stmt.value if isinstance(stmt, (ast.Assign, ast.AnnAssign)) else None
    if shape == LITERAL:
        for node in (annotation, value):
            if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id == "Literal":
                return node
        raise SourceError(f"{where} carries no `Literal[...]`, so the frozen enum members are not readable there")
    if value is None:
        raise SourceError(f"{where} declares a value set with nothing on its right-hand side to read")
    return value


def _literal_members(node: ast.expr, where: str) -> tuple[str, ...]:
    if not (isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id == "Literal"):
        raise SourceError(f"{where} is not a `Literal[...]`, so its members are not readable as `Literal` entries")
    elements = list(node.slice.elts) if isinstance(node.slice, ast.Tuple) else [node.slice]
    return _strings(elements, where)


READERS = {REGISTRY: _dict_keys, COLLECTION: _set_members, LITERAL: _literal_members}


def read_tree() -> dict[str, Declared]:
    """The six frozen sets, as this checkout declares them."""
    modules: dict[Path, ast.Module] = {}
    declared: dict[str, Declared] = {}
    for frozen in SETS:
        if frozen.source not in modules:
            modules[frozen.source] = _module(frozen.source)
        body = modules[frozen.source].body
        where = str(frozen.source)
        if frozen.owner is not None:
            for stmt in body:
                if isinstance(stmt, ast.ClassDef) and stmt.name == frozen.owner:
                    body = stmt.body
                    where = f"{frozen.source} class {frozen.owner}"
                    break
            else:
                raise SourceError(f"{where} declares no class {frozen.owner}")
        stmt = _binding(body, frozen.symbol, where)
        node = _member_node(stmt, frozen.shape, where)
        declared[frozen.id] = Declared(stmt.lineno, READERS[frozen.shape](node, f"{where}:{stmt.lineno}"))
    return declared


def read_manifest(path: Path) -> dict[str, tuple[str, ...]]:
    """The pinned sets, or a failure that says why the baseline cannot be trusted."""
    if not path.is_file():
        raise SourceError(f"{path} is missing: run `uv run python -m tools.value_sets --write` at the head that should become the baseline")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise SourceError(f"{path} is not readable JSON: {exc}") from exc
    if not isinstance(data, dict) or not data:
        raise SourceError(f"{path} pins no set")
    pinned: dict[str, tuple[str, ...]] = {}
    for key, value in data.items():
        if not isinstance(value, list) or not all(isinstance(name, str) for name in value):
            raise SourceError(f"{path} pins {key} as something other than a list of names")
        pinned[key] = tuple(value)
    unknown = sorted(set(pinned) - {frozen.id for frozen in SETS})
    if unknown:
        raise SourceError(f"{path} pins {_joined(unknown)}, which this tree does not declare where the freeze entry puts it")
    missing = sorted({frozen.id for frozen in SETS} - set(pinned))
    if missing:
        raise SourceError(f"{path} pins none of {_joined(missing)}: re-run `--write` to pin all six sets")
    return pinned


def compare(pinned: dict[str, tuple[str, ...]], declared: dict[str, Declared]) -> list[Drift]:
    """Per set, the names the tree has gained and the names it has lost."""
    drifts = []
    for frozen in SETS:
        gained = sorted(set(declared[frozen.id].names) - set(pinned[frozen.id]))
        lost = sorted(set(pinned[frozen.id]) - set(declared[frozen.id].names))
        if gained or lost:
            drifts.append(Drift(frozen.id, frozen.source, declared[frozen.id].lineno, tuple(gained), tuple(lost)))
    return drifts


def census(declared: dict[str, Declared]) -> str:
    total = sum(len(one.names) for one in declared.values())
    per_set = ", ".join(f"{key} {len(one.names)}" for key, one in declared.items())
    return (
        f"frozen value sets ok: {len(declared)} sets across {len({frozen.source for frozen in SETS})} files, "
        f"{total} names pinned ({per_set})"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=SUMMARY)
    parser.add_argument("--write", action="store_true", help="pin the sets this tree declares into the manifest")
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if this tree moves a set the manifest pins",
    )
    args = parser.parse_args(argv)

    try:
        declared = read_tree()
    except SourceError as exc:
        print(f"frozen value sets: {exc}", file=sys.stderr)
        return 2

    if args.write:
        MANIFEST.write_text(
            json.dumps({key: list(one.names) for key, one in declared.items()}, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(census(declared))
        return 0

    if args.check:
        try:
            pinned = read_manifest(MANIFEST)
        except SourceError as exc:
            print(f"frozen value sets: {exc}", file=sys.stderr)
            return 2
        drifts = compare(pinned, declared)
        if drifts:
            for drift in drifts:
                print(drift.render(), file=sys.stderr)
            print(FREEZE_RULE, file=sys.stderr)
            return 1
        print(census(declared))
        return 0

    for frozen in SETS:
        one = declared[frozen.id]
        print(f"{frozen.id} ({frozen.source}:{one.lineno}): {_joined(one.names)}")
    print(census(declared))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
