"""The model-facing strings ship as package data and load as prose.

The loaders in ``prompts.py`` and ``dashboard.py`` are all that is left; what
matters is that the ``resources/`` files resolve through ``importlib.resources``
-- so a wheel carries them -- and that the constants equal the file contents.
"""

import re
from importlib.resources import files
from typing import ClassVar

import pytest

from seekwright.config import FREE_PROVIDERS
from seekwright.dashboard import DASHBOARD_HTML
from seekwright.prompts import (
    ANSWER_DESCRIPTION,
    ANSWER_SYSTEM_PROMPT,
    FETCH_DESCRIPTION,
    SEARCH_DESCRIPTION,
    SERVER_INSTRUCTIONS,
)

_RESOURCES = files("seekwright").joinpath("resources")

CASES = {
    "server_instructions.txt": SERVER_INSTRUCTIONS,
    "search_description.txt": SEARCH_DESCRIPTION,
    "fetch_description.txt": FETCH_DESCRIPTION,
    "answer_description.txt": ANSWER_DESCRIPTION,
    "answer_system.txt": ANSWER_SYSTEM_PROMPT,
    "dashboard.html": DASHBOARD_HTML,
}

# Page, system prompt and instructions end with a newline; tool descriptions do not,
# because a client renders a trailing newline in a description as a blank line.
TRAILING_NEWLINE = {
    "server_instructions.txt": True,
    "search_description.txt": False,
    "fetch_description.txt": False,
    "answer_description.txt": False,
    "answer_system.txt": True,
    "dashboard.html": True,
}


def test_every_resource_ships_and_loads() -> None:
    for name, value in CASES.items():
        path = _RESOURCES.joinpath(name)
        assert path.is_file(), name
        assert value == path.read_text(encoding="utf-8")
        assert value.endswith("\n") is TRAILING_NEWLINE[name], name


def test_paragraphs_stay_unwrapped() -> None:
    # A paragraph soft-wrapped across lines would render wrapped in a client;
    # the value keeps each paragraph on one line, blank lines between.
    assert "\n\n" in SERVER_INSTRUCTIONS
    assert "\n\n" in SEARCH_DESCRIPTION
    assert "\n\n" in FETCH_DESCRIPTION
    assert "\n\n" in ANSWER_DESCRIPTION
    assert "\n\n" in ANSWER_SYSTEM_PROMPT


# The machine-readable half of the contract: keep the sentence whole, ending at its
# first period.
UNBILLED_ANCHOR = "The names that cannot bill are "


def _unbilled_names_in(text: str) -> set[str]:
    """The provider names ``text`` lists as unable to bill.

    Whitespace is flattened first: `server_instructions.txt` wraps its
    paragraphs across source lines, so its sentence is only whole once the
    newlines are gone.
    """
    flat = " ".join(text.split())
    start = flat.index(UNBILLED_ANCHOR) + len(UNBILLED_ANCHOR)
    return set(re.findall(r"`([^`]+)`", flat[start : flat.index(".", start)]))


class TestTheUnbilledSetIsNamed:
    """The strings a *calling model* reads name every provider that cannot bill.

    The drift guard, in the shape of
    `test_config.py::TestTheDocumentedExample`: the prose and
    `config.FREE_PROVIDERS` are asserted to be the *same* set, in both
    directions. A provider that lands in `FREE_PROVIDERS` without the prose
    being touched fails here, and so does a prose list that outlives a rename
    or a name that leaves the set while the prose still promises it is free.

    The claim being guarded is the one that made a model avoid the free names:
    the strings used to say exactly one provider was unbilled. Three sites
    enumerate the set -- both resources and `search`'s `mode` description,
    which is the schema a client renders -- so all three are asserted.
    """

    PROSE: ClassVar[dict[str, str]] = {
        "search_description.txt": SEARCH_DESCRIPTION,
        "server_instructions.txt": SERVER_INSTRUCTIONS,
    }

    @pytest.mark.parametrize("filename", sorted(PROSE))
    def test_it_names_exactly_the_providers_that_cannot_bill(self, filename):
        text = self.PROSE[filename]
        flat = " ".join(text.split())

        assert UNBILLED_ANCHOR in flat, f"{filename} drops the unbilled set"
        assert _unbilled_names_in(text) == set(FREE_PROVIDERS), filename

    @pytest.mark.parametrize("filename", sorted(PROSE))
    def test_the_retired_understatement_stays_out(self, filename):
        """The wording the issue was filed about cannot come back beside the set.

        "All but one are billed" is a summary claim the named set contradicts,
        and it is what told a model that naming a free provider would cost it.
        """
        assert "all but one" not in self.PROSE[filename].lower()

    async def test_the_mode_parameter_names_it_too(self, monkeypatch, tmp_path):
        """`mode`'s own description is the third site, and a client renders it.

        A set named in the resources and not in the schema would still be a
        contract the model reads wrong.
        """
        config = tmp_path / "config.toml"
        config.write_text("[providers.serper]\nenabled = true\n")
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(config))
        from seekwright.server import mcp

        search = next(tool for tool in await mcp.list_tools() if tool.name == "search")
        description = search.inputSchema["properties"]["mode"]["description"]

        assert UNBILLED_ANCHOR in " ".join(description.split())
        assert _unbilled_names_in(description) == set(FREE_PROVIDERS)
