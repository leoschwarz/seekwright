"""The packaging files that carry a copy of the version, and the build pin.

Two of them cannot be derived and can only be checked. `uv_build` requires a
static `version` in `[project]` -- `dynamic = ["version"]` is rejected outright
-- and an image `LABEL` cannot read Python at build time, so `pyproject.toml`
and the Containerfile each carry a copy of `seekwright.__version__`. Nothing
downstream would notice them drifting until a release shipped a wheel, an image
and a User-Agent naming three different versions, which is the failure this
module exists to make loud.

The toolchain check is here for the same reason `uv build` warns: a `uv_build`
requirement the running uv falls outside of means the published wheel was built
by a backend nobody runs locally.

The docs are checked for the same reason, one release further out. Two pages
quote the User-Agent in prose -- `docs/reference/configuration.md` shows the
`user_agent` default, `docs/reference/fetch-safety.md` names it in a sentence
about what a Chromium fingerprint is checked against -- and prose is the one
copy no import can reach and no `$EDITOR` line in `docs/reference/container.md`
lists. A page still saying `seekwright/0.1.0` after a bump to 0.2.0 is the same
drift as a stale `pyproject.toml`, one release later.
"""

import inspect
import re
import tomllib
from pathlib import Path

from seekwright import DEFAULT_USER_AGENT, PROJECT_URL, __version__
from seekwright.config import FetchConfig
from seekwright.fetcher import HttpFetcher

REPO_ROOT = Path(__file__).resolve().parents[2]
PYPROJECT = tomllib.loads((REPO_ROOT / "pyproject.toml").read_text(encoding="utf-8"))
CONTAINERFILE = (REPO_ROOT / "Containerfile").read_text(encoding="utf-8")

# The tracker's home, named by the metadata `Issues` field. It names the public
# home like every other shipped URL: an instance address is not a link to ship.
TRACKER_URL = "https://github.com/leoschwarz/seekwright"

# Every page that states what the tree does now: the README and the `docs/` tree.
DOCS = REPO_ROOT / "docs"
DOC_PAGES = sorted([*DOCS.rglob("*.md"), REPO_ROOT / "README.md"])

# The product token carries digits; path and placeholder mentions of `seekwright/`
# do not.
UA_VERSION = re.compile(r"seekwright/(\d+(?:\.\d+)*)")


def containerfile_label(name: str) -> str:
    """The value of one OCI label in the Containerfile."""
    match = re.search(rf'org\.opencontainers\.image\.{name}="([^"]*)"', CONTAINERFILE)
    assert match is not None, f"the Containerfile carries no image.{name} label"
    return match.group(1)


def uv_image_tag() -> str:
    """The uv version the image builds with."""
    match = re.search(r"FROM ghcr\.io/astral-sh/uv:(\S+) AS uv", CONTAINERFILE)
    assert match is not None, "the Containerfile does not build from the uv image"
    return match.group(1)


class TestTheVersionHasOneSource:
    def test_pyproject_carries_it(self):
        assert PYPROJECT["project"]["version"] == __version__

    def test_the_image_label_carries_it(self):
        assert containerfile_label("version") == __version__

    def test_the_user_agent_is_derived_from_it(self):
        assert DEFAULT_USER_AGENT == f"seekwright/{__version__} (+{PROJECT_URL})"
        assert FetchConfig().user_agent == DEFAULT_USER_AGENT
        # The fetcher's own default is what a hand-built `HttpFetcher` sends;
        # `factory`/`cli` pass the config's value.
        parameter = inspect.signature(HttpFetcher.__init__).parameters["user_agent"]
        assert parameter.default == DEFAULT_USER_AGENT

    def test_the_user_agent_names_no_dead_host(self):
        # `seekwright.dev` is a parked placeholder behind a self-signed certificate.
        assert "seekwright.dev" not in DEFAULT_USER_AGENT

    def test_every_metadata_url_names_the_canonical_home(self):
        urls = PYPROJECT["project"]["urls"]
        assert urls["Homepage"] == PROJECT_URL
        assert urls["Repository"] == PROJECT_URL
        # The one in-tree document, through GitHub's canonical file view -- the
        # URL that serves a file there once the repository is published.
        assert urls["Documentation"] == f"{PROJECT_URL}/blob/main/docs/index.md"
        # The image label is a copy of the home URL, exactly as the version
        # label is a copy of the version: nothing reads the source at build time.
        assert containerfile_label("source") == PROJECT_URL

    def test_the_tracker_field_names_the_public_home_like_the_others(self):
        # There is no exception any more: the instance tracker resolves only on
        # the machine that hosts it, so a reader of this metadata could not open
        # it, and the field points at the home instead.
        assert PYPROJECT["project"]["urls"]["Issues"] == f"{TRACKER_URL}/issues"

    def test_no_shipped_url_names_a_host_a_reader_cannot_open(self):
        # The check is positive: every shipped URL sits under the canonical home,
        # so any other host fails it without this file naming a retired or
        # machine-local address. A reader of this metadata has to be able to open
        # what it names, and an address that resolves only on the machine that
        # publishes it makes the field a URL nobody can follow.
        shipped = [
            *PYPROJECT["project"]["urls"].values(),
            PROJECT_URL,
            DEFAULT_USER_AGENT,
            containerfile_label("source"),
        ]
        off_home = [url for url in shipped if PROJECT_URL not in url]
        assert not off_home, "; ".join(off_home)


def requirement_names(requirements: list[str]) -> set[str]:
    """The distributions a requirement list names, specifiers and markers off."""
    return {re.split(r"[<>=!~;\[]", line.strip())[0] for line in requirements}


class TestThePdfParserIsAnExtra:
    """The one library that parses a stranger's bytes is opt-in.

    `pypdf` walks a file structure nobody asked for, so an install of this
    package that never reads a PDF should not carry it at all. It belongs to
    the extra of the backend that reads those bytes -- step 4 of the wiring
    list in `extractors/base.py` -- and that module guards the import, so an
    install carrying only part of the extra loses PDF reading and nothing else.
    """

    def test_the_core_install_carries_no_pdf_parser(self):
        core = requirement_names(PYPROJECT["project"]["dependencies"])
        assert "pypdf" not in core, "the PDF parser must not be a core dependency"

    def test_the_backend_that_reads_pdf_carries_it(self):
        extras = PYPROJECT["project"]["optional-dependencies"]
        assert "pypdf" in requirement_names(extras["trafilatura"])

    def test_the_shipped_image_still_asks_for_that_extra(self):
        """The image is the artifact that must keep reading PDFs, and it now
        gets the parser from the extra rather than from the core install."""
        assert re.search(r"--extra[= ]trafilatura", CONTAINERFILE), (
            "the image no longer installs the default extraction backend's extra"
        )


class TestTheBuildToolchain:
    def test_the_image_is_the_uv_build_requirement(self):
        (requirement,) = PYPROJECT["build-system"]["requires"]
        match = re.fullmatch(r"uv_build>=([^,]+),<([^,]+)", requirement)
        assert match is not None, (
            f"the pin needs a lower and an upper bound: {requirement!r}"
        )
        lower, _upper = match.groups()
        # The image's uv builds the wheel that ships, so the tag is the
        # requirement's lower bound.
        assert uv_image_tag() == lower


class TestTheDocsQuoteTheCurrentUserAgent:
    """The User-Agent is quoted in prose, where nothing derives it.

    `test_the_user_agent_is_derived_from_it` covers the copy the code builds;
    these pages are the copies a bump can forget, because prose is what no
    import reaches and the `$EDITOR` lines in `docs/reference/container.md`
    cannot enumerate. The bump step already runs this module, so the guard is
    what makes that step sufficient.
    """

    def test_the_scan_has_a_page_that_quotes_it(self):
        # A scan of nothing passes for the wrong reason: at least one page has
        # to carry the literal for the check below to be a check at all.
        quoting = [
            page
            for page in DOC_PAGES
            if UA_VERSION.search(page.read_text(encoding="utf-8"))
        ]
        assert quoting, "no page under docs/ or the README quotes the User-Agent"

    def test_no_page_quotes_another_version(self):
        stale = []
        for page in DOC_PAGES:
            text = page.read_text(encoding="utf-8")
            for match in UA_VERSION.finditer(text):
                if match.group(1) == __version__:
                    continue
                line = text.count("\n", 0, match.start()) + 1
                where = page.relative_to(REPO_ROOT)
                stale.append(f"{where}:{line}: {match.group(0)}")
        assert not stale, (
            f"these pages quote a User-Agent version other than {__version__}: "
            + "; ".join(stale)
        )
