"""The frozen surface of the release, printed out of the tree rather than from memory.

The v0.1.0 freeze names what it freezes -- three MCP tools, their REST projection,
three client verbs, seventeen provider names, the config keys -- and this module
reads those names back out of `server.py`, `cli.py`, `config.py` and `models.py`.
`docs/reference/surface.md` is that printing checked in; `--check` re-reads the
tree, re-renders it, and exits non-zero printing the exact drift, so a name cannot
join the frozen surface without the manifest moving in the same pull request.

Exit codes: 1 when the body below the marker has drifted or the manifest carries
no marker line, 2 when the manifest is not in the tree at all.

Three conventions the rendering depends on:

* Stdlib only, and no import of the package: `ast` reads the source text, where
  importing `config.py` would report what the interpreter resolved.
* Name sets are sorted, so a name arriving shows up as one added line at a known
  place. Parameter lists keep the order the code declares them in: for a tool,
  that order is the schema the caller reads.
* `--check` compares only what sits below `MARKER`, since the header carries the
  commit and the read instant and those change on every run.

What is deliberately absent: any judgement about whether a change is allowed.
Whether a move breaks the freeze stays a reviewer's call against the boundary in
`AGENTS.md`.
"""

from __future__ import annotations

import argparse
import ast
import difflib
import json
import re
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, NamedTuple

SUMMARY = "Print the frozen surface from the tree, or check it against the manifest."
MANIFEST = "docs/reference/surface.md"
MARKER = "<!-- surface:body -->"
NO_COMMIT = "no-commit"
TS_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
# A linked worktree or a submodule keeps `.git` as a pointer file naming its git
# dir.
GITDIR_POINTER = "gitdir: "
COMMONDIR = "commondir"
# Two lines of context per hunk keeps the printed drift short. A section heading
# above each hunk is what makes a hunk that short say which name it drifted.
CONTEXT_LINES = 2
HUNK_HEADER = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")

SERVER = "src/seekwright/server.py"
CLI = "src/seekwright/cli.py"
CONFIG = "src/seekwright/config.py"
MODELS = "src/seekwright/models.py"

TOOL_DECORATOR = "mcp.tool"
ROUTE_DECORATOR = "mcp.custom_route"
MODEL_VALIDATOR = "model_validate"
# The routes the freeze names; a route elsewhere in the file is drift the diff
# names.
FROZEN_ROUTE_PREFIX = "/api/v1/"
SUBCOMMANDS_ASSIGNMENT = "_SUBCOMMANDS"
SERVER_ENTRY = "main"
CONFIG_ROOT = "Config"
# The config table whose value type repeats per provider name: `[providers]` maps
# a provider name to one table, so that value type carries the per-provider keys.
PROVIDERS_FIELD = "providers"
KNOWN_PROVIDERS = "KNOWN_PROVIDERS"
# `ctx` is FastMCP's injection point and `self`/`cls` are method receivers: none
# of them is an argument a caller passes.
HIDDEN_ARGUMENTS = frozenset({"ctx", "self", "cls"})


def parse(root: Path, relative: str) -> ast.Module:
    """Parse one file out of the tree.

    A file that does not parse stops the run with its own line, the way a source
    that stopped declaring a name does: the tree cannot be printed, and a
    traceback names no frozen name.
    """
    try:
        return ast.parse((root / relative).read_text(encoding="utf-8"), filename=relative)
    except SyntaxError as exc:
        raise SystemExit(f"{relative}:{exc.lineno} does not parse: {exc.msg}") from exc


def classes(tree: ast.Module) -> dict[str, ast.ClassDef]:
    """Every top-level class, by name."""
    return {n.name: n for n in tree.body if isinstance(n, ast.ClassDef)}


def functions(
    tree: ast.Module,
) -> dict[str, ast.FunctionDef | ast.AsyncFunctionDef]:
    """Every top-level function and coroutine, by name."""
    return {
        n.name: n
        for n in tree.body
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
    }


def fields(node: ast.ClassDef) -> list[str]:
    """The keys a model declares, in declaration order.

    An annotated class attribute named with a leading `_` is skipped: pydantic
    keeps those as private attributes, and they are not keys anyone writes.
    """
    return [
        stmt.target.id
        for stmt in node.body
        if isinstance(stmt, ast.AnnAssign)
        and isinstance(stmt.target, ast.Name)
        and not stmt.target.id.startswith("_")
    ]


def assignment_value(tree: ast.Module, name: str) -> ast.expr:
    """The value assigned to a module-level name.

    A name the module no longer assigns at top level stops the tool rather than
    reading as an empty set: an empty provider list printed by a check that was
    meant to catch exactly that is the failure mode this tool exists to avoid.
    """
    for stmt in tree.body:
        if not isinstance(stmt, (ast.Assign, ast.AnnAssign)):
            continue
        targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
        for target in targets:
            if (
                isinstance(target, ast.Name)
                and target.id == name
                and stmt.value is not None
            ):
                return stmt.value
    raise SystemExit(f"{name} is no longer assigned at the top level of the tree")


def string_items(value: ast.expr) -> list[str]:
    """The string literals in a tuple, list, set display, or a call over them.

    `KNOWN_PROVIDERS` is a `frozenset` call wrapping a set display and
    `_SUBCOMMANDS` is a tuple, so both shapes are read. Anything else is a shape
    change to look at by hand, not one to guess at.
    """
    parts: list[ast.expr]
    if isinstance(value, ast.Call):
        parts = list(value.args)
    elif isinstance(value, (ast.Tuple, ast.List, ast.Set)):
        parts = [value]
    else:
        raise SystemExit(f"unreadable name set: {ast.unparse(value)}")
    found: list[str] = []
    for part in parts:
        elements = part.elts if isinstance(part, (ast.Tuple, ast.List, ast.Set)) else [part]
        for element in elements:
            if not isinstance(element, ast.Constant) or not isinstance(element.value, str):
                raise SystemExit(f"unreadable name set entry: {ast.unparse(element)}")
            found.append(element.value)
    return found


def decorator_call(
    node: ast.FunctionDef | ast.AsyncFunctionDef, wanted: str
) -> ast.Call | None:
    """The `wanted(...)` call decorating this function, if it carries one."""
    for item in node.decorator_list:
        if isinstance(item, ast.Call) and ast.unparse(item.func) == wanted:
            return item
    return None


def keyword_strings(call: ast.Call, name: str) -> list[str]:
    """The string literals held by one keyword argument that is a list or tuple."""
    for keyword in call.keywords:
        if keyword.arg == name and isinstance(keyword.value, (ast.List, ast.Tuple)):
            return [
                element.value
                for element in keyword.value.elts
                if isinstance(element, ast.Constant) and isinstance(element.value, str)
            ]
    return []


def argument_names(node: ast.FunctionDef | ast.AsyncFunctionDef) -> list[str]:
    """The arguments a caller passes, in the order the code declares them."""
    return [
        arg.arg
        for arg in (*node.args.args, *node.args.kwonlyargs)
        if arg.arg not in HIDDEN_ARGUMENTS
    ]


def read_tools(server: ast.Module) -> list[dict[str, Any]]:
    """Each MCP tool: the name the decorator registers, and the arguments it takes."""
    tools: list[dict[str, Any]] = []
    for node in functions(server).values():
        call = decorator_call(node, TOOL_DECORATOR)
        if call is None:
            continue
        named = [
            keyword.value.value
            for keyword in call.keywords
            if keyword.arg == "name"
            and isinstance(keyword.value, ast.Constant)
            and isinstance(keyword.value.value, str)
        ]
        tools.append(
            {
                "name": named[0] if named else node.name,
                "handler": node.name,
                "line": node.lineno,
                "arguments": argument_names(node),
            }
        )
    return sorted(tools, key=lambda tool: str(tool["name"]))


def request_model(
    handler: ast.FunctionDef | ast.AsyncFunctionDef, model_names: set[str]
) -> str | None:
    """The model a REST handler validates its JSON body against.

    The handler is the registration's argument, so the route and the body model
    are read as the tree connects them rather than by a table of routes kept here.
    """
    for call in ast.walk(handler):
        if (
            isinstance(call, ast.Call)
            and isinstance(call.func, ast.Attribute)
            and call.func.attr == MODEL_VALIDATOR
            and isinstance(call.func.value, ast.Name)
            and call.func.value.id in model_names
        ):
            return call.func.value.id
    return None


def read_routes(server: ast.Module, models: ast.Module) -> list[dict[str, Any]]:
    """Every `mcp.custom_route` registration: method, path, and the body keys."""
    model_classes = classes(models)
    handlers = functions(server)
    routes: list[dict[str, Any]] = []
    for node in ast.walk(server):
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Call):
            continue
        registration = node.func
        if ast.unparse(registration.func) != ROUTE_DECORATOR or not registration.args:
            continue
        path = registration.args[0]
        if not isinstance(path, ast.Constant) or not isinstance(path.value, str):
            raise SystemExit(f"unreadable route path: {ast.unparse(path)}")
        handler_name = ast.unparse(node.args[0]) if node.args else "?"
        handler = handlers.get(handler_name)
        model = request_model(handler, set(model_classes)) if handler else None
        routes.append(
            {
                "method": "/".join(keyword_strings(registration, "methods")),
                "path": path.value,
                "handler": handler_name,
                "line": node.lineno,
                "request_model": model,
                "body_keys": sorted(fields(model_classes[model])) if model else [],
            }
        )
    return routes


def read_cli(cli: ast.Module) -> dict[str, list[str]]:
    """The client verbs and the server flags, both out of `cli.py`.

    The verbs are the tuple the dispatch reads, not argparse subparsers: `cli.py`
    keeps the two parsers apart on purpose, and the tuple is what a caller sees.
    The flags are the long options added inside the server entry; `_client_parser`
    adds client flags, which are fields of a request body, and the freeze names
    the verbs rather than every flag of every verb.
    """
    verbs = sorted(string_items(assignment_value(cli, SUBCOMMANDS_ASSIGNMENT)))
    entry = functions(cli).get(SERVER_ENTRY)
    if entry is None:
        raise SystemExit(f"{SERVER_ENTRY} is no longer a top-level function of cli.py")
    flags: list[str] = []
    for call in ast.walk(entry):
        if (
            isinstance(call, ast.Call)
            and isinstance(call.func, ast.Attribute)
            and call.func.attr == "add_argument"
            and call.args
            and isinstance(call.args[0], ast.Constant)
            and isinstance(call.args[0].value, str)
            and call.args[0].value.startswith("--")
        ):
            flags.append(call.args[0].value)
    return {"verbs": verbs, "server_flags": flags}


def read_providers(config: ast.Module) -> list[str]:
    """The provider name set, from `config.KNOWN_PROVIDERS`."""
    return sorted(string_items(assignment_value(config, KNOWN_PROVIDERS)))


def read_config(config: ast.Module) -> dict[str, Any]:
    """The config keys: the section tables, the per-provider keys, the top level.

    The section tables are not a list kept here -- they are the models the `Config`
    model names as its own sub-tables, so a section added or dropped moves this
    reading with it, and the count in the header line moves too.
    """
    by_name = classes(config)
    root = by_name.get(CONFIG_ROOT)
    if root is None:
        raise SystemExit(f"{CONFIG_ROOT} is no longer a top-level class of config.py")
    sections: list[dict[str, Any]] = []
    per_provider = ""
    for stmt in root.body:
        if not isinstance(stmt, ast.AnnAssign) or not isinstance(stmt.target, ast.Name):
            continue
        if stmt.target.id == PROVIDERS_FIELD and isinstance(stmt.annotation, ast.Subscript):
            slice_ = stmt.annotation.slice
            value = slice_.elts[-1] if isinstance(slice_, ast.Tuple) and slice_.elts else None
            if isinstance(value, ast.Name) and value.id in by_name:
                per_provider = value.id
        elif isinstance(stmt.annotation, ast.Name) and stmt.annotation.id in by_name:
            model = stmt.annotation.id
            sections.append(
                {"table": stmt.target.id, "model": model, "keys": sorted(fields(by_name[model]))}
            )
    sections.sort(key=lambda section: str(section["table"]))
    return {
        "top_level": sorted(fields(by_name[CONFIG_ROOT])),
        "sections": sections,
        "per_provider_model": per_provider,
        "per_provider_keys": sorted(fields(by_name[per_provider])) if per_provider else [],
    }


def git_directory(root: Path) -> Path | None:
    """Where the checkout keeps its refs.

    `.git` is a directory in a normal checkout and a pointer file in a linked
    worktree or a submodule, and the pointer is relative to the checkout.
    """
    dot = root / ".git"
    if dot.is_dir():
        return dot
    try:
        text = dot.read_text(encoding="utf-8")
    except OSError:
        return None
    for line in text.splitlines():
        if not line.startswith(GITDIR_POINTER):
            continue
        target = Path(line.removeprefix(GITDIR_POINTER).strip())
        return target if target.is_absolute() else root / target
    return None


def ref_directories(git: Path) -> list[Path]:
    """The directories a ref can live in, in the order git reads them: the
    worktree's own first, then the common directory named by `commondir`."""
    directories = [git]
    try:
        common = (git / COMMONDIR).read_text(encoding="utf-8").strip()
    except OSError:
        return directories
    path = Path(common)
    directories.append(path if path.is_absolute() else git / path)
    return directories


def packed_ref(git: Path, ref: str) -> str:
    """The SHA a packed-ref file names for `ref`, empty when it names none."""
    try:
        lines = (git / "packed-refs").read_text(encoding="utf-8").splitlines()
    except OSError:
        return ""
    for line in lines:
        if line.startswith(("#", "^")):
            continue
        sha, _, name = line.partition(" ")
        if name == ref:
            return sha
    return ""


def head_commit(root: Path) -> str:
    """The commit the tree was read at, taken from the ref files.

    Read rather than run: this tool prints a tree and has no business shelling
    out to git. A detached checkout, as CI makes one, names the commit directly.
    A linked worktree keeps `HEAD` inside the directory its `.git` pointer names,
    and the branch checked out there has its ref in that directory or in the
    common directory, so both are read: treating `<root>/.git` as a directory
    printed `no-commit` for every worktree-based checkout.
    """
    git = git_directory(root)
    if git is None:
        return NO_COMMIT
    try:
        head = (git / "HEAD").read_text(encoding="utf-8").strip()
    except OSError:
        return NO_COMMIT
    if not head.startswith("ref:"):
        return head
    ref = head[4:].strip()
    for directory in ref_directories(git):
        try:
            return (directory / ref).read_text(encoding="utf-8").strip()
        except OSError:
            pass
        if sha := packed_ref(directory, ref):
            return sha
    return NO_COMMIT


def read_surface(root: Path) -> dict[str, Any]:
    """Take the whole reading: four files parsed out of the tree, nothing written."""
    server = parse(root, SERVER)
    routes = read_routes(server, parse(root, MODELS))
    config_tree = parse(root, CONFIG)
    return {
        "commit": head_commit(root),
        "taken_at": datetime.now(UTC).strftime(TS_FORMAT),
        "tools": read_tools(server),
        "rest_routes": sorted(
            (r for r in routes if str(r["path"]).startswith(FROZEN_ROUTE_PREFIX)),
            key=lambda route: (str(route["method"]), str(route["path"])),
        ),
        "operational_routes": sorted(
            (r for r in routes if not str(r["path"]).startswith(FROZEN_ROUTE_PREFIX)),
            key=lambda route: (str(route["method"]), str(route["path"])),
        ),
        "cli": read_cli(parse(root, CLI)),
        "providers": read_providers(config_tree),
        "config": read_config(config_tree),
    }


def counts(reading: dict[str, Any]) -> dict[str, int]:
    """The numbers the header line carries."""
    sections: list[dict[str, Any]] = reading["config"]["sections"]
    return {
        "tools": len(reading["tools"]),
        "rest_routes": len(reading["rest_routes"]),
        "operational_routes": len(reading["operational_routes"]),
        "cli_verbs": len(reading["cli"]["verbs"]),
        "server_flags": len(reading["cli"]["server_flags"]),
        "providers": len(reading["providers"]),
        "sections": len(sections),
        "section_keys": sum(len(section["keys"]) for section in sections),
        "per_provider_keys": len(reading["config"]["per_provider_keys"]),
        "top_level_keys": len(reading["config"]["top_level"]),
    }


def header(reading: dict[str, Any]) -> list[str]:
    """What the manifest says above the marker: how it was made, and what it holds."""
    tallies = counts(reading)
    return [
        "# The frozen surface, printed from the tree",
        "",
        "Generated by `tools/surface.py` from the source tree; not edited by hand.",
        "What it lists is the request side: the names a caller sends. The response",
        "models and the `Literal` vocabularies inside the tool arguments are named",
        "in [public-api.md](public-api.md), not here.",
        "Regenerate this file with `uv run python -m tools.surface > docs/reference/surface.md`.",
        "`uv run python -m tools.surface --check` re-reads the tree and prints the exact",
        "drift when this file no longer matches it, which is the CI step that keeps the",
        "v0.1.0 freeze boundary honest. It exits 1 when the body below",
        "the marker line has drifted or this file carries no marker line, and 2 only",
        "when this file is missing from the tree.",
        "",
        f"Printed from commit `{reading['commit']}` at `{reading['taken_at']}`.",
        "",
        (
            f"{tallies['tools']} MCP tools, {tallies['rest_routes']} REST routes, "
            f"{tallies['cli_verbs']} CLI verbs, {tallies['server_flags']} server flags, "
            f"{tallies['providers']} provider names, {tallies['section_keys']} section "
            f"config keys over {tallies['sections']} tables, "
            f"{tallies['per_provider_keys']} per-provider config keys, "
            f"{tallies['operational_routes']} operational routes."
        ),
        "",
        MARKER,
    ]


def entry(label: str) -> str:
    """One name, as a list item: the shape a drift shows up as in a diff."""
    return f"- `{label}`"


def render(reading: dict[str, Any]) -> list[str]:
    """The whole manifest: the header, then the body `--check` compares."""
    tallies = counts(reading)
    lines = header(reading) + [""]
    lines += [f"## MCP tools ({tallies['tools']})", ""]
    for tool in reading["tools"]:
        lines += [
            f"### `{tool['name']}` ({len(tool['arguments'])} arguments)",
            "",
            *(entry(argument) for argument in tool["arguments"]),
            "",
        ]
    lines += [f"## REST routes ({tallies['rest_routes']})", ""]
    for route in reading["rest_routes"]:
        lines += [
            (
                f"### `{route['method']} {route['path']}` "
                f"(`{route['request_model']}`, {len(route['body_keys'])} body keys)"
            ),
            "",
            *(entry(key) for key in route["body_keys"]),
            "",
        ]
    lines += [
        f"## Routes outside the frozen projection ({tallies['operational_routes']})",
        "",
        f"Registered by the same `custom_route` calls, not under `{FROZEN_ROUTE_PREFIX}`:",
        "",
    ]
    lines += [
        entry(f"{route['method']} {route['path']}") for route in reading["operational_routes"]
    ]
    lines += ["", f"## CLI verbs ({tallies['cli_verbs']})", ""]
    lines += [entry(verb) for verb in reading["cli"]["verbs"]]
    lines += ["", f"## Server flags ({tallies['server_flags']})", ""]
    lines += [entry(flag) for flag in reading["cli"]["server_flags"]]
    lines += ["", f"## Provider names ({tallies['providers']})", ""]
    lines += [entry(name) for name in reading["providers"]]
    lines += [
        "",
        (
            f"## Config sections ({tallies['section_keys']} keys over "
            f"{tallies['sections']} tables)"
        ),
        "",
    ]
    for section in reading["config"]["sections"]:
        lines += [
            f"### `[{section['table']}]` -- `{section['model']}` ({len(section['keys'])})",
            "",
            *(entry(key) for key in section["keys"]),
            "",
        ]
    lines += [
        (
            f"### Per-provider keys -- `{reading['config']['per_provider_model']}` "
            f"({tallies['per_provider_keys']})"
        ),
        "",
        *(entry(key) for key in reading["config"]["per_provider_keys"]),
        "",
        f"### Top-level keys -- `Config` ({tallies['top_level_keys']})",
        "",
        *(entry(key) for key in reading["config"]["top_level"]),
        "",
    ]
    # The manifest ends at its last name: a trailing separator moves on every
    # regeneration.
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def body_of(lines: list[str]) -> list[str]:
    """The lines below the marker: everything `--check` holds constant."""
    try:
        index = lines.index(MARKER)
    except ValueError:
        raise SystemExit(f"{MARKER} is missing: not a rendering made by this tool") from None
    body = lines[index + 1 :]
    # Trailing blank lines are not surface: an editor or a checkout that strips
    # them at EOF would otherwise read as drift.
    while body and not body[-1].strip():
        body.pop()
    return body


class Hunk(NamedTuple):
    """One `@@` block of a rendered diff: the header line as printed, the line it
    starts at on each side, and the lines under it."""

    header: str
    old_start: int
    new_start: int
    body: list[str]


def hunks(diff: list[str]) -> list[Hunk]:
    """Split a rendered unified diff into its hunks, dropping the file headers."""
    found: list[Hunk] = []
    for line in diff:
        match = HUNK_HEADER.match(line)
        if match:
            found.append(Hunk(line, int(match[1]), int(match[2]), []))
        elif found:
            found[-1].body.append(line)
    return found


def first_change(hunk: Hunk) -> tuple[int, bool]:
    """The 1-based line of a hunk's first change, and whether it is on the old side.

    A pure insertion has no old-side line, so it is located on the new side."""
    old, new = hunk.old_start, hunk.new_start
    for line in hunk.body:
        if line.startswith("+"):
            return new, False
        if line.startswith("-"):
            return old, True
        if not line.startswith("\\"):
            old += 1
            new += 1
    return old, True


def section_of(lines: list[str], line_number: int) -> str:
    """The last heading at or before a 1-based line of the manifest body.

    The heading is what a reviewer needs and a hunk does not carry: two lines of
    context rarely reach the `### `search`` line above them, so a bare
    `@@ -25,5 +25,5 @@` names a drifted argument without naming the tool, route
    or config table that owns it."""
    section = ""
    for line in lines[: max(line_number, 0)]:
        if line.startswith("#"):
            section = line
    return section or "(the top of the body)"


def drift(checked_in: list[str], printed: list[str]) -> list[str]:
    """The unified diff between the checked-in body and what the tree prints now.

    Each hunk is preceded by the heading its first change sits under, so the CI
    output says which section drifted as well as which line did."""
    diff = list(
        difflib.unified_diff(
            checked_in,
            printed,
            fromfile=f"{MANIFEST} (checked in)",
            tofile="the tree as it is now",
            lineterm="",
            n=CONTEXT_LINES,
        )
    )
    annotated: list[str] = []
    for line in diff:
        if HUNK_HEADER.match(line):
            break
        annotated.append(line)
    for hunk in hunks(diff):
        number, old_side = first_change(hunk)
        section = section_of(checked_in if old_side else printed, number)
        annotated += [f">> section: {section}", hunk.header, *hunk.body]
    return annotated


def check(manifest: Path, reading: dict[str, Any]) -> int:
    """Exit 0 when the tree still prints what is checked in, 1 with the drift."""
    try:
        checked_in = body_of(manifest.read_text(encoding="utf-8").splitlines())
    except OSError:
        print(f"no manifest at {manifest}: regenerate it (see the header of this tool)",
              file=sys.stderr)
        return 2
    changed = drift(checked_in, body_of(render(reading)))
    if changed:
        print(
            f"surface drift: the tree at {reading['commit']} does not match "
            f"{manifest}",
            file=sys.stderr,
        )
        print("\n".join(changed))
        print(
            f"{len([line for line in changed if line.startswith(('+', '-')) and not line.startswith(('+++', '---'))])}"
            " line(s) drifted; regenerate with "
            f"`uv run python -m tools.surface > {MANIFEST}`",
            file=sys.stderr,
        )
        return 1
    tallies = counts(reading)
    print(
        f"SURFACE OK: the tree at {reading['commit']} still prints the checked-in "
        f"surface ({tallies['tools']} tools, {tallies['rest_routes']} REST routes, "
        f"{tallies['cli_verbs']} verbs, {tallies['providers']} providers, "
        f"{tallies['section_keys']} + {tallies['per_provider_keys']} config keys)."
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=SUMMARY)
    parser.add_argument(
        "--json", action="store_true", help="print the reading as one JSON document"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help=f"exit non-zero, printing the exact drift, if the tree no longer matches {MANIFEST}",
    )
    parser.add_argument(
        "--manifest", default=MANIFEST, help="the checked-in rendering to check against"
    )
    args = parser.parse_args(argv)
    reading = read_surface(Path.cwd())
    if args.check:
        return check(Path(args.manifest), reading)
    if args.json:
        print(json.dumps(reading, indent=2, sort_keys=True))
        return 0
    print("\n".join(render(reading)))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
