"""Every model-facing string in one place: nothing here but prose.

`server.py` wires these into the FastMCP instructions and the tool schemas;
the texts themselves are content, and they live as plain files under
``resources/`` so a prompt diff is a text diff and the "what does the model
read" audit has a single home.

They are read from package data once, at import. uv_build puts every file under
the module root into the wheel, so ``resources/`` needs no build-backend
configuration to ship -- see ``docs/reference/container.md`` for the image that
consumes it.

Each file keeps a whole paragraph per line, blank lines between paragraphs: the
value is what the MCP clients render, so a paragraph soft-wrapped across source
lines would render wrapped. The tool descriptions carry no trailing newline,
which is why the old inline constants ended with a source continuation -- don't
add one.
"""

from __future__ import annotations

from importlib.resources import files

_RESOURCES = files("seekwright").joinpath("resources")

SERVER_INSTRUCTIONS = _RESOURCES.joinpath("server_instructions.txt").read_text(
    encoding="utf-8"
)
SEARCH_DESCRIPTION = _RESOURCES.joinpath("search_description.txt").read_text(
    encoding="utf-8"
)
FETCH_DESCRIPTION = _RESOURCES.joinpath("fetch_description.txt").read_text(
    encoding="utf-8"
)
ANSWER_SYSTEM_PROMPT = _RESOURCES.joinpath("answer_system.txt").read_text(
    encoding="utf-8"
)
ANSWER_DESCRIPTION = _RESOURCES.joinpath("answer_description.txt").read_text(
    encoding="utf-8"
)
