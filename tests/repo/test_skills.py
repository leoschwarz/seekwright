"""The two skills under `skills/` stay adapters to the deployment, never a second one.

A skill is distributed away from this checkout: whatever installs it copies the
directory and nothing else, so the page carries the surface as prose and drifts the
moment the tree moves. That is the whole risk this file exists for, and each rule
answers one way the copy can go wrong. Rules 1 to 4 pin the *format* an Agent Skills
host reads -- the set of skills, the two-key frontmatter it parses without a YAML
dependency, the markdown-only rule that keeps deployment guidance a command a human
watches rather than a script it runs unattended, and the link rule, since a
directory copied elsewhere cannot resolve `../docs/…`. Rules 5 to 8 read the live
surface from `tools/surface.py` and refuse a name the tree no longer carries: a
flag, a route, a flavoured provider, an environment variable. A skill that tells an
agent to dial `/api/v2/search` or set a variable the config never reads is worse than
no skill, because the agent cannot tell the difference.

Rule 9 is the split itself. The request that produced these two files splits on who
holds what: a caller handed a URL is not handed the install path, and the skill that
person installs must never be able to walk it. The check is vocabulary, because that
is what is checkable -- the usage skill says "install nothing" in prose and carries
no command that installs, while every container, key and publish instruction lives on
one side of the directory boundary.

Style follows `tests/repo/test_doc_cites.py`: one scan rooted at one directory, a
failure that names the offending file and line, and a planted page proving the
patterns bite, since a guard over an empty population passes in silence.
"""

from __future__ import annotations

import importlib.util
import re
from pathlib import Path
from types import ModuleType
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SKILLS = ROOT / "skills"
PUBLIC_API = ROOT / "docs" / "reference" / "public-api.md"

# A third skill is a deliberate act, and naming it here is the act: the population
# rule is what stops the directory growing a third opinion about how to deploy.
SKILL_NAMES = {"seekwright", "seekwright-deploy"}

# The host's context budget, not a taste limit: the description sits in a host's
# context permanently, and the body is read only once the description has matched.
NAME_LIMIT = 64
DESCRIPTION_LIMIT = 1024
BODY_LIMIT = 150
FRONTMATTER_KEYS = {"name", "description"}
SKILL_SUFFIXES = {".md"}

# The vocabulary only `seekwright-deploy` may print. Each entry is a command, a flag
# or a variable, not a word: the usage skill has to be able to *say* "installs
# nothing" without carrying the command that installs it.
OPERATOR_ONLY = (
    "docker",
    "podman",
    "uv sync",
    "cp .env",
    "--host",
    "--allowed-host",
    "SEEKWRIGHT_PUBLISH",
    "API_KEY",
)

FENCE = re.compile(r"^\s*(?:```|~~~)")
INLINE_CODE = re.compile(r"`([^`\n]+)`")
FRONTMATTER_KEY = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*): (.+)$")
LONG_FLAG = re.compile(r"--[a-z][a-z0-9-]*")
ROUTE = re.compile(r"/(?:api/v1/[a-z0-9]+|healthz|dashboard(?:/[a-z0-9-]+)?)")
# A bare lower-case name carrying exactly one `:` is how a provider name is spelled,
# and a flavour that does not exist in `KNOWN_PROVIDERS` is invented prose. Host and
# port (`192.0.2.10:8000`) falls out on the leading digit, a URL on its slashes.
FLAVOURED_NAME = re.compile(r"[a-z][a-z0-9]*(?::[a-z][a-z0-9]*)?")
ENV_VAR = re.compile(r"SEEKWRIGHT_[A-Z0-9_]+")
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]*)")

# The environment a skill may name: read out of `src/`, the two Compose templates,
# and `docs/`. Anything else is a variable no code reads.
ENV_SOURCES: tuple[Path, ...] = (ROOT / "src", ROOT / "docs")
ENV_TEMPLATES: tuple[Path, ...] = (
    ROOT / "deploy" / "compose" / ".env.example",
    ROOT / "deploy" / "compose" / "search.env.example",
)


def _load_tool() -> ModuleType:
    """`tools/surface.py` as a module, without the repository root on `sys.path`."""
    spec = importlib.util.spec_from_file_location(
        "surface_tool", ROOT / "tools" / "surface.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


surface = _load_tool()


def _label(path: Path) -> str:
    """A path a reader can open from the repository root, or an absolute one."""
    return str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)


def _read(page: Path) -> list[str]:
    """A page as lines, the unit every failure names itself by."""
    return page.read_text(encoding="utf-8").splitlines()


def _skill_dirs() -> list[Path]:
    """The skill directories, sorted, so a failure names them in a stable order."""
    if not SKILLS.is_dir():
        return []
    return sorted(path for path in SKILLS.iterdir() if path.is_dir())


def _pages() -> list[Path]:
    """Every page under `skills/`."""
    return sorted(path for path in SKILLS.rglob("*.md") if path.is_file())


def _code_spans(lines: list[str]) -> list[tuple[int, str]]:
    """Every code span on a page, fenced or inline, with the line it starts on.

    The span, not the line, is the unit: `docker compose run --rm` and `curl -s` are
    real commands a skill has to print, and only the ones sharing a span with the
    word `seekwright` are claims about this tool's own surface.
    """
    spans: list[tuple[int, str]] = []
    opened: int | None = None
    body: list[str] = []
    for lineno, line in enumerate(lines, start=1):
        if FENCE.match(line):
            if opened is None:
                opened, body = lineno, []
            else:
                spans.append((opened, "\n".join(body)))
                opened = None
            continue
        if opened is not None:
            body.append(line)
            continue
        for match in INLINE_CODE.finditer(line):
            spans.append((lineno, match.group(1)))
    if opened is not None:
        spans.append((opened, "\n".join(body)))
    return spans


def _surface() -> dict[str, Any]:
    return surface.read_surface(ROOT)


def _env_names() -> set[str]:
    """Every `SEEKWRIGHT_*` the tree itself reads or advertises."""
    names: set[str] = set()
    for path in [*ENV_TEMPLATES, *(p for root in ENV_SOURCES for p in root.rglob("*"))]:
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        names.update(ENV_VAR.findall(text))
    return names


def _flag_offenders(
    page: Path, lines: list[str], flags: set[str], reference: str
) -> list[str]:
    """A long flag printed inside a `seekwright` span that the tree does not have."""
    found: list[str] = []
    for lineno, span in _code_spans(lines):
        if "seekwright" not in span.lower():
            continue
        for flag in LONG_FLAG.findall(span):
            if flag in flags or flag in reference:
                continue
            found.append(
                f"{_label(page)}:{lineno}: {flag} is printed as a seekwright flag and "
                "documented in neither surface.md's server flags nor public-api.md"
            )
    return found


def _route_offenders(page: Path, lines: list[str], paths: set[str]) -> list[str]:
    """A path a skill tells a caller to dial that no route registers."""
    found: list[str] = []
    for lineno, span in _code_spans(lines):
        for token in ROUTE.findall(span):
            if token in paths:
                continue
            found.append(
                f"{_label(page)}:{lineno}: {token} is named as a route; the tree "
                f"registers {', '.join(sorted(paths))}"
            )
    return found


def _provider_offenders(page: Path, lines: list[str], names: set[str]) -> list[str]:
    """A `backend:flavour` spelled out of nothing, such as an invented `exa:paid`."""
    found: list[str] = []
    for lineno, span in _code_spans(lines):
        if ":" not in span or not FLAVOURED_NAME.fullmatch(span):
            continue
        if span in names:
            continue
        found.append(
            f"{_label(page)}:{lineno}: {span} is not a provider name the tree knows"
        )
    return found


def _env_offenders(page: Path, lines: list[str], known: set[str]) -> list[str]:
    """An environment variable no code in this tree reads."""
    found: list[str] = []
    for lineno, line in enumerate(lines, start=1):
        for token in ENV_VAR.findall(line):
            if token in known:
                continue
            found.append(
                f"{_label(page)}:{lineno}: {token} is set nowhere in src/, the Compose "
                "env templates, or docs/"
            )
    return found


def _link_offenders(page: Path, lines: list[str]) -> list[str]:
    """A link that leaves the skill directory the page ships in.

    The directory is the unit of distribution, so a relative target has to resolve
    inside it and exist; `https://` and a bare anchor are the only escapes, and a
    pointer to this repository belongs in prose, not in link syntax.
    """
    found: list[str] = []
    home = page.parent.resolve()
    for lineno, line in enumerate(lines, start=1):
        for target in LINK.findall(line):
            if target.startswith(("http://", "https://", "#")):
                continue
            parts = Path(target).parts
            if target.startswith("/") or ".." in parts or parts[:1] == ("docs",):
                found.append(
                    f"{_label(page)}:{lineno}: {target} reaches outside the skill "
                    "directory; name the path in prose instead of linking to it"
                )
                continue
            resolved = (page.parent / target).resolve()
            if not resolved.is_relative_to(home):
                found.append(
                    f"{_label(page)}:{lineno}: {target} resolves outside the skill "
                    "directory"
                )
            elif not resolved.exists():
                found.append(
                    f"{_label(page)}:{lineno}: {target} is a link to a file that is "
                    "not in the skill directory"
                )
    return found


def _grant_offenders(page: Path, lines: list[str]) -> list[str]:
    """Install, configuration and key vocabulary in the skill that only calls."""
    found: list[str] = []
    for lineno, line in enumerate(lines, start=1):
        for term in OPERATOR_ONLY:
            if term in line:
                found.append(
                    f"{_label(page)}:{lineno}: {term!r} belongs to the operator skill; "
                    f"a caller handed a URL is not handed the install path: {line.strip()}"
                )
    return found


def test_the_skill_set_is_exactly_the_two_shipped_skills() -> None:
    """`skills/` holds one usage skill and one operator skill, and no third opinion."""
    assert SKILLS.is_dir(), "there is no skills/ directory"
    found = {path.name for path in _skill_dirs()}
    assert found == SKILL_NAMES, (
        f"skills/ holds {sorted(found)}; the two-skill split is the design, so a third "
        "skill is an edit to this list as well as to the tree"
    )


def test_each_skill_directory_holds_one_two_key_page() -> None:
    """The frontmatter the host parses without a YAML dependency, and a bounded body.

    Two single-line keys, `name` matching the directory, and a body short enough to
    be a runbook rather than a second copy of the reference pages: the description is
    what sits permanently in a host's context, and the body is only read once the
    description has matched.
    """
    dirs = _skill_dirs()
    assert dirs, "no skill directory under skills/"
    offenders: list[str] = []
    for directory in dirs:
        page = directory / "SKILL.md"
        if not page.is_file():
            offenders.append(f"{_label(page)}:1: a skill directory with no SKILL.md")
            continue
        lines = page.read_text(encoding="utf-8").splitlines()
        if lines[:1] != ["---"]:
            offenders.append(f"{_label(page)}:1: the page does not open with `---`")
            continue
        closing = next((i for i in range(1, len(lines)) if lines[i] == "---"), None)
        if closing is None:
            offenders.append(f"{_label(page)}:1: the frontmatter fence is never closed")
            continue
        fields: dict[str, str] = {}
        for index in range(1, closing):
            line = lines[index]
            match = FRONTMATTER_KEY.match(line)
            if match is None:
                offenders.append(
                    f"{_label(page)}:{index + 1}: {line.strip()} is not a single-line "
                    "`key: value` frontmatter entry"
                )
                continue
            key, value = match.groups()
            if key not in FRONTMATTER_KEYS:
                offenders.append(
                    f"{_label(page)}:{index + 1}: {key!r} is not one of the two keys"
                )
            if value.startswith((">", "|")):
                offenders.append(
                    f"{_label(page)}:{index + 1}: {key} is a multi-line scalar, which "
                    "the host's parser and this guard both refuse"
                )
            fields[key] = value
        if set(fields) != FRONTMATTER_KEYS:
            offenders.append(
                f"{_label(page)}:1: frontmatter carries {sorted(fields)}, not exactly "
                f"{sorted(FRONTMATTER_KEYS)}"
            )
        name = fields.get("name", "")
        if name != directory.name:
            offenders.append(
                f"{_label(page)}:1: name {name!r} does not match the directory "
                f"{directory.name!r}"
            )
        if len(name) > NAME_LIMIT:
            offenders.append(f"{_label(page)}:1: name exceeds {NAME_LIMIT} characters")
        description = fields.get("description", "")
        if len(description) > DESCRIPTION_LIMIT:
            offenders.append(
                f"{_label(page)}:2: description exceeds {DESCRIPTION_LIMIT} characters"
            )
        body = lines[closing + 1 :]
        if len(body) > BODY_LIMIT:
            offenders.append(
                f"{_label(page)}:{closing + 2}: the body is {len(body)} lines, over the "
                f"{BODY_LIMIT} a runbook gets"
            )
    assert not offenders, "\n".join(offenders)


def test_a_skill_carries_markdown_and_nothing_else() -> None:
    """Commands a human watches run, not a script an agent runs unattended.

    The blast radius of a bundled script is the operator's machine, and every command
    these pages print already exists as a documented one-liner.
    """
    extra = sorted(
        _label(path)
        for path in SKILLS.rglob("*")
        if path.is_file() and path.suffix not in SKILL_SUFFIXES
    )
    assert not extra, f"skills/ carries non-markdown files: {extra}"


def test_no_link_in_a_skill_page_reaches_outside_its_directory() -> None:
    """A skill directory is copied on its own, so every link has to land inside it."""
    pages = _pages()
    assert pages, "no pages under skills/"
    offenders = [o for page in pages for o in _link_offenders(page, _read(page))]
    assert not offenders, "\n".join(offenders)


def test_every_flag_a_skill_prints_is_a_documented_flag() -> None:
    """A flag in a `seekwright` span is a claim about the frozen surface.

    `tools/surface.py` prints the server flags; `public-api.md` is the source for the
    client verbs' flags, which the instrument does not print. The span filter is what
    keeps `docker compose run --rm` out of the assertion.
    """
    flags = set(_surface()["cli"]["server_flags"])
    reference = PUBLIC_API.read_text(encoding="utf-8")
    offenders = [o for page in _pages() for o in _flag_offenders(page, _read(page), flags, reference)]
    printed = [
        flag
        for page in _pages()
        for _, span in _code_spans(_read(page))
        if "seekwright" in span.lower()
        for flag in LONG_FLAG.findall(span)
    ]
    assert printed, "no skill prints a seekwright flag, so this guard checks nothing"
    assert not offenders, "\n".join(offenders)


def test_every_route_a_skill_names_is_a_route_the_tree_registers() -> None:
    """`/api/v1/…`, `/healthz` and `/dashboard` are read from the live surface."""
    paths = {
        str(route["path"])
        for route in [*_surface()["rest_routes"], *_surface()["operational_routes"]]
    }
    offenders = [o for page in _pages() for o in _route_offenders(page, _read(page), paths)]
    named = [
        token
        for page in _pages()
        for _, span in _code_spans(_read(page))
        for token in ROUTE.findall(span)
    ]
    assert named, "no skill names a route, so this guard checks nothing"
    assert not offenders, "\n".join(offenders)


def test_every_flavoured_provider_name_a_skill_prints_is_a_real_name() -> None:
    """A flavour is only ever a half of a backend that exists, so `exa:paid` is invented."""
    names = set(_surface()["providers"])
    offenders = [
        o for page in _pages() for o in _provider_offenders(page, _read(page), names)
    ]
    printed = [
        span
        for page in _pages()
        for _, span in _code_spans(_read(page))
        if ":" in span and FLAVOURED_NAME.fullmatch(span)
    ]
    assert printed, "no skill prints a flavoured provider name, so this guard checks nothing"
    assert not offenders, "\n".join(offenders)


def test_every_environment_variable_a_skill_sets_exists() -> None:
    """A variable the tree does not read is a skill that tells an operator to do nothing."""
    known = _env_names()
    offenders = [o for page in _pages() for o in _env_offenders(page, _read(page), known)]
    named = [token for page in _pages() for token in ENV_VAR.findall("\n".join(_read(page)))]
    assert named, "no skill names an environment variable, so this guard checks nothing"
    assert not offenders, "\n".join(offenders)


def test_the_usage_skill_never_walks_the_operator_path() -> None:
    """The machine-checked form of the two-skill split.

    Whoever is handed a listener URL is not handed the install path, the keys, or the
    address to publish on: the usage skill refuses that in prose, and this refuses it
    in vocabulary, because prose rots and a string does not.
    """
    usage = SKILLS / "seekwright"
    pages = sorted(path for path in usage.rglob("*.md") if path.is_file())
    assert pages, f"{_label(usage)} holds no page"
    offenders = [o for page in pages for o in _grant_offenders(page, _read(page))]
    assert not offenders, "\n".join(offenders)


def test_the_patterns_refuse_each_drift_shape_and_keep_the_neighbours() -> None:
    """A guard over two files is a guard over two files: the bite is planted and proven.

    Each shape is one the tree can plausibly acquire -- a renamed flag, a route the
    version moved off, an invented flavour, a variable the config never reads, a
    pointer to a page that stopped shipping -- alongside the legal neighbour a real
    page has to keep.
    """
    page = SKILLS / "planted.md"
    # The planted page sits at `skills/`, so its link home is `skills/` itself: the
    # legal relative target is a file that is really there.
    lines = [
        (
            "Run `uv run seekwright --check`; never ask for `uv run seekwright "
            "--allow-host 127.0.0.1`, POST to `/api/v1/serp` instead of `/healthz`, "
            "and name `exa:paid` beside the real `exa:free`."
        ),
        (
            "Set `SEEKWRIGHT_BILLING_KEY`, run `docker compose up -d`, and read "
            "[the guide](../docs/index.md) or [the page](docs/reference/container.md)."
        ),
        (
            "[the real page](seekwright/SKILL.md) and [the site]"
            "(https://example.com/) and [the anchor](#top) all stay legal."
        ),
    ]

    flags = set(_surface()["cli"]["server_flags"])
    reference = PUBLIC_API.read_text(encoding="utf-8")
    drifted_flags = _flag_offenders(page, lines, flags, reference)
    assert len(drifted_flags) == 1 and "--allow-host" in drifted_flags[0], drifted_flags

    routes = {
        str(route["path"])
        for route in [*_surface()["rest_routes"], *_surface()["operational_routes"]]
    }
    drifted_routes = _route_offenders(page, lines, routes)
    assert len(drifted_routes) == 1 and "/api/v1/serp" in drifted_routes[0], drifted_routes

    names = set(_surface()["providers"])
    drifted_providers = _provider_offenders(page, lines, names)
    assert len(drifted_providers) == 1 and "exa:paid" in drifted_providers[0], (
        drifted_providers
    )

    drifted_env = _env_offenders(page, lines, _env_names())
    assert len(drifted_env) == 1 and "SEEKWRIGHT_BILLING_KEY" in drifted_env[0], (
        drifted_env
    )

    drifted_grants = _grant_offenders(page, lines)
    assert len(drifted_grants) == 1 and "docker" in drifted_grants[0], drifted_grants

    drifted_links = _link_offenders(page, lines)
    assert len(drifted_links) == 2, drifted_links
    assert any("../docs/index.md" in o for o in drifted_links), drifted_links
    assert any("docs/reference/container.md" in o for o in drifted_links), drifted_links

