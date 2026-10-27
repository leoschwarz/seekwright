"""The egress bundle stays one bundle: a rendered list, a mount and a proxy rule that agree.

The lists that bound egress live outside the app on purpose -- the proxy bounds dispatch
and the network bounds egress -- and that placement is what lets them come apart: a
provider lands, its host never joins `deploy/compose/generated/search-allow.txt`, and the
search container answers `TCP_DENIED/503`. A stale mount shows up at `docker compose up`,
not at review. The bundle is four artifacts -- a generated list, a proxy config, a
compose mount and a role config -- and this file keeps them naming the same things.

The checks belonging to `tools/egress_lists.py` run through the tool: `--check` exits 1
when a rendered list no longer matches what `src/` dials and 2 when a source the census
reads has moved, including a strict fetch list behind `fetcher.py` or answering for none
of the fallbacks whose host the deployment configures by URL. The census gets two checks
of its own, because a provider name the reader cannot parse only shrinks the printed
count, at rc 0. Those two load the tool by path, the way `tests/repo/test_surface.py`
loads its own -- `testpaths` is `tests`, so a bare `pytest` run has no repository root on
`sys.path`.

This file reads the index rather than the working tree: `deploy/` is gitignored except
for one subtree, so a bundle outside `deploy/compose/` exists on one laptop and in no
clone. The reverse is checked too: the exception stays one subtree.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "deploy" / "compose"
LISTS = BUNDLE / "egress"
GENERATED = BUNDLE / "generated"
SQUID = BUNDLE / "squid"
COREDNS = BUNDLE / "coredns"
COMPOSE = BUNDLE / "compose.yaml"
# The published image both roles run; the tag is the release, and a local build replaces it.
IMAGE = "ghcr.io/leoschwarz/seekwright:${SEEKWRIGHT_TAG:-v0.1.0}"

# Every path the bundle needs in a clone, named exactly once here; `.gitignore` names the subtree once.
TRACKED = (
    "deploy/compose/.env.example",
    "deploy/compose/compose.yaml",
    "deploy/compose/coredns/Corefile",
    "deploy/compose/fetch.toml",
    "deploy/compose/search.env.example",
    "deploy/compose/search.toml",
    "deploy/compose/egress/deny-hosts.txt",
    "deploy/compose/egress/fetch-allow-hosts.txt",
    "deploy/compose/generated/fetch-allow.txt",
    "deploy/compose/generated/fetch-deny.txt",
    "deploy/compose/generated/search-allow.txt",
    "deploy/compose/squid/fetch-lenient.conf",
    "deploy/compose/squid/fetch-strict.conf",
    "deploy/compose/squid/search-allow.conf",
)

GENERATED_LISTS = ("search-allow.txt", "fetch-deny.txt", "fetch-allow.txt")

# The frozen surface, printed by `tools/surface.py`: the provider set the request side publishes.
MANIFEST = ROOT / "docs" / "reference" / "surface.md"
PROVIDER_SECTION = "## Provider names ("


def _load_tool() -> ModuleType:
    """`tools/egress_lists.py` as a module, without the repository root on `sys.path`."""
    spec = importlib.util.spec_from_file_location("egress_lists_tool", ROOT / "tools" / "egress_lists.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


egress = _load_tool()


def read(path: Path) -> str:
    """A bundle file, or a failure that names the path rather than an empty string."""
    assert path.is_file(), f"{path.relative_to(ROOT)} is missing from the tree"
    return path.read_text(encoding="utf-8")


def test_the_generated_lists_match_the_tree() -> None:
    """`--check` is green, so every rendered host still names something `src/` dials.

    The one check that catches a provider landing without its host joining the proxy's allow-list.
    """
    done = subprocess.run(
        [sys.executable, "-m", "tools.egress_lists", "--check"],
        capture_output=True,
        text=True,
        check=False,
        cwd=ROOT,
    )
    assert done.returncode == 0, f"--check exited {done.returncode}: {done.stdout.strip()} {done.stderr.strip()}"


def test_the_strict_fetch_list_carries_the_keyed_fallbacks() -> None:
    """A strict list that leaves a fallback out does not narrow `fetch`, it outages it.

    The two keyed fallbacks dial hosts that are also search-provider hosts, so
    the easy mistake is to let them follow the providers off the list. `render` refuses
    to render a strict list that omits a fallback host (exit 2), and the ladder would walk
    to a fallback the proxy answers `TCP_DENIED/503`.
    """
    constants = egress._constants(egress.FETCHER)
    assert constants["TAVILY_EXTRACT_ENDPOINT"] == "https://api.tavily.com/extract"
    assert constants["LINKUP_FETCH_ENDPOINT"] == "https://api.linkup.so/v1/fetch"

    fallbacks = egress.fallback_hosts()
    assert {"api.tavily.com", "api.linkup.so"} <= fallbacks, f"fallback hosts read: {sorted(fallbacks)}"

    strict = {line.strip() for line in read(GENERATED / "fetch-allow.txt").splitlines()}
    missing = sorted(fallbacks - strict)
    assert not missing, f"generated fetch-allow.txt omits {missing}"


# A provider module and a fetcher written in the annotated form: name and endpoint each carry a type, and
# the path constant has to stay out of the read whichever form it is written in.
ANNOTATED_PROVIDER = """
from typing import ClassVar, Final

ENDPOINT: Final[str] = "https://api.annotated.example/v1/search"
CRAWL_PATH: Final[str] = "/crawl"


class AnnotatedProvider:
    name: ClassVar[str] = "annotated"
"""

ANNOTATED_FETCHER = """
from typing import Final

SCRAPPA_SCRAPER_ENDPOINT: Final[str] = "https://scrappa.example/api/web-scraper"
CRAWL4AI_CRAWL_PATH: Final[str] = "/crawl"
JINA_READER_ENDPOINT: Final[str] = "https://r.jina.example/"

KNOWN_FALLBACKS: dict[str, Fallback] = {
    "crawl4ai": Fallback(name="crawl4ai", billable=False, endpoint=None, build=_build_crawl4ai),
    "jina": Fallback(name="jina", billable=False, endpoint=JINA_READER_ENDPOINT, build=_build_jina),
    "scrappa": Fallback(name="scrappa", billable=True, endpoint=SCRAPPA_SCRAPER_ENDPOINT, build=_build_scrappa),
}
"""

# A fallback row that names no constant at all, and a constant no row names: either one leaves a host the
# strict fetch policy would omit, so the reader has to refuse the tree instead of rendering around it.
FALLBACK_WITHOUT_AN_ENDPOINT = """
JINA_READER_ENDPOINT: Final[str] = "https://r.jina.example/"

KNOWN_FALLBACKS: dict[str, Fallback] = {
    "jina": Fallback(name="jina", billable=False, build=_build_jina),
}
"""

FALLBACK_ROW_NAMING_A_MISSING_CONSTANT = """
LINKUP_FETCH_ENDPOINT: Final[str] = "https://api.linkup.example/v1/fetch"

KNOWN_FALLBACKS: dict[str, Fallback] = {
    "linkup": Fallback(name="linkup", billable=True, endpoint=LINKUP_FETCH_URL, build=_build_linkup),
}
"""


def test_the_reader_reads_annotated_names_and_endpoints(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`name: ClassVar[str] = "..."` is a provider name and `ENDPOINT: Final[str] = "https://..."` is an
    endpoint, and both are read.

    An earlier QA reading measured the reader walking only `ast.Assign`: a module written in the
    annotated form was skipped outright -- no name read, so no row -- and the printed census simply came
    out smaller, at rc 0. A path constant stays out of the list in either form.
    """
    providers = tmp_path / "providers"
    providers.mkdir()
    (providers / "annotated.py").write_text(ANNOTATED_PROVIDER.lstrip(), encoding="utf-8")
    fetcher = tmp_path / "fetcher.py"
    fetcher.write_text(ANNOTATED_FETCHER.lstrip(), encoding="utf-8")
    monkeypatch.setattr(egress, "PROVIDERS_DIR", providers)
    monkeypatch.setattr(egress, "FETCHER", fetcher)
    assert egress.provider_hosts() == {"annotated": {"api.annotated.example"}}
    assert egress.fallback_hosts() == {"r.jina.example", "scrappa.example"}


UNCLAIMED_ENDPOINT_CONSTANT = """
TAVILY_EXTRACT_ENDPOINT: Final[str] = "https://api.tavily.example/extract"

KNOWN_FALLBACKS: dict[str, Fallback] = {
    "crawl4ai": Fallback(name="crawl4ai", billable=False, endpoint=None, build=_build_crawl4ai),
}
"""


FALLBACK_WITH_AN_INLINE_URL = """
KNOWN_FALLBACKS: dict[str, Fallback] = {
    "linkup": Fallback(name="linkup", billable=True, endpoint="https://api.linkup.example/v1/fetch", build=_build_linkup),
}
"""


@pytest.mark.parametrize(
    ("source", "refusal"),
    [
        (FALLBACK_WITHOUT_AN_ENDPOINT, "declares no endpoint"),
        (FALLBACK_WITH_AN_INLINE_URL, "instead of naming a module-level constant"),
        (FALLBACK_ROW_NAMING_A_MISSING_CONSTANT, "no module-level endpoint constant"),
        (UNCLAIMED_ENDPOINT_CONSTANT, "dialed by no KNOWN_FALLBACKS row"),
    ],
    ids=["row-without-an-endpoint", "row-with-an-inline-url", "row-naming-nothing", "constant-no-row-claims"],
)
def test_a_registry_that_cannot_account_for_a_dialled_host_is_refused(
    source: str, refusal: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Each way the fallback registry can lose sight of a host is a refusal, not a shorter list.

    The strict fetch policy is rendered from these rows, so a fallback the reader has no host for is a
    ladder step the proxy would refuse: the failure this tool exists to catch, arriving as a
    red check instead of as a `TCP_DENIED` at fetch time.
    """
    fetcher = tmp_path / "fetcher.py"
    fetcher.write_text(source.lstrip(), encoding="utf-8")
    monkeypatch.setattr(egress, "FETCHER", fetcher)
    with pytest.raises(egress.EgressToolError, match=refusal):
        egress.fallback_hosts()


# The operator's strict fetch list, in the four shapes the configured-by-URL rule meets. The host of the
# `crawl4ai` fallback is `fetch.crawl4ai_url`, which no reading of `src/` can name, so this file is the only
# place it can be answered for.
OPERATOR_LIST_WITH_A_HOST = """
# this deployment's own renderer
fallback=crawl4ai renderer.internal.example
r.jina.example
scrappa.example
"""

OPERATOR_LIST_WITH_A_BARE_DECLARATION = """
fallback=crawl4ai
r.jina.example
scrappa.example
"""

OPERATOR_LIST_THAT_SAYS_NOTHING = """
r.jina.example
scrappa.example
"""

OPERATOR_LIST_ANSWERING_FOR_THE_WRONG_FALLBACK = """
fallback=jina mirror.jina.example
fallback=crawl4ai renderer.internal.example
r.jina.example
scrappa.example
"""


def _strict_fixture(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, allow_list: str) -> None:
    """A tree the tool can render from, with one operator allow-list written by hand.

    The tool reads module-level paths, so the fixture moves them rather than writing outside `tmp_path`.
    """
    providers = tmp_path / "providers"
    providers.mkdir()
    (providers / "annotated.py").write_text(ANNOTATED_PROVIDER.lstrip(), encoding="utf-8")
    (tmp_path / "health.py").write_text("", encoding="utf-8")
    (tmp_path / "fetcher.py").write_text(ANNOTATED_FETCHER.lstrip(), encoding="utf-8")
    lists = tmp_path / "egress"
    lists.mkdir()
    (lists / "fetch-allow-hosts.txt").write_text(allow_list.lstrip(), encoding="utf-8")
    (lists / "deny-hosts.txt").write_text("sink.example\n", encoding="utf-8")
    monkeypatch.setattr(egress, "PROVIDERS_DIR", providers)
    monkeypatch.setattr(egress, "FETCHER", tmp_path / "fetcher.py")
    monkeypatch.setattr(egress, "HEALTH", tmp_path / "health.py")
    monkeypatch.setattr(egress, "LISTS_DIR", lists)
    monkeypatch.setattr(egress, "GENERATED_DIR", tmp_path / "generated")


@pytest.mark.parametrize(
    ("allow_list", "refusal"),
    [
        (OPERATOR_LIST_THAT_SAYS_NOTHING, "says nothing about crawl4ai"),
        (OPERATOR_LIST_ANSWERING_FOR_THE_WRONG_FALLBACK, "no fallback this ladder walks"),
    ],
    ids=["fallback-answered-nowhere", "fallback-answered-for-the-wrong-name"],
)
def test_a_strict_list_that_does_not_answer_for_a_configured_by_url_fallback_is_refused(
    allow_list: str, refusal: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A ladder step whose host the deployment writes in its own config has to be answered for in this file.

    That fallback is the one the census cannot supply: `crawl4ai` dials `fetch.crawl4ai_url`, and the file holding
    that key can hold `fetch.crawl4ai_token`, so the tool reads the operator's answer instead of opening the
    deployment's config. An unanswered fallback is the outage this tool guards against -- the ladder walks to a
    proxy that refuses it -- and an answer written for a fallback a constant names is a list overruling the code.
    """
    _strict_fixture(tmp_path, monkeypatch, allow_list)
    with pytest.raises(egress.EgressToolError, match=refusal):
        egress.render()


def test_a_host_an_operator_configures_by_url_lands_in_the_rendered_allow_list(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`fallback=<name> <host>` is not a note beside the list: the host it names is rendered into it."""
    _strict_fixture(tmp_path, monkeypatch, OPERATOR_LIST_WITH_A_HOST)
    rendered = egress.render()[egress.GENERATED_DIR / egress.FETCH_ALLOW]
    assert rendered == "r.jina.example\nrenderer.internal.example\nscrappa.example\n"


def test_a_bare_fallback_line_answers_for_a_fallback_without_naming_a_host(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`fallback=crawl4ai` alone clears the check and adds nothing: it says this deployment runs no renderer.

    The shipped bundle carries that form, because `deploy/compose/fetch.toml` names no `fetch.crawl4ai_url`.
    """
    _strict_fixture(tmp_path, monkeypatch, OPERATOR_LIST_WITH_A_BARE_DECLARATION)
    rendered = egress.render()[egress.GENERATED_DIR / egress.FETCH_ALLOW]
    assert rendered == "r.jina.example\nscrappa.example\n"


def test_the_shipped_strict_list_answers_for_every_fallback_no_constant_names() -> None:
    """The rule above holds for the bundle in the tree, where the fallbacks are the real ones.

    `--check` exiting 0 already fails this bundle if the answer is dropped; this says which rule that 0
    covers, and names the fallback when the answer goes missing.
    """
    answered = egress._operator_list(egress.LISTS_DIR / "fetch-allow-hosts.txt").fallbacks
    unaccounted = sorted(egress.configured_fallbacks() - set(answered))
    assert not unaccounted, (
        f"these fallbacks dial a host no constant names, and the operator's list answers for none of them: "
        f"{unaccounted}"
    )


def test_a_source_that_does_not_parse_is_named_and_not_traced(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A source the census reads that stops parsing is refused with the file and the line.

    The reading is of source text, so a file that does not parse is a source that moved: it gets the
    same one-line refusal every unreadable source gets, naming where it sits, because a traceback
    names no provider and no fallback for the operator whose list is now unmaintainable.
    """
    _strict_fixture(tmp_path, monkeypatch, OPERATOR_LIST_WITH_A_BARE_DECLARATION)
    (tmp_path / "fetcher.py").write_text('KNOWN_FALLBACKS = {"jina": Fallback(\n', encoding="utf-8")

    with pytest.raises(egress.EgressToolError, match="does not parse") as caught:
        egress.render()
    assert "fetcher.py:1" in str(caught.value), str(caught.value)


def test_the_census_reads_exactly_the_provider_set_the_manifest_publishes(
    monkeypatch: pytest.MonkeyPatch
) -> None:
    """The two tools that read the provider set out of `src/` agree on it.

    `docs/reference/surface.md` is the frozen surface, printed by `tools/surface.py`. A name the egress
    reader cannot parse is a name whose host no proxy allow-list can carry, and `--check` says nothing
    about it, so the two readings are compared here. The manifest writes a free tier as its own name
    (`exa:free`), which is one module, so the tiers are folded before the comparison.
    """
    monkeypatch.setattr(egress, "PROVIDERS_DIR", ROOT / "src" / "seekwright" / "providers")
    body = read(MANIFEST)
    assert PROVIDER_SECTION in body, f"{MANIFEST.relative_to(ROOT)} holds no provider-name section"
    section = body.split(PROVIDER_SECTION, 1)[1].split("\n## ", 1)[0]
    published: set[str] = set()
    for line in section.splitlines():
        if line.startswith("- `"):
            published.add(line.removeprefix("- `").removesuffix("`").split(":", 1)[0])
    read_names = set(egress.provider_hosts())
    assert published == read_names, (
        f"the manifest publishes {sorted(published - read_names)}, which the egress census does not read; "
        f"the census reads {sorted(read_names - published)}, which the manifest does not publish"
    )


def test_the_whole_bundle_is_tracked() -> None:
    """Every bundle path is in the index, `deploy/` being gitignored around it.

    Both directions: `deploy/compose/` is the one public subtree, so a snapshot committed under a name
    the gitignore does not predict is a tracked file in every clone.
    """
    done = subprocess.run(
        ["git", "ls-files", "deploy"], capture_output=True, text=True, check=False, cwd=ROOT
    )
    assert done.returncode == 0, done.stderr.strip()
    tracked = {line.strip() for line in done.stdout.splitlines() if line.strip()}
    missing = sorted(path for path in TRACKED if path not in tracked)
    assert not missing, f"these egress bundle paths are not tracked: {missing}"
    extra = sorted(tracked - set(TRACKED))
    assert not extra, (
        f"these paths are tracked inside the one public subtree under `deploy/`, which the exception "
        f"`!deploy/compose/` opens and an operator's own values must not land in: {extra}"
    )


def test_every_generated_list_is_read_by_a_proxy_and_mounted() -> None:
    """Each rendered list is named by a Squid config, and each name a config reads exists.

    Squid's file-form ACL takes a path, so a rename on one side of it fails at proxy start rather than
    at review, which is the half a generated file cannot check for itself.
    """
    named: set[str] = set()
    for conf in sorted(SQUID.glob("*.conf")):
        named |= set(re.findall(r"dstdomain /etc/squid/lists/([A-Za-z0-9._-]+)", read(conf)))
    unread = sorted(named - set(GENERATED_LISTS))
    assert not unread, f"these Squid configs read a list the tree does not render: {unread}"
    unused = sorted(set(GENERATED_LISTS) - named)
    assert not unused, f"these rendered lists are read by no proxy config: {unused}"
    compose = read(COMPOSE)
    for name in named:
        assert (GENERATED / name).is_file(), f"{GENERATED / name} is read by a proxy and missing"
    assert "./generated:/etc/squid/lists:ro" in compose, (
        "compose must mount deploy/compose/generated where the proxy configs read it"
    )


def test_the_two_roles_keep_opposite_default_policies() -> None:
    """The search proxy ends in `deny all` behind an allow-list; the fetch proxy ends in `allow all`.

    Those two endings are the answer: a known URL set gets the hard rule, an unknown
    one gets the sink deny-list. Flipping either one turns the deployment into the other role.
    """
    search = read(SQUID / "search-allow.conf")
    assert re.search(
        r"http_access deny nonpublic\nhttp_access allow provider_hosts\nhttp_access deny all", search
    ), "the search proxy allows its rendered list only to a name that resolves somewhere public"
    lenient = read(SQUID / "fetch-lenient.conf")
    assert "http_access deny sinks" in lenient and lenient.rstrip().endswith("cache deny all")
    assert re.search(r"http_access deny sinks\nhttp_access deny nonpublic\nhttp_access allow all", lenient), (
        "the default fetch policy is the deny-list and then everything else"
    )
    strict = read(SQUID / "fetch-strict.conf")
    assert re.search(r"http_access allow readable\nhttp_access deny all", strict), (
        "the strict fetch policy must refuse every host the operator has not named"
    )


def test_compose_gives_each_role_its_own_proxy_and_no_route_around_it() -> None:
    """Two role networks, both `internal`, and only the proxies reach the network with a route out.

    `internal: true` is what makes the proxy un-bypassable; an app service also sitting on `egress`
    would hold a route of its own and the lists would bound nothing.
    """
    compose = read(COMPOSE)
    for network in ("search-egress", "fetch-egress"):
        assert re.search(rf"  {network}:\n    internal: true", compose), f"{network} must stay internal"
    for role, proxy in (("search", "search-proxy"), ("fetch", "fetch-proxy")):
        block = re.search(rf"^  {role}:\n((?:    .+\n)+)", compose, re.MULTILINE)
        assert block, f"compose has no {role} service"
        body = block.group(1)
        assert f"HTTPS_PROXY=http://{proxy}:3128" in body, f"{role} must dial out through {proxy}"
        assert f"networks: [{role}-egress]" in body, f"{role} must sit only on its own role network"
        assert f"image: {IMAGE}" in body, f"{role} must run the published image"
        assert "restart: unless-stopped" in body, f"{role} must come back after a restart of the host"
    for proxy, role in (("search-proxy", "search"), ("fetch-proxy", "fetch")):
        block = re.search(rf"^  {proxy}:\n((?:    .+\n)+)", compose, re.MULTILINE)
        assert block, f"compose has no {proxy} service"
        assert "restart: unless-stopped" in block.group(1), f"{proxy} must come back too"
        # Per proxy, not either/or: on the other role's network a proxy enforces the other role's list, which is
        # how a keyless search role ends up behind the fetch deny-list.
        assert f"networks: [{role}-egress, egress]" in block.group(1), (
            f"{proxy} must bridge {role}-egress and the network with a route out, not the other role's"
        )


def test_only_the_search_role_is_handed_a_key() -> None:
    """`search.env` reaches the search service and no other, so the fetch role holds nothing to spend."""
    compose = read(COMPOSE)
    search = re.search(r"^  search:\n((?:    .+\n)+)", compose, re.MULTILINE)
    fetch = re.search(r"^  fetch:\n((?:    .+\n)+)", compose, re.MULTILINE)
    assert search and fetch, "compose has no search or fetch service"
    assert "path: ./search.env" in search.group(1), "the search role reads its keys from search.env"
    assert "required: false" in search.group(1), "a keyless deployment must start without the file"
    assert "env_file" not in fetch.group(1), "the fetch role must be handed no env_file"
    assert not re.search(r"SEEKWRIGHT_[A-Z0-9_]*_API_KEY", fetch.group(1)), (
        "no key may reach the container that reads caller-chosen pages"
    )


def test_no_default_publishes_a_listener_beyond_loopback() -> None:
    """Both listeners default to `127.0.0.1`, in the port mapping and the Host allowlist alike.

    The published address is the access control, so this default is the bundle's whole safety margin.
    """
    compose = read(COMPOSE)
    for role, port in (("search", 8000), ("fetch", 8001)):
        block = re.search(rf"^  {role}:\n((?:    .+\n)+)", compose, re.MULTILINE)
        assert block, f"compose has no {role} service"
        body = block.group(1)
        assert f'"${{SEEKWRIGHT_PUBLISH:-127.0.0.1}}:{port}:8000"' in body, (
            f"{role} must publish on loopback by default"
        )
        assert f'"${{SEEKWRIGHT_PUBLISH:-127.0.0.1}}:{port}"' in body, (
            f"{role}'s Host allowlist must name the same default address"
        )


def test_the_operator_env_files_are_ignored_and_their_examples_are_not() -> None:
    """`.env` and `search.env` hold an operator's own values; the `.example` files are the template."""
    for path in ("deploy/compose/.env", "deploy/compose/search.env"):
        done = subprocess.run(["git", "check-ignore", "-q", path], capture_output=True, cwd=ROOT, check=False)
        assert done.returncode == 0, f"{path} is committable: it holds an operator's own values"
    for path in ("deploy/compose/.env.example", "deploy/compose/search.env.example"):
        done = subprocess.run(["git", "check-ignore", "-q", path], capture_output=True, cwd=ROOT, check=False)
        assert done.returncode != 0, f"{path} is gitignored: a clone then has no template to copy"


def test_the_example_env_files_carry_no_secret() -> None:
    """Every key line in the examples is commented out: the template names the variable and no value."""
    for name in (".env.example", "search.env.example"):
        for number, line in enumerate(read(BUNDLE / name).splitlines(), start=1):
            assert not re.match(r"^[A-Z0-9_]*API_KEY=\S", line), (
                f"{name}:{number} ships a value for a key: the template names variables, it does not fill them"
            )


def test_the_paranoid_switch_is_one_variable_and_both_files_exist() -> None:
    """`EGRESS_FETCH_POLICY=strict` is the whole of enabling the paranoid mode, and both forms are in the tree.

    A policy an operator has to edit a file to enable is a policy they do not enable.
    """
    compose = read(COMPOSE)
    assert "./squid/fetch-${EGRESS_FETCH_POLICY:-lenient}.conf:/etc/squid/squid.conf:ro" in compose, (
        "the fetch proxy's config is the one line the switch moves"
    )
    assert (SQUID / "fetch-lenient.conf").is_file() and (SQUID / "fetch-strict.conf").is_file()
    mounted = [line for line in compose.splitlines() if "EGRESS_FETCH_POLICY" in line and line.lstrip().startswith("- ")]
    assert len(mounted) == 1, "one switch, mounted once"


def test_the_role_configs_hold_the_switches_the_runbook_claims() -> None:
    """`config/search.toml` closes `fetch`; `config/fetch.toml` declares an empty provider set.

    Those two keys are the only difference between the containers, so a bundle whose configs drifted
    serves the wrong half of the surface on the wrong network.
    """
    search = read(BUNDLE / "search.toml")
    assert "permitted_providers = [" in search and re.search(r"\[fetch\]\nenabled = false", search), (
        "the search role must permit named providers and disable fetch"
    )
    fetch = read(BUNDLE / "fetch.toml")
    assert "permitted_providers = []" in fetch and re.search(r"\[fetch\]\nenabled = true", fetch), (
        "the fetch role must permit no provider and enable fetch"
    )


def test_the_deny_list_is_the_only_operator_list_the_default_policy_reads() -> None:
    """The lenient policy reads the operator's deny-list, and that list holds no provider host.

    A sink refused for `fetch` that a `search` also dials would be a policy aimed at the wrong role: the
    two proxies are separate, and keeping the sets apart is what makes that mistake visible.
    """
    deny = GENERATED / "fetch-deny.txt"
    refused = {line.strip() for line in read(deny).splitlines() if line.strip()}
    assert refused, "the default fetch policy is an empty deny-list, which refuses nothing"
    allowed = {line.strip() for line in read(GENERATED / "search-allow.txt").splitlines() if line.strip()}
    overlap = sorted(refused & allowed)
    assert not overlap, f"these hosts are refused for fetch and allowed for search: {overlap}"
    assert LISTS.is_dir() and (LISTS / "deny-hosts.txt").is_file()

def test_the_fetch_role_asks_a_resolver_the_same_file_starts() -> None:
    """An `internal` network has no route to a name server, so the fetch role's `dns:` names one this
    same bundle starts, at the address that service is given on that network.

    `fetch` resolves the target itself before the proxy is dialled (`fetcher.resolve_public`), so a role
    container with no name answer cannot fetch at all -- and a `dns:` line pointing at an address the
    bundle does not start is invisible until the first fetch fails.
    """
    compose = read(COMPOSE)
    named = re.findall(r"dns: \[([\d.]+)\]", compose)
    assert named, "the fetch role sits on an internal network and names no resolver"
    block = re.search(r"^  resolver:\n((?:    .+\n)+)", compose, re.MULTILINE)
    assert block, "compose has no resolver service"
    for address in named:
        assert f"ipv4_address: {address}" in block.group(1), (
            f"the role asks {address}, which no service in this file is given"
        )
    assert "./coredns/Corefile:/etc/coredns/Corefile:ro" in block.group(1)
    assert (COREDNS / "Corefile").is_file(), "the resolver mounts a Corefile the tree does not hold"


def test_the_exception_is_one_subtree_and_the_rest_of_deploy_stays_ignored() -> None:
    """`!deploy/compose/` is the whole exception: a snapshot file beside it stays untracked.

    `deploy/` keeps the operator's deployment snapshot -- hostnames, addresses, the update loop -- out
    of the tree, and exceptions written per sub-path would let a real `deploy/squid/prod.conf` or
    `deploy/config/prod.toml` sit in a clone as a committable file; this fails the widening.
    """
    for path in ("deploy/compose.yaml", "deploy/search.toml", "deploy/squid/prod.conf", "deploy/box/Caddyfile"):
        done = subprocess.run(["git", "check-ignore", "-q", path], capture_output=True, cwd=ROOT, check=False)
        assert done.returncode == 0, f"{path} is no longer gitignored: the exception has widened"
