"""An MCP proxy in front of web-search providers: paid, free-tiered and keyless."""

# The single source for the version: `pyproject.toml`'s `version` and the Containerfile's image-version
# label each carry a copy that cannot read this one, and tests/repo/test_packaging.py asserts they match.
__version__ = "0.1.0"

# The canonical home every shipped URL sits under; `seekwright.dev` stays out of
# every shipped field (tests/repo/test_packaging.py).
PROJECT_URL = "https://github.com/leoschwarz/seekwright"

# What `fetch` sends to an arbitrary third-party site: product, version, contact.
DEFAULT_USER_AGENT = f"seekwright/{__version__} (+{PROJECT_URL})"


def main() -> None:
    # Imported lazily so `import seekwright` stays cheap: config loading exits on a
    # missing provider key or an empty provider set.
    from .cli import main as _main

    _main()


__all__ = ["main"]
