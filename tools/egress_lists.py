"""The host lists the deployment dials against, printed out of the tree rather than from memory.

The proxy bounds *dispatch* and the network bounds *egress*, so the hosts a deployment
may reach live in the deployment -- a proxy configuration, not a config key. The half
that is not the operator's opinion is derivable: a `search` dials the endpoints the
adapters name, and a `fetch` dials through the endpoints the rows of
`fetcher.KNOWN_FALLBACKS` name. Written by hand those lists drift -- a provider lands,
the list does not move, and the deployment quietly refuses a working provider -- so this
tool reads them back out of `src/` and writes them, and `--check` fails the tree when a
checked-in copy has drifted.

Exit codes mirror `tools/surface.py`: 1 when a rendered list has drifted, 2 when a source
the census reads is missing or stops saying what the tool claims.

Three conventions the rendering depends on:

* Stdlib only, and no import of the package: `ast` reads the source text, where importing
  `config.py` would report what the interpreter resolved.
* Squid's file-form ACLs take one item per line and document no comment syntax, so the
  rendered files carry no comments; the prose lives in the `deploy/compose/egress/`
  files this tool reads.
* Hosts are sorted, so a new endpoint shows up as one added line at a known place.

What is deliberately absent: any list of hosts a *caller* may fetch. A `fetch` target is
arbitrary by design (`docs/reference/fetch-safety.md`); the lenient default is a
deny-list of sinks in `deploy/compose/egress/deny-hosts.txt`, the paranoid variant is
`deploy/compose/egress/fetch-allow-hosts.txt`, and `render` refuses one that has not
kept up with `fetcher.py`.

A fallback configured by URL is cross-checked in the operator's file rather than
rendered out of the config: that file can carry `fetch.crawl4ai_token`, and a census
reading a deployment's secrets is a wider surface than the line it saves. So
`fallback=<name> <host>` names the host the ladder dials for it and a bare
`fallback=<name>` says this deployment runs no such service; one answered nowhere fails
`--check`. The check proves every fallback the ladder walks is accounted for, not that
the answer matches the URL the config holds.
"""

from __future__ import annotations

import argparse
import ast
import difflib
import re
import sys
from pathlib import Path
from typing import NamedTuple
from urllib.parse import urlsplit

SUMMARY = "Print the deployment egress lists from the tree, or check them against it."
PROVIDERS_DIR = Path("src/seekwright/providers")
FETCHER = Path("src/seekwright/fetcher.py")
# The registry whose rows name the fallbacks a `fetch` ladder walks, and the constant each one dials.
FALLBACKS = "KNOWN_FALLBACKS"
HEALTH = Path("src/seekwright/health.py")
LISTS_DIR = Path("deploy/compose/egress")
GENERATED_DIR = Path("deploy/compose/generated")
CONTEXT_LINES = 2

# A module-level string constant ending this way is an endpoint the code dials, not a path or a
# marker: `CRAWL4AI_CRAWL_PATH` and `JINA_CONTENT_MARKER`, both in `fetcher.py`, fail this test and
# stay out of the lists.
ENDPOINT_CONSTANT = re.compile(r"(?:ENDPOINT|_URL)$")

# A host line in an operator list, in the spelling Squid's `dstdomain` reads: a leading dot matches
# that domain and every host under it, and a bare host matches that one host only. A URL here would
# match nothing forever, so it is refused rather than written out.
HOST_LINE = re.compile(r"^\.?[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$")

# A line of an operator list that answers for a fallback no constant names: `fallback=<name> <host>` names the host this
# deployment dials for it, and a bare `fallback=<name>` says this deployment runs no such service. `<name>` is the key
# of the row in `fetcher.KNOWN_FALLBACKS`, which is the only name a configured-by-URL fallback carries anywhere.
FALLBACK_CLAIM = re.compile(r"^fallback=([a-z][a-z0-9_-]*)(?:[ \t]+(\S+))?$")

# The two names with no endpoint constant to read, because their host comes from this deployment's
# config. Each row cites the code that derives the host, and `_require` below fails the tree when that
# code stops saying it, so a row cannot outlive the line it describes.
CONFIG_DERIVED: dict[str, tuple[str, ...]] = {
    # `https://{app_id}-dsn.algolia.net/1/indexes/{index}/query`, from health.py's probe builder: the
    # app id is the operator's, so the widest honest entry is the domain.
    "algolia": (".algolia.net",),
    # `config.providers["searxng"].url` -- an instance this repository has never seen a name for.
    # The operator names it in `deploy/compose/egress/deny-hosts.txt`'s sibling lists when they enable searxng.
    "searxng": (),
}
CITATIONS: dict[str, str] = {
    "algolia": "-dsn.algolia.net",
    "searxng": 'providers["searxng"].url',
}

SEARCH_ALLOW = "search-allow.txt"
FETCH_ALLOW = "fetch-allow.txt"
FETCH_DENY = "fetch-deny.txt"
GENERATED = {SEARCH_ALLOW: "providers", FETCH_ALLOW: "allow", FETCH_DENY: "deny"}


class EgressToolError(Exception):
    """The tree or an operator list says something this tool cannot render."""


class OperatorList(NamedTuple):
    """One operator file as this tool reads it: the hosts it names, and the fallbacks it answers for.

    `hosts` is every host in the file, including the one a `fallback=<name> <host>` line carries, because a
    fallback's host belongs to the allow-list like any other. `fallbacks` maps each fallback name answered there to the
    hosts named for it, and an empty set is the answer that this deployment runs no such service.
    """

    hosts: set[str]
    fallbacks: dict[str, set[str]]


class FallbackRead(NamedTuple):
    """`fetcher.KNOWN_FALLBACKS` as the census reads it: the hosts its rows dial, and the rows that name none.

    `configured` holds the key of every row declaring `endpoint=None`, the registry's own way of saying its
    host comes from this deployment's config. No reading of `src/` can name that host, so the operator's
    strict list has to answer for it.
    """

    hosts: set[str]
    configured: set[str]


def _assigned(node: ast.stmt) -> tuple[str, ast.expr | None] | None:
    """The name and the value of a plain assignment, `x = v` or `x: T = v`.

    Both forms are read on purpose. A reader that walked only `ast.Assign` would drop an annotated
    constant without a word, and `census` below would print a smaller count at rc 0.
    """
    if isinstance(node, ast.Assign):
        if len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
            return None
        return node.targets[0].id, node.value
    if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
        return node.target.id, node.value
    return None


def _keyword(call: ast.Call, arg: str) -> ast.expr | None:
    """The value of one keyword argument of a call, or None where it is not written."""
    for keyword in call.keywords:
        if keyword.arg == arg:
            return keyword.value
    return None


def _module(path: Path) -> ast.Module:
    """Parse one source the census reads.

    A file that stops parsing is a source that has moved, and it is named on one
    line with the exit code the gate reads: an uncaught `SyntaxError` here is a
    traceback that names neither the provider whose module it sits in nor the
    fallback whose registry it broke.
    """
    try:
        return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except SyntaxError as exc:
        raise EgressToolError(f"{path}:{exc.lineno} does not parse: {exc.msg}") from exc


def _constants(path: Path) -> dict[str, str]:
    """Module-level string constants of `path` whose name reads like an endpoint."""
    tree = _module(path)
    found: dict[str, str] = {}
    for node in tree.body:
        assigned = _assigned(node)
        if assigned is None or not ENDPOINT_CONSTANT.search(assigned[0]):
            continue
        value = assigned[1]
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            found[assigned[0]] = value.value
    return found


def _host(value: str, *, source: str) -> str:
    """The host an endpoint constant dials, or the domain a `CONFIG_DERIVED` row names."""
    if value.startswith("."):
        # A derived row names a domain whose host is the operator's, so no URL sits in front of it.
        if not HOST_LINE.match(value):
            raise EgressToolError(f"{source}: {value!r} is not a host line")
        return value
    parts = urlsplit(value)
    host = (parts.hostname or "").lower()
    if parts.scheme not in {"http", "https"} or not host:
        raise EgressToolError(f"{source}: {value!r} is not an http(s) endpoint")
    return host


def _class_names(path: Path) -> set[str]:
    """Provider names a module declares: every `name = "..."` on a class in it, annotated or not."""
    tree = _module(path)
    names: set[str] = set()
    for node in tree.body:
        if not isinstance(node, ast.ClassDef):
            continue
        for child in node.body:
            assigned = _assigned(child)
            if assigned is None or assigned[0] != "name":
                continue
            # A class attribute `name = "..."` is a provider name; anything else is a default.
            literal = getattr(assigned[1], "value", None)
            if isinstance(literal, str):
                names.add(literal)
    return names


def _require(name: str, source: Path) -> None:
    """Fail the tree when a `CONFIG_DERIVED` row's cited code stops saying what the row claims."""
    needle = CITATIONS[name]
    if needle not in source.read_text(encoding="utf-8"):
        raise EgressToolError(f"{source}: does not contain {needle!r}, which {name}'s derived host cites")


def provider_hosts() -> dict[str, set[str]]:
    """Provider name to the hosts that name can dial, read out of `providers/`."""
    hosts: dict[str, set[str]] = {}
    for path in sorted(PROVIDERS_DIR.glob("*.py")):
        names = _class_names(path)
        if not names:
            continue
        constants = _constants(path)
        for name in names:
            derived = CONFIG_DERIVED.get(name)
            if not constants and derived is None:
                raise EgressToolError(f"{path}: provider {name!r} dials no host this tool can read")
            if derived is not None:
                _require(name, HEALTH)
            endpoints = list(constants.values()) + list(derived or ())
            hosts[name] = {_host(url, source=f"{path}") for url in endpoints}
    if not hosts:
        raise EgressToolError(f"{PROVIDERS_DIR}: no provider module read")
    return hosts


def _fallback_rows() -> dict[str, ast.Call]:
    """The rows of `fetcher.KNOWN_FALLBACKS`, keyed by the name each is filed under."""
    tree = _module(FETCHER)
    for node in tree.body:
        assigned = _assigned(node)
        if assigned is None or assigned[0] != FALLBACKS:
            continue
        value = assigned[1]
        if not isinstance(value, ast.Dict):
            raise EgressToolError(f"{FETCHER}: {FALLBACKS} is not a literal mapping")
        rows: dict[str, ast.Call] = {}
        for key, row in zip(value.keys, value.values, strict=True):
            name = getattr(key, "value", None)
            if not isinstance(name, str) or not isinstance(row, ast.Call):
                raise EgressToolError(f"{FETCHER}: a {FALLBACKS} row is not a name keyed to a `Fallback(...)`")
            declared = getattr(_keyword(row, "name"), "value", None)
            if declared is not None and declared != name:
                raise EgressToolError(f"{FETCHER}: the {FALLBACKS} row keyed {name!r} declares name={declared!r}")
            rows[name] = row
        if not rows:
            raise EgressToolError(f"{FETCHER}: {FALLBACKS} holds no rows")
        return rows
    raise EgressToolError(f"{FETCHER}: no {FALLBACKS} read")


def _read_fallbacks() -> FallbackRead:
    """What `fetcher.KNOWN_FALLBACKS` dials, and which of its rows name no host to dial.

    A strict fetch policy that leaves one of these out does not narrow the tool, it breaks it: the
    ladder walks to a fallback the proxy refuses. `render` below refuses that, and the test runs it.

    Each row names the constant it dials, so a further fallback brings its own host rather than
    teaching this tool a vendor. `endpoint=None` is the honest answer for a fallback whose host this
    deployment writes in its own config: it is the host no reading of `src/` can name,
    and so the one the operator's strict list has to answer for. A row that declares no
    endpoint at all is a hole in the strict list, so the tree is refused rather than rendered
    around it.
    """
    constants = _constants(FETCHER)
    claimed: set[str] = set()
    hosts: set[str] = set()
    configured: set[str] = set()
    for name, row in _fallback_rows().items():
        endpoint = _keyword(row, "endpoint")
        if isinstance(endpoint, ast.Name):
            if endpoint.id not in constants:
                raise EgressToolError(
                    f"{FETCHER}: fallback {name!r} names {endpoint.id}, which is no module-level endpoint constant here"
                )
            claimed.add(endpoint.id)
            hosts.add(_host(constants[endpoint.id], source=f"{FETCHER}"))
        elif isinstance(endpoint, ast.Constant) and endpoint.value is None:
            configured.add(name)
        elif isinstance(endpoint, (ast.Constant, ast.JoinedStr, ast.Call)):
            # The likelier author mistake is a URL written into the row rather than named beside it, and it
            # reads differently: the host is dialled, it is just not readable out of a row of the registry.
            raise EgressToolError(
                f"{FETCHER}: fallback {name!r} writes its endpoint into the row instead of naming a "
                f"module-level constant, which is the form the census reads"
            )
        else:
            raise EgressToolError(
                f"{FETCHER}: fallback {name!r} declares no endpoint, so no list can carry the host it dials"
            )
    unclaimed = sorted(set(constants) - claimed)
    if unclaimed:
        raise EgressToolError(
            f"{FETCHER}: {', '.join(unclaimed)} is dialed by no {FALLBACKS} row, so no proxy list would name it"
        )
    return FallbackRead(hosts, configured)


def fallback_hosts() -> set[str]:
    """The hosts `fetch`'s own fallbacks dial, read from `fetcher.KNOWN_FALLBACKS`."""
    return _read_fallbacks().hosts


def configured_fallbacks() -> set[str]:
    """The fallbacks whose host this deployment writes in its own config, named as its own registry names them."""
    return _read_fallbacks().configured


def _operator_list(human: Path) -> OperatorList:
    """The operator's host list, comments and blanks dropped, every survivor validated.

    A `fallback=<name>` line is a survivor too, and is validated as a line of this file rather than as a host
    line: it carries a host only where one follows the name, and that host joins the list like any other.
    """
    if not human.is_file():
        raise EgressToolError(f"{human}: missing")
    entries: set[str] = set()
    fallbacks: dict[str, set[str]] = {}
    for number, raw in enumerate(human.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        claimed = FALLBACK_CLAIM.match(line)
        if claimed is not None:
            name, host = claimed.group(1), claimed.group(2)
            named_for = fallbacks.setdefault(name, set())
            if host is None:
                continue
            if not HOST_LINE.match(host):
                raise EgressToolError(f"{human}:{number}: {host!r} after `fallback={name}` is not a host line")
            entries.add(host)
            named_for.add(host)
            continue
        if not HOST_LINE.match(line):
            raise EgressToolError(f"{human}:{number}: {line!r} is not a host line")
        entries.add(line)
    return OperatorList(entries, fallbacks)


def render() -> dict[Path, str]:
    """Every generated file, keyed by path, as the bytes it should hold."""
    hosts: set[str] = set()
    for name_set in provider_hosts().values():
        hosts |= name_set
    allow_list = LISTS_DIR / "fetch-allow-hosts.txt"
    operator = _operator_list(allow_list)
    strict = operator.hosts
    fallbacks = _read_fallbacks()
    # Refusing a fallback the ladder still walks to turns a narrowing into an outage, so it is a hard error.
    missing = sorted(fallbacks.hosts - strict)
    if missing:
        raise EgressToolError(
            f"{allow_list} names no fallback: a strict policy that "
            f"omits {', '.join(missing)} breaks `fetch` rather than narrowing it"
        )
    # The other half of the same rule, read from the operator rather than from their config: a fallback whose
    # host only the deployment knows has to be answered for somewhere this tool can see.
    unanswered = sorted(fallbacks.configured - set(operator.fallbacks))
    if unanswered:
        raise EgressToolError(
            f"{allow_list} says nothing about {', '.join(unanswered)}, whose host no constant names: write "
            f"`fallback=<name> <host>` for the host this deployment dials, or `fallback=<name>` to say it runs none"
        )
    unfounded = sorted(set(operator.fallbacks) - fallbacks.configured)
    if unfounded:
        raise EgressToolError(
            f"{allow_list} answers for {', '.join(unfounded)}, which names its own host in a constant or is "
            f"no fallback this ladder walks, so the list has nothing to answer there"
        )

    rendered: dict[Path, str] = {
        GENERATED_DIR / SEARCH_ALLOW: "".join(f"{host}\n" for host in sorted(hosts)),
        GENERATED_DIR / FETCH_ALLOW: "".join(f"{host}\n" for host in sorted(strict)),
        GENERATED_DIR / FETCH_DENY: "".join(
            f"{host}\n" for host in sorted(_operator_list(LISTS_DIR / "deny-hosts.txt").hosts)
        ),
    }
    return rendered


def census() -> str:
    """One line naming what was read, so a census that shrinks is visible in `--check` output."""
    hosts = provider_hosts()
    named = {name for name in hosts if name in CONFIG_DERIVED}
    total = {host for group in hosts.values() for host in group}
    fallbacks = _read_fallbacks()
    return (
        f"egress lists ok: {len(hosts)} provider names read, "
        f"{len(total)} search-reachable hosts, "
        f"{len(named)} config-derived ({', '.join(sorted(named))}), "
        f"{len(fallbacks.hosts)} fetch fallback hosts, "
        f"{len(fallbacks.configured)} configured by URL ({', '.join(sorted(fallbacks.configured))})"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=SUMMARY)
    parser.add_argument("--write", action="store_true", help="write the generated files")
    parser.add_argument("--check", action="store_true", help="fail if the generated files have drifted")
    args = parser.parse_args(argv)

    for path in (PROVIDERS_DIR, FETCHER, HEALTH, LISTS_DIR):
        if not path.exists():
            print(f"egress lists: {path} is missing", file=sys.stderr)
            return 2
    try:
        rendered = render()
    except EgressToolError as exc:
        print(f"egress lists: {exc}", file=sys.stderr)
        return 2

    if args.write:
        for path, text in rendered.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        print(census())
        return 0

    if args.check:
        drifted = False
        for path, text in rendered.items():
            if not path.is_file():
                print(f"egress lists: {path} is missing", file=sys.stderr)
                drifted = True
                continue
            current = path.read_text(encoding="utf-8")
            if current == text:
                continue
            drifted = True
            print(f"DRIFT in {path}:", file=sys.stderr)
            sys.stderr.writelines(
                difflib.unified_diff(
                    current.splitlines(keepends=True),
                    text.splitlines(keepends=True),
                    fromfile=f"{path} (checked in)",
                    tofile=f"{path} (tree)",
                    n=CONTEXT_LINES,
                )
            )
        if drifted:
            print("egress lists: re-run `uv run python -m tools.egress_lists --write`", file=sys.stderr)
            return 1
        print(census())
        return 0

    for path, text in rendered.items():
        print(f"# {path}")
        sys.stdout.write(text)
    print(census())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
